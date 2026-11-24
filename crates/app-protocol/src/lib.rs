//! Typed protocol shared by the UI, CLI, local IPC and MCP adapters.
//!
//! Commands are the only way to mutate Core state. Queries are read-only and
//! events are emitted by Core; they are separate types on purpose.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Wire protocol version. Independent from the application semantic version.
pub const PROTOCOL_VERSION: u32 = 1;

/// A resize payload from before the transparent pad carried no alpha; its fill
/// was always opaque. Serde uses this when the field is absent.
fn opaque_fill_alpha() -> u8 {
    255
}

/// Extensions the browser treats as images and the Editor decodes.
///
/// Kept here rather than in Core so every front end (the Qt file dialog now,
/// the CLI and the IPC/MCP adapters later) offers exactly the same list. The
/// decoders are compiled into or linked against the binary — nothing is fetched
/// at run time; AVIF's is the system libdav1d the `image` crate links — which is
/// what keeps a sandboxed Flatpak build able to open the same formats once that
/// library is carried with it. HEIC/HEIF are listed although no decoder exists
/// for them: hiding a modern phone format would be worse than saying "no
/// decoder" when one is opened. `.jpe` is a JPEG spelling `image` does not map
/// by name; it decodes by content sniffing.
pub const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jpe", "jfif", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "heic",
    "heif", "dds", "exr", "hdr", "ico", "pnm", "pbm", "pgm", "ppm", "qoi", "tga", "ff",
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

/// The resampling filter a resize asks for. `Auto` is the fast box average when
/// the target is smaller and Lanczos3 when it is larger; the named filters are
/// the `image` crate's kernels, so the view's dropdown changes real pixels
/// rather than only its label.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResizeFilter {
    #[default]
    Auto,
    Nearest,
    Bilinear,
    Bicubic,
    Bspline,
    Lanczos3,
}

/// How a resize relates the source's shape to the target's.
///
/// A resize answers "make this W × H", not "decide what the new shape keeps";
/// the second question has three honest answers, so it is asked explicitly
/// instead of being assumed. `Stretch` is the default because it is the only
/// one that discards nothing: every source pixel contributes to the result.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResizeMode {
    /// Scale the whole frame to the target, even when the aspect changes.
    #[default]
    Stretch,
    /// Keep the source's shape and take a centred rectangle of it that covers
    /// the target. Pixels outside that rectangle are discarded.
    Cover,
    /// Scale the whole frame to fit inside the target and fill the leftover
    /// with `fill`. Nothing is stretched and nothing is discarded; the result
    /// is a letterbox or a pillarbox.
    Pad,
}

impl ResizeMode {
    /// The mode a payload means.
    ///
    /// An older payload carries no mode. A `fill` meant "fit and pad", and no
    /// fill meant the centred cover crop — that is the pair the form used to
    /// offer, and a replayed journal must keep its meaning. A *new* payload
    /// always names its mode, so the default for anyone else is `Stretch`:
    /// silently discarding the edges is the bug this enum exists to end.
    pub fn for_payload(mode: Option<Self>, fill: Option<[u8; 3]>) -> Self {
        mode.unwrap_or(if fill.is_some() {
            Self::Pad
        } else {
            Self::Stretch
        })
    }
}

/// A file format a batch convert can write.
///
/// The Editor picks its save format from the destination's extension, but a
/// batch destination is built by Core: the user names a format, Core names the
/// file. The variants are the encoders this build carries, so the dropdown can
/// offer nothing the worker would refuse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageFormat {
    Png,
    Jpeg,
    Webp,
    Tiff,
    Gif,
    Bmp,
    Tga,
    Qoi,
}

impl ImageFormat {
    /// Every format a convert offers, in the order the form lists them.
    pub const ALL: [Self; 8] = [
        Self::Png,
        Self::Jpeg,
        Self::Webp,
        Self::Tiff,
        Self::Gif,
        Self::Bmp,
        Self::Tga,
        Self::Qoi,
    ];

    /// The extension the written file carries, without the dot.
    pub const fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Webp => "webp",
            Self::Tiff => "tiff",
            Self::Gif => "gif",
            Self::Bmp => "bmp",
            Self::Tga => "tga",
            Self::Qoi => "qoi",
        }
    }

    /// The dotted extension the form shows.
    pub const fn label(self) -> &'static str {
        match self {
            Self::Png => ".png",
            Self::Jpeg => ".jpg",
            Self::Webp => ".webp",
            Self::Tiff => ".tiff",
            Self::Gif => ".gif",
            Self::Bmp => ".bmp",
            Self::Tga => ".tga",
            Self::Qoi => ".qoi",
        }
    }
}

/// What one batch job does to every input image.
///
/// A batch is one typed job, not a list of per-file commands: the three
/// operations share the input list, the output policy, the progress counter and
/// the cancellation flag, and a front end that sent a hundred commands could
/// neither cancel them together nor say "12 of 40" honestly.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum BatchOperation {
    /// Scale every image to exactly `width` × `height`.
    ///
    /// The mode and filter mean what they mean in `EditorResize`; `cover` and
    /// `pad` are how one target size fits a folder of mixed shapes.
    Resize {
        width: u32,
        height: u32,
        #[serde(default)]
        mode: ResizeMode,
        #[serde(default)]
        filter: ResizeFilter,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Cut a proportional rectangle from every image.
    ///
    /// Each value is a percentage (0–100) of that image's own side, so one job
    /// describes the same trim on a folder of mixed sizes: `0,0,100,100` is the
    /// whole picture and `10,10,80,80` trims ten percent from each side.
    Crop {
        #[serde(default)]
        x: f64,
        #[serde(default)]
        y: f64,
        #[serde(default)]
        width: f64,
        #[serde(default)]
        height: f64,
        /// `"percent"` (default, 0–100) or `"pixels"` (absolute pixels).
        #[serde(default = "default_crop_unit")]
        unit: String,
        /// Optional 9-point anchor (`top_left`..`bottom_right`). When set,
        /// placement is computed per image from this anchor instead of `x, y`.
        #[serde(default)]
        anchor: Option<String>,
        /// Optional aspect ratio (`width / height`). When set without explicit
        /// width/height, cuts the largest rectangle of this ratio from each image.
        #[serde(default)]
        ratio: Option<f64>,
    },
    /// Re-encode every image in `format`, with `quality` for the lossy encoder.
    Convert {
        format: ImageFormat,
        #[serde(default)]
        quality: Option<u8>,
    },
}

impl BatchOperation {
    /// Stable name for the journal, the progress label and the logs.
    pub const fn name(&self) -> &'static str {
        match self {
            Self::Resize { .. } => "resize",
            Self::Crop { .. } => "crop",
            Self::Convert { .. } => "convert",
        }
    }
}

/// Where a batch job gets its files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum BatchSource {
    /// The explicit list the interface sends — normally the selection.
    Selection { paths: Vec<String> },
    /// Every image directly inside `path`. Non-recursive: the Browser shows one
    /// folder, and a batch that silently descended would touch files the user
    /// never saw.
    Folder { path: String },
}

/// Where a batch job writes its results.
///
/// The default the interface sends is a suffix beside the source; replacing the
/// originals is a separate, explicit answer because a batch is not a save and
/// the project never overwrites a source by default.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchOutput {
    /// Destination folder; `None` writes beside each source.
    #[serde(default)]
    pub folder: Option<String>,
    /// Text inserted before the extension. Empty keeps the name.
    #[serde(default)]
    pub suffix: String,
    /// Replace the source files in place. Never inferred from an empty suffix:
    /// this flag is the only way a destination may be its own source.
    #[serde(default)]
    pub overwrite: bool,
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

/// Every panel the window can show, in the order Settings lists them.
///
/// The keys are the contract between the Settings checkbox, the view that owns
/// the panel and the saved layout: a key Core does not know is dropped when the
/// layout is sanitized, and a key absent from a saved file opens visible. They
/// are dotted by workspace because the same question ("quick access?") has a
/// different answer in the Browser and in the Editor — the Viewer may keep its
/// files list shut while the Browser shows both.
pub const LAYOUT_PANEL_KEYS: [&str; 14] = [
    "browser.quickAccess",
    "browser.explorer",
    "browser.preview",
    "browser.batch",
    "viewer.quickAccess",
    "viewer.explorer",
    "viewer.info",
    "editor.quickAccess",
    "editor.explorer",
    "editor.tools",
    "editor.options",
    "editor.info",
    "editor.history",
    "editor.original",
];

/// The reference tabs the Editor's dock can have open. An unknown value falls
/// back to `info` when the layout is sanitized.
pub const LAYOUT_REFERENCE_TABS: [&str; 3] = ["info", "history", "original"];

/// How the Browser draws a folder: large cells with the picture decoded
/// (`thumbnails`), small cells with the file type's icon (`icons`), or one line
/// per entry with its type, size and modification time (`details`). An unknown
/// value falls back to `thumbnails` when the layout is sanitized.
pub const LAYOUT_VIEW_MODES: [&str; 3] = ["thumbnails", "icons", "details"];

/// Which entry attribute the Browser sorts by. Unknown values fall back to `name`.
pub const LAYOUT_SORT_FIELDS: [&str; 4] = ["name", "modified", "size", "kind"];

/// Sort direction in the Browser. Unknown values fall back to `asc`.
pub const LAYOUT_SORT_ORDERS: [&str; 2] = ["asc", "desc"];

/// Discrete Browser thumbnail/item size presets: very small, small, medium, large, very large.
pub const LAYOUT_THUMB_SIZES: [&str; 5] = ["xs", "s", "m", "l", "xl"];

/// Viewer chrome density modes:
/// - `compact`: image-only viewport with a floating HUD on pointer hover.
/// - `simple`: top toolbar + image viewport, hiding sidebars, filmstrip and status bar.
/// - `standard`: full workspace with sidebars, filmstrip and status bar (default).
pub const LAYOUT_VIEWER_UI_MODES: [&str; 3] = ["compact", "simple", "standard"];

/// Viewer image display modes:
/// - `single`: one image fitted/zoomed in the canvas (default).
/// - `dual`: two-page book/manga spread with smart landscape & cover handling.
/// - `webtoon`: continuous virtualized vertical strip.
pub const LAYOUT_VIEWER_DISPLAY_MODES: [&str; 3] = ["single", "dual", "webtoon"];

/// Compact / Fullscreen floating HUD docked edges.
pub const LAYOUT_COMPACT_HUD_EDGES: [&str; 4] = ["top", "bottom", "left", "right"];

fn default_true() -> bool {
    true
}

fn default_crop_unit() -> String {
    "percent".to_owned()
}

fn default_canvas_anchor() -> String {
    "center".to_owned()
}

/// The persisted layout: which panels each workspace shows, how wide its docks
/// are, and how the Editor splits its two halves.
///
/// It lives in the protocol because it is a preference the CLI has to be able
/// to read and write as well as the window: a layout is Core state, not a QML
/// variable. Zoom, pan and hover stay presentation state; a panel's existence,
/// the width it is drawn at and the tab that is open are remembered across
/// launches, so they are here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LayoutState {
    /// Width of the shared left dock (quick access + explorer).
    pub left_width: u32,
    /// Width of the shared right dock.
    pub right_width: u32,
    /// `LAYOUT_PANEL_KEYS` → visible. An absent key means visible.
    pub panels: BTreeMap<String, bool>,
    /// The Editor's tool rail as one or two columns.
    pub editor_tool_columns: u8,
    /// Height of the Editor's reference dock when the user has dragged it.
    /// `0` is the default: the dock takes only the height its page needs.
    pub editor_reference_height: u32,
    /// The open reference tab: one of `LAYOUT_REFERENCE_TABS`.
    pub editor_reference_tab: String,
    /// How the Browser draws a folder: one of `LAYOUT_VIEW_MODES`.
    pub browser_view: String,
    /// Browser sort attribute: one of `LAYOUT_SORT_FIELDS`.
    pub browser_sort_by: String,
    /// Browser sort direction: one of `LAYOUT_SORT_ORDERS`.
    pub browser_sort_order: String,
    /// Browser thumbnail/icon size step: one of `LAYOUT_THUMB_SIZES`.
    pub browser_thumb_size: String,
    /// Viewer UI chrome density: one of `LAYOUT_VIEWER_UI_MODES`.
    pub viewer_ui_mode: String,
    /// Viewer image display mode: one of `LAYOUT_VIEWER_DISPLAY_MODES`.
    pub viewer_display_mode: String,
    /// Right-to-left reading order for Dual / Manga mode.
    pub manga_rtl: bool,
    /// Keep page 0 standalone as a cover page in Dual mode.
    pub manga_cover_separate: bool,
    /// Gap in pixels between pages in Dual and Webtoon modes (`0..=64`).
    pub manga_page_gap: u16,
    /// Docked edge of the Compact / Fullscreen floating HUD toolbar.
    pub compact_hud_edge: String,
    /// Whether the Compact / Fullscreen floating HUD stays permanently visible.
    pub compact_hud_pinned: bool,
}

impl Default for LayoutState {
    fn default() -> Self {
        Self {
            left_width: 260,
            right_width: 300,
            panels: LAYOUT_PANEL_KEYS
                .iter()
                .map(|key| ((*key).to_owned(), true))
                .collect(),
            editor_tool_columns: 2,
            editor_reference_height: 0,
            editor_reference_tab: "info".to_owned(),
            browser_view: "thumbnails".to_owned(),
            browser_sort_by: "name".to_owned(),
            browser_sort_order: "asc".to_owned(),
            browser_thumb_size: "m".to_owned(),
            viewer_ui_mode: "simple".to_owned(),
            viewer_display_mode: "single".to_owned(),
            manga_rtl: false,
            manga_cover_separate: true,
            manga_page_gap: 8,
            compact_hud_edge: "top".to_owned(),
            compact_hud_pinned: false,
        }
    }
}

impl LayoutState {
    /// Clamp what can be clamped, drop unknown panel keys and put back the ones
    /// a file forgot. A layout that came from a newer build keeps every panel
    /// it did not name visible rather than silently hiding it.
    pub fn sanitized(mut self) -> Self {
        self.left_width = self.left_width.clamp(180, 560);
        self.right_width = self.right_width.clamp(200, 640);
        self.editor_tool_columns = self.editor_tool_columns.clamp(1, 2);
        // 0 means "as tall as the page", which is a valid answer; anything
        // else is a height a person dragged, bounded so the tool frame keeps
        // its room.
        self.editor_reference_height = self.editor_reference_height.min(900);
        if !LAYOUT_REFERENCE_TABS.contains(&self.editor_reference_tab.as_str()) {
            self.editor_reference_tab = "info".to_owned();
        }
        if !LAYOUT_VIEW_MODES.contains(&self.browser_view.as_str()) {
            self.browser_view = "thumbnails".to_owned();
        }
        if !LAYOUT_SORT_FIELDS.contains(&self.browser_sort_by.as_str()) {
            self.browser_sort_by = "name".to_owned();
        }
        if !LAYOUT_SORT_ORDERS.contains(&self.browser_sort_order.as_str()) {
            self.browser_sort_order = "asc".to_owned();
        }
        if !LAYOUT_THUMB_SIZES.contains(&self.browser_thumb_size.as_str()) {
            self.browser_thumb_size = "m".to_owned();
        }
        if !LAYOUT_VIEWER_UI_MODES.contains(&self.viewer_ui_mode.as_str()) {
            self.viewer_ui_mode = "simple".to_owned();
        }
        if !LAYOUT_VIEWER_DISPLAY_MODES.contains(&self.viewer_display_mode.as_str()) {
            self.viewer_display_mode = "single".to_owned();
        }
        self.manga_page_gap = self.manga_page_gap.min(64);
        if !LAYOUT_COMPACT_HUD_EDGES.contains(&self.compact_hud_edge.as_str()) {
            self.compact_hud_edge = "top".to_owned();
        }
        let mut panels = BTreeMap::new();
        for key in LAYOUT_PANEL_KEYS {
            panels.insert(
                key.to_owned(),
                self.panels.get(key).copied().unwrap_or(true),
            );
        }
        self.panels = panels;
        self
    }

    /// Is a panel visible? An absent key is visible, which is also what a
    /// sanitized layout guarantees, so a view can use this directly.
    pub fn panel(&self, key: &str) -> bool {
        self.panels.get(key).copied().unwrap_or(true)
    }

    /// Hide or show one panel. The layout is sanitized by the command, so a
    /// key from a newer view is dropped rather than stored.
    pub fn with_panel(mut self, key: &str, visible: bool) -> Self {
        self.panels.insert(key.to_owned(), visible);
        self
    }

    /// The layout this config's legacy flags meant.
    ///
    /// Before a layout was saved, visibility lived in four booleans. They are
    /// read once: `false` hides every panel of that dock, `true` (and an absent
    /// field) leaves the defaults alone.
    pub fn from_legacy(
        left_panel: Option<bool>,
        right_panel: Option<bool>,
        right_panel_viewer: Option<bool>,
        right_panel_editor: Option<bool>,
    ) -> Self {
        let mut layout = Self::default();
        if left_panel == Some(false) {
            for key in [
                "browser.quickAccess",
                "browser.explorer",
                "viewer.quickAccess",
                "viewer.explorer",
                "editor.quickAccess",
                "editor.explorer",
            ] {
                layout.panels.insert(key.to_owned(), false);
            }
        }
        if right_panel == Some(false) {
            for key in ["browser.preview", "browser.batch"] {
                layout.panels.insert(key.to_owned(), false);
            }
        }
        if right_panel_viewer == Some(false) {
            layout.panels.insert("viewer.info".to_owned(), false);
        }
        if right_panel_editor == Some(false) {
            for key in [
                "editor.options",
                "editor.info",
                "editor.history",
                "editor.original",
            ] {
                layout.panels.insert(key.to_owned(), false);
            }
        }
        layout
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
        #[serde(default = "default_true")]
        hardware_acceleration: bool,
        #[serde(default = "default_true")]
        anti_aliasing: bool,
    },
    ToggleTheme,
    /// Set the interface language (`system`, `editor`, `en` or `vi`).
    SetLanguage {
        language: Language,
    },
    ToggleLeftPanel,
    /// Replace the persisted layout: which panels each workspace shows, the two
    /// dock widths and the Editor's split. A layout is a preference, so it is
    /// written to `config.json` immediately rather than waiting for a form.
    SetLayout {
        layout: LayoutState,
    },
    /// Show or hide the right panel of a workspace.
    ///
    /// Each workspace owns its own preference, because a narrow Viewer wants
    /// its information panel while a Browser with a wide preview does not, and
    /// hiding one must not hide the other. `workspace` names the one whose
    /// panel is toggled; an older client that omits it toggles the workspace
    /// that is open, which is what a toolbar button means.
    ToggleRightPanel {
        #[serde(default)]
        workspace: Option<Workspace>,
    },
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
    /// source's EXIF/XMP/ICC segments when both files are JPEG. `max_edge`, when
    /// given, scales the copy down so its longer side is at most that many
    /// pixels, aspect kept and never upscaled — the delivery size, not an edit.
    /// Exporting onto the document's own file is refused — that is what
    /// `editor_save` is for.
    EditorExport {
        path: String,
        #[serde(default)]
        quality: Option<u8>,
        #[serde(default)]
        metadata: bool,
        #[serde(default)]
        max_edge: Option<u32>,
    },
    /// Scale the working document to exactly `width` × `height`.
    ///
    /// `mode` decides what happens when the target's shape differs from the
    /// source's: `stretch` (the default) scales the whole frame and loses
    /// nothing, `cover` keeps the source's shape by discarding a centred
    /// rectangle of it, and `pad` fits the whole frame inside and fills the
    /// leftover with `fill`. An older payload that carries only `fill` keeps
    /// its pad; one that carries no `fill` used to mean `cover` and now means
    /// `stretch`, because discarding pixels is a choice the caller must make.
    /// Resize is not anchored: where the result sits is a Crop decision, not a
    /// Resize one.
    EditorResize {
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        /// Alpha for `fill`: 255 is an opaque pad, 0 the transparent one the
        /// form's background dropdown offers. Older payloads are opaque.
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        /// Absent in a payload from before the three modes existed; see
        /// [`ResizeMode::for_payload`] for what an absent value means.
        #[serde(default)]
        mode: Option<ResizeMode>,
        #[serde(default)]
        filter: ResizeFilter,
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
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        #[serde(default)]
        mode: Option<ResizeMode>,
        #[serde(default)]
        filter: ResizeFilter,
    },
    /// Cut the working document to the given rectangle, in document pixels.
    ///
    /// Without a `fill` the rectangle must lie inside the picture: that is the
    /// ordinary crop, and a larger rectangle is refused. With a `fill` the
    /// canvas may **grow** — `x`/`y` go negative and the rectangle may reach
    /// past the picture's right and bottom edges — and every pixel outside the
    /// picture is painted with that RGB colour at `fill_alpha`. The rectangle
    /// must still overlap the picture, so a grow is a border around the photo
    /// and never an empty coloured page.
    EditorCrop {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        /// Alpha for `fill`: 255 is an opaque grow border, 0 the transparent
        /// one. Older payloads are opaque, and `None` never reads it.
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Render the crop in the canvas without cutting the document: the pixels,
    /// the history and the save target stay as they are until `EditorCrop` is
    /// applied. The draft is published as `editor.previewDraft` with
    /// `kind: "crop"`.
    EditorCropPreview {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Straighten the frame: the four corners of the quadrilateral inside the
    /// working document that should become the whole output. `corners` are in
    /// document pixels, clockwise in the document's own winding — top-left,
    /// top-right, bottom-right, bottom-left — and the output keeps the
    /// document's width and height. An identity quad (the document's own frame)
    /// changes nothing, so a client cannot record an empty step.
    EditorTransform {
        corners: [[f64; 2]; 4],
    },
    /// Free-transform the working document inside its existing `W × H` frame:
    /// scale the image to `width × height`, place it at `(x, y)` (clipping any
    /// overflow), and fill the uncovered canvas with `fill` / `fill_alpha`.
    EditorFreeTransform {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        rotation: f64,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Render the transform in the canvas without reshaping the document: the
    /// pixels, the history and the save target stay as they are until
    /// `EditorTransform` is applied. The draft is published as
    /// `editor.previewDraft` with `kind: "transform"`.
    EditorTransformPreview {
        corners: [[f64; 2]; 4],
    },
    /// Grow or shrink the canvas without scaling the image pixels.
    /// `anchor` is one of the 9 positions (`top_left`, `top`, `top_right`,
    /// `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`);
    /// uncovered pixels are painted with `fill` / `fill_alpha`.
    EditorCanvasSize {
        width: u32,
        height: u32,
        #[serde(default = "default_canvas_anchor")]
        anchor: String,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Rotate the working document clockwise by an arbitrary angle in degrees.
    /// The canvas expands to hold the rotated bounding box and uncovered
    /// corners are filled with `fill` / `fill_alpha`.
    EditorRotateAngle {
        degrees: f64,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Adjust brightness, contrast and saturation of the working document.
    /// Values are normalized in `-1.0..=1.0` (`0.0` = unchanged).
    EditorAdjustColor {
        #[serde(default)]
        brightness: f64,
        #[serde(default)]
        contrast: f64,
        #[serde(default)]
        saturation: f64,
    },
    /// Rotate the working document clockwise; degrees must be 90, 180 or 270
    /// (negative values rotate counter-clockwise).
    EditorRotate {
        degrees: i32,
    },
    EditorFlip {
        axis: FlipAxis,
    },
    /// Paint one freehand stroke onto the working document. `points` are in
    /// document pixels in drawing order; the whole list is one history step, so
    /// one undo removes the stroke. `radius` is half the brush's width in
    /// document pixels, `opacity` is 0–1 and `erase` clears alpha instead of
    /// blending `color`. A single point paints a dot.
    EditorPaintStroke {
        points: Vec<[f64; 2]>,
        color: [u8; 3],
        radius: f64,
        opacity: f64,
        #[serde(default)]
        erase: bool,
    },
    EditorUndo,
    EditorRedo,
    /// Discard every edit and return the working document to the source image.
    EditorReset,
    /// Drop the working document. The source file is untouched.
    EditorClose,
    /// Run one operation over a list of images on a worker thread.
    ///
    /// The job is bounded (`MAX_BATCH_FILES`), cancellable
    /// (`cancel_operation`) and observable: Core publishes a `batch` slot with
    /// the count and the file being written. The sources are never modified
    /// unless `output.overwrite` says so.
    BatchRun {
        operation: BatchOperation,
        source: BatchSource,
        #[serde(default)]
        output: BatchOutput,
    },
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
            Self::SetLayout { .. } => "set_layout",
            Self::ToggleRightPanel { .. } => "toggle_right_panel",
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
            Self::EditorTransform { .. } => "editor_transform",
            Self::EditorFreeTransform { .. } => "editor_free_transform",
            Self::EditorTransformPreview { .. } => "editor_transform_preview",
            Self::EditorCanvasSize { .. } => "editor_canvas_size",
            Self::EditorRotateAngle { .. } => "editor_rotate_angle",
            Self::EditorAdjustColor { .. } => "editor_adjust_color",
            Self::EditorRotate { .. } => "editor_rotate",
            Self::EditorFlip { .. } => "editor_flip",
            Self::EditorPaintStroke { .. } => "editor_paint_stroke",
            Self::EditorUndo => "editor_undo",
            Self::EditorRedo => "editor_redo",
            Self::EditorReset => "editor_reset",
            Self::EditorClose => "editor_close",
            Self::BatchRun { .. } => "batch_run",
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
    fn a_batch_job_round_trips_with_its_operation_and_policy() {
        // The shape the QML sends: one command, one operation, one policy.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"b","command":{"type":"batch_run",
                "operation":{"operation":"crop","x":10,"y":10,"width":80,"height":80},
                "source":{"source":"selection","paths":["/pics/a.png"]},
                "output":{"suffix":"_cropped"}}}"#,
        )
        .unwrap();
        assert_eq!(env.command.name(), "batch_run");
        match env.command {
            Command::BatchRun {
                operation,
                source,
                output,
            } => {
                assert_eq!(
                    operation,
                    BatchOperation::Crop {
                        x: 10.0,
                        y: 10.0,
                        width: 80.0,
                        height: 80.0,
                        unit: "percent".to_owned(),
                        anchor: None,
                        ratio: None,
                    }
                );
                assert_eq!(
                    source,
                    BatchSource::Selection {
                        paths: vec!["/pics/a.png".into()]
                    }
                );
                // An older payload carries no folder or overwrite: the safe
                // default is a suffixed copy beside the source.
                assert_eq!(output.folder, None);
                assert_eq!(output.suffix, "_cropped");
                assert!(!output.overwrite);
            }
            other => panic!("parsed as {}", other.name()),
        }

        let command = Command::BatchRun {
            operation: BatchOperation::Resize {
                width: 800,
                height: 600,
                mode: ResizeMode::Cover,
                filter: ResizeFilter::Lanczos3,
                fill: None,
                fill_alpha: 255,
            },
            source: BatchSource::Folder {
                path: "/pics".into(),
            },
            output: BatchOutput {
                folder: Some("/out".into()),
                suffix: "_small".into(),
                overwrite: false,
            },
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"operation\":\"resize\""), "{json}");
        assert!(json.contains("\"mode\":\"cover\""), "{json}");
        let round: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(round.name(), "batch_run");
        match round {
            Command::BatchRun { operation, .. } => {
                assert_eq!(operation.name(), "resize");
                assert!(matches!(operation, BatchOperation::Resize { .. }));
            }
            other => panic!("round trip changed the command to {}", other.name()),
        }
    }

    #[test]
    fn theme_toggles_both_ways() {
        assert_eq!(Theme::Dark.toggled(), Theme::Light);
        assert_eq!(Theme::Light.toggled(), Theme::Dark);
    }

    #[test]
    fn a_right_panel_toggle_names_its_workspace_or_means_the_open_one() {
        // The toolbar button sends no workspace: whatever is on screen is what
        // the user is looking at.
        let env: Envelope =
            serde_json::from_str(r#"{"id":"p","command":{"type":"toggle_right_panel"}}"#).unwrap();
        match env.command {
            Command::ToggleRightPanel { workspace } => assert_eq!(workspace, None),
            other => panic!("parsed as {}", other.name()),
        }

        // A replay or a CLI can name the workspace it means.
        let command = Command::ToggleRightPanel {
            workspace: Some(Workspace::Viewer),
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"workspace\":\"viewer\""), "{json}");
        let round: Command = serde_json::from_str(&json).unwrap();
        match round {
            Command::ToggleRightPanel { workspace } => {
                assert_eq!(workspace, Some(Workspace::Viewer))
            }
            other => panic!("round trip changed the command to {}", other.name()),
        }
        assert_eq!(round.name(), "toggle_right_panel");
    }

    #[test]
    fn a_layout_round_trips_and_sanitizes() {
        let command = Command::SetLayout {
            layout: LayoutState::default()
                .with_panel("editor.history", false)
                .with_panel("made.up", false),
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"set_layout\""), "{json}");
        let round: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(round.name(), "set_layout");
        match round {
            Command::SetLayout { layout } => {
                assert!(!layout.panel("editor.history"));
                // The payload carries what the view sent; Core drops a key it
                // does not know when it sanitizes the layout.
                assert!(!layout.panel("made.up"));
            }
            other => panic!("round trip changed the command to {}", other.name()),
        }

        // Out-of-range numbers are clamped instead of trusted, and a tab that
        // is not a reference tab reads as `info`.
        let wild = LayoutState {
            left_width: 5,
            right_width: 9999,
            editor_tool_columns: 7,
            editor_reference_height: 9999,
            editor_reference_tab: "elsewhere".into(),
            browser_view: "gallery".into(),
            viewer_ui_mode: "zen".into(),
            viewer_display_mode: "carousel".into(),
            manga_page_gap: 999,
            ..LayoutState::default()
        }
        .sanitized();
        assert_eq!(wild.left_width, 180);
        assert_eq!(wild.right_width, 640);
        assert_eq!(wild.editor_tool_columns, 2);
        assert_eq!(wild.editor_reference_height, 900);
        assert_eq!(wild.editor_reference_tab, "info");
        // The Browser's view mode is one of the three the window draws; a value
        // from a newer build reads as the default rather than as a blank grid.
        assert_eq!(wild.browser_view, "thumbnails");
        assert_eq!(wild.viewer_ui_mode, "simple");
        assert_eq!(wild.viewer_display_mode, "single");
        assert_eq!(wild.manga_page_gap, 64);
        // It travels in camelCase like every other layout field, so the window
        // and the CLI name the same thing.
        let json = serde_json::to_string(&Command::SetLayout {
            layout: LayoutState {
                browser_view: "details".into(),
                viewer_ui_mode: "compact".into(),
                viewer_display_mode: "dual".into(),
                manga_rtl: true,
                ..LayoutState::default()
            },
        })
        .unwrap();
        assert!(json.contains("\"browserView\":\"details\""), "{json}");
        assert!(json.contains("\"viewerUiMode\":\"compact\""), "{json}");
        assert!(json.contains("\"viewerDisplayMode\":\"dual\""), "{json}");
        assert!(json.contains("\"mangaRtl\":true"), "{json}");

        // An older config's booleans hide the dock they described.
        let legacy = LayoutState::from_legacy(Some(false), Some(true), Some(false), Some(false));
        assert!(!legacy.panel("browser.quickAccess"));
        assert!(!legacy.panel("editor.explorer"));
        assert!(legacy.panel("browser.preview"));
        assert!(!legacy.panel("viewer.info"));
        assert!(!legacy.panel("editor.history"));
        assert!(
            legacy.panel("editor.tools"),
            "the rail was never a config flag"
        );
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
                    fill_alpha: 255,
                    mode: Some(ResizeMode::Stretch),
                    filter: ResizeFilter::Auto,
                },
                "editor_resize",
            ),
            (
                Command::EditorResizePreview {
                    width: 800,
                    height: 600,
                    fill: Some([1, 2, 3]),
                    fill_alpha: 0,
                    mode: Some(ResizeMode::Pad),
                    filter: ResizeFilter::Bicubic,
                },
                "editor_resize_preview",
            ),
            (
                Command::EditorCrop {
                    x: 10,
                    y: 20,
                    width: 300,
                    height: 400,
                    fill: None,
                    fill_alpha: 255,
                },
                "editor_crop",
            ),
            (
                Command::EditorCropPreview {
                    x: -10,
                    y: -20,
                    width: 300,
                    height: 400,
                    fill: Some([9, 8, 7]),
                    fill_alpha: 0,
                },
                "editor_crop_preview",
            ),
            (
                Command::EditorTransform {
                    corners: [[4.0, 2.0], [40.0, 0.0], [40.0, 20.0], [0.0, 20.0]],
                },
                "editor_transform",
            ),
            (
                Command::EditorFreeTransform {
                    x: 10,
                    y: 20,
                    width: 200,
                    height: 150,
                    rotation: 0.0,
                    fill: Some([12, 34, 56]),
                    fill_alpha: 255,
                },
                "editor_free_transform",
            ),
            (
                Command::EditorTransformPreview {
                    corners: [[4.0, 2.0], [40.0, 0.0], [40.0, 20.0], [0.0, 20.0]],
                },
                "editor_transform_preview",
            ),
            (Command::EditorRotate { degrees: 90 }, "editor_rotate"),
            (
                Command::EditorFlip {
                    axis: FlipAxis::Vertical,
                },
                "editor_flip",
            ),
            (
                Command::EditorPaintStroke {
                    points: vec![[10.0, 12.0], [40.0, 18.0]],
                    color: [255, 0, 0],
                    radius: 8.0,
                    opacity: 0.75,
                    erase: false,
                },
                "editor_paint_stroke",
            ),
            (Command::EditorUndo, "editor_undo"),
            (Command::EditorRedo, "editor_redo"),
            (Command::EditorReset, "editor_reset"),
            (
                Command::EditorExport {
                    path: "/a.jpg".into(),
                    quality: Some(80),
                    metadata: true,
                    max_edge: Some(1920),
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
        // falls back to the encoder's default, metadata is off and the copy
        // keeps its own size, which is the safe answer (nothing is copied or
        // shrunk that the caller did not ask for).
        let env: Envelope = serde_json::from_str(
            r#"{"id":"x","command":{"type":"editor_export","path":"/a.jpg"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorExport {
                path,
                quality,
                metadata,
                max_edge,
            } => {
                assert_eq!(path, "/a.jpg");
                assert_eq!(quality, None);
                assert!(!metadata);
                assert_eq!(max_edge, None);
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
                fill_alpha,
                mode,
                filter,
                width,
                height,
            } => {
                assert_eq!((width, height), (64, 32));
                assert_eq!(fill, None);
                assert_eq!(fill_alpha, 255, "an old payload pads opaquely");
                // No mode and no fill is the old `cover` payload. The protocol
                // keeps the field absent and lets Core read it, so a client
                // that knows only the old shape is still understood.
                assert_eq!(mode, None);
                assert_eq!(
                    ResizeMode::for_payload(mode, fill),
                    ResizeMode::Stretch,
                    "a payload with no mode and no fill now stretches"
                );
                assert_eq!(filter, ResizeFilter::Auto);
            }
            other => panic!("unexpected command {other:?}"),
        }
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32,"anchor":"bottom_right","fill":[1,2,3],"fill_alpha":0,"filter":"bspline"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize {
                fill,
                fill_alpha,
                mode,
                filter,
                ..
            } => {
                assert_eq!(fill, Some([1, 2, 3]));
                assert_eq!(fill_alpha, 0);
                assert_eq!(mode, None);
                assert_eq!(
                    ResizeMode::for_payload(mode, fill),
                    ResizeMode::Pad,
                    "an old payload that carries a fill keeps its pad"
                );
                assert_eq!(filter, ResizeFilter::Bspline);
            }
            other => panic!("unexpected command {other:?}"),
        }
        // A payload that names its mode keeps it, including `cover` with no
        // fill: the explicit answer is what the form sends.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32,"mode":"cover"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize { mode, fill, .. } => {
                assert_eq!(mode, Some(ResizeMode::Cover));
                assert_eq!(ResizeMode::for_payload(mode, fill), ResizeMode::Cover);
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

        // A stroke written by an older client that does not know `erase` is a
        // brush stroke, not an eraser one.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"p","command":{"type":"editor_paint_stroke","points":[[1,2]],"color":[0,0,0],"radius":4,"opacity":1}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorPaintStroke { erase, points, .. } => {
                assert!(!erase);
                assert_eq!(points, vec![[1.0, 2.0]]);
            }
            other => panic!("unexpected command {other:?}"),
        }

        // A crop preview is the same rectangle as the applied crop and has its
        // own name, so a journal line can never read as a cut. A payload from
        // before the grow mode is an inside crop with no fill.
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
                fill,
                fill_alpha,
            } => {
                assert_eq!((x, y, width, height), (4, 2, 10, 8));
                assert_eq!(fill, None);
                assert_eq!(fill_alpha, 255);
            }
            other => panic!("unexpected command {other:?}"),
        }

        // A grow crop can start outside the picture; the negative origin is
        // part of the typed command, not a view-only number.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"g","command":{"type":"editor_crop","x":-12,"y":-8,"width":120,"height":90,"fill":[255,255,255],"fill_alpha":0}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorCrop {
                x,
                y,
                fill,
                fill_alpha,
                ..
            } => {
                assert_eq!((x, y), (-12, -8));
                assert_eq!(fill, Some([255, 255, 255]));
                assert_eq!(fill_alpha, 0);
            }
            other => panic!("unexpected command {other:?}"),
        }
    }
}
