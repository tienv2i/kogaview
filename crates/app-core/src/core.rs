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
use crate::state::{Crumb, SelectionInfo, UiState};
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
        };

        if let Some(folder) = core.config.last_folder.clone() {
            let path = PathBuf::from(folder);
            if path.is_dir() {
                core.state.root_folder = Some(path.to_string_lossy().into_owned());
                core.start_scan(path, false, true);
            }
        }

        core
    }

    pub fn snapshot_json(&self) -> String {
        serde_json::to_string(&self.state).unwrap_or_else(|error| {
            tracing::error!(target: "kogaview::core", %error, "cannot serialize state");
            "{}".to_owned()
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
                let path = PathBuf::from(path);
                let canonical = match path.canonicalize() {
                    Ok(path) if path.is_dir() => path,
                    _ => {
                        return json!({
                            "ok": false,
                            "error": { "code": "not_found", "message": format!("{} is not a directory", path.display()) }
                        })
                        .to_string();
                    }
                };
                match ops::list_folders(&canonical) {
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
        let first = PathBuf::from(first)
            .canonicalize()
            .map_err(|error| ProtocolError::new("not_found", format!("{error}")))?;

        if first.is_dir() {
            return self.open_folder(first, true);
        }

        let parent = first
            .parent()
            .ok_or_else(|| ProtocolError::new("invalid_path", "file has no parent folder"))?
            .to_path_buf();

        let canonical_paths = paths
            .iter()
            .filter_map(|path| PathBuf::from(path).canonicalize().ok())
            .filter(|path| path.is_file())
            .map(|path| path.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        self.state.workspace = Workspace::Viewer;
        self.state.viewer_path = Some(first.to_string_lossy().into_owned());
        self.pending_viewer = self.state.viewer_path.clone();
        self.pending_selection = Some(if canonical_paths.is_empty() {
            vec![first.to_string_lossy().into_owned()]
        } else {
            canonical_paths
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
        let canonical = path
            .canonicalize()
            .map_err(|error| ProtocolError::new("not_found", format!("{error}")))?;
        if !canonical.is_dir() {
            return Err(ProtocolError::new(
                "not_a_directory",
                format!("{} is not a directory", canonical.display()),
            ));
        }

        if set_browser_workspace {
            self.state.workspace = Workspace::Browser;
            // Only an explicit open re-roots the explorer; `Navigate` (tree
            // clicks, double-clicking a folder in the grid, breadcrumbs) keeps
            // the tree where the user opened it.
            self.state.root_folder = Some(canonical.to_string_lossy().into_owned());
        }
        self.pending_viewer = None;
        self.pending_selection = None;
        self.config.last_folder = Some(canonical.to_string_lossy().into_owned());
        self.save_config();
        self.start_scan(canonical.clone(), true, false);
        Ok(Some(format!("Opened {}", canonical.display())))
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
        let parent = parent
            .canonicalize()
            .map_err(|error| ProtocolError::new("not_found", format!("{error}")))?;
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
        let destination = destination
            .canonicalize()
            .map_err(|error| ProtocolError::new("not_found", format!("{error}")))?;
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
            let canonical = source.canonicalize().unwrap_or_else(|_| source.clone());
            if canonical.is_dir()
                && (destination.starts_with(&canonical) || canonical == destination)
            {
                return Err(ProtocolError::new(
                    "invalid_destination",
                    format!("cannot copy or move {} into itself", canonical.display()),
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
        let canonical = path
            .canonicalize()
            .map_err(|error| ProtocolError::new("not_found", format!("{error}")))?;
        if !canonical.is_dir() {
            return Err(ProtocolError::new(
                "not_a_directory",
                "only folders can be added to quick access",
            ));
        }
        let label = canonical.to_string_lossy().into_owned();
        if !self.config.quick_access.contains(&label) {
            self.config.quick_access.push(label);
            self.state.favorites = self.config.quick_access.clone();
            self.save_config();
        }
        Ok(Some(format!(
            "Added {} to quick access",
            canonical.display()
        )))
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
}
