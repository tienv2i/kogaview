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

    pub(super) fn editor_ai_remove_background(
        &mut self,
        model_id: &str,
        feather: u8,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.ai_rx.is_some() {
            return Err(ProtocolError::with_line(
                "busy",
                "an AI task is already running",
                UiText::new("ai_task_busy"),
            ));
        }
        let pixels = self
            .editor
            .as_ref()
            .ok_or_else(no_editor_document)?
            .pixels();

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
        self.state.busy = true;
        self.state.ai_task = Some(AiTaskState {
            kind: "inference".to_owned(),
            target: model_id.to_owned(),
            running: true,
            percent: 5,
            stage: "Starting Remove Background…".to_owned(),
            error: None,
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
            .unwrap_or("rmbg-1.4")
            .to_owned();
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
        });
        self.state.status = UiText::new("ai_removing_background");

        let device = self.config.ai.device;
        let model_path = PathBuf::from(model_path_str);
        let action_name = qa.action.clone();
        let params = qa.params.clone();

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
                } => {
                    finished = true;
                    if let Some(target_path) = self.ai_quick_action_output.take() {
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
                        match image::open(&output_path).map(|img| img.into_rgba8()) {
                            Ok(rgba) => {
                                let label = UiText::with("remove_background", [model_id]);
                                let op = EditOperation::AiResult {
                                    label,
                                    pixels: Arc::new(rgba),
                                };
                                match self.editor_apply(op) {
                                    Ok(_) => {
                                        if let Some(task) = self.state.ai_task.as_mut() {
                                            task.running = false;
                                            task.percent = 100;
                                            task.stage = format!("Done ({device_used})");
                                            task.error = None;
                                        }
                                        self.state.status =
                                            UiText::new("ai_remove_background_done");
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

#[cfg(test)]
mod tests {
    use super::*;

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
