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
