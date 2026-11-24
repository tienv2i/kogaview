//! The Editor's commands: opening a document, applying and previewing an
//! operation, saving, exporting, and the worker messages that answer them.
//!
//! The pixels live in `kogaview-editor`; this module owns the document's place
//! in Core — its save target, its preview cache, its open/closed lifecycle and
//! the rule that a second open cannot replace unsaved work.
use super::*;
use crate::state::LayerSummary;

impl Core {
    /// Load a source image into the Editor as a working document.
    ///
    /// The file is only read. Decoding and the first preview run on a worker
    /// thread, so a large photo does not stall the window; the UI publishes a
    /// spinner and the name until `apply_editor_task` installs the document.
    pub(super) fn open_editor(&mut self, path: &str) -> Result<Option<UiText>, ProtocolError> {
        let source = ops::normalize_path(Path::new(path));
        if !source.is_file() {
            return Err(ProtocolError::line(
                "not_found",
                UiText::with("not_a_file", [source.display().to_string()]),
            ));
        }
        if !ops::is_image_path(&source) {
            return Err(ProtocolError::line(
                "not_an_image",
                UiText::with("not_an_image", [source.display().to_string()]),
            ));
        }
        let path_label = source.to_string_lossy().into_owned();
        let name = source
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path_label.clone());
        // Refuse before a worker is spawned: otherwise the reply says `ok` and
        // the failure arrives later as the platform's own English sentence. The
        // check builds the real decoder, so HEIC (listed, no decoder) and this
        // build's AVIF are both answered with a line the window can translate.
        if !editor::has_decoder(&source) {
            return Err(ProtocolError::line(
                "no_decoder",
                UiText::with("no_decoder", [path_label.clone()]),
            ));
        }
        let preview_dir = self.editor_preview_dir()?;

        // Reopening what is already open is not a new document. Before this
        // check every `editor_open` — the Viewer's picture switching into the
        // Editor a second time, the Editor's own Open pointed at the same file
        // — tore the document down, deleted its preview, asked the worker to
        // decode the same bytes again and dropped the undo history. The user
        // saw the canvas blink and lost their steps for asking to see the same
        // picture.
        if let Some(document) = self.editor.as_ref() {
            if ops::normalize_path(document.save_target().0) == source {
                // Unsaved edits win over "reload": the file on disk is not
                // what the window is showing, and an Open that quietly threw
                // the edits away would be data loss with no question asked.
                if document.has_unsaved_changes() {
                    return Ok(Some(UiText::new("editor_already_open")));
                }
                // A clean document whose file was rewritten by another program
                // *is* stale, so it falls through and decodes again; the same
                // file unchanged keeps the history and the current preview.
                if !document.source_changed() {
                    self.state.workspace = Workspace::Editor;
                    self.set_selection(vec![path_label.clone()]);
                    self.state.status = UiText::new("editor_already_open");
                    return Ok(Some(UiText::new("editor_already_open")));
                }
            } else if document.has_unsaved_changes() {
                // A different picture must not replace unsaved work without an
                // answer. The shell asks first and sends `editor_reset` when
                // the user discards; a CLI or IPC caller gets this refusal
                // instead of silent loss.
                return Err(ProtocolError::line(
                    "unsaved_document",
                    UiText::with("unsaved_document", [path_label.clone()]),
                ));
            }
        }

        self.editor_generation += 1;
        let generation = self.editor_generation;
        let preview = preview_dir.join(format!("preview-{generation}.png"));

        // A new document reuses the workspace: drop the old pixels and preview,
        // and let an in-flight result for the old generation be discarded on
        // arrival.
        if let Some(previous) = self.editor_preview_path.take() {
            let _ = std::fs::remove_file(previous);
        }
        self.editor_preview_stamp = None;
        self.clear_editor_draft();
        self.editor = None;
        self.editor_rendering = true;
        self.state.workspace = Workspace::Editor;
        self.set_selection(vec![path_label.clone()]);
        self.state.busy = true;
        let opening = UiText::with("opening_in_editor", [name.clone()]);
        self.state.status = opening.clone();
        let (file_modified, file_size) = file_identity(&source);
        self.state.editor = Some(EditorState {
            save_path: path_label.clone(),
            path: path_label,
            name,
            width: 0,
            height: 0,
            can_undo: false,
            can_redo: false,
            modified: false,
            history: Vec::new(),
            redo_history: Vec::new(),
            redo_count: 0,
            layers: Vec::new(),
            active_layer_id: 0,
            canvas_background: None,
            has_selection: false,
            selection_bounds: None,
            selection_overlay_path: None,
            selection_revision: 0,
            clipboard_export_path: None,
            clipboard_export_revision: 0,
            active_layer_preview_path: None,
            below_active_preview_path: None,
            above_active_preview_path: None,
            layer_preview_revision: 0,
            ram_canvas_revision: 0,
            ram_layer_revision: 0,
            ram_selection_revision: 0,
            preview_path: None,
            preview_revision: generation,
            preview_modified: 0,
            preview_size: 0,
            file_modified,
            file_size,
            preview_draft: None,
            rendering: true,
            saved: true,
            format: save_format_label(&source),
            saving: false,
            // Width stays 0 until the header is read, so `hasDocument` is
            // false: the placeholder, not a canvas, until the first decode.
            opening: false,
        });
        editor::spawn_open(source, generation, preview, self.editor_tx.clone());
        Ok(Some(opening))
    }

    /// Create a brand-new blank canvas in memory without touching disk.
    pub(super) fn editor_new(
        &mut self,
        width: u32,
        height: u32,
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
        name: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return Err(ProtocolError::line(
                "invalid_edit",
                UiText::with(
                    "invalid_dimensions",
                    [width.to_string(), height.to_string()],
                ),
            ));
        }
        if u64::from(width) * u64::from(height) > editor::MAX_DOCUMENT_PIXELS {
            return Err(ProtocolError::line(
                "invalid_edit",
                UiText::with(
                    "invalid_dimensions",
                    [width.to_string(), height.to_string()],
                ),
            ));
        }
        let doc_name = if name.trim().is_empty() {
            "Untitled.png".to_owned()
        } else {
            name.trim().to_owned()
        };
        if let Some(document) = self.editor.as_ref() {
            if document.has_unsaved_changes() {
                return Err(ProtocolError::line(
                    "unsaved_document",
                    UiText::with("unsaved_document", [doc_name]),
                ));
            }
        }
        let [r, g, b] = fill.unwrap_or([0, 0, 0]);
        let alpha = if fill.is_none() && fill_alpha == 0 {
            0
        } else {
            fill_alpha
        };
        let blank = Arc::new(image::RgbaImage::from_pixel(
            width,
            height,
            image::Rgba([0, 0, 0, 0]),
        ));
        let mut stack = editor::LayerStack::from_single(blank);
        stack.layers[0].name = "Layer 1".to_owned();
        stack.background = if alpha == 0 { None } else { Some([r, g, b]) };
        self.install_in_memory_stack(stack, &doc_name)?;
        Ok(Some(UiText::with(
            "editor_created",
            [width.to_string(), height.to_string()],
        )))
    }

    /// Paste an image file (e.g. from the system clipboard) as a new centered
    /// layer in the open document, or create a new document when Editor is empty.
    pub(super) fn editor_paste_image(
        &mut self,
        path: &str,
        name: &str,
        mode: kogaview_protocol::PasteMode,
    ) -> Result<Option<UiText>, ProtocolError> {
        let source = ops::normalize_path(Path::new(path));
        if !source.is_file() {
            return Err(ProtocolError::line(
                "not_found",
                UiText::with("not_a_file", [source.display().to_string()]),
            ));
        }
        let decoded = editor::decode_rgba(&source).map_err(|msg| {
            ProtocolError::with_line(
                "decode_error",
                msg,
                UiText::with("no_decoder", [source.display().to_string()]),
            )
        })?;
        // Clean up temporary clipboard PNG written by PlatformHelper.
        if source
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("kogaview-clipboard-"))
        {
            let _ = std::fs::remove_file(&source);
        }

        if let Some(document) = self.editor.as_mut() {
            let layer_name = if name.trim().is_empty() {
                "Pasted Layer".to_owned()
            } else {
                name.trim().to_owned()
            };
            document
                .paste_image_with_mode(layer_name, decoded, mode)
                .map_err(invalid_edit)?;
            self.clear_editor_draft();
            self.schedule_editor_preview();
            self.refresh_editor_status();
            Ok(Some(UiText::new("layer_pasted")))
        } else {
            let (w, h) = decoded.dimensions();
            let doc_name = if name.trim().is_empty() {
                "Clipboard.png".to_owned()
            } else {
                name.trim().to_owned()
            };
            self.install_in_memory_document(decoded, &doc_name)?;
            Ok(Some(UiText::with(
                "editor_created",
                [w.to_string(), h.to_string()],
            )))
        }
    }

    fn install_in_memory_document(
        &mut self,
        image: image::RgbaImage,
        doc_name: &str,
    ) -> Result<(), ProtocolError> {
        let stack = editor::LayerStack::from_single(Arc::new(image));
        self.install_in_memory_stack(stack, doc_name)
    }

    fn install_in_memory_stack(
        &mut self,
        stack: editor::LayerStack,
        doc_name: &str,
    ) -> Result<(), ProtocolError> {
        let base_dir = self
            .state
            .current_folder
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
            .unwrap_or_else(|| PathBuf::from("."));
        let virtual_path = base_dir.join(doc_name);
        let mut document = EditorDocument::from_stack(virtual_path, stack);
        document.mark_unsaved();

        if let Some(previous) = self.editor_preview_path.take() {
            let _ = std::fs::remove_file(previous);
        }
        self.editor_preview_stamp = None;
        self.clear_editor_draft();
        self.editor = Some(document);
        self.state.workspace = Workspace::Editor;
        self.state.editor_caption = None;
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(())
    }

    /// Publish an ephemeral in-RAM preview for a filter popup (Color & light or
    /// Curves) without mutating the document or recording an undo step.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn editor_preview_filter(
        &mut self,
        clear: bool,
        kind: &str,
        brightness: f64,
        contrast: f64,
        hue: f64,
        saturation: f64,
        value: f64,
        shadows: [f64; 3],
        midtones: [f64; 3],
        highlights: [f64; 3],
        preserve_luminosity: bool,
        rgb: Vec<[f64; 2]>,
        red: Vec<[f64; 2]>,
        green: Vec<[f64; 2]>,
        blue: Vec<[f64; 2]>,
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &self.editor else {
            return Err(no_editor_document());
        };
        if clear {
            crate::ram_preview::set_canvas(document.pixels());
            self.editor_ram_canvas_revision += 1;
            self.publish_editor();
            return Ok(None);
        }
        let op = match kind {
            "hsv" => EditOperation::AdjustHsv {
                hue,
                saturation,
                value,
            },
            "color_balance" => EditOperation::ColorBalance {
                shadows,
                midtones,
                highlights,
                preserve_luminosity,
            },
            "curves" => EditOperation::AdjustCurves {
                rgb,
                red,
                green,
                blue,
            },
            _ if !rgb.is_empty() || !red.is_empty() || !green.is_empty() || !blue.is_empty() => {
                EditOperation::AdjustCurves {
                    rgb,
                    red,
                    green,
                    blue,
                }
            }
            _ => EditOperation::AdjustColor {
                brightness,
                contrast,
                saturation,
            },
        };
        let preview = document.preview_color_filter(&op, target);
        crate::ram_preview::set_canvas(Arc::new(preview));
        self.editor_ram_canvas_revision += 1;
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_apply(
        &mut self,
        operation: EditOperation,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.editor_apply_with_target(operation, ApplyTarget::WholeImage)
    }

    pub(super) fn editor_apply_with_target(
        &mut self,
        operation: EditOperation,
        target: ApplyTarget,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let had_selection = document.selection().is_some();
        let changed = document
            .apply_with_target(operation.clone(), target)
            .map_err(invalid_edit)?;
        if !changed {
            return Ok(Some(UiText::new("edit_noop")));
        }
        // Only clear the selection overlay here if the edit dropped the selection;
        // when a selection remains active, `schedule_editor_preview()` refreshes it once.
        if had_selection && document.selection().is_none() {
            self.refresh_selection_overlay();
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        // The same line the History panel records, so the toast and the history
        // cannot word one operation two ways.
        Ok(Some(operation.label()))
    }

    /// Jump directly to `target_index` in the Undo/Redo history stack (`0` = original).
    pub(super) fn editor_history_jump(
        &mut self,
        target_index: usize,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        if !document.jump_history(target_index) {
            return Ok(None);
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(UiText::new("history_jumped")))
    }

    /// Select the active layer without recording an undo step.
    pub(super) fn editor_layer_select(&mut self, id: u64) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        document.select_layer(id).map_err(invalid_edit)?;
        self.refresh_layer_split_previews();
        self.publish_editor();
        Ok(None)
    }

    /// Publish downscaled `(below, active, above)` RGBA frames into RAM for
    /// both single-layer and multi-layer documents so live Transform previews
    /// always render the active layer's own bounds cleanly with zero disk I/O.
    pub(super) fn refresh_layer_split_previews(&mut self) {
        for slot in [
            &mut self.editor_active_layer_preview_path,
            &mut self.editor_below_active_preview_path,
            &mut self.editor_above_active_preview_path,
        ] {
            if let Some(old) = slot.take() {
                let _ = std::fs::remove_file(old);
            }
        }
        let Some(document) = &self.editor else {
            crate::ram_preview::clear_split_layers();
            self.editor_ram_layer_revision = 0;
            return;
        };
        let (below, active, above) = document.active_layer_split_previews();
        crate::ram_preview::set_split_layers(below, active, above);
        self.editor_ram_layer_revision += 1;
        self.editor_layer_preview_revision = self.editor_ram_layer_revision;
    }

    /// Apply a structural or property [`editor::LayerOperation`] (recorded in Undo/Redo).
    pub(super) fn editor_layer_op(
        &mut self,
        op: editor::LayerOperation,
    ) -> Result<Option<UiText>, ProtocolError> {
        let label = op.label();
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let changed = document.apply_layer_op(op).map_err(invalid_edit)?;
        if !changed {
            return Ok(None);
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(label))
    }

    pub(super) fn refresh_selection_overlay(&mut self) {
        if let Some(old) = self.editor_selection_overlay_path.take() {
            let _ = std::fs::remove_file(old);
        }
        let Some(document) = &self.editor else {
            crate::ram_preview::clear_selection();
            self.editor_ram_selection_revision = 0;
            return;
        };
        let Some(mask) = document.selection() else {
            crate::ram_preview::clear_selection();
            self.editor_ram_selection_revision = 0;
            return;
        };
        let ants0 = mask.render_overlay_image_phase(false);
        let ants1 = mask.render_overlay_image_phase(true);
        let red_mask = mask.render_red_overlay_image();
        crate::ram_preview::set_selection_visuals(ants0, ants1, red_mask);
        crate::ram_preview::set_selection_mask(mask.render_mask_image());
        if let Some((sel_base, sel_float)) = document.selection_split_previews() {
            crate::ram_preview::set_selection_split(sel_base, sel_float);
        }
        self.editor_ram_selection_revision += 1;
        self.editor_selection_revision = self.editor_ram_selection_revision;
    }

    pub(super) fn editor_select_rect(
        &mut self,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        mode: kogaview_protocol::SelectionMode,
        feather: u32,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let (cw, ch) = document.dimensions();
        let mask = editor::SelectionMask::rect(cw, ch, x, y, width, height);
        document.apply_selection_mask(mask, mode, feather);
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_select_ellipse(
        &mut self,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        mode: kogaview_protocol::SelectionMode,
        feather: u32,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let (cw, ch) = document.dimensions();
        let mask = editor::SelectionMask::ellipse(cw, ch, x, y, width, height);
        document.apply_selection_mask(mask, mode, feather);
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_select_lasso(
        &mut self,
        points: &[[f64; 2]],
        mode: kogaview_protocol::SelectionMode,
        feather: u32,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let (cw, ch) = document.dimensions();
        let mask = editor::SelectionMask::polygon(cw, ch, points);
        document.apply_selection_mask(mask, mode, feather);
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn editor_select_magic_wand(
        &mut self,
        x: i32,
        y: i32,
        tolerance: u8,
        contiguous: bool,
        sample_all_layers: bool,
        mode: kogaview_protocol::SelectionMode,
        feather: u32,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        document.select_magic_wand(
            x,
            y,
            tolerance,
            contiguous,
            sample_all_layers,
            mode,
            feather,
        );
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_select_move(
        &mut self,
        dx: i32,
        dy: i32,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        if document.move_selection(dx, dy) {
            self.refresh_selection_overlay();
            self.publish_editor();
        }
        Ok(None)
    }

    pub(super) fn editor_selection_copy(
        &mut self,
        cut: bool,
    ) -> Result<Option<UiText>, ProtocolError> {
        let extracted = {
            let Some(document) = &self.editor else {
                return Err(no_editor_document());
            };
            document.extract_selection_image().map_err(invalid_edit)?
        };
        let dir = self.editor_preview_dir()?;
        self.editor_clipboard_export_revision += 1;
        let out_path = dir.join(format!(
            "clipboard-{}.png",
            self.editor_clipboard_export_revision
        ));
        extracted.save(&out_path).map_err(|error| {
            ProtocolError::with_line(
                "io_error",
                format!("could not write clipboard export: {error}"),
                UiText::new("edit_error"),
            )
        })?;
        if let Some(prev) = self.editor_clipboard_export_path.replace(out_path) {
            let _ = std::fs::remove_file(prev);
        }
        if cut {
            if let Some(document) = &mut self.editor {
                let changed = if document.selection().is_some() {
                    document.selection_delete().map_err(invalid_edit)?
                } else if document.layers().len() > 1 {
                    let active_id = document.active_layer_id();
                    document
                        .apply_layer_op(editor::LayerOperation::Delete { id: active_id })
                        .map_err(invalid_edit)?
                } else {
                    document.clear_active_layer().map_err(invalid_edit)?
                };
                if changed {
                    self.clear_editor_draft();
                    self.schedule_editor_preview();
                    self.refresh_editor_status();
                    return Ok(Some(UiText::new("selection_cut")));
                }
            }
        }
        self.publish_editor();
        Ok(Some(if cut {
            UiText::new("selection_cut")
        } else {
            UiText::new("selection_copied")
        }))
    }

    pub(super) fn editor_select_all(&mut self) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        document.select_all();
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_select_clear(&mut self) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        if !document.clear_selection() {
            return Ok(None);
        }
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_select_invert(&mut self) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        document.invert_selection();
        self.refresh_selection_overlay();
        self.publish_editor();
        Ok(None)
    }

    pub(super) fn editor_selection_delete(&mut self) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let changed = document.selection_delete().map_err(invalid_edit)?;
        if !changed {
            return Ok(None);
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(UiText::new("selection_delete")))
    }

    pub(super) fn editor_selection_fill(
        &mut self,
        color: [u8; 3],
        opacity: f32,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let changed = document
            .selection_fill(color, opacity)
            .map_err(invalid_edit)?;
        if !changed {
            return Ok(None);
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(UiText::new("selection_fill")))
    }

    pub(super) fn editor_selection_duplicate_layer(
        &mut self,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let changed = document.selection_duplicate_layer().map_err(invalid_edit)?;
        if !changed {
            return Ok(None);
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(UiText::new("selection_duplicated")))
    }

    pub(super) fn editor_selection_crop(&mut self) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let changed = document.selection_crop().map_err(invalid_edit)?;
        if !changed {
            return Ok(None);
        }
        self.refresh_selection_overlay();
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(UiText::new("selection_cropped")))
    }

    /// Render what an edit *would* produce, without applying it.
    ///
    /// The draft is a separate preview file and its own generation, so the
    /// canvas can show the result while the document, the history and the save
    /// target stay exactly as they were. Applying the matching operation
    /// afterwards is what records the step; dismissing the tool or applying
    /// anything else drops the draft file.
    pub(super) fn editor_preview(
        &mut self,
        operation: EditOperation,
        kind: PreviewKind,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &self.editor else {
            return Err(no_editor_document());
        };
        let (width, height) = match &operation {
            EditOperation::Resize { width, height, .. }
            | EditOperation::Crop { width, height, .. } => (*width, *height),
            // The frame does not move, so the draft is the document's size.
            EditOperation::Transform { .. } | EditOperation::FreeTransform { .. } => {
                document.dimensions()
            }
            _ => (0, 0),
        };
        let changes = document.would_change(&operation).map_err(invalid_edit)?;
        if !changes {
            self.clear_editor_draft();
            self.publish_editor();
            return Ok(Some(kind.noop()));
        }
        let pixels = document.pixels();
        let Ok(dir) = self.editor_preview_dir() else {
            return Ok(Some(UiText::new("preview_folder_failed")));
        };
        self.editor_draft_generation += 1;
        let generation = self.editor_draft_generation;
        let preview = dir.join(format!("draft-{generation}.png"));
        editor::spawn_draft(
            pixels,
            operation,
            generation,
            preview,
            self.editor_tx.clone(),
        );
        Ok(Some(kind.preview(width, height)))
    }

    pub(super) fn editor_resize_preview(
        &mut self,
        width: u32,
        height: u32,
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
        mode: Option<ResizeMode>,
        filter: ResizeFilter,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.editor_preview(
            EditOperation::Resize {
                width,
                height,
                fill,
                fill_alpha,
                mode: ResizeMode::for_payload(mode, fill),
                filter,
            },
            PreviewKind::Resize,
        )
    }

    pub(super) fn editor_crop_preview(
        &mut self,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.editor_preview(
            EditOperation::Crop {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            },
            PreviewKind::Crop,
        )
    }

    pub(super) fn editor_transform_preview(
        &mut self,
        corners: [[f64; 2]; 4],
    ) -> Result<Option<UiText>, ProtocolError> {
        self.editor_preview(EditOperation::Transform { corners }, PreviewKind::Transform)
    }

    /// Drop the live-preview draft: remove its file and make any worker result
    /// for it stale before the next state is published.
    pub(super) fn clear_editor_draft(&mut self) {
        self.editor_draft_generation += 1;
        self.editor_draft_size = (0, 0);
        self.editor_draft_kind.clear();
        if let Some(path) = self.editor_draft_path.take() {
            let _ = std::fs::remove_file(path);
        }
    }

    pub(super) fn editor_step(&mut self, undo: bool) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let moved = if undo {
            document.undo()
        } else {
            document.redo()
        };
        if !moved {
            return Ok(Some(if undo {
                UiText::new("nothing_to_undo")
            } else {
                UiText::new("nothing_to_redo")
            }));
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        // A literal per branch, not one code chosen by an expression: the
        // catalogue gate reads the codes out of the source, and a code built
        // inside `if`/`else` would be invisible to it.
        Ok(Some(if undo {
            UiText::new("undo")
        } else {
            UiText::new("redo")
        }))
    }

    pub(super) fn editor_reset(&mut self) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        if !document.reset() {
            return Ok(Some(UiText::new("nothing_to_reset")));
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        Ok(Some(UiText::new("reset_done")))
    }

    /// Write the working pixels to `path`, or to the document's own save path
    /// when `path` is `None` (the Save button).
    ///
    /// Overwriting the source is allowed — the user asked for it by pressing
    /// Save — but it is never implicit: the command is journaled like every
    /// other, the previous bytes are kept as `<name>.bak` beside the file, and
    /// Core refuses when the file changed on disk since it was opened, because
    /// writing would then silently discard whatever changed it. Encoding and
    /// writing run on a worker; the document keeps rendering its preview and
    /// `saved` flips only when the bytes are really there.
    pub(super) fn editor_save(
        &mut self,
        path: Option<&str>,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &self.editor else {
            return Err(no_editor_document());
        };
        // Only the initial decode is a real wait: the pixels being saved do
        // not exist until it finishes. A pending *preview* is just the picture
        // on screen lagging the pixels, and Core applies edits synchronously,
        // so the bytes written are always the current document.
        if self.editor.is_none()
            || self
                .state
                .editor
                .as_ref()
                .is_none_or(|editor| editor.width == 0)
        {
            return Err(ProtocolError::line(
                "busy",
                UiText::new("editor_still_opening"),
            ));
        }
        let destination = match path {
            Some(path) => ops::normalize_path(Path::new(path)),
            None => document.save_target().0.to_path_buf(),
        };
        if destination.is_dir() {
            return Err(ProtocolError::line(
                "invalid_path",
                UiText::with(
                    "destination_is_a_folder",
                    [destination.display().to_string()],
                ),
            ));
        }
        if editor::SaveFormat::from_path(&destination).is_none() {
            let line = UiText::with(
                "unsupported_save_format",
                [
                    destination.display().to_string(),
                    editor::SaveFormat::CHOICES.to_owned(),
                ],
            );
            return Err(ProtocolError::with_line(
                "unsupported_format",
                format!(
                    "cannot save as {}; use one of {}",
                    destination.display(),
                    editor::SaveFormat::CHOICES
                ),
                line,
            ));
        }
        // Only the source can have moved under us; another destination is the
        // user's own choice to replace.
        let source = document.source_path().to_path_buf();
        if destination == source && document.source_changed() {
            return Err(ProtocolError::line(
                "source_changed",
                UiText::with("source_changed_on_disk", [source.display().to_string()]),
            ));
        }
        let stack = document.stack().clone();
        let label = destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| destination.to_string_lossy().into_owned());

        // Encoding and writing happen on a worker: a 24 MP JPEG takes about
        // half a second to encode, which would be a visible freeze here. The
        // document stays open and `saved` only flips when the bytes exist.
        self.editor_save_generation += 1;
        let save = self.editor_save_generation;
        self.editor_saving = true;
        self.state.status = UiText::with("saving", [label.clone()]);
        self.publish_editor();
        let (sender, receiver) = mpsc::channel();
        let thread_source = source.clone();
        std::thread::spawn(move || {
            let result = editor::save_stack(&thread_source, &stack, &destination);
            let _ = sender.send(EditorSaveResult {
                save,
                destination,
                result,
            });
        });
        self.pending_save = Some(receiver);
        // `saving` travels in the snapshot, so the view's spinner and the
        // disabled buttons are Core's answer rather than a local guess. The
        // status line names the file; `Toast` would speak over it.
        self.publish_editor();
        self.state.bump();
        Ok(Some(UiText::with("saving", [label])))
    }

    /// Write a delivery copy of the working document.
    ///
    /// Nothing about the document moves: the save target stays where it was,
    /// `saved` keeps describing those pixels, and the history is untouched. The
    /// one thing this refuses is the document's own file — replacing that is
    /// `editor_save`, with its backup and its source check.
    pub(super) fn editor_export(
        &mut self,
        path: &str,
        quality: Option<u8>,
        metadata: bool,
        max_edge: Option<u32>,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &self.editor else {
            return Err(no_editor_document());
        };
        if document.dimensions().0 == 0 {
            return Err(ProtocolError::line(
                "busy",
                UiText::new("document_still_decoding"),
            ));
        }
        if self.editor_saving {
            return Err(ProtocolError::line("busy", UiText::new("write_in_flight")));
        }
        let destination = ops::normalize_path(&PathBuf::from(path));
        if destination == document.source_path() {
            return Err(ProtocolError::with_line(
                "invalid_destination",
                "exporting onto the open document would replace it; use Save",
                UiText::new("export_onto_document"),
            ));
        }
        if editor::SaveFormat::from_path(&destination).is_none() {
            let line = UiText::with(
                "unsupported_export_format",
                [
                    destination.display().to_string(),
                    editor::SaveFormat::CHOICES.to_owned(),
                ],
            );
            return Err(ProtocolError::with_line(
                "invalid_destination",
                format!(
                    "cannot export as {}; use one of {}",
                    destination.display(),
                    editor::SaveFormat::CHOICES
                ),
                line,
            ));
        }
        let label = destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| destination.to_string_lossy().into_owned());
        let source = document.source_path().to_path_buf();
        let pixels = document.pixels();
        self.editor_save_generation += 1;
        let save = self.editor_save_generation;
        self.editor_saving = true;
        // A zero or absent `max_edge` means "the document's own size": a
        // request for no change, not a request for a 0-pixel copy.
        let max_edge = max_edge.filter(|edge| *edge > 0);
        self.state.status = UiText::with("exporting", [label.clone()]);
        self.publish_editor();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result =
                editor::export_pixels(&source, &pixels, &destination, quality, metadata, max_edge);
            let _ = sender.send(EditorExportResult {
                save,
                destination,
                result,
            });
        });
        self.pending_export = Some(receiver);
        self.state.bump();
        Ok(Some(UiText::with("exporting", [label])))
    }

    /// Finish an export a worker completed.
    pub(super) fn apply_export_result(&mut self, result: EditorExportResult) -> bool {
        if result.save != self.editor_save_generation {
            return false;
        }
        self.editor_saving = false;
        let label = result
            .destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        match result.result {
            Ok(()) => {
                tracing::info!(
                    target: "kogaview::editor",
                    path = %result.destination.display(),
                    "editor export written"
                );
                self.state.status = UiText::with("exported", [label]);
            }
            Err(message) => {
                tracing::warn!(
                    target: "kogaview::editor",
                    path = %result.destination.display(),
                    %message,
                    "editor export failed"
                );
                self.state.status = UiText::with("export_error", [message]);
            }
        }
        self.publish_editor();
        true
    }

    /// Finish a write that a worker completed.
    pub(super) fn apply_save_result(&mut self, result: EditorSaveResult) -> bool {
        if result.save != self.editor_save_generation {
            return false;
        }
        self.editor_saving = false;
        let Some(document) = &mut self.editor else {
            return true;
        };
        match result.result {
            Ok(()) => {
                let label = result
                    .destination
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default();
                if document.mark_saved(result.destination.clone()).is_ok() {
                    // Core just wrote the source itself; that is not an
                    // outside change.
                    if result.destination == document.source_path().to_path_buf() {
                        document.remember_source();
                    }
                }
                self.state.status = UiText::with("saved", [label]);
            }
            Err(message) => {
                tracing::warn!(
                    target: "kogaview::editor",
                    path = %result.destination.display(),
                    %message,
                    "editor save failed"
                );
                self.state.status = UiText::with("save_error", [message]);
            }
        }
        self.publish_editor();
        true
    }

    /// Carrying the Viewer's photograph into the Editor. A switch from the
    /// Viewer is explicit about which picture is on screen, so the Editor
    /// follows it even when a different document is still open — opening
    /// another image in the Viewer and coming back must not resurrect the old
    /// one. A switch from anywhere else carries an image only into an empty
    /// Editor, because the document already open is the one the user chose.
    ///
    /// Unsaved edits are never replaced by a switch: the window's
    /// unsaved-changes guard owns that decision, and its Discard answer resets
    /// the document (making it saved) before the workspace changes.
    pub(super) fn link_viewer_into_editor(&mut self, from_viewer: bool) {
        let path = match self.state.viewer_path.clone() {
            Some(path) => path,
            // A freshly opened folder has no viewer path until the Viewer was
            // entered; the selection is what a switch from the Browser carries.
            None => match self.state.selection.first().cloned() {
                Some(path) if ops::is_image_path(Path::new(&path)) => path,
                _ => return,
            },
        };
        if let Some(editor) = &self.state.editor {
            let same = ops::normalize_path(Path::new(&editor.path))
                == ops::normalize_path(Path::new(&path));
            if same || !from_viewer {
                return;
            }
        }
        if self
            .editor
            .as_ref()
            .is_some_and(|document| !document.save_target().1)
        {
            return;
        }
        if !editor::has_decoder(Path::new(&path)) {
            self.state.status = UiText::with("no_decoder", [path]);
            return;
        }
        let opened = self.open_editor(&path);
        tracing::debug!(
            target: "kogaview::editor",
            %path,
            from_viewer,
            ok = opened.is_ok(),
            "linked the viewer image into the editor"
        );
    }

    pub(super) fn editor_close(&mut self) -> Result<Option<UiText>, ProtocolError> {
        if self.editor.is_none() {
            return Err(no_editor_document());
        }
        // Bump the generation first: a worker still decoding or rendering now
        // belongs to a document that no longer exists.
        self.editor_generation += 1;
        self.editor = None;
        self.editor_rendering = false;
        self.state.editor = None;
        self.state.editor_caption = None;
        self.state.busy = false;
        self.clear_editor_draft();
        if let Some(preview) = self.editor_preview_path.take() {
            let _ = std::fs::remove_file(preview);
        }
        self.editor_preview_stamp = None;
        crate::ram_preview::clear_all();
        self.editor_ram_canvas_revision = 0;
        self.editor_ram_layer_revision = 0;
        self.editor_ram_selection_revision = 0;
        self.state.status = UiText::new("editor_closed");
        Ok(Some(UiText::new("editor_closed")))
    }

    /// Republish the Editor projection after a synchronous edit. Publishes the
    /// live RGBA frame directly into RAM (`image://editor/canvas?rev=N`) so the
    /// UI updates on the very next frame with zero PNG encode / disk latency,
    /// while keeping the background preview PNG path up to date for legacy callers.
    pub(super) fn schedule_editor_preview(&mut self) {
        let Some(document) = &self.editor else {
            return;
        };
        self.editor_generation += 1;
        let generation = self.editor_generation;
        let pixels = document.pixels();
        crate::ram_preview::set_canvas(Arc::clone(&pixels));
        self.editor_ram_canvas_revision += 1;
        self.editor_rendering = true;
        self.refresh_layer_split_previews();
        if self
            .editor
            .as_ref()
            .is_some_and(|d| d.selection().is_some())
        {
            self.refresh_selection_overlay();
        }
        self.publish_editor();
        let Ok(dir) = self.editor_preview_dir() else {
            self.editor_rendering = false;
            self.state.status = UiText::new("preview_folder_failed");
            self.publish_editor();
            return;
        };
        let preview = dir.join(format!("preview-{generation}.png"));
        editor::spawn_preview(pixels, generation, preview, self.editor_tx.clone());
    }

    /// The status line always names the document and its current size; an edit
    /// that only refreshed the preview would otherwise leave the old size
    /// there (measured in the real window: an applied crop left 1600 × 1000).
    pub(super) fn refresh_editor_status(&mut self) {
        let Some(document) = &self.editor else {
            return;
        };
        let (width, height) = document.dimensions();
        let name = document
            .source_path()
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "image".to_owned());
        self.state.status = UiText::with("editing", [name, width.to_string(), height.to_string()]);
    }

    /// Project the Core-owned document into the serializable UI state.
    pub(super) fn publish_editor(&mut self) {
        let Some(document) = &self.editor else {
            self.state.editor = None;
            return;
        };
        let (width, height) = document.dimensions();
        let path = document.source_path().to_string_lossy().into_owned();
        let name = document
            .source_path()
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.clone());
        let (save_path, saved) = document.save_target();
        let save_path = save_path.to_string_lossy().into_owned();
        let format = save_format_label(Path::new(&save_path));
        let previous = self.state.editor.take();
        let (preview_modified, preview_size) = self.editor_preview_stamp.unwrap_or((0, 0));
        // The file on disk, not the preview: the Original tab draws what Save
        // last wrote, and a save to the same path changes these two numbers
        // without changing the path.
        let (file_modified, file_size) = file_identity(Path::new(&save_path));
        let layers: Vec<LayerSummary> = document
            .layers()
            .iter()
            .map(|l| LayerSummary {
                id: l.id,
                name: l.name.clone(),
                visible: l.visible,
                locked: l.locked,
                opacity: l.opacity,
                blend_mode: l.blend_mode.as_key().to_owned(),
                offset_x: l.offset_x,
                offset_y: l.offset_y,
                width: l.pixels.width(),
                height: l.pixels.height(),
                kind: "raster".to_owned(),
            })
            .collect();
        let active_layer_id = document.active_layer_id();
        let canvas_background = document.canvas_background();
        let has_selection = document.selection().is_some();
        let selection_bounds = document.selection_bounds();
        self.state.editor = Some(EditorState {
            path,
            name,
            width,
            height,
            can_undo: document.can_undo(),
            can_redo: document.can_redo(),
            modified: document.can_undo(),
            history: document.history(),
            redo_history: document.redo_history(),
            redo_count: document.redo_count(),
            layers,
            active_layer_id,
            canvas_background,
            has_selection,
            selection_bounds,
            selection_overlay_path: self
                .editor_selection_overlay_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            selection_revision: self.editor_selection_revision,
            clipboard_export_path: self
                .editor_clipboard_export_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            clipboard_export_revision: self.editor_clipboard_export_revision,
            active_layer_preview_path: self
                .editor_active_layer_preview_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            below_active_preview_path: self
                .editor_below_active_preview_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            above_active_preview_path: self
                .editor_above_active_preview_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            layer_preview_revision: self.editor_layer_preview_revision,
            ram_canvas_revision: self.editor_ram_canvas_revision,
            ram_layer_revision: self.editor_ram_layer_revision,
            ram_selection_revision: self.editor_ram_selection_revision,
            preview_path: self
                .editor_preview_path
                .as_ref()
                .map(|path| path.to_string_lossy().into_owned()),
            preview_revision: previous
                .as_ref()
                .map(|editor| editor.preview_revision)
                .unwrap_or(0),
            preview_modified,
            preview_size,
            file_modified,
            file_size,
            preview_draft: self
                .editor_draft_path
                .as_ref()
                .map(|path| EditorPreviewDraft {
                    kind: self.editor_draft_kind.clone(),
                    path: path.to_string_lossy().into_owned(),
                    width: self.editor_draft_size.0,
                    height: self.editor_draft_size.1,
                }),
            rendering: self.editor_rendering,
            save_path,
            saved,
            format,
            saving: self.editor_saving,
            opening: false,
        });
    }

    /// Publish the first, reduced decode of an image whose full frame is still
    /// decoding: the canvas can draw the picture and the footer the real size
    /// while the tools stay disabled (`opening: true`).
    ///
    /// This is the same `EditorState` the document publishes two seconds later,
    /// so nothing jumps when the full frame lands — only `opening` flips and
    /// the sharper preview replaces the soft one.
    pub(super) fn publish_opening_preview(
        &mut self,
        source: &Path,
        preview: PathBuf,
        generation: u64,
        width: u32,
        height: u32,
    ) {
        self.install_editor_preview(&preview, generation);
        let (preview_modified, preview_size) = self.editor_preview_stamp.unwrap_or((0, 0));
        let name = source
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| source.to_string_lossy().into_owned());
        let path = source.to_string_lossy().into_owned();
        let format = save_format_label(source);
        let (file_modified, file_size) = file_identity(source);
        self.state.editor = Some(EditorState {
            name,
            width,
            height,
            can_undo: false,
            can_redo: false,
            modified: false,
            history: Vec::new(),
            redo_history: Vec::new(),
            redo_count: 0,
            layers: Vec::new(),
            active_layer_id: 0,
            canvas_background: None,
            has_selection: false,
            selection_bounds: None,
            selection_overlay_path: None,
            selection_revision: 0,
            clipboard_export_path: None,
            clipboard_export_revision: 0,
            active_layer_preview_path: None,
            below_active_preview_path: None,
            above_active_preview_path: None,
            layer_preview_revision: 0,
            ram_canvas_revision: 0,
            ram_layer_revision: 0,
            ram_selection_revision: 0,
            preview_path: Some(preview.to_string_lossy().into_owned()),
            preview_revision: generation,
            preview_modified,
            preview_size,
            file_modified,
            file_size,
            preview_draft: None,
            rendering: true,
            save_path: path.clone(),
            // Untouched so far, and the pixels on disk at `save_path` are the
            // ones being decoded: Save has nothing to write until an edit.
            saved: true,
            format,
            saving: false,
            opening: true,
            path,
        });
    }

    pub(super) fn editor_preview_dir(&self) -> Result<PathBuf, ProtocolError> {
        let dir = self.paths.cache_dir.join("editor");
        std::fs::create_dir_all(&dir).map_err(|error| {
            // The OS text is the diagnostic; the interface says the same thing
            // about the preview folder it already has a line for.
            ProtocolError::with_line(
                "io_error",
                format!("could not create {}: {error}", dir.display()),
                UiText::new("preview_folder_failed"),
            )
        })?;
        Ok(dir)
    }

    /// Consume one worker result. Stale generations are dropped, including the
    /// preview file they wrote.
    pub(super) fn apply_editor_task(&mut self, task: EditorTask) -> bool {
        match task {
            EditorTask::FirstPreview {
                generation,
                source,
                preview,
                width,
                height,
            } => {
                if generation != self.editor_generation {
                    let _ = std::fs::remove_file(preview);
                    return false;
                }
                // The picture is what the user is waiting for; the pixels that
                // editing needs are still decoding, so `rendering` stays true
                // and the canvas dims the preview until the document lands.
                self.publish_opening_preview(&source, preview, generation, width, height);
                tracing::debug!(
                    target: "kogaview::editor",
                    generation,
                    "editor first preview installed"
                );
                // No `publish_editor()` here: it takes its size and history from
                // the document, which is still decoding, and would wipe the
                // provisional state this line just published.
                true
            }
            EditorTask::Opened {
                generation,
                document,
                preview,
            } => {
                if generation != self.editor_generation {
                    let _ = std::fs::remove_file(preview);
                    return false;
                }
                let (width, height) = document.dimensions();
                self.install_editor_preview(&preview, generation);
                tracing::debug!(
                    target: "kogaview::editor",
                    generation,
                    width,
                    height,
                    "editor document installed"
                );
                let name = document
                    .source_path()
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let caption = super::ai::load_caption_for_image(document.source_path());
                crate::ram_preview::set_canvas(document.pixels());
                self.editor_ram_canvas_revision += 1;
                self.editor = Some(document);
                self.refresh_layer_split_previews();
                self.editor_rendering = false;
                self.state.busy = false;
                self.state.editor_caption = caption;
                self.state.status =
                    UiText::with("editing", [name, width.to_string(), height.to_string()]);
                self.publish_editor();
                true
            }
            EditorTask::Preview {
                generation,
                preview,
            } => {
                if generation != self.editor_generation {
                    let _ = std::fs::remove_file(preview);
                    return false;
                }
                self.install_editor_preview(&preview, generation);
                self.editor_rendering = false;
                self.publish_editor();
                true
            }
            EditorTask::Draft {
                generation,
                kind,
                preview,
                width,
                height,
            } => {
                if generation != self.editor_draft_generation {
                    let _ = std::fs::remove_file(preview);
                    return false;
                }
                if let Some(previous) = self.editor_draft_path.replace(preview) {
                    let _ = std::fs::remove_file(previous);
                }
                self.editor_draft_size = (width, height);
                self.editor_draft_kind = kind;
                self.publish_editor();
                true
            }
            EditorTask::DraftFailed {
                generation,
                message,
            } => {
                if generation != self.editor_draft_generation {
                    return false;
                }
                tracing::warn!(
                    target: "kogaview::editor",
                    %message,
                    "editor draft preview failed"
                );
                // The document is untouched, so there is nothing to explain in
                // the status line: drop the stale draft and show the document.
                self.clear_editor_draft();
                self.publish_editor();
                true
            }
            EditorTask::Failed {
                generation,
                message,
            } => {
                if generation != self.editor_generation {
                    return false;
                }
                tracing::warn!(
                    target: "kogaview::editor",
                    %message,
                    "editor task failed"
                );
                self.editor_rendering = false;
                self.state.busy = false;
                self.state.status = UiText::with("edit_error", [message]);
                // An open that never produced a document leaves the workspace
                // empty — including the fast preview it may have shown first,
                // which would otherwise sit in the cache with nothing behind
                // it. An edit failure keeps the last good preview.
                if self.editor.is_none() {
                    if let Some(path) = self.editor_preview_path.take() {
                        let _ = std::fs::remove_file(path);
                    }
                    self.editor_preview_stamp = None;
                    self.state.editor = None;
                } else {
                    self.publish_editor();
                }
                true
            }
        }
    }

    pub(super) fn install_editor_preview(&mut self, path: &Path, generation: u64) {
        if let Some(previous) = self.editor_preview_path.replace(path.to_path_buf()) {
            if previous != path {
                let _ = std::fs::remove_file(previous);
            }
        }
        // The cache that resolves the thumbnail keys on the file's identity, so
        // record what it needs while the file is known to be complete.
        self.editor_preview_stamp = std::fs::metadata(path).ok().map(|metadata| {
            let modified = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|age| age.as_millis() as u64)
                .unwrap_or(0);
            (modified, metadata.len())
        });
        if let Some(editor) = &mut self.state.editor {
            editor.preview_path = Some(path.to_string_lossy().into_owned());
            editor.preview_revision = generation;
            editor.preview_modified = self
                .editor_preview_stamp
                .map(|stamp| stamp.0)
                .unwrap_or_default();
            editor.preview_size = self
                .editor_preview_stamp
                .map(|stamp| stamp.1)
                .unwrap_or_default();
            editor.rendering = false;
        }
    }
}
