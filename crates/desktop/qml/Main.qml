import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import io.github.tienv2i.KogaView 1.0

ApplicationWindow {
    id: root

    width: 1280
    height: 820
    // The floor is measured, not typed: a window must keep every toolbar icon
    // with the labels dropped, and leave room for a sidebar and a picture. See
    // `ToolbarMetrics.minimumWindowWidth` and
    // `docs/adr/0010-earned-labels-and-picture-sized-windows.md`.
    minimumWidth: root.minimumWindowWidth
    minimumHeight: 420
    visible: true
    title: qsTr("KogaView") + (bridge.profile === "dev" ? " " + qsTr("(Dev)") : "")
    color: appTheme.background

    Theme {
        id: appTheme
        // Core owns the stored theme. While the Settings dialog previews one,
        // `previewTheme` (ephemeral, never written) wins so the window repaints
        // before anything is saved; clearing it — on Cancel or on the save that
        // publishes the new theme — falls back to the stored value. This is the
        // one piece of state QML is allowed to own, and ADR 0009 records why:
        // a preview that had to be persisted first would not be a preview.
        dark: (root.previewTheme || root.state.theme) === "dark"
    }

    /// The theme the Settings dialog is previewing, or empty for "the stored
    /// theme". Set by `previewRequested`, cleared by `revertRequested` and by
    /// every save.
    property string previewTheme: ""

    // --------------------------------------------------- toolbar compaction
    //
    // A narrow window must not cut the toolbar in half. Every toolbar button is
    // an icon square, and a label only appears when the window is wide enough
    // to give it room (`CompactToolbarButton.useText`). `ToolbarMetrics` owns
    // the measuring; the shell only reads the two answers:
    //
    //   width ≥ labelThreshold      ⇒ labels may appear
    //   width ≥ minimumWindowWidth  ⇒ the window may exist at all
    //
    // Both come from the same arithmetic, so a window that may exist can always
    // draw every icon. See `docs/adr/0010-*.md`.

    ToolbarMetrics {
        id: toolbarMetrics
    }

    /// Where a label first has room, and what the window may shrink to.
    readonly property real toolbarLabelThreshold: toolbarMetrics.labelThreshold
    readonly property real minimumWindowWidth: toolbarMetrics.minimumWindowWidth
    /// True while the window is wide enough for labels beside the icons.
    readonly property bool toolbarLabels: root.width >= root.toolbarLabelThreshold

    /// The floor is also enforced here, and not only through `minimumWidth`.
    ///
    /// On this GNOME/Wayland session the compositor does not honour a QML
    /// window's minimum size for a programmatic `resize`: a request for 200 px
    /// produced a 200 px window whose toolbar was cut in half. A user-initiated
    /// drag is clamped by the compositor, but the shell-facing contract has to
    /// hold on its own too — this re-applies the floor whenever the window ends
    /// up narrower than `minimumWindowWidth`.
    onWidthChanged: {
        if (root.width < root.minimumWindowWidth) {
            Qt.callLater(root.enforceMinimumWidth)
        }
    }

    /// Put the window back at its floor after a resize that went under it.
    function enforceMinimumWidth() {
        if (root.width < root.minimumWindowWidth) {
            root.width = root.minimumWindowWidth
        }
    }

    /// Menus size themselves to their longest label, and the pixels have to come
    /// from C++: a `Menu`'s own `font` follows its width, so measuring text inside
    /// the menu whose width depends on it loops in QML. The widths depend on the
    /// window font and on the interface language, which changes while the app
    /// runs, so the measurement is assigned rather than bound and re-run by
    /// `applyInterfaceLanguage`.
    property bool menuWidthsMeasured: false
    function measureMenuLabels(force) {
        if (menuWidthsMeasured && force !== true) return
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
    /// The installer C++ exposed as the context property `Language`
    /// (`cpp/language.cpp`). It is not named `Language` here: QML already has a
    /// `Language` enum from QtQuick.Window, which shadows a context property of
    /// that name and would make `Language.locale` undefined.
    readonly property var languageInstaller: typeof LanguageInstaller === "undefined"
                                              ? null : LanguageInstaller
    /// The locale the interface is in now (`vi`), or empty for the desktop's
    /// own language. Written by C++ and by `applyInterfaceLanguage` below, so a
    /// label asks one property instead of a translator.
    property string interfaceLanguage: ""
    /// The last `bridge.language` applied here. QML can watch the bridge's
    /// notifier; C++ cannot connect to it, because CXX-Qt declares those signals
    /// private (`connect` returns false there).
    property string appliedLanguage: ""
    /// Install a language while the window is open.
    function applyInterfaceLanguage(locale) {
        if (!root.languageInstaller) return;
        if (root.languageInstaller.locale === locale) return;
        root.languageInstaller.apply(locale);
        var now = root.languageInstaller.locale;
        root.appliedLanguage = now === undefined || now === null ? "" : String(now);
        // Menus fit their labels, and the labels just changed language.
        root.measureMenuLabels(true);
    }
    /// Re-read the language after a snapshot. QML re-evaluates this binding on
    /// every command, because `snapshot.state` is replaced then, so a
    /// `set_settings` whose `language` field changed is applied even when the
    /// bridge's own property emitted nothing the window saw.
    function syncInterfaceLanguage() {
        var stored = (snapshot.state && snapshot.state.language) ? snapshot.state.language : "";
        if (stored !== root.appliedLanguage) root.applyInterfaceLanguage(stored);
    }
    Connections {
        target: bridge
        function onLanguageChanged() { root.applyInterfaceLanguage(bridge.language); }
    }
    Connections {
        target: snapshot
        function onStateChanged() { root.syncInterfaceLanguage(); }
    }
    /// True while the file chooser was opened from the Editor, so a chosen
    /// file loads into the editor instead of replacing the Viewer.
    property bool choosingForEditor: false

    /// The bridge publishes the folder listing apart from everything else; this
    /// assembles the two back into the snapshot the views render.
    StateSnapshot {
        id: snapshot
        metaJson: bridge.stateJson
        listingJson: bridge.listingJson
        epoch: bridge.listingEpoch
    }

    /// Called by C++ after it swapped translators: publishes a snapshot whose
    /// strings are the new language, so the views rebuild from it.
    function retranslateBridge() {
        bridge.retranslate();
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

    /// Send several commands that belong to one user action (the Edit entries
    /// send `select` + `set_workspace` + `editor_open`).
    ///
    /// They must not be dispatched back to back from inside a handler: each
    /// `dispatch` publishes a new `state`, whose `onStateChanged` reloads the
    /// folder tree, and that rebuild runs while the handler that opened the
    /// context menu is still on the stack — the third command was silently
    /// dropped and the Editor never received the image. Queuing the rest with
    /// `Qt.callLater` lets the handler return first.
    function sendSequence(commands) {
        var pending = commands.slice();
        function next() {
            if (pending.length === 0) return;
            root.send(pending.shift());
            if (pending.length > 0) Qt.callLater(next);
        }
        next();
    }

    function openSettings() {
        // Open on what is stored, not on a default: the snapshot carries the
        // two checkboxes beside the theme, so the dialog shows the saved values.
        settingsDialog.initialTheme = root.state.theme || "dark";
        settingsDialog.initialRemember = root.state.rememberLastFolder !== false;
        settingsDialog.initialBackground = root.state.backgroundThumbnails !== false;
        settingsDialog.initialLanguage = root.state.language || "system";
        settingsDialog.languageChoices = Platform.languages();
        settingsDialog.open();
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
        if (!Platform.requestOpenFile(qsTr("Open images"))) {
            fileFallback.open();
        }
    }

    /// The Editor's chooser. It uses the same portal/fallback route as
    /// `chooseFiles`, but the picked file becomes an `editor_open` command.
    function chooseEditorImage() {
        root.choosingForEditor = true;
        if (!Platform.requestOpenFile(qsTr("Open an image for editing"))) {
            fileFallback.open();
        }
    }

    /// A chooser answered outside the Editor is an ordinary multi-file open;
    /// one opened from the Editor loads exactly one file into the working
    /// document. `open_file` would replace the Viewer instead.
    function handleOpenedPaths(paths) {
        if (!paths || paths.length === 0) {
            root.choosingForEditor = false;
            return;
        }
        if (root.choosingForEditor) {
            root.choosingForEditor = false;
            root.send({ type: "editor_open", path: paths[0] });
        } else {
            root.send({ type: "open_file", paths: paths });
        }
    }

    /// True while the Editor holds edits that are not on disk. Every way out of
    /// the Editor asks this first.
    readonly property bool editorHasUnsavedChanges:
        !!(root.state.editor && root.state.editor.modified && !root.state.editor.saved)

    /// Save As: the chooser suggests where the document would go now. The
    /// dialog is opened from the Editor's button; the chosen path becomes
    /// `editor_save_as`.
    function chooseEditorSaveAs() {
        var editor = workspaceLoader.item;
        saveFallback.currentFile = "file://" + (editor && editor.saveAsPath ? editor.saveAsPath : "")
        saveFallback.open();
    }

    /// A request to leave the Editor while edits are unsaved. `action` is what
    /// happens if the user says "Discard"; "quit" closes the window.
    property var pendingLeave: null
    function guardEditorLeave(action) {
        if (root.state.workspace !== "editor" || !root.editorHasUnsavedChanges) {
            root.runLeave(action);
            return;
        }
        root.pendingLeave = action;
        unsavedDialog.open();
    }
    /// The dialog's Save answer: write, then go. The save and the leave are
    /// queued, because each command republishes the state and a leave sent in
    /// the same turn as the save could be dropped.
    function leaveAfterSave() {
        var leave = root.pendingLeave;
        root.pendingLeave = null;
        unsavedDialog.close();
        var following = leave === "quit"
                ? null
                : (leave && leave.workspace
                   ? { type: "set_workspace", workspace: leave.workspace }
                   : { type: "editor_close" });
        var commands = [{ type: "editor_save" }];
        if (following) commands.push(following);
        root.sendSequence(commands);
        if (leave === "quit") Qt.callLater(function() { root.runLeave("quit"); });
    }
    /// The dialog's Discard answer: drop the edits and go.
    function leaveAfterDiscard() {
        var leave = root.pendingLeave;
        unsavedDialog.close();
        root.runLeave(leave);
    }

    function runLeave(action) {
        root.pendingLeave = null;
        if (action === "quit") {
            leavingForQuit = true;
            Qt.quit();
        } else if (action && action.workspace) {
            root.send({ type: "set_workspace", workspace: action.workspace });
        } else if (action && action.close) {
            root.send({ type: "editor_close" });
        }
    }
    /// Set right before the window is allowed to close, so `onClosing` does not
    /// ask a second time.
    property bool leavingForQuit: false

    function chooseFolder() {
        root.folderDialogPurpose = "open";
        if (!Platform.requestOpenFolder(qsTr("Open folder"))) {
            folderFallback.open();
        }
    }

    function chooseDestination(action, paths) {
        root.pendingDestination = { action: action, paths: paths };
        root.folderDialogPurpose = "destination";
        if (!Platform.requestOpenFolder(qsTr("Choose destination folder"))) {
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

    /// The window the shell opened with. `open FILE` sizes it to the picture
    /// before the Viewer's first fit, so the user sees one fitted image
    /// instead of a default window followed by a jump to the photo's shape.
    ///
    /// The chrome measured here is what the Viewer adds around the picture:
    /// the header and footer bars, the filmstrip, and the margin `fittedZoom`
    /// leaves (2 %). It is a *target*, not a promise: the compositor may clamp
    /// the size, `minimumWidth` keeps it usable, and the working area keeps it
    /// on screen.
    readonly property int viewerChromeHeight: 50 + 32 + 106 + 16
    readonly property int viewerChromeWidth: 16

    /// The size a window should have to show `imageWidth`×`imageHeight` with
    /// as little empty space as possible.
    ///
    /// A small picture never enlarges the picture past 100 %, so its window
    /// only has to be big enough to frame it; a large one is fitted into a
    /// window no bigger than the screen allows. Either way the bounds are the
    /// window floor and the available screen area — an 8000×6000 photo does
    /// not ask for an 8000 px window.
    function windowSizeForImage(imageWidth, imageHeight) {
        if (!imageWidth || !imageHeight) {
            return { width: root.width, height: root.height }
        }
        var screen = root.screen
        var available = screen && screen.desktopAvailableWidth > 0
                        ? screen.desktopAvailableWidth : 1920
        var availableHeight = screen && screen.desktopAvailableHeight > 0
                              ? screen.desktopAvailableHeight : 1080
        // Leave room for panels and a strip of desktop on every side; a window
        // that fills the screen exactly is hard to move and indistinguishable
        // from fullscreen.
        var maxWidth = Math.round(available * 0.92)
        var maxHeight = Math.round(availableHeight * 0.92)
        // The picture's own box: what is left of the screen once the toolbar,
        // footer and filmstrip have taken theirs. Measuring the scale against
        // the *window* instead would ask for an image plus chrome taller than
        // the screen.
        var pictureWidth = Math.max(1, maxWidth - root.viewerChromeWidth)
        var pictureHeight = Math.max(1, maxHeight - root.viewerChromeHeight)
        // The picture at its fitted zoom: never above 100 %, and `fittedZoom`'s
        // 2 % margin applies once it is scaled down.
        var scale = Math.min(1, Math.min(pictureWidth / imageWidth,
                                         pictureHeight / imageHeight))
        if (scale < 1) {
            scale *= 0.98
        }
        var width = Math.round(imageWidth * scale) + root.viewerChromeWidth
        var height = Math.round(imageHeight * scale) + root.viewerChromeHeight
        return {
            width: Math.max(root.minimumWidth, Math.min(maxWidth, width)),
            height: Math.max(root.minimumHeight, Math.min(maxHeight, height))
        }
    }

    /// The size the shell is trying to give the window, or zeroes when the
    /// window was not opened with an image. Only the launch path writes it.
    property var openedWindowSize: ({ width: 0, height: 0 })

    /// Size the window to the image the shell opened. Only the launch path
    /// calls this: a folder opened from inside the app must not resize the
    /// window under the user's hands.
    function fitWindowToImage(path) {
        var size = Platform.imageSize(path)
        if (!size || !size.width || !size.height) {
            return
        }
        var target = root.windowSizeForImage(size.width, size.height)
        root.openedWindowSize = target
        root.width = target.width
        root.height = target.height
        // The compositor can apply its own geometry when the window is mapped:
        // on this machine GNOME turned a 1639×1104 request into a 1920×1125
        // window. Setting the size again once the window exists is what makes
        // it stick. It runs at most twice, at launch only, so a window the user
        // resizes afterwards is never pulled back.
        Qt.callLater(root.enforceOpenedWindowSize)
        retryWindowSizeTimer.restart()
    }

    /// Restore `openedWindowSize` if the compositor overrode it.
    function enforceOpenedWindowSize() {
        var target = root.openedWindowSize
        if (!target || !target.width) {
            return
        }
        if (root.width !== target.width || root.height !== target.height) {
            root.width = target.width
            root.height = target.height
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
            var target = root.toLocalPath(rest[0]);
            root.fitWindowToImage(target);
            root.send({ type: "open_file", paths: rest });
        }
    }

    Component.onCompleted: {
        // Before the first menu can open: they size themselves to the labels.
        root.measureMenuLabels();
        snapshot.apply();
        // C++ applied the stored language before the window existed; this is
        // the same value, adopted so a later change is a real difference.
        var installed = root.languageInstaller ? root.languageInstaller.locale : "";
        root.appliedLanguage = installed === undefined || installed === null ? "" : String(installed);
        root.processLaunchArguments();
    }

    Connections {
        target: Platform
        function onFilesSelected(paths) {
            root.handleOpenedPaths(paths);
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

    // One late attempt at the opened window's size, for a compositor that
    // applies its geometry after the first frame. It is not a loop: it fires
    // once, and only when a launch sized the window.
    Timer {
        id: retryWindowSizeTimer
        objectName: "retryWindowSizeTimer"
        interval: 250
        repeat: false
        onTriggered: root.enforceOpenedWindowSize()
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
        onActivated: root.guardEditorLeave("quit")
    }
    Shortcut {
        sequence: "Ctrl+S"
        onActivated: {
            if (root.state.workspace === "editor" && root.editorHasUnsavedChanges) {
                root.send({ type: "editor_save" });
            }
        }
    }
    Shortcut {
        sequence: "Ctrl+Shift+S"
        onActivated: {
            if (root.state.workspace === "editor") {
                root.chooseEditorSaveAs();
            }
        }
    }
    Shortcut {
        sequence: "F5"
        onActivated: root.send({ type: "refresh" })
    }
    // Workspace navigation, the same guarded path the switcher buttons take:
    // leaving the Editor with unsaved edits asks before it goes.
    Shortcut {
        sequence: "Ctrl+1"
        onActivated: root.guardEditorLeave({ workspace: "browser" })
    }
    Shortcut {
        sequence: "Ctrl+2"
        onActivated: root.guardEditorLeave({ workspace: "viewer" })
    }
    Shortcut {
        sequence: "Ctrl+3"
        onActivated: root.guardEditorLeave({ workspace: "editor" })
    }

    header: ToolBar {
        id: headerBar
        padding: 0
        background: Rectangle {
            color: appTheme.surface
        }
        contentHeight: 50

        RowLayout {
            objectName: "mainToolbarRow"
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 4

            WorkspaceSwitcher {
                objectName: "workspaceSwitcher"
                theme: appTheme
                metrics: toolbarMetrics
                showLabels: root.toolbarLabels
                workspace: root.state.workspace || "browser"
                onSelected: function(workspace) {
                    // Leaving the Editor with unsaved edits asks first; any
                    // other switch is immediate.
                    root.guardEditorLeave({ workspace: workspace });
                }
            }

            ToolbarSeparator { theme: appTheme }

            Loader {
                id: workspaceToolbar
                objectName: "workspaceToolbarLoader"
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

            CompactToolbarButton {
                objectName: "mainMenuButton"
                theme: appTheme
                metrics: toolbarMetrics
                showLabel: root.toolbarLabels
                icon.name: "open-menu-symbolic"
                text: qsTr("Menu")
                ToolTip.visible: hovered && !useText
                ToolTip.text: qsTr("Main menu")
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
                text: qsTr("%1 items · %2 images").arg(root.state.itemCount || 0).arg(root.state.imageCount || 0)
                color: appTheme.textMuted
            }

            Label {
                text: root.state.workspace || "browser"
                color: appTheme.accent
            }

            Label {
                text: qsTr("rev %1").arg(bridge.revision)
                color: appTheme.textMuted
            }

            ToolButton {
                visible: bridge.busy
                text: qsTr("Cancel")
                focusPolicy: Qt.NoFocus
                activeFocusOnTab: false
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
            onEditInEditor: function(path) {
                root.sendSequence([
                    { type: "select", paths: [path] },
                    { type: "set_workspace", workspace: "editor" },
                    { type: "editor_open", path: path }
                ]);
            }
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
            menuLabelWidths: appTheme.menuLabelWidths
            state: root.state
            entries: snapshot.entries
            viewerImages: snapshot.viewerImages
            thumbnails: typeof Thumbnails !== "undefined" ? Thumbnails : null
            onCommand: function(command) { root.send(command); }
            onCopyImage: function(path) { Platform.copyImage(path); }
            onCopyText: function(text) { Platform.copyText(text); }
            onOpenWith: function(path) { Platform.openWith(path); }
            onEditInEditor: function(path) {
                root.sendSequence([
                    { type: "select", paths: [path] },
                    { type: "set_workspace", workspace: "editor" },
                    { type: "editor_open", path: path }
                ]);
            }
            onRequestDestination: function(action, paths) {
                root.chooseDestination(action, paths);
            }
            onRequestDelete: function(paths) {
                root.pendingDelete = paths;
                deleteDialog.open();
            }
        }
    }

    Component {
        id: editorComponent
        EditorView {
            objectName: "editor"
            theme: appTheme
            state: root.state
            onCommand: function(command) { root.send(command); }
            onRequestOpen: root.chooseEditorImage()
            onRequestSaveAs: root.chooseEditorSaveAs()
        }
    }

    Menu {
        id: mainMenu
        implicitWidth: appTheme.menuWidth(appTheme.menuLabelWidths)

        MenuItem {
            text: appTheme.menuEntries[15]
            icon.name: "document-open-symbolic"
            onTriggered: root.chooseFiles()
        }
        MenuItem {
            text: appTheme.menuEntries[16]
            icon.name: "folder-open-symbolic"
            onTriggered: root.chooseFolder()
        }
        MenuSeparator {}
        MenuItem {
            text: root.state.theme === "dark" ? appTheme.menuEntries[18] : appTheme.menuEntries[19]
            icon.name: root.state.theme === "dark"
                       ? "weather-clear-symbolic"
                       : "weather-clear-night-symbolic"
            onTriggered: root.send({ type: "toggle_theme" })
        }
        MenuItem {
            text: appTheme.menuEntries[20]
            icon.name: "preferences-system-symbolic"
            onTriggered: root.openSettings()
        }
        MenuSeparator {}
        MenuItem {
            text: appTheme.menuEntries[21]
            icon.name: "application-exit-symbolic"
            onTriggered: Qt.quit()
        }
    }

    SettingsDialog {
        id: settingsDialog
        objectName: "settingsDialog"
        theme: appTheme
        /// Live preview: the window repaints with the value under the control
        /// that was just changed, before anything is saved. The theme is an
        /// ephemeral override (`previewTheme`); the language goes through the
        /// same live translator switch the menu uses.
        onPreviewRequested: function(themeName, rememberLastFolder, backgroundThumbnails, language) {
            root.previewTheme = themeName;
            if (language) root.applyInterfaceLanguage(language === "system" ? "" : language);
        }
        /// Apply (stay open) or OK (close): persist through the one command
        /// that owns these values. The preview becomes the stored value, so the
        /// override is dropped and the binding takes over again.
        onSaveRequested: function(themeName, rememberLastFolder, backgroundThumbnails, language) {
            root.previewTheme = "";
            root.send({ type: "set_settings", theme: themeName,
                        remember_last_folder: rememberLastFolder,
                        background_thumbnails: backgroundThumbnails,
                        language: language });
        }
        /// Cancel, × or Escape: nothing was written, so dropping the override
        /// is the whole undo, and the language goes back to the stored one.
        onRevertRequested: {
            root.previewTheme = "";
            root.applyInterfaceLanguage(root.state.language === "system"
                                        ? "" : (root.state.language || ""));
        }
    }

    FileDialog {
        id: fileFallback
        title: qsTr("Open images")
        fileMode: FileDialog.OpenFiles
        // One filter for every chooser, built in C++ from the protocol's list so
        // the dialog, the browser and the Editor cannot drift apart.
        nameFilters: [Platform.imageNameFilter()]
        onAccepted: {
            var paths = [];
            for (var index = 0; index < selectedFiles.length; index++) {
                paths.push(root.toLocalPath(selectedFiles[index]));
            }
            root.handleOpenedPaths(paths);
        }
        onRejected: root.choosingForEditor = false
    }

    FolderDialog {
        id: folderFallback
        title: root.folderDialogPurpose === "destination"
               ? qsTr("Choose destination folder")
               : qsTr("Open folder")
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
        title: qsTr("Delete permanently?")
        text: root.pendingDelete
              ? (qsTr("Permanently delete %1 item(s)? This cannot be undone.").arg(root.pendingDelete.length))
              : ""
        buttons: MessageDialog.Yes | MessageDialog.Cancel
        onAccepted: {
            root.send({ type: "delete_permanently", paths: root.pendingDelete || [] });
            root.pendingDelete = null;
        }
        onRejected: root.pendingDelete = null
    }

    onClosing: function(close) {
        if (root.leavingForQuit) return;
        if (root.state.workspace === "editor" && root.editorHasUnsavedChanges) {
            close.accepted = false;
            root.guardEditorLeave("quit");
        }
    }

    // The Save As chooser. It is a native dialog opened from the Editor's own
    // button; the picked path becomes one `editor_save_as` command.
    FileDialog {
        id: saveFallback
        title: qsTr("Save image as")
        fileMode: FileDialog.SaveFile
        nameFilters: Platform.saveNameFilters()
        defaultSuffix: "png"
        onAccepted: {
            var path = root.toLocalPath(selectedFile);
            if (path) root.send({ type: "editor_save_as", path: path });
        }
    }

    // Asked before leaving the Editor with edits that are not on disk, and
    // before closing the window. The answers a user needs are three — Save,
    // Discard, Cancel — while `MessageDialog` offers only Accept/Reject, and
    // `MessageDialog.Save`/`Discard` do not exist on this Qt. So the dialog is a
    // plain `Dialog` with the three buttons placed by this file.
    Dialog {
        id: unsavedDialog
        objectName: "unsavedDialog"
        title: qsTr("Unsaved changes")
        modal: true
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 420

        contentItem: ColumnLayout {
            spacing: 10

            Label {
                Layout.fillWidth: true
                text: qsTr("The editor has changes that are not saved to a file. Save them first?")
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Item { Layout.fillWidth: true }
                Button {
                    objectName: "unsavedDiscard"
                    text: qsTr("Discard")
                    onClicked: root.leaveAfterDiscard()
                }
                Button {
                    objectName: "unsavedCancel"
                    text: qsTr("Cancel")
                    onClicked: root.pendingLeave = null
                }
                Button {
                    objectName: "unsavedSave"
                    text: qsTr("Save")
                    highlighted: true
                    onClicked: root.leaveAfterSave()
                }
            }
        }
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
