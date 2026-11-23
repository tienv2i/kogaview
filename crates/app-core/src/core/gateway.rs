//! The gateway: one ordered entry point, its queries, and the poll loop that
//! turns finished background work into state.
//!
//! Adapters never call a handler; they submit an `Envelope` here, and `poll`
//! is what the shell calls on a timer to publish what the workers produced.
use super::*;

impl Core {
    pub fn dispatch(&mut self, envelope_json: &str) -> String {
        let envelope: Envelope = match serde_json::from_str(envelope_json) {
            Ok(envelope) => envelope,
            Err(error) => {
                return json!({
                    "id": "",
                    "ok": false,
                    "revision": self.state.revision,
                    "error": { "code": "invalid_envelope", "message": format!("invalid command envelope: {error}") }
                })
                .to_string();
            }
        };

        let command = envelope.command;
        let command_name = command.name();
        let result = self.execute(command.clone());
        match &result {
            Ok(_) => {
                self.state.bump();
                self.journal.record(JournalEntry {
                    command_id: &envelope.id,
                    command: &command,
                    revision: self.state.revision,
                    result: &result,
                });
                tracing::debug!(
                    target: "kogaview::command",
                    id = %envelope.id,
                    command = command_name,
                    revision = self.state.revision,
                    "command completed"
                );
                // `message` stays the English rendering, because the journal,
                // the CLI and the log read it; `ui` is the same line as a code
                // so a front end with a translator can word it itself.
                let line = result.as_ref().ok().and_then(|line| line.clone());
                json!({
                    "id": envelope.id,
                    "ok": true,
                    "revision": self.state.revision,
                    "message": line.as_ref().map(UiText::english),
                    "ui": line,
                })
                .to_string()
            }
            Err(error) => {
                self.journal.record(JournalEntry {
                    command_id: &envelope.id,
                    command: &command,
                    revision: self.state.revision,
                    result: &result,
                });
                tracing::warn!(
                    target: "kogaview::command",
                    id = %envelope.id,
                    command = command_name,
                    code = %error.code,
                    message = %error.message,
                    "command rejected"
                );
                json!({
                    "id": envelope.id,
                    "ok": false,
                    "revision": self.state.revision,
                    "error": error,
                })
                .to_string()
            }
        }
    }

    pub fn query_json(&mut self, query_json: &str) -> String {
        let query: Query = match serde_json::from_str(query_json) {
            Ok(query) => query,
            Err(error) => {
                return json!({
                    "ok": false,
                    "error": { "code": "invalid_query", "message": format!("invalid query: {error}") }
                })
                .to_string();
            }
        };

        match query {
            Query::State => self.snapshot_json(),
            Query::ListFolders { path } => {
                // Normalise without resolving links: the tree is built from the
                // paths the user sees, so a folder reached through a symlink
                // must hand back children under that same path.
                let path = ops::normalize_path(Path::new(&path));
                if !path.is_dir() {
                    return json!({
                        "ok": false,
                        "error": { "code": "not_found", "message": format!("{} is not a directory", path.display()) }
                    })
                    .to_string();
                }
                match ops::list_folders(&path) {
                    Ok(folders) => json!({
                        "ok": true,
                        "folders": folders
                            .iter()
                            .map(|folder| json!({ "name": &folder.name, "path": &folder.path }))
                            .collect::<Vec<_>>()
                    })
                    .to_string(),
                    Err(error) => json!({
                        "ok": false,
                        "error": { "code": "io_error", "message": error }
                    })
                    .to_string(),
                }
            }
        }
    }

    pub fn poll(&mut self) -> bool {
        let mut changed = false;

        if let Some(receiver) = &self.scan_rx {
            match receiver.try_recv() {
                Ok(result) => {
                    self.scan_rx = None;
                    changed |= self.apply_scan(result);
                }
                Err(TryRecvError::Empty) => {}
                Err(TryRecvError::Disconnected) => {
                    self.scan_rx = None;
                    self.state.busy = false;
                    self.state.status = UiText::new("folder_scan_failed");
                    changed = true;
                }
            }
        }

        if let Some(receiver) = &self.op_rx {
            match receiver.try_recv() {
                Ok(result) => {
                    self.op_rx = None;
                    self.cancel_op = None;
                    self.state.busy = false;
                    self.state.status = result.message;
                    // An operation finished: the tree on disk may differ now
                    // even when the refreshed listing looks the same.
                    self.state.tree_revision += 1;
                    if result.ok && result.refresh {
                        self.refresh_current();
                    }
                    changed = true;
                }
                Err(TryRecvError::Empty) => {}
                Err(TryRecvError::Disconnected) => {
                    self.op_rx = None;
                    self.cancel_op = None;
                    self.state.busy = false;
                    self.state.status = UiText::new("file_operation_failed");
                    changed = true;
                }
            }
        }

        // Editor workers report through one persistent channel. A preview is
        // allowed to arrive after the command that produced it returned, which
        // is why it needs its own poll branch and its own revision bump.
        loop {
            let task = match self.editor_rx.try_recv() {
                Ok(task) => task,
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            };
            changed |= self.apply_editor_task(task);
        }

        if let Some(receiver) = &self.pending_save {
            match receiver.try_recv() {
                Ok(result) => {
                    self.pending_save = None;
                    changed |= self.apply_save_result(result);
                }
                Err(TryRecvError::Empty) => {}
                Err(TryRecvError::Disconnected) => {
                    self.pending_save = None;
                    self.editor_saving = false;
                    self.state.status = UiText::new("save_incomplete");
                    changed = true;
                }
            }
        }

        if let Some(receiver) = &self.pending_export {
            match receiver.try_recv() {
                Ok(result) => {
                    self.pending_export = None;
                    changed |= self.apply_export_result(result);
                }
                Err(TryRecvError::Empty) => {}
                Err(TryRecvError::Disconnected) => {
                    self.pending_export = None;
                    self.editor_saving = false;
                    self.state.status = UiText::new("export_incomplete");
                    changed = true;
                }
            }
        }

        // A batch worker reports once per file and once when it stops. The
        // receiver is taken out while it is drained so the state updates below
        // can borrow `self`; an idle channel goes back untouched.
        if let Some(receiver) = self.batch_rx.take() {
            let mut finished = false;
            loop {
                match receiver.try_recv() {
                    Ok(BatchEvent::Progress(progress)) => {
                        if let Some(batch) = &mut self.state.batch {
                            batch.done = progress.done;
                            batch.failed = progress.failed;
                            batch.current = progress.current;
                        }
                        changed = true;
                    }
                    Ok(BatchEvent::Finished(result)) => {
                        if let Some(batch) = &mut self.state.batch {
                            batch.done = result.done;
                            batch.failed = result.failed;
                            batch.running = false;
                            batch.cancelled = result.cancelled;
                        }
                        self.batch_cancel = None;
                        self.state.busy = false;
                        self.state.status = result.message;
                        // The tree on disk may differ now even when the
                        // refreshed listing looks the same.
                        self.state.tree_revision += 1;
                        if result.refresh {
                            self.refresh_current();
                        }
                        finished = true;
                        changed = true;
                        break;
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        self.batch_cancel = None;
                        if let Some(batch) = &mut self.state.batch {
                            batch.running = false;
                        }
                        self.state.busy = false;
                        self.state.status = UiText::new("batch_incomplete");
                        finished = true;
                        changed = true;
                        break;
                    }
                }
            }
            if !finished {
                self.batch_rx = Some(receiver);
            }
        }

        if changed {
            self.state.bump();
        }
        changed
    }

    pub(super) fn execute(&mut self, command: Command) -> Result<Option<UiText>, ProtocolError> {
        match command {
            Command::OpenFile { paths } => self.open_file(paths),
            Command::OpenFolder { path } => self.open_folder(PathBuf::from(path), true),
            Command::Navigate { path } => self.open_folder(PathBuf::from(path), false),
            Command::Refresh => {
                self.state.tree_revision += 1;
                self.refresh_current();
                Ok(Some(UiText::new("refreshed")))
            }
            Command::Select { paths } => {
                self.set_selection(paths);
                Ok(None)
            }
            Command::SetWorkspace { workspace } => {
                let previous = self.state.workspace;
                self.state.workspace = workspace;
                match workspace {
                    Workspace::Viewer => self.ensure_viewer_selection(),
                    // The Viewer and the Editor are one photograph seen two
                    // ways: arriving at an empty Editor carries the image the
                    // Viewer shows, and arriving from the Viewer carries the
                    // image it shows *now*. A switch from any other workspace
                    // keeps the document the user already has.
                    Workspace::Editor => {
                        self.link_viewer_into_editor(previous == Workspace::Viewer)
                    }
                    Workspace::Browser => {}
                }
                // Leaving the Editor while a document is still open keeps the
                // document (it is restored on return), but the status line
                // describes what the workspace shows: "Editing …" would claim
                // the Browser is the Editor.
                if workspace != Workspace::Editor && self.editor.is_some() {
                    self.state.status = UiText::empty();
                }
                Ok(None)
            }
            Command::SetTheme { theme } => {
                self.set_theme(theme);
                Ok(None)
            }
            Command::SetSettings {
                theme,
                remember_last_folder,
                background_thumbnails,
                language,
                hardware_acceleration,
                anti_aliasing,
            } => {
                // `remember_last_folder` is what decides whether the explorer
                // folders are written at all, so it is committed in one place:
                // turning it on restores the folders this session showed, and
                // turning it off stops the next navigation from saving them and
                // drops the stale values the file may still hold.
                self.config.theme = theme;
                self.config.language = language;
                self.config.remember_last_folder = remember_last_folder;
                self.config.background_thumbnails = background_thumbnails;
                self.config.hardware_acceleration = hardware_acceleration;
                self.config.anti_aliasing = anti_aliasing;
                self.state.theme = theme;
                self.state.language = language;
                self.state.remember_last_folder = remember_last_folder;
                self.state.background_thumbnails = background_thumbnails;
                self.state.hardware_acceleration = hardware_acceleration;
                self.state.anti_aliasing = anti_aliasing;
                self.remember_explorer_folders();
                self.save_config();
                self.state.bump();
                Ok(Some(UiText::new("settings_saved")))
            }
            Command::SetLanguage { language } => {
                self.config.language = language;
                self.state.language = language;
                self.save_config();
                self.state.bump();
                Ok(Some(UiText::with(
                    "language_set",
                    [language.as_str().to_owned()],
                )))
            }
            Command::ToggleTheme => {
                self.set_theme(self.config.theme.toggled());
                Ok(None)
            }
            Command::ToggleLeftPanel => {
                // Kept for a replayed journal and a future CLI. The window has
                // no button for it: a panel is toggled by name through
                // `set_layout`, so the left dock as a whole means "every panel
                // on that side of the open workspace".
                let workspace = self.state.workspace;
                self.toggle_panels(&left_panel_keys(workspace));
                Ok(None)
            }
            Command::ToggleRightPanel { workspace } => {
                // One preference per workspace: the Browser's preview and
                // metadata panel, the Viewer's information panel and the
                // Editor's dock show different things and size the picture
                // differently, so a toggle says which one it means. A front
                // end that sends no workspace means the one on screen.
                let workspace = workspace.unwrap_or(self.state.workspace);
                self.toggle_panels(&right_panel_keys(workspace));
                Ok(None)
            }
            Command::SetLayout { layout } => {
                // A layout is a preference, not a document fact: it is written
                // as it arrives, so closing the window is not a save step. The
                // command is validated here rather than by the view, so a CLI
                // cannot save a width the splitter would never reach.
                let layout = layout.sanitized();
                let sort_changed = self.config.layout.browser_sort_by != layout.browser_sort_by
                    || self.config.layout.browser_sort_order != layout.browser_sort_order;
                self.config.layout = layout.clone();
                self.state.layout = layout;
                if sort_changed && !self.state.entries.is_empty() {
                    self.sort_entries();
                    self.listing_epoch += 1;
                    self.sync_viewer();
                }
                self.save_config();
                self.state.bump();
                Ok(Some(UiText::new("layout_saved")))
            }
            Command::ToggleFilmstrip => {
                self.config.filmstrip = !self.config.filmstrip;
                self.state.filmstrip = self.config.filmstrip;
                self.save_config();
                Ok(None)
            }
            Command::NewFolder { parent, name } => self.new_folder(PathBuf::from(parent), &name),
            Command::CopyTo { paths, destination } => {
                self.transfer(paths, PathBuf::from(destination), false)
            }
            Command::MoveTo { paths, destination } => {
                self.transfer(paths, PathBuf::from(destination), true)
            }
            Command::Trash { paths } => self.trash_paths(paths),
            Command::DeletePermanently { paths } => self.delete_paths(paths),
            Command::AddFavorite { path } => self.add_favorite(PathBuf::from(path)),
            Command::RemoveFavorite { path } => self.remove_favorite(&path),
            Command::MoveFavorite { path, direction } => self.move_favorite(&path, direction),
            Command::ViewerNext => self.step_viewer(1),
            Command::ViewerPrevious => self.step_viewer(-1),
            Command::ViewerOpen { path } => self.open_viewer_image(&path),
            Command::EditorOpen { path } => self.open_editor(&path),
            Command::EditorResize {
                width,
                height,
                fill,
                fill_alpha,
                mode,
                filter,
            } => self.editor_apply(EditOperation::Resize {
                width,
                height,
                fill,
                fill_alpha,
                // A payload from before the modes existed says what it meant
                // with `fill` alone; see `ResizeMode::for_payload`.
                mode: ResizeMode::for_payload(mode, fill),
                filter,
            }),
            Command::EditorResizePreview {
                width,
                height,
                fill,
                fill_alpha,
                mode,
                filter,
            } => self.editor_resize_preview(width, height, fill, fill_alpha, mode, filter),
            Command::EditorCrop {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            } => self.editor_apply(EditOperation::Crop {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            }),
            Command::EditorCropPreview {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            } => self.editor_crop_preview(x, y, width, height, fill, fill_alpha),
            Command::EditorTransform { corners } => {
                self.editor_apply(EditOperation::Transform { corners })
            }
            Command::EditorFreeTransform {
                x,
                y,
                width,
                height,
                rotation,
                fill,
                fill_alpha,
            } => self.editor_apply(EditOperation::FreeTransform {
                x,
                y,
                width,
                height,
                rotation,
                fill,
                fill_alpha,
            }),
            Command::EditorTransformPreview { corners } => self.editor_transform_preview(corners),
            Command::EditorCanvasSize {
                width,
                height,
                anchor,
                fill,
                fill_alpha,
            } => self.editor_apply(EditOperation::CanvasSize {
                width,
                height,
                anchor,
                fill,
                fill_alpha,
            }),
            Command::EditorRotateAngle {
                degrees,
                fill,
                fill_alpha,
            } => self.editor_apply(EditOperation::RotateAngle {
                degrees,
                fill,
                fill_alpha,
            }),
            Command::EditorAdjustColor {
                brightness,
                contrast,
                saturation,
            } => self.editor_apply(EditOperation::AdjustColor {
                brightness,
                contrast,
                saturation,
            }),
            Command::EditorRotate { degrees } => {
                self.editor_apply(EditOperation::Rotate { degrees })
            }
            Command::EditorFlip { axis } => self.editor_apply(EditOperation::Flip { axis }),
            Command::EditorPaintStroke {
                points,
                color,
                radius,
                opacity,
                erase,
            } => self.editor_apply(EditOperation::Paint {
                points,
                color,
                radius,
                opacity,
                erase,
            }),
            Command::EditorSave => self.editor_save(None),
            Command::EditorSaveAs { path } => self.editor_save(Some(&path)),
            Command::EditorExport {
                path,
                quality,
                metadata,
                max_edge,
            } => self.editor_export(&path, quality, metadata, max_edge),
            Command::EditorUndo => self.editor_step(true),
            Command::EditorRedo => self.editor_step(false),
            Command::EditorReset => self.editor_reset(),
            Command::EditorClose => self.editor_close(),
            Command::BatchRun {
                operation,
                source,
                output,
            } => self.batch_run(operation, source, output),
            Command::CancelOperation => {
                let mut cancelled = false;
                if let Some(cancel) = &self.cancel_op {
                    cancel.store(true, Ordering::SeqCst);
                    cancelled = true;
                }
                if let Some(cancel) = &self.batch_cancel {
                    cancel.store(true, Ordering::SeqCst);
                    cancelled = true;
                }
                if cancelled {
                    self.state.status = UiText::new("cancelling");
                    Ok(Some(UiText::new("cancelling")))
                } else {
                    Err(ProtocolError::with_line(
                        "not_running",
                        "there is no long-running operation to cancel",
                        UiText::new("cancel_nothing_running"),
                    ))
                }
            }
        }
    }

    pub(super) fn start_operation<F>(&mut self, status: UiText, work: F)
    where
        F: FnOnce(Arc<AtomicBool>) -> OpResult + Send + 'static,
    {
        let (sender, receiver) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.cancel_op = Some(cancel.clone());
        self.op_rx = Some(receiver);
        self.state.busy = true;
        self.state.status = status;
        std::thread::spawn(move || {
            let _ = sender.send(work(cancel));
        });
    }
}
