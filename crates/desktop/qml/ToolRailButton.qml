import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl

// One square button in the Editor's tool rail.
//
// The rail is icon-only, so every button carries its sentence in a tooltip and
// in its accessible name — without either, a rail of drawings is a memory
// test. The colours come from the app theme rather than the platform palette.
ToolButton {
    id: root

    property Theme theme: Theme {}
    property string iconSource: ""
    property string tooltip: ""
    /// The tool this button selects is current (or the action is busy).
    property bool active: false

    readonly property color iconColor: !enabled
                                       ? Qt.rgba(theme.textMuted.r, theme.textMuted.g,
                                                 theme.textMuted.b, 0.4)
                                       : active ? theme.accent
                                       : hovered ? theme.text
                                       : theme.textMuted

    display: AbstractButton.IconOnly
    // The style's own "this is the current one" flag; the views and the QML
    // suite already read `highlighted`, and the background below draws it.
    highlighted: root.active

    // The square and the drawing are this rail's numbers, not the style's.
    // Inheriting them made the icons start at one size and appear smaller after
    // the first click, because the platform style re-laid the content out. Both
    // are logical pixels, so Qt scales them by the interface scale; the drawing
    // is rasterised at 2× so a 200 % desktop is sharp rather than stretched.
    readonly property int iconSize: 20
    readonly property int buttonSize: 34

    implicitWidth: buttonSize
    implicitHeight: buttonSize
    padding: 0
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false

    icon.source: root.iconSource
    icon.width: root.iconSize
    icon.height: root.iconSize
    icon.color: root.iconColor

    // The button draws its own drawing. `icon.source` is enough under the Basic
    // style, but Breeze's Button content item only looks at `icon.name` and
    // substitutes a generic document glyph for a file source — the rail was a
    // row of identical page icons on this desktop, and empty on the Basic one
    // before the tinted source was drawn here. `IconImage` is the renderer the
    // styles themselves use, keeps the SVG's alpha, and takes the colour.
    contentItem: Item {
        IconImage {
            id: drawing
            source: root.iconSource
            sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
            width: root.iconSize
            height: root.iconSize
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
            color: root.iconColor
        }
    }

    /// The drawing itself. `AbstractButton` sizes its content item to the
    /// control, so the size that matters is this one, not the wrapper's.
    readonly property Item iconDrawing: drawing

    Accessible.name: root.tooltip
    ToolTip.visible: hovered && root.tooltip.length > 0
    ToolTip.text: root.tooltip

    background: Rectangle {
        radius: root.theme.radius
        scale: root.down ? 0.94 : 1.0
        color: root.active ? root.theme.selection
             : root.hovered ? root.theme.hover
             : "transparent"
        border.width: root.active ? 1 : 0
        border.color: root.theme.accent
        Behavior on color { ColorAnimation { duration: 110; easing.type: Easing.OutQuad } }
        Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
    }
}
