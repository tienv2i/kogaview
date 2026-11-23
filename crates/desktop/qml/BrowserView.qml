import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
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

    // ---------------------------------------------------------- view modes
    //
    // A folder can be shown three ways, as a file manager does it: large cells
    // with the picture decoded (`thumbnails`), small cells with the file type's
    // icon (`icons`), or one line per entry with its type, size and modification
    // time (`details`). The choice is a layout value (`browserView`), not a QML
    // variable, for the same reason a panel's visibility is: a file manager that
    // forgets how you asked to see a folder asks again every launch. The view
    // only reports the choice.
    readonly property var viewModes: ["thumbnails", "icons", "details"]
    readonly property string viewMode: {
        var saved = "" + (view.layout.browserView || "")
        return view.viewModes.indexOf(saved) >= 0 ? saved : "thumbnails"
    }
    readonly property bool detailsShown: view.viewMode === "details"
    /// The three switch buttons, in the order a file manager draws them.
    readonly property var viewModeEntries: [
        { key: "thumbnails", label: qsTr("Thumbnails"), icon: "icons/view-thumbnails.svg" },
        { key: "icons", label: qsTr("Icons"), icon: "icons/view-icons.svg" },
        { key: "details", label: qsTr("Details"), icon: "icons/view-details.svg" }
    ]
    function setViewMode(mode) {
        if (view.viewModes.indexOf(mode) < 0 || mode === view.viewMode) return
        view.layoutRequested({ browserView: mode })
    }

    // --------------------------------------------------------- sort & sizes
    readonly property var sortFields: ["name", "modified", "size", "kind"]
    readonly property string sortBy: {
        var saved = "" + (view.layout.browserSortBy || "")
        return view.sortFields.indexOf(saved) >= 0 ? saved : "name"
    }
    readonly property string sortOrder:
        view.layout.browserSortOrder === "desc" ? "desc" : "asc"
    readonly property var sortEntries: [
        { key: "name", label: qsTr("Name") },
        { key: "modified", label: qsTr("Modified") },
        { key: "size", label: qsTr("Size") },
        { key: "kind", label: qsTr("Type") }
    ]
    function sortLabel() {
        for (var i = 0; i < view.sortEntries.length; ++i) {
            if (view.sortEntries[i].key === view.sortBy) return view.sortEntries[i].label
        }
        return qsTr("Name")
    }
    function setSortField(field) {
        if (view.sortFields.indexOf(field) < 0) return
        if (field === view.sortBy) {
            view.layoutRequested({ browserSortOrder: view.sortOrder === "asc" ? "desc" : "asc" })
        } else {
            view.layoutRequested({ browserSortBy: field, browserSortOrder: "asc" })
        }
    }
    function setSortOrder(order) {
        if (order !== "asc" && order !== "desc") return
        if (order === view.sortOrder) return
        view.layoutRequested({ browserSortOrder: order })
    }

    // Five discrete thumbnail/item sizes: very small, small, medium, large, very large.
    readonly property var thumbSizes: ["xs", "s", "m", "l", "xl"]
    readonly property string thumbSize: {
        var saved = "" + (view.layout.browserThumbSize || "")
        return view.thumbSizes.indexOf(saved) >= 0 ? saved : "m"
    }
    readonly property int thumbSizeIndex: Math.max(0, view.thumbSizes.indexOf(view.thumbSize))
    readonly property var thumbSizeLabels: [
        qsTr("Very small"),
        qsTr("Small"),
        qsTr("Medium"),
        qsTr("Large"),
        qsTr("Very large")
    ]
    readonly property string thumbSizeLabel: view.thumbSizeLabels[view.thumbSizeIndex] || qsTr("Medium")
    function stepThumbSize(delta) {
        var next = Math.max(0, Math.min(view.thumbSizes.length - 1, view.thumbSizeIndex + delta))
        if (next === view.thumbSizeIndex) return
        view.layoutRequested({ browserThumbSize: view.thumbSizes[next] })
    }

    /// One line of the details list, scaled by `thumbSize`.
    readonly property int detailsRowHeight: [24, 27, 30, 36, 44][view.thumbSizeIndex] || 30
    /// The details columns that do not take the leftover width: type, size and
    /// modification time. The header and the rows read the same numbers, so the
    /// two cannot drift into a stair-step.
    readonly property int detailsTypeWidth: 116
    readonly property int detailsSizeWidth: 96
    readonly property int detailsModifiedWidth: 136
    /// The kind-of-file drawing that starts every row; the header leaves the
    /// same gap so its columns sit above the rows' own.
    readonly property int detailsIconWidth: [14, 15, 16, 20, 26][view.thumbSizeIndex] || 16

    /// How many entries the shape on screen is showing, for the empty-folder
    /// sentence: the grid counts cells, the details list counts lines.
    readonly property int listedCount: view.detailsShown ? fileList.count : grid.count

    /// The type column's words. A folder is a folder, a file is named by its
    /// extension — the same token Core's `kind` carries (`.jpg`) — and a name
    /// without one says so. Only the two words are translated: an extension is
    /// the same in every language.
    function entryKind(entry) {
        if (!entry) return "—"
        if (entry.isDir) return qsTr("Folder")
        var name = "" + (entry.name || "")
        var dot = name.lastIndexOf(".")
        if (dot <= 0 || dot === name.length - 1) return qsTr("File")
        return name.substring(dot).toLowerCase()
    }

    /// The list the keyboard and a click act on: the grid in the two grid
    /// shapes, the details list in the third. Both have `currentIndex` and
    /// `positionViewAtIndex`, which is the whole interface the helpers need.
    readonly property var activeView: view.detailsShown ? fileList : grid
    /// Move the cursor to `index` and bring it into view before the next state
    /// snapshot arrives.
    function revealIndex(index) {
        var target = view.activeView
        if (!target) return
        target.currentIndex = index
        target.positionViewAtIndex(index, view.detailsShown ? ListView.Contain
                                                            : GridView.Contain)
    }

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
    /// `revealIndex` makes the movement visible before the next state snapshot
    /// arrives, in whichever of the three shapes is showing.
    function selectIndex(index) {
        var list = view.entries || [];
        if (list.length === 0) return;
        index = Math.max(0, Math.min(list.length - 1, index));
        view.keyboardCursor = index;
        view.selectionAnchor = index;
        view.revealIndex(index);
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
        view.activeView.currentIndex = index;
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
        view.revealIndex(index);
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
        view.revealIndex(index);
        view.command({ type: "select", paths: paths });
    }

    /// How many cells fit in a row, so Up/Down move by a real row. The details
    /// list is one column of lines, so a row step is one entry there.
    function gridColumns() {
        if (view.detailsShown) return 1;
        return Math.max(1, Math.floor(grid.width / Math.max(1, grid.cellWidth)));
    }

    function gridPageRows() {
        if (view.detailsShown) {
            return Math.max(1, Math.floor(fileList.height / view.detailsRowHeight));
        }
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

                    // Sort button: opens the sort-field & direction menu.
                    AbstractButton {
                        id: sortButton
                        objectName: "browserSortButton"
                        implicitHeight: 28
                        leftPadding: 10
                        rightPadding: 10
                        topPadding: 4
                        bottomPadding: 4
                        implicitWidth: sortRow.implicitWidth + leftPadding + rightPadding
                        focusPolicy: Qt.NoFocus
                        activeFocusOnTab: false
                        hoverEnabled: true
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Sort files")
                        onClicked: {
                            sortPopup.x = Math.max(6, Math.min(crumbBar.width - sortPopup.width - 6, sortButton.x))
                            sortPopup.y = crumbBar.height + 2
                            sortPopup.open()
                        }

                        background: Rectangle {
                            radius: view.theme.radius
                            color: sortButton.hovered ? view.theme.hover : "transparent"
                            border.width: 1
                            border.color: view.theme.border
                        }
                        contentItem: RowLayout {
                            id: sortRow
                            spacing: 6
                            Label {
                                text: view.sortLabel() + (view.sortOrder === "desc" ? " ↓" : " ↑")
                                color: view.theme.text
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    // Thumbnail / item size steppers (5 levels: XS, S, M, L, XL).
                    RowLayout {
                        objectName: "thumbSizeSwitch"
                        spacing: 2

                        AbstractButton {
                            id: thumbDownButton
                            objectName: "thumbSizeDown"
                            implicitWidth: 26
                            implicitHeight: 28
                            padding: 0
                            focusPolicy: Qt.NoFocus
                            activeFocusOnTab: false
                            hoverEnabled: true
                            enabled: view.thumbSizeIndex > 0
                            ToolTip.visible: hovered
                            ToolTip.text: qsTr("Smaller items (%1)").arg(view.thumbSizeLabel)
                            onClicked: view.stepThumbSize(-1)

                            background: Rectangle {
                                radius: view.theme.radius
                                color: thumbDownButton.hovered && thumbDownButton.enabled
                                       ? view.theme.hover : "transparent"
                            }
                            contentItem: Label {
                                text: "−"
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: thumbDownButton.enabled ? view.theme.text : view.theme.textMuted
                                font.pixelSize: 14
                                font.bold: true
                            }
                        }

                        AbstractButton {
                            id: thumbUpButton
                            objectName: "thumbSizeUp"
                            implicitWidth: 26
                            implicitHeight: 28
                            padding: 0
                            focusPolicy: Qt.NoFocus
                            activeFocusOnTab: false
                            hoverEnabled: true
                            enabled: view.thumbSizeIndex < view.thumbSizes.length - 1
                            ToolTip.visible: hovered
                            ToolTip.text: qsTr("Larger items (%1)").arg(view.thumbSizeLabel)
                            onClicked: view.stepThumbSize(1)

                            background: Rectangle {
                                radius: view.theme.radius
                                color: thumbUpButton.hovered && thumbUpButton.enabled
                                       ? view.theme.hover : "transparent"
                            }
                            contentItem: Label {
                                text: "+"
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: thumbUpButton.enabled ? view.theme.text : view.theme.textMuted
                                font.pixelSize: 14
                                font.bold: true
                            }
                        }
                    }

                    // How the folder is drawn, where a file manager puts it: at
                    // the end of the path bar. The three buttons are the app's
                    // own (the platform's `ToolButton` drew its icons with the
                    // palette, and the drawings are this repository's), the
                    // current one is armed, and each names itself for a reader
                    // who cannot see the drawing.
                    RowLayout {
                        objectName: "viewModeSwitch"
                        spacing: 2

                        Repeater {
                            model: view.viewModeEntries

                            delegate: AbstractButton {
                                id: modeButton

                                required property var modelData

                                objectName: "viewMode" + modelData.key.charAt(0).toUpperCase()
                                            + modelData.key.slice(1)
                                readonly property bool armed: view.viewMode === modelData.key

                                implicitWidth: 30
                                implicitHeight: 28
                                padding: 0
                                focusPolicy: Qt.NoFocus
                                activeFocusOnTab: false
                                hoverEnabled: true

                                Accessible.name: modelData.label
                                Accessible.role: Accessible.Button
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Show as %1").arg(modelData.label)

                                onClicked: view.setViewMode(modelData.key)

                                background: Rectangle {
                                    radius: view.theme.radius
                                    color: modeButton.armed ? view.theme.selection
                                         : modeButton.hovered ? view.theme.hover
                                         : "transparent"
                                    border.width: modeButton.armed ? 1 : 0
                                    border.color: view.theme.accent
                                }

                                contentItem: Item {
                                    IconImage {
                                        anchors.centerIn: parent
                                        source: modelData.icon
                                        sourceSize: Qt.size(32, 32)
                                        width: 16
                                        height: 16
                                        fillMode: Image.PreserveAspectFit
                                        color: modeButton.armed ? view.theme.accent
                                             : modeButton.hovered ? view.theme.text
                                             : view.theme.textMuted
                                    }
                                }
                            }
                        }
                    }
                }

                Popup {
                    id: sortPopup
                    objectName: "browserSortMenu"
                    parent: crumbBar
                    padding: 6
                    width: 190
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                    background: Rectangle {
                        radius: view.theme.radius
                        color: view.theme.surface
                        border.width: 1
                        border.color: view.theme.border
                    }

                    contentItem: ColumnLayout {
                        spacing: 2

                        Repeater {
                            model: view.sortEntries
                            delegate: AbstractButton {
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 28
                                hoverEnabled: true
                                focusPolicy: Qt.NoFocus
                                onClicked: {
                                    view.setSortField(modelData.key)
                                    sortPopup.close()
                                }
                                background: Rectangle {
                                    radius: view.theme.radius
                                    color: parent.hovered ? view.theme.hover : "transparent"
                                }
                                contentItem: RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    Label {
                                        text: view.sortBy === modelData.key ? "✓" : ""
                                        color: view.theme.accent
                                        Layout.preferredWidth: 14
                                        font.pixelSize: 12
                                    }
                                    Label {
                                        text: modelData.label
                                        color: view.theme.text
                                        Layout.fillWidth: true
                                        font.pixelSize: 12
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            Layout.topMargin: 2
                            Layout.bottomMargin: 2
                            color: view.theme.border
                        }

                        Repeater {
                            model: [
                                { key: "asc", label: qsTr("Ascending") },
                                { key: "desc", label: qsTr("Descending") }
                            ]
                            delegate: AbstractButton {
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 28
                                hoverEnabled: true
                                focusPolicy: Qt.NoFocus
                                onClicked: {
                                    view.setSortOrder(modelData.key)
                                    sortPopup.close()
                                }
                                background: Rectangle {
                                    radius: view.theme.radius
                                    color: parent.hovered ? view.theme.hover : "transparent"
                                }
                                contentItem: RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    Label {
                                        text: view.sortOrder === modelData.key ? "✓" : ""
                                        color: view.theme.accent
                                        Layout.preferredWidth: 14
                                        font.pixelSize: 12
                                    }
                                    Label {
                                        text: modelData.label
                                        color: view.theme.text
                                        Layout.fillWidth: true
                                        font.pixelSize: 12
                                    }
                                }
                            }
                        }
                    }
                }

                AppMenu {
                    id: hiddenMenu
                    theme: view.theme
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
                // Only the shape on screen holds delegates: a hidden grid with a
                // live model would decode a thumbnail per entry for a picture
                // nobody is looking at.
                model: view.detailsShown ? [] : (view.entries || [])
                visible: !view.detailsShown
                // Five size presets (XS, S, M, L, XL) for both thumbnails and icons.
                readonly property int thumbnailTargetWidth: [108, 140, 178, 230, 300][view.thumbSizeIndex] || 178
                readonly property int thumbnailMinWidth: [92, 112, 132, 172, 224][view.thumbSizeIndex] || 132
                readonly property int iconTargetWidth: [76, 96, 116, 148, 184][view.thumbSizeIndex] || 116
                readonly property int iconMinWidth: [68, 82, 96, 120, 152][view.thumbSizeIndex] || 96
                readonly property int thumbnailCellWidth:
                    Math.max(thumbnailMinWidth, Math.floor(width / Math.max(1, Math.floor(width / thumbnailTargetWidth))))
                readonly property int iconCellWidth:
                    Math.max(iconMinWidth, Math.floor(width / Math.max(1, Math.floor(width / iconTargetWidth))))
                readonly property bool iconsShown: view.viewMode === "icons"
                readonly property int iconGlyphSize:
                    iconsShown ? ([22, 26, 32, 42, 54][view.thumbSizeIndex] || 32)
                               : ([28, 36, 44, 56, 72][view.thumbSizeIndex] || 44)
                cellWidth: iconsShown ? iconCellWidth : thumbnailCellWidth
                // An icon cell is a drawing and a name, not a picture and a
                // caption, so it is shorter than it is wide: a row of them reads
                // as a list of kinds rather than a wall of empty tiles.
                cellHeight: iconsShown ? Math.round(iconCellWidth * 0.78)
                                       : Math.round(cellWidth * 0.78) + 32
                boundsBehavior: Flickable.StopAtBounds
                // Moderate off-screen delegate buffer: keeps adjacent rows warm
                // during scroll without spiking delegate creation on mode/sort switches.
                cacheBuffer: Math.max(320, Math.round(height * 0.75))
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
                        anchors.leftMargin: grid.iconsShown ? 6 : 10
                        anchors.rightMargin: grid.iconsShown ? 6 : 10
                        anchors.topMargin: grid.iconsShown ? 6 : 10
                        height: parent.height - (grid.iconsShown ? 32 : 42)

                        Rectangle {
                            anchors.fill: parent
                            radius: 4
                            color: grid.iconsShown ? "transparent" : view.theme.thumb
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
                                ///
                                /// The icon shape names the kind of file rather
                                /// than showing it, so it asks for no thumbnail
                                /// at all: a folder of two hundred pictures is a
                                /// list, not two hundred decodes.
                                thumbnailable: cell.entry.isImage && !grid.iconsShown
                                modified: cell.entry.modified
                                fileSize: cell.entry.size
                                asynchronous: true
                                fillMode: Image.PreserveAspectFit
                                sourceSize.width: Math.max(64, Math.ceil(thumbFrame.width * 2))
                                sourceSize.height: Math.max(64, Math.ceil(thumbFrame.height * 2))
                                visible: !grid.iconsShown
                            }

                            Icon {
                                objectName: "gridIcon"
                                visible: grid.iconsShown || entry.isDir || !entry.isImage
                                anchors.centerIn: parent
                                iconName: entry.isDir ? "folder-symbolic"
                                                      : entry.isImage ? "image-x-generic-symbolic"
                                                                      : "text-x-generic-symbolic"
                                iconSize: grid.iconGlyphSize
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

            // The details shape: a header row naming the four columns, then one
            // line per entry. The header does not scroll with the list — a
            // column you cannot name once you are past the first screenful is a
            // column you have to remember — and it reads the same column widths
            // as every row.
            Rectangle {
                id: detailsHeader
                objectName: "detailsHeader"
                visible: view.detailsShown
                Layout.fillWidth: true
                Layout.preferredHeight: view.detailsRowHeight
                color: view.theme.surfaceAlt
                border.width: 1
                border.color: view.theme.border

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 8

                    // The rows start with a 16 px drawing; the header starts with
                    // its width in blank, so `Tên` sits over the names.
                    Item {
                        Layout.preferredWidth: view.detailsIconWidth
                        Layout.preferredHeight: 1
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Label {
                            objectName: "detailsNameColumn"
                            text: qsTr("Name")
                            color: view.sortBy === "name" ? view.theme.text : view.theme.textMuted
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Label {
                            visible: view.sortBy === "name"
                            text: view.sortOrder === "desc" ? "↓" : "↑"
                            color: view.theme.accent
                            font.pixelSize: 11
                        }
                        Item { Layout.fillWidth: true }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onSingleTapped: view.setSortField("name") }
                    }
                    RowLayout {
                        Layout.preferredWidth: view.detailsTypeWidth
                        spacing: 4
                        Label {
                            objectName: "detailsTypeColumn"
                            text: qsTr("Type")
                            color: view.sortBy === "kind" ? view.theme.text : view.theme.textMuted
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Label {
                            visible: view.sortBy === "kind"
                            text: view.sortOrder === "desc" ? "↓" : "↑"
                            color: view.theme.accent
                            font.pixelSize: 11
                        }
                        Item { Layout.fillWidth: true }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onSingleTapped: view.setSortField("kind") }
                    }
                    RowLayout {
                        Layout.preferredWidth: view.detailsSizeWidth
                        spacing: 4
                        Item { Layout.fillWidth: true }
                        Label {
                            visible: view.sortBy === "size"
                            text: view.sortOrder === "desc" ? "↓" : "↑"
                            color: view.theme.accent
                            font.pixelSize: 11
                        }
                        Label {
                            objectName: "detailsSizeColumn"
                            text: qsTr("Size")
                            color: view.sortBy === "size" ? view.theme.text : view.theme.textMuted
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onSingleTapped: view.setSortField("size") }
                    }
                    RowLayout {
                        Layout.preferredWidth: view.detailsModifiedWidth
                        spacing: 4
                        Label {
                            objectName: "detailsModifiedColumn"
                            text: qsTr("Modified")
                            color: view.sortBy === "modified" ? view.theme.text : view.theme.textMuted
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Label {
                            visible: view.sortBy === "modified"
                            text: view.sortOrder === "desc" ? "↓" : "↑"
                            color: view.theme.accent
                            font.pixelSize: 11
                        }
                        Item { Layout.fillWidth: true }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onSingleTapped: view.setSortField("modified") }
                    }
                }
            }

            ListView {
                id: fileList
                objectName: "fileList"
                visible: view.detailsShown
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                // As in the grid: only the shape on screen holds delegates.
                model: view.detailsShown ? (view.entries || []) : []
                boundsBehavior: Flickable.StopAtBounds
                // Moderate off-screen delegate buffer: keeps adjacent rows warm
                // during scroll without spiking delegate creation on mode/sort switches.
                cacheBuffer: Math.max(320, Math.round(height * 0.75))
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                WheelScroll {
                    view: fileList
                    step: view.detailsRowHeight
                }

                delegate: Rectangle {
                    id: fileRowRow
                    objectName: "fileRow"
                    width: fileList.width
                    height: view.detailsRowHeight

                    required property int index
                    required property var modelData

                    property var entry: modelData
                    property bool selected: (view.state.selection || []).indexOf(entry.path) >= 0

                    color: selected ? view.theme.selection
                         : rowHover.hovered ? view.theme.hover
                         : "transparent"

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: view.theme.border
                        opacity: 0.4
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8

                        // The kind of file, as the folder's own drawing: a
                        // folder for a folder, the picture the format for an
                        // image, a page for anything else.
                        Icon {
                            objectName: "rowIcon"
                            Layout.preferredWidth: view.detailsIconWidth
                            Layout.preferredHeight: view.detailsIconWidth
                            iconName: fileRowRow.entry.isDir ? "folder-symbolic"
                                    : fileRowRow.entry.isImage ? "image-x-generic-symbolic"
                                                               : "text-x-generic-symbolic"
                            iconSize: 16
                            iconColor: view.theme.textMuted
                        }
                        Label {
                            objectName: "rowName"
                            Layout.fillWidth: true
                            text: fileRowRow.entry.name
                            color: view.theme.text
                            font.pixelSize: 12
                            elide: Text.ElideMiddle
                        }
                        Label {
                            objectName: "rowType"
                            Layout.preferredWidth: view.detailsTypeWidth
                            text: view.entryKind(fileRowRow.entry)
                            color: view.theme.textMuted
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        Label {
                            objectName: "rowSize"
                            Layout.preferredWidth: view.detailsSizeWidth
                            text: fileRowRow.entry.isDir ? "—"
                                                        : view.theme.formatBytes(fileRowRow.entry.size)
                            color: view.theme.textMuted
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                        Label {
                            objectName: "rowModified"
                            Layout.preferredWidth: view.detailsModifiedWidth
                            text: view.theme.formatDateShort(fileRowRow.entry.modified)
                            color: view.theme.textMuted
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }

                    HoverHandler { id: rowHover }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onClicked: function(mouse) { view.clickIndex(index, mouse.modifiers) }
                        onDoubleClicked: view.openEntry(fileRowRow.entry)
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onSingleTapped: {
                            var selection = view.state.selection || [];
                            if (selection.indexOf(fileRowRow.entry.path) < 0) {
                                view.selectionAnchor = index;
                                view.command({ type: "select", paths: [fileRowRow.entry.path] });
                            }
                            view.openFileMenu(fileRowRow.entry);
                        }
                    }
                }
            }

            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 8
                Layout.bottomMargin: 8
                visible: view.listedCount === 0 && !view.state.busy
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
    AppMenu {
        id: fileMenu
        objectName: "fileMenu"
        theme: view.theme
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

    AppMenu {
        id: folderMenu
        objectName: "folderMenu"
        theme: view.theme
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

    AppMenu {
        id: quickMenu
        objectName: "quickMenu"
        theme: view.theme
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
    AppMenu {
        id: browserOverflow
        objectName: "browserOverflowMenu"
        theme: view.theme
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
