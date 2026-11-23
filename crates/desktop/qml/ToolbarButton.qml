import QtQuick
import QtQuick.Controls

// Themed toolbar button. The stock ToolButton draws its checked state with the
// platform palette, which is unreadable against the custom dark/light surfaces,
// so colors are derived from the app theme instead.
ToolButton {
    id: root

    property Theme theme: Theme {}

    display: AbstractButton.IconOnly
    // 34 px is the icon-only square; when a label is shown the button grows to
    // fit `<icon> <text>` instead of clipping the text.
    implicitWidth: Math.max(34, contentItem
                            ? contentItem.implicitWidth + leftPadding + rightPadding
                            : 34)
    implicitHeight: 34
    leftPadding: 8
    rightPadding: 8
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false
    icon.width: 18
    icon.height: 18
    icon.color: !enabled ? Qt.rgba(theme.textMuted.r, theme.textMuted.g, theme.textMuted.b, 0.4)
                : checked ? theme.accent
                : hovered ? theme.text
                : theme.textMuted

    function applyPalette() {
        palette.button = root.theme.surface
        palette.buttonText = root.theme.text
        palette.windowText = root.theme.text
        palette.highlight = root.theme.accent
        palette.highlightedText = root.theme.accentText
    }

    Connections {
        target: root.theme
        function onDarkChanged() { root.applyPalette() }
    }
    Component.onCompleted: root.applyPalette()

    background: Rectangle {
        radius: root.theme.radius
        color: root.checked ? root.theme.selection
             : (root.hovered ? root.theme.hover : "transparent")
        border.width: root.checked ? 1 : 0
        border.color: root.theme.accent
    }
}
