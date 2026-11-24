//! UI theme, language, panel visibility, and persisted workspace layout state.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

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

