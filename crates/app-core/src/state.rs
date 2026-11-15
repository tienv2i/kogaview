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
    /// Folder the explorer tree is rooted at. It is kept apart from
    /// `current_folder`: the tree may stay at a parent while the list shows a
    /// child. Navigation moves it only when the folder leaves its subtree
    /// (breadcrumbs to an ancestor, "up" past the root); opening a folder that
    /// is already inside the tree leaves it alone.
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

    /// The snapshot without its folder listing.
    ///
    /// The listing is published apart ([`FolderListing`]), because it is the one
    /// part that grows with the folder — roughly 170 bytes per item and 30 per
    /// image path, so a thousand photos serialise to a 200 KB string — while
    /// everything here stays around a kilobyte and can travel on every state
    /// change. `entries`/`viewerImages` are simply absent from the result: the
    /// window splices in the listing it already parsed.
    pub fn meta(&self) -> StateMeta<'_> {
        StateMeta {
            revision: self.revision,
            workspace: &self.workspace,
            theme: &self.theme,
            current_folder: &self.current_folder,
            root_folder: &self.root_folder,
            tree_revision: self.tree_revision,
            breadcrumbs: &self.breadcrumbs,
            selection: &self.selection,
            selection_info: &self.selection_info,
            favorites: &self.favorites,
            left_panel: self.left_panel,
            right_panel: self.right_panel,
            filmstrip: self.filmstrip,
            viewer_index: self.viewer_index,
            viewer_path: &self.viewer_path,
            busy: self.busy,
            status: &self.status,
            config_path: &self.config_path,
            home: &self.home,
            item_count: self.item_count,
            image_count: self.image_count,
        }
    }
}

/// Everything in the snapshot that grows with the folder, and nothing else.
///
/// Shipped by the Qt adapter under its own epoch, because it changes only when
/// the folder listing does: a click or an arrow key in the grid must not pay for
/// a thousand entries.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderListing<'a> {
    pub entries: &'a [Entry],
    pub viewer_images: &'a [String],
}

/// Everything a Browser or Viewer paints that does not grow with the folder.
///
/// The folder listing itself has no field here at all: serialising it into the
/// metadata only to be thrown away on the other side would make every command
/// cost as much as the folder is big.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateMeta<'a> {
    pub revision: u64,
    pub workspace: &'a Workspace,
    pub theme: &'a Theme,
    pub current_folder: &'a Option<String>,
    pub root_folder: &'a Option<String>,
    pub tree_revision: u64,
    pub breadcrumbs: &'a [Crumb],
    pub selection: &'a [String],
    pub selection_info: &'a Option<SelectionInfo>,
    pub favorites: &'a [String],
    pub left_panel: bool,
    pub right_panel: bool,
    pub filmstrip: bool,
    pub viewer_index: Option<usize>,
    pub viewer_path: &'a Option<String>,
    pub busy: bool,
    pub status: &'a str,
    pub config_path: &'a str,
    pub home: &'a str,
    pub item_count: usize,
    pub image_count: usize,
}
