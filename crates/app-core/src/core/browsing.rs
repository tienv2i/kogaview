//! The Browser's commands: folders, scans, selection, files and the settings
//! that describe them.
//!
//! A scan runs on a worker and answers through `Core::poll`; everything else in
//! this module either changes the listing or a preference that outlives it.
use super::*;

impl Core {
    pub(super) fn open_file(
        &mut self,
        paths: Vec<String>,
    ) -> Result<Option<UiText>, ProtocolError> {
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
        self.set_viewer_path(Some(first.to_string_lossy().into_owned()));
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

    pub(super) fn open_folder(
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

    pub(super) fn refresh_current(&mut self) {
        let Some(folder) = self.state.current_folder.clone() else {
            return;
        };
        let selection = self.state.selection.clone();
        self.pending_selection = Some(selection);
        self.pending_viewer = self.state.viewer_path.clone();
        self.start_scan(PathBuf::from(folder), false, false);
    }

    pub(super) fn start_scan(&mut self, folder: PathBuf, clear_entries: bool, restore: bool) {
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

    pub(super) fn apply_scan(&mut self, result: ScanResult) -> bool {
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
                self.sort_entries();
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

    /// Sort `self.state.entries` according to `self.state.layout.browser_sort_by`
    /// and `browser_sort_order`, always keeping directories ahead of files.
    pub(super) fn sort_entries(&mut self) {
        let sort_by = self.state.layout.browser_sort_by.clone();
        let descending = self.state.layout.browser_sort_order == "desc";
        self.state.entries.sort_by(|a, b| {
            // Directories always stay grouped before files.
            let group = b.is_dir.cmp(&a.is_dir);
            if group != std::cmp::Ordering::Equal {
                return group;
            }
            let primary = match sort_by.as_str() {
                "modified" => a.modified.cmp(&b.modified),
                "size" => a.size.cmp(&b.size),
                "kind" => {
                    let ext_a = Path::new(&a.name)
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("")
                        .to_lowercase();
                    let ext_b = Path::new(&b.name)
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("")
                        .to_lowercase();
                    ext_a.cmp(&ext_b)
                }
                _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            };
            let ordered = if descending {
                primary.reverse()
            } else {
                primary
            };
            ordered.then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
    }

    pub(super) fn set_selection(&mut self, paths: Vec<String>) {
        self.state.selection = paths;
        self.state.selection_info = self.build_selection_info();
    }

    pub(super) fn build_selection_info(&self) -> Option<SelectionInfo> {
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

    pub(super) fn set_theme(&mut self, theme: Theme) {
        self.config.theme = theme;
        self.state.theme = theme;
        self.save_config();
    }

    pub(super) fn new_folder(
        &mut self,
        parent: PathBuf,
        name: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
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

    pub(super) fn transfer(
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

    pub(super) fn trash_paths(
        &mut self,
        paths: Vec<String>,
    ) -> Result<Option<UiText>, ProtocolError> {
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

    pub(super) fn delete_paths(
        &mut self,
        paths: Vec<String>,
    ) -> Result<Option<UiText>, ProtocolError> {
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

    pub(super) fn validated_deletion_paths(
        &self,
        paths: Vec<String>,
    ) -> Result<Vec<PathBuf>, ProtocolError> {
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

    pub(super) fn add_favorite(&mut self, path: PathBuf) -> Result<Option<UiText>, ProtocolError> {
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

    pub(super) fn remove_favorite(&mut self, path: &str) -> Result<Option<UiText>, ProtocolError> {
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

    pub(super) fn move_favorite(
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
    pub(super) fn save_explorer_folders(&mut self, root: String, folder: String) {
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
    pub(super) fn remember_explorer_folders(&mut self) {
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

    pub(super) fn save_config(&mut self) {
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

    /// Hide or show a whole side of the open workspace.
    ///
    /// The old command toggled one boolean per dock. Now a side is a list of
    /// panels: when any of them is visible, the command hides them all; when
    /// none is, it shows them all, so one press still means "the other state"
    /// and no panel is left behind in a half-shown dock.
    pub(super) fn toggle_panels(&mut self, keys: &[&str]) {
        let any_shown = keys.iter().any(|key| self.config.layout.panel(key));
        let mut layout = self.config.layout.clone();
        for key in keys {
            layout = layout.with_panel(key, !any_shown);
        }
        let layout = layout.sanitized();
        self.config.layout = layout.clone();
        self.state.layout = layout;
        self.save_config();
    }
}
