import QtQuick
import QtQuick.Layouts

// The left-hand column, shared by the three workspaces.
//
// It is a surface and two stacked panels, not one sidebar: Quick access and
// Explorer are independent, each can be switched off in Settings › Appearance,
// and whichever is left takes the whole column. The order is fixed — pinned
// folders above the tree — because both answer "take me to a folder" and a tab
// strip for two short lists would cost a row to save nothing.
//
// The panels themselves are shared QML (`QuickAccessPanel.qml`,
// `ExplorerPanel.qml`), so the Viewer and the Editor show the same tree the
// Browser does. Which of them exist is the saved layout's answer; this file
// only draws what it is told and keeps no preference of its own.
Item {
    id: dock

    property Theme theme: Theme {}
    property var state: ({})
    property var listFolders: function(path) { return { ok: false, folders: [] }; }
    property bool quickAccessShown: true
    property bool explorerShown: true
    /// The width the splitter is dragging to; the host owns the value so a
    /// layout loaded from `config.json` and a drag write the same place.
    signal openFolder(string path)
    signal navigateTo(string path)
    signal openMenu(string path)
    signal quickMenu(string path)

    readonly property bool empty: !dock.quickAccessShown && !dock.explorerShown

    Rectangle {
        anchors.fill: parent
        color: dock.theme.sidebar
        border.width: 1
        border.color: dock.theme.border
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6
        visible: !dock.empty

        QuickAccessPanel {
            id: quickAccess
            objectName: "quickAccessPanel"
            Layout.fillWidth: true
            // A short list is a short panel; the tree gets the rest. With the
            // tree switched off there is nothing to share with, so the list
            // takes the column and scrolls.
            Layout.preferredHeight: dock.explorerShown
                                    ? Math.min(quickAccess.naturalHeight, 190)
                                    : dock.height
            Layout.fillHeight: !dock.explorerShown
            visible: dock.quickAccessShown
            theme: dock.theme
            state: dock.state
            favorites: dock.state.favorites || []
            onOpenFolder: function(path) { dock.openFolder(path) }
            onOpenMenu: function(path) { dock.quickMenu(path) }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            visible: dock.quickAccessShown && dock.explorerShown
            color: dock.theme.border
        }

        ExplorerPanel {
            objectName: "explorerPanel"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: dock.explorerShown
            theme: dock.theme
            state: dock.state
            listFolders: dock.listFolders
            onNavigateTo: function(path) { dock.navigateTo(path) }
            onOpenMenu: function(path) { dock.openMenu(path) }
        }
    }
}
