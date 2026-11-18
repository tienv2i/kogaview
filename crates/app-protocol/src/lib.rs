//! Typed protocol shared by the UI, CLI, local IPC and MCP adapters.
//!
//! Commands are the only way to mutate Core state. Queries are read-only and
//! events are emitted by Core; they are separate types on purpose.

use serde::{Deserialize, Serialize};

/// Wire protocol version. Independent from the application semantic version.
pub const PROTOCOL_VERSION: u32 = 1;

/// Extensions the browser treats as images and the Editor decodes.
///
/// Kept here rather than in Core so every front end (the Qt file dialog now,
/// the CLI and the IPC/MCP adapters later) offers exactly the same list. The
/// decoders are compiled into the binary — nothing is fetched at run time —
/// which is what keeps a sandboxed Flatpak build able to open the same formats.
/// HEIC/HEIF are listed although no `image` decoder exists for them: hiding a
/// modern phone format would be worse than saying "no decoder" when one is
/// opened.
pub const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jfif", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "heic", "heif",
    "dds", "exr", "hdr", "ico", "pnm", "pbm", "pgm", "ppm", "qoi", "tga", "ff",
];

/// The same list as a Qt file-dialog name filter (`Images (*.jpg …)`).
pub fn image_name_filter() -> String {
    let patterns: Vec<String> = IMAGE_EXTENSIONS
        .iter()
        .map(|extension| format!("*.{extension}"))
        .collect();
    format!("Images ({})", patterns.join(" "))
}

/// The three UI workspaces. Navigation is a Core concern, not QML state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Workspace {
    Browser,
    Viewer,
    Editor,
}

impl Workspace {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Browser => "browser",
            Self::Viewer => "viewer",
            Self::Editor => "editor",
        }
    }
}

impl Default for Workspace {
    fn default() -> Self {
        Self::Browser
    }
}

/// The axis a flip mirrors the working image across. Parts of the Editor
/// protocol; kept here so the CLI/IPC/MCP front ends share the one type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FlipAxis {
    /// Mirror left/right (a vertical mirror line).
    Horizontal,
    /// Mirror top/bottom (a horizontal mirror line).
    Vertical,
}

/// Interface language. The UI text is translated at runtime from `.ts` files
/// compiled into the binary; Core only carries the selection.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Language {
    /// Follow the desktop's own locale.
    #[default]
    System,
    /// Follow the language of the documents being edited.
    Editor,
    #[serde(rename = "en")]
    English,
    #[serde(rename = "vi")]
    Vietnamese,
}

impl Language {
    /// The value QML and the settings dialog use.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Editor => "editor",
            Self::English => "en",
            Self::Vietnamese => "vi",
        }
    }

    /// The locale the translator should be installed for, or `None` when the
    /// language follows the desktop (Qt's default translator stays in charge).
    pub const fn requested(self) -> Option<&'static str> {
        match self {
            Self::System => None,
            // Editor-language UI is not wired yet: it falls back to the
            // desktop locale rather than pretending to follow the document.
            Self::Editor => None,
            Self::English => Some("en"),
            Self::Vietnamese => Some("vi"),
        }
    }
}

/// Presentation theme. Persisted in the user configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    Light,
    Dark,
}

impl Theme {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub const fn toggled(self) -> Self {
        match self {
            Self::Light => Self::Dark,
            Self::Dark => Self::Light,
        }
    }
}

impl Default for Theme {
    fn default() -> Self {
        Self::Dark
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MoveDirection {
    Up,
    Down,
}

/// A command envelope. The id is echoed back and recorded in the journal.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub id: String,
    #[serde(default = "default_protocol")]
    pub protocol: u32,
    pub command: Command,
}

fn default_protocol() -> u32 {
    PROTOCOL_VERSION
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    OpenFile {
        paths: Vec<String>,
    },
    OpenFolder {
        path: String,
    },
    Navigate {
        path: String,
    },
    Refresh,
    Select {
        paths: Vec<String>,
    },
    SetWorkspace {
        workspace: Workspace,
    },
    SetTheme {
        theme: Theme,
    },
    SetSettings {
        theme: Theme,
        remember_last_folder: bool,
        background_thumbnails: bool,
        #[serde(default)]
        language: Language,
    },
    ToggleTheme,
    /// Set the interface language (`system`, `editor`, `en` or `vi`).
    SetLanguage {
        language: Language,
    },
    ToggleLeftPanel,
    ToggleRightPanel,
    ToggleFilmstrip,
    NewFolder {
        parent: String,
        name: String,
    },
    CopyTo {
        paths: Vec<String>,
        destination: String,
    },
    MoveTo {
        paths: Vec<String>,
        destination: String,
    },
    Trash {
        paths: Vec<String>,
    },
    DeletePermanently {
        paths: Vec<String>,
    },
    AddFavorite {
        path: String,
    },
    RemoveFavorite {
        path: String,
    },
    MoveFavorite {
        path: String,
        direction: MoveDirection,
    },
    ViewerNext,
    ViewerPrevious,
    ViewerOpen {
        path: String,
    },
    /// Load an image into the Editor workspace. The source file is never
    /// modified; all edits live in a working document in Core.
    EditorOpen {
        path: String,
    },
    /// Write the working document over its own source file. Core refuses when
    /// the source changed on disk since it was opened, and keeps a `.bak`
    /// copy of the previous bytes. Never the default: the UI asks twice.
    EditorSave,
    /// Write the working document to another file, leaving the source alone.
    /// The extension of `path` picks the encoding (PNG, JPEG, WebP, …).
    EditorSaveAs {
        path: String,
    },
    /// Scale the working document to fit exactly `width` × `height`. When the
    /// target aspect differs the source is cropped around its centre before
    /// scaling, so pixels are never stretched. An optional `fill` colour pads
    /// the shorter side to a square (side = the longer edge) first, also
    /// centred. Resize is not anchored: where the result sits is a Crop
    /// decision, not a Resize one.
    EditorResize {
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
    },
    /// Render the resize in the canvas without changing the document: the
    /// pixels, the history and the save target stay as they are until
    /// `EditorResize` is applied. The draft preview is published as
    /// `editor.previewDraft`.
    EditorResizePreview {
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
    },
    /// Cut the working document to the given rectangle, in document pixels.
    EditorCrop {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    },
    /// Rotate the working document clockwise; degrees must be 90, 180 or 270
    /// (negative values rotate counter-clockwise).
    EditorRotate {
        degrees: i32,
    },
    EditorFlip {
        axis: FlipAxis,
    },
    EditorUndo,
    EditorRedo,
    /// Discard every edit and return the working document to the source image.
    EditorReset,
    /// Drop the working document. The source file is untouched.
    EditorClose,
    CancelOperation,
}

impl Command {
    /// Stable command name used by the journal and logs.
    pub fn name(&self) -> &'static str {
        match self {
            Self::OpenFile { .. } => "open_file",
            Self::OpenFolder { .. } => "open_folder",
            Self::Navigate { .. } => "navigate",
            Self::Refresh => "refresh",
            Self::Select { .. } => "select",
            Self::SetWorkspace { .. } => "set_workspace",
            Self::SetTheme { .. } => "set_theme",
            Self::SetSettings { .. } => "set_settings",
            Self::ToggleTheme => "toggle_theme",
            Self::SetLanguage { .. } => "set_language",
            Self::ToggleLeftPanel => "toggle_left_panel",
            Self::ToggleRightPanel => "toggle_right_panel",
            Self::ToggleFilmstrip => "toggle_filmstrip",
            Self::NewFolder { .. } => "new_folder",
            Self::CopyTo { .. } => "copy_to",
            Self::MoveTo { .. } => "move_to",
            Self::Trash { .. } => "trash",
            Self::DeletePermanently { .. } => "delete_permanently",
            Self::AddFavorite { .. } => "add_favorite",
            Self::RemoveFavorite { .. } => "remove_favorite",
            Self::MoveFavorite { .. } => "move_favorite",
            Self::ViewerNext => "viewer_next",
            Self::ViewerPrevious => "viewer_previous",
            Self::ViewerOpen { .. } => "viewer_open",
            Self::CancelOperation => "cancel_operation",
            Self::EditorOpen { .. } => "editor_open",
            Self::EditorSave => "editor_save",
            Self::EditorSaveAs { .. } => "editor_save_as",
            Self::EditorResize { .. } => "editor_resize",
            Self::EditorResizePreview { .. } => "editor_resize_preview",
            Self::EditorCrop { .. } => "editor_crop",
            Self::EditorRotate { .. } => "editor_rotate",
            Self::EditorFlip { .. } => "editor_flip",
            Self::EditorUndo => "editor_undo",
            Self::EditorRedo => "editor_redo",
            Self::EditorReset => "editor_reset",
            Self::EditorClose => "editor_close",
        }
    }
}

/// Read-only query surface. Queries never mutate state.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Query {
    ListFolders { path: String },
    State,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

impl ProtocolError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_names_are_stable() {
        assert_eq!(Workspace::default(), Workspace::Browser);
        assert_eq!(Workspace::Browser.as_str(), "browser");
        assert_eq!(Workspace::Viewer.as_str(), "viewer");
        assert_eq!(Workspace::Editor.as_str(), "editor");
    }

    #[test]
    fn command_wire_names_are_stable() {
        let env: Envelope =
            serde_json::from_str(r#"{"id":"a","command":{"type":"toggle_theme"}}"#).unwrap();
        assert_eq!(env.protocol, PROTOCOL_VERSION);
        assert_eq!(env.command.name(), "toggle_theme");

        let command = Command::CopyTo {
            paths: vec!["/a.jpg".into()],
            destination: "/tmp".into(),
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"copy_to\""));
        assert!(json.contains("\"destination\""));
    }

    #[test]
    fn theme_toggles_both_ways() {
        assert_eq!(Theme::Dark.toggled(), Theme::Light);
        assert_eq!(Theme::Light.toggled(), Theme::Dark);
    }

    #[test]
    fn editor_commands_round_trip_and_name() {
        let commands = vec![
            (
                Command::EditorOpen {
                    path: "/a.jpg".into(),
                },
                "editor_open",
            ),
            (
                Command::EditorResize {
                    width: 800,
                    height: 600,
                    fill: None,
                },
                "editor_resize",
            ),
            (
                Command::EditorResizePreview {
                    width: 800,
                    height: 600,
                    fill: Some([1, 2, 3]),
                },
                "editor_resize_preview",
            ),
            (
                Command::EditorCrop {
                    x: 10,
                    y: 20,
                    width: 300,
                    height: 400,
                },
                "editor_crop",
            ),
            (Command::EditorRotate { degrees: 90 }, "editor_rotate"),
            (
                Command::EditorFlip {
                    axis: FlipAxis::Vertical,
                },
                "editor_flip",
            ),
            (Command::EditorUndo, "editor_undo"),
            (Command::EditorRedo, "editor_redo"),
            (Command::EditorReset, "editor_reset"),
            (Command::EditorClose, "editor_close"),
        ];
        for (command, expected_name) in commands {
            let json = serde_json::to_string(&command).unwrap();
            assert!(json.contains(&format!("\"{expected_name}\"")), "{json}");
            let round: Command = serde_json::from_str(&json).unwrap();
            assert_eq!(serde_json::to_string(&round).unwrap(), json);
            assert_eq!(round.name(), expected_name);
        }
        // FlipAxis wire values are snake_case and stable.
        let json = serde_json::to_string(&Command::EditorFlip {
            axis: FlipAxis::Horizontal,
        })
        .unwrap();
        assert!(json.contains("\"horizontal\""));
        let env: Envelope =
            serde_json::from_str(r#"{"id":"e","command":{"type":"editor_rotate","degrees":-90}}"#)
                .unwrap();
        assert_eq!(env.command.name(), "editor_rotate");

        // Older resize commands carry no fill; the field defaults to no
        // padding. An `anchor` from the short-lived anchored design is simply
        // ignored, because Resize no longer has one.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize {
                fill,
                width,
                height,
            } => {
                assert_eq!((width, height), (64, 32));
                assert_eq!(fill, None);
            }
            other => panic!("unexpected command {other:?}"),
        }
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32,"anchor":"bottom_right","fill":[1,2,3]}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize { fill, .. } => {
                assert_eq!(fill, Some([1, 2, 3]));
            }
            other => panic!("unexpected command {other:?}"),
        }
        // The draft preview is the same shape and is journalled under its own
        // name, so a preview never looks like an applied resize.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize_preview","width":1024,"height":1024}}"#,
        )
        .unwrap();
        assert_eq!(env.command.name(), "editor_resize_preview");
    }
}
