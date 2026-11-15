import QtQuick
import QtQuick.Controls

// Themed toolbar button. The stock ToolButton draws its checked state with the
// platform palette, which is unreadable against the custom dark/light surfaces,
// so colors are derived from the app theme instead.
ToolButton {
    id: root

    property Theme theme: Theme {}

    display: AbstractButton.IconOnly
    implicitWidth: 34
    implicitHeight: 34
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false
    icon.width: 18
    icon.height: 18
    icon.color: !enabled ? Qt.rgba(theme.textMuted.r, theme.textMuted.g, theme.textMuted.b, 0.4)
                : checked ? theme.accent
                : hovered ? theme.text
                : theme.textMuted

    background: Rectangle {
        radius: root.theme.radius
        color: root.checked ? root.theme.selection
             : (root.hovered ? root.theme.hover : "transparent")
        border.width: root.checked ? 1 : 0
        border.color: root.theme.accent
    }
}
