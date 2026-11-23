import QtQuick
import QtQuick.Controls

// The small menu a folder row offers in the Viewer and the Editor.
//
// Both workspaces show the same left dock as the Browser but own no file list,
// so the Browser's full folder menu (new folder, add to quick access, copy
// path…) would be a menu of things these views do not do. Two actions are
// enough: go to that folder in the Browser, or show it in the desktop's file
// manager. The Browser keeps its own, longer menu.
AppMenu {
    id: menu

    property string path: ""

    signal openInBrowser()
    signal reveal()

    implicitWidth: 230

    MenuItem {
        objectName: "folderMenuOpenInBrowser"
        text: qsTr("Open in Browser")
        icon.name: "folder-open-symbolic"
        onTriggered: menu.openInBrowser()
    }
    MenuItem {
        objectName: "folderMenuReveal"
        text: menu.theme.menuEntries[39]
        icon.name: "folder-documents-symbolic"
        onTriggered: menu.reveal()
    }
}
