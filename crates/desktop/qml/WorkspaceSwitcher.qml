import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Browser / Viewer / Editor switcher for the main toolbar.
//
// Every button renders `<icon> <text>` instead of an icon alone: with three
// icon-only buttons the current workspace was not readable at a glance and the
// tooltips were the only way to tell them apart.
RowLayout {
    id: root

    property Theme theme: Theme {}
    property string workspace: "browser"

    signal selected(string workspace)

    spacing: 2

    Repeater {
        model: [
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

        delegate: ToolbarButton {
            objectName: "workspaceButton-" + modelData.name
            theme: root.theme
            checkable: true
            checked: root.workspace === modelData.name
            display: AbstractButton.TextBesideIcon
            icon.name: modelData.icon
            text: modelData.label
            ToolTip.visible: hovered
            ToolTip.text: modelData.tip
            onClicked: root.selected(modelData.name)
        }
    }
}
