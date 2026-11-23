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
    /// Pixels each of `Theme.menuShortcutLabels` needs — the key column a menu
    /// names at its right edge. Measured by the shell for the same reason as
    /// `menuLabelWidths`.
    property var menuShortcutWidths: []
    property real menuWidth: theme.menuWidth(menuLabelWidths, menuShortcutWidths)
    /// True while the window is below the full icon row (`Main.qml`): the
    /// toolbar keeps navigation and folds the rest into `browserOverflowMenu`.
    property bool miniToolbar: false
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
    /// The Batch page asked for its form. The shell owns the dialog because it
    /// is modal for the whole window; `mode` is `resize`, `crop` or `convert`.
    signal requestBatch(string mode)
    /// Ask the shell to select the file in the desktop's file manager (`Show
    /// in folder`). The platform layer owns the FileManager1/portal choice, so
    /// the view only names the path.
    signal revealPath(string path)
    /// The user changed the layout: a splitter, the open reference tab or a
    /// panel. The shell keeps one copy for the three workspaces and sends it to
    /// Core as a `set_layout`, so a width or a tab survives the next launch.
    signal layoutRequested(var patch)

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
    /// The cell a Shift-click or Shift-arrow range grows from. A plain click
    /// and a Ctrl-click move it; a range never does, so the anchor stays put
    /// while the other end moves.
    property int selectionAnchor: -1

    /// The saved layout: which panels this workspace shows, the two dock
    /// widths and the Editor's split. The shell owns one copy for the three
    /// workspaces, because a width dragged in the Browser is the width the
    /// Editor opens at. A view reports an interaction with `layoutRequested`;
    /// it never writes the layout itself.
    property var layout: ({})
    readonly property var panels: view.layout.panels || ({})
    function panelShown(key) { return view.panels[key] !== false }
    readonly property bool quickAccessShown: view.panelShown("browser.quickAccess")
    readonly property bool explorerShown: view.panelShown("browser.explorer")
    /// The whole left dock is the sum of its panels: hiding every one hides the
    /// column, showing any one brings it back. There is no separate switch.
    readonly property bool leftDockShown: view.quickAccessShown || view.explorerShown

    // Sidebar widths. The saved layout is the source; a drag writes a local
    // value while the pointer is down and the shell sends the result in one
    // `set_layout` when it comes up, so a saved width comes back on the next
    // launch and a drag does not put a command in the journal per pixel.
    property real leftPanelWidth: view.layout.leftWidth || theme.panelWidth
    property bool leftDragging: false
    Binding {
        target: view
        property: "leftPanelWidth"
        value: view.layout.leftWidth || view.theme.panelWidth
        when: !view.leftDragging
        restoreMode: Binding.RestoreNone
    }
    property real rightPanelWidth: view.layout.rightWidth || theme.previewWidth
    property bool rightDragging: false
    Binding {
        target: view
        property: "rightPanelWidth"
        value: view.layout.rightWidth || view.theme.previewWidth
        when: !view.rightDragging
        restoreMode: Binding.RestoreNone
    }
    /// The shell keeps one width for all three workspaces; this view draws it
    /// within its own range, so a width dragged in the Editor cannot become a
    /// sliver here.
    readonly property real dockWidth: Math.max(200, Math.min(640, rightPanelWidth))

    property var selectionInfo: view.state.selectionInfo || null

    /// The Browser's sidebar pages. The page is presentation state, like the
    /// tab the Editor keeps open: hiding Batch action changes no file and sends
    /// no command. `Info` is not a tab: it sits under the preview because the
    /// two answer one question together. The burger menu's `View > Sidebar`
    /// submenu is the only place a panel is shown or hidden.
    property string rightPage: "preview"
    readonly property bool previewPanelVisible: view.panelShown("browser.preview")
    readonly property bool batchPanelVisible: view.panelShown("browser.batch")
    readonly property var rightPageEntries: [
        { key: "preview", label: qsTr("Preview"), icon: "icons/preview.svg",
          shown: view.previewPanelVisible },
        { key: "batch", label: qsTr("Batch action"), icon: "icons/batch.svg",
          shown: view.batchPanelVisible }
    ]
    /// The whole sidebar is the sum of its panels: hiding every one hides the
    /// column, showing any one brings it back. There is no separate switch.
    readonly property int visiblePanelCount:
        (view.previewPanelVisible ? 1 : 0) + (view.batchPanelVisible ? 1 : 0)
    readonly property bool sidebarShown: view.visiblePanelCount > 0
    /// How many of the selected paths are images. The batch page counts what it
    /// could act on, not a folder that happens to be selected beside them.
    readonly property int selectedImages: {
        var selection = view.state.selection || []
        var entries = view.entries || []
        var count = 0
        for (var index = 0; index < selection.length; ++index) {
            for (var entry = 0; entry < entries.length; ++entry) {
                if (entries[entry].path === selection[index]) {
                    if (entries[entry].isImage) ++count
                    break
                }
            }
        }
        return count
    }
    /// The selected paths that are images, in the order the selection names
    /// them. The batch form sends exactly these: Core would filter the rest,
    /// but the count on the form must match the count the job reports.
    readonly property var selectedImagePaths: {
        var selection = view.state.selection || []
        var entries = view.entries || []
        var paths = []
        for (var index = 0; index < selection.length; ++index) {
            for (var entry = 0; entry < entries.length; ++entry) {
                if (entries[entry].path === selection[index]) {
                    if (entries[entry].isImage) paths.push(entries[entry].path)
                    break
                }
            }
        }
        return paths
    }
    /// The first image a batch would process, so its form opens on a real
    /// picture's shape. The selection wins; an empty one falls back to the
    /// folder's first image.
    readonly property var batchSample: {
        var selection = view.state.selection || []
        var entries = view.entries || []
        for (var index = 0; index < selection.length; ++index) {
            for (var entry = 0; entry < entries.length; ++entry) {
                if (entries[entry].path === selection[index] && entries[entry].isImage) {
                    return entries[entry]
                }
            }
        }
        for (var fallback = 0; fallback < entries.length; ++fallback) {
            if (entries[fallback].isImage) return entries[fallback]
        }
        return null
    }
    /// Show the Batch page: a job just started there, and its progress is the
    /// answer the form promised — and the page names the three tools a form
    /// belongs to. A layout that hides the panel would show neither, so the
    /// page asks for the panel as well.
    function showBatchPage() {
        if (!view.batchPanelVisible) {
            view.setPanelVisible("batch", true)
            return
        }
        view.rightPage = "batch"
    }
    /// Settings' Appearance tab toggled one of this workspace's panels. The
    /// layout is Core's, so the view reports which key changed; opening a page
    /// that was just shown is the one piece of presentation state that follows.
    function setPanelVisible(key, visible) {
        var layoutKey = "browser." + key
        if (key !== "preview" && key !== "batch"
            && key !== "quickAccess" && key !== "explorer") return
        var patch = {}
        patch.panels = {}
        patch.panels[layoutKey] = visible
        view.layoutRequested(patch)
        if (key === "preview" || key === "batch") {
            if (visible) {
                view.rightPage = key
            } else if (view.rightPage === key) {
                // Name the page that is still there, not the one just hidden.
                var other = key === "preview" ? "batch" : "preview"
                if (view.panelShown("browser." + other)) view.rightPage = other
            }
        }
    }

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
        view.selectionAnchor = index;
        grid.currentIndex = index;
        grid.positionViewAtIndex(index, GridView.Contain);
        var selection = view.state.selection || [];
        if (selection.length === 1 && selection[0] === list[index].path) return;
        view.command({ type: "select", paths: [list[index].path] });
    }

    /// A click on one cell. A plain click selects exactly that cell; Ctrl
    /// toggles it and leaves the rest of the selection alone; Shift selects the
    /// range from the anchor to this cell. The modifiers come from the click
    /// itself, so the same gesture works whether the window's last key was a
    /// Ctrl or not.
    function clickIndex(index, modifiers) {
        var list = view.entries || [];
        if (index < 0 || index >= list.length || !list[index]) return;
        var path = list[index].path;
        var selection = (view.state.selection || []).slice();
        if ((modifiers & Qt.ShiftModifier) !== 0) {
            view.extendSelectionTo(index);
            return;
        }
        view.keyboardCursor = index;
        view.selectionAnchor = index;
        grid.currentIndex = index;
        if ((modifiers & Qt.ControlModifier) !== 0) {
            var at = selection.indexOf(path);
            if (at >= 0) {
                selection.splice(at, 1);
            } else {
                selection.push(path);
            }
            view.command({ type: "select", paths: selection });
            return;
        }
        grid.positionViewAtIndex(index, GridView.Contain);
        if (selection.length === 1 && selection[0] === path) return;
        view.command({ type: "select", paths: [path] });
    }

    /// The cell a Shift+arrow grows or shrinks from: the keyboard cursor when
    /// one is set, otherwise the first selected entry. The anchor is the other
    /// end and stays put.
    function rangeCursor() {
        var count = (view.entries || []).length;
        if (view.keyboardCursor >= 0 && view.keyboardCursor < count) {
            return view.keyboardCursor;
        }
        return view.currentIndex();
    }

    /// Select the range from the anchor to `index`, inclusive. The anchor is    /// the cell the range grows from; when there is none yet, the range starts
    /// where the keyboard cursor is (or at `index` itself).
    function extendSelectionTo(index) {
        var list = view.entries || [];
        if (list.length === 0) return;
        index = Math.max(0, Math.min(list.length - 1, index));
        if (view.selectionAnchor < 0) {
            view.selectionAnchor = view.currentIndex();
        }
        var anchor = view.selectionAnchor < 0 ? index : view.selectionAnchor;
        var start = Math.min(anchor, index);
        var end = Math.max(anchor, index);
        var paths = [];
        for (var step = start; step <= end; ++step) {
            if (list[step]) paths.push(list[step].path);
        }
        view.keyboardCursor = index;
        grid.currentIndex = index;
        grid.positionViewAtIndex(index, GridView.Contain);
        view.command({ type: "select", paths: paths });
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
        view.selectionAnchor = 0;
        view.command({ type: "select", paths: paths });
    }

    function clearSelection() {
        view.selectionAnchor = -1;
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
        // Shift extends the selection from the anchor instead of moving it.
        // The anchor is where the last plain click (or arrow) landed, so a
        // range can grow and shrink without losing its other end.
        if ((event.modifiers & Qt.ShiftModifier) !== 0) {
            var cursor = view.rangeCursor();
            if (cursor < 0) return;
            switch (event.key) {
            case Qt.Key_Left:
                view.extendSelectionTo(cursor - 1);
                event.accepted = true;
                break;
            case Qt.Key_Right:
                view.extendSelectionTo(cursor + 1);
                event.accepted = true;
                break;
            case Qt.Key_Up:
                view.extendSelectionTo(cursor - view.gridColumns());
                event.accepted = true;
                break;
            case Qt.Key_Down:
                view.extendSelectionTo(cursor + view.gridColumns());
                event.accepted = true;
                break;
            case Qt.Key_Home:
                view.extendSelectionTo(0);
                event.accepted = true;
                break;
            case Qt.Key_End:
                view.extendSelectionTo((view.entries || []).length - 1);
                event.accepted = true;
                break;
            default:
                break;
            }
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

        // ------------------------------------------------------- left dock
        // Quick access and Explorer are two panels of one column, shared with
        // the Viewer and the Editor. Which are on is the saved layout's answer;
        // the column itself is shown while at least one of them is.
        LeftDock {
            objectName: "leftPanel"
            visible: view.leftDockShown
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            theme: view.theme
            state: view.state
            quickAccessShown: view.quickAccessShown
            explorerShown: view.explorerShown
            listFolders: view.listFolders
            onOpenFolder: function(path) { view.command({ type: "open_folder", path: path }) }
            onNavigateTo: function(path) { view.command({ type: "navigate", path: path }) }
            onOpenMenu: function(path) { view.openFolderMenu(path) }
            onQuickMenu: function(path) { view.openQuickMenu(path) }
        }

        PanelSplitter {
            objectName: "leftSplitter"
            visible: view.leftDockShown
            Layout.fillHeight: true
            theme: view.theme
            value: view.leftPanelWidth
            defaultValue: view.theme.panelWidth
            direction: 1
            minimum: 180
            maximum: 560
            onMoved: function(width) {
                view.leftDragging = true
                view.leftPanelWidth = width
            }
            onReleased: function(width) {
                view.leftDragging = false
                view.layoutRequested({ leftWidth: Math.round(width) })
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

                    // A MouseArea rather than a TapHandler because the
                    // modifiers of the click are what decide between "this
                    // one", "add this one" and "the range to here" — and a
                    // TapHandler's point carries no modifiers.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onClicked: function(mouse) { view.clickIndex(index, mouse.modifiers) }
                        onDoubleClicked: view.openEntry(entry)
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onSingleTapped: {
                            // Right-clicking inside a multi-selection keeps it:
                            // the menu then acts on everything the user chose.
                            var selection = view.state.selection || [];
                            if (selection.indexOf(entry.path) < 0) {
                                view.selectionAnchor = index;
                                view.command({ type: "select", paths: [entry.path] });
                            }
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
            visible: view.sidebarShown
            Layout.fillHeight: true
            theme: view.theme
            value: view.rightPanelWidth
            defaultValue: view.theme.previewWidth
            direction: -1
            minimum: 200
            maximum: 640
            onMoved: function(width) {
                view.rightDragging = true
                view.rightPanelWidth = width
            }
            onReleased: function(width) {
                view.rightDragging = false
                view.layoutRequested({ rightWidth: Math.round(width) })
            }
        }

        // --------------------------------------------------- right sidebar
        // Two pages: the picture and the file's details are read together, so
        // they share the Preview page; Batch action is the selection as a
        // question of its own. The dock is shared with the Viewer and the
        // Editor (`RightDock.qml`), and its width is the shell's one value for
        // all three workspaces. The burger menu's `View > Sidebar` submenu is
        // where either page is hidden or brought back.
        RightDock {
            objectName: "rightPanel"
            visible: view.sidebarShown
            Layout.preferredWidth: view.dockWidth
            Layout.fillHeight: true
            theme: view.theme
            backgroundColor: view.theme.sidebar
            tabs: view.rightPageEntries
            currentKey: view.rightPage
            compact: view.dockWidth < 240
            stripObjectName: "browserRightTabs"
            tabKeyPrefix: "browserTab"
            pagesObjectName: "browserRightPages"
            onActivated: function(key) { view.rightPage = key }

            ScrollView {
                id: browserInfoPage
                objectName: "browserPreviewPage"
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    width: browserInfoPage.availableWidth
                    spacing: 12

                    PreviewPanel {
                        Layout.fillWidth: true
                        theme: view.theme
                        book: thumbs
                        path: view.selectionInfo ? view.selectionInfo.path : ""
                        thumbnailable: !!(view.selectionInfo && view.selectionInfo.isImage)
                        modified: view.selectionInfo ? view.selectionInfo.modified : 0
                        fileSize: view.selectionInfo ? view.selectionInfo.size : 0
                        heading: qsTr("Preview")
                        placeholder: view.selectionInfo ? qsTr("No image preview")
                                                     : qsTr("Nothing selected")
                        captionObjectName: "previewCaption"
                        thumbnailObjectName: "previewThumbnail"
                    }

                    InfoPanel {
                        Layout.fillWidth: true
                        theme: view.theme
                        info: view.selectionInfo
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            ScrollView {
                id: browserBatchPage
                objectName: "browserBatchPage"
                contentWidth: availableWidth
                clip: true

                BatchPanel {
                    width: browserBatchPage.availableWidth
                    theme: view.theme
                    selectionCount: view.selectedImages
                    batch: view.state.batch || null
                    onRequestResize: view.requestBatch("resize")
                    onRequestCrop: view.requestBatch("crop")
                    onRequestConvert: view.requestBatch("convert")
                    onRequestCancel: view.command({ type: "cancel_operation" })
                }
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
        MenuItem {
            text: view.theme.menuEntries[38]
            icon.name: "folder-documents-symbolic"
            onTriggered: view.revealPath(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy image content")
            icon.name: "edit-copy-symbolic"
            enabled: view.menuIsImage
            onTriggered: view.copyImage(view.menuPath)
            MenuShortcut { text: "Ctrl+Shift+C" }
        }
        MenuItem {
            text: qsTr("Copy file path")
            icon.name: "edit-copy-symbolic"
            onTriggered: view.copyText(view.menuPath)
            MenuShortcut { text: "Ctrl+Alt+C" }
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
            text: qsTr("New folder…")
            icon.name: "folder-new-symbolic"
            onTriggered: view.promptNewFolder(view.menuPath)
        }
        MenuItem {
            text: view.theme.menuEntries[38]
            icon.name: "folder-documents-symbolic"
            onTriggered: view.revealPath(view.menuPath)
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy path")
            icon.name: "edit-copy-symbolic"
            onTriggered: view.copyText(view.menuPath)
            MenuShortcut { text: "Ctrl+Alt+C" }
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
            text: view.theme.menuEntries[38]
            icon.name: "folder-documents-symbolic"
            onTriggered: view.revealPath(view.menuPath)
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

    /// The actions the mini toolbar cannot show. Same actions, labels and keys
    /// as the toolbar buttons it replaces; see `Viewer.qml` for why the labels
    /// come from `Theme.menuEntries`.
    Menu {
        id: browserOverflow
        objectName: "browserOverflowMenu"
        implicitWidth: view.menuWidth

        MenuItem {
            text: view.theme.menuEntries[9]
            icon.name: "folder-new-symbolic"
            onTriggered: view.promptNewFolder(view.state.currentFolder)
        }
    }

    DialogFrame {
        id: newFolderDialog
        objectName: "newFolderDialog"
        namePrefix: "newFolder"
        title: qsTr("New folder")
        preferredWidth: 380

        /// An empty name is not a folder: Create stays disabled until there is
        /// something to name.
        function create() {
            var name = nameField.text.trim();
            if (name.length === 0) return;
            view.command({
                type: "new_folder",
                parent: view.newFolderParent,
                name: name
            });
            newFolderDialog.close();
        }

        /// Every open starts on an empty field with the keyboard in it.
        function prepare() {
            nameField.text = "";
            nameField.forceActiveFocus();
        }

        FormRow {
            theme: view.theme
            label: qsTr("Folder name")
            labelWidth: newFolderDialog.labelWidth
            Layout.fillWidth: true

            TextField {
                id: nameField
                objectName: "newFolderName"
                Layout.fillWidth: true
                placeholderText: qsTr("New folder")
                onAccepted: newFolderDialog.create()
            }
        }

        footer: DialogFooter {
            namePrefix: "newFolder"
            theme: view.theme
            height: newFolderDialog.footerHeight

            Item { Layout.fillWidth: true }
            PanelAction {
                objectName: "newFolderCancel"
                theme: view.theme
                text: qsTr("Cancel")
                implicitWidth: 88
                onClicked: newFolderDialog.close()
            }
            PanelAction {
                objectName: "newFolderCreate"
                theme: view.theme
                text: qsTr("Create")
                implicitWidth: 88
                primary: true
                enabled: nameField.text.trim().length > 0
                onClicked: newFolderDialog.create()
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
                ToolTip.text: qsTr("Go to parent folder (Backspace)")
                onClicked: view.goUp()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "view-refresh-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Refresh (F5)")
                onClicked: view.command({ type: "refresh" })
            }
            ToolbarButton {
                theme: view.theme
                objectName: "openFolderButton"
                icon.name: "folder-open-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Open folder… (Ctrl+Shift+O)")
                // The dialog lives in the shell, like "Open folder" in the menu,
                // and the chosen folder re-roots the tree (open_folder).
                onClicked: view.requestOpenFolder()
            }
            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "folder-new-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("New folder")
                onClicked: view.promptNewFolder(view.state.currentFolder)
            }
            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }
            ToolbarButton {
                objectName: "browserOverflowButton"
                theme: view.theme
                visible: view.miniToolbar
                icon.name: "view-more-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("More browser actions")
                onClicked: browserOverflow.popup(this)
            }
        }
    }
}
