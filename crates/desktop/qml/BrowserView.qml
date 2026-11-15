import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: view

    property Theme theme: Theme {}
    property var state: ({})
    property var listFolders: function(path) { return { ok: false, folders: [] }; }

    signal command(var command)
    signal toast(string message)
    signal copyImage(string path)
    signal copyText(string text)
    signal openExternal(string path)
    signal requestDestination(string action, var paths)
    signal requestDelete(var paths)

    property string menuPath: ""
    property bool menuIsImage: false
    property bool menuIsDir: false
    property string newFolderParent: ""

    // Expansion lives outside the tree nodes so the tree can be rebuilt after a
    // file operation without collapsing what the user had open.
    property var expandedPaths: ({})
    property var collapsedPaths: ({})
    property int lastTreeRevision: -1

    /// Reload the tree after Core reports that the folder tree may have changed
    /// (copy, move, trash, delete, new folder, explicit refresh). Coalesced so a
    /// burst of state updates rebuilds the tree once.
    function requestTreeRefresh() {
        treeRefreshTimer.restart();
    }

    function reloadTree() {
        var root = treeRoot.item;
        if (!root) return;
        var savedY = treeScroll.contentY;
        root.reloadChildren();
        // Rebuilding the nodes changes the content height, so the scroll offset
        // is restored afterwards and clamped to the new content.
        Qt.callLater(function() {
            var limit = Math.max(0, treeScroll.contentHeight - treeScroll.height);
            treeScroll.contentY = Math.min(savedY, limit);
        });
    }

    Timer {
        id: treeRefreshTimer
        interval: 120
        onTriggered: view.reloadTree()
    }

    Connections {
        target: view
        function onStateChanged() {
            var revision = view.state.treeRevision;
            if (typeof revision !== "number") return;
            if (view.lastTreeRevision === revision) return;
            var isFirstState = view.lastTreeRevision < 0;
            view.lastTreeRevision = revision;
            if (!isFirstState) view.requestTreeRefresh();
        }
    }

    property var selectionInfo: view.state.selectionInfo || null

    function parentPath(path) {
        if (!path) return "";
        var trimmed = ("" + path).replace(/\/+$/, "");
        var index = trimmed.lastIndexOf("/");
        if (index <= 0) return "/";
        return trimmed.substring(0, index);
    }

    function baseName(path) {
        if (!path) return "";
        var trimmed = ("" + path).replace(/\/+$/, "");
        var index = trimmed.lastIndexOf("/");
        return index >= 0 ? trimmed.substring(index + 1) : trimmed;
    }

    function folderLabel(path) {
        if (!path) return "";
        if (path === view.state.home) return "Home";
        return view.baseName(path) || "/";
    }

    function isFavorite(path) {
        return (view.state.favorites || []).indexOf(path) >= 0;
    }

    function openEntry(entry) {
        if (entry.isDir) {
            // Browsing into a folder from the grid navigates; only quick access
            // and "Open folder" re-root the explorer tree.
            view.command({ type: "navigate", path: entry.path });
        } else if (entry.isImage) {
            view.command({ type: "open_file", paths: [entry.path] });
        } else {
            view.openExternal(entry.path);
        }
    }

    function goUp() {
        var folder = view.state.currentFolder;
        if (!folder) return;
        view.command({ type: "navigate", path: view.parentPath(folder) });
    }

    function promptNewFolder(parent) {
        view.newFolderParent = parent || view.state.currentFolder || "";
        newFolderDialog.open();
    }

    function openFileMenu(entry) {
        view.menuPath = entry.path;
        view.menuIsImage = entry.isImage;
        view.menuIsDir = entry.isDir;
        fileMenu.popup();
    }

    function openFolderMenu(path) {
        view.menuPath = path;
        view.menuIsDir = true;
        view.menuIsImage = false;
        folderMenu.popup();
    }

    function openQuickMenu(path) {
        view.menuPath = path;
        quickMenu.popup();
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------- left sidebar
        Rectangle {
            visible: !!view.state.leftPanel
            Layout.preferredWidth: view.theme.panelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            border.width: 1
            border.color: view.theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Label {
                    text: "Quick access"
                    color: view.theme.textMuted
                    font.bold: true
                    font.pixelSize: 12
                }

                ListView {
                    id: quickList
                    objectName: "quickAccessList"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 190)
                    clip: true
                    interactive: contentHeight > height
                    model: view.state.favorites || []

                    delegate: Rectangle {
                        objectName: "quickAccessItem"
                        width: quickList.width
                        height: 32
                        radius: view.theme.radius
                        color: quickHover.hovered ? view.theme.hover : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            spacing: 6

                            Label {
                                text: "★"
                                color: view.theme.accent
                            }
                            Label {
                                text: view.folderLabel(modelData)
                                color: view.theme.text
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }
                        }

                        HoverHandler { id: quickHover }
                        TapHandler {
                            acceptedButtons: Qt.LeftButton
                            onSingleTapped: view.command({ type: "open_folder", path: modelData })
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onSingleTapped: view.openQuickMenu(modelData)
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: view.theme.border
                }

                Label {
                    text: "Folders"
                    color: view.theme.textMuted
                    font.bold: true
                    font.pixelSize: 12
                }

                Flickable {
                    id: treeScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: treeRoot.height
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    Loader {
                        id: treeRoot
                        objectName: "folderTreeRoot"
                        width: parent.width
                        height: item ? item.implicitHeight : 0
                        // The tree is rooted at the folder the user opened, not
                        // at whatever folder was navigated to, so browsing the
                        // tree or the grid never moves its root.
                        property string folderPath: view.state.rootFolder
                                                   || view.state.currentFolder || ""
                        // No root node at all when nothing is open, instead of
                        // an empty row in the tree.
                        sourceComponent: folderPath ? folderNode : null
                        onLoaded: if (item) item.reset(folderPath, view.folderLabel(folderPath), 0)
                        onFolderPathChanged: if (item) item.reset(folderPath, view.folderLabel(folderPath), 0)
                    }
                }
            }
        }

        // ------------------------------------------------------------ center
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                id: crumbBar
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                color: view.theme.surface
                border.width: 1
                border.color: view.theme.border

                property var crumbs: view.state.breadcrumbs || []
                property var visibleCrumbs: []
                property var hiddenCrumbs: []

                function recalc() {
                    var all = crumbs || [];
                    if (all.length === 0) {
                        visibleCrumbs = [];
                        hiddenCrumbs = [];
                        return;
                    }
                    // Keep the root visible: when space runs out, elide the
                    // middle of the path, never the anchor.
                    var available = Math.max(160, width - 16);
                    var rootWidth = crumbMetrics.advanceWidth(all[0].name) + 40;
                    var tail = [all[all.length - 1]];
                    var used = crumbMetrics.advanceWidth(all[all.length - 1].name) + 40;
                    for (var index = all.length - 2; index >= 1; index--) {
                        var itemWidth = crumbMetrics.advanceWidth(all[index].name) + 40;
                        // Reserve room for the ellipsis button while collapsing.
                        var needsEllipsis = (index > 1);
                        if (used + itemWidth + rootWidth + (needsEllipsis ? 42 : 0) > available) {
                            break;
                        }
                        used += itemWidth;
                        tail.unshift(all[index]);
                    }
                    var hidden = all.slice(1, all.length - tail.length);
                    // The root is rendered separately so the ellipsis always
                    // follows it, never precedes it.
                    hiddenCrumbs = hidden;
                    visibleCrumbs = tail;
                }

                FontMetrics {
                    id: crumbMetrics
                    font: crumbFont.font
                }
                FontMetrics {
                    id: crumbFont
                    font: Qt.font({ pixelSize: 13 })
                }

                Component.onCompleted: recalc()
                onWidthChanged: recalc()
                onCrumbsChanged: recalc()

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 2

                    Label {
                        objectName: "crumbLabel"
                        visible: crumbBar.crumbs.length > 0
                        text: crumbBar.crumbs.length > 0 ? crumbBar.crumbs[0].name : ""
                        color: view.theme.text
                        elide: Text.ElideMiddle
                        Layout.maximumWidth: 190
                        padding: 4
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            acceptedButtons: Qt.LeftButton
                            onSingleTapped: view.command({
                                type: "navigate",
                                path: crumbBar.crumbs[0].path
                            })
                        }
                    }

                    Label {
                        visible: crumbBar.crumbs.length > 1
                        text: "›"
                        color: view.theme.textMuted
                    }

                    ToolButton {
                        visible: crumbBar.hiddenCrumbs.length > 0
                        text: "…"
                        implicitWidth: 28
                        implicitHeight: 28
                        ToolTip.visible: hovered
                        ToolTip.text: "Hidden parent folders"
                        onClicked: hiddenMenu.popup()
                    }

                    Label {
                        visible: crumbBar.hiddenCrumbs.length > 0
                        text: "›"
                        color: view.theme.textMuted
                    }

                    Repeater {
                        model: crumbBar.visibleCrumbs

                        delegate: RowLayout {
                            spacing: 2

                            Label {
                                objectName: "crumbLabel"
                                text: modelData.name
                                color: view.theme.text
                                elide: Text.ElideMiddle
                                Layout.maximumWidth: 190
                                padding: 4
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    acceptedButtons: Qt.LeftButton
                                    onSingleTapped: view.command({
                                        type: "navigate",
                                        path: modelData.path
                                    })
                                }
                            }
                            Label {
                                visible: index < crumbBar.visibleCrumbs.length - 1
                                text: "›"
                                color: view.theme.textMuted
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Label {
                        visible: !!view.state.busy
                        text: "Loading…"
                        color: view.theme.textMuted
                    }
                }

                Menu {
                    id: hiddenMenu
                    Instantiator {
                        model: crumbBar.hiddenCrumbs
                        delegate: MenuItem {
                            text: modelData.name
                            onTriggered: view.command({
                                type: "navigate",
                                path: modelData.path
                            })
                        }
                        onObjectAdded: (index, object) => hiddenMenu.insertItem(index, object)
                        onObjectRemoved: (index, object) => hiddenMenu.removeItem(object)
                    }
                }
            }

            GridView {
                id: grid
                objectName: "fileGrid"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: view.state.entries || []
                cellWidth: Math.max(132, Math.floor(width / Math.max(1, Math.floor(width / 178))))
                cellHeight: Math.round(cellWidth * 0.78) + 32
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                    id: cell
                    objectName: "fileCell"
                    width: grid.cellWidth
                    height: grid.cellHeight

                    property var entry: modelData
                    property bool selected: (view.state.selection || []).indexOf(entry.path) >= 0

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: view.theme.radius
                        color: cell.selected ? view.theme.selection
                                            : (cellHover.hovered ? view.theme.hover : "transparent")
                        border.width: cell.selected ? 1 : 0
                        border.color: view.theme.accent
                    }

                    Item {
                        id: thumbFrame
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        anchors.topMargin: 10
                        height: parent.height - 42

                        Rectangle {
                            anchors.fill: parent
                            radius: 4
                            color: view.theme.thumb
                            clip: true

                            Image {
                                anchors.fill: parent
                                anchors.margins: 2
                                source: entry.isImage ? "file://" + entry.path : ""
                                asynchronous: true
                                cache: false
                                fillMode: Image.PreserveAspectFit
                                sourceSize.width: Math.max(64, Math.ceil(thumbFrame.width * 2))
                                sourceSize.height: Math.max(64, Math.ceil(thumbFrame.height * 2))
                            }

                            Icon {
                                visible: entry.isDir || !entry.isImage
                                anchors.centerIn: parent
                                iconName: entry.isDir ? "folder-symbolic"
                                                      : "image-missing-symbolic"
                                iconSize: 44
                                iconColor: view.theme.textMuted
                            }
                        }
                    }

                    Label {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        anchors.bottomMargin: 6
                        text: entry.name
                        color: view.theme.text
                        elide: Text.ElideMiddle
                        horizontalAlignment: Text.AlignHCenter
                        font.pixelSize: 12
                    }

                    HoverHandler { id: cellHover }

                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onSingleTapped: view.command({ type: "select", paths: [entry.path] })
                        onDoubleTapped: view.openEntry(entry)
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onSingleTapped: {
                            view.command({ type: "select", paths: [entry.path] });
                            view.openFileMenu(entry);
                        }
                    }
                }
            }

            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 8
                Layout.bottomMargin: 8
                visible: grid.count === 0 && !view.state.busy
                text: view.state.currentFolder
                      ? "This folder has no visible images or subfolders."
                      : "Open a folder to start browsing your photos."
                color: view.theme.textMuted
            }
        }

        // --------------------------------------------------- right sidebar
        Rectangle {
            visible: !!view.state.rightPanel
            Layout.preferredWidth: view.theme.previewWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            border.width: 1
            border.color: view.theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                Label {
                    text: "Preview"
                    color: view.theme.textMuted
                    font.bold: true
                    font.pixelSize: 12
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(230, width * 0.72)
                    radius: view.theme.radius
                    color: view.theme.thumb
                    clip: true

                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
                        source: (view.selectionInfo && view.selectionInfo.isImage)
                                ? "file://" + view.selectionInfo.path : ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: Math.ceil(width * 2)
                        sourceSize.height: Math.ceil(height * 2)
                    }

                    Label {
                        anchors.centerIn: parent
                        visible: !view.selectionInfo || !view.selectionInfo.isImage
                        text: view.selectionInfo ? "No image preview" : "Nothing selected"
                        color: view.theme.textMuted
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: view.selectionInfo ? view.selectionInfo.name : "—"
                    color: view.theme.text
                    font.bold: true
                    elide: Text.ElideMiddle
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 4

                    Label { text: "Type"; color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: view.selectionInfo ? view.selectionInfo.kind : "—"
                        color: view.theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Label { text: "Size"; color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: view.selectionInfo
                              ? view.theme.formatBytes(view.selectionInfo.size) : "—"
                        color: view.theme.text
                    }

                    Label { text: "Dimensions"; color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: (view.selectionInfo && view.selectionInfo.width)
                              ? (view.selectionInfo.width + " × " + view.selectionInfo.height)
                              : "—"
                        color: view.theme.text
                    }

                    Label { text: "Modified"; color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: view.selectionInfo
                              ? view.theme.formatDate(view.selectionInfo.modified) : "—"
                        color: view.theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                Label {
                    text: "Path"
                    color: view.theme.textMuted
                    font.pixelSize: 12
                }
                Label {
                    Layout.fillWidth: true
                    text: view.selectionInfo ? view.selectionInfo.path : "—"
                    color: view.theme.text
                    font.pixelSize: 11
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 4
                    elide: Text.ElideRight
                }

                Item { Layout.fillHeight: true }
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
                    view.expandedPaths[path] = true;
                    delete view.collapsedPaths[path];
                    load();
                }
            }

            function load() {
                if (!nodePath) return;
                var response = view.listFolders(nodePath);
                children = (response && response.ok) ? response.folders : [];
            }

            /// Click or double-click: expand the node and show that folder in
            /// the grid. This navigates — it never re-roots the tree, which only
            /// quick access and "Open folder" do.
            function activate() {
                if (!nodePath) return;
                expand();
                view.command({ type: "navigate", path: nodePath });
            }

            function expand() {
                if (!nodePath || expanded) return;
                expanded = true;
                view.expandedPaths[nodePath] = true;
                delete view.collapsedPaths[nodePath];
                load();
            }

            function collapse() {
                if (!nodePath || !expanded) return;
                expanded = false;
                delete view.expandedPaths[nodePath];
                // Remember the collapse so auto-reveal does not undo it.
                view.collapsedPaths[nodePath] = true;
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
                if (!nodePath || view.collapsedPaths[nodePath]) return;
                var current = view.state.currentFolder || "";
                if (!current) return;
                if (current !== nodePath && current.indexOf(nodePath + "/") !== 0) return;
                expand();
            }

            /// Restore the expansion recorded before the tree was rebuilt.
            function restoreExpansion() {
                if (!nodePath) return;
                if (view.expandedPaths[nodePath] === true) expand();
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
                objectName: "folderTreeRow"
                width: node.width
                height: 30
                radius: 4
                color: node.nodePath === (view.state.currentFolder || "")
                       ? view.theme.selection
                       : (nodeHover.hovered ? view.theme.hover : "transparent")

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
                        onClicked: node.toggleExpanded()
                    }

                    Icon {
                        iconName: "folder-symbolic"
                        iconSize: 15
                        iconColor: view.theme.textMuted
                    }

                    Label {
                        text: node.nodeName
                        color: view.theme.text
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
                    onSingleTapped: view.openFolderMenu(node.nodePath)
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
                target: view
                function onStateChanged() { node.followCurrent() }
            }
        }
    }

    // ------------------------------------------------------------ context menus
    Menu {
        id: fileMenu

        MenuItem {
            text: "Open"
            icon.name: "document-open-symbolic"
            onTriggered: {
                if (view.menuIsDir) {
                    view.command({ type: "open_folder", path: view.menuPath });
                } else if (view.menuIsImage) {
                    view.command({ type: "open_file", paths: [view.menuPath] });
                } else {
                    view.openExternal(view.menuPath);
                }
            }
        }
        MenuItem {
            text: "Edit"
            icon.name: "document-edit-symbolic"
            enabled: !view.menuIsDir
            onTriggered: {
                view.command({ type: "select", paths: [view.menuPath] });
                view.command({ type: "set_workspace", workspace: "editor" });
            }
        }
        MenuItem {
            text: "Open with system application"
            icon.name: "application-x-executable-symbolic"
            onTriggered: view.openExternal(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: "Copy image content"
            icon.name: "edit-copy-symbolic"
            enabled: view.menuIsImage
            onTriggered: view.copyImage(view.menuPath)
        }
        MenuItem {
            text: "Copy file path"
            icon.name: "edit-copy-symbolic"
            onTriggered: view.copyText(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: "Copy to…"
            icon.name: "folder-copy-symbolic"
            onTriggered: view.requestDestination("copy_to", [view.menuPath])
        }
        MenuItem {
            text: "Move to…"
            icon.name: "folder-move-symbolic"
            onTriggered: view.requestDestination("move_to", [view.menuPath])
        }
        MenuSeparator {}
        MenuItem {
            text: "Move to trash"
            icon.name: "user-trash-symbolic"
            onTriggered: view.command({ type: "trash", paths: [view.menuPath] })
        }
        MenuItem {
            text: "Delete permanently…"
            icon.name: "edit-delete-symbolic"
            onTriggered: view.requestDelete([view.menuPath])
        }
    }

    Menu {
        id: folderMenu

        MenuItem {
            text: "Open"
            icon.name: "folder-open-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuItem {
            text: "Explore here"
            icon.name: "folder-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuItem {
            text: "New folder…"
            icon.name: "folder-new-symbolic"
            onTriggered: view.promptNewFolder(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: "Copy path"
            icon.name: "edit-copy-symbolic"
            onTriggered: view.copyText(view.menuPath)
        }
        MenuItem {
            text: view.isFavorite(view.menuPath)
                  ? "Remove from quick access" : "Add to quick access"
            icon.name: view.isFavorite(view.menuPath) ? "starred-symbolic" : "non-starred-symbolic"
            onTriggered: {
                view.command(view.isFavorite(view.menuPath)
                             ? { type: "remove_favorite", path: view.menuPath }
                             : { type: "add_favorite", path: view.menuPath });
            }
        }
        MenuSeparator {}
        MenuItem {
            text: "Copy to…"
            icon.name: "folder-copy-symbolic"
            onTriggered: view.requestDestination("copy_to", [view.menuPath])
        }
        MenuItem {
            text: "Move to…"
            icon.name: "folder-move-symbolic"
            onTriggered: view.requestDestination("move_to", [view.menuPath])
        }
        MenuSeparator {}
        MenuItem {
            text: "Move to trash"
            icon.name: "user-trash-symbolic"
            onTriggered: view.command({ type: "trash", paths: [view.menuPath] })
        }
        MenuItem {
            text: "Delete permanently…"
            icon.name: "edit-delete-symbolic"
            onTriggered: view.requestDelete([view.menuPath])
        }
    }

    Menu {
        id: quickMenu

        MenuItem {
            text: "Open"
            icon.name: "folder-open-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuItem {
            text: "Explore here"
            icon.name: "folder-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuSeparator {}
        MenuItem {
            text: "Move up"
            icon.name: "go-up-symbolic"
            onTriggered: view.command({
                type: "move_favorite",
                path: view.menuPath,
                direction: "up"
            })
        }
        MenuItem {
            text: "Move down"
            icon.name: "go-down-symbolic"
            onTriggered: view.command({
                type: "move_favorite",
                path: view.menuPath,
                direction: "down"
            })
        }
        MenuSeparator {}
        MenuItem {
            text: "Remove from quick access"
            icon.name: "list-remove-symbolic"
            onTriggered: view.command({
                type: "remove_favorite",
                path: view.menuPath
            })
        }
    }

    Dialog {
        id: newFolderDialog
        title: "New folder"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        anchors.centerIn: Overlay.overlay
        width: 380

        onOpened: {
            nameField.text = "";
            nameField.forceActiveFocus();
        }
        onAccepted: {
            var name = nameField.text.trim();
            if (name.length > 0) {
                view.command({
                    type: "new_folder",
                    parent: view.newFolderParent,
                    name: name
                });
            }
        }

        contentItem: ColumnLayout {
            spacing: 8
            Label {
                text: "Folder name"
                color: view.theme.textMuted
            }
            TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: "New folder"
                onAccepted: newFolderDialog.accept()
            }
        }
    }

    // -------------------------------------------------------- workspace toolbar
    property Component toolbar: Component {
        RowLayout {
            spacing: 2

            ToolbarButton {
                theme: view.theme
                icon.name: "go-up-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.state.currentFolder
                ToolTip.visible: hovered
                ToolTip.text: "Go to parent folder"
                onClicked: view.goUp()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "view-refresh-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: "Refresh"
                onClicked: view.command({ type: "refresh" })
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "folder-new-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: "New folder"
                onClicked: view.promptNewFolder(view.state.currentFolder)
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                theme: view.theme
                checkable: true
                checked: !!view.state.leftPanel
                icon.name: "sidebar-show-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: "Toggle quick access and folder tree"
                onClicked: view.command({ type: "toggle_left_panel" })
            }
            ToolbarButton {
                theme: view.theme
                checkable: true
                checked: !!view.state.rightPanel
                icon.name: "sidebar-show-right-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: "Toggle preview and metadata panel"
                onClicked: view.command({ type: "toggle_right_panel" })
            }
        }
    }
}
