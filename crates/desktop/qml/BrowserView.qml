import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: view

    property Theme theme: Theme {}
    /// Pixel widths of `Theme.menuEntryLabels` and the menu width they imply.
    /// The shell measures them in C++ (`Platform.textWidths`) and hands them in,
    /// because this view can run with a `Theme` of its own — in the test harness
    /// — that the shell never touches.
    property var menuLabelWidths: []
    property real menuWidth: theme.menuWidth(menuLabelWidths)
    property var state: ({})
    /// The folder listing, published apart from `state` so that an unchanged
    /// listing keeps the same array (and the grid keeps its delegates).
    property var entries: []
    /// The `Thumbnails` context object (C++ `ThumbnailCache`). Null in the QML
    /// test harness, where the views decode the originals as before.
    property var thumbnails: null
    property var listFolders: function(path) { return { ok: false, folders: [] }; }

    signal command(var command)
    signal toast(string message)
    signal copyImage(string path)
    signal copyText(string text)
    signal openExternal(string path)
    /// Show the desktop's "Open With" chooser for the file.
    signal openWith(string path)
    /// Open `path` in the Editor from the current state: the shell batches
    /// `select` + `set_workspace` + `editor_open` so none is dropped.
    signal editInEditor(string path)
    signal requestDestination(string action, var paths)
    signal requestDelete(var paths)
    /// "Open folder": the shell owns the dialog, so the view only asks for it.
    signal requestOpenFolder()

    property string menuPath: ""
    property bool menuIsImage: false
    property bool menuIsDir: false
    property string newFolderParent: ""

    /// Keyboard ownership, as in the Viewer: the Browser view holds focus while
    /// its workspace is up, and its buttons refuse focus, so the arrows below
    /// move the grid instead of a toolbar.
    focus: true
    /// Where the keyboard cursor rests. Core owns `selection`; this only
    /// remembers the cell the next arrow starts from, because a selection that
    /// left the folder (or an empty one) has no index to walk from.
    property int keyboardCursor: -1

    // Sidebar widths. Seeded from the theme, then owned by the drag handles so
    // both panels are resizable; nothing is persisted yet.
    property real leftPanelWidth: theme.panelWidth
    property real rightPanelWidth: theme.previewWidth

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
        if (path === view.state.home) return qsTr("Home");
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

    // ------------------------------------------------------------- keyboard
    //
    // The grid is driven like any file manager: arrows move one cell or row,
    // PageUp/PageDown move a screenful, Home/End jump to the ends, Enter opens
    // the cell (folder -> navigate, image -> Viewer), Backspace goes to the
    // parent, Ctrl+A selects the listing, Delete trashes the selection and
    // Escape clears it. Every key that changes selection or the folder emits
    // the same typed command a click does; nothing is mutated in QML.

    /// Index of `path` in the listing, or -1 when it left the folder.
    function indexOfPath(path) {
        var list = view.entries || [];
        for (var index = 0; index < list.length; ++index) {
            if (list[index] && list[index].path === path) return index;
        }
        return -1;
    }

    /// The cell the next key starts from: the first selected entry the grid
    /// still shows, then the remembered cursor, then the first cell.
    function currentIndex() {
        var selection = view.state.selection || [];
        for (var index = 0; index < selection.length; ++index) {
            var found = view.indexOfPath(selection[index]);
            if (found >= 0) return found;
        }
        var count = (view.entries || []).length;
        if (view.keyboardCursor >= 0 && view.keyboardCursor < count) {
            return view.keyboardCursor;
        }
        return count > 0 ? 0 : -1;
    }

    /// Move the keyboard cursor to `index` and select exactly that entry.
    /// `grid.currentIndex` and `positionViewAtIndex` make the movement visible
    /// before the next state snapshot arrives.
    function selectIndex(index) {
        var list = view.entries || [];
        if (list.length === 0) return;
        index = Math.max(0, Math.min(list.length - 1, index));
        view.keyboardCursor = index;
        grid.currentIndex = index;
        grid.positionViewAtIndex(index, GridView.Contain);
        var selection = view.state.selection || [];
        if (selection.length === 1 && selection[0] === list[index].path) return;
        view.command({ type: "select", paths: [list[index].path] });
    }

    /// How many cells fit in a row, so Up/Down move by a real row.
    function gridColumns() {
        return Math.max(1, Math.floor(grid.width / Math.max(1, grid.cellWidth)));
    }

    function gridPageRows() {
        return Math.max(1, Math.floor(grid.height / Math.max(1, grid.cellHeight)));
    }

    function moveCursor(delta) {
        var index = view.currentIndex();
        if (index < 0) return;
        // The first arrow out of an empty selection lands on the first cell
        // instead of skipping it, which is what a file manager does.
        if ((view.state.selection || []).length === 0 && view.keyboardCursor < 0) {
            view.selectIndex(index);
            return;
        }
        view.selectIndex(index + delta);
    }

    function moveCursorRows(rows) {
        view.moveCursor(rows * view.gridColumns());
    }

    function openCursor() {
        var list = view.entries || [];
        var index = view.currentIndex();
        if (index >= 0 && list[index]) view.openEntry(list[index]);
    }

    function selectAllEntries() {
        var list = view.entries || [];
        if (list.length === 0) return;
        var paths = [];
        for (var index = 0; index < list.length; ++index) {
            if (list[index]) paths.push(list[index].path);
        }
        view.keyboardCursor = view.currentIndex();
        view.command({ type: "select", paths: paths });
    }

    function clearSelection() {
        if ((view.state.selection || []).length > 0) {
            view.command({ type: "select", paths: [] });
        }
    }

    /// Trash what is selected, or the cell under the keyboard cursor when the
    /// selection has left the folder. Trash is recoverable, so — like the file
    /// menu's "Move to trash" — it does not ask first; permanent delete keeps
    /// its confirmation dialog.
    function trashSelection() {
        var list = view.entries || [];
        var selection = view.state.selection || [];
        var paths = [];
        for (var index = 0; index < selection.length; ++index) {
            if (view.indexOfPath(selection[index]) >= 0) paths.push(selection[index]);
        }
        if (paths.length === 0) {
            var cursor = view.currentIndex();
            if (cursor >= 0 && list[cursor]) paths.push(list[cursor].path);
        }
        if (paths.length > 0) {
            view.command({ type: "trash", paths: paths });
        }
    }

    Keys.onPressed: function(event) {
        if ((event.modifiers & Qt.AltModifier) !== 0) {
            return;
        }
        if ((event.modifiers & Qt.ControlModifier) !== 0) {
            // Ctrl+A is the one modified key the grid owns; every other Ctrl
            // combination belongs to the shell's window shortcuts.
            if (event.key === Qt.Key_A) {
                view.selectAllEntries();
                event.accepted = true;
            }
            return;
        }
        switch (event.key) {
        case Qt.Key_Left:
            view.moveCursor(-1);
            event.accepted = true;
            break;
        case Qt.Key_Right:
            view.moveCursor(1);
            event.accepted = true;
            break;
        case Qt.Key_Up:
            view.moveCursorRows(-1);
            event.accepted = true;
            break;
        case Qt.Key_Down:
            view.moveCursorRows(1);
            event.accepted = true;
            break;
        case Qt.Key_PageUp:
            view.moveCursorRows(-view.gridPageRows());
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            view.moveCursorRows(view.gridPageRows());
            event.accepted = true;
            break;
        case Qt.Key_Home:
            view.selectIndex(0);
            event.accepted = true;
            break;
        case Qt.Key_End:
            view.selectIndex((view.entries || []).length - 1);
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            view.openCursor();
            event.accepted = true;
            break;
        case Qt.Key_Backspace:
            view.goUp();
            event.accepted = true;
            break;
        case Qt.Key_Escape:
            view.clearSelection();
            event.accepted = true;
            break;
        case Qt.Key_Delete:
            // Holding the key must not walk the folder into the trash: one
            // press, one command. The repeat arrives as the same key with
            // `isAutoRepeat` set.
            if (!event.isAutoRepeat) {
                view.trashSelection();
                event.accepted = true;
            }
            break;
        default:
            break;
        }
    }

    Component.onCompleted: view.forceActiveFocus()

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

    // Shared thumbnail bookkeeping for the grid and the preview panel. The
    // decoding itself belongs to C++; this only maps (path, size, mtime, edge)
    // to a cached file url.
    ThumbnailBook {
        id: thumbs
        cache: view.thumbnails
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------- left sidebar
        Rectangle {
            objectName: "leftPanel"
            visible: !!view.state.leftPanel
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            border.width: 1
            border.color: view.theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Label {
                    text: qsTr("Quick access")
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
                    /// Three 32 px rows per notch.
                    WheelScroll {
                        view: quickList
                        step: 96
                    }

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
                                text: qsTr("★")
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
                    text: qsTr("Folders")
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
                    /// Five 24 px rows per notch, like a tree in any other file
                    /// manager — Qt's own 72 px is three.
                    WheelScroll {
                        view: treeScroll
                        step: 120
                    }

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

        PanelSplitter {
            objectName: "leftSplitter"
            visible: !!view.state.leftPanel
            Layout.fillHeight: true
            theme: view.theme
            value: view.leftPanelWidth
            defaultValue: view.theme.panelWidth
            direction: 1
            minimum: 180
            maximum: 560
            onMoved: function(width) { view.leftPanelWidth = width }
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
                        text: qsTr("›")
                        color: view.theme.textMuted
                    }

                    ToolButton {
                        visible: crumbBar.hiddenCrumbs.length > 0
                        text: qsTr("…")
                        implicitWidth: 28
                        implicitHeight: 28
                        focusPolicy: Qt.NoFocus
                        activeFocusOnTab: false
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Hidden parent folders")
                        onClicked: hiddenMenu.popup()
                    }

                    Label {
                        visible: crumbBar.hiddenCrumbs.length > 0
                        text: qsTr("›")
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
                                text: qsTr("›")
                                color: view.theme.textMuted
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Label {
                        visible: !!view.state.busy
                        text: qsTr("Loading…")
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
                model: view.entries || []
                cellWidth: Math.max(132, Math.floor(width / Math.max(1, Math.floor(width / 178))))
                cellHeight: Math.round(cellWidth * 0.78) + 32
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                /// A notch moves exactly one row of cells, so the wheel keeps
                /// the grid under the pointer instead of crawling by 72 px.
                WheelScroll {
                    view: grid
                    step: grid.cellHeight
                }

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

                            CachedThumbnail {
                                id: thumbImage
                                objectName: "gridThumbnail"
                                anchors.fill: parent
                                anchors.margins: 2
                                book: thumbs
                                path: cell.entry.path
                                /// The size bucket is the cache key's size
                                /// component: one per tile shape, not one per
                                /// pixel width.
                                thumbnailable: cell.entry.isImage
                                modified: cell.entry.modified
                                fileSize: cell.entry.size
                                asynchronous: true
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
                      ? qsTr("This folder has no visible images or subfolders.")
                      : qsTr("Open a folder to start browsing your photos.")
                color: view.theme.textMuted
            }
        }

        PanelSplitter {
            objectName: "rightSplitter"
            visible: !!view.state.rightPanel
            Layout.fillHeight: true
            theme: view.theme
            value: view.rightPanelWidth
            defaultValue: view.theme.previewWidth
            direction: -1
            minimum: 200
            maximum: 640
            onMoved: function(width) { view.rightPanelWidth = width }
        }

        // --------------------------------------------------- right sidebar
        Rectangle {
            objectName: "rightPanel"
            visible: !!view.state.rightPanel
            Layout.preferredWidth: view.rightPanelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            border.width: 1
            border.color: view.theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                Label {
                    text: qsTr("Preview")
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

                    CachedThumbnail {
                        id: previewImage
                        objectName: "previewThumbnail"
                        anchors.fill: parent
                        anchors.margins: 4
                        readonly property var info: view.selectionInfo
                        book: thumbs
                        path: info ? info.path : ""
                        thumbnailable: !!(info && info.isImage)
                        modified: info ? info.modified : 0
                        fileSize: info ? info.size : 0
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: Math.ceil(width * 2)
                        sourceSize.height: Math.ceil(height * 2)
                    }

                    Label {
                        anchors.centerIn: parent
                        visible: !view.selectionInfo || !view.selectionInfo.isImage
                        text: view.selectionInfo ? qsTr("No image preview") : qsTr("Nothing selected")
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

                    Label { text: qsTr("Type"); color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: view.selectionInfo ? view.selectionInfo.kind : "—"
                        color: view.theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Label { text: qsTr("Size"); color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: view.selectionInfo
                              ? view.theme.formatBytes(view.selectionInfo.size) : "—"
                        color: view.theme.text
                    }

                    Label { text: qsTr("Dimensions"); color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: (view.selectionInfo && view.selectionInfo.width)
                              ? (view.selectionInfo.width + " × " + view.selectionInfo.height)
                              : "—"
                        color: view.theme.text
                    }

                    Label { text: qsTr("Modified"); color: view.theme.textMuted; font.pixelSize: 12 }
                    Label {
                        text: view.selectionInfo
                              ? view.theme.formatDate(view.selectionInfo.modified) : "—"
                        color: view.theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                Label {
                    text: qsTr("Path")
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
                        focusPolicy: Qt.NoFocus
                        activeFocusOnTab: false
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
        objectName: "fileMenu"
        implicitWidth: view.menuWidth

        MenuItem {
            text: qsTr("Open")
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
            text: qsTr("Edit")
            icon.name: "document-edit-symbolic"
            enabled: !view.menuIsDir
            onTriggered: {
                // One batch: dispatching them back to back from this handler
                // dropped `editor_open` (see `Main.sendSequence`).
                view.editInEditor(view.menuPath);
            }
        }
        MenuItem {
            text: qsTr("Open with…")
            icon.name: "application-x-executable-symbolic"
            onTriggered: view.openWith(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy image content")
            icon.name: "edit-copy-symbolic"
            enabled: view.menuIsImage
            onTriggered: view.copyImage(view.menuPath)
        }
        MenuItem {
            text: qsTr("Copy file path")
            icon.name: "edit-copy-symbolic"
            onTriggered: view.copyText(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy to…")
            icon.name: "folder-copy-symbolic"
            onTriggered: view.requestDestination("copy_to", [view.menuPath])
        }
        MenuItem {
            text: qsTr("Move to…")
            icon.name: "folder-move-symbolic"
            onTriggered: view.requestDestination("move_to", [view.menuPath])
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Move to trash")
            icon.name: "user-trash-symbolic"
            onTriggered: view.command({ type: "trash", paths: [view.menuPath] })
        }
        MenuItem {
            text: qsTr("Delete permanently…")
            icon.name: "edit-delete-symbolic"
            onTriggered: view.requestDelete([view.menuPath])
        }
    }

    Menu {
        id: folderMenu
        objectName: "folderMenu"
        implicitWidth: view.menuWidth

        MenuItem {
            text: qsTr("Open")
            icon.name: "folder-open-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuItem {
            text: qsTr("Explore here")
            icon.name: "folder-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuItem {
            text: qsTr("New folder…")
            icon.name: "folder-new-symbolic"
            onTriggered: view.promptNewFolder(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy path")
            icon.name: "edit-copy-symbolic"
            onTriggered: view.copyText(view.menuPath)
        }
        MenuItem {
            text: view.isFavorite(view.menuPath)
                  ? qsTr("Remove from quick access") : qsTr("Add to quick access")
            icon.name: view.isFavorite(view.menuPath) ? "starred-symbolic" : "non-starred-symbolic"
            onTriggered: {
                view.command(view.isFavorite(view.menuPath)
                             ? { type: "remove_favorite", path: view.menuPath }
                             : { type: "add_favorite", path: view.menuPath });
            }
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy to…")
            icon.name: "folder-copy-symbolic"
            onTriggered: view.requestDestination("copy_to", [view.menuPath])
        }
        MenuItem {
            text: qsTr("Move to…")
            icon.name: "folder-move-symbolic"
            onTriggered: view.requestDestination("move_to", [view.menuPath])
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Move to trash")
            icon.name: "user-trash-symbolic"
            onTriggered: view.command({ type: "trash", paths: [view.menuPath] })
        }
        MenuItem {
            text: qsTr("Delete permanently…")
            icon.name: "edit-delete-symbolic"
            onTriggered: view.requestDelete([view.menuPath])
        }
    }

    Menu {
        id: quickMenu
        objectName: "quickMenu"
        implicitWidth: view.menuWidth

        MenuItem {
            text: qsTr("Open")
            icon.name: "folder-open-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuItem {
            text: qsTr("Explore here")
            icon.name: "folder-symbolic"
            onTriggered: view.command({ type: "open_folder", path: view.menuPath })
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Move up")
            icon.name: "go-up-symbolic"
            onTriggered: view.command({
                type: "move_favorite",
                path: view.menuPath,
                direction: "up"
            })
        }
        MenuItem {
            text: qsTr("Move down")
            icon.name: "go-down-symbolic"
            onTriggered: view.command({
                type: "move_favorite",
                path: view.menuPath,
                direction: "down"
            })
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Remove from quick access")
            icon.name: "list-remove-symbolic"
            onTriggered: view.command({
                type: "remove_favorite",
                path: view.menuPath
            })
        }
    }

    Dialog {
        id: newFolderDialog
        title: qsTr("New folder")
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 380
        // Explicit buttons for the same reason as the settings dialog: Qt's own
        // "OK"/"Cancel" are the system's translations, and the app's own
        // catalogue travels with it.
        footer: DialogButtonBox {
            alignment: Qt.AlignRight
            Button {
                text: qsTr("Cancel")
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
                onClicked: newFolderDialog.reject()
            }
            Button {
                objectName: "newFolderCreate"
                text: qsTr("Create")
                highlighted: true
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
                onClicked: newFolderDialog.accept()
            }
        }

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
                text: qsTr("Folder name")
                color: view.theme.textMuted
            }
            TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: qsTr("New folder")
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
                ToolTip.text: qsTr("Go to parent folder")
                onClicked: view.goUp()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "view-refresh-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Refresh")
                onClicked: view.command({ type: "refresh" })
            }
            ToolbarButton {
                theme: view.theme
                objectName: "openFolderButton"
                icon.name: "folder-open-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Open folder…")
                // The dialog lives in the shell, like "Open folder" in the menu,
                // and the chosen folder re-roots the tree (open_folder).
                onClicked: view.requestOpenFolder()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "folder-new-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("New folder")
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
                ToolTip.text: qsTr("Toggle quick access and folder tree")
                onClicked: view.command({ type: "toggle_left_panel" })
            }
            ToolbarButton {
                theme: view.theme
                checkable: true
                checked: !!view.state.rightPanel
                icon.name: "sidebar-show-right-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Toggle preview and metadata panel")
                onClicked: view.command({ type: "toggle_right_panel" })
            }
        }
    }
}
