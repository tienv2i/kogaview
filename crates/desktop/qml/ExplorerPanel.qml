import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The left dock's second page: the folder tree.
//
// It is a view, not a model: the folders come from `listFolders` (C++ in the
// app, a stub in the QML suite) and the current folder comes from the published
// state, so the tree in the Viewer and the Editor is the same tree the Browser
// shows. Expansion is kept here rather than in the nodes, so a rebuild after a
// file operation does not collapse what the user had open.
//
// A click on a folder asks the host to navigate; the host decides whether that
// is a `navigate` in place (the Browser) or a switch to the Browser (the Viewer
// and the Editor).
Item {
    id: panel

    property Theme theme: Theme {}
    property var state: ({})
    property var listFolders: function(path) { return { ok: false, folders: [] }; }
    property string scrollObjectName: "explorerScroll"
    property string rootObjectName: "folderTreeRoot"
    property string rowObjectName: "folderTreeRow"

    signal navigateTo(string path)
    signal openMenu(string path)

    // Expansion lives outside the tree nodes, so the tree can be rebuilt after a
    // file operation without collapsing what the user had open.
    property var expandedPaths: ({})
    property var collapsedPaths: ({})
    property int lastTreeRevision: -1

    /// Reload the tree after Core reports that the folder tree may have changed
    /// (copy, move, trash, delete, new folder, explicit refresh). Coalesced so a
    /// burst of state updates rebuilds the tree once.
    function requestTreeRefresh() {
        treeRefreshTimer.restart()
    }

    function reload() {
        var root = treeRoot.item
        if (!root) return
        var savedY = treeScroll.contentY
        root.reloadChildren()
        // Rebuilding the nodes changes the content height, so the scroll offset
        // is restored afterwards and clamped to the new content.
        Qt.callLater(function() {
            var limit = Math.max(0, treeScroll.contentHeight - treeScroll.height)
            treeScroll.contentY = Math.min(savedY, limit)
        })
    }

    Timer {
        id: treeRefreshTimer
        interval: 120
        onTriggered: panel.reload()
    }

    Connections {
        target: panel
        function onStateChanged() {
            var revision = panel.state.treeRevision
            if (typeof revision !== "number") return
            if (panel.lastTreeRevision === revision) return
            var isFirstState = panel.lastTreeRevision < 0
            panel.lastTreeRevision = revision
            if (!isFirstState) panel.requestTreeRefresh()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        Label {
            Layout.fillWidth: true
            text: qsTr("Explorer")
            color: panel.theme.textMuted
            font.bold: true
            font.pixelSize: 12
        }

        Flickable {
            id: treeScroll
            objectName: panel.scrollObjectName
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: treeRoot.height
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            /// Five 24 px rows per notch, like a tree in any other file
            /// manager — Qt's own 72 px is three.
            WheelScroll {
                view: treeScroll
                step: 120
            }

            Loader {
                id: treeRoot
                objectName: panel.rootObjectName
                width: parent.width
                height: item ? item.implicitHeight : 0
                // The tree is rooted at the folder the user opened, not at
                // whatever folder was navigated to, so browsing the tree or the
                // grid never moves its root.
                property string folderPath: panel.state.rootFolder
                                           || panel.state.currentFolder || ""
                // No root node at all when nothing is open, instead of an empty
                // row in the tree.
                sourceComponent: folderPath ? folderNode : null
                onLoaded: if (item) item.reset(folderPath, panel.folderLabel(folderPath), 0)
                onFolderPathChanged: if (item) item.reset(folderPath, panel.folderLabel(folderPath), 0)
            }
        }
    }

    // ------------------------------------------------------- folder tree node
    Component {
        id: folderNode

        Column {
            id: node

            property string nodePath: ""
            property string nodeName: ""
            property int depth: 0
            property bool expanded: false
            property var children: []

            spacing: 0
            width: parent ? parent.width : 200

            function reset(path, name, level) {
                nodePath = path;
                nodeName = name;
                depth = level;
                children = [];
                expanded = false;
                if (path) {
                    expanded = true;
                    panel.expandedPaths[path] = true;
                    delete panel.collapsedPaths[path];
                    load();
                }
            }

            function load() {
                if (!nodePath) return;
                var response = panel.listFolders(nodePath);
                children = (response && response.ok) ? response.folders : [];
            }

            /// Click or double-click: expand the node and show that folder in
            /// the grid. This navigates — it never re-roots the tree, which only
            /// quick access and "Open folder" do.
            function activate() {
                if (!nodePath) return;
                expand();
                panel.navigateTo(nodePath);
            }

            function expand() {
                if (!nodePath || expanded) return;
                expanded = true;
                panel.expandedPaths[nodePath] = true;
                delete panel.collapsedPaths[nodePath];
                load();
            }

            function collapse() {
                if (!nodePath || !expanded) return;
                expanded = false;
                delete panel.expandedPaths[nodePath];
                // Remember the collapse so auto-reveal does not undo it.
                panel.collapsedPaths[nodePath] = true;
            }

            /// Collapse/expand from the disclosure arrow; the arrow only changes
            /// the tree, it does not navigate.
            function toggleExpanded() {
                if (expanded) {
                    collapse();
                } else {
                    expand();
                }
            }

            /// Expand (never collapse) towards the folder shown in the grid, so
            /// navigating from the grid, breadcrumbs or the toolbar reveals the
            /// node. A node the user collapsed on purpose is left alone.
            function followCurrent() {
                if (!nodePath || panel.collapsedPaths[nodePath]) return;
                var current = panel.state.currentFolder || "";
                if (!current) return;
                if (current !== nodePath && current.indexOf(nodePath + "/") !== 0) return;
                expand();
            }

            /// Restore the expansion recorded before the tree was rebuilt.
            function restoreExpansion() {
                if (!nodePath) return;
                if (panel.expandedPaths[nodePath] === true) expand();
            }

            /// Rebuild this node's children from the filesystem, then refresh the
            /// already-loaded subtree below it. A change deeper in the tree
            /// leaves this listing identical, so no delegate would be recreated
            /// and the stale grandchild rows would survive; recursing into the
            /// live child nodes (which each reload their own children) reaches
            /// every open level. The current folder and the expansion stay put.
            function reloadChildren() {
                if (!expanded) return;
                load();
                for (var i = 0; i < childRepeater.count; ++i) {
                    var loader = childRepeater.itemAt(i);
                    var child = loader ? loader.item : null;
                    if (child) child.reloadChildren();
                }
            }

            Rectangle {
                objectName: panel.rowObjectName
                width: node.width
                height: 30
                radius: 4
                color: node.nodePath === (panel.state.currentFolder || "")
                       ? panel.theme.selection
                       : (nodeHover.hovered ? panel.theme.hover : "transparent")

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 4 + Math.min(node.depth, 10) * 12
                    anchors.rightMargin: 4
                    spacing: 2

                    ToolButton {
                        implicitWidth: 20
                        implicitHeight: 20
                        text: node.expanded ? "▾" : "▸"
                        display: AbstractButton.TextOnly
                        focusPolicy: Qt.NoFocus
                        activeFocusOnTab: false
                        onClicked: node.toggleExpanded()
                    }

                    Icon {
                        iconName: "folder-symbolic"
                        iconSize: 15
                        iconColor: panel.theme.textMuted
                    }

                    Label {
                        text: node.nodeName
                        color: panel.theme.text
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                }

                HoverHandler { id: nodeHover }
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    // Both a click and a double-click expand the node; the tree
                    // root and the grid folder stay where the user opened them.
                    onSingleTapped: node.activate()
                    onDoubleTapped: node.activate()
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onSingleTapped: panel.openMenu(node.nodePath)
                }
            }

            Repeater {
                id: childRepeater
                model: node.expanded ? node.children : []

                delegate: Loader {
                    width: node.width
                    sourceComponent: folderNode
                    onLoaded: {
                        item.nodePath = modelData.path;
                        item.nodeName = modelData.name;
                        item.depth = node.depth + 1;
                        item.expanded = false;
                        item.restoreExpansion();
                        item.followCurrent();
                    }
                }
            }

            Connections {
                target: panel
                function onStateChanged() { node.followCurrent() }
            }
        }
    }

    function folderLabel(path) {
        if (!path) return ""
        if (path === (panel.state.home || "")) return qsTr("Home")
        var trimmed = ("" + path).replace(/\/+$/, "")
        var index = trimmed.lastIndexOf("/")
        return index >= 0 ? trimmed.substring(index + 1) : trimmed
    }
}
