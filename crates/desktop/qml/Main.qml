import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import io.github.tienv2i.KogaView 1.0

ApplicationWindow {
    id: root

    width: 1280
    height: 820
    minimumWidth: 940
    minimumHeight: 560
    visible: true
    title: "KogaView" + (bridge.profile === "dev" ? " (Dev)" : "")
    color: appTheme.background

    Theme {
        id: appTheme
        dark: root.state.theme === "dark"
    }

    /// Menus size themselves to their longest label, and the pixels have to come
    /// from C++: a `Menu`'s own `font` follows its width, so measuring text inside
    /// the menu whose width depends on it loops in QML. The widths depend on the
    /// window font only, which does not change while the app runs; one
    /// measurement at startup is therefore enough, and it is assigned rather than
    /// bound because Qt 6.12 does not re-evaluate a binding whose value comes
    /// from a function that writes state of its own.
    property bool menuWidthsMeasured: false
    function measureMenuLabels() {
        if (menuWidthsMeasured) return
        appTheme.menuLabelWidths =
            Platform.textWidths(appTheme.menuEntryLabels, Qt.application.font)
        menuWidthsMeasured = true
    }

    // Keep built-in controls (menus, dialogs, scroll bars) in step with the
    // app theme instead of the platform default palette.
    palette.window: appTheme.background
    palette.windowText: appTheme.text
    palette.base: appTheme.surface
    palette.alternateBase: appTheme.surfaceAlt
    palette.text: appTheme.text
    palette.button: appTheme.surface
    palette.buttonText: appTheme.text
    palette.brightText: "#ffffff"
    palette.highlight: appTheme.accent
    palette.highlightedText: appTheme.accentText
    palette.toolTipBase: appTheme.surfaceAlt
    palette.toolTipText: appTheme.text
    palette.placeholderText: appTheme.textMuted
    palette.mid: appTheme.border
    palette.dark: appTheme.border
    palette.light: appTheme.surfaceAlt

    KogaViewBridge {
        id: bridge
        // Lets the debug-only QA harness reach the same command gateway.
        objectName: "bridge"
    }

    // Everything the window paints except the folder listing, which travels as
    // the snapshot's own `entries`/`viewerImages` so an unchanged listing keeps
    // its identity between snapshots.
    property var state: snapshot.state
    property string toastText: ""
    property var pendingDestination: null
    property var pendingDelete: null
    property string folderDialogPurpose: "open"

    /// The bridge publishes the folder listing apart from everything else; this
    /// assembles the two back into the snapshot the views render.
    StateSnapshot {
        id: snapshot
        metaJson: bridge.stateJson
        listingJson: bridge.listingJson
        epoch: bridge.listingEpoch
    }

    function showToast(message) {
        if (!message) return;
        root.toastText = String(message);
        toastTimer.restart();
    }

    function send(command) {
        var envelope = {
            protocol: 1,
            id: "ui-" + Date.now() + "-" + Math.floor(Math.random() * 1000000),
            command: command
        };
        var text = bridge.dispatch(JSON.stringify(envelope));
        var result = null;
        try {
            result = JSON.parse(text);
        } catch (error) {
            console.warn("KogaView: cannot parse command result:", text);
        }
        if (result) {
            if (!result.ok && result.error) {
                root.showToast(result.error.message);
            } else if (result.message && command.type !== "select") {
                root.showToast(result.message);
            }
        }
        return result;
    }

    function listFolders(path) {
        if (!path) return { ok: false, folders: [] };
        var text = bridge.query(JSON.stringify({ type: "list_folders", path: path }));
        try {
            return JSON.parse(text);
        } catch (error) {
            return { ok: false, folders: [] };
        }
    }

    function chooseFiles() {
        if (!Platform.requestOpenFile("Open images")) {
            fileFallback.open();
        }
    }

    function chooseFolder() {
        root.folderDialogPurpose = "open";
        if (!Platform.requestOpenFolder("Open folder")) {
            folderFallback.open();
        }
    }

    function chooseDestination(action, paths) {
        root.pendingDestination = { action: action, paths: paths };
        root.folderDialogPurpose = "destination";
        if (!Platform.requestOpenFolder("Choose destination folder")) {
            folderFallback.open();
        }
    }

    function handleFolderSelected(path) {
        if (!path) return;
        if (root.pendingDestination) {
            var pending = root.pendingDestination;
            root.pendingDestination = null;
            root.send({
                type: pending.action,
                paths: pending.paths,
                destination: path
            });
        } else {
            root.send({ type: "open_folder", path: path });
        }
    }

    function toLocalPath(url) {
        var text = "" + url;
        if (text.indexOf("file://") === 0) {
            text = text.substring("file://".length);
        }
        try {
            return decodeURIComponent(text);
        } catch (error) {
            return text;
        }
    }

    function processLaunchArguments() {
        var args = launchArgs || [];
        if (args.length === 0) return;
        var rest = Array.prototype.slice.call(args);
        var mode = "open";
        if (rest[0] === "open" || rest[0] === "open-folder") {
            mode = rest.shift();
        }
        if (mode === "open-folder") {
            if (rest.length > 0) {
                root.send({ type: "open_folder", path: rest[0] });
            }
        } else if (rest.length > 0) {
            root.send({ type: "open_file", paths: rest });
        }
    }

    Component.onCompleted: {
        // Before the first menu can open: they size themselves to the labels.
        root.measureMenuLabels();
        snapshot.apply();
        root.processLaunchArguments();
    }

    Connections {
        target: Platform
        function onFilesSelected(paths) {
            if (paths && paths.length > 0) {
                root.send({ type: "open_file", paths: paths });
            }
        }
        function onFolderSelected(path) {
            root.handleFolderSelected(path);
        }
        function onCopyResult(ok, message) {
            root.showToast(message);
        }
        function onDialogError(message) {
            root.showToast(message);
        }
        function onInfo(message) {
            root.showToast(message);
        }
    }

    Timer {
        id: toastTimer
        interval: 3400
        onTriggered: root.toastText = ""
    }

    Timer {
        interval: 120
        running: true
        repeat: true
        onTriggered: {
            if (bridge.poll()) {
                snapshot.apply();
            }
        }
    }

    Shortcut {
        sequence: "Ctrl+O"
        onActivated: root.chooseFiles()
    }
    Shortcut {
        sequence: "Ctrl+Shift+O"
        onActivated: root.chooseFolder()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "F5"
        onActivated: root.send({ type: "refresh" })
    }

    header: ToolBar {
        id: headerBar
        padding: 0
        background: Rectangle {
            color: appTheme.surface
        }
        contentHeight: 50

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 4

            WorkspaceSwitcher {
                objectName: "workspaceSwitcher"
                theme: appTheme
                workspace: root.state.workspace || "browser"
                onSelected: function(workspace) {
                    root.send({ type: "set_workspace", workspace: workspace });
                }
            }

            ToolbarSeparator { theme: appTheme }

            Loader {
                id: workspaceToolbar
                Layout.alignment: Qt.AlignVCenter
                sourceComponent: workspaceLoader.item ? workspaceLoader.item.toolbar : null
            }

            Item {
                Layout.fillWidth: true
            }

            BusyIndicator {
                running: bridge.busy
                visible: running
                implicitWidth: 28
                implicitHeight: 28
            }

            ToolbarButton {
                theme: appTheme
                icon.name: "open-menu-symbolic"
                text: "Menu"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: "Main menu"
                onClicked: mainMenu.popup()
            }
        }
    }

    footer: ToolBar {
        id: footerBar
        padding: 0
        background: Rectangle {
            color: appTheme.surface
        }
        contentHeight: 32

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10

            Label {
                text: bridge.statusMessage
                color: appTheme.textMuted
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Label {
                visible: !!(root.state.selectionInfo)
                text: root.state.selectionInfo
                      ? (root.state.selectionInfo.name + " · "
                         + appTheme.formatBytes(root.state.selectionInfo.size))
                      : ""
                color: appTheme.textMuted
                elide: Text.ElideMiddle
                Layout.maximumWidth: 340
            }

            Label {
                text: (root.state.itemCount || 0) + " items · "
                      + (root.state.imageCount || 0) + " images"
                color: appTheme.textMuted
            }

            Label {
                text: root.state.workspace || "browser"
                color: appTheme.accent
            }

            Label {
                text: "rev " + bridge.revision
                color: appTheme.textMuted
            }

            ToolButton {
                visible: bridge.busy
                text: "Cancel"
                onClicked: root.send({ type: "cancel_operation" })
            }
        }
    }

    Loader {
        id: workspaceLoader
        anchors.fill: parent
        sourceComponent: {
            if (root.state.workspace === "viewer") return viewerComponent;
            if (root.state.workspace === "editor") return editorComponent;
            return browserComponent;
        }
    }

    Component {
        id: browserComponent
        BrowserView {
            objectName: "browser"
            theme: appTheme
            menuLabelWidths: appTheme.menuLabelWidths
            state: root.state
            entries: snapshot.entries
            thumbnails: typeof Thumbnails !== "undefined" ? Thumbnails : null
            listFolders: root.listFolders
            onCommand: function(command) { root.send(command); }
            onToast: function(message) { root.showToast(message); }
            onCopyImage: function(path) { Platform.copyImage(path); }
            onCopyText: function(text) { Platform.copyText(text); }
            onOpenExternal: function(path) { Platform.openExternally(path); }
            onOpenWith: function(path) { Platform.openWith(path); }
            onRequestDestination: function(action, paths) {
                root.chooseDestination(action, paths);
            }
            onRequestDelete: function(paths) {
                root.pendingDelete = paths;
                deleteDialog.open();
            }
            onRequestOpenFolder: root.chooseFolder()
        }
    }

    Component {
        id: viewerComponent
        Viewer {
            objectName: "viewer"
            theme: appTheme
            state: root.state
            entries: snapshot.entries
            viewerImages: snapshot.viewerImages
            thumbnails: typeof Thumbnails !== "undefined" ? Thumbnails : null
            onCommand: function(command) { root.send(command); }
        }
    }

    Component {
        id: editorComponent
        EditorView {
            theme: appTheme
            state: root.state
            onCommand: function(command) { root.send(command); }
        }
    }

    Menu {
        id: mainMenu
        implicitWidth: appTheme.menuWidth(appTheme.menuLabelWidths)

        MenuItem {
            text: "Open file…"
            icon.name: "document-open-symbolic"
            onTriggered: root.chooseFiles()
        }
        MenuItem {
            text: "Open folder…"
            icon.name: "folder-open-symbolic"
            onTriggered: root.chooseFolder()
        }
        MenuSeparator {}
        MenuItem {
            text: root.state.theme === "dark" ? "Switch to light mode" : "Switch to dark mode"
            icon.name: root.state.theme === "dark"
                       ? "weather-clear-symbolic"
                       : "weather-clear-night-symbolic"
            onTriggered: root.send({ type: "toggle_theme" })
        }
        MenuSeparator {}
        MenuItem {
            text: "Exit"
            icon.name: "application-exit-symbolic"
            onTriggered: Qt.quit()
        }
    }

    FileDialog {
        id: fileFallback
        title: "Open images"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "Images (*.jpg *.jpeg *.png *.webp *.gif *.bmp *.tif *.tiff *.avif *.heic)"
        ]
        onAccepted: {
            var paths = [];
            for (var index = 0; index < selectedFiles.length; index++) {
                paths.push(root.toLocalPath(selectedFiles[index]));
            }
            if (paths.length > 0) {
                root.send({ type: "open_file", paths: paths });
            }
        }
    }

    FolderDialog {
        id: folderFallback
        title: root.folderDialogPurpose === "destination"
               ? "Choose destination folder"
               : "Open folder"
        onAccepted: {
            var path = root.toLocalPath(selectedFolder);
            if (root.folderDialogPurpose === "destination") {
                root.handleFolderSelected(path);
            } else {
                root.send({ type: "open_folder", path: path });
            }
        }
        onRejected: {
            root.pendingDestination = null;
        }
    }

    MessageDialog {
        id: deleteDialog
        title: "Delete permanently?"
        text: root.pendingDelete
              ? ("Permanently delete " + root.pendingDelete.length
                 + " item(s)? This cannot be undone.")
              : ""
        buttons: MessageDialog.Yes | MessageDialog.Cancel
        onAccepted: {
            root.send({ type: "delete_permanently", paths: root.pendingDelete || [] });
            root.pendingDelete = null;
        }
        onRejected: root.pendingDelete = null
    }

    Rectangle {
        id: toast
        z: 1000
        visible: root.toastText !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: Math.min(parent.width - 80, toastLabel.implicitWidth + 32)
        height: toastLabel.implicitHeight + 20
        radius: appTheme.radius
        color: appTheme.surfaceAlt
        border.width: 1
        border.color: appTheme.border

        Label {
            id: toastLabel
            anchors.centerIn: parent
            width: Math.min(parent.width - 24, implicitWidth)
            text: root.toastText
            color: appTheme.text
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
