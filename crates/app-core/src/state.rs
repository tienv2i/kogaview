//! Serializable view of Core state.
//!
//! The UI renders this snapshot; it never mutates it. Every field here is
//! produced by Core after a command or a completed background task.

use kogaview_protocol::{Theme, Workspace};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub is_image: bool,
    pub size: u64,
    pub modified: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Crumb {
    pub name: String,
    pub path: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectionInfo {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub size: u64,
    pub modified: u64,
    pub is_image: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    pub revision: u64,
    pub workspace: Workspace,
    pub theme: Theme,
    pub current_folder: Option<String>,
    /// Folder the explorer tree is rooted at. Only an explicit open (quick
    /// access, "Open folder", launch argument) moves it; plain navigation
    /// inside the tree or the grid leaves it alone.
    pub root_folder: Option<String>,
    /// Bumped whenever an operation may have changed the folder tree (copy,
    /// move, trash, delete, new folder, explicit refresh). The explorer reloads
    /// its nodes when this changes and keeps its expansion and current folder.
    pub tree_revision: u64,
    pub breadcrumbs: Vec<Crumb>,
    pub entries: Vec<Entry>,
    pub selection: Vec<String>,
    pub selection_info: Option<SelectionInfo>,
    pub favorites: Vec<String>,
    pub left_panel: bool,
    pub right_panel: bool,
    pub filmstrip: bool,
    pub viewer_images: Vec<String>,
    pub viewer_index: Option<usize>,
    pub viewer_path: Option<String>,
    pub busy: bool,
    pub status: String,
    pub config_path: String,
    pub home: String,
    pub item_count: usize,
    pub image_count: usize,
}

impl UiState {
    pub fn new(
        theme: Theme,
        favorites: Vec<String>,
        left_panel: bool,
        right_panel: bool,
        filmstrip: bool,
        config_path: String,
    ) -> Self {
        Self {
            revision: 0,
            workspace: Workspace::Browser,
            theme,
            current_folder: None,
            root_folder: None,
            tree_revision: 0,
            breadcrumbs: Vec::new(),
            entries: Vec::new(),
            selection: Vec::new(),
            selection_info: None,
            favorites,
            left_panel,
            right_panel,
            filmstrip,
            viewer_images: Vec::new(),
            viewer_index: None,
            viewer_path: None,
            busy: false,
            status: "Ready".to_owned(),
            config_path,
            home: crate::paths::home_dir().to_string_lossy().into_owned(),
            item_count: 0,
            image_count: 0,
        }
    }

    pub fn bump(&mut self) {
        self.revision += 1;
    }
}
