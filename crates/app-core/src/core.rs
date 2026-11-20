//! The single ordered command gateway and state owner.
//!
//! `Core` is Qt-independent. UI, CLI, IPC and MCP adapters submit the same
//! envelopes; background work reports back through `poll`.

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::Arc;

use kogaview_protocol::{Command, Envelope, MoveDirection, ProtocolError, Query, Theme, Workspace};
use serde_json::{json, Value};

use crate::config::Config;
use crate::editor::{self, EditOperation, EditorDocument, EditorTask};
use crate::journal::{Journal, JournalEntry};
use crate::ops;
use crate::paths::AppPaths;
use crate::state::{
    Crumb, EditorPreviewDraft, EditorState, FolderListing, SelectionInfo, UiState, UiText,
};
use crate::AppIdentity;

struct ScanResult {
    generation: u64,
    folder: PathBuf,
    entries: Result<Vec<crate::state::Entry>, String>,
}

/// The dotted extension a path would save with, for the file list's label.
fn save_format_label(path: &Path) -> String {
    editor::SaveFormat::from_path(path)
        .map(|format| format.label().to_owned())
        .unwrap_or_else(|| ops::kind_label(path))
}

/// A save that finished on a worker.
struct EditorSaveResult {
    save: u64,
    destination: PathBuf,
    result: Result<(), String>,
}

struct EditorExportResult {
    save: u64,
    destination: PathBuf,
    result: Result<(), String>,
}

/// Which size tool a live preview belongs to.
///
/// The two tools share one draft pipeline and differ only in what the interface
/// calls the result, so the codes live here as literals: the QML line table is
/// checked against them by `scripts/check_translations.py`, and a `format!`ed
/// code would slip past that gate.
#[derive(Clone, Copy)]
enum PreviewKind {
    Resize,
    Crop,
}

impl PreviewKind {
    /// The line for "that rectangle/size changes nothing".
    fn noop(self) -> UiText {
        match self {
            Self::Resize => UiText::new("resize_noop"),
            Self::Crop => UiText::new("crop_noop"),
        }
    }

    /// The line for "rendering a draft of …".
    fn preview(self, width: u32, height: u32) -> UiText {
        match self {
            Self::Resize => UiText::with("resize_preview", [width.to_string(), height.to_string()]),
            Self::Crop => UiText::with("crop_preview", [width.to_string(), height.to_string()]),
        }
    }
}

struct OpResult {
    ok: bool,
    /// The line the status bar shows when the operation finishes, as a code so
    /// the interface can say it in its own language.
    message: UiText,
    refresh: bool,
}

pub struct Core {
    paths: AppPaths,
    config: Config,
    config_path: PathBuf,
    state: UiState,
    journal: Journal,
    scan_rx: Option<Receiver<ScanResult>>,
    scan_generation: u64,
    op_rx: Option<Receiver<OpResult>>,
    cancel_op: Option<Arc<AtomicBool>>,
    pending_viewer: Option<String>,
    pending_selection: Option<Vec<String>>,
    /// The Editor's working document. Core owns the pixels; the UI only gets a
    /// preview path, so no front end can mutate them without a command.
    editor: Option<EditorDocument>,
    /// Editor work runs on worker threads (decode, preview encode) and reports
    /// through this one channel, so a preview can arrive after the command that
    /// produced it already returned.
    editor_tx: mpsc::Sender<EditorTask>,
    editor_rx: Receiver<EditorTask>,
    /// Bumped for every issued editor task; results from an older generation
    /// are discarded so a slow open cannot overwrite a newer document.
    editor_generation: u64,
    editor_rendering: bool,
    /// Preview PNG currently referenced by the UI. Replaced (and deleted) when
    /// the next one is installed.
    editor_preview_path: Option<PathBuf>,
    /// Identity of that file — modification time in milliseconds and size in
    /// bytes — published so caches keyed on a path cannot answer a reused
    /// preview name with an older image.
    editor_preview_stamp: Option<(u64, u64)>,
    /// The live-preview resize: its PNG and its own generation, separate from
    /// `editor_generation` so a draft can never be mistaken for the document's
    /// preview (or the other way round).
    editor_draft_path: Option<PathBuf>,
    editor_draft_size: (u32, u32),
    /// The tool that asked for the draft (`resize` or `crop`), so the view can
    /// hide it after a tool switch instead of painting the other result.
    editor_draft_kind: String,
    editor_draft_generation: u64,
    /// True while a save is being encoded and written on a worker.
    editor_saving: bool,
    /// Bumped for every save, so a result for a superseded save is dropped.
    editor_save_generation: u64,
    /// The worker's answer for the save in flight.
    pending_save: Option<Receiver<EditorSaveResult>>,
    pending_export: Option<Receiver<EditorExportResult>>,
    /// Bumped whenever the folder listing is replaced. The Qt adapter ships the
    /// listing on its own and only re-sends it when this changes, because it is
    /// the one part of the snapshot that grows with the folder.
    listing_epoch: u64,
}

impl Core {
    pub fn new() -> Self {
        let identity = AppIdentity::current();
        let paths = AppPaths::for_identity(&identity);
        let config_path = paths.config_dir.join("config.json");
        let (config, warning) = Config::load_or_create(&config_path);
        if let Some(warning) = &warning {
            tracing::warn!(target: "kogaview::config", %warning, "configuration fallback");
        }

        let journal = Journal::new(&paths.journal_dir);
        let config_path_label = config_path.to_string_lossy().into_owned();
        let (editor_tx, editor_rx) = mpsc::channel();
        let state = UiState::new(
            config.theme,
            config.language,
            config.quick_access.clone(),
            config.left_panel,
            config.right_panel,
            config.filmstrip,
            config.remember_last_folder,
            config.background_thumbnails,
            config_path_label,
        );

        let mut core = Self {
            paths,
            config,
            config_path,
            state,
            journal,
            scan_rx: None,
            scan_generation: 0,
            op_rx: None,
            cancel_op: None,
            pending_viewer: None,
            pending_selection: None,
            editor: None,
            editor_tx: editor_tx.clone(),
            editor_rx,
            editor_generation: 0,
            editor_rendering: false,
            editor_preview_path: None,
            editor_preview_stamp: None,
            editor_draft_path: None,
            editor_draft_size: (0, 0),
            editor_draft_kind: String::new(),
            editor_draft_generation: 0,
            editor_saving: false,
            editor_save_generation: 0,
            pending_save: None,
            pending_export: None,
            listing_epoch: 0,
        };

        core.restore_last_session();
        core
    }

    /// Re-open the folders the previous session left behind.
    ///
    /// The tree root and the folder the list showed are separate pieces of
    /// state, so a session left with `~/Pictures` in the sidebar and
    /// `~/Pictures/Child` open comes back the same way instead of collapsing
    /// both into the deeper folder.
    fn restore_last_session(&mut self) {
        // A session the user asked not to remember opens nothing, even if a
        // previous run left folders in the file (`SetSettings` drops them, but a
        // hand-edited or older config may still carry them).
        if !self.config.remember_last_folder {
            return;
        }
        let saved_root = self.config.tree_root.clone();
        let saved_folder = self.config.last_folder.clone();
        let (root, folder) =
            restored_folders(saved_root.as_deref(), saved_folder.as_deref(), |path| {
                path.is_dir()
            });
        let (Some(root), Some(folder)) = (root, folder) else {
            return;
        };

        let root_label = root.to_string_lossy().into_owned();
        let folder_label = folder.to_string_lossy().into_owned();
        self.state.root_folder = Some(root_label.clone());
        self.start_scan(folder, false, true);
        // Persist what startup actually resolved, so a root derived from the
        // surviving folder is not re-derived (or lost) on every start.
        self.save_explorer_folders(root_label, folder_label);
    }

    /// Build a Core whose configuration, journal and state directories live in
    /// `base`, so a test can drive real commands without touching the user's
    /// files. Test-only: production always goes through `Core::new()`.
    #[cfg(test)]
    fn for_test(base: &Path) -> Self {
        let config_path = base.join("config.json");
        // Load like startup does, so a test can save a config and build the
        // "next run" on top of it.
        let (config, _) = Config::load_or_create(&config_path);
        let paths = AppPaths {
            state_dir: base.join("state"),
            cache_dir: base.join("cache"),
            config_dir: base.join("config"),
            data_dir: base.join("data"),
            log_dir: base.join("state/logs"),
            journal_dir: base.join("state/journal"),
            screenshot_dir: base.join("state/screenshots"),
        };
        let journal = Journal::new(&paths.journal_dir);
        let (editor_tx, editor_rx) = mpsc::channel();
        let state = UiState::new(
            config.theme,
            config.language,
            config.quick_access.clone(),
            config.left_panel,
            config.right_panel,
            config.filmstrip,
            config.remember_last_folder,
            config.background_thumbnails,
            config_path.to_string_lossy().into_owned(),
        );
        Self {
            paths,
            config,
            config_path,
            state,
            journal,
            scan_rx: None,
            scan_generation: 0,
            op_rx: None,
            cancel_op: None,
            pending_viewer: None,
            pending_selection: None,
            editor: None,
            editor_tx,
            editor_rx,
            editor_generation: 0,
            editor_rendering: false,
            editor_preview_path: None,
            editor_preview_stamp: None,
            editor_draft_path: None,
            editor_draft_size: (0, 0),
            editor_draft_kind: String::new(),
            editor_draft_generation: 0,
            editor_saving: false,
            editor_save_generation: 0,
            pending_save: None,
            pending_export: None,
            listing_epoch: 0,
        }
    }

    /// The folders to restore, read back the way startup reads them.
    #[cfg(test)]
    fn saved_folders(&self) -> (Option<String>, Option<String>) {
        let (config, _) = Config::load_or_create(&self.config_path);
        (config.tree_root, config.last_folder)
    }

    /// The complete snapshot: the metadata the window renders *and* the folder
    /// listing. Used by `Query::State`, the CLI and the tests, where 200 KB is
    /// not on anybody's critical path. Built by splicing the two halves, so it is
    /// the same object a window that has both would render.
    pub fn snapshot_json(&self) -> String {
        let meta = self.meta_json();
        let listing = self.folder_json();
        let mut full: serde_json::Map<String, Value> = match serde_json::from_str(&meta) {
            Ok(Value::Object(map)) => map,
            _ => serde_json::Map::new(),
        };
        let listing: serde_json::Map<String, Value> = match serde_json::from_str(&listing) {
            Ok(Value::Object(map)) => map,
            _ => serde_json::Map::new(),
        };
        for (key, value) in listing {
            full.insert(key, value);
        }
        Value::Object(full).to_string()
    }

    /// The same snapshot without the folder listing, which is shipped
    /// separately by [`Core::folder_json`]. Around a kilobyte, so the window can
    /// re-render it after every command — every click, every arrow key — without
    /// touching the listing.
    pub fn meta_json(&self) -> String {
        self.serialize(&self.state.meta())
    }

    /// The folder listing — the entries and the filmstrip's image paths — and
    /// nothing else. Re-serialised only when [`Core::listing_epoch`] moves.
    pub fn folder_json(&self) -> String {
        self.serialize(&FolderListing {
            entries: &self.state.entries,
            viewer_images: &self.state.viewer_images,
        })
    }

    /// Changes exactly when the folder listing is replaced (a scan landing, a
    /// failed scan clearing it, a new folder starting to load).
    pub fn listing_epoch(&self) -> u64 {
        self.listing_epoch
    }

    fn serialize<T: serde::Serialize>(&self, value: &T) -> String {
        serde_json::to_string(value).unwrap_or_else(|error| {
            tracing::error!(target: "kogaview::core", %error, "cannot serialize state");
            String::from("{}")
        })
    }

    pub fn busy(&self) -> bool {
        self.state.busy
    }

    pub fn revision(&self) -> u64 {
        self.state.revision
    }

    pub fn status(&self) -> &UiText {
        &self.state.status
    }

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

    /// Deliver completed background work. Returns true when state changed.
    /// The configured interface language, as the settings store it.
    pub fn language(&self) -> &'static str {
        self.state.language.as_str()
    }

    /// True while a save is in flight, for the UI's busy indicator.
    pub fn editor_saving(&self) -> bool {
        self.editor_saving
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

        if changed {
            self.state.bump();
        }
        changed
    }

    fn execute(&mut self, command: Command) -> Result<Option<UiText>, ProtocolError> {
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
                self.state.workspace = workspace;
                match workspace {
                    Workspace::Viewer => self.ensure_viewer_selection(),
                    // The Viewer and the Editor are one photograph seen two
                    // ways: arriving at an empty Editor carries the image the
                    // Viewer shows. A document the user already opened wins,
                    // so returning from the Browser does not reload it.
                    Workspace::Editor => self.link_viewer_into_editor(),
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
                self.state.theme = theme;
                self.state.language = language;
                self.state.remember_last_folder = remember_last_folder;
                self.state.background_thumbnails = background_thumbnails;
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
                self.config.left_panel = !self.config.left_panel;
                self.state.left_panel = self.config.left_panel;
                self.save_config();
                Ok(None)
            }
            Command::ToggleRightPanel => {
                self.config.right_panel = !self.config.right_panel;
                self.state.right_panel = self.config.right_panel;
                self.save_config();
                Ok(None)
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
            } => self.editor_apply(EditOperation::Resize {
                width,
                height,
                fill,
            }),
            Command::EditorResizePreview {
                width,
                height,
                fill,
            } => self.editor_resize_preview(width, height, fill),
            Command::EditorCrop {
                x,
                y,
                width,
                height,
            } => self.editor_apply(EditOperation::Crop {
                x,
                y,
                width,
                height,
            }),
            Command::EditorCropPreview {
                x,
                y,
                width,
                height,
            } => self.editor_crop_preview(x, y, width, height),
            Command::EditorRotate { degrees } => {
                self.editor_apply(EditOperation::Rotate { degrees })
            }
            Command::EditorFlip { axis } => self.editor_apply(EditOperation::Flip { axis }),
            Command::EditorSave => self.editor_save(None),
            Command::EditorSaveAs { path } => self.editor_save(Some(&path)),
            Command::EditorExport {
                path,
                quality,
                metadata,
            } => self.editor_export(&path, quality, metadata),
            Command::EditorUndo => self.editor_step(true),
            Command::EditorRedo => self.editor_step(false),
            Command::EditorReset => self.editor_reset(),
            Command::EditorClose => self.editor_close(),
            Command::CancelOperation => {
                if let Some(cancel) = &self.cancel_op {
                    cancel.store(true, Ordering::SeqCst);
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

    fn open_file(&mut self, paths: Vec<String>) -> Result<Option<UiText>, ProtocolError> {
        let first = paths
            .first()
            .ok_or_else(|| ProtocolError::line("invalid_path", UiText::new("open_needs_a_path")))?;
        let first = ops::normalize_path(&PathBuf::from(first));
        if !first.exists() {
            return Err(ProtocolError::line(
                "not_found",
                UiText::with("path_missing", [first.display().to_string()]),
            ));
        }

        if first.is_dir() {
            return self.open_folder(first, true);
        }

        let parent = first
            .parent()
            .ok_or_else(|| ProtocolError::line("invalid_path", UiText::new("path_has_no_folder")))?
            .to_path_buf();

        let scanned_paths = paths
            .iter()
            .map(|path| ops::normalize_path(&PathBuf::from(path)))
            .filter(|path| path.is_file())
            .map(|path| path.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        self.state.workspace = Workspace::Viewer;
        self.state.viewer_path = Some(first.to_string_lossy().into_owned());
        self.pending_viewer = self.state.viewer_path.clone();
        self.pending_selection = Some(if scanned_paths.is_empty() {
            vec![first.to_string_lossy().into_owned()]
        } else {
            scanned_paths
        });
        self.start_scan(parent, true, false);
        Ok(Some(UiText::with(
            "opening_file",
            [first
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()],
        )))
    }

    fn open_folder(
        &mut self,
        path: PathBuf,
        set_browser_workspace: bool,
    ) -> Result<Option<UiText>, ProtocolError> {
        // A symlinked folder opens like any other folder: the path the user
        // asked for stays in the breadcrumbs, the tree root and the grid, so
        // navigating into the link does not teleport to its target.
        let path = ops::normalize_path(&path);
        if !path.is_dir() {
            return Err(ProtocolError::line(
                "not_a_directory",
                UiText::with("not_a_folder", [path.display().to_string()]),
            ));
        }

        if set_browser_workspace {
            self.state.workspace = Workspace::Browser;
        }
        // The tree root and the open folder are two different things. This is
        // the one place that decides the root for a *navigation*: it stays put
        // while the folder is inside the tree and follows it as soon as the
        // folder leaves (breadcrumbs to an ancestor, "up" past the root). An
        // explicit open inside the tree therefore does not re-root either.
        let root = root_after_navigation(self.state.root_folder.as_deref().map(Path::new), &path);
        let root_label = root.to_string_lossy().into_owned();
        let folder_label = path.to_string_lossy().into_owned();
        self.state.root_folder = Some(root_label.clone());
        self.pending_viewer = None;
        self.pending_selection = None;

        // `Navigate` now has to persist too: it is the only command that moves
        // the folder the list shows. Only write when something really changed,
        // so a refresh or a repeated click does not rewrite the file.
        self.save_explorer_folders(root_label, folder_label);

        self.start_scan(path.clone(), true, false);
        Ok(Some(UiText::with(
            "folder_opened",
            [path.display().to_string()],
        )))
    }

    fn refresh_current(&mut self) {
        let Some(folder) = self.state.current_folder.clone() else {
            return;
        };
        let selection = self.state.selection.clone();
        self.pending_selection = Some(selection);
        self.pending_viewer = self.state.viewer_path.clone();
        self.start_scan(PathBuf::from(folder), false, false);
    }

    fn start_scan(&mut self, folder: PathBuf, clear_entries: bool, restore: bool) {
        self.scan_generation += 1;
        let generation = self.scan_generation;
        let (sender, receiver) = mpsc::channel();
        self.scan_rx = Some(receiver);
        self.state.busy = true;
        self.state.current_folder = Some(folder.to_string_lossy().into_owned());
        self.state.breadcrumbs = breadcrumbs(&folder);
        if clear_entries {
            self.state.entries.clear();
            self.listing_epoch += 1;
            self.state.selection.clear();
            self.state.selection_info = None;
        }
        let folder_label = folder.display().to_string();
        self.state.status = if restore {
            UiText::new("restoring_folder")
        } else {
            UiText::with("loading_folder", [folder_label])
        };

        let thread_folder = folder.clone();
        std::thread::spawn(move || {
            let entries = ops::read_entries(&thread_folder);
            let _ = sender.send(ScanResult {
                generation,
                folder: thread_folder,
                entries,
            });
        });
    }

    fn apply_scan(&mut self, result: ScanResult) -> bool {
        if result.generation != self.scan_generation {
            // A newer navigation superseded this scan.
            return false;
        }

        match result.entries {
            Ok(entries) => {
                let existing = entries
                    .iter()
                    .map(|entry| entry.path.clone())
                    .collect::<HashSet<_>>();
                self.state.entries = entries;
                self.listing_epoch += 1;
                self.state.item_count = self.state.entries.len();
                self.state.image_count = self
                    .state
                    .entries
                    .iter()
                    .filter(|entry| entry.is_image)
                    .count();

                if let Some(pending) = self.pending_selection.take() {
                    self.state.selection = pending
                        .into_iter()
                        .filter(|path| existing.contains(path))
                        .collect();
                } else {
                    self.state.selection.retain(|path| existing.contains(path));
                }

                self.sync_viewer();
                self.state.selection_info = self.build_selection_info();
                self.state.busy = false;
                self.state.status = UiText::with(
                    "folder_contents",
                    [
                        self.state.item_count.to_string(),
                        self.state.image_count.to_string(),
                    ],
                );
                tracing::info!(
                    target: "kogaview::scan",
                    folder = %result.folder.display(),
                    items = self.state.item_count,
                    images = self.state.image_count,
                    "folder scan complete"
                );
            }
            Err(error) => {
                self.state.entries.clear();
                self.listing_epoch += 1;
                self.state.item_count = 0;
                self.state.image_count = 0;
                self.state.busy = false;
                self.state.status = UiText::with("folder_error", [error.clone()]);
                tracing::error!(
                    target: "kogaview::scan",
                    folder = %result.folder.display(),
                    %error,
                    "folder scan failed"
                );
            }
        }
        true
    }

    fn sync_viewer(&mut self) {
        let images = self
            .state
            .entries
            .iter()
            .filter(|entry| entry.is_image)
            .map(|entry| entry.path.clone())
            .collect::<Vec<_>>();
        self.state.viewer_images = images.clone();

        let candidate = self
            .pending_viewer
            .take()
            .or_else(|| self.state.viewer_path.clone())
            .filter(|path| images.contains(path));

        if let Some(path) = candidate {
            let index = images.iter().position(|image| image == &path);
            self.state.viewer_index = index;
            self.state.viewer_path = index.map(|index| images[index].clone());
        } else if self.state.workspace == Workspace::Viewer && !images.is_empty() {
            self.state.viewer_index = Some(0);
            self.state.viewer_path = Some(images[0].clone());
        } else {
            self.state.viewer_index = None;
            self.state.viewer_path = None;
        }
    }

    fn set_selection(&mut self, paths: Vec<String>) {
        self.state.selection = paths;
        self.state.selection_info = self.build_selection_info();
    }

    fn build_selection_info(&self) -> Option<SelectionInfo> {
        let path = self.state.selection.first()?;
        let path = Path::new(path);
        let metadata = std::fs::metadata(path).ok()?;
        let is_dir = metadata.is_dir();
        let (width, height) = if !is_dir && ops::is_image_path(path) {
            match ops::image_dimensions(path) {
                Some((width, height)) => (Some(width), Some(height)),
                None => (None, None),
            }
        } else {
            (None, None)
        };
        Some(SelectionInfo {
            path: path.to_string_lossy().into_owned(),
            name: path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.to_string_lossy().into_owned()),
            kind: if is_dir {
                "folder".to_owned()
            } else {
                ops::kind_label(path)
            },
            is_image: !is_dir && ops::is_image_path(path),
            size: metadata.len(),
            modified: metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs())
                .unwrap_or_default(),
            width,
            height,
        })
    }

    fn ensure_viewer_selection(&mut self) {
        if self.state.viewer_images.is_empty() {
            return;
        }
        let selected = self
            .state
            .selection
            .iter()
            .find(|path| self.state.viewer_images.contains(path))
            .cloned();
        if let Some(path) = selected {
            if let Some(index) = self
                .state
                .viewer_images
                .iter()
                .position(|image| image == &path)
            {
                self.state.viewer_index = Some(index);
                self.state.viewer_path = Some(path);
            }
        } else if self.state.viewer_path.is_none() {
            self.state.viewer_index = Some(0);
            self.state.viewer_path = Some(self.state.viewer_images[0].clone());
        }
    }

    fn open_viewer_image(&mut self, path: &str) -> Result<Option<UiText>, ProtocolError> {
        let index = self
            .state
            .viewer_images
            .iter()
            .position(|image| image == path)
            .ok_or_else(|| ProtocolError::line("not_found", UiText::new("not_in_this_folder")))?;
        self.state.viewer_index = Some(index);
        self.state.viewer_path = Some(path.to_owned());
        self.state.workspace = Workspace::Viewer;
        self.set_selection(vec![path.to_owned()]);
        Ok(None)
    }

    fn step_viewer(&mut self, delta: isize) -> Result<Option<UiText>, ProtocolError> {
        if self.state.viewer_images.is_empty() {
            return Err(ProtocolError::line(
                "no_images",
                UiText::new("no_images_here"),
            ));
        }
        let length = self.state.viewer_images.len() as isize;
        let current = self.state.viewer_index.unwrap_or(0) as isize;
        let next = (current + delta).rem_euclid(length) as usize;
        let path = self.state.viewer_images[next].clone();
        self.state.viewer_index = Some(next);
        self.state.viewer_path = Some(path.clone());
        self.state.workspace = Workspace::Viewer;
        self.set_selection(vec![path]);
        Ok(None)
    }

    /// Load a source image into the Editor as a working document.
    ///
    /// The file is only read. Decoding and the first preview run on a worker
    /// thread, so a large photo does not stall the window; the UI publishes a
    /// spinner and the name until `apply_editor_task` installs the document.
    fn open_editor(&mut self, path: &str) -> Result<Option<UiText>, ProtocolError> {
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
        let preview_dir = self.editor_preview_dir()?;
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
            redo_count: 0,
            preview_path: None,
            preview_revision: generation,
            preview_modified: 0,
            preview_size: 0,
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

    fn editor_apply(&mut self, operation: EditOperation) -> Result<Option<UiText>, ProtocolError> {
        let Some(document) = &mut self.editor else {
            return Err(no_editor_document());
        };
        let changed = document.apply(operation.clone()).map_err(invalid_edit)?;
        if !changed {
            return Ok(Some(UiText::new("edit_noop")));
        }
        self.clear_editor_draft();
        self.schedule_editor_preview();
        self.refresh_editor_status();
        // The same line the History panel records, so the toast and the history
        // cannot word one operation two ways.
        Ok(Some(operation.label()))
    }

    /// Render what an edit *would* produce, without applying it.
    ///
    /// The draft is a separate preview file and its own generation, so the
    /// canvas can show the result while the document, the history and the save
    /// target stay exactly as they were. Applying the matching operation
    /// afterwards is what records the step; dismissing the tool or applying
    /// anything else drops the draft file.
    fn editor_preview(
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

    fn editor_resize_preview(
        &mut self,
        width: u32,
        height: u32,
        fill: Option<[u8; 3]>,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.editor_preview(
            EditOperation::Resize {
                width,
                height,
                fill,
            },
            PreviewKind::Resize,
        )
    }

    fn editor_crop_preview(
        &mut self,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) -> Result<Option<UiText>, ProtocolError> {
        self.editor_preview(
            EditOperation::Crop {
                x,
                y,
                width,
                height,
            },
            PreviewKind::Crop,
        )
    }

    /// Drop the live-preview draft: remove its file and make any worker result
    /// for it stale before the next state is published.
    fn clear_editor_draft(&mut self) {
        self.editor_draft_generation += 1;
        self.editor_draft_size = (0, 0);
        self.editor_draft_kind.clear();
        if let Some(path) = self.editor_draft_path.take() {
            let _ = std::fs::remove_file(path);
        }
    }

    fn editor_step(&mut self, undo: bool) -> Result<Option<UiText>, ProtocolError> {
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

    fn editor_reset(&mut self) -> Result<Option<UiText>, ProtocolError> {
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
    fn editor_save(&mut self, path: Option<&str>) -> Result<Option<UiText>, ProtocolError> {
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
        let pixels = document.pixels();
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
            let result = editor::save_pixels(&thread_source, &pixels, &destination);
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
    fn editor_export(
        &mut self,
        path: &str,
        quality: Option<u8>,
        metadata: bool,
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
        self.state.status = UiText::with("exporting", [label.clone()]);
        self.publish_editor();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let result = editor::export_pixels(&source, &pixels, &destination, quality, metadata);
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
    fn apply_export_result(&mut self, result: EditorExportResult) -> bool {
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
    fn apply_save_result(&mut self, result: EditorSaveResult) -> bool {
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

    /// Carrying the Viewer's photograph into an empty Editor. Only when there
    /// is nothing open: an in-progress document is never replaced by a
    /// workspace switch.
    fn link_viewer_into_editor(&mut self) {
        // A document open in the Editor wins over the Viewer: a switch must not
        // throw away in-progress work, saved or not.
        if self.editor.is_some() {
            return;
        }
        let path = match self.state.viewer_path.clone() {
            Some(path) => path,
            // A freshly opened folder has no viewer path until the Viewer was
            // entered; the selection is what a switch from the Browser carries.
            None => match self.state.selection.first().cloned() {
                Some(path) if ops::is_image_path(Path::new(&path)) => path,
                _ => return,
            },
        };
        if !editor::has_decoder(Path::new(&path)) {
            self.state.status = UiText::with("no_decoder", [path]);
            return;
        }
        let opened = self.open_editor(&path);
        tracing::debug!(
            target: "kogaview::editor",
            %path,
            ok = opened.is_ok(),
            "linked the viewer image into the editor"
        );
    }

    fn editor_close(&mut self) -> Result<Option<UiText>, ProtocolError> {
        if self.editor.is_none() {
            return Err(no_editor_document());
        }
        // Bump the generation first: a worker still decoding or rendering now
        // belongs to a document that no longer exists.
        self.editor_generation += 1;
        self.editor = None;
        self.editor_rendering = false;
        self.state.editor = None;
        self.state.busy = false;
        self.clear_editor_draft();
        if let Some(preview) = self.editor_preview_path.take() {
            let _ = std::fs::remove_file(preview);
        }
        self.editor_preview_stamp = None;
        self.state.status = UiText::new("editor_closed");
        Ok(Some(UiText::new("editor_closed")))
    }

    /// Republish the Editor projection after a synchronous edit, then ask a
    /// worker for a preview. The previous preview stays on screen (marked
    /// `rendering`) until the new file exists, so QML never loads a missing
    /// image and flashes empty.
    fn schedule_editor_preview(&mut self) {
        let Some(document) = &self.editor else {
            return;
        };
        self.editor_generation += 1;
        let generation = self.editor_generation;
        let pixels = document.pixels();
        self.editor_rendering = true;
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
    fn refresh_editor_status(&mut self) {
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
    fn publish_editor(&mut self) {
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
        self.state.editor = Some(EditorState {
            path,
            name,
            width,
            height,
            can_undo: document.can_undo(),
            can_redo: document.can_redo(),
            modified: document.can_undo(),
            history: document.history(),
            redo_count: document.redo_count(),
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
    fn publish_opening_preview(
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
        self.state.editor = Some(EditorState {
            name,
            width,
            height,
            can_undo: false,
            can_redo: false,
            modified: false,
            history: Vec::new(),
            redo_count: 0,
            preview_path: Some(preview.to_string_lossy().into_owned()),
            preview_revision: generation,
            preview_modified,
            preview_size,
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

    fn editor_preview_dir(&self) -> Result<PathBuf, ProtocolError> {
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
    fn apply_editor_task(&mut self, task: EditorTask) -> bool {
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
                self.editor = Some(document);
                self.editor_rendering = false;
                self.state.busy = false;
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

    fn install_editor_preview(&mut self, path: &Path, generation: u64) {
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

    fn set_theme(&mut self, theme: Theme) {
        self.config.theme = theme;
        self.state.theme = theme;
        self.save_config();
    }

    fn new_folder(&mut self, parent: PathBuf, name: &str) -> Result<Option<UiText>, ProtocolError> {
        let parent = ops::normalize_path(&parent);
        let created = ops::create_folder(&parent, name)
            .map_err(|error| ProtocolError::new("io_error", error))?;
        self.state.tree_revision += 1;
        self.refresh_current();
        Ok(Some(UiText::with(
            "created",
            [created.display().to_string()],
        )))
    }

    fn transfer(
        &mut self,
        paths: Vec<String>,
        destination: PathBuf,
        move_paths: bool,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.state.busy {
            return Err(ProtocolError::line(
                "busy",
                UiText::new("operation_in_progress"),
            ));
        }
        let destination = ops::normalize_path(&destination);
        if !destination.is_dir() {
            return Err(ProtocolError::line(
                "not_a_directory",
                UiText::with("not_a_folder", [destination.display().to_string()]),
            ));
        }

        let sources = paths
            .into_iter()
            .map(PathBuf::from)
            .filter(|path| path.exists())
            .collect::<Vec<_>>();
        if sources.is_empty() {
            return Err(ProtocolError::line(
                "not_found",
                UiText::new("no_source_files"),
            ));
        }
        for source in &sources {
            // `canonicalize` only here: folding a symlink lets a folder be
            // copied into itself through a link to it.
            let resolved = source.canonicalize().unwrap_or_else(|_| source.clone());
            if resolved.is_dir() && (destination.starts_with(&resolved) || resolved == destination)
            {
                return Err(ProtocolError::line(
                    "invalid_destination",
                    UiText::with("copy_into_itself", [resolved.display().to_string()]),
                ));
            }
        }

        let count = sources.len();
        let moving = move_paths;
        self.start_operation(
            if moving {
                UiText::with("moving", [count.to_string()])
            } else {
                UiText::with("copying", [count.to_string()])
            },
            move |cancel| {
                let mut failures = Vec::new();
                let mut moved = 0;
                for source in &sources {
                    if cancel.load(Ordering::SeqCst) {
                        return OpResult {
                            ok: false,
                            message: UiText::with("cancelled_after", [moved.to_string()]),
                            refresh: true,
                        };
                    }
                    let result = if moving {
                        ops::move_path(source, &destination)
                    } else {
                        ops::copy_path(source, &destination)
                    };
                    match result {
                        Ok(_) => moved += 1,
                        Err(error) => failures.push(error),
                    }
                }
                let line = if failures.is_empty() {
                    if moving {
                        UiText::with(
                            "moved_to",
                            [moved.to_string(), destination.display().to_string()],
                        )
                    } else {
                        UiText::with(
                            "copied_to",
                            [moved.to_string(), destination.display().to_string()],
                        )
                    }
                } else if moving {
                    UiText::with(
                        "move_failed",
                        [
                            moved.to_string(),
                            failures.len().to_string(),
                            failures[0].clone(),
                        ],
                    )
                } else {
                    UiText::with(
                        "copy_failed",
                        [
                            moved.to_string(),
                            failures.len().to_string(),
                            failures[0].clone(),
                        ],
                    )
                };
                OpResult {
                    ok: failures.is_empty(),
                    message: line,
                    refresh: true,
                }
            },
        );
        Ok(Some(UiText::with(
            if move_paths { "moving" } else { "copying" },
            [count.to_string()],
        )))
    }

    fn trash_paths(&mut self, paths: Vec<String>) -> Result<Option<UiText>, ProtocolError> {
        let paths = self.validated_deletion_paths(paths)?;
        let count = paths.len();
        self.start_operation(
            UiText::with("moving_to_trash", [count.to_string()]),
            move |cancel| {
                if cancel.load(Ordering::SeqCst) {
                    return OpResult {
                        ok: false,
                        message: UiText::new("cancelled"),
                        refresh: true,
                    };
                }
                match ops::trash_paths(&paths) {
                    Ok(()) => OpResult {
                        ok: true,
                        message: UiText::with("moved_to_trash", [count.to_string()]),
                        refresh: true,
                    },
                    Err(error) => OpResult {
                        ok: false,
                        message: UiText::with("trash_failed", [error]),
                        refresh: false,
                    },
                }
            },
        );
        Ok(Some(UiText::with("moving_to_trash", [count.to_string()])))
    }

    fn delete_paths(&mut self, paths: Vec<String>) -> Result<Option<UiText>, ProtocolError> {
        let paths = self.validated_deletion_paths(paths)?;
        let count = paths.len();
        self.start_operation(
            UiText::with("deleting_permanently", [count.to_string()]),
            move |cancel| {
                let mut failures = Vec::new();
                let mut deleted = 0;
                for path in &paths {
                    if cancel.load(Ordering::SeqCst) {
                        return OpResult {
                            ok: false,
                            message: UiText::with("cancelled_after_delete", [deleted.to_string()]),
                            refresh: true,
                        };
                    }
                    match ops::remove_path(path) {
                        Ok(()) => deleted += 1,
                        Err(error) => failures.push(error),
                    }
                }
                OpResult {
                    ok: failures.is_empty(),
                    message: if failures.is_empty() {
                        UiText::with("deleted_permanently", [deleted.to_string()])
                    } else {
                        UiText::with(
                            "delete_failed",
                            [
                                deleted.to_string(),
                                failures.len().to_string(),
                                failures[0].clone(),
                            ],
                        )
                    },
                    refresh: true,
                }
            },
        );
        Ok(Some(UiText::with(
            "deleting_permanently",
            [count.to_string()],
        )))
    }

    fn validated_deletion_paths(&self, paths: Vec<String>) -> Result<Vec<PathBuf>, ProtocolError> {
        if self.state.busy {
            return Err(ProtocolError::line(
                "busy",
                UiText::new("operation_in_progress"),
            ));
        }
        let mut result = Vec::new();
        for raw in paths {
            let path = PathBuf::from(raw);
            if !path.exists() {
                continue;
            }
            ops::safe_for_deletion(&path)
                .map_err(|line| ProtocolError::line("invalid_path", line))?;
            result.push(path);
        }
        if result.is_empty() {
            return Err(ProtocolError::line(
                "not_found",
                UiText::new("no_existing_paths"),
            ));
        }
        Ok(result)
    }

    fn start_operation<F>(&mut self, status: UiText, work: F)
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

    fn add_favorite(&mut self, path: PathBuf) -> Result<Option<UiText>, ProtocolError> {
        let path = ops::normalize_path(&path);
        if !path.is_dir() {
            return Err(ProtocolError::line(
                "not_a_directory",
                UiText::new("quick_access_needs_a_folder"),
            ));
        }
        let label = path.to_string_lossy().into_owned();
        if !self.config.quick_access.contains(&label) {
            self.config.quick_access.push(label);
            self.state.favorites = self.config.quick_access.clone();
            self.save_config();
        }
        Ok(Some(UiText::with(
            "quick_access_added",
            [path.display().to_string()],
        )))
    }

    fn remove_favorite(&mut self, path: &str) -> Result<Option<UiText>, ProtocolError> {
        let before = self.config.quick_access.len();
        self.config.quick_access.retain(|favorite| favorite != path);
        if self.config.quick_access.len() == before {
            return Err(ProtocolError::line(
                "not_found",
                UiText::new("not_in_quick_access"),
            ));
        }
        self.state.favorites = self.config.quick_access.clone();
        self.save_config();
        Ok(Some(UiText::new("quick_access_removed")))
    }

    fn move_favorite(
        &mut self,
        path: &str,
        direction: MoveDirection,
    ) -> Result<Option<UiText>, ProtocolError> {
        let Some(index) = self
            .config
            .quick_access
            .iter()
            .position(|favorite| favorite == path)
        else {
            return Err(ProtocolError::line(
                "not_found",
                UiText::new("not_in_quick_access"),
            ));
        };
        let target = match direction {
            MoveDirection::Up if index > 0 => index - 1,
            MoveDirection::Down if index + 1 < self.config.quick_access.len() => index + 1,
            _ => return Ok(None),
        };
        self.config.quick_access.swap(index, target);
        self.state.favorites = self.config.quick_access.clone();
        self.save_config();
        Ok(None)
    }

    /// Record the two explorer folders, honouring `remember_last_folder`.
    ///
    /// When the user turned remembering off, the folders are cleared instead of
    /// written, so the next start opens nothing and the file never keeps a path
    /// the user asked not to keep. The write is skipped when nothing changed.
    fn save_explorer_folders(&mut self, root: String, folder: String) {
        if !self.config.remember_last_folder {
            let root = self.config.tree_root.take();
            let folder = self.config.last_folder.take();
            if root.is_some() || folder.is_some() {
                self.save_config();
            }
            return;
        }
        let changed = self.config.tree_root.as_deref() != Some(root.as_str())
            || self.config.last_folder.as_deref() != Some(folder.as_str());
        self.config.tree_root = Some(root);
        self.config.last_folder = Some(folder);
        if changed {
            self.save_config();
        }
    }

    /// Make the configuration agree with what this session is showing, so a
    /// later start restores it — or forget it, when the user turned that off.
    fn remember_explorer_folders(&mut self) {
        let root = self.state.root_folder.clone();
        let folder = self.state.current_folder.clone();
        match (root, folder) {
            (Some(root), Some(folder)) => self.save_explorer_folders(root, folder),
            _ => {
                if !self.config.remember_last_folder {
                    self.config.tree_root = None;
                    self.config.last_folder = None;
                }
            }
        }
    }

    fn save_config(&mut self) {
        if let Err(error) = self.config.save(&self.config_path) {
            tracing::error!(
                target: "kogaview::config",
                path = %self.config_path.display(),
                %error,
                "cannot save configuration"
            );
            self.state.status = UiText::with("config_save_failed", [error.to_string()]);
        }
    }

    #[allow(dead_code)]
    pub fn paths(&self) -> &AppPaths {
        &self.paths
    }

    #[allow(dead_code)]
    pub fn state_value(&self) -> Value {
        serde_json::to_value(&self.state).unwrap_or(Value::Null)
    }
}

/// Does `path` live inside `root`, or is it `root` itself?
fn is_within(root: &Path, path: &Path) -> bool {
    // `Path::starts_with` compares whole components, so `/a/bc` is not inside
    // `/a/b`; a plain string prefix check would get that wrong.
    path == root || path.starts_with(root)
}

/// The error every editor command returns when no document is loaded.
/// A rejected edit: the validator names the cause as a line, and the journal
/// gets a sentence rather than a code and its arguments in a row.
///
/// The two codes whose arguments would read as numbers with no meaning keep the
/// sentence they had before the rejection became a line; every other validator
/// message already reads as one once its underscores are opened (`crop size
/// empty`, `invalid rotation 360`). The interface is not affected: it draws the
/// `line`, never this message.
fn invalid_edit(line: UiText) -> ProtocolError {
    let numbers: Vec<&str> = line.args.iter().map(String::as_str).collect();
    let message = match (line.code.as_str(), numbers.as_slice()) {
        ("crop_does_not_fit", [width, height, x, y, doc_w, doc_h]) => {
            format!("crop {width} × {height} at {x},{y} does not fit the {doc_w} × {doc_h} image")
        }
        ("resize_too_large", [width, height, limit]) => {
            format!("resize to {width} × {height} is larger than the {limit} pixel limit")
        }
        _ => line.english(),
    };
    ProtocolError::with_line("invalid_edit", message, line)
}

fn no_editor_document() -> ProtocolError {
    ProtocolError::line("no_document", UiText::new("needs_a_document"))
}

/// The explorer root to use once the user is looking at `folder`.
///
/// The tree follows the file list only when the folder leaves the root's
/// subtree. An open of something already inside the tree (a quick-access entry
/// pointing at a child, a launcher argument) keeps the tree where it is, so
/// browsing one tree never re-roots it, while a breadcrumb to an ancestor or
/// "up" past the root does.
fn root_after_navigation(current_root: Option<&Path>, folder: &Path) -> PathBuf {
    match current_root {
        Some(root) if is_within(root, folder) => root.to_path_buf(),
        _ => folder.to_path_buf(),
    }
}

/// Resolve the two folders saved in the configuration into the pair to restore.
///
/// Each value is validated on its own, so a folder that disappeared does not
/// cost the user the other one: whatever is still on disk wins and the second
/// value is derived from it.
fn restored_folders(
    saved_root: Option<&str>,
    saved_folder: Option<&str>,
    is_dir: impl Fn(&Path) -> bool,
) -> (Option<PathBuf>, Option<PathBuf>) {
    let root = saved_root.map(PathBuf::from).filter(|path| is_dir(path));
    let folder = saved_folder.map(PathBuf::from).filter(|path| is_dir(path));
    match (root, folder) {
        (Some(root), Some(folder)) => {
            // Never restore an open folder outside the tree: the tree would
            // show nothing and the first click in it would re-root anyway.
            if is_within(&root, &folder) {
                (Some(root), Some(folder))
            } else {
                (Some(folder.clone()), Some(folder))
            }
        }
        (Some(root), None) => (Some(root.clone()), Some(root)),
        (None, Some(folder)) => (Some(folder.clone()), Some(folder)),
        (None, None) => (None, None),
    }
}

fn breadcrumbs(path: &Path) -> Vec<Crumb> {
    let mut result = Vec::new();
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component);
        let name = match component {
            Component::RootDir => "/".to_owned(),
            Component::Prefix(prefix) => prefix.as_os_str().to_string_lossy().into_owned(),
            _ => component.as_os_str().to_string_lossy().into_owned(),
        };
        result.push(Crumb {
            name,
            path: current.to_string_lossy().into_owned(),
        });
    }
    if result.is_empty() {
        result.push(Crumb {
            name: path.to_string_lossy().into_owned(),
            path: path.to_string_lossy().into_owned(),
        });
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-core-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Remove a test directory, retrying while a worker still holds a file in it.
    ///
    /// The Editor renders previews into `<base>/cache/editor` on a worker
    /// thread, so a `remove_dir_all` can meet a write that lands between its
    /// enumeration and its last unlink — the call then answers "Directory not
    /// empty" and the test fails on teardown, not on behaviour. Retrying is the
    /// honest fix: nothing here asserts on how fast a preview is written.
    fn remove_tree(path: &Path) {
        for _ in 0..50 {
            match std::fs::remove_dir_all(path) {
                Ok(()) => return,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(20)),
            }
        }
        let _ = std::fs::remove_dir_all(path);
    }

    /// Wait for the background folder scan to land, the way the UI's poll timer
    /// does. Returns false if it never does.
    fn settle_scan(core: &mut Core) -> bool {
        for _ in 0..2000 {
            if core.poll() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        false
    }

    fn select_json(path: &Path) -> String {
        format!(
            r#"{{"id":"select-1","protocol":1,"command":{{"type":"select","paths":["{}"]}}}}"#,
            path.display()
        )
    }

    /// The point of the split: the only part of the snapshot that grows with the
    /// folder — the listing and the filmstrip's image paths — is published under
    /// its own epoch, so a select does not pay to re-serialise a thousand
    /// entries, and it is still shipped exactly when the listing changes.
    #[test]
    fn the_folder_listing_travels_apart_from_the_metadata() {
        let base = temp_dir();
        let folder = base.join("Photos");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("one.png"), b"png").unwrap();
        std::fs::write(folder.join("two.png"), b"png").unwrap();
        let runtime = base.join("runtime");

        let mut core = Core::for_test(&runtime);
        // With the scan in flight — even with two images, the worker thread has
        // probably not answered yet — a select must not move the epoch: the
        // window would then re-parse a listing it already has, and would take the
        // empty one if the select came between the clear and the landing.
        core.open_folder(folder.clone(), true).unwrap();
        let while_loading = core.listing_epoch();
        // The open itself cleared the previous listing, which is epoch movement
        // of its own; the select must leave that number alone.
        assert!(while_loading > 0, "the open did not clear the listing");
        core.dispatch(&select_json(&folder.join("one.png")));
        assert_eq!(
            core.listing_epoch(),
            while_loading,
            "a select while the folder was loading re-published the listing"
        );
        assert!(settle_scan(&mut core), "the folder scan never landed");
        // And the landing itself is epoch movement: it is the only signal the
        // window gets that its entries are stale.
        assert!(
            core.listing_epoch() > while_loading,
            "the scan replaced the listing without moving the epoch"
        );
        let last = core.listing_epoch();
        let listing: Value = serde_json::from_str(&core.folder_json()).unwrap();
        assert_eq!(listing["entries"].as_array().unwrap().len(), 2);
        assert_eq!(listing["viewerImages"].as_array().unwrap().len(), 2);
        let meta: Value = serde_json::from_str(&core.meta_json()).unwrap();
        assert_eq!(meta["itemCount"], 2);
        // The metadata alone does not carry the listing at all — not even an
        // empty array, which would still be a field the window had to overwrite.
        assert!(
            meta.get("entries").is_none(),
            "the metadata carried the listing"
        );
        assert!(meta.get("viewerImages").is_none());
        // …so a select, which cannot change the listing, leaves the epoch alone.
        core.dispatch(&select_json(&folder.join("two.png")));
        let after_select: Value = serde_json::from_str(&core.meta_json()).unwrap();
        assert_eq!(
            after_select["selection"].as_array().unwrap(),
            &vec![Value::from(folder.join("two.png").to_string_lossy())]
        );
        assert_eq!(after_select["selectionInfo"]["name"], "two.png");
        assert_eq!(
            core.listing_epoch(),
            last,
            "a select re-published the listing"
        );

        // …while navigating elsewhere does ship the new one.
        let other = base.join("Other");
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(other.join("three.png"), b"png").unwrap();
        core.open_folder(other.clone(), false).unwrap();
        assert!(settle_scan(&mut core), "the folder scan never landed");
        assert!(
            core.listing_epoch() > last,
            "navigation did not move the epoch"
        );
        let listing: Value = serde_json::from_str(&core.folder_json()).unwrap();
        assert_eq!(listing["entries"][0]["name"], "three.png");
        assert_eq!(
            listing["viewerImages"][0],
            Value::from(other.join("three.png").to_string_lossy().as_ref())
        );

        // Snapshot and the two halves describe the same state field for field.
        let full: Value = serde_json::from_str(&core.snapshot_json()).unwrap();
        let meta: Value = serde_json::from_str(&core.meta_json()).unwrap();
        let listing: Value = serde_json::from_str(&core.folder_json()).unwrap();
        assert_eq!(full["entries"], listing["entries"]);
        assert_eq!(full["viewerImages"], listing["viewerImages"]);
        let mut merged = meta.as_object().unwrap().clone();
        merged.insert("entries".to_owned(), listing["entries"].clone());
        merged.insert("viewerImages".to_owned(), listing["viewerImages"].clone());
        assert_eq!(
            Value::Object(merged),
            full,
            "the metadata and the listing did not add up to the snapshot"
        );

        remove_tree(&base);
    }

    #[test]
    fn breadcrumbs_include_the_root() {
        let crumbs = breadcrumbs(Path::new("/home/user/Pictures"));
        assert_eq!(crumbs[0].name, "/");
        assert_eq!(crumbs[0].path, "/");
        assert_eq!(crumbs.last().unwrap().name, "Pictures");
        assert_eq!(crumbs.last().unwrap().path, "/home/user/Pictures");
    }

    #[test]
    fn folder_names_are_validated_before_creation() {
        let dir = temp_dir();
        let error = ops::create_folder(&dir, "bad/name").unwrap_err();
        assert!(error.contains("separator"));
        let created = ops::create_folder(&dir, "New folder").unwrap();
        assert!(created.is_dir());
        remove_tree(&dir);
    }

    // ------------------------------------------------- explorer root vs list

    /// The tree keeps its root while the folder stays inside it, so browsing
    /// one tree never re-roots it.
    #[test]
    fn the_root_survives_navigation_inside_the_tree() {
        let root = Path::new("/home/user/Pictures");
        for folder in ["/home/user/Pictures", "/home/user/Pictures/Child"] {
            assert_eq!(
                root_after_navigation(Some(root), Path::new(folder)),
                root,
                "{} re-rooted the tree",
                folder
            );
        }
    }

    /// A sibling whose name merely starts with the root's name is *outside* it.
    #[test]
    fn a_sibling_with_a_common_prefix_is_outside_the_tree() {
        assert!(!is_within(
            Path::new("/home/user/Pictures"),
            Path::new("/home/user/Pictures-old")
        ));
        assert_eq!(
            root_after_navigation(
                Some(Path::new("/home/user/Pictures")),
                Path::new("/Pictures-old")
            ),
            PathBuf::from("/Pictures-old")
        );
    }

    /// Leaving the subtree — breadcrumbs to an ancestor, "up" past the root —
    /// moves the tree with the list.
    #[test]
    fn leaving_the_subtree_moves_the_root() {
        let root = Path::new("/home/user/Pictures");
        for folder in ["/home/user", "/", "/mnt/photos"] {
            assert_eq!(
                root_after_navigation(Some(root), Path::new(folder)),
                PathBuf::from(folder)
            );
        }
        // Nothing open yet: the first folder becomes the root.
        assert_eq!(
            root_after_navigation(None, Path::new("/tmp")),
            PathBuf::from("/tmp")
        );
    }

    /// The two saved values come back as two values: the sidebar keeps the
    /// parent while the list shows the child.
    #[test]
    fn both_saved_folders_are_restored_separately() {
        let (root, folder) = restored_folders(
            Some("/home/user/Pictures"),
            Some("/home/user/Pictures/Child"),
            |_| true,
        );
        assert_eq!(root.unwrap(), PathBuf::from("/home/user/Pictures"));
        assert_eq!(folder.unwrap(), PathBuf::from("/home/user/Pictures/Child"));
    }

    /// One missing folder must not cost the other one.
    #[test]
    fn a_missing_folder_is_derived_from_the_surviving_one() {
        let existing = ["/home/user/Pictures"];

        // Only the tree root survived: the list opens it.
        let (root, folder) = restored_folders(Some("/gone"), Some("/home/user/Pictures"), |path| {
            existing.contains(&path.to_string_lossy().as_ref())
        });
        assert_eq!(root.unwrap(), PathBuf::from("/home/user/Pictures"));
        assert_eq!(folder.unwrap(), PathBuf::from("/home/user/Pictures"));

        // Only the open folder survived: it becomes the root.
        let (root, folder) = restored_folders(Some("/home/user/Pictures"), Some("/gone"), |path| {
            existing.contains(&path.to_string_lossy().as_ref())
        });
        assert_eq!(root.unwrap(), PathBuf::from("/home/user/Pictures"));
        assert_eq!(folder.unwrap(), PathBuf::from("/home/user/Pictures"));
    }

    /// A config that would restore the list outside the tree is repaired instead
    /// of showing an empty tree.
    #[test]
    fn a_folder_outside_the_saved_root_is_repaired() {
        let (root, folder) = restored_folders(Some("/home/user"), Some("/mnt/photos"), |_| true);
        assert_eq!(root.unwrap(), PathBuf::from("/mnt/photos"));
        assert_eq!(folder.unwrap(), PathBuf::from("/mnt/photos"));
    }

    /// Drive the real commands: the two values must survive as two values, both
    /// in the state the UI renders and in the configuration written to disk.
    #[test]
    fn the_root_and_the_open_folder_are_saved_apart() {
        let base = temp_dir();
        let root = base.join("Pictures");
        let child = root.join("Child");
        std::fs::create_dir_all(&child).unwrap();
        let runtime = base.join("runtime");

        let grandchild = child.join("Grand");
        std::fs::create_dir_all(&grandchild).unwrap();

        let mut core = Core::for_test(&runtime);
        core.open_folder(root.clone(), true).unwrap();
        // An explicit open of a folder that is already inside the tree — quick
        // access, "Open folder", a launcher argument — keeps the tree root.
        core.open_folder(child.clone(), true).unwrap();
        // A plain navigation (`Navigate`: tree click, grid double-click,
        // breadcrumb) inside the tree changes the list only.
        core.open_folder(grandchild.clone(), false).unwrap();

        let root_label = root.to_string_lossy().into_owned();
        let grandchild_label = grandchild.to_string_lossy().into_owned();
        assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));
        assert_eq!(
            core.state.current_folder.as_deref(),
            Some(grandchild_label.as_str())
        );
        assert_eq!(
            core.saved_folders(),
            (Some(root_label), Some(grandchild_label)),
            "the sidebar root and the open folder were written as one value"
        );

        remove_tree(&base);
    }

    /// Walking out of the tree ("up" past the root, a breadcrumb to an ancestor)
    /// takes the tree with it, and that move is persisted too.
    #[test]
    fn walking_out_of_the_tree_re_roots_the_saved_value() {
        let base = temp_dir();
        let root = base.join("Pictures");
        let child = root.join("Child");
        std::fs::create_dir_all(&child).unwrap();
        let runtime = base.join("runtime");

        let mut core = Core::for_test(&runtime);
        core.open_folder(child.clone(), true).unwrap();
        assert_eq!(
            core.state.root_folder.as_deref(),
            Some(child.to_string_lossy().as_ref())
        );

        core.open_folder(base.clone(), false).unwrap();
        let base_label = base.to_string_lossy().into_owned();
        assert_eq!(core.state.root_folder.as_deref(), Some(base_label.as_str()));
        assert_eq!(core.saved_folders().0, Some(base_label));

        remove_tree(&base);
    }

    /// A restored session comes back with the tree above the open folder, not
    /// with both collapsed into the deeper folder (the bug this fixes).
    #[test]
    fn restoring_a_session_keeps_the_tree_above_the_open_folder() {
        let base = temp_dir();
        let root = base.join("Pictures");
        let child = root.join("Child");
        std::fs::create_dir_all(&child).unwrap();
        let runtime = base.join("runtime");

        {
            let mut core = Core::for_test(&runtime);
            core.config.tree_root = Some(root.to_string_lossy().into_owned());
            core.config.last_folder = Some(child.to_string_lossy().into_owned());
            core.save_config();
        }

        let mut core = Core::for_test(&runtime);
        core.restore_last_session();

        let root_label = root.to_string_lossy().into_owned();
        let child_label = child.to_string_lossy().into_owned();
        assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));
        assert_eq!(
            core.state.current_folder.as_deref(),
            Some(child_label.as_str())
        );

        remove_tree(&base);
    }

    /// Only the open folder was saved (or only the root): the other value is
    /// derived instead of leaving the window half empty.
    #[test]
    fn restoring_derives_the_value_that_is_missing() {
        let base = temp_dir();
        let child = base.join("Pictures/Child");
        std::fs::create_dir_all(&child).unwrap();
        let runtime = base.join("runtime");
        let child_label = child.to_string_lossy().into_owned();

        {
            let mut core = Core::for_test(&runtime);
            core.config.last_folder = Some(child_label.clone());
            core.save_config();
        }
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert_eq!(
            core.state.root_folder.as_deref(),
            Some(child_label.as_str())
        );
        assert_eq!(
            core.state.current_folder.as_deref(),
            Some(child_label.as_str())
        );

        // Now save a tree root only.
        std::fs::remove_file(runtime.join("config.json")).unwrap();
        {
            let mut core = Core::for_test(&runtime);
            core.config.tree_root = Some(child_label.clone());
            core.save_config();
        }
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert_eq!(
            core.state.root_folder.as_deref(),
            Some(child_label.as_str())
        );
        assert_eq!(
            core.state.current_folder.as_deref(),
            Some(child_label.as_str())
        );

        remove_tree(&base);
    }

    /// Folders that no longer exist open nothing, exactly like a first run.
    #[test]
    fn restoring_deleted_folders_opens_nothing() {
        let base = temp_dir();
        let runtime = base.join("runtime");
        {
            let mut core = Core::for_test(&runtime);
            core.config.tree_root = Some("/definitely/gone".to_owned());
            core.config.last_folder = Some("/also/gone".to_owned());
            core.save_config();
        }
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert!(core.state.root_folder.is_none());
        assert!(core.state.current_folder.is_none());
        remove_tree(&base);
    }

    #[test]
    fn nothing_opens_when_no_saved_folder_survives() {
        let (root, folder) = restored_folders(Some("/gone"), Some("/gone-too"), |_| false);
        assert!(root.is_none());
        assert!(folder.is_none());
        let (root, folder) = restored_folders(None, None, |_| true);
        assert!(root.is_none() && folder.is_none());
    }

    /// `set_settings` is what the Settings dialog sends. It has to change what
    /// the *next* run restores, not only the file: that is the state delta the
    /// user selected the checkbox for.
    #[test]
    fn settings_decide_whether_the_folders_come_back() {
        let base = temp_dir();
        let root = base.join("Pictures");
        let child = root.join("Child");
        std::fs::create_dir_all(&child).unwrap();
        let runtime = base.join("runtime");
        let root_label = root.to_string_lossy().into_owned();
        let child_label = child.to_string_lossy().into_owned();

        let settings = |remember: bool| {
            format!(
                r#"{{"id":"settings-1","protocol":1,"command":{{"type":"set_settings",
                    "theme":"dark","remember_last_folder":{remember},
                    "background_thumbnails":true}}}}"#
            )
        };

        {
            let mut core = Core::for_test(&runtime);
            core.open_folder(root.clone(), true).unwrap();
            core.open_folder(child.clone(), true).unwrap();
            assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));
            assert_eq!(
                core.saved_folders(),
                (Some(root_label.clone()), Some(child_label.clone()))
            );
        }

        // Remembered: the folder comes back, as before.
        {
            let mut core = Core::for_test(&runtime);
            core.dispatch(&settings(true));
            assert_eq!(
                core.saved_folders(),
                (Some(root_label.clone()), Some(child_label.clone()))
            );
        }
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert_eq!(
            core.state.current_folder.as_deref(),
            Some(child_label.as_str())
        );
        assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));

        // Not remembered: the saved values are dropped, and the next start
        // opens nothing even though this session is showing the folder.
        {
            let mut core = Core::for_test(&runtime);
            core.restore_last_session();
            assert!(core.state.remember_last_folder);
            core.dispatch(&settings(false));
            assert!(
                !core.state.remember_last_folder,
                "the dialog reads this from the snapshot; it still says remembered"
            );
            assert_eq!(
                core.saved_folders(),
                (None, None),
                "turning the option off left the folders in the file"
            );
            // A navigation after that must not put them back.
            core.open_folder(root.clone(), true).unwrap();
            assert_eq!(
                core.saved_folders(),
                (None, None),
                "navigation re-saved the folders"
            );
        }
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert!(
            core.state.current_folder.is_none(),
            "a session the user asked not to remember came back anyway"
        );

        // And turning it on again remembers what is on screen now, without a
        // navigation in between.
        {
            let mut core = Core::for_test(&runtime);
            core.open_folder(root.clone(), true).unwrap();
            core.open_folder(child.clone(), true).unwrap();
            core.dispatch(&settings(true));
            assert_eq!(core.saved_folders(), (Some(root_label), Some(child_label)));
        }

        remove_tree(&base);
    }

    /// A config that says "do not remember" is obeyed even when it still holds
    /// folders (hand-edited, or written by an older build).
    #[test]
    fn a_config_that_forgets_opens_nothing() {
        let base = temp_dir();
        let root = base.join("Pictures");
        std::fs::create_dir_all(&root).unwrap();
        let runtime = base.join("runtime");
        {
            let mut core = Core::for_test(&runtime);
            core.open_folder(root, true).unwrap();
            core.config.remember_last_folder = false;
            core.save_config();
        }
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert!(core.state.root_folder.is_none());
        assert!(core.state.current_folder.is_none());
        remove_tree(&base);
    }

    /// Poll until the editor has a document and no preview render outstanding.
    /// Wait for a save worker to report back, the way the UI's poll timer does.
    fn settle_save(core: &mut Core) -> bool {
        for _ in 0..3000 {
            core.poll();
            if !core.editor_saving() {
                return core
                    .state
                    .editor
                    .as_ref()
                    .is_some_and(|editor| editor.saved);
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        false
    }

    fn dispatch_json(core: &mut Core, id: &str, command: &str) -> serde_json::Value {
        serde_json::from_str(&core.dispatch(&editor_envelope(id, command))).unwrap()
    }

    /// Wait for an export worker to finish writing `path`.
    fn settle_export(core: &mut Core, path: &Path) -> bool {
        for _ in 0..4000 {
            core.poll();
            if !core.editor_saving() && path.is_file() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        false
    }

    /// A JPEG whose entropy-coded data changes with the quality setting, with
    /// an EXIF APP1 segment a reader can look for after an export.
    fn write_jpeg_with_exif(path: &Path, width: u32, height: u32) {
        let image = image::RgbaImage::from_fn(width, height, |x, y| {
            image::Rgba([
                ((x * 37 + y * 11) % 256) as u8,
                ((x * 13 + y * 29) % 256) as u8,
                ((x * x + y * y) % 256) as u8,
                255,
            ])
        });
        let encoded = editor::encode_with(&image, editor::SaveFormat::Jpeg, Some(95)).unwrap();
        let payload = b"Exif\0\0KogaViewExportTest";
        let length = (payload.len() + 2) as u16;
        let mut bytes = encoded[..2].to_vec();
        bytes.extend_from_slice(&[0xFF, 0xE1, (length >> 8) as u8, length as u8]);
        bytes.extend_from_slice(payload);
        bytes.extend_from_slice(&encoded[2..]);
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn export_writes_a_copy_with_the_chosen_quality_and_keeps_the_document() {
        let base = temp_dir();
        let photo = base.join("photo.jpg");
        write_jpeg_with_exif(&photo, 160, 120);
        let mut core = Core::for_test(&base.join("runtime"));
        dispatch_json(
            &mut core,
            "open-1",
            &format!(r#"{{"type":"editor_open","path":"{}"}}"#, photo.display()),
        );
        assert!(settle_editor(&mut core), "the document never opened");

        // An edit makes `saved` false; an export must not touch that, nor move
        // the save target.
        dispatch_json(
            &mut core,
            "rotate-1",
            r#"{"type":"editor_rotate","degrees":90}"#,
        );
        let before = core.state.editor.clone().unwrap();
        assert!(!before.saved, "the edit must leave the document unsaved");

        let small = base.join("small.jpg");
        let large = base.join("large.jpg");
        // `plain` differs from `large` in the metadata flag only, so a size
        // comparison between `small` and `plain` measures the quality setting
        // alone — comparing against `large` would measure the APP1 segment it
        // carries as well.
        let plain = base.join("plain.jpg");
        for (path, quality, metadata, id) in [
            (&small, 20, false, "export-1"),
            (&large, 95, true, "export-2"),
            (&plain, 95, false, "export-3"),
        ] {
            let response = dispatch_json(
                &mut core,
                id,
                &format!(
                    r#"{{"type":"editor_export","path":"{}","quality":{quality},"metadata":{metadata}}}"#,
                    path.display()
                ),
            );
            assert_eq!(response["ok"], true, "{response}");
            assert!(
                settle_export(&mut core, path),
                "no file at {}",
                path.display()
            );
        }

        let after = core.state.editor.as_ref().unwrap();
        assert_eq!(
            after.save_path, before.save_path,
            "export moved the save target"
        );
        assert_eq!(after.saved, before.saved, "export changed the saved flag");
        assert_eq!(after.history, before.history, "export changed the history");
        assert_eq!(core.state.status.code, "exported");
        assert_eq!(core.state.status.args[0], "plain.jpg");

        let small_len = std::fs::metadata(&small).unwrap().len();
        let plain_len = std::fs::metadata(&plain).unwrap().len();
        assert!(
            small_len < plain_len,
            "quality 20 wrote {small_len} bytes, quality 95 wrote {plain_len}"
        );

        // Metadata is the caller's choice, and only JPEG carries it. The fake
        // APP1 the source holds must be in the copy that asked for it.
        let with_meta = std::fs::read(&large).unwrap();
        let without = std::fs::read(&plain).unwrap();
        assert!(
            with_meta.windows(9).any(|window| window == b"KogaViewE"),
            "the export dropped the source metadata"
        );
        assert!(
            !without.windows(9).any(|window| window == b"KogaViewE"),
            "an export that refused metadata copied it anyway"
        );

        // Exporting onto the document's own file is refused: that is Save.
        let refused = dispatch_json(
            &mut core,
            "export-3",
            &format!(r#"{{"type":"editor_export","path":"{}"}}"#, photo.display()),
        );
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error"]["code"], "invalid_destination");
        remove_tree(&base);
    }

    #[test]
    fn save_overwrites_the_source_with_the_edit_and_keeps_a_backup() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let before = std::fs::read(&photo).unwrap();
        let mut core = Core::for_test(&base.join("runtime"));
        dispatch_json(
            &mut core,
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        );
        assert!(settle_editor(&mut core), "the document never arrived");
        assert!(core.state.editor.as_ref().unwrap().saved);
        assert_eq!(
            core.state.editor.as_ref().unwrap().save_path,
            photo.to_string_lossy()
        );

        dispatch_json(
            &mut core,
            "rotate-1",
            r#"{"type":"editor_rotate","degrees":90}"#,
        );
        assert!(
            !core.state.editor.as_ref().unwrap().saved,
            "an edit makes the document unsaved"
        );

        let response = dispatch_json(&mut core, "save-1", r#"{"type":"editor_save"}"#);
        assert_eq!(response["ok"], true, "{response}");
        assert!(settle_save(&mut core), "the save never finished");
        let editor = core.state.editor.as_ref().unwrap();
        assert!(editor.saved);
        assert_eq!(editor.save_path, photo.to_string_lossy());

        // The source now holds the rotated pixels: 20 × 40, not the original 40 × 20.
        let written = image::open(&photo).unwrap();
        assert_eq!((written.width(), written.height()), (20, 40));
        // The bytes it had before the save are kept beside it.
        let backup = base.join("photo.png.bak");
        assert_eq!(std::fs::read(&backup).unwrap(), before);
        // Journaled like every other command.
        let journal =
            std::fs::read_to_string(base.join("runtime/state/journal/commands.jsonl")).unwrap();
        assert!(journal.contains("\"command\":\"editor_save\""), "{journal}");
        remove_tree(&base);
    }

    #[test]
    fn save_as_moves_the_save_target_and_leaves_the_source_alone() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let before = std::fs::read(&photo).unwrap();
        let destination = base.join("copy.jpeg");
        let mut core = Core::for_test(&base.join("runtime"));
        dispatch_json(
            &mut core,
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        );
        assert!(settle_editor(&mut core));
        dispatch_json(
            &mut core,
            "crop-1",
            r#"{"type":"editor_crop","x":0,"y":0,"width":10,"height":5}"#,
        );

        let response = dispatch_json(
            &mut core,
            "save-as-1",
            &format!(
                r#"{{"type":"editor_save_as","path":{}}}"#,
                serde_json::to_string(&destination.to_string_lossy()).unwrap()
            ),
        );
        assert_eq!(response["ok"], true, "{response}");
        assert!(settle_save(&mut core), "the save never finished");

        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!(editor.save_path, destination.to_string_lossy());
        assert_eq!(editor.format, ".jpg");
        // A save-as never touches the source and keeps no backup of it.
        assert_eq!(std::fs::read(&photo).unwrap(), before);
        assert!(!base.join("photo.png.bak").exists());
        let written = image::open(&destination).unwrap();
        assert_eq!((written.width(), written.height()), (10, 5));
        remove_tree(&base);
    }

    #[test]
    fn a_save_is_refused_when_the_source_changed_under_the_document() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let mut core = Core::for_test(&base.join("runtime"));
        dispatch_json(
            &mut core,
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        );
        assert!(settle_editor(&mut core));
        dispatch_json(
            &mut core,
            "rotate-1",
            r#"{"type":"editor_rotate","degrees":90}"#,
        );

        // Something else rewrites the file while the document is open.
        write_png(&photo, 40, 20);
        let now = std::time::SystemTime::now() + std::time::Duration::from_secs(2);
        std::fs::File::options()
            .write(true)
            .open(&photo)
            .unwrap()
            .set_modified(now)
            .unwrap();

        let response = dispatch_json(&mut core, "save-1", r#"{"type":"editor_save"}"#);
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error"]["code"], "source_changed", "{response}");
        assert!(!core.state.editor.as_ref().unwrap().saved);

        // Save As is still allowed, and says nothing about the source.
        let elsewhere = base.join("rescue.png");
        let response = dispatch_json(
            &mut core,
            "save-as-1",
            &format!(
                r#"{{"type":"editor_save_as","path":{}}}"#,
                serde_json::to_string(&elsewhere.to_string_lossy()).unwrap()
            ),
        );
        assert_eq!(response["ok"], true, "{response}");
        assert!(settle_save(&mut core));
        remove_tree(&base);
    }

    #[test]
    fn saving_an_unsupported_extension_is_rejected_before_any_write() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let mut core = Core::for_test(&base.join("runtime"));
        dispatch_json(
            &mut core,
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        );
        assert!(settle_editor(&mut core));
        let target = base.join("idea.psd");
        let response = dispatch_json(
            &mut core,
            "save-as-1",
            &format!(
                r#"{{"type":"editor_save_as","path":{}}}"#,
                serde_json::to_string(&target.to_string_lossy()).unwrap()
            ),
        );
        assert_eq!(
            response["error"]["code"], "unsupported_format",
            "{response}"
        );
        assert!(!target.exists(), "a rejected save writes nothing");
        remove_tree(&base);
    }

    #[test]
    fn switching_to_the_editor_carries_the_viewer_image() {
        let base = temp_dir();
        write_png(&base.join("one.png"), 10, 10);
        write_png(&base.join("two.png"), 12, 12);
        let mut core = Core::for_test(&base.join("runtime"));
        let folder = base.to_string_lossy().into_owned();
        dispatch_json(
            &mut core,
            "open-1",
            &format!(r#"{{"type":"open_folder","path":{folder:?}}}"#),
        );
        assert!(settle_scan(&mut core), "the folder never listed");
        dispatch_json(
            &mut core,
            "viewer-1",
            r#"{"type":"set_workspace","workspace":"viewer"}"#,
        );
        assert!(core.state.viewer_path.is_some(), "the viewer needs a path");
        let shown = core.state.viewer_path.clone().unwrap();

        // The workspace switcher alone: no `editor_open` anywhere in the user's action.
        let response = dispatch_json(
            &mut core,
            "editor-1",
            r#"{"type":"set_workspace","workspace":"editor"}"#,
        );
        assert_eq!(response["ok"], true, "{response}");
        let editor = core
            .state
            .editor
            .as_ref()
            .expect("the editor must open the viewed image");
        assert_eq!(editor.path, shown);
        assert!(settle_editor(&mut core));
        assert_eq!(
            core.state.status.code, "editing",
            "the editor must say it is editing: {:?}",
            core.state.status
        );
        assert_eq!(core.state.status.args[0], "one.png");

        // A second switch back does not reload, and a document already open
        // wins over the Viewer's current image.
        let kept = core.state.editor.as_ref().unwrap().path.clone();
        dispatch_json(
            &mut core,
            "browser-1",
            r#"{"type":"set_workspace","workspace":"browser"}"#,
        );
        let status = core.state.status.clone();
        assert!(
            status.is_empty(),
            "the Browser still claimed to be editing: {status:?}"
        );
        dispatch_json(
            &mut core,
            "editor-2",
            r#"{"type":"set_workspace","workspace":"editor"}"#,
        );
        assert_eq!(core.state.editor.as_ref().unwrap().path, kept);
        remove_tree(&base);
    }

    fn settle_editor(core: &mut Core) -> bool {
        for _ in 0..3000 {
            core.poll();
            match &core.state.editor {
                Some(editor) if editor.width > 0 && !editor.rendering => return true,
                _ => {}
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        false
    }

    /// Wait for a live-preview draft to land. `settle_editor` cannot stand in
    /// for this: the document is not rendering, so it returns before the draft
    /// worker has answered.
    fn settle_draft(core: &mut Core) -> bool {
        for _ in 0..3000 {
            core.poll();
            if let Some(editor) = &core.state.editor {
                if editor.preview_draft.is_some() {
                    return true;
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        false
    }

    fn write_png(path: &Path, width: u32, height: u32) {
        let image = image::RgbaImage::from_fn(width, height, |x, y| {
            image::Rgba([(x % 251) as u8, (y % 251) as u8, 90, 255])
        });
        image::DynamicImage::ImageRgba8(image)
            .save_with_format(path, image::ImageFormat::Png)
            .unwrap();
    }

    fn editor_envelope(id: &str, command: &str) -> String {
        format!(r#"{{"id":"{id}","protocol":1,"command":{command}}}"#)
    }

    #[test]
    fn an_image_opens_in_the_editor_and_the_source_is_never_written() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let before = std::fs::read(&photo).unwrap();
        let runtime = base.join("runtime");
        let mut core = Core::for_test(&runtime);

        let response = core.dispatch(&editor_envelope(
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        ));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], true, "{response}");
        assert!(settle_editor(&mut core), "the document never arrived");

        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (40, 20));
        assert_eq!(editor.name, "photo.png");
        assert_eq!(core.state.workspace, Workspace::Editor);
        assert!(editor.preview_path.is_some());
        let preview = PathBuf::from(editor.preview_path.as_ref().unwrap());
        assert!(preview.is_file(), "the preview PNG must exist");

        // A rotate changes the published size, keeps the source untouched, and
        // lands a new preview.
        let response = core.dispatch(&editor_envelope(
            "rotate-1",
            r#"{"type":"editor_rotate","degrees":90}"#,
        ));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"],
            true,
            "{response}"
        );
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (20, 40));
        assert_eq!(editor.history, vec![UiText::new("rotate_right")]);
        assert!(editor.can_undo);
        assert!(!editor.can_redo);
        assert!(settle_editor(&mut core), "the preview never landed");
        assert_eq!(std::fs::read(&photo).unwrap(), before);

        // Undo restores the size and offers redo.
        core.dispatch(&editor_envelope("undo-1", r#"{"type":"editor_undo"}"#));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (40, 20));
        assert!(!editor.can_undo);
        assert!(editor.can_redo);
        assert_eq!(editor.history.len(), 0);
        assert!(settle_editor(&mut core));

        core.dispatch(&editor_envelope("redo-1", r#"{"type":"editor_redo"}"#));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (20, 40));
        assert!(settle_editor(&mut core));

        // Close drops the document and its preview, and still leaves the file.
        let current_preview = PathBuf::from(
            core.state
                .editor
                .as_ref()
                .unwrap()
                .preview_path
                .as_ref()
                .unwrap(),
        );
        core.dispatch(&editor_envelope("close-1", r#"{"type":"editor_close"}"#));
        assert!(core.state.editor.is_none());
        assert!(
            !current_preview.is_file(),
            "the preview is removed on close"
        );
        assert_eq!(std::fs::read(&photo).unwrap(), before);

        // The journal recorded each command that reached the gateway.
        let journal =
            std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
        for name in [
            "editor_open",
            "editor_rotate",
            "editor_undo",
            "editor_redo",
            "editor_close",
        ] {
            assert!(
                journal.contains(&format!("\"command\":\"{name}\"")),
                "{journal}"
            );
        }

        remove_tree(&base);
    }

    #[test]
    fn editor_commands_without_a_document_are_rejected_and_journaled() {
        let base = temp_dir();
        let runtime = base.join("runtime");
        let mut core = Core::for_test(&runtime);

        for (id, command) in [
            ("undo", r#"{"type":"editor_undo"}"#),
            ("redo", r#"{"type":"editor_redo"}"#),
            (
                "crop",
                r#"{"type":"editor_crop","x":0,"y":0,"width":4,"height":4}"#,
            ),
            ("resize", r#"{"type":"editor_resize","width":4,"height":4}"#),
            ("rotate", r#"{"type":"editor_rotate","degrees":90}"#),
            ("flip", r#"{"type":"editor_flip","axis":"horizontal"}"#),
            ("reset", r#"{"type":"editor_reset"}"#),
        ] {
            let response = core.dispatch(&editor_envelope(id, command));
            let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
            assert_eq!(parsed["ok"], false, "{command}: {response}");
            assert_eq!(parsed["error"]["code"], "no_document", "{command}");
            assert!(core.state.editor.is_none());
        }

        let journal =
            std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
        assert!(journal.contains("\"ok\":false"));
        remove_tree(&base);
    }

    /// A rejection the interface can word itself travels as `{ code, args }`
    /// next to the English message: the window says it in its own language, the
    /// journal keeps a sentence, and a rejection whose detail is the platform's
    /// (an envelope that did not parse) carries no line at all.
    #[test]
    fn a_rejection_carries_a_line_the_interface_can_translate() {
        let base = temp_dir();
        let runtime = base.join("runtime");
        let mut core = Core::for_test(&runtime);

        let reply = dispatch_json(&mut core, "cancel-1", r#"{"type":"cancel_operation"}"#);
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"]["code"], "not_running", "{reply}");
        assert_eq!(
            reply["error"]["ui"]["code"], "cancel_nothing_running",
            "{reply}"
        );
        assert_eq!(reply["error"]["ui"]["args"], json!([]), "{reply}");
        // The journal's sentence is not the line's mechanical rendering.
        assert_eq!(
            reply["error"]["message"], "there is no long-running operation to cancel",
            "{reply}"
        );

        // A rejection that identifies something the filesystem named keeps the
        // path as an argument: the interface owns the sentence, the path is
        // data and must arrive unchanged.
        let missing = base.join("gone.jpg");
        let reply = dispatch_json(
            &mut core,
            "open-1",
            &format!(
                r#"{{"type":"open_file","paths":["{}"]}}"#,
                missing.display()
            ),
        );
        assert_eq!(reply["error"]["ui"]["code"], "path_missing", "{reply}");
        assert_eq!(
            reply["error"]["ui"]["args"][0],
            missing.display().to_string(),
            "{reply}"
        );

        // The journal kept the English sentence, so a reader of the log is not
        // asked to decode a code.
        let journal =
            std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
        assert!(journal.contains("no long-running operation"), "{journal}");

        // An envelope that never parsed is answered before the gateway: there
        // is no command to word, so the rejection has no line.
        let reply: serde_json::Value = serde_json::from_str(&core.dispatch("{")).unwrap();
        assert_eq!(reply["error"]["code"], "invalid_envelope", "{reply}");
        assert!(reply["error"].get("ui").is_none(), "{reply}");

        remove_tree(&base);
    }

    #[test]
    fn opening_a_missing_or_non_image_file_is_rejected() {
        let base = temp_dir();
        let runtime = base.join("runtime");
        let mut core = Core::for_test(&runtime);

        let missing = base.join("missing.png");
        let response = core.dispatch(&editor_envelope(
            "open-missing",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&missing.to_string_lossy()).unwrap()
            ),
        ));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], false);
        assert_eq!(parsed["error"]["code"], "not_found");

        let notes = base.join("notes.txt");
        std::fs::write(&notes, "not an image").unwrap();
        let response = core.dispatch(&editor_envelope(
            "open-text",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&notes.to_string_lossy()).unwrap()
            ),
        ));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], false);
        assert_eq!(parsed["error"]["code"], "not_an_image");

        remove_tree(&base);
    }

    #[test]
    fn editor_resize_crop_and_flip_change_the_published_size() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let runtime = base.join("runtime");
        let mut core = Core::for_test(&runtime);
        core.dispatch(&editor_envelope(
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        ));
        assert!(settle_editor(&mut core));

        core.dispatch(&editor_envelope(
            "crop-1",
            r#"{"type":"editor_crop","x":4,"y":2,"width":10,"height":8}"#,
        ));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (10, 8));
        assert_eq!(
            editor.history,
            vec![UiText::with("crop", ["10", "8", "4", "2"])]
        );
        assert_eq!(core.state.status.code, "editing");
        assert_eq!(
            &core.state.status.args[1..],
            ["10", "8"],
            "the status line must follow the document size: {:?}",
            core.state.status
        );

        core.dispatch(&editor_envelope(
            "resize-1",
            r#"{"type":"editor_resize","width":25,"height":25}"#,
        ));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (25, 25));
        // The published preview carries its own identity, not just a name the
        // next run will reuse: this is what keeps a thumbnail cache from
        // answering with an older document's image.
        assert!(editor.preview_modified > 0);
        assert!(editor.preview_size > 0);

        core.dispatch(&editor_envelope(
            "flip-1",
            r#"{"type":"editor_flip","axis":"vertical"}"#,
        ));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (25, 25));
        assert_eq!(editor.history.len(), 3);

        // An out-of-bounds crop is rejected with a message and changes nothing.
        let response = core.dispatch(&editor_envelope(
            "crop-2",
            r#"{"type":"editor_crop","x":20,"y":20,"width":10,"height":10}"#,
        ));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], false);
        assert_eq!(parsed["error"]["code"], "invalid_edit");
        // The rejection says why twice: the line the window translates, and the
        // sentence the journal keeps. The numbers must be in both.
        assert_eq!(parsed["error"]["ui"]["code"], "crop_does_not_fit");
        assert_eq!(
            parsed["error"]["message"],
            "crop 10 × 10 at 20,20 does not fit the 25 × 25 image"
        );
        assert_eq!(core.state.editor.as_ref().unwrap().history.len(), 3);

        // The live preview is a draft: it publishes its own path and target
        // size, and leaves the document, its history and its save target alone.
        let before_history = core.state.editor.as_ref().unwrap().history.clone();
        let response = core.dispatch(&editor_envelope(
            "draft-1",
            r#"{"type":"editor_resize_preview","width":20,"height":20}"#,
        ));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"],
            true,
            "{response}"
        );
        {
            let editor = core.state.editor.as_ref().unwrap();
            assert_eq!((editor.width, editor.height), (25, 25));
            assert_eq!(editor.history, before_history);
            assert!(
                editor.preview_draft.is_none(),
                "the draft renders on a worker"
            );
        }
        assert!(settle_draft(&mut core), "the draft preview never landed");
        let draft = core
            .state
            .editor
            .as_ref()
            .unwrap()
            .preview_draft
            .clone()
            .expect("a draft is published");
        assert_eq!((draft.width, draft.height), (20, 20));
        assert_eq!(draft.kind, "resize");
        let draft_path = PathBuf::from(&draft.path);
        assert!(draft_path.is_file());
        let decoded = image::open(&draft_path).unwrap();
        assert_eq!(
            (decoded.width(), decoded.height()),
            (20, 20),
            "the draft is rendered at the target size"
        );

        // Applying the same size records the step and drops the draft file.
        core.dispatch(&editor_envelope(
            "resize-2",
            r#"{"type":"editor_resize","width":20,"height":20}"#,
        ));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (20, 20));
        assert!(editor.preview_draft.is_none());
        assert!(!draft_path.exists(), "the applied draft file is cleaned up");
        assert_eq!(
            editor.history.last(),
            Some(&UiText::with("resize", ["20", "20"]))
        );

        // Reset drops every step, back to the source size.
        core.dispatch(&editor_envelope("reset-1", r#"{"type":"editor_reset"}"#));
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (40, 20));
        assert!(editor.history.is_empty());
        assert!(!editor.can_undo);
        assert!(!editor.modified);

        remove_tree(&base);
    }

    /// A crop preview is a draft like the resize one: it renders the rectangle
    /// Core would cut, publishes it under its own kind, and leaves the
    /// document, its history and its preview alone. A no-op rectangle and an
    /// out-of-bounds one are answered without rendering anything.
    #[test]
    fn a_crop_preview_is_a_draft_that_never_cuts() {
        let base = temp_dir();
        let photo = base.join("photo.png");
        write_png(&photo, 40, 20);
        let runtime = base.join("runtime");
        let mut core = Core::for_test(&runtime);
        core.dispatch(&editor_envelope(
            "open-1",
            &format!(
                r#"{{"type":"editor_open","path":{}}}"#,
                serde_json::to_string(&photo.to_string_lossy()).unwrap()
            ),
        ));
        assert!(settle_editor(&mut core));
        let document_preview = core.state.editor.as_ref().unwrap().preview_path.clone();

        let response = core.dispatch(&editor_envelope(
            "crop-preview-1",
            r#"{"type":"editor_crop_preview","x":4,"y":2,"width":10,"height":8}"#,
        ));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"],
            true,
            "{response}"
        );
        assert!(settle_draft(&mut core), "the crop draft never landed");
        let draft = core
            .state
            .editor
            .as_ref()
            .unwrap()
            .preview_draft
            .clone()
            .expect("the crop draft is published");
        assert_eq!(draft.kind, "crop");
        assert_eq!((draft.width, draft.height), (10, 8));
        let draft_path = PathBuf::from(&draft.path);
        let decoded = image::open(&draft_path).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (10, 8));
        {
            let editor = core.state.editor.as_ref().unwrap();
            assert_eq!((editor.width, editor.height), (40, 20));
            assert!(editor.history.is_empty());
            assert_eq!(editor.preview_path, document_preview);
        }

        // Any other edit drops the draft file and publishes no draft.
        core.dispatch(&editor_envelope(
            "rotate-1",
            r#"{"type":"editor_rotate","degrees":90}"#,
        ));
        let editor = core.state.editor.as_ref().unwrap();
        assert!(editor.preview_draft.is_none());
        assert!(!draft_path.exists(), "another edit drops the crop draft");
        assert!(settle_editor(&mut core));

        // The whole image is not a crop: nothing is rendered and the message
        // says why, rather than leaving a stale draft on screen.
        let response = core.dispatch(&editor_envelope(
            "crop-preview-2",
            r#"{"type":"editor_crop_preview","x":0,"y":0,"width":20,"height":40}"#,
        ));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], true, "{response}");
        assert_eq!(parsed["message"], "crop noop");
        assert_eq!(parsed["ui"]["code"], "crop_noop");
        assert!(core.state.editor.as_ref().unwrap().preview_draft.is_none());

        // Out of bounds is rejected at the gateway: no draft, no revision.
        let revision = core.state.revision;
        let response = core.dispatch(&editor_envelope(
            "crop-preview-3",
            r#"{"type":"editor_crop_preview","x":15,"y":0,"width":10,"height":10}"#,
        ));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], false, "{response}");
        assert_eq!(parsed["error"]["code"], "invalid_edit");
        assert_eq!(core.state.revision, revision);
        assert!(core.state.editor.as_ref().unwrap().preview_draft.is_none());

        core.dispatch(&editor_envelope("close-1", r#"{"type":"editor_close"}"#));
        remove_tree(&base);
    }
}
