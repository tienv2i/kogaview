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
    function menuWidth(widths) {
        var widest = 0
        for (var i = 0; i < widths.length; ++i) {
            if (widths[i] > widest) widest = widths[i]
        }
        return Math.max(theme.menuMinimumWidth,
                        Math.ceil(widest + theme.menuEntryGutter + theme.menuEntryPostText))
    }

    /// Every label a menu in this app can show. The set is fixed so the menu keeps
    /// one width from one right click to the next instead of resizing per entry.
    readonly property var menuEntryLabels: [
        "Open", "Edit", "Open with…", "Copy image content", "Copy file path",
        "Copy to…", "Move to…", "Move to trash", "Delete permanently…",
        "Explore here", "New folder…", "Copy path", "Add to quick access",
        "Remove from quick access", "Move up", "Move down",
        "Open file…", "Open folder…", "Switch to light mode",
        "Switch to dark mode", "Exit"
    ]
    /// Pixels each of `menuEntryLabels` needs, measured once by the shell with the
    /// window font the entries are drawn in (`Main.qml` fills this in).
    property var menuLabelWidths: []
    /// Nothing narrower than this, so a menu of short labels is not a sliver.
    readonly property real menuMinimumWidth: 168
    /// What an entry draws before its text: the style's 6 px left padding. The
    /// icon is a separate child that takes no room while it draws nothing (see
    /// `docs/M1-REPORT.md`), so the label begins right after the padding.
    readonly property real menuEntryGutter: 6
    /// What it draws after the text: the 6 px right padding. No shortcut column
    /// is used, so nothing else takes room from the label.
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
}
