//! AI plugin host & on-demand model commands owned by `Core`.
//!
//! All AI work runs off the GUI thread (downloads via `curl`, inference via an
//! out-of-process `jsonl-stdio` worker). `poll_ai()` drains progress/completion
//! events on the shell's poll timer and applies finished pixel outputs to
//! `EditorDocument` as a single undoable `EditOperation::AiResult`.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, TryRecvError};
use std::sync::Arc;

use kogaview_protocol::{AiDevice, AiTaskState, ProtocolError, UiText};
use serde_json::json;

use super::*;
use crate::plugins::{self, AiWorkerEvent, REMBG_ACTION};

impl Core {
    /// Refresh discovered plugin manifests and model installation status.
    /// Reads only small JSON manifests and `stat()`s model files — never
    /// spawns any worker process.
    pub(super) fn refresh_ai_inventory(&mut self) {
        self.ai_plugins = plugins::discover_plugins(&self.paths.plugins_dir);
        self.state.ai_settings = self.config.ai.clone();
        self.state.ai_plugins = plugins::plugin_statuses(&self.ai_plugins);
        self.state.ai_models =
            plugins::model_statuses(&self.paths.models_dir, &self.config.ai, &self.ai_plugins);
        self.state.quick_actions = plugins::quick_actions(&self.ai_plugins);
    }

    pub(super) fn ai_refresh_plugins(&mut self) -> Result<Option<UiText>, ProtocolError> {
        self.refresh_ai_inventory();
        Ok(Some(UiText::new("ai_plugins_refreshed")))
    }

    pub(super) fn ai_set_settings(
        &mut self,
        device: AiDevice,
        auto_unload_secs: u32,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.config.ai.device = device;
        self.config.ai.auto_unload_secs = auto_unload_secs;
        self.config.ai = self.config.ai.clone().sanitized();
        self.state.ai_settings = self.config.ai.clone();
        self.save_config();
        Ok(Some(UiText::new("settings_saved")))
    }

    pub(super) fn ai_download_model(
        &mut self,
        model_id: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let specs = plugins::catalog_models(&self.ai_plugins);
        let Some(spec) = specs.into_iter().find(|m| m.id == model_id) else {
            return Err(ProtocolError::with_line(
                "not_found",
                format!("unknown AI model: {model_id}"),
                UiText::with("ai_model_unknown", [model_id.to_owned()]),
            ));
        };

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_rx = Some(rx);
        self.ai_cancel = Some(Arc::clone(&cancel));
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "download".to_owned(),
            target: spec.id.clone(),
            running: true,
            percent: 0,
            stage: format!("Downloading {}…", spec.name),
            error: None,
            clipboard_text: None,
            translation: None,
            caption_text: None,
        });
        self.state.status = UiText::with("ai_downloading_model", [spec.name.clone()]);

        let models_dir = self.paths.models_dir.clone();
        std::thread::spawn(move || {
            plugins::download_model(&spec, &models_dir, cancel, &tx);
        });

        Ok(Some(UiText::with(
            "ai_downloading_model",
            [model_id.to_owned()],
        )))
    }

    pub(super) fn ai_delete_model(
        &mut self,
        model_id: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        let specs = plugins::catalog_models(&self.ai_plugins);
        let Some(spec) = specs.into_iter().find(|m| m.id == model_id) else {
            return Err(ProtocolError::with_line(
                "not_found",
                format!("unknown AI model: {model_id}"),
                UiText::with("ai_model_unknown", [model_id.to_owned()]),
            ));
        };
        let path = self.paths.models_dir.join(&spec.file);
        if path.is_file() {
            fs::remove_file(&path).map_err(|error| {
                ProtocolError::with_line(
                    "io_error",
                    format!("cannot delete model {}: {error}", path.display()),
                    UiText::with("ai_model_delete_failed", [model_id.to_owned()]),
                )
            })?;
        }
        self.config.ai.custom_model_paths.remove(model_id);
        self.save_config();
        self.refresh_ai_inventory();
        Ok(Some(UiText::with("ai_model_deleted", [spec.name])))
    }

    pub(super) fn ai_set_custom_model(
        &mut self,
        model_id: &str,
        path: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            self.config.ai.custom_model_paths.remove(model_id);
        } else {
            let candidate = PathBuf::from(trimmed);
            if !candidate.is_file() {
                return Err(ProtocolError::with_line(
                    "not_found",
                    format!("model file not found: {}", candidate.display()),
                    UiText::with("ai_model_file_missing", [trimmed.to_owned()]),
                ));
            }
            self.config
                .ai
                .custom_model_paths
                .insert(model_id.to_owned(), trimmed.to_owned());
        }
        self.save_config();
        self.refresh_ai_inventory();
        Ok(Some(UiText::new("settings_saved")))
    }

    pub(super) fn ai_cancel(&mut self) -> Result<Option<UiText>, ProtocolError> {
        if let Some(cancel) = &self.ai_cancel {
            cancel.store(true, Ordering::SeqCst);
            self.state.status = UiText::new("cancelling");
            Ok(Some(UiText::new("cancelling")))
        } else {
            Err(ProtocolError::with_line(
                "not_running",
                "no AI task is currently running",
                UiText::new("cancel_nothing_running"),
            ))
        }
    }

    /// Resolve the input pixel buffer and coordinate offset `(ox, oy)` for an
    /// Editor AI operation targeting `target`. Refuses early if `ActiveLayer` is
    /// locked or hidden so no worker process is spawned unnecessarily.
    fn editor_ai_input(
        &self,
        target: ApplyTarget,
    ) -> Result<(Arc<image::RgbaImage>, i32, i32), ProtocolError> {
        let doc = self.editor.as_ref().ok_or_else(no_editor_document)?;
        if target == ApplyTarget::ActiveLayer {
            let active = doc.active_layer();
            if active.locked {
                return Err(ProtocolError::line(
                    "invalid_edit",
                    UiText::new("layer_locked"),
                ));
            }
            if !active.visible {
                return Err(ProtocolError::line(
                    "invalid_edit",
                    UiText::new("layer_hidden"),
                ));
            }
            Ok((Arc::clone(&active.pixels), active.offset_x, active.offset_y))
        } else {
            Ok((doc.pixels(), 0, 0))
        }
    }

    pub(super) fn editor_ai_remove_background(
        &mut self,
        model_id: &str,
        feather: u8,
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let (pixels, _, _) = self.editor_ai_input(target)?;

        // Ensure plugin list is up to date before spawning.
        self.refresh_ai_inventory();

        let Some(plugin) = self
            .ai_plugins
            .iter()
            .find(|p| {
                p.available
                    && p.manifest
                        .capabilities
                        .iter()
                        .any(|c| c.action == REMBG_ACTION)
            })
            .cloned()
        else {
            return Err(ProtocolError::with_line(
                "plugin_missing",
                "Remove Background plugin binary (kogaview-plugin-rembg) is not installed",
                UiText::new("ai_plugin_missing"),
            ));
        };

        let Some(model_status) = self.state.ai_models.iter().find(|m| m.id == model_id) else {
            return Err(ProtocolError::with_line(
                "not_found",
                format!("unknown AI model: {model_id}"),
                UiText::with("ai_model_unknown", [model_id.to_owned()]),
            ));
        };
        let Some(model_path_str) = model_status.effective_path.clone() else {
            return Err(ProtocolError::with_line(
                "model_missing",
                format!("AI model '{model_id}' is not downloaded yet"),
                UiText::with("ai_model_not_installed", [model_status.name.clone()]),
            ));
        };

        fs::create_dir_all(&self.paths.ai_ipc_dir).map_err(|error| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot create ai-ipc directory: {error}"),
                UiText::new("ai_inference_failed"),
            )
        })?;

        self.ai_generation += 1;
        let gen = self.ai_generation;
        let input_path = self.paths.ai_ipc_dir.join(format!("in-{gen}.png"));
        let output_path = self.paths.ai_ipc_dir.join(format!("out-{gen}.png"));
        let _ = fs::remove_file(&output_path);

        pixels.save(&input_path).map_err(|error| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot write temporary input PNG: {error}"),
                UiText::new("ai_inference_failed"),
            )
        })?;

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_rx = Some(rx);
        self.ai_cancel = Some(Arc::clone(&cancel));
        self.ai_temp_input = Some(input_path.clone());
        self.ai_temp_output = Some(output_path.clone());
        self.ai_apply_target = target;
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "inference".to_owned(),
            target: model_id.to_owned(),
            running: true,
            percent: 5,
            stage: "Starting Remove Background…".to_owned(),
            error: None,
            clipboard_text: None,
            translation: None,
            caption_text: None,
        });
        self.state.status = UiText::new("ai_removing_background");

        let device = self.config.ai.device;
        let model_id_owned = model_id.to_owned();
        let model_path = PathBuf::from(model_path_str);
        let feather_clamped = feather.min(20);

        std::thread::spawn(move || {
            plugins::run_plugin_inference(
                &plugin,
                REMBG_ACTION,
                &model_id_owned,
                &model_path,
                device,
                &input_path,
                &output_path,
                json!({ "feather": feather_clamped }),
                cancel,
                &tx,
            );
        });

        Ok(Some(UiText::new("ai_removing_background")))
    }

    /// Run a plugin-contributed Quick Action from Browser or Viewer context menus.
    /// Non-destructive: writes `<stem>-nobg.png` next to the source file and
    /// refreshes the folder listing when done.
    pub(super) fn quick_action_run(
        &mut self,
        plugin_id: &str,
        action_id: &str,
        paths: Vec<String>,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let Some(first_path) = paths.into_iter().find(|p| !p.trim().is_empty()) else {
            return Err(ProtocolError::with_line(
                "invalid_input",
                "no image path provided for quick action",
                UiText::new("no_source_files"),
            ));
        };
        let src_path = PathBuf::from(&first_path);
        if !src_path.is_file() {
            return Err(ProtocolError::with_line(
                "not_found",
                format!("image not found: {}", src_path.display()),
                UiText::new("no_existing_paths"),
            ));
        }

        self.refresh_ai_inventory();

        let Some(plugin) = self
            .ai_plugins
            .iter()
            .find(|p| p.manifest.id == plugin_id)
            .cloned()
        else {
            return Err(ProtocolError::with_line(
                "plugin_missing",
                format!("plugin '{plugin_id}' not found"),
                UiText::new("ai_plugin_missing"),
            ));
        };
        if !plugin.available {
            return Err(ProtocolError::with_line(
                "plugin_missing",
                format!(
                    "plugin '{}' binary is not installed (run: just build-plugin-rembg)",
                    plugin.manifest.name
                ),
                UiText::new("ai_plugin_missing"),
            ));
        }
        let Some(qa) = plugin
            .manifest
            .quick_actions
            .iter()
            .find(|q| q.id == action_id)
            .cloned()
        else {
            return Err(ProtocolError::with_line(
                "not_found",
                format!("quick action '{action_id}' not found on plugin '{plugin_id}'"),
                UiText::new("ai_inference_failed"),
            ));
        };

        let model_id = qa
            .params
            .get("modelId")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_owned();
        let model_path = if model_id.is_empty() {
            PathBuf::new()
        } else {
            let Some(model_status) = self.state.ai_models.iter().find(|m| m.id == model_id) else {
                return Err(ProtocolError::with_line(
                    "not_found",
                    format!("unknown AI model: {model_id}"),
                    UiText::with("ai_model_unknown", [model_id]),
                ));
            };
            let Some(model_path_str) = model_status.effective_path.clone() else {
                return Err(ProtocolError::with_line(
                    "model_missing",
                    format!("AI model '{model_id}' is not downloaded yet"),
                    UiText::with("ai_model_not_installed", [model_status.name.clone()]),
                ));
            };
            PathBuf::from(model_path_str)
        };

        fs::create_dir_all(&self.paths.ai_ipc_dir).map_err(|error| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot create ai-ipc directory: {error}"),
                UiText::new("ai_inference_failed"),
            )
        })?;

        self.ai_generation += 1;
        let gen = self.ai_generation;
        let tmp_out = self.paths.ai_ipc_dir.join(format!("qa-out-{gen}.png"));
        let _ = fs::remove_file(&tmp_out);

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_rx = Some(rx);
        self.ai_cancel = Some(Arc::clone(&cancel));
        self.ai_temp_input = None;
        self.ai_temp_output = Some(tmp_out.clone());
        self.ai_quick_action_output = Some(src_path.clone());
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "inference".to_owned(),
            target: qa.label.clone(),
            running: true,
            percent: 5,
            stage: format!("{}…", qa.label),
            error: None,
            clipboard_text: None,
            translation: None,
            caption_text: None,
        });
        self.state.status = UiText::new("ai_removing_background");

        let device = self.config.ai.device;
        let action_name = qa.action.clone();
        let mut params = qa.params.clone();
        if let Some(obj) = params.as_object_mut() {
            obj.insert(
                "modelsDir".to_owned(),
                json!(self.paths.models_dir.display().to_string()),
            );
        }

        std::thread::spawn(move || {
            plugins::run_plugin_inference(
                &plugin,
                &action_name,
                &model_id,
                &model_path,
                device,
                &src_path,
                &tmp_out,
                params,
                cancel,
                &tx,
            );
        });

        Ok(Some(UiText::new("ai_removing_background")))
    }

    /// Translate or OCR-only an entire image or a cropped `[x, y, w, h]` region
    /// in Viewer.
    /// - `ocr_engine == "manga_ocr"` or `"rapidocr"`: routes to `kogaview.ocr.ai` (`viewer.ai_ocr`)
    /// - `ocr_engine == "tesseract"` (or empty): routes to `viewer.ocr_copy` when `target_lang`
    ///   is empty, or `viewer.translate` when `target_lang` is set.
    pub(super) fn viewer_translate(
        &mut self,
        path: &str,
        source_lang: &str,
        target_lang: &str,
        region: Option<[i32; 4]>,
        ocr_engine: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let src_path = PathBuf::from(path);
        if !src_path.is_file() {
            return Err(ProtocolError::with_line(
                "not_found",
                format!("image not found: {}", src_path.display()),
                UiText::new("no_existing_paths"),
            ));
        }

        self.refresh_ai_inventory();

        let ocr_only = target_lang.trim().is_empty();
        let use_ai_ocr = ocr_engine == "manga_ocr" || ocr_engine == "rapidocr";
        let wanted_action = if use_ai_ocr {
            "viewer.ai_ocr"
        } else if ocr_only {
            "viewer.ocr_copy"
        } else {
            "viewer.translate"
        };

        let Some(plugin) = self
            .ai_plugins
            .iter()
            .find(|p| {
                p.available
                    && p.manifest
                        .capabilities
                        .iter()
                        .any(|c| c.action == wanted_action)
            })
            .cloned()
        else {
            return Err(ProtocolError::with_line(
                "plugin_missing",
                if use_ai_ocr {
                    "AI OCR plugin (Manga-OCR / RapidOCR) is not installed (run: just build-plugin-ai-ocr)"
                } else if ocr_only {
                    "OCR plugin is not installed (run: just build-plugin-ocr)"
                } else {
                    "Read & Translate plugin is not installed (run: just build-plugin-translate)"
                },
                UiText::new("ai_translate_plugin_missing"),
            ));
        };

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_rx = Some(rx);
        self.ai_cancel = Some(Arc::clone(&cancel));
        self.ai_temp_input = None;
        self.ai_temp_output = None;
        self.ai_quick_action_output = None;
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "translate".to_owned(),
            target: path.to_owned(),
            running: true,
            percent: 10,
            stage: if use_ai_ocr {
                if ocr_engine == "manga_ocr" {
                    "Running Manga-OCR…".to_owned()
                } else {
                    "Running RapidOCR…".to_owned()
                }
            } else if ocr_only {
                "Scanning text (OCR)…".to_owned()
            } else {
                "Translating…".to_owned()
            },
            error: None,
            clipboard_text: None,
            translation: None,
            caption_text: None,
        });
        self.state.status = UiText::new("ai_translating");

        let device = self.config.ai.device;
        let models_dir = self.paths.models_dir.display().to_string();
        let mut params = if use_ai_ocr {
            json!({
                "engine": ocr_engine,
                "sourceLang": source_lang,
                "targetLang": target_lang,
                "modelsDir": models_dir,
            })
        } else if ocr_only {
            json!({
                "lang": source_lang,
                "modelsDir": models_dir,
                "returnTranslation": true,
            })
        } else {
            json!({
                "sourceLang": source_lang,
                "targetLang": target_lang,
                "modelsDir": models_dir,
            })
        };
        if let Some([x, y, w, h]) = region {
            params["region"] = json!({ "x": x, "y": y, "width": w, "height": h });
        }

        let action_owned = wanted_action.to_owned();
        std::thread::spawn(move || {
            let empty_out = PathBuf::new();
            let empty_model = PathBuf::new();
            plugins::run_plugin_inference(
                &plugin,
                &action_owned,
                "",
                &empty_model,
                device,
                &src_path,
                &empty_out,
                params,
                cancel,
                &tx,
            );
        });

        Ok(Some(UiText::new("ai_translating")))
    }

    /// Drain events from any active AI download or inference worker.
    pub(super) fn poll_ai(&mut self) -> bool {
        let mut changed = false;
        let mut finished = false;
        let mut events = Vec::new();

        if let Some(rx) = &self.ai_rx {
            loop {
                match rx.try_recv() {
                    Ok(ev) => events.push(ev),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        finished = true;
                        break;
                    }
                }
            }
        }

        for ev in events {
            changed = true;
            match ev {
                AiWorkerEvent::Progress { percent, stage } => {
                    if let Some(task) = self.state.ai_task.as_mut() {
                        task.percent = percent;
                        task.stage = stage;
                    }
                }
                AiWorkerEvent::DownloadDone { model_id, .. } => {
                    finished = true;
                    self.refresh_ai_inventory();
                    if let Some(task) = self.state.ai_task.as_mut() {
                        task.running = false;
                        task.percent = 100;
                        task.stage = "Download complete".to_owned();
                        task.error = None;
                    }
                    self.state.status = UiText::with("ai_model_downloaded", [model_id]);
                }
                AiWorkerEvent::InferenceDone {
                    model_id,
                    output_path,
                    device_used,
                    clipboard_text,
                    translation,
                    caption_text,
                } => {
                    finished = true;
                    if let Some(tr) = translation {
                        self.ai_quick_action_output = None;
                        if let Some(task) = self.state.ai_task.as_mut() {
                            task.running = false;
                            task.percent = 100;
                            task.stage = "Translated".to_owned();
                            task.error = None;
                            task.translation = Some(tr);
                        }
                        self.state.status = UiText::new("ai_translate_done");
                    } else if let Some(text) = clipboard_text {
                        self.ai_quick_action_output = None;
                        let chars = text.chars().count();
                        if let Some(task) = self.state.ai_task.as_mut() {
                            task.running = false;
                            task.percent = 100;
                            task.stage = format!("Copied {chars} characters");
                            task.error = None;
                            task.clipboard_text = Some(text);
                            task.caption_text = caption_text;
                        }
                        self.state.status =
                            UiText::with("ai_quick_action_copied", [chars.to_string()]);
                    } else if let Some(cap) = caption_text {
                        self.ai_quick_action_output = None;
                        if let Some(task) = self.state.ai_task.as_mut() {
                            task.running = false;
                            task.percent = 100;
                            task.stage = "Caption generated".to_owned();
                            task.error = None;
                            task.caption_text = Some(cap);
                        }
                        self.state.status = UiText::new("ai_caption_done");
                    } else if let Some(target_path) = self.ai_quick_action_output.take() {
                        match backup_and_overwrite(&target_path, &output_path) {
                            Ok(backup_path) => {
                                let out_name = target_path
                                    .file_name()
                                    .and_then(|n| n.to_str())
                                    .unwrap_or("image")
                                    .to_owned();
                                tracing::info!(
                                    target: "kogaview::plugins",
                                    target = %target_path.display(),
                                    backup = %backup_path.display(),
                                    device = %device_used,
                                    "quick action backed up original and overwrote target"
                                );
                                if let Some(task) = self.state.ai_task.as_mut() {
                                    task.running = false;
                                    task.percent = 100;
                                    task.stage = format!("Saved {out_name} ({device_used})");
                                    task.error = None;
                                }
                                self.state.tree_revision += 1;
                                self.refresh_current();
                                let target_str = target_path.to_string_lossy().into_owned();
                                let _ = self.open_file(vec![target_str]);
                                self.state.status =
                                    UiText::with("ai_quick_action_saved", [out_name]);
                            }
                            Err(message) => {
                                if let Some(task) = self.state.ai_task.as_mut() {
                                    task.running = false;
                                    task.error = Some(message);
                                }
                                self.state.status = UiText::new("ai_inference_failed");
                            }
                        }
                    } else {
                        let is_watermark = self
                            .state
                            .ai_task
                            .as_ref()
                            .map(|t| {
                                t.target.starts_with("editor.dewatermark")
                                    || t.target.starts_with("editor.inpaint")
                                    || t.target.starts_with("editor.ai_inpaint")
                            })
                            .unwrap_or(false);
                        match image::open(&output_path).map(|img| img.into_rgba8()) {
                            Ok(rgba) => {
                                let label = if is_watermark {
                                    UiText::new("remove_watermark")
                                } else {
                                    UiText::with("remove_background", [model_id])
                                };
                                let op = EditOperation::AiResult {
                                    label,
                                    pixels: Arc::new(rgba),
                                };
                                let apply_target = self.ai_apply_target;
                                match self.editor_apply_with_target(op, apply_target) {
                                    Ok(_) => {
                                        if let Some(task) = self.state.ai_task.as_mut() {
                                            task.running = false;
                                            task.percent = 100;
                                            task.stage = format!("Done ({device_used})");
                                            task.error = None;
                                        }
                                        self.state.status = if is_watermark {
                                            UiText::new("ai_remove_watermark_done")
                                        } else {
                                            UiText::new("ai_remove_background_done")
                                        };
                                    }
                                    Err(err) => {
                                        if let Some(task) = self.state.ai_task.as_mut() {
                                            task.running = false;
                                            task.error = Some(err.message.clone());
                                        }
                                        self.state.status = UiText::new("ai_inference_failed");
                                    }
                                }
                            }
                            Err(error) => {
                                if let Some(task) = self.state.ai_task.as_mut() {
                                    task.running = false;
                                    task.error =
                                        Some(format!("cannot decode plugin output PNG: {error}"));
                                }
                                self.state.status = UiText::new("ai_inference_failed");
                            }
                        }
                    }
                }
                AiWorkerEvent::Failed { message } => {
                    finished = true;
                    if let Some(task) = self.state.ai_task.as_mut() {
                        task.running = false;
                        task.error = Some(message);
                    }
                    self.state.status = UiText::new("ai_inference_failed");
                }
                AiWorkerEvent::Cancelled => {
                    finished = true;
                    if let Some(task) = self.state.ai_task.as_mut() {
                        task.running = false;
                        task.stage = "Cancelled".to_owned();
                    }
                    self.state.status = UiText::new("operation_cancelled");
                }
            }
        }

        if finished {
            self.ai_rx = None;
            self.ai_cancel = None;
            self.ai_quick_action_output = None;
            self.ai_apply_target = ApplyTarget::WholeImage;
            if let Some(p) = self.ai_temp_input.take() {
                let _ = fs::remove_file(p);
            }
            if let Some(p) = self.ai_temp_output.take() {
                let _ = fs::remove_file(p);
            }
            self.state.busy = self.op_rx.is_some() || self.batch_rx.is_some();
            if let Some(task) = self.state.ai_task.as_mut() {
                task.running = false;
            }
            changed = true;
        }

        changed
    }
}

/// Compute the backup path next to `target`:
/// - First backup: `<filename>~` (e.g. `photo.png~`)
/// - Subsequent backups when it already exists: `<filename>.2~`, `<filename>.3~`, …
/// Every backup filename ends with `~`.
pub(crate) fn next_backup_path(target: &Path) -> PathBuf {
    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    let name = target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("image");
    let first = parent.join(format!("{name}~"));
    if !first.exists() {
        return first;
    }
    let mut index = 2u32;
    loop {
        let candidate = parent.join(format!("{name}.{index}~"));
        if !candidate.exists() {
            return candidate;
        }
        index += 1;
    }
}

/// Back up `target` to `next_backup_path(target)` and atomically overwrite
/// `target` with `result_png` (staged in the same directory so cross-device
/// `rename` never fails).
pub(crate) fn backup_and_overwrite(target: &Path, result_png: &Path) -> Result<PathBuf, String> {
    let backup = next_backup_path(target);
    fs::copy(target, &backup)
        .map_err(|e| format!("cannot create backup '{}': {e}", backup.display()))?;

    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    let name = target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("image");
    let staged = parent.join(format!(".{name}.kogaview-qa.tmp"));
    if let Err(e) = fs::copy(result_png, &staged) {
        let _ = fs::remove_file(&staged);
        return Err(format!("cannot stage quick action output: {e}"));
    }
    if let Err(e) = fs::rename(&staged, target) {
        let _ = fs::remove_file(&staged);
        return Err(format!("cannot overwrite '{}': {e}", target.display()));
    }
    Ok(backup)
}

/// Sidecar JSON path for an image's saved translation bubbles:
/// `<image_dir>/.kogaview/translation/<file_name>.json`.
pub(crate) fn translation_sidecar_path(image_path: &Path) -> Option<PathBuf> {
    let parent = image_path.parent()?;
    let name = image_path.file_name()?.to_str()?;
    if name.is_empty() {
        return None;
    }
    Some(
        parent
            .join(".kogaview")
            .join("translation")
            .join(format!("{name}.json")),
    )
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranslationSidecarFile {
    version: u32,
    image: String,
    #[serde(default)]
    blocks: Vec<kogaview_protocol::TranslationBlock>,
}

/// Load persisted translation bubbles for `image_path` if a valid sidecar exists.
pub(crate) fn load_saved_translation(
    image_path: &str,
) -> Option<kogaview_protocol::SavedTranslation> {
    let sidecar = translation_sidecar_path(Path::new(image_path))?;
    let raw = fs::read_to_string(&sidecar).ok()?;
    let parsed: TranslationSidecarFile = serde_json::from_str(&raw).ok()?;
    if parsed.blocks.is_empty() {
        return None;
    }
    Some(kogaview_protocol::SavedTranslation {
        path: image_path.to_owned(),
        blocks: parsed.blocks,
    })
}

fn remove_sidecar_and_prune(sidecar: &Path) -> Result<(), String> {
    if sidecar.exists() {
        fs::remove_file(sidecar)
            .map_err(|e| format!("cannot remove '{}': {e}", sidecar.display()))?;
    }
    if let Some(trans_dir) = sidecar.parent() {
        let _ = fs::remove_dir(trans_dir);
        if let Some(meta_dir) = trans_dir.parent() {
            let _ = fs::remove_dir(meta_dir);
        }
    }
    Ok(())
}

impl Core {
    /// Save Viewer translation bubbles to `<dir>/.kogaview/translation/<file>.json`.
    /// When `blocks` is empty, removes the sidecar file instead of keeping an empty file.
    pub(super) fn viewer_save_translation(
        &mut self,
        path: &str,
        blocks: Vec<kogaview_protocol::TranslationBlock>,
    ) -> Result<Option<UiText>, ProtocolError> {
        let img_path = Path::new(path);
        let Some(sidecar) = translation_sidecar_path(img_path) else {
            return Err(ProtocolError::with_line(
                "invalid_path",
                format!("cannot resolve translation sidecar path for '{path}'"),
                UiText::new("no_existing_paths"),
            ));
        };

        if blocks.is_empty() {
            remove_sidecar_and_prune(&sidecar).map_err(|msg| {
                ProtocolError::with_line("io_error", msg, UiText::new("ai_inference_failed"))
            })?;
            if self.state.viewer_path.as_deref() == Some(path) {
                self.state.viewer_saved_translation = None;
            }
            return Ok(None);
        }

        if let Some(dir) = sidecar.parent() {
            fs::create_dir_all(dir).map_err(|e| {
                ProtocolError::with_line(
                    "io_error",
                    format!(
                        "cannot create translation directory '{}': {e}",
                        dir.display()
                    ),
                    UiText::new("ai_inference_failed"),
                )
            })?;
        }

        let image_name = img_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_owned();
        let payload = TranslationSidecarFile {
            version: 1,
            image: image_name,
            blocks: blocks.clone(),
        };
        let bytes = serde_json::to_vec_pretty(&payload).map_err(|e| {
            ProtocolError::with_line(
                "serialize_error",
                format!("cannot serialize translation sidecar: {e}"),
                UiText::new("ai_inference_failed"),
            )
        })?;

        let tmp = sidecar.with_extension("json.tmp");
        fs::write(&tmp, &bytes).map_err(|e| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot write '{}': {e}", tmp.display()),
                UiText::new("ai_inference_failed"),
            )
        })?;
        if let Err(e) = fs::rename(&tmp, &sidecar) {
            let _ = fs::remove_file(&tmp);
            return Err(ProtocolError::with_line(
                "io_error",
                format!("cannot save '{}': {e}", sidecar.display()),
                UiText::new("ai_inference_failed"),
            ));
        }

        if self.state.viewer_path.as_deref() == Some(path) {
            self.state.viewer_saved_translation = Some(kogaview_protocol::SavedTranslation {
                path: path.to_owned(),
                blocks,
            });
        }
        Ok(None)
    }

    /// Delete `<dir>/.kogaview/translation/<file>.json` and clear saved state.
    pub(super) fn viewer_delete_translation(
        &mut self,
        path: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(sidecar) = translation_sidecar_path(Path::new(path)) else {
            return Err(ProtocolError::with_line(
                "invalid_path",
                format!("cannot resolve translation sidecar path for '{path}'"),
                UiText::new("no_existing_paths"),
            ));
        };
        remove_sidecar_and_prune(&sidecar).map_err(|msg| {
            ProtocolError::with_line("io_error", msg, UiText::new("ai_inference_failed"))
        })?;
        if self.state.viewer_path.as_deref() == Some(path) {
            self.state.viewer_saved_translation = None;
        }
        Ok(Some(UiText::new("ai_translation_deleted")))
    }

    /// Run Gemini Reverse Alpha Blending watermark removal on the open Editor
    /// document (non-destructive, pushes `EditOperation::AiResult`).
    pub(super) fn editor_dewatermark_gemini(
        &mut self,
        size: &str,
        logo_value: f32,
        force: bool,
        offset_x: i32,
        offset_y: i32,
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.run_editor_image_plugin(
            "editor.dewatermark_gemini",
            "Remove Gemini logo…",
            json!({
                "size": size,
                "logoValue": logo_value,
                "force": force,
                "offsetX": offset_x,
                "offsetY": offset_y,
            }),
            "Watermark Remover plugin is not installed (run: just build-plugin-dewatermark)",
            target,
        )
    }

    /// Run general rectangular watermark inpainting on the open Editor document
    /// (non-destructive, pushes `EditOperation::AiResult`).
    pub(super) fn editor_inpaint_region(
        &mut self,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        feather: u32,
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        let (_, ox, oy) = self.editor_ai_input(target)?;
        self.run_editor_image_plugin(
            "editor.inpaint_region",
            "Removing watermark region…",
            json!({
                "x": x - ox,
                "y": y - oy,
                "width": width,
                "height": height,
                "feather": feather,
            }),
            "Watermark Remover plugin is not installed (run: just build-plugin-dewatermark)",
            target,
        )
    }

    /// Run AI Watermark Detector (YOLO26/YOLO11) + Inpainter (MI-GAN/LaMa) on
    /// the open Editor document (non-destructive, pushes `EditOperation::AiResult`).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn editor_ai_inpaint(
        &mut self,
        detector_model: &str,
        inpainter_model: &str,
        confidence: f32,
        mask_padding: u32,
        region_x: i32,
        region_y: i32,
        region_width: i32,
        region_height: i32,
        brush_strokes: &[kogaview_protocol::AiMaskStroke],
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        let (_, ox, oy) = self.editor_ai_input(target)?;
        let local_strokes: Vec<kogaview_protocol::AiMaskStroke> = if ox == 0 && oy == 0 {
            brush_strokes.to_vec()
        } else {
            brush_strokes
                .iter()
                .map(|s| kogaview_protocol::AiMaskStroke {
                    radius: s.radius,
                    points: s
                        .points
                        .iter()
                        .map(|[px, py]| [px - ox as f32, py - oy as f32])
                        .collect(),
                })
                .collect()
        };
        let models_dir = self.paths.models_dir.display().to_string();
        self.run_editor_image_plugin(
            "editor.ai_inpaint",
            "Detecting & removing watermark (AI)…",
            json!({
                "modelsDir": models_dir,
                "detectorModel": detector_model,
                "inpainterModel": inpainter_model,
                "confidence": confidence,
                "maskPadding": mask_padding,
                "regionX": region_x - ox,
                "regionY": region_y - oy,
                "regionWidth": region_width,
                "regionHeight": region_height,
                "brushStrokes": local_strokes,
            }),
            "AI Watermark Remover plugin is not installed (run: just build-plugin-ai-inpaint)",
            target,
        )
    }

    /// Refine alpha transparency on the active layer of the open Editor document:
    /// - `erase_strokes`: smoothly lowers alpha toward 0 (removes leftover BG)
    /// - `restore_strokes`: blends pixels back from `doc.active_layer_original_pixels()`
    ///   (restores foreground accidentally cut by AI Remove Background)
    pub(super) fn editor_refine_alpha(
        &mut self,
        erase_strokes: &[kogaview_protocol::AiMaskStroke],
        restore_strokes: &[kogaview_protocol::AiMaskStroke],
        softness: f32,
    ) -> Result<Option<UiText>, ProtocolError> {
        if erase_strokes.is_empty() && restore_strokes.is_empty() {
            return Ok(None);
        }
        let (working, original, ox, oy) = {
            let doc = self.editor.as_ref().ok_or_else(no_editor_document)?;
            let active = doc.active_layer();
            if active.locked {
                return Err(ProtocolError::line(
                    "invalid_edit",
                    UiText::new("layer_locked"),
                ));
            }
            if !active.visible {
                return Err(ProtocolError::line(
                    "invalid_edit",
                    UiText::new("layer_hidden"),
                ));
            }
            (
                Arc::clone(&active.pixels),
                doc.active_layer_original_pixels(),
                active.offset_x as f32,
                active.offset_y as f32,
            )
        };
        let (w, h) = working.dimensions();
        let softness = softness.clamp(0.0, 1.0);
        let mut out = (*working).clone();

        let stamp_strokes = |strokes: &[kogaview_protocol::AiMaskStroke]| -> Vec<f32> {
            let mut map = vec![0.0f32; (w as usize) * (h as usize)];
            for stroke in strokes {
                let r = stroke.radius.clamp(2.0, 240.0);
                let inner = r * (1.0 - softness);
                let mut stamp_disk = |cx: f32, cy: f32| {
                    let x0 = ((cx - r).floor() as i32).clamp(0, w as i32 - 1);
                    let y0 = ((cy - r).floor() as i32).clamp(0, h as i32 - 1);
                    let x1 = ((cx + r).ceil() as i32).clamp(0, w as i32 - 1);
                    let y1 = ((cy + r).ceil() as i32).clamp(0, h as i32 - 1);
                    for y in y0..=y1 {
                        let dy = y as f32 - cy;
                        let row = (y as usize) * (w as usize);
                        for x in x0..=x1 {
                            let dx = x as f32 - cx;
                            let d = dx.hypot(dy);
                            if d > r {
                                continue;
                            }
                            let weight = if d <= inner || r <= inner + 1e-4 {
                                1.0
                            } else {
                                let t = ((r - d) / (r - inner)).clamp(0.0, 1.0);
                                t * t * (3.0 - 2.0 * t)
                            };
                            let idx = row + x as usize;
                            if weight > map[idx] {
                                map[idx] = weight;
                            }
                        }
                    }
                };
                if stroke.points.len() == 1 {
                    stamp_disk(stroke.points[0][0] - ox, stroke.points[0][1] - oy);
                } else {
                    for win in stroke.points.windows(2) {
                        let (x0, y0) = (win[0][0] - ox, win[0][1] - oy);
                        let (x1, y1) = (win[1][0] - ox, win[1][1] - oy);
                        let dist = (x1 - x0).hypot(y1 - y0).max(1.0);
                        let step = (r * 0.30).max(1.5);
                        let steps = (dist / step).ceil() as usize;
                        for i in 0..=steps {
                            let t = i as f32 / steps.max(1) as f32;
                            stamp_disk(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t);
                        }
                    }
                }
            }
            map
        };

        if !restore_strokes.is_empty() {
            let restore_map = stamp_strokes(restore_strokes);
            let (ow, oh) = original.dimensions();
            for y in 0..h {
                let row = (y as usize) * (w as usize);
                let sy = if oh == h {
                    y
                } else {
                    ((y as u64 * oh as u64) / h.max(1) as u64).min(oh.saturating_sub(1) as u64)
                        as u32
                };
                for x in 0..w {
                    let alpha_w = restore_map[row + x as usize];
                    if alpha_w <= 0.001 {
                        continue;
                    }
                    let sx = if ow == w {
                        x
                    } else {
                        ((x as u64 * ow as u64) / w.max(1) as u64).min(ow.saturating_sub(1) as u64)
                            as u32
                    };
                    let cur = out.get_pixel(x, y);
                    let src = original.get_pixel(sx, sy);
                    let inv = 1.0 - alpha_w;
                    let r = (cur[0] as f32 * inv + src[0] as f32 * alpha_w).round() as u8;
                    let g = (cur[1] as f32 * inv + src[1] as f32 * alpha_w).round() as u8;
                    let b = (cur[2] as f32 * inv + src[2] as f32 * alpha_w).round() as u8;
                    let a = (cur[3] as f32 * inv + src[3] as f32 * alpha_w).round() as u8;
                    out.put_pixel(x, y, image::Rgba([r, g, b, a]));
                }
            }
        }

        if !erase_strokes.is_empty() {
            let erase_map = stamp_strokes(erase_strokes);
            for y in 0..h {
                let row = (y as usize) * (w as usize);
                for x in 0..w {
                    let ew = erase_map[row + x as usize];
                    if ew <= 0.001 {
                        continue;
                    }
                    let cur = out.get_pixel(x, y);
                    let new_a = ((cur[3] as f32) * (1.0 - ew)).round().clamp(0.0, 255.0) as u8;
                    out.put_pixel(x, y, image::Rgba([cur[0], cur[1], cur[2], new_a]));
                }
            }
        }

        let op = EditOperation::AiResult {
            label: UiText::new("refine_alpha_mask"),
            pixels: Arc::new(out),
        };
        self.editor_apply_with_target(op, ApplyTarget::ActiveLayer)?;
        self.state.status = UiText::new("ai_mask_refined");
        Ok(Some(UiText::new("ai_mask_refined")))
    }

    /// Shared helper to run an image-output plugin on the open Editor document
    /// non-destructively (renders active layer or composited image -> temp PNG -> plugin -> `AiResult`).
    fn run_editor_image_plugin(
        &mut self,
        action: &str,
        stage_label: &str,
        params: serde_json::Value,
        missing_msg: &str,
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let (pixels, _, _) = self.editor_ai_input(target)?;

        self.refresh_ai_inventory();
        let Some(plugin) = self
            .ai_plugins
            .iter()
            .find(|p| p.available && p.manifest.capabilities.iter().any(|c| c.action == action))
            .cloned()
        else {
            return Err(ProtocolError::with_line(
                "plugin_missing",
                missing_msg,
                UiText::new("ai_inference_failed"),
            ));
        };

        fs::create_dir_all(&self.paths.ai_ipc_dir).map_err(|error| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot create ai-ipc directory: {error}"),
                UiText::new("ai_inference_failed"),
            )
        })?;
        self.ai_generation += 1;
        let gen = self.ai_generation;
        let tmp_in = self.paths.ai_ipc_dir.join(format!("wm-in-{gen}.png"));
        let tmp_out = self.paths.ai_ipc_dir.join(format!("wm-out-{gen}.png"));
        let _ = fs::remove_file(&tmp_out);
        pixels.save(&tmp_in).map_err(|error| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot write plugin input PNG: {error}"),
                UiText::new("ai_inference_failed"),
            )
        })?;

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_rx = Some(rx);
        self.ai_cancel = Some(Arc::clone(&cancel));
        self.ai_temp_input = Some(tmp_in.clone());
        self.ai_temp_output = Some(tmp_out.clone());
        self.ai_quick_action_output = None;
        self.ai_apply_target = target;
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "inference".to_owned(),
            target: action.to_owned(),
            running: true,
            percent: 10,
            stage: stage_label.to_owned(),
            error: None,
            clipboard_text: None,
            translation: None,
            caption_text: None,
        });
        self.state.status = UiText::new("ai_removing_watermark");

        let device = self.config.ai.device;
        let action_owned = action.to_owned();
        std::thread::spawn(move || {
            let empty_model = PathBuf::new();
            plugins::run_plugin_inference(
                &plugin,
                &action_owned,
                "",
                &empty_model,
                device,
                &tmp_in,
                &tmp_out,
                params,
                cancel,
                &tx,
            );
        });
        Ok(Some(UiText::new("ai_removing_watermark")))
    }

    /// Generate AI tags/caption for the open Editor image via `kogaview-plugin-caption`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn editor_generate_caption(
        &mut self,
        model_id: &str,
        general_threshold: f32,
        character_threshold: f32,
        replace_underscores: bool,
        prefix: &str,
        suffix: &str,
        exclude_tags: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let Some(doc) = self.editor.as_ref() else {
            return Err(ProtocolError::with_line(
                "no_document",
                "no image is open in the Editor",
                UiText::new("ai_inference_failed"),
            ));
        };
        let src_path = doc.source_path().to_path_buf();

        self.refresh_ai_inventory();
        let Some(plugin) = self
            .ai_plugins
            .iter()
            .find(|p| {
                p.available
                    && p.manifest
                        .capabilities
                        .iter()
                        .any(|c| c.action == "editor.caption")
            })
            .cloned()
        else {
            return Err(ProtocolError::with_line(
                "plugin_missing",
                "AI Caption plugin is not installed (run: just build-plugin-caption)",
                UiText::new("ai_inference_failed"),
            ));
        };

        let model_path = self
            .state
            .ai_models
            .iter()
            .find(|m| m.id == model_id)
            .and_then(|m| m.effective_path.as_ref())
            .map(PathBuf::from)
            .unwrap_or_default();

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_rx = Some(rx);
        self.ai_cancel = Some(Arc::clone(&cancel));
        self.ai_temp_input = None;
        self.ai_temp_output = None;
        self.ai_quick_action_output = None;
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "caption".to_owned(),
            target: model_id.to_owned(),
            running: true,
            percent: 10,
            stage: "Generating caption…".to_owned(),
            error: None,
            clipboard_text: None,
            translation: None,
            caption_text: None,
        });
        self.state.status = UiText::new("ai_caption_running");

        let device = self.config.ai.device;
        let models_dir = self.paths.models_dir.display().to_string();
        let model_id_owned = model_id.to_owned();
        let params = json!({
            "modelId": model_id,
            "modelsDir": models_dir,
            "generalThreshold": general_threshold,
            "characterThreshold": character_threshold,
            "replaceUnderscores": replace_underscores,
            "prefix": prefix,
            "suffix": suffix,
            "excludeTags": exclude_tags,
        });

        std::thread::spawn(move || {
            let empty_out = PathBuf::new();
            plugins::run_plugin_inference(
                &plugin,
                "editor.caption",
                &model_id_owned,
                &model_path,
                device,
                &src_path,
                &empty_out,
                params,
                cancel,
                &tx,
            );
        });
        Ok(Some(UiText::new("ai_caption_running")))
    }

    /// Save (or remove if empty) `<image_stem>.txt` beside the open Editor image.
    pub(super) fn editor_save_caption(
        &mut self,
        text: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(doc) = self.editor.as_ref() else {
            return Err(ProtocolError::with_line(
                "no_document",
                "no image is open in the Editor",
                UiText::new("ai_inference_failed"),
            ));
        };
        let txt_path = doc.source_path().with_extension("txt");
        let trimmed = text.trim();
        if trimmed.is_empty() {
            if txt_path.exists() {
                fs::remove_file(&txt_path).map_err(|e| {
                    ProtocolError::with_line(
                        "io_error",
                        format!("cannot remove '{}': {e}", txt_path.display()),
                        UiText::new("ai_inference_failed"),
                    )
                })?;
            }
            self.state.editor_caption = None;
            return Ok(Some(UiText::new("ai_caption_deleted")));
        }

        let tmp = txt_path.with_extension("txt.tmp");
        fs::write(&tmp, trimmed.as_bytes()).map_err(|e| {
            ProtocolError::with_line(
                "io_error",
                format!("cannot write '{}': {e}", tmp.display()),
                UiText::new("ai_inference_failed"),
            )
        })?;
        fs::rename(&tmp, &txt_path).map_err(|e| {
            let _ = fs::remove_file(&tmp);
            ProtocolError::with_line(
                "io_error",
                format!("cannot save '{}': {e}", txt_path.display()),
                UiText::new("ai_inference_failed"),
            )
        })?;
        self.state.editor_caption = Some(trimmed.to_owned());
        Ok(Some(UiText::new("ai_caption_saved")))
    }
}

/// Load `<image_stem>.txt` if it exists beside `image_path`.
pub(crate) fn load_caption_for_image(image_path: &Path) -> Option<String> {
    let txt_path = image_path.with_extension("txt");
    let content = fs::read_to_string(txt_path).ok()?;
    let trimmed = content.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_translation_roundtrips_and_deletes_cleanly() {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-translation-sidecar-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let img = dir.join("page01.png");
        fs::write(&img, b"fake").unwrap();
        let img_str = img.to_string_lossy().into_owned();

        let sidecar = translation_sidecar_path(&img).unwrap();
        assert_eq!(sidecar, dir.join(".kogaview/translation/page01.png.json"));
        assert!(load_saved_translation(&img_str).is_none());

        fs::create_dir_all(sidecar.parent().unwrap()).unwrap();
        let payload = TranslationSidecarFile {
            version: 1,
            image: "page01.png".to_owned(),
            blocks: vec![kogaview_protocol::TranslationBlock {
                x: 10,
                y: 20,
                w: 100,
                h: 50,
                original: "こんにちは".to_owned(),
                translated: "Xin chào".to_owned(),
            }],
        };
        fs::write(&sidecar, serde_json::to_vec_pretty(&payload).unwrap()).unwrap();

        let loaded = load_saved_translation(&img_str).expect("should load saved sidecar");
        assert_eq!(loaded.path, img_str);
        assert_eq!(loaded.blocks.len(), 1);
        assert_eq!(loaded.blocks[0].translated, "Xin chào");

        remove_sidecar_and_prune(&sidecar).unwrap();
        assert!(!sidecar.exists());
        assert!(!dir.join(".kogaview").exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn backup_paths_append_tilde_and_increment_number() {
        let dir =
            std::env::temp_dir().join(format!("kogaview-qa-backup-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let src = dir.join("photo.png");
        let res = dir.join("result.png");
        fs::write(&src, b"original-v1").unwrap();
        fs::write(&res, b"edited-v2").unwrap();

        let b1 = backup_and_overwrite(&src, &res).unwrap();
        assert_eq!(b1, dir.join("photo.png~"));
        assert_eq!(fs::read(&b1).unwrap(), b"original-v1");
        assert_eq!(fs::read(&src).unwrap(), b"edited-v2");

        fs::write(&res, b"edited-v3").unwrap();
        let b2 = backup_and_overwrite(&src, &res).unwrap();
        assert_eq!(b2, dir.join("photo.png.2~"));
        assert_eq!(fs::read(&b2).unwrap(), b"edited-v2");
        assert_eq!(fs::read(&src).unwrap(), b"edited-v3");

        fs::write(&res, b"edited-v4").unwrap();
        let b3 = backup_and_overwrite(&src, &res).unwrap();
        assert_eq!(b3, dir.join("photo.png.3~"));
        assert_eq!(fs::read(&b3).unwrap(), b"edited-v3");
        assert_eq!(fs::read(&src).unwrap(), b"edited-v4");

        let _ = fs::remove_dir_all(&dir);
    }
}
