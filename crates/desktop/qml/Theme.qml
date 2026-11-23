import QtQuick

/// The single source of presentation colors. Core owns the persisted theme;
/// this object only maps it to colors and metrics.
QtObject {
    id: theme

    property bool dark: true

    readonly property color background: dark ? "#101216" : "#f3f4f6"
    readonly property color surface: dark ? "#181b21" : "#ffffff"
    readonly property color surfaceAlt: dark ? "#21252d" : "#eceef2"
    readonly property color sidebar: dark ? "#14171c" : "#f8f9fb"
    readonly property color thumb: dark ? "#0b0d10" : "#e6e8ec"
    readonly property color border: dark ? "#2b3039" : "#d7dbe2"
    readonly property color text: dark ? "#e8eaed" : "#1c1f24"
    readonly property color textMuted: dark ? "#9aa1ac" : "#5b6370"
    readonly property color accent: dark ? "#4a9eff" : "#0a66c2"
    readonly property color accentText: dark ? "#0b1a2b" : "#ffffff"
    readonly property color selection: dark ? "#14395c" : "#d8e9fb"
    readonly property color hover: dark ? "#222833" : "#e9edf3"
    readonly property color danger: dark ? "#ff6b6b" : "#c62828"

    readonly property int radius: 6
    readonly property int spacing: 8
    readonly property int panelWidth: 260
    readonly property int previewWidth: 300
    readonly property int rowHeight: 40

    /// How wide a menu showing `widths` has to be to not cut any of its entries.
    ///
    /// Qt Quick Controls gives every menu a fixed 200 and every entry
    /// `implicitWidth: 200`, so a longer label ("Open with…", "Delete
    /// permanently…") is elided mid-word while "Open" leaves the menu mostly
    /// empty. The longest label decides the width; its pixels come from
    /// `Platform.textWidths`, measured in C++ because a `Menu`'s own `font`
    /// follows its width and measuring text inside the menu would loop it.
    ///
    /// `shortcutWidths` is the same measurement for the keys a menu names at
    /// its right edge (`MenuShortcut.qml`). It is optional: a menu with no
    /// hints needs no column, and a menu that passes an empty list stays as
    /// wide as its labels. When hints are shown, the column is the widest key
    /// plus `menuShortcutGap`, so no key can be drawn over the label it
    /// belongs to.
    function menuWidth(widths, shortcutWidths) {
        var widest = 0
        for (var i = 0; i < widths.length; ++i) {
            if (widths[i] > widest) widest = widths[i]
        }
        var widestKey = 0
        if (shortcutWidths) {
            for (var k = 0; k < shortcutWidths.length; ++k) {
                if (shortcutWidths[k] > widestKey) widestKey = shortcutWidths[k]
            }
        }
        return Math.max(theme.menuMinimumWidth,
                        Math.ceil(widest + theme.menuEntryGutter + theme.menuEntryPostText
                                  + (widestKey > 0 ? widestKey + theme.menuShortcutGap : 0)))
    }

    /// Every label a menu in this app can show, in the interface language. The
    /// set is fixed so the menu keeps one width from one right click to the next
    /// instead of resizing per entry.
    ///
    /// The literals are written inside `qsTr` here, one per line, so `lupdate`
    /// extracts them into the `Theme` context: a loop over a list of variables
    /// is invisible to it, and the menus stayed English until this list did.
    /// Measuring the *translated* labels is deliberate — a menu has to fit what
    /// it draws, and `Main.qml` re-measures when the language changes.
    readonly property var menuEntryLabels: [
        qsTr("Open"), qsTr("Edit"), qsTr("Open with…"),
        qsTr("Copy image content"), qsTr("Copy file path"),
        qsTr("Copy to…"), qsTr("Move to…"), qsTr("Move to trash"),
        qsTr("Delete permanently…"),
        qsTr("New folder…"), qsTr("Copy path"),
        qsTr("Add to quick access"),
        qsTr("Remove from quick access"), qsTr("Move up"), qsTr("Move down"),
        qsTr("Open file…"), qsTr("Open folder…"), qsTr("Switch to light mode"),
        qsTr("Switch to dark mode"), qsTr("Settings…"), qsTr("Exit"),
        qsTr("Fit to window"), qsTr("Actual size"), qsTr("Rotate left"),
        qsTr("Rotate right"),
        qsTr("Flip horizontal"), qsTr("Flip vertical"), qsTr("Reset edits"),
        qsTr("Close editor"),
        // Shell menu only: the explicit way into the Editor. Appended so the
        // indices the Browser, Viewer and Editor menus already use do not move.
        qsTr("Open in editor…"),
        // Mini-toolbar overflow menus (row 87). Appended for the same reason:
        // the views address this list by index and the old slots must not move.
        qsTr("Zoom in"), qsTr("Zoom out"), qsTr("Toggle thumbnail filmstrip"),
        qsTr("Toggle quick access and folder tree"),
        qsTr("Toggle preview and metadata panel"),
        qsTr("Save as…"), qsTr("Export a copy…"), qsTr("Reset to original"),
        // The shared right dock and the file manager's own "locate" (row 96).
        // Appended again: the views and the shell address this list by index.
        qsTr("Show in folder"),
        qsTr("Toggle information panel"),
        qsTr("Toggle tool and reference panel"),
        // The shell's way into the Browser's batch form (row 103). Appended
        // for the same reason as every entry above: indices are a contract.
        qsTr("Tools…"),
        qsTr("Reset view"),
        qsTr("Color & light"),
        qsTr("Viewer mode & layout"),
        qsTr("Fullscreen"),
        qsTr("Canvas background")
    ]
    /// The labels the menus are built from (`Main.qml`, the Editor's canvas
    /// menu). Same list, kept as a name of its own so the views read
    /// "what to show" and the shell reads "what to measure".
    readonly property var menuEntries: menuEntryLabels
    /// The shell's way into the Browser's batch form. Named rather than indexed
    /// by callers so appending new measured labels never breaks the entry.
    readonly property string batchToolsLabel: menuEntryLabels[menuEntryLabels.length - 6]
    /// Pixels each of `menuEntryLabels` needs, measured once by the shell with the
    /// window font the entries are drawn in (`Main.qml` fills this in).
    property var menuLabelWidths: []
    /// The keys a context menu names at the right edge (`MenuShortcut.qml`).
    /// Key names are not translated: a keyboard shortcut is a legend for a
    /// physical key, not a word. Measured like the labels, because a menu has to
    /// fit the column as well as the text.
    readonly property var menuShortcutLabels: [
        "Ctrl+Shift+C", "Ctrl+Alt+C", "Ctrl+O", "Ctrl+Shift+O", "Ctrl+Shift+S",
        "Ctrl+Q", "Ctrl+Z", "Ctrl+Shift+Z", "Enter", "Delete", "Backspace",
        "F5", "F", "0", "0/1", "Shift+R", "R", "H", "V", "T", "M", "F11", "+", "-"
    ]
    /// Pixels each of `menuShortcutLabels` needs, measured by `Main.qml`.
    property var menuShortcutWidths: []
    /// Room between the longest label and the key column: 12 px of right
    /// margin, 12 px of breathing room, and the entry's own right padding.
    readonly property real menuShortcutGap: 24
    /// Nothing narrower than this, so a menu of short labels is not a sliver.
    readonly property real menuMinimumWidth: 168
    /// What an entry draws before its text: the style's 6 px left padding. The
    /// icon is a separate child that takes no room while it draws nothing (see
    /// `docs/M1-REPORT.md`), so the label begins right after the padding.
    readonly property real menuEntryGutter: 6
    /// What it draws after the text: the 6 px right padding. The key column is
    /// accounted for separately (`menuShortcutGap`), because only a menu that
    /// names keys pays for it.
    readonly property real menuEntryPostText: 6

    function formatBytes(bytes) {
        var value = Number(bytes) || 0;
        if (value < 1024) return value + " B";
        var units = ["KB", "MB", "GB", "TB"];
        var index = -1;
        do {
            value /= 1024;
            index++;
        } while (value >= 1024 && index < units.length - 1);
        return value.toFixed(value >= 10 ? 0 : 1) + " " + units[index];
    }

    function formatDate(seconds) {
        if (!seconds) return "—";
        return new Date(Number(seconds) * 1000).toLocaleString();
    }

    /// A date for a table cell. `formatDate` draws the whole localised line —
    /// weekday, zone and all — which needs the width of a panel; a list column
    /// has a fixed one, and a date that ends in an ellipsis is not a date. So a
    /// cell gets the locale's short date and the time, which fits at any size.
    function formatDateShort(seconds) {
        if (!seconds) return "—";
        const date = new Date(Number(seconds) * 1000);
        const locale = Qt.locale();
        return date.toLocaleString(locale, locale.dateFormat(Locale.ShortFormat) + " HH:mm");
    }
}
