import QtQuick
import QtQuick.Controls

/// A `Menu` that wears KogaView's own `Theme` instead of the desktop's.
///
/// A `Menu` is a popup parented to the window overlay (or its own top-level
/// surface), so it does not inherit the shell's palette reliably across theme
/// switches, and monochrome `-symbolic` icons from a dark desktop icon theme
/// (e.g. Breeze Dark / Papirus-Dark) draw near-white on a light menu unless
/// `icon.color` is tinted explicitly.
///
/// Just like `DialogFrame`, the palette is written imperatively because
/// `palette` is a grouped property whose bindings do not re-evaluate when
/// `theme.dark` flips while the window is open.
Menu {
    id: menu

    property Theme theme: Theme {}

    function applyTheme() {
        palette.window = menu.theme.surface
        palette.windowText = menu.theme.text
        palette.base = menu.theme.surface
        palette.alternateBase = menu.theme.surfaceAlt
        palette.text = menu.theme.text
        palette.button = menu.theme.surface
        palette.buttonText = menu.theme.text
        palette.brightText = "#ffffff"
        palette.highlight = menu.theme.accent
        palette.highlightedText = menu.theme.accentText
        palette.placeholderText = menu.theme.textMuted
        palette.toolTipBase = menu.theme.surfaceAlt
        palette.toolTipText = menu.theme.text
        palette.mid = menu.theme.border
        palette.dark = menu.theme.border
        palette.light = menu.theme.surfaceAlt
        palette.shadow = menu.theme.border

        for (var i = 0; i < menu.count; ++i) {
            var entry = menu.itemAt(i)
            if (entry && entry.icon !== undefined) {
                entry.icon.color = entry.enabled ? menu.theme.text : menu.theme.textMuted
            }
        }
    }

    Connections {
        target: menu.theme
        function onDarkChanged() { menu.applyTheme() }
    }

    Component.onCompleted: menu.applyTheme()
    onAboutToShow: menu.applyTheme()
}
