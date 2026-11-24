//! The single ordered command gateway and state owner.
//!
//! `Core` is Qt-independent. UI, CLI, IPC and MCP adapters submit the same
//! envelopes; background work reports back through `poll`.
//!
//! The struct and the state every area shares live here — `Core`, its
//! constructor, the snapshot it publishes and the small value types a worker
//! sends back. The commands themselves are one module per area:
//!
//! | Module | What it owns |
//! |---|---|
//! | `gateway` | `dispatch`, the queries, `execute`'s command match and the `poll` loop |
//! | `browsing` | folders, scans, selection, files, favourites, theme, panels and the saved config |
//! | `viewing` | the Viewer's path, selection and step |
//! | `editing` | the Editor's document lifecycle, save/export, previews and the worker messages |
//! | `jobs` | the batch worker and the input set it runs over |
//!
//! A method a sibling module calls is `pub(super)`; the fields stay private to
//! this module, which every other one is a child of. `tests` is the whole
//! suite in one file, because it shares the fixtures at its top.

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::Arc;

use kogaview_protocol::{
    BatchOperation, BatchOutput, BatchSource, Command, Envelope, MoveDirection, ProtocolError,
    Query, ResizeFilter, ResizeMode, Theme, Workspace,
};
use serde_json::{json, Value};

use crate::batch::{self, BatchEvent};
use crate::config::Config;
use crate::editor::{self, EditOperation, EditorDocument, EditorTask};
use crate::journal::{Journal, JournalEntry};
use crate::ops;
use crate::paths::AppPaths;
use crate::state::{
    BatchState, Crumb, EditorPreviewDraft, EditorState, FolderListing, SelectionInfo, UiState,
    UiText,
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

/// Milliseconds since the epoch and the byte size of a file, or `(0, 0)` when
/// it cannot be read.
///
/// This is the identity a thumbnail cache keys on. A file's path repeats
/// between runs and after a Save (save-as aside), so the picture behind a path
/// can change while the name stays — the two numbers are what tell the two
/// states apart.
fn file_identity(path: &Path) -> (u64, u64) {
    std::fs::metadata(path)
        .ok()
        .map(|metadata| {
            let modified = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|age| age.as_millis() as u64)
                .unwrap_or(0);
            (modified, metadata.len())
        })
        .unwrap_or((0, 0))
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
/// The tools share one draft pipeline and differ only in what the interface
/// calls the result, so the codes live here as literals: the QML line table is
/// checked against them by `scripts/check_translations.py`, and a `format!`ed
/// code would slip past that gate.
#[derive(Clone, Copy)]
enum PreviewKind {
    Resize,
    Crop,
    Transform,
}

impl PreviewKind {
    /// The line for "that rectangle/size changes nothing".
    fn noop(self) -> UiText {
        match self {
            Self::Resize => UiText::new("resize_noop"),
            Self::Crop => UiText::new("crop_noop"),
            Self::Transform => UiText::new("transform_noop"),
        }
    }

    /// The line for "rendering a draft of …".
    fn preview(self, width: u32, height: u32) -> UiText {
        match self {
            Self::Resize => UiText::with("resize_preview", [width.to_string(), height.to_string()]),
            Self::Crop => UiText::with("crop_preview", [width.to_string(), height.to_string()]),
            Self::Transform => {
                UiText::with("transform_preview", [width.to_string(), height.to_string()])
            }
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
    /// A batch job's worker. Progress and the final line arrive here; a batch
    /// has its own cancel flag so a Cancel never reaches a copy that happens to
    /// be running at the same time.
    batch_rx: Option<Receiver<BatchEvent>>,
    batch_cancel: Option<Arc<AtomicBool>>,
    /// Discovered AI plugin manifests (static JSON only; never spawned at startup).
    ai_plugins: Vec<crate::plugins::DiscoveredPlugin>,
    /// Active AI model download or out-of-process inference worker.
    ai_rx: Option<Receiver<crate::plugins::AiWorkerEvent>>,
    ai_cancel: Option<Arc<AtomicBool>>,
    ai_generation: u64,
    ai_temp_input: Option<PathBuf>,
    ai_temp_output: Option<PathBuf>,
    /// Bumped whenever the folder listing is replaced. The Qt adapter ships the
    /// listing on its own and only re-sends it when this changes, because it is
    /// the one part of the snapshot that grows with the folder.
    listing_epoch: u64,
}

mod ai;
mod browsing;
mod editing;
mod gateway;
mod jobs;
#[cfg(test)]
mod tests;
mod viewing;

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
            config.layout.clone(),
            config.filmstrip,
            config.remember_last_folder,
            config.background_thumbnails,
            config.hardware_acceleration,
            config.anti_aliasing,
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
            batch_rx: None,
            batch_cancel: None,
            ai_plugins: Vec::new(),
            ai_rx: None,
            ai_cancel: None,
            ai_generation: 0,
            ai_temp_input: None,
            ai_temp_output: None,
            listing_epoch: 0,
        };

        core.refresh_ai_inventory();
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
            plugins_dir: base.join("data/plugins"),
            models_dir: base.join("data/models"),
            ai_ipc_dir: base.join("cache/ai-ipc"),
        };
        let journal = Journal::new(&paths.journal_dir);
        let (editor_tx, editor_rx) = mpsc::channel();
        let state = UiState::new(
            config.theme,
            config.language,
            config.quick_access.clone(),
            config.layout.clone(),
            config.filmstrip,
            config.remember_last_folder,
            config.background_thumbnails,
            config.hardware_acceleration,
            config.anti_aliasing,
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
            batch_rx: None,
            batch_cancel: None,
            ai_plugins: Vec::new(),
            ai_rx: None,
            ai_cancel: None,
            ai_generation: 0,
            ai_temp_input: None,
            ai_temp_output: None,
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

    /// Deliver completed background work. Returns true when state changed.
    /// The configured interface language, as the settings store it.
    pub fn language(&self) -> &'static str {
        self.state.language.as_str()
    }

    /// True while a save is in flight, for the UI's busy indicator.
    pub fn editor_saving(&self) -> bool {
        self.editor_saving
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

/// The panels on the left edge of a workspace, in the order they are stacked.
fn left_panel_keys(workspace: Workspace) -> [&'static str; 2] {
    match workspace {
        Workspace::Browser => ["browser.quickAccess", "browser.explorer"],
        Workspace::Viewer => ["viewer.quickAccess", "viewer.explorer"],
        Workspace::Editor => ["editor.quickAccess", "editor.explorer"],
    }
}

/// The panels in a workspace's right dock.
fn right_panel_keys(workspace: Workspace) -> &'static [&'static str] {
    match workspace {
        Workspace::Browser => &["browser.preview", "browser.batch"],
        Workspace::Viewer => &["viewer.info"],
        Workspace::Editor => &[
            "editor.options",
            "editor.info",
            "editor.history",
            "editor.original",
        ],
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
