//! Serializable view of Core state.
//!
//! The UI renders this snapshot; it never mutates it. Every field here is
//! produced by Core after a command or a completed background task.

use kogaview_protocol::{Language, LayoutState, Theme, Workspace};
use serde::Serialize;

// The line shape is part of the protocol: both a successful command result and
// a rejected one carry one, so it lives next to `ProtocolError` and Core only
// re-exports it.
pub use kogaview_protocol::UiText;

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

/// A live batch job, or the last one that finished.
///
/// Core publishes this so the Browser's Batch page can draw "12 of 40" and a
/// Cancel button without owning any of the work. `running` is false after the
/// job ends, and the counts stay so the page can report what happened until the
/// next job replaces them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchState {
    /// `resize`, `crop` or `convert` — the operation's stable name.
    pub operation: String,
    pub total: usize,
    pub done: usize,
    pub failed: usize,
    pub running: bool,
    pub cancelled: bool,
    /// The file being written now, or the last one the job reported.
    pub current: String,
}

/// A live-preview render: which tool produced it (`resize` or `crop`), the
/// target size and where the pixels are, so the canvas can draw the result
/// without the document moving.
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EditorPreviewDraft {
    /// `resize` or `crop`; the view shows a draft only while its tool is
    /// selected, so switching tools never paints the other tool's result.
    pub kind: String,
    pub path: String,
    pub width: u32,
    pub height: u32,
}

/// What the Editor paints, projected from the Core-owned working document.
///
/// The pixels stay in Core; this is the serializable description the UI needs:
/// identity, size, whether undo/redo can do anything, the applied-operation
/// labels, and where the latest preview PNG lives. `previewRevision` lets the
/// view tell a stale image from the current one; `rendering` is true while a
/// worker is still encoding the preview for the newest edit.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorState {
    /// The source image; never written to.
    pub path: String,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub can_undo: bool,
    pub can_redo: bool,
    pub modified: bool,
    /// Labels of the applied operations, oldest first. Each is a code plus the
    /// numbers it mentions, so the History panel can speak the interface
    /// language without Core knowing which language that is.
    pub history: Vec<UiText>,
    pub redo_count: usize,
    pub preview_path: Option<String>,
    pub preview_revision: u64,
    /// Identity of the preview file (milliseconds since the epoch, and its
    /// size in bytes). The thumbnail cache keys on these, so a preview file
    /// whose name is reused by a later run can never answer with an older
    /// thumbnail — the paths repeat every run, the timestamps do not.
    pub preview_modified: u64,
    pub preview_size: u64,
    /// Identity of the file on disk the document was last saved to (or opened
    /// from), the same pair for the same reason: the Original tab draws that
    /// file's thumbnail and must follow a Save, whose write changes both
    /// numbers while the path may stay the same.
    pub file_modified: u64,
    pub file_size: u64,
    /// The live-preview resize, when one is armed. Independent of the document
    /// and its history: `null` while nothing is being previewed.
    pub preview_draft: Option<EditorPreviewDraft>,
    pub rendering: bool,
    /// Where saving would write. It follows the source until a save-as or a
    /// save to another file moves it.
    pub save_path: String,
    /// True when the working pixels are on disk at `save_path`.
    pub saved: bool,
    /// The save style the file list advertises (`.jpg`, `.png`), derived from
    /// the save path's extension.
    pub format: String,
    /// True while the pixels are being encoded and written on a worker.
    pub saving: bool,
    /// True while what the canvas shows is the first, reduced decode of an
    /// image whose full frame is still being decoded. The picture and the
    /// document size are already right, so the window can draw it; the tools
    /// wait, because Core has no pixels to edit yet.
    pub opening: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    pub revision: u64,
    pub workspace: Workspace,
    pub theme: Theme,
    /// The interface language the settings ask for (`system` by default).
    pub language: Language,
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
    /// Which panels each workspace shows, the two dock widths and the Editor's
    /// split. Core owns it because it is saved in `config.json`; a view reads it
    /// and asks for a change with `set_layout`.
    pub layout: LayoutState,
    pub filmstrip: bool,
    /// The two settings the Settings dialog edits besides the theme. They are
    /// published so the dialog opens on what is stored, not on a default.
    pub remember_last_folder: bool,
    pub background_thumbnails: bool,
    pub viewer_images: Vec<String>,
    pub viewer_index: Option<usize>,
    pub viewer_path: Option<String>,
    /// The identity of the bytes the Viewer is showing: modification time in
    /// milliseconds and size in bytes. The path alone cannot tell "the same
    /// picture again" from "the same path with new bytes on disk", and a QML
    /// `Image` whose `source` string does not change never reloads, so an
    /// externally edited file kept its old pixels. `(0, 0)` means no file.
    pub viewer_modified: u64,
    pub viewer_size: u64,
    /// The Editor's working document, or `None` when nothing is open. Pixels
    /// live in Core's `EditorDocument`; this is the published description.
    pub editor: Option<EditorState>,
    /// The batch job in flight, or the last one that finished. `None` until the
    /// first job, so the Batch page can tell "never run" from "finished".
    pub batch: Option<BatchState>,
    pub busy: bool,
    /// What the status bar says, as a translatable line.
    pub status: UiText,
    pub config_path: String,
    pub home: String,
    pub item_count: usize,
    pub image_count: usize,
}

impl UiState {
    pub fn new(
        theme: Theme,
        language: Language,
        favorites: Vec<String>,
        layout: LayoutState,
        filmstrip: bool,
        remember_last_folder: bool,
        background_thumbnails: bool,
        config_path: String,
    ) -> Self {
        Self {
            revision: 0,
            workspace: Workspace::Browser,
            theme,
            language,
            current_folder: None,
            root_folder: None,
            tree_revision: 0,
            breadcrumbs: Vec::new(),
            entries: Vec::new(),
            selection: Vec::new(),
            selection_info: None,
            favorites,
            layout,
            filmstrip,
            remember_last_folder,
            background_thumbnails,
            viewer_images: Vec::new(),
            viewer_index: None,
            viewer_path: None,
            viewer_modified: 0,
            viewer_size: 0,
            editor: None,
            batch: None,
            busy: false,
            status: UiText::new("ready"),
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
            language: &self.language,
            current_folder: &self.current_folder,
            root_folder: &self.root_folder,
            tree_revision: self.tree_revision,
            breadcrumbs: &self.breadcrumbs,
            selection: &self.selection,
            selection_info: &self.selection_info,
            favorites: &self.favorites,
            layout: &self.layout,
            filmstrip: self.filmstrip,
            remember_last_folder: self.remember_last_folder,
            background_thumbnails: self.background_thumbnails,
            viewer_index: self.viewer_index,
            viewer_path: &self.viewer_path,
            viewer_modified: self.viewer_modified,
            viewer_size: self.viewer_size,
            editor: &self.editor,
            batch: &self.batch,
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
    pub language: &'a Language,
    pub current_folder: &'a Option<String>,
    pub root_folder: &'a Option<String>,
    pub tree_revision: u64,
    pub breadcrumbs: &'a [Crumb],
    pub selection: &'a [String],
    pub selection_info: &'a Option<SelectionInfo>,
    pub favorites: &'a [String],
    pub layout: &'a LayoutState,
    pub filmstrip: bool,
    pub remember_last_folder: bool,
    pub background_thumbnails: bool,
    pub viewer_index: Option<usize>,
    pub viewer_path: &'a Option<String>,
    /// The bytes behind `viewer_path`; see `UiState::viewer_modified`.
    pub viewer_modified: u64,
    pub viewer_size: u64,
    pub editor: &'a Option<EditorState>,
    pub batch: &'a Option<BatchState>,
    pub busy: bool,
    pub status: &'a UiText,
    pub config_path: &'a str,
    pub home: &'a str,
    pub item_count: usize,
    pub image_count: usize,
}
