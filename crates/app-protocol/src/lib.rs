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
    /// Write a copy for delivery, leaving the document exactly as it is: the
    /// save target, the saved flag and the history do not move. `quality`
    /// (1–100) applies to the lossy encoders (JPEG today); `metadata` keeps the
    /// source's EXIF/XMP/ICC segments when both files are JPEG. Exporting onto
    /// the document's own file is refused — that is what `editor_save` is for.
    EditorExport {
        path: String,
        #[serde(default)]
        quality: Option<u8>,
        #[serde(default)]
        metadata: bool,
    },
    /// Scale the working document to exactly `width` × `height`. Without a
    /// `fill`, the target aspect is covered by a centred crop before scaling,
    /// so pixels are never stretched. With a `fill`, the whole source is scaled
    /// to fit inside the target and the leftover is padded with that RGB
    /// colour, centred; the pad is only square when the target is square.
    /// Resize is not anchored: where the result sits is a Crop decision, not a
    /// Resize one.
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
    /// Render the crop in the canvas without cutting the document: the pixels,
    /// the history and the save target stay as they are until `EditorCrop` is
    /// applied. The draft is published as `editor.previewDraft` with
    /// `kind: "crop"`.
    EditorCropPreview {
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
            Self::EditorExport { .. } => "editor_export",
            Self::EditorResize { .. } => "editor_resize",
            Self::EditorResizePreview { .. } => "editor_resize_preview",
            Self::EditorCrop { .. } => "editor_crop",
            Self::EditorCropPreview { .. } => "editor_crop_preview",
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

/// A line meant for the interface, with its wording kept out of Core.
///
/// Core knows *what* happened — a folder loaded, a resize was applied, a
/// destination was rejected — and the interface knows *how to say it* in the
/// current language. Publishing a `code` plus positional `args` instead of a
/// formatted English sentence is what lets the QML translate at the edge, where
/// the active translator lives. The codes are part of the published contract:
/// `crates/desktop/qml/UiLines.qml` is the one place that maps them to
/// sentences, and an unknown code falls back to joining its arguments so a
/// newer Core cannot blank the status bar.
///
/// It lives in the protocol crate rather than Core because a command *result*
/// carries one too — both the success line and the error line travel over the
/// same wire shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiText {
    pub code: String,
    pub args: Vec<String>,
}

impl UiText {
    /// A line with no arguments.
    pub fn new(code: &str) -> Self {
        Self {
            code: code.to_owned(),
            args: Vec::new(),
        }
    }

    /// A line whose sentence is completed by the given positional arguments.
    pub fn with(code: &str, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            code: code.to_owned(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }

    /// The empty line, used to hide the status bar's message.
    pub fn empty() -> Self {
        Self::new("")
    }

    pub fn is_empty(&self) -> bool {
        self.code.is_empty()
    }

    /// The English rendering used by the command journal, the structured log
    /// and any front end that has no translator: the code with its underscores
    /// opened up, followed by the arguments.
    ///
    /// It is deliberately mechanical rather than a second table of sentences:
    /// the interface's wording lives in the QML (one `qsTr` per code), and a
    /// paraphrase here would be a translation nobody maintains. A reader of
    /// `journal/commands.jsonl` has the command name next to it, so
    /// `editor_export` + `exporting pic-export.jpg` reads unambiguously.
    pub fn english(&self) -> String {
        if self.code.is_empty() {
            return String::new();
        }
        let mut text = self.code.replace('_', " ");
        for argument in &self.args {
            text.push(' ');
            text.push_str(argument);
        }
        text
    }
}

/// A rejected command.
///
/// `code` and `message` are contract: the code is the stable machine name a
/// client branches on, the message is the English sentence the journal and the
/// structured log record. `ui` is the same rejection as a translatable line, so
/// the window can say it in its own language instead of printing English in a
/// Vietnamese interface. It is `None` where the detail *is* the platform's text
/// (an OS error, a filesystem path) — there is nothing to translate there, and
/// inventing a sentence would hide the real cause.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ui: Option<UiText>,
}

impl ProtocolError {
    /// A rejection whose detail is not translatable: an OS error, an invalid
    /// envelope, a path the filesystem named.
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            ui: None,
        }
    }

    /// A rejection the interface words itself, with an explicit English
    /// message for the journal (the sentence a reader of the log wants, which
    /// is not always the mechanical rendering of the line).
    pub fn with_line(code: impl Into<String>, message: impl Into<String>, line: UiText) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            ui: Some(line),
        }
    }

    /// A rejection the interface words itself, where those words are also the
    /// journal's: the message is the line's English rendering.
    pub fn line(code: impl Into<String>, line: UiText) -> Self {
        let code = code.into();
        let message = line.english();
        Self {
            code,
            message,
            ui: Some(line),
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
            (
                Command::EditorCropPreview {
                    x: 10,
                    y: 20,
                    width: 300,
                    height: 400,
                },
                "editor_crop_preview",
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
            (
                Command::EditorExport {
                    path: "/a.jpg".into(),
                    quality: Some(80),
                    metadata: true,
                },
                "editor_export",
            ),
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

        // An older client that knows only the path still exports: quality
        // falls back to the encoder's default and metadata is off, which is the
        // safe answer (nothing is copied that the caller did not ask for).
        let env: Envelope = serde_json::from_str(
            r#"{"id":"x","command":{"type":"editor_export","path":"/a.jpg"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorExport {
                path,
                quality,
                metadata,
            } => {
                assert_eq!(path, "/a.jpg");
                assert_eq!(quality, None);
                assert!(!metadata);
            }
            other => panic!("unexpected command {other:?}"),
        }

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

        // A crop preview is the same rectangle as the applied crop and has its
        // own name, so a journal line can never read as a cut.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_crop_preview","x":4,"y":2,"width":10,"height":8}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorCropPreview {
                x,
                y,
                width,
                height,
            } => assert_eq!((x, y, width, height), (4, 2, 10, 8)),
            other => panic!("unexpected command {other:?}"),
        }
    }
}
