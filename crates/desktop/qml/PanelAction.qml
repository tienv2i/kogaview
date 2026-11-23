import QtQuick
import QtQuick.Controls

// One full-width action row in a dock page (the Browser's Batch page).
//
// Drawn here rather than with a stock `Button`: inside this window the
// platform style's fill ignores the theme and painted a white slab with
// near-black text on the dark dock, and a running job's disabled state was a
// paler slab of the same thing. The colours, the radius and the disabled ink
// come from the app theme, like the rest of the chrome (see `ToolbarButton`,
// `ToolRailButton` and `PanelTabs` for the same reason).
//
// The words are the caller's: this file draws no string and owns nothing to
// translate, so a page keeps its own sentences.
AbstractButton {
    id: root

    property Theme theme: Theme {}
    /// The one action a page wants the eye to land on (the form's Run). It is
    /// painted with the accent rather than the surface, which is what a stock
    /// `highlighted` button would do if its palette were the theme's.
    property bool primary: false

    implicitHeight: 30
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false

    background: Rectangle {
        radius: root.theme.radius
        scale: root.down && root.enabled ? 0.97 : 1.0
        color: !root.enabled ? "transparent"
             : root.primary ? (root.hovered ? Qt.lighter(root.theme.accent, 1.1)
                                            : root.theme.accent)
             : root.hovered ? root.theme.hover
             : root.theme.surface
        border.width: 1
        border.color: root.enabled ? (root.primary ? root.theme.accent : root.theme.border)
                                   : Qt.rgba(root.theme.border.r, root.theme.border.g,
                                             root.theme.border.b, 0.5)
        Behavior on color { ColorAnimation { duration: 110; easing.type: Easing.OutQuad } }
        Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
    }

    contentItem: Text {
        text: root.text
        color: !root.enabled ? root.theme.textMuted
             : root.primary ? root.theme.accentText
             : root.theme.text
        opacity: root.enabled ? 1.0 : 0.7
        font: root.font
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
