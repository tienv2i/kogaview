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
    minimumHeight: 480
    visible: true
    title: qsTr("KogaView") + (bridge.profile === "dev" ? " " + qsTr("(Dev)") : "")
    color: appTheme.background

    /// Turns Core's `{ code, args }` lines into sentences in the interface
    /// language (see `UiLines.qml`).
    UiLines {
        id: uiLines
    }

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
    // A narrow window must not cut the toolbar in half. The header has three
    // modes, decided per open workspace because the switcher's three buttons
    // are part of every row:
    //
    //   "full"     width ≥ that workspace's label threshold ⇒ labels appear
    //   "compact"  width ≥ that workspace's icon row       ⇒ every icon appears
    //   "mini"     narrower                                ⇒ buttons fold
    //
    // and no window may be narrower than `minimumWindowWidth`. `ToolbarMetrics`
    // owns the measuring (`modeFor`); the shell only reads the answer. See
    // `docs/adr/0010-*.md`, ADR 0015 and ADR 0017.

    ToolbarMetrics {
        id: toolbarMetrics
    }

    /// Where a label first has room, where the icon row stops fitting, and what
    /// the window may shrink to.
    readonly property real minimumWindowWidth: toolbarMetrics.minimumWindowWidth

    /// The open workspace, or the Browser before Core has answered.
    readonly property string toolbarWorkspace: root.state.workspace || "browser"
    /// That workspace's own label and fold points, for the dev harness log and
    /// for anything that wants the numbers rather than the mode.
    readonly property real toolbarLabelThreshold:
        toolbarMetrics.labelThresholdFor(root.toolbarWorkspace)
    readonly property real toolbarFoldWidth:
        toolbarMetrics.compactRowFor(root.toolbarWorkspace)
    /// The tier the header is in: "full" (labels), "compact" (every icon) or
    /// "mini" (folded into the overflow menu).
    ///
    /// This is measured per workspace, not once for the widest one: a window
    /// wide enough for the Browser's six buttons must not fold just because the
    /// Editor, which is not on screen, carries thirteen. Switching workspace
    /// re-runs the same decision with the switcher's three buttons counted
    /// against that workspace's row (`ToolbarMetrics.modeFor`).
    readonly property string toolbarMode:
        toolbarMetrics.modeFor(root.toolbarWorkspace, root.width)
    /// True while the open workspace's row can afford labels beside the icons.
    readonly property bool toolbarLabels: root.toolbarMode === "full"
    /// True once the 3-button switcher collapses into 1 dropdown button.
    readonly property bool toolbarSwitcherCollapsed:
        root.toolbarMode === "collapsed" || root.toolbarMode === "mini"
    /// True below the collapsed row: secondary buttons fold into `⋯` and
    /// Viewer hides its `1 / N` counter.
    readonly property bool toolbarMini: root.toolbarMode === "mini"
    /// Viewer-specific progressive compaction: hide `1 / N` counter first,
    /// then fold trailing buttons one-by-one into `⋯`.
    readonly property bool toolbarViewerHideCounter:
        toolbarMetrics.viewerHideCounterFor(root.width)
    readonly property int toolbarViewerFoldCount:
        toolbarMetrics.viewerFoldCountFor(root.width)

    /// The layout on screen. Core owns the saved one (`state.layout`); while
    /// Settings is open the form edits a copy and the window draws *that*, so
    /// a checkbox or a width is a preview until Apply — the same shape the
    /// theme preview has. `null` means "the saved layout".
    property var previewLayout: null
    readonly property var activeLayout: root.previewLayout
                                        || root.state.layout
                                        || ({})
    readonly property string viewerUiMode: {
        var mode = root.activeLayout && root.activeLayout.viewerUiMode
        return (mode === "compact" || mode === "simple" || mode === "standard")
               ? mode : "simple"
    }
    readonly property bool viewerCompactActive:
        root.state.workspace === "viewer" && root.viewerUiMode === "compact"
    readonly property bool viewerSimpleActive:
        root.state.workspace === "viewer" && root.viewerUiMode === "simple"
    /// Fullscreen state for Viewer (`F11`). Independent of Compact/Simple/Standard
    /// so exiting fullscreen restores the exact prior window visibility and mode.
    property bool viewerFullscreen: false
    property int _preFullscreenVisibility: Window.Windowed

    function toggleViewerFullscreen() {
        if (root.viewerFullscreen) {
            root.viewerFullscreen = false
            root.visibility = root._preFullscreenVisibility === Window.FullScreen
                              ? Window.Windowed : root._preFullscreenVisibility
        } else {
            root._preFullscreenVisibility = root.visibility
            root.viewerFullscreen = true
            root.visibility = Window.FullScreen
        }
    }

    Connections {
        target: snapshot
        function onStateChanged() {
            if (root.viewerFullscreen && root.state.workspace !== "viewer") {
                root.toggleViewerFullscreen()
            }
        }
    }

    /// One view asked for a layout change: a splitter, the rail's columns, a
    /// reference tab, a panel from Settings. While the Settings form is open
    /// the change is only previewed; otherwise it is the saved layout, so a
    /// drag or a tab is remembered without a second Save. The patch carries
    /// only what moved; the rest is taken from the layout on screen.
    function requestLayout(patch) {
        var next = root.mergeLayout(root.activeLayout, patch)
        if (settingsDialog.visible) {
            root.previewLayout = next
            settingsDialog.adoptLayout(next)
            return
        }
        root.previewLayout = null
        root.send({ type: "set_layout", layout: next })
    }

    /// Merge a patch into a layout without sharing objects with either side:
    /// a form, a view and Core must not end up holding one map between them.
    function mergeLayout(base, patch) {
        var source = base || ({})
        var changes = patch || ({})
        var result = {
            leftWidth: changes.leftWidth !== undefined ? changes.leftWidth : source.leftWidth,
            rightWidth: changes.rightWidth !== undefined ? changes.rightWidth : source.rightWidth,
            editorToolColumns: changes.editorToolColumns !== undefined
                               ? changes.editorToolColumns : source.editorToolColumns,
            editorReferenceHeight: changes.editorReferenceHeight !== undefined
                                   ? changes.editorReferenceHeight
                                   : source.editorReferenceHeight,
            editorReferenceTab: changes.editorReferenceTab !== undefined
                                ? changes.editorReferenceTab : source.editorReferenceTab,
            // How the Browser draws a folder: a layout value, so it is
            // remembered across launches like a dock's width.
            browserView: changes.browserView !== undefined
                         ? changes.browserView : source.browserView,
            browserSortBy: changes.browserSortBy !== undefined
                           ? changes.browserSortBy : source.browserSortBy,
            browserSortOrder: changes.browserSortOrder !== undefined
                              ? changes.browserSortOrder : source.browserSortOrder,
            browserThumbSize: changes.browserThumbSize !== undefined
                              ? changes.browserThumbSize : source.browserThumbSize,
            viewerUiMode: changes.viewerUiMode !== undefined
                          ? changes.viewerUiMode : source.viewerUiMode,
            viewerDisplayMode: changes.viewerDisplayMode !== undefined
                               ? changes.viewerDisplayMode : source.viewerDisplayMode,
            mangaRtl: changes.mangaRtl !== undefined
                      ? changes.mangaRtl : source.mangaRtl,
            mangaCoverSeparate: changes.mangaCoverSeparate !== undefined
                                ? changes.mangaCoverSeparate : source.mangaCoverSeparate,
            mangaPageGap: changes.mangaPageGap !== undefined
                          ? changes.mangaPageGap : source.mangaPageGap,
            panels: {}
        }
        var panels = source.panels || ({})
        for (var key in panels) result.panels[key] = panels[key]
        var changedPanels = changes.panels || ({})
        for (var panelKey in changedPanels) result.panels[panelKey] = changedPanels[panelKey]
        return result
    }

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
        appTheme.menuShortcutWidths =
            Platform.textWidths(appTheme.menuShortcutLabels, Qt.application.font)
        menuWidthsMeasured = true
    }

    // Keep built-in controls (menus, dialogs, combo boxes, buttons, scroll
    // bars) in step with the app theme instead of the desktop's palette.
    // Written imperatively (not as grouped `palette.*:` bindings) because
    // grouped palette bindings do not re-evaluate when `appTheme.dark` flips
    // while the window is open, and synced to `QGuiApplication::setPalette` so
    // popups inherit the active theme too.
    function applyPalette() {
        root.palette.window = appTheme.background
        root.palette.windowText = appTheme.text
        root.palette.base = appTheme.surface
        root.palette.alternateBase = appTheme.surfaceAlt
        root.palette.text = appTheme.text
        root.palette.button = appTheme.surface
        root.palette.buttonText = appTheme.text
        root.palette.brightText = "#ffffff"
        root.palette.highlight = appTheme.accent
        root.palette.highlightedText = appTheme.accentText
        root.palette.toolTipBase = appTheme.surfaceAlt
        root.palette.toolTipText = appTheme.text
        root.palette.placeholderText = appTheme.textMuted
        root.palette.mid = appTheme.border
        root.palette.dark = appTheme.border
        root.palette.light = appTheme.surfaceAlt
        root.palette.shadow = appTheme.border
        if (typeof Platform !== "undefined" && Platform && Platform.applyThemePalette) {
            Platform.applyThemePalette({
                background: appTheme.background,
                surface: appTheme.surface,
                surfaceAlt: appTheme.surfaceAlt,
                text: appTheme.text,
                textMuted: appTheme.textMuted,
                accent: appTheme.accent,
                accentText: appTheme.accentText,
                border: appTheme.border
            }, appTheme.dark)
        }
    }

    Connections {
        target: appTheme
        function onDarkChanged() { root.applyPalette() }
    }

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
    /// True while a modal dialog owns the window. Qt still delivers pointer
    /// events to pointer handlers *under* a popup, so without this a drag on the
    /// Settings header reached the Viewer's pan handler: the dialog stood still
    /// while the picture slid behind it. Disabling the workspace loader is
    /// also the modal contract for the wheel, taps and clicks, not just drags.
    readonly property bool modalDialogOpen: settingsDialog.visible
                                            || batchResizeDialog.visible
                                            || batchCropDialog.visible
                                            || batchConvertDialog.visible
                                            || unsavedDialog.visible
                                            || deleteDialog.visible
                                            || fileFallback.visible
                                            || folderFallback.visible
                                            || saveFallback.visible
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
                // A rejection can be worded by the interface too: Core sends
                // `error.ui` as a `{code, args}` line for everything whose
                // cause is its own, and only leaves it out when the detail is
                // the platform's (an OS error, a bad envelope). `message` is
                // still there as the English fallback.
                if (result.error.ui && result.error.ui.code) {
                    root.showToast(uiLines.text(result.error.ui, root.state.language));
                } else {
                    root.showToast(result.error.message);
                }
            } else if (command.type !== "select" && command.type !== "set_layout") {
                // The typed line first: Core publishes `{code, args}` so the
                // toast speaks the interface language. `message` is the English
                // rendering kept for the journal and for callers without one.
                // A layout change is silent like a selection: clicking a tab or
                // releasing a splitter would otherwise announce "Layout saved"
                // on every turn. Settings still confirms with "Settings saved",
                // the command that owns the form the change came from.
                if (result.ui && result.ui.code) {
                    root.showToast(uiLines.text(result.ui, root.state.language));
                } else if (result.message) {
                    root.showToast(result.message);
                }
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
        settingsDialog.initialHardwareAcceleration = root.state.hardwareAcceleration !== false;
        settingsDialog.initialAntiAliasing = root.state.antiAliasing !== false;
        settingsDialog.initialLanguage = root.state.language || "system";
        settingsDialog.initialLayout = JSON.parse(JSON.stringify(root.state.layout || ({})));
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

    // -------------------------------------------------- clipboard shortcuts
    //
    // The context menus name these keys beside the copy entries. Ctrl and Alt
    // combinations belong to the window (a focused field must get first
    // refusal), and only the shell can read Core's selection whichever
    // workspace is up. The views keep their own menu entries; these functions
    // and those entries run the same `Platform.copyImage`/`copyText`.
    //
    // A copy is a shortcut for what the menu offers, so it does nothing where
    // the menus offer nothing: the Editor has no copy entry.

    /// Copy the pixels of the one image the current workspace is looking at.
    function copyImageContent() {
        if (root.state.workspace !== "browser" && root.state.workspace !== "viewer") return;
        var path = "";
        if (root.state.workspace === "viewer") {
            path = root.state.viewerPath || "";
        } else {
            var selection = root.state.selection || [];
            if (selection.length === 1 && root.state.selectionInfo
                    && root.state.selectionInfo.isImage) {
                path = selection[0];
            }
        }
        if (!path) {
            root.showToast(qsTr("Select one image to copy its content."));
            return;
        }
        Platform.copyImage(path);
    }

    /// Copy the path(s) the current workspace points at: the open image, the
    /// Browser's selection, or the folder the Browser is showing.
    function copySelectedPaths() {
        if (root.state.workspace !== "browser" && root.state.workspace !== "viewer") return;
        var paths = [];
        if (root.state.workspace === "viewer") {
            if (root.state.viewerPath) paths = [root.state.viewerPath];
        } else {
            paths = root.state.selection || [];
            if (paths.length === 0 && root.state.currentFolder) {
                paths = [root.state.currentFolder];
            }
        }
        if (paths.length === 0) return;
        Platform.copyText(paths.join("\n"));
    }

    /// The chooser behind the Editor's Open button and the shell menu's "Open
    /// in editor…". It uses the same portal/fallback route as `chooseFiles`, but
    /// the picked file becomes an `editor_open` command.
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
            root.requestEditorOpen(paths[0]);
        } else {
            root.send({ type: "open_file", paths: paths });
        }
    }

    /// True while the Editor holds edits that are not on disk. Every way out of
    /// the Editor asks this first.
    readonly property bool editorHasUnsavedChanges:
        !!(root.state.editor && root.state.editor.modified && !root.state.editor.saved)

    /// Open `path` in the Editor, asking about unsaved edits first.
    ///
    /// Every entry point goes through here — the Editor's Open button, the
    /// shell menu's "Open in editor…", the fallback chooser — because Core
    /// answers `unsaved_document` rather than replacing a document whose edits
    /// are not on disk. Asking is the shell's job: Core enforces the rule, the
    /// dialog is how the user answers it.
    function requestEditorOpen(path, selectFirst) {
        if (!path) return;
        // The question is about the *document*, not about the workspace it is
        // in: edits left behind in the Editor are still unsaved when the user
        // asks for another picture from the Viewer.
        if (root.editorHasUnsavedChanges) {
            root.pendingLeave = { editorOpen: path, select: !!selectFirst };
            unsavedDialog.open();
            return;
        }
        root.runEditorOpen(path, selectFirst);
    }

    /// The commands that open `path`, in the order each one needs. A chooser
    /// answered outside the Editor switches to it first; `sendSequence` keeps
    /// that order, because each command republishes the state and a workspace
    /// switch sent later would arrive too late. The prefix is also what the
    /// unsaved dialog's answers build on, so the save or the reset is sent
    /// ahead of the exact same open.
    function editorOpenCommands(path, selectFirst) {
        var commands = [];
        if (selectFirst) {
            commands.push({ type: "select", paths: [path] });
        }
        if (root.state.workspace !== "editor") {
            commands.push({ type: "set_workspace", workspace: "editor" });
        }
        commands.push({ type: "editor_open", path: path });
        return commands;
    }

    function runEditorOpen(path, selectFirst) {
        root.sendSequence(root.editorOpenCommands(path, selectFirst));
    }

    /// Which save chooser is waiting for an answer: "document" (Save as…), or
    /// "export" (Export a copy…'s Browse). A portal answer arrives as one
    /// signal with a path, so the shell has to remember what it asked.
    property string pendingSave: ""

    /// The answer to either save chooser, from the portal or from the Qt
    /// fallback. Both dialogs send it here so the two routes cannot drift.
    function handleSaveFileChosen(path) {
        var purpose = root.pendingSave;
        root.pendingSave = "";
        if (!path) return;
        if (purpose === "export") {
            var editor = workspaceLoader.item;
            if (editor && editor.applyExportPath) editor.applyExportPath(path);
        } else {
            root.send({ type: "editor_save_as", path: path });
        }
    }

    /// Save As: the chooser suggests where the document would go now. The
    /// dialog is opened from the Editor's button; the chosen path becomes
    /// `editor_save_as`.
    ///
    /// The desktop's own dialog is asked first (`FileChooser.SaveFile`) — the
    /// same `xdg-desktop-portal` window every *open* chooser in this window
    /// uses. Save as was the one chooser that went straight to the Qt
    /// `FileDialog`, so the user met the platform's stripped-down dialog with
    /// a file-type combo here and the desktop's own everywhere else.
    function chooseEditorSaveAs() {
        var editor = workspaceLoader.item;
        var path = editor && editor.saveAsPath ? editor.saveAsPath : "";
        root.pendingSave = "document";
        if (Platform.requestSaveFile(qsTr("Save image as"), path)) return;
        root.pendingSave = "";
        saveFallback.currentFile = "file://" + path;
        saveFallback.open();
    }

    /// Export's Browse: the chooser suggests the same delivery name the dialog
    /// opened on, and its answer is written back into that dialog's field.
    function chooseEditorExportPath() {
        var editor = workspaceLoader.item;
        var path = editor && editor.exportPath ? editor.exportPath : "";
        root.pendingSave = "export";
        if (Platform.requestSaveFile(qsTr("Export image as"), path)) return;
        root.pendingSave = "";
        exportFallback.currentFile = "file://" + path;
        exportFallback.open()
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
                ? []
                : (leave && leave.editorOpen
                   ? root.editorOpenCommands(leave.editorOpen, leave.select)
                   : [ leave && leave.workspace
                       ? { type: "set_workspace", workspace: leave.workspace }
                       : { type: "editor_close" } ]);
        root.sendSequence([{ type: "editor_save" }].concat(following));
        if (leave === "quit") Qt.callLater(function() { root.runLeave("quit"); });
    }
    /// The dialog's Discard answer: drop the edits and go. Dropping them is a
    /// command of its own (`editor_reset`), not just a disappearance of the
    /// question: the document stays open, and without the reset Core would
    /// still consider it edited and would refuse to replace it with the
    /// picture the Viewer shows next. Quitting skips the reset — nothing
    /// survives the window.
    function leaveAfterDiscard() {
        var leave = root.pendingLeave;
        root.pendingLeave = null;
        unsavedDialog.close();
        if (leave === "quit") {
            root.runLeave("quit");
            return;
        }
        var following = leave && leave.editorOpen
                ? root.editorOpenCommands(leave.editorOpen, leave.select)
                : [ leave && leave.workspace
                    ? { type: "set_workspace", workspace: leave.workspace }
                    : (leave && leave.close ? { type: "editor_close" } : null) ];
        // Leaving the Editor for another workspace keeps the document open, so
        // the edits have to be reverted for real. Closing the document drops it
        // anyway. An open replaces the document too, but Core refuses to do so
        // while the document is dirty, so the reset has to come first.
        if (leave && (leave.workspace || leave.editorOpen)) {
            root.sendSequence([{ type: "editor_reset" }].concat(following));
        } else if (following[0]) {
            root.send(following[0]);
        }
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

    // ---------------------------------------------------------------- batch
    //
    // One dialog per batch action, and one page that names all three. The
    // Browser's Batch page asks for a form by naming its action; the shell's
    // Tools entry opens that page. A form only formats the command; Core
    // resolves the folder, validates the job and publishes its progress, which
    // the page draws.

    /// The selected paths that are images, in the selection's order.
    function batchSelectionPaths() {
        var selection = root.state.selection || [];
        var entries = snapshot.entries || [];
        var paths = [];
        for (var index = 0; index < selection.length; ++index) {
            for (var entry = 0; entry < entries.length; ++entry) {
                if (entries[entry].path === selection[index]) {
                    if (entries[entry].isImage) paths.push(entries[entry].path);
                    break;
                }
            }
        }
        return paths;
    }

    /// The first image a job would process, so the size form opens on a real
    /// picture's shape instead of a guess.
    function batchSample(selection) {
        var entries = snapshot.entries || [];
        var wanted = selection || [];
        for (var index = 0; index < wanted.length; ++index) {
            for (var entry = 0; entry < entries.length; ++entry) {
                if (entries[entry].path === wanted[index] && entries[entry].isImage) {
                    return entries[entry];
                }
            }
        }
        for (var fallback = 0; fallback < entries.length; ++fallback) {
            if (entries[fallback].isImage) return entries[fallback];
        }
        return null;
    }

    /// The dialog that asks for `operation`: one per batch action, each with
    /// its own title and its own options (`BatchResizeDialog`, `BatchCropDialog`,
    /// `BatchConvertDialog`). An unknown or empty name is the first action, so
    /// the Tools… entry — which names no action — has something to open.
    function batchDialogFor(operation) {
        switch (operation) {
        case "crop": return batchCropDialog
        case "convert": return batchConvertDialog
        default: return batchResizeDialog
        }
    }

    /// The Tools… entry: the page that names all three batch tools — and that
    /// draws a running job's progress — not one of the forms. The entry says
    /// "Tools…", so it should not decide which tool the user wants; the page's
    /// own Resize…, Crop… and Convert… buttons open the three dialogs.
    function openBatchTools() {
        if (root.state.workspace !== "browser") return;
        var browser = workspaceLoader.item;
        if (browser && browser.showBatchPage) browser.showBatchPage();
    }

    function openBatchDialog(operation) {
        if (root.state.workspace !== "browser") return;
        var dialog = root.batchDialogFor(operation);
        var selection = root.batchSelectionPaths();
        dialog.selectionPaths = selection;
        dialog.currentFolder = root.state.currentFolder || "";
        var sample = root.batchSample(selection);
        dialog.sampleWidth = sample ? (sample.width || 0) : 0;
        dialog.sampleHeight = sample ? (sample.height || 0) : 0;
        dialog.open();
    }

    /// A form's Run: one `batch_run`, then the page that draws Core's progress
    /// for it. The three dialogs share this so none of them can forget the page.
    function startBatchJob(command) {
        root.send(command);
        var browser = workspaceLoader.item;
        if (browser && browser.showBatchPage) browser.showBatchPage();
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
    readonly property bool viewerFilmstripWillShow:
        root.viewerUiMode === "standard"
        && (root.activeLayout.viewerDisplayMode || "single") !== "webtoon"
        && !!root.state.filmstrip
        && (snapshot.viewerImages || []).length > 1
    readonly property bool viewerRightDockWillShow:
        root.viewerUiMode === "standard"
        && !(root.activeLayout.panels && root.activeLayout.panels["viewer.info"] === false)
    readonly property int viewerChromeHeight:
        (root.viewerUiMode === "compact" ? 0 : 50)
        + (root.viewerUiMode === "standard" ? 32 : 0)
        + (root.viewerFilmstripWillShow ? 106 : 0)
        + 16
    readonly property int viewerChromeWidth:
        (root.viewerRightDockWillShow
         ? (Math.max(200, Math.min(640, root.activeLayout.rightWidth || appTheme.previewWidth)) + 4)
         : 0)
        + 16

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
        root.applyPalette();
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
        function onSaveFileSelected(path) {
            root.handleSaveFileChosen(path);
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
    // The keys the context menus name for their copy entries. They follow the
    // same rule as the shortcuts above: the window, not a view, owns Ctrl/Alt,
    // so a focused text field keeps its own Ctrl+C. A modal dialog owns the
    // keyboard while it is up, so the copy keys wait.
    Shortcut {
        sequence: "Ctrl+Shift+C"
        enabled: !root.modalDialogOpen
        onActivated: root.copyImageContent()
    }
    Shortcut {
        sequence: "Ctrl+Alt+C"
        enabled: !root.modalDialogOpen
        onActivated: root.copySelectedPaths()
    }
    // The Editor's size form is a question, not a mode, so its key belongs to
    // the window: it opens from anywhere in the Editor and the form itself
    // selects the Width field. A shell modal still owns the keyboard first.
    Shortcut {
        sequence: "Ctrl+Alt+I"
        enabled: !root.modalDialogOpen && root.state.workspace === "editor"
        onActivated: {
            var editor = workspaceLoader.item
            if (editor && editor.openResizeDialog) editor.openResizeDialog()
        }
    }

    Shortcut {
        sequence: "F11"
        enabled: !root.modalDialogOpen && root.state.workspace === "viewer"
        onActivated: root.toggleViewerFullscreen()
    }

    header: ToolBar {
        id: headerBar
        objectName: "mainHeaderBar"
        visible: !root.viewerCompactActive && !root.viewerFullscreen
        implicitHeight: visible ? 50 : 0
        height: visible ? 50 : 0
        padding: 0
        background: Rectangle {
            color: appTheme.surface
        }
        contentHeight: visible ? 50 : 0

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
                collapsed: root.toolbarSwitcherCollapsed
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
                onClicked: mainMenu.toggleFrom(this)
            }
        }
    }

    footer: ToolBar {
        id: footerBar
        objectName: "mainFooterBar"
        visible: !root.viewerCompactActive && !root.viewerSimpleActive && !root.viewerFullscreen
        implicitHeight: visible ? 32 : 0
        height: visible ? 32 : 0
        padding: 0
        background: Rectangle {
            color: appTheme.surface
        }
        contentHeight: visible ? 32 : 0

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10

            Label {
                text: uiLines.text(root.state.status, root.state.language)
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
        // A modal dialog owns the pointer. Pointer handlers are not occluded by
        // a popup (the Settings header drag used to pan the Viewer instead), so
        // the workspace has to be switched off while one is open. Focus returns
        // to the view when the loader comes back; `aModalDialogOwnsThePointer`
        // pins that down.
        enabled: !root.modalDialogOpen
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
            menuShortcutWidths: appTheme.menuShortcutWidths
            miniToolbar: root.toolbarMini
            state: root.state
            entries: snapshot.entries
            thumbnails: typeof Thumbnails !== "undefined" ? Thumbnails : null
            listFolders: root.listFolders
            layout: root.activeLayout
            onLayoutRequested: function(patch) { root.requestLayout(patch) }
            onRevealPath: function(path) { Platform.revealInFolder(path); }
            onCommand: function(command) { root.send(command); }
            onToast: function(message) { root.showToast(message); }
            onCopyImage: function(path) { Platform.copyImage(path); }
            onCopyText: function(text) { Platform.copyText(text); }
            onOpenExternal: function(path) { Platform.openExternally(path); }
            onOpenWith: function(path) { Platform.openWith(path); }
            onEditInEditor: function(path) {
                root.requestEditorOpen(path, true);
            }
            onRequestDestination: function(action, paths) {
                root.chooseDestination(action, paths);
            }
            onRequestDelete: function(paths) {
                root.pendingDelete = paths;
                deleteDialog.open();
            }
            onRequestOpenFolder: root.chooseFolder()
            onRequestBatch: function(mode) { root.openBatchDialog(mode) }
        }
    }

    Component {
        id: viewerComponent
        Viewer {
            objectName: "viewer"
            theme: appTheme
            menuLabelWidths: appTheme.menuLabelWidths
            menuShortcutWidths: appTheme.menuShortcutWidths
            miniToolbar: root.toolbarViewerFoldCount > 0
            hideCounter: root.toolbarViewerHideCounter
            toolbarFoldCount: root.toolbarViewerFoldCount
            state: root.state
            entries: snapshot.entries
            viewerImages: snapshot.viewerImages
            thumbnails: typeof Thumbnails !== "undefined" ? Thumbnails : null
            listFolders: root.listFolders
            layout: root.activeLayout
            fullscreen: root.viewerFullscreen
            onToggleFullscreen: root.toggleViewerFullscreen()
            onLayoutRequested: function(patch) { root.requestLayout(patch) }
            onRevealPath: function(path) { Platform.revealInFolder(path); }
            onCommand: function(command) { root.send(command); }
            onCopyImage: function(path) { Platform.copyImage(path); }
            onCopyText: function(text) { Platform.copyText(text); }
            onOpenWith: function(path) { Platform.openWith(path); }
            onEditInEditor: function(path) {
                root.requestEditorOpen(path, true);
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
            miniToolbar: root.toolbarMini
            state: root.state
            thumbnails: typeof Thumbnails !== "undefined" ? Thumbnails : null
            listFolders: root.listFolders
            layout: root.activeLayout
            onLayoutRequested: function(patch) { root.requestLayout(patch) }
            onRevealPath: function(path) { Platform.revealInFolder(path); }
            onCommand: function(command) { root.send(command); }
            onRequestOpen: root.chooseEditorImage()
            onRequestSaveAs: root.chooseEditorSaveAs()
            onRequestExportPath: root.chooseEditorExportPath()
        }
    }

    AppMenu {
        id: mainMenu
        objectName: "mainMenu"
        theme: appTheme
        implicitWidth: appTheme.menuWidth(appTheme.menuLabelWidths,
                                          appTheme.menuShortcutWidths)

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
        MenuItem {
            text: appTheme.menuEntries[29]
            icon.name: "document-edit-symbolic"
            onTriggered: root.chooseEditorImage()
        }
        MenuSeparator {}
        MenuItem {
            text: root.state.theme === "dark" ? appTheme.menuEntries[17] : appTheme.menuEntries[18]
            icon.name: root.state.theme === "dark"
                       ? "weather-clear-symbolic"
                       : "weather-clear-night-symbolic"
            onTriggered: root.send({ type: "toggle_theme" })
        }
        MenuItem {
            text: appTheme.menuEntries[19]
            icon.name: "preferences-system-symbolic"
            onTriggered: root.openSettings()
        }
        MenuSeparator {}
        MenuItem {
            text: appTheme.menuEntries[20]
            icon.name: "application-exit-symbolic"
            onTriggered: Qt.quit()
        }
    }

    /// The three batch forms: one per action, each with its own title and its
    /// own options, sharing `BatchJobDialog`'s input/output/policy half so the
    /// three cannot disagree about where images come from or results go. They
    /// live in the shell, not in the Browser, so the window can make them modal
    /// for the whole workspace (`modalDialogOpen`) while the dialog itself stays
    /// interactive. The Browser's Batch page names which one to open.
    BatchResizeDialog {
        id: batchResizeDialog
        objectName: "batchResizeDialog"
        theme: appTheme
        onRunRequested: function(command) { root.startBatchJob(command) }
    }

    BatchCropDialog {
        id: batchCropDialog
        objectName: "batchCropDialog"
        theme: appTheme
        onRunRequested: function(command) { root.startBatchJob(command) }
    }

    BatchConvertDialog {
        id: batchConvertDialog
        objectName: "batchConvertDialog"
        theme: appTheme
        onRunRequested: function(command) { root.startBatchJob(command) }
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
        onLayoutPreviewRequested: function(layout) {
            root.previewLayout = JSON.parse(JSON.stringify(layout));
        }
        /// Apply (stay open) or OK (close): persist through the one command
        /// that owns these values. The preview becomes the stored value, so the
        /// override is dropped and the binding takes over again.
        onSaveRequested: function(themeName, rememberLastFolder, backgroundThumbnails, language) {
            root.previewTheme = "";
            root.send({ type: "set_settings", theme: themeName,
                        remember_last_folder: rememberLastFolder,
                        background_thumbnails: backgroundThumbnails,
                        hardware_acceleration: settingsDialog.hardwareAccelerationValue,
                        anti_aliasing: settingsDialog.antiAliasingValue,
                        language: language });
        }
        onLayoutSaveRequested: function(layout) {
            root.previewLayout = null;
            root.send({ type: "set_layout", layout: layout });
        }
        /// Cancel, × or Escape: nothing was written, so dropping the override
        /// is the whole undo, and the language goes back to the stored one.
        onRevertRequested: {
            root.previewTheme = "";
            root.previewLayout = null;
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

    /// A destructive question, asked in the same frame as every other form: a
    /// `MessageDialog` would draw the system's "Yes"/"Cancel", which a machine
    /// without `qtbase_<locale>.qm` renders in English inside a Vietnamese
    /// window — and "Yes" does not say what it will do.
    DialogFrame {
        id: deleteDialog
        objectName: "deleteDialog"
        namePrefix: "delete"
        title: qsTr("Delete permanently?")
        preferredWidth: 420

        /// Escape and the × cancel: a destructive answer is given only by
        /// naming it.
        onCloseRequested: {
            root.pendingDelete = null;
            deleteDialog.close();
        }
        onClosed: root.pendingDelete = null

        Label {
            Layout.fillWidth: true
            text: root.pendingDelete
                  ? (qsTr("Permanently delete %1 item(s)? This cannot be undone.").arg(root.pendingDelete.length))
                  : ""
            color: appTheme.text
            wrapMode: Text.WordWrap
        }

        footer: DialogFooter {
            namePrefix: "delete"
            theme: appTheme
            height: deleteDialog.footerHeight

            Item { Layout.fillWidth: true }
            PanelAction {
                objectName: "deleteCancel"
                theme: appTheme
                text: qsTr("Cancel")
                implicitWidth: 88
                onClicked: {
                    root.pendingDelete = null;
                    deleteDialog.close();
                }
            }
            PanelAction {
                objectName: "deleteConfirm"
                theme: appTheme
                text: qsTr("Delete")
                implicitWidth: 88
                primary: true
                onClicked: {
                    root.send({ type: "delete_permanently", paths: root.pendingDelete || [] });
                    root.pendingDelete = null;
                    deleteDialog.close();
                }
            }
        }
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
        onAccepted: root.handleSaveFileChosen(root.toLocalPath(selectedFile))
        onRejected: root.pendingSave = ""
    }

    // Export picks a destination only; the quality and metadata live in the
    // Editor's own dialog, which the chosen path is written back into.
    FileDialog {
        id: exportFallback
        objectName: "exportFallback"
        title: qsTr("Export image as")
        fileMode: FileDialog.SaveFile
        nameFilters: Platform.saveNameFilters()
        defaultSuffix: "jpg"
        onAccepted: root.handleSaveFileChosen(root.toLocalPath(selectedFile))
        onRejected: root.pendingSave = ""
    }

    // Asked before leaving the Editor with edits that are not on disk, and
    // before closing the window. The answers a user needs are three — Save,
    // Discard, Cancel — while `MessageDialog` offers only Accept/Reject, and
    // `MessageDialog.Save`/`Discard` do not exist on this Qt. So the dialog is a
    // plain `Dialog` with the three buttons placed by this file.
    DialogFrame {
        id: unsavedDialog
        objectName: "unsavedDialog"
        namePrefix: "unsaved"
        title: qsTr("Unsaved changes")
        preferredWidth: 420
        // Cancel and Escape both mean "stay here": no command, and no stale
        // answer left for the next question.
        onCloseRequested: unsavedDialog.close()
        onClosed: root.pendingLeave = null

        Label {
            Layout.fillWidth: true
            text: qsTr("The editor has changes that are not saved to a file. Save them first?")
            color: appTheme.text
            wrapMode: Text.WordWrap
        }

        footer: DialogFooter {
            namePrefix: "unsaved"
            theme: appTheme
            height: unsavedDialog.footerHeight

            Item { Layout.fillWidth: true }
            PanelAction {
                objectName: "unsavedDiscard"
                theme: appTheme
                text: qsTr("Discard")
                implicitWidth: 88
                onClicked: root.leaveAfterDiscard()
            }
            PanelAction {
                objectName: "unsavedCancel"
                theme: appTheme
                text: qsTr("Cancel")
                implicitWidth: 88
                onClicked: unsavedDialog.close()
            }
            PanelAction {
                objectName: "unsavedSave"
                theme: appTheme
                text: qsTr("Save")
                implicitWidth: 88
                primary: true
                onClicked: root.leaveAfterSave()
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
