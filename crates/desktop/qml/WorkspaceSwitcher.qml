import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts

// Browser / Viewer / Editor switcher for the main toolbar.
//
// Adapts smoothly across three widths:
// 1. Wide (`showLabels: true`, `collapsed: false`): 3 labelled buttons.
// 2. Medium (`showLabels: false`, `collapsed: false`): 3 icon-only buttons.
// 3. Narrow (`collapsed: true`): 1 compact dropdown button (`[icon ▾]`) opening
//    the workspace picker menu, saving ~60 px for workspace controls.
RowLayout {
    id: root

    property Theme theme: Theme {}
    property string workspace: "browser"
    /// Whether the shell has room for the labels; see `Main.qml`.
    property bool showLabels: false
    /// When true (narrow/mini toolbar), collapse the 3 buttons into 1 dropdown.
    property bool collapsed: false
    /// The measured pieces of the toolbar; `ToolbarMetrics.qml`.
    property QtObject metrics: ToolbarMetrics {}

    readonly property var model: [
        {
            name: "browser",
            label: qsTr("Browser"),
            icon: "view-grid-symbolic",
            bundledIcon: "icons/browser.svg",
            shortcut: "Ctrl+1",
            tip: qsTr("Browser workspace: folders and thumbnails (Ctrl+1)")
        },
        {
            name: "viewer",
            label: qsTr("Viewer"),
            icon: "image-x-generic-symbolic",
            bundledIcon: "icons/viewer.svg",
            shortcut: "Ctrl+2",
            tip: qsTr("Viewer workspace: zoom, pan, rotate (Ctrl+2)")
        },
        {
            name: "editor",
            label: qsTr("Editor"),
            icon: "document-edit-symbolic",
            bundledIcon: "icons/editor.svg",
            shortcut: "Ctrl+3",
            tip: qsTr("Editor workspace: non-destructive edits (Ctrl+3)")
        }
    ]

    readonly property var currentEntry: {
        for (var i = 0; i < root.model.length; ++i) {
            if (root.model[i].name === root.workspace) return root.model[i]
        }
        return root.model[0]
    }

    signal selected(string workspace)

    readonly property real iconsWidth: root.metrics.switcherIconsWidth
    readonly property real labelsWidth: root.metrics.switcherLabelsWidth

    spacing: root.metrics.buttonSpacing

    Repeater {
        model: root.model

        delegate: CompactToolbarButton {
            objectName: "workspaceButton-" + modelData.name
            visible: !root.collapsed
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

    ToolButton {
        id: dropdownButton
        objectName: "workspaceSwitcherDropdown"
        visible: root.collapsed
        implicitWidth: root.metrics.switcherCollapsedWidth
        implicitHeight: 34
        padding: 0
        focusPolicy: Qt.NoFocus
        activeFocusOnTab: false
        checked: switcherMenu.visible

        contentItem: Item {
            Row {
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                spacing: 6

                IconImage {
                    source: root.currentEntry.bundledIcon
                    sourceSize: Qt.size(32, 32)
                    width: 16
                    height: 16
                    fillMode: Image.PreserveAspectFit
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.theme.accent
                }

                IconImage {
                    source: "icons/chevron.svg"
                    sourceSize: Qt.size(20, 20)
                    width: 10
                    height: 10
                    fillMode: Image.PreserveAspectFit
                    anchors.verticalCenter: parent.verticalCenter
                    color: dropdownButton.hovered ? root.theme.text : root.theme.textMuted
                }
            }
        }

        background: Rectangle {
            radius: root.theme.radius
            color: dropdownButton.checked ? root.theme.selection
                 : dropdownButton.hovered ? root.theme.hover
                 : root.theme.surfaceAlt
            border.width: 1
            border.color: dropdownButton.checked || dropdownButton.hovered
                          ? root.theme.accent : root.theme.border
        }

        Accessible.name: root.currentEntry.label
        ToolTip.visible: hovered
        ToolTip.text: root.currentEntry.tip
        onClicked: switcherMenu.toggleFrom(dropdownButton)
    }

    AppMenu {
        id: switcherMenu
        objectName: "workspaceSwitcherMenu"
        theme: root.theme

        Repeater {
            model: root.model

            delegate: MenuItem {
                required property var modelData
                objectName: "workspaceMenu-" + modelData.name
                text: modelData.label
                icon.source: modelData.bundledIcon
                checkable: true
                checked: root.workspace === modelData.name
                onTriggered: root.selected(modelData.name)
                MenuShortcut { text: modelData.shortcut }
            }
        }
    }
}
