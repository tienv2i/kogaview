import QtQuick
import QtQuick.Controls

/// Shared plugin-driven "Quick actions" submenu reused by both Browser's
/// `fileMenu` and Viewer's `canvasMenu`.
///
/// Actions are declared in each plugin's `manifest.json` (`quickActions`) and
/// published by Core in `state.quickActions`. Filtering by `workspace` lets a
/// plugin target Browser, Viewer, or both from one shared component.
AppMenu {
    id: menu
    objectName: "quickActionMenu"
    title: qsTr("Quick actions")

    /// `"browser"` or `"viewer"`.
    property string workspace: "browser"
    /// Full `state.quickActions` list published by Core.
    property var quickActions: []
    /// Target image paths (e.g. `[view.menuPath]` or `[view.currentPath]`).
    property var targetPaths: []
    /// False when the right-clicked target is a directory or non-image.
    property bool targetEnabled: true

    signal actionTriggered(string pluginId, string actionId, var paths)

    readonly property var filteredActions: {
        var list = menu.quickActions || []
        var out = []
        for (var i = 0; i < list.length; ++i) {
            var item = list[i]
            if (!item) continue
            var ws = item.workspaces || []
            if (ws.length === 0 || ws.indexOf(menu.workspace) >= 0) {
                out.push(item)
            }
        }
        return out
    }

    enabled: menu.targetEnabled && menu.filteredActions.length > 0

    Instantiator {
        model: menu.filteredActions
        delegate: MenuItem {
            required property var modelData
            text: modelData.label
            icon.source: "icons/ai-rembg.svg"
            enabled: menu.targetEnabled
            onTriggered: menu.actionTriggered(modelData.pluginId, modelData.id, menu.targetPaths)
        }
        onObjectAdded: function(index, object) {
            menu.insertItem(index, object)
        }
        onObjectRemoved: function(index, object) {
            menu.removeItem(object)
        }
    }
}
