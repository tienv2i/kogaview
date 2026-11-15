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
use crate::journal::{Journal, JournalEntry};
use crate::ops;
use crate::paths::AppPaths;
use crate::state::{Crumb, FolderListing, SelectionInfo, UiState};
use crate::AppIdentity;

struct ScanResult {
    generation: u64,
    folder: PathBuf,
    entries: Result<Vec<crate::state::Entry>, String>,
}

struct OpResult {
    ok: bool,
    message: String,
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
        let state = UiState::new(
            config.theme,
            config.quick_access.clone(),
            config.left_panel,
            config.right_panel,
            config.filmstrip,
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
        if self.config.tree_root.as_deref() != Some(root_label.as_str())
            || self.config.last_folder.as_deref() != Some(folder_label.as_str())
        {
            self.config.tree_root = Some(root_label);
            self.config.last_folder = Some(folder_label);
            self.save_config();
        }
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
        let state = UiState::new(
            config.theme,
            config.quick_access.clone(),
            config.left_panel,
            config.right_panel,
            config.filmstrip,
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

    pub fn status(&self) -> &str {
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
                json!({
                    "id": envelope.id,
                    "ok": true,
                    "revision": self.state.revision,
                    "message": result.as_ref().ok().and_then(|message| message.clone()),
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
                    self.state.status = "Folder scan failed".to_owned();
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
                    self.state.status = "File operation failed".to_owned();
                    changed = true;
                }
            }
        }

        if changed {
            self.state.bump();
        }
        changed
    }

    fn execute(&mut self, command: Command) -> Result<Option<String>, ProtocolError> {
        match command {
            Command::OpenFile { paths } => self.open_file(paths),
            Command::OpenFolder { path } => self.open_folder(PathBuf::from(path), true),
            Command::Navigate { path } => self.open_folder(PathBuf::from(path), false),
            Command::Refresh => {
                self.state.tree_revision += 1;
                self.refresh_current();
                Ok(Some("Refreshed".to_owned()))
            }
            Command::Select { paths } => {
                self.set_selection(paths);
                Ok(None)
            }
            Command::SetWorkspace { workspace } => {
                self.state.workspace = workspace;
                if workspace == Workspace::Viewer {
                    self.ensure_viewer_selection();
                }
                Ok(None)
            }
            Command::SetTheme { theme } => {
                self.set_theme(theme);
                Ok(None)
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
            Command::CancelOperation => {
                if let Some(cancel) = &self.cancel_op {
                    cancel.store(true, Ordering::SeqCst);
                    self.state.status = "Cancelling…".to_owned();
                    Ok(Some("Cancelling current operation".to_owned()))
                } else {
                    Err(ProtocolError::new(
                        "not_running",
                        "there is no long-running operation to cancel",
                    ))
                }
            }
        }
    }

    fn open_file(&mut self, paths: Vec<String>) -> Result<Option<String>, ProtocolError> {
        let first = paths.first().ok_or_else(|| {
            ProtocolError::new("invalid_path", "open_file requires at least one path")
        })?;
        let first = ops::normalize_path(&PathBuf::from(first));
        if !first.exists() {
            return Err(ProtocolError::new(
                "not_found",
                format!("{} does not exist", first.display()),
            ));
        }

        if first.is_dir() {
            return self.open_folder(first, true);
        }

        let parent = first
            .parent()
            .ok_or_else(|| ProtocolError::new("invalid_path", "file has no parent folder"))?
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
        Ok(Some(format!(
            "Opening {}",
            first.file_name().unwrap_or_default().to_string_lossy()
        )))
    }

    fn open_folder(
        &mut self,
        path: PathBuf,
        set_browser_workspace: bool,
    ) -> Result<Option<String>, ProtocolError> {
        // A symlinked folder opens like any other folder: the path the user
        // asked for stays in the breadcrumbs, the tree root and the grid, so
        // navigating into the link does not teleport to its target.
        let path = ops::normalize_path(&path);
        if !path.is_dir() {
            return Err(ProtocolError::new(
                "not_a_directory",
                format!("{} is not a directory", path.display()),
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
        let changed = self.config.tree_root.as_deref() != Some(root_label.as_str())
            || self.config.last_folder.as_deref() != Some(folder_label.as_str());
        self.config.tree_root = Some(root_label);
        self.config.last_folder = Some(folder_label);
        if changed {
            self.save_config();
        }

        self.start_scan(path.clone(), true, false);
        Ok(Some(format!("Opened {}", path.display())))
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
        self.state.status = if restore {
            "Restoring last folder…".to_owned()
        } else {
            format!("Loading {}…", folder.display())
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
                self.state.status = format!(
                    "{} items · {} images",
                    self.state.item_count, self.state.image_count
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
                self.state.status = error.clone();
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

    fn open_viewer_image(&mut self, path: &str) -> Result<Option<String>, ProtocolError> {
        let index = self
            .state
            .viewer_images
            .iter()
            .position(|image| image == path)
            .ok_or_else(|| {
                ProtocolError::new("not_found", "that image is not part of the current folder")
            })?;
        self.state.viewer_index = Some(index);
        self.state.viewer_path = Some(path.to_owned());
        self.state.workspace = Workspace::Viewer;
        self.set_selection(vec![path.to_owned()]);
        Ok(None)
    }

    fn step_viewer(&mut self, delta: isize) -> Result<Option<String>, ProtocolError> {
        if self.state.viewer_images.is_empty() {
            return Err(ProtocolError::new(
                "no_images",
                "there are no images in the current folder",
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

    fn set_theme(&mut self, theme: Theme) {
        self.config.theme = theme;
        self.state.theme = theme;
        self.save_config();
    }

    fn new_folder(&mut self, parent: PathBuf, name: &str) -> Result<Option<String>, ProtocolError> {
        let parent = ops::normalize_path(&parent);
        let created = ops::create_folder(&parent, name)
            .map_err(|error| ProtocolError::new("io_error", error))?;
        self.state.tree_revision += 1;
        self.refresh_current();
        Ok(Some(format!("Created {}", created.display())))
    }

    fn transfer(
        &mut self,
        paths: Vec<String>,
        destination: PathBuf,
        move_paths: bool,
    ) -> Result<Option<String>, ProtocolError> {
        if self.state.busy {
            return Err(ProtocolError::new(
                "busy",
                "another background operation is still running",
            ));
        }
        let destination = ops::normalize_path(&destination);
        if !destination.is_dir() {
            return Err(ProtocolError::new(
                "not_a_directory",
                format!("{} is not a directory", destination.display()),
            ));
        }

        let sources = paths
            .into_iter()
            .map(PathBuf::from)
            .filter(|path| path.exists())
            .collect::<Vec<_>>();
        if sources.is_empty() {
            return Err(ProtocolError::new("not_found", "no source files exist"));
        }
        for source in &sources {
            // `canonicalize` only here: folding a symlink lets a folder be
            // copied into itself through a link to it.
            let resolved = source.canonicalize().unwrap_or_else(|_| source.clone());
            if resolved.is_dir() && (destination.starts_with(&resolved) || resolved == destination)
            {
                return Err(ProtocolError::new(
                    "invalid_destination",
                    format!("cannot copy or move {} into itself", resolved.display()),
                ));
            }
        }

        let label = if move_paths { "Moving" } else { "Copying" };
        let count = sources.len();
        self.start_operation(format!("{label} {count} item(s)…"), move |cancel| {
            let mut failures = Vec::new();
            let mut moved = 0;
            for source in &sources {
                if cancel.load(Ordering::SeqCst) {
                    return OpResult {
                        ok: false,
                        message: format!("Cancelled after {moved} item(s)"),
                        refresh: true,
                    };
                }
                let result = if move_paths {
                    ops::move_path(source, &destination)
                } else {
                    ops::copy_path(source, &destination)
                };
                match result {
                    Ok(_) => moved += 1,
                    Err(error) => failures.push(error),
                }
            }
            OpResult {
                ok: failures.is_empty(),
                message: if failures.is_empty() {
                    format!("{label} {moved} item(s) to {}", destination.display())
                } else {
                    format!(
                        "{label} finished with {} error(s): {}",
                        failures.len(),
                        failures[0]
                    )
                },
                refresh: true,
            }
        });
        Ok(Some(format!("{label} {count} item(s)…")))
    }

    fn trash_paths(&mut self, paths: Vec<String>) -> Result<Option<String>, ProtocolError> {
        let paths = self.validated_deletion_paths(paths)?;
        let count = paths.len();
        self.start_operation(
            format!("Moving {count} item(s) to trash…"),
            move |cancel| {
                if cancel.load(Ordering::SeqCst) {
                    return OpResult {
                        ok: false,
                        message: "Cancelled".to_owned(),
                        refresh: true,
                    };
                }
                match ops::trash_paths(&paths) {
                    Ok(()) => OpResult {
                        ok: true,
                        message: format!("Moved {count} item(s) to trash"),
                        refresh: true,
                    },
                    Err(error) => OpResult {
                        ok: false,
                        message: format!("Move to trash failed: {error}"),
                        refresh: false,
                    },
                }
            },
        );
        Ok(Some(format!("Moving {count} item(s) to trash…")))
    }

    fn delete_paths(&mut self, paths: Vec<String>) -> Result<Option<String>, ProtocolError> {
        let paths = self.validated_deletion_paths(paths)?;
        let count = paths.len();
        self.start_operation(
            format!("Deleting {count} item(s) permanently…"),
            move |cancel| {
                let mut failures = Vec::new();
                let mut deleted = 0;
                for path in &paths {
                    if cancel.load(Ordering::SeqCst) {
                        return OpResult {
                            ok: false,
                            message: format!("Cancelled after deleting {deleted} item(s)"),
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
                        format!("Permanently deleted {deleted} item(s)")
                    } else {
                        format!(
                            "Deleted {deleted} item(s); {} error(s): {}",
                            failures.len(),
                            failures[0]
                        )
                    },
                    refresh: true,
                }
            },
        );
        Ok(Some(format!("Deleting {count} item(s) permanently…")))
    }

    fn validated_deletion_paths(&self, paths: Vec<String>) -> Result<Vec<PathBuf>, ProtocolError> {
        if self.state.busy {
            return Err(ProtocolError::new(
                "busy",
                "another background operation is still running",
            ));
        }
        let mut result = Vec::new();
        for raw in paths {
            let path = PathBuf::from(raw);
            if !path.exists() {
                continue;
            }
            ops::safe_for_deletion(&path)
                .map_err(|error| ProtocolError::new("invalid_path", error))?;
            result.push(path);
        }
        if result.is_empty() {
            return Err(ProtocolError::new(
                "not_found",
                "no existing paths selected",
            ));
        }
        Ok(result)
    }

    fn start_operation<F>(&mut self, status: String, work: F)
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

    fn add_favorite(&mut self, path: PathBuf) -> Result<Option<String>, ProtocolError> {
        let path = ops::normalize_path(&path);
        if !path.is_dir() {
            return Err(ProtocolError::new(
                "not_a_directory",
                "only folders can be added to quick access",
            ));
        }
        let label = path.to_string_lossy().into_owned();
        if !self.config.quick_access.contains(&label) {
            self.config.quick_access.push(label);
            self.state.favorites = self.config.quick_access.clone();
            self.save_config();
        }
        Ok(Some(format!("Added {} to quick access", path.display())))
    }

    fn remove_favorite(&mut self, path: &str) -> Result<Option<String>, ProtocolError> {
        let before = self.config.quick_access.len();
        self.config.quick_access.retain(|favorite| favorite != path);
        if self.config.quick_access.len() == before {
            return Err(ProtocolError::new(
                "not_found",
                "that folder is not in quick access",
            ));
        }
        self.state.favorites = self.config.quick_access.clone();
        self.save_config();
        Ok(Some("Removed from quick access".to_owned()))
    }

    fn move_favorite(
        &mut self,
        path: &str,
        direction: MoveDirection,
    ) -> Result<Option<String>, ProtocolError> {
        let Some(index) = self
            .config
            .quick_access
            .iter()
            .position(|favorite| favorite == path)
        else {
            return Err(ProtocolError::new(
                "not_found",
                "that folder is not in quick access",
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

    fn save_config(&mut self) {
        if let Err(error) = self.config.save(&self.config_path) {
            tracing::error!(
                target: "kogaview::config",
                path = %self.config_path.display(),
                %error,
                "cannot save configuration"
            );
            self.state.status = format!("Cannot save configuration: {error}");
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
        let mut last = core.listing_epoch();
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

        std::fs::remove_dir_all(base).unwrap();
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
        std::fs::remove_dir_all(dir).unwrap();
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

        std::fs::remove_dir_all(base).unwrap();
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

        std::fs::remove_dir_all(base).unwrap();
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

        std::fs::remove_dir_all(base).unwrap();
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

        std::fs::remove_dir_all(base).unwrap();
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
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn nothing_opens_when_no_saved_folder_survives() {
        let (root, folder) = restored_folders(Some("/gone"), Some("/gone-too"), |_| false);
        assert!(root.is_none());
        assert!(folder.is_none());
        let (root, folder) = restored_folders(None, None, |_| true);
        assert!(root.is_none() && folder.is_none());
    }
}
