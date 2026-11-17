import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Browser / Viewer / Editor switcher for the main toolbar.
//
// Every button renders `<icon> <text>` instead of an icon alone — with three
// icon-only buttons the current workspace was not readable at a glance and the
// tooltips were the only way to tell them apart. The text is the first thing
// dropped when the window narrows (`CompactToolbarButton`), so the switcher
// stays three icons wide instead of forcing the rest of the toolbar out of the
// window. Widths come from `ToolbarMetrics`, the same object the window's
// minimum width is derived from.
RowLayout {
    id: root

    property Theme theme: Theme {}
    property string workspace: "browser"
    /// Whether the shell has room for the labels; see `Main.qml`.
    property bool showLabels: false
    /// The measured pieces of the toolbar; `ToolbarMetrics.qml`.
    property QtObject metrics: ToolbarMetrics {}

    readonly property var model: [
        {
            name: "browser",
            label: qsTr("Browser"),
            icon: "view-grid-symbolic",
            tip: qsTr("Browser workspace: folders and thumbnails")
        },
        {
            name: "viewer",
            label: qsTr("Viewer"),
            icon: "image-x-generic-symbolic",
            tip: qsTr("Viewer workspace: zoom, pan, rotate")
        },
        {
            name: "editor",
            label: qsTr("Editor"),
            icon: "document-edit-symbolic",
            tip: qsTr("Editor workspace: non-destructive edits")
        }
    ]

    signal selected(string workspace)

    /// Two widths the window floor and the label threshold are built from:
    /// the switcher as three icons, and as three labelled buttons. They come
    /// from `ToolbarMetrics`, so they cannot drift from the rest of the
    /// toolbar's arithmetic.
    readonly property real iconsWidth: root.metrics.switcherIconsWidth
    readonly property real labelsWidth: root.metrics.switcherLabelsWidth

    spacing: root.metrics.buttonSpacing

    Repeater {
        model: root.model

        delegate: CompactToolbarButton {
            objectName: "workspaceButton-" + modelData.name
            theme: root.theme
            metrics: root.metrics
            showLabel: root.showLabels
            checkable: true
            checked: root.workspace === modelData.name
            icon.name: modelData.icon
            text: modelData.label
            ToolTip.visible: hovered
            ToolTip.text: modelData.tip
            onClicked: root.selected(modelData.name)
        }
    }
}
