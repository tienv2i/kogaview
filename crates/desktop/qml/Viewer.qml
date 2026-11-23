import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts

Item {
    id: view

    property Theme theme: Theme {}
    property var state: ({})
    /// The folder listing, published apart from `state` so that an unchanged
    /// listing keeps the same arrays between snapshots.
    property var entries: []
    property var viewerImages: []
    /// The `Thumbnails` context object (C++ `ThumbnailCache`). Null in the QML
    /// test harness, where the filmstrip decodes the originals as before.
    property var thumbnails: null
    /// The folder tree's listing: C++ in the app, a stub in the QML suite.
    property var listFolders: function(path) { return { ok: false, folders: [] }; }

    /// The filmstrip tiles are drawn from the cache, so it needs each file's
    /// size and mtime for the key; `viewerImages` carries paths only, so they
    /// come from the folder listing. Rebuilt once per state update.
    property var imageMeta: {
        var map = {};
        var list = view.entries || [];
        for (var index = 0; index < list.length; ++index) {
            var entry = list[index];
            if (entry && entry.isImage) map[entry.path] = entry;
        }
        return map;
    }

    ThumbnailBook {
        id: thumbs
        cache: view.thumbnails
    }

    FolderMenu {
        id: folderMenu
        theme: view.theme
        onOpenInBrowser: view.command({ type: "open_folder", path: folderMenu.path })
        onReveal: view.revealPath(folderMenu.path)
    }

    function openFolderMenu(path) {
        folderMenu.path = path
        folderMenu.popup()
    }

    property alias zoom: viewport.zoom
    property alias offsetX: viewport.offsetX
    property alias offsetY: viewport.offsetY
    // `rotation` is already an Item property; the image rotation must not
    // shadow it, or the whole workspace would rotate.
    property int rotationAngle: 0
    property bool flipH: false
    property bool flipV: false
    /// Fit-to-window as a *mode*, not a one-shot. While it is on, the picture
    /// is re-fitted whenever the viewport, the image or its rotation changes,
    /// so resizing the window keeps the whole picture inside the new area.
    /// Any deliberate zoom (wheel, buttons, 100 %) turns it off, and `fit()`
    /// turns it back on.
    property alias autoFit: viewport.autoFit

    /// True when the picture is smaller than the viewport, so fitting leaves
    /// it at its natural size instead of blowing it up. It drives a quiet one
    /// line of guidance; `fit()` never enlarges past 100 % (see
    /// `docs/adr/0010-earned-labels-and-picture-sized-windows.md`), because a
    /// 300×200 photo stretched to fill a 1500×900 window is blurry and reads
    /// as a broken viewer.
    readonly property bool imageSmallerThanViewport:
        image.status === Image.Ready
        && viewport.width > 0 && viewport.height > 0
        && (fittedZoom() >= 1)
    /// The zoom as a whole percentage, for the footer readout: an image opened
    /// fitted at 32 % must say so.
    readonly property int zoomPercent: Math.round(view.zoom * 100)
    readonly property bool zoomIsNotActual: Math.abs(view.zoom - 1) > 0.005

    /// The filmstrip is shown when the user asked for it *and* there is a
    /// strip worth showing: a folder with one image has nothing to scroll.
    readonly property bool filmstripShown: !!view.state.filmstrip && view.images.length > 1

    signal command(var command)
    /// The canvas menu's shell-side actions. The view only says *what* the user
    /// asked for; the shell owns the platform calls (clipboard, application
    /// chooser, destination picker, delete confirmation), exactly as it does for
    /// the browser's menus.
    signal copyImage(string path)
    signal copyText(string text)
    signal openWith(string path)
    /// Open the current image in the Editor; the shell batches the three
    /// commands (see `BrowserView.editInEditor`).
    signal editInEditor(string path)
    signal requestDestination(string action, var paths)
    signal requestDelete(var paths)
    /// Ask the shell to select the file in the desktop's file manager.
    signal revealPath(string path)
    /// A layout interaction — a splitter, a panel from Settings' Appearance
    /// tab — as a patch the shell merges into the saved layout.
    signal layoutRequested(var patch)

    /// Keyboard ownership. The viewing area is the window's focus target while
    /// this workspace is up, so the shortcuts below reach the view instead of a
    /// toolbar button (those refuse focus) or the Loader. Opening a popup or a
    /// dialog moves focus to it and the keys go there until it closes.
    focus: true

    /// The widths `Main.qml` measured for `Theme.menuEntryLabels` and for the
    /// key column (`Theme.menuShortcutLabels`), so the canvas menu is as wide as
    /// the longest label it can show instead of the style's fixed 200 px. Empty
    /// in the QML harness, where the theme's floor applies.
    property var menuLabelWidths: []
    property var menuShortcutWidths: []
    property real menuWidth: theme.menuWidth(menuLabelWidths, menuShortcutWidths)
    /// True while the window is below the full icon row (`Main.qml`): the
    /// toolbar keeps its navigation and folds the rest into `viewerOverflowMenu`.
    property bool miniToolbar: false

    /// The saved layout. The shell owns one copy for the three workspaces; a
    /// view reports an interaction and never writes it.
    property var layout: ({})
    readonly property var panels: view.layout.panels || ({})
    function panelShown(key) { return view.panels[key] !== false }
    readonly property bool quickAccessShown: view.panelShown("viewer.quickAccess")
    readonly property bool explorerShown: view.panelShown("viewer.explorer")
    readonly property bool leftDockShown: view.quickAccessShown || view.explorerShown
    readonly property bool infoPanelVisible: view.panelShown("viewer.info")
    readonly property bool sidebarShown: view.infoPanelVisible

    // Widths: the saved layout is the source; a drag keeps a local value while
    // the pointer is down and the shell saves the result once it comes up.
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
    readonly property real dockWidth:
        Math.max(200, Math.min(640, rightPanelWidth))

    /// Settings' Appearance tab toggled one of this workspace's panels. The
    /// layout is Core's, so the view only says which key changed.
    function setPanelVisible(key, visible) {
        var patch = { panels: {} }
        if (key === "info") patch.panels["viewer.info"] = visible
        else if (key === "quickAccess") patch.panels["viewer.quickAccess"] = visible
        else if (key === "explorer") patch.panels["viewer.explorer"] = visible
        else return
        view.layoutRequested(patch)
    }

    property string currentPath: view.state.viewerPath || ""
    property var images: view.viewerImages || []
    property int imageIndex: (view.state.viewerIndex === undefined
                              || view.state.viewerIndex === null)
                             ? -1 : view.state.viewerIndex

    /// The open image described the way `InfoPanel` expects a selection: the
    /// folder listing carries its size and time, and the decoded picture its
    /// dimensions. Null when nothing is open.
    readonly property var currentInfo: {
        if (!view.currentPath) return null
        var meta = view.imageMeta[view.currentPath] || null
        var name = view.currentPath.split("/").pop()
        var dot = name.lastIndexOf(".")
        var extension = dot > 0 ? name.substring(dot).toLowerCase() : ""
        return {
            path: view.currentPath,
            name: name,
            kind: extension,
            size: meta ? meta.size : 0,
            modified: meta ? meta.modified : 0,
            isImage: true,
            width: image.status === Image.Ready ? image.implicitWidth : 0,
            height: image.status === Image.Ready ? image.implicitHeight : 0
        }
    }

    function setZoom(value) { viewport.setZoom(value) }
    function zoomAt(factor, pointX, pointY) { viewport.zoomAt(factor, pointX, pointY) }
    function zoomIn() { viewport.zoomIn() }
    function zoomOut() { viewport.zoomOut() }
    function fit() { viewport.fit() }
    function fittedZoom() { return viewport.fittedZoom() }
    function refitOrClamp() { viewport.refitOrClamp() }
    function clampOffsets() { viewport.clampOffsets() }
    function actualSize() { viewport.actualSize() }

    function rotateLeft() {
        view.rotationAngle = (view.rotationAngle + 270) % 360;
    }

    function rotateRight() {
        view.rotationAngle = (view.rotationAngle + 90) % 360;
    }

    function toggleFlipH() {
        view.flipH = !view.flipH;
    }

    function toggleFlipV() {
        view.flipV = !view.flipV;
    }

    /// Reset zoom, pan, rotation and flip back to the fitted default view.
    function resetView() {
        view.rotationAngle = 0;
        view.flipH = false;
        view.flipV = false;
        view.fit();
    }

    /// Nudge the picture with the arrow keys. Only meaningful when the zoomed
    /// picture is larger than the viewport; `clampOffsets()` decides that, so a
    /// fitted picture simply stays centred.
    function panBy(dx, dy) { viewport.panBy(dx, dy) }

    /// Ask Core for the neighbouring image. The Viewer only translates the key;
    /// `viewer_previous`/`viewer_next` own the wrap-around and the state.
    function stepImage(delta) {
        if (view.images.length === 0) {
            return;
        }
        view.command({ type: delta < 0 ? "viewer_previous" : "viewer_next" });
    }

    /// Jump to an index in the folder without stepping through every file.
    function openImageAt(index) {
        if (index < 0 || index >= view.images.length) {
            return;
        }
        view.command({ type: "viewer_open", path: view.images[index] });
    }

    function backToBrowser() {
        view.command({ type: "set_workspace", workspace: "browser" });
    }

    // Turning a picture swaps the sides that must fit, so a fitted view has to
    // be refitted even though the image itself did not change.
    onRotationAngleChanged: view.refitOrClamp()
    // Resizing the window is the common case: the picture must stay whole.
    // These handlers fire on every frame of a drag, and `fit()` only writes
    // properties, so there is no binding loop to worry about.
    onWidthChanged: view.refitOrClamp()
    onHeightChanged: view.refitOrClamp()

    onCurrentPathChanged: {
        view.autoFit = true;
        view.rotationAngle = 0;
        view.flipH = false;
        view.flipV = false;
        view.zoom = 1;
        view.offsetX = 0;
        view.offsetY = 0;
    }

    // ------------------------------------------------------------- keyboard
    //
    // The map is the one a desktop image viewer teaches: arrows/PageUp/PageDown
    // walk the folder, +/− zoom, 0/1 show actual size, F fits, R turns, H/V
    // flip, T toggles the filmstrip, Delete trashes, Escape/Backspace returns to
    // the Browser. Up/Down pan instead of walking, because a zoomed picture is
    // looked at more often than the folder is stepped through vertically.
    //
    // Ctrl and Alt combinations are left alone: `Main.qml` owns those window
    // shortcuts (Ctrl+O, Ctrl+S, …) and a view must not swallow them. `event.
    // isAutoRepeat` is honoured for the destructive key only — holding Delete
    // must not empty the folder.
    Keys.onPressed: function(event) {
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        if ((event.modifiers & Qt.ControlModifier) !== 0
                || (event.modifiers & Qt.AltModifier) !== 0) {
            return;
        }
        var hasImage = !!view.currentPath;
        switch (event.key) {
        case Qt.Key_Left:
        case Qt.Key_PageUp:
            view.stepImage(-1);
            event.accepted = true;
            break;
        case Qt.Key_Right:
        case Qt.Key_PageDown:
            view.stepImage(1);
            event.accepted = true;
            break;
        case Qt.Key_Space:
            // Shift+Space walks backwards, the convention in every viewer that
            // offers Space as "next".
            view.stepImage(shift ? -1 : 1);
            event.accepted = true;
            break;
        case Qt.Key_Home:
            view.openImageAt(0);
            event.accepted = true;
            break;
        case Qt.Key_End:
            view.openImageAt(view.images.length - 1);
            event.accepted = true;
            break;
        case Qt.Key_Up:
            if (hasImage) {
                view.panBy(0, 60);
                event.accepted = true;
            }
            break;
        case Qt.Key_Down:
            if (hasImage) {
                view.panBy(0, -60);
                event.accepted = true;
            }
            break;
        case Qt.Key_Plus:
        case Qt.Key_Equal:
            if (hasImage) {
                view.zoomIn();
                event.accepted = true;
            }
            break;
        case Qt.Key_Minus:
        case Qt.Key_Underscore:
            if (hasImage) {
                view.zoomOut();
                event.accepted = true;
            }
            break;
        case Qt.Key_0:
        case Qt.Key_1:
            if (hasImage) {
                view.actualSize();
                event.accepted = true;
            }
            break;
        case Qt.Key_F:
            if (hasImage) {
                view.fit();
                event.accepted = true;
            }
            break;
        case Qt.Key_R:
            if (hasImage) {
                if (shift) view.rotateLeft();
                else view.rotateRight();
                event.accepted = true;
            }
            break;
        case Qt.Key_H:
            if (hasImage) {
                view.toggleFlipH();
                event.accepted = true;
            }
            break;
        case Qt.Key_V:
            if (hasImage) {
                view.toggleFlipV();
                event.accepted = true;
            }
            break;
        case Qt.Key_T:
            view.command({ type: "toggle_filmstrip" });
            event.accepted = true;
            break;
        case Qt.Key_Delete:
            if (hasImage && !event.isAutoRepeat) {
                view.command({ type: "trash", paths: [view.currentPath] });
                event.accepted = true;
            }
            break;
        case Qt.Key_Escape:
        case Qt.Key_Backspace:
            view.backToBrowser();
            event.accepted = true;
            break;
        default:
            break;
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // The files: the same two panels the Browser shows. A folder click
        // here opens it in the Browser — the Viewer is about one picture, and
        // silently re-rooting it would change what "previous/next" means.
        LeftDock {
            objectName: "viewerLeftPanel"
            visible: view.leftDockShown
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            theme: view.theme
            state: view.state
            quickAccessShown: view.quickAccessShown
            explorerShown: view.explorerShown
            listFolders: view.listFolders
            onOpenFolder: function(path) { view.command({ type: "open_folder", path: path }) }
            onNavigateTo: function(path) { view.command({ type: "open_folder", path: path }) }
            onOpenMenu: function(path) { view.openFolderMenu(path) }
            onQuickMenu: function(path) { view.openFolderMenu(path) }
        }

        PanelSplitter {
            objectName: "viewerLeftSplitter"
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

        // The picture and its filmstrip share the centre column; the right
        // dock is a fourth column and can be revealed or hidden in Settings.
        ColumnLayout {
            // A layout child, not an anchored one: `anchors.fill` would make
            // this column cover the left dock declared before it, leaving the
            // panel visible in its properties and nowhere on screen.
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ImageCanvas {
                id: viewport
                objectName: "viewerViewport"
                wheelHandlerName: "viewerWheelHandler"
                panHandlerName: "viewerPanHandler"
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: view.canvasBgUseTheme
                       ? view.theme.background
                       : (view.canvasBgChecker ? "transparent" : view.canvasBgColor)
                hasContent: !!view.currentPath && image.implicitWidth > 0 && image.implicitHeight > 0
                contentWidth: image.implicitWidth
                contentHeight: image.implicitHeight
                minZoom: 0.05
                maxZoom: 16
                fitPadding: 0
                fitScaleFactor: 0.98
                fitCapAtOne: true
                clampOnZoom: false
                // Free pan in Viewer (always behaves like Hand tool without a separate mode).
                panMargin: Math.max(64, Math.round(Math.min(width, height) * 0.35))
                inputBlocked: viewerBgColorDialog.visible
                rotationAngle: view.rotationAngle
                flipH: view.flipH
                flipV: view.flipV
                allowLeftPan: true
                allowMiddlePan: true
                allowDoubleTapZoom: true

                Checkerboard {
                    objectName: "viewerViewportCheckerboard"
                    anchors.fill: parent
                    square: 12
                    visible: !view.canvasBgUseTheme && view.canvasBgChecker
                }

                Item {
                    id: canvas
                    objectName: "viewerCanvas"
                    width: Math.max(1, image.implicitWidth)
                    height: Math.max(1, image.implicitHeight)
                    scale: viewport.zoom
                    rotation: view.rotationAngle
                    x: viewport.itemX
                    y: viewport.itemY

                    transform: Scale {
                        origin.x: canvas.width / 2
                        origin.y: canvas.height / 2
                        xScale: view.flipH ? -1 : 1
                        yScale: view.flipV ? -1 : 1
                    }

                    Image {
                        id: image
                        objectName: "viewerImage"
                        anchors.fill: parent
                        source: view.currentPath
                                ? "file://" + view.currentPath
                                  + "?v=" + view.state.viewerModified + "-" + view.state.viewerSize
                                : ""
                        asynchronous: true
                        cache: false
                        fillMode: Image.PreserveAspectFit
                        // Presentation-only light & colour preview (never saved).
                        layer.enabled: viewerAdjustPanel.changed
                        layer.effect: MultiEffect {
                            brightness: viewerAdjustPanel.brightness
                            contrast: viewerAdjustPanel.contrast
                            saturation: viewerAdjustPanel.saturation
                        }

                        onStatusChanged: {
                            if (status === Image.Ready && view.autoFit) {
                                view.fit();
                            }
                        }
                    }
                }

                /// Right click anywhere in the viewing area opens the canvas menu
                /// for the image on screen. It only takes the right button, so it
                /// neither competes with the left-button double tap above nor with
                /// the drag that pans.
                TapHandler {
                    objectName: "viewerContextTap"
                    acceptedButtons: Qt.RightButton
                    onSingleTapped: function(point) {
                        if (!view.currentPath) {
                            return;
                        }
                        // Open at the click, not at the global pointer: `popup()` with
                        // no arguments asks the compositor for the cursor position,
                        // which is stale for a synthetic event (and not always
                        // reported under Wayland). `point.position` is in the
                        // handler's parent, the viewport.
                        var local = viewport.mapToItem(view, point.position.x,
                                                       point.position.y);
                        canvasMenu.popup(view, local.x, local.y);
                    }
                }

                Label {
                    anchors.centerIn: parent
                    visible: !view.currentPath
                    text: qsTr("Open an image to start viewing")
                    color: view.theme.textMuted
                    font.pixelSize: 16
                }

                Label {
                    anchors.centerIn: parent
                    visible: image.status === Image.Error
                    text: qsTr("This image cannot be decoded")
                    color: view.theme.danger
                    font.pixelSize: 15
                }

                // Guidance for the one case where "fitted" is not what the eye
                // expects: the picture is smaller than the window, so it sits at
                // 100 % surrounded by space. It says what happened and what to do,
                // and it stays out of the way — centred under the picture, muted,
                // hidden the moment a zoom leaves the fitted size.
                Label {
                    objectName: "viewerSmallImageHint"
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Bottom of the viewport rather than under the picture: the
                    // picture can be any size, and a caption that follows it would
                    // move with every zoom.
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 12
                    visible: view.imageSmallerThanViewport && view.autoFit
                    text: qsTr("Small image shown at 100 % — scroll or press + to enlarge")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                    background: Rectangle {
                        radius: view.theme.radius
                        color: view.theme.surface
                        border.width: 1
                        border.color: view.theme.border
                    }
                    padding: 8
                }
            }

            Rectangle {
                id: filmstrip
                objectName: "viewerFilmstripHost"
                // A single-image folder has no strip to scroll, so the toggle in
                // the toolbar hides it even though the preference is on; the
                // checkpoint there still shows the preference, so turning it off
                // and on again is not needed to get the strip back in a folder
                // that has one.
                visible: view.filmstripShown
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 106 : 0
                color: view.theme.surface

                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: view.theme.border
                }

                ListView {
                    id: strip
                    objectName: "viewerFilmstrip"
                    anchors.fill: parent
                    anchors.margins: 8
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    model: view.images
                    currentIndex: view.imageIndex
                    boundsBehavior: Flickable.StopAtBounds
                    /// The strip is horizontal, and Qt only scrolls the axis the
                    /// wheel reports — a mouse wheel reports vertical, so without
                    /// this the filmstrip ignores it entirely. The wheel is taken
                    /// here so it scrolls the strip instead of bubbling up to the
                    /// canvas's scroll-to-zoom handler behind it.
                    WheelHandler {
                        objectName: "filmstripWheelHandler"
                        /// `PointerDevice.Mouse` only, the default, silently ignores
                        /// touchpads on Wayland.
                        acceptedDevices: PointerDevice.AllDevices
                        onWheel: function(event) {
                            event.accepted = true;
                            /// Two groups of three 78 px tiles plus their 6 px gaps
                            /// per mouse notch (504 px), so one notch moves the strip
                            /// by a pair of tile groups instead of a single tile.
                            var step = 504;
                            var maxX = Math.max(0, strip.contentWidth - strip.width);
                            var dx = 0;
                            /// The device decides which delta is real: a mouse on
                            /// this desktop sends `angleDelta` ±120 *and* a
                            /// `pixelDelta` of a tenth of a notch, so checking the
                            /// pixel delta first would drop a notch to 20 px.
                            var notches = event.angleDelta.y !== 0 ? event.angleDelta.y / 120
                                                                   : event.angleDelta.x / 120;
                            if (notches !== 0) {
                                /// Mouse: a vertical wheel moves the strip sideways,
                                /// and a notch down (negative, "towards the user")
                                /// advances to the next images, the same direction
                                /// the grid below moves.
                                dx = -notches * step;
                            } else if (event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0) {
                                /// Touchpad: the pixels it reported, doubled the same
                                /// way `WheelScroll` doubles them so the strip keeps
                                /// up with the grid. A finger moving down the pad
                                /// reports a negative `y`, and that advances the strip
                                /// — the same direction a notch down does, and the
                                /// direction the grid already scrolls.
                                dx = (event.pixelDelta.x - event.pixelDelta.y)
                                     * 2;
                            }
                            if (dx === 0) return;
                            // Accumulate on the *target*, not on the animated
                            // position: a second notch that arrives while the strip
                            // is still gliding would otherwise restart from where it
                            // happens to be and lose the first notch's travel.
                            var base = filmstripGlide.running ? filmstripGlide.to
                                                              : strip.contentX;
                            filmstripGlide.to = Math.max(0, Math.min(maxX, base + dx));
                            filmstripGlide.restart();
                        }
                    }
                    NumberAnimation {
                        id: filmstripGlide
                        target: strip
                        property: "contentX"
                        duration: 150
                        easing.type: Easing.OutCubic
                    }

                    delegate: Item {
                        width: 78
                        height: strip.height

                        Rectangle {
                            anchors.fill: parent
                            radius: view.theme.radius
                            color: view.theme.thumb
                            border.width: index === view.imageIndex ? 2 : 1
                            border.color: index === view.imageIndex
                                          ? view.theme.accent : view.theme.border
                            clip: true

                            CachedThumbnail {
                                id: stripThumb
                                objectName: "stripThumbnail"
                                anchors.fill: parent
                                anchors.margins: 3
                                /// Entry of this image, for the cache key.
                                readonly property var meta: view.imageMeta[modelData] || null
                                book: thumbs
                                path: modelData
                                modified: meta ? meta.modified : 0
                                fileSize: meta ? meta.size : 0
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 160
                                sourceSize.height: 160
                            }
                        }

                        TapHandler {
                            acceptedButtons: Qt.LeftButton
                            onSingleTapped: view.command({
                                type: "viewer_open",
                                path: modelData
                            })
                        }
                    }
                }
            }
        }

        PanelSplitter {
            objectName: "viewerRightSplitter"
            visible: view.sidebarShown
            Layout.fillHeight: true
            theme: view.theme
            value: view.dockWidth
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

        // Right dock in Viewer: file Information + view-only Light & Color
        // adjustments (presentation-only, never saved to disk).
        RightDock {
            objectName: "viewerRightPanel"
            visible: view.sidebarShown
            Layout.preferredWidth: view.dockWidth
            Layout.fillHeight: true
            theme: view.theme
            backgroundColor: view.theme.sidebar
            tabs: [
                { key: "info", label: qsTr("Info"), icon: "icons/info.svg",
                  shown: view.infoPanelVisible },
                { key: "adjust", label: qsTr("Color"), icon: "icons/adjust.svg",
                  shown: view.infoPanelVisible }
            ]
            currentKey: view.viewerRightTab
            onActivated: function(key) { view.viewerRightTab = key }
            stripObjectName: "viewerRightTabs"
            tabKeyPrefix: "viewerTab"
            pagesObjectName: "viewerRightPages"

            ScrollView {
                id: viewerInfoPage
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    width: viewerInfoPage.availableWidth
                    spacing: 8

                    InfoPanel {
                        Layout.fillWidth: true
                        theme: view.theme
                        info: view.currentInfo
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            ScrollView {
                id: viewerAdjustPage
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    width: viewerAdjustPage.availableWidth
                    spacing: 8

                    ColorAdjustPanel {
                        id: viewerAdjustPanel
                        objectName: "viewerColorAdjustPanel"
                        Layout.fillWidth: true
                        Layout.margins: 12
                        theme: view.theme
                        viewOnly: true
                        showReset: true
                    }

                    Item { Layout.fillHeight: true }
                }
            }
        }
    }

    /// The right-click menu on the image itself. The first block is the file
    /// actions the browser's file menu already offers (the image is on screen,
    /// so there is no "Open" entry — it is already open); the last block is the
    /// viewer's own presentation state, which Qt owns and which therefore runs
    /// the same functions the toolbar buttons call.
    AppMenu {
        id: canvasMenu
        objectName: "viewerMenu"
        theme: view.theme
        implicitWidth: view.menuWidth

        MenuItem {
            text: qsTr("Edit")
            icon.name: "document-edit-symbolic"
            enabled: !!view.currentPath
            onTriggered: {
                // One batch: dispatching them back to back from this handler
                // dropped `editor_open` (see `Main.sendSequence`).
                view.editInEditor(view.currentPath);
            }
        }
        MenuItem {
            text: qsTr("Open with…")
            icon.name: "application-x-executable-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.openWith(view.currentPath)
        }
        MenuItem {
            text: view.theme.menuEntries[38]
            icon.name: "folder-documents-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.revealPath(view.currentPath)
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy image content")
            icon.name: "edit-copy-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.copyImage(view.currentPath)
            MenuShortcut { text: "Ctrl+Shift+C" }
        }
        MenuItem {
            text: qsTr("Copy file path")
            icon.name: "edit-copy-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.copyText(view.currentPath)
            MenuShortcut { text: "Ctrl+Alt+C" }
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy to…")
            icon.name: "folder-copy-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.requestDestination("copy_to", [view.currentPath])
        }
        MenuItem {
            text: qsTr("Move to…")
            icon.name: "folder-move-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.requestDestination("move_to", [view.currentPath])
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Move to trash")
            icon.name: "user-trash-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.command({ type: "trash", paths: [view.currentPath] })
            MenuShortcut { text: "Delete" }
        }
        MenuItem {
            text: qsTr("Delete permanently…")
            icon.name: "edit-delete-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.requestDelete([view.currentPath])
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Fit to window")
            icon.name: "zoom-fit-best-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.fit()
            MenuShortcut { text: "F" }
        }
        MenuItem {
            text: qsTr("Actual size")
            icon.name: "zoom-original-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.actualSize()
            MenuShortcut { text: "0/1" }
        }
        MenuItem {
            text: qsTr("Rotate left")
            icon.name: "object-rotate-left-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.rotateLeft()
            MenuShortcut { text: "Shift+R" }
        }
        MenuItem {
            text: qsTr("Rotate right")
            icon.name: "object-rotate-right-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.rotateRight()
            MenuShortcut { text: "R" }
        }
    }

    /// The actions the mini toolbar cannot show. It is the same buttons, in the
    /// same order, as the ones the toolbar hides below
    /// `ToolbarMetrics.compactToolbarWidth`; the labels come from
    /// `Theme.menuEntries` so they are the strings the menu width was measured
    /// from, and the keys are the ones the tooltips name.
    AppMenu {
        id: viewerOverflow
        objectName: "viewerOverflowMenu"
        theme: view.theme
        implicitWidth: view.menuWidth

        MenuItem {
            text: view.theme.menuEntries[30]
            icon.name: "zoom-in-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.zoomIn()
            MenuShortcut { text: "+" }
        }
        MenuItem {
            text: view.theme.menuEntries[31]
            icon.name: "zoom-out-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.zoomOut()
            MenuShortcut { text: "-" }
        }
        MenuItem {
            text: view.theme.menuEntries[22]
            icon.name: "zoom-original-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.actualSize()
            MenuShortcut { text: "0/1" }
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[23]
            icon.name: "object-rotate-left-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.rotateLeft()
            MenuShortcut { text: "Shift+R" }
        }
        MenuItem {
            text: view.theme.menuEntries[24]
            icon.name: "object-rotate-right-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.rotateRight()
            MenuShortcut { text: "R" }
        }
        MenuItem {
            text: view.theme.menuEntries[25]
            icon.name: "object-flip-horizontal-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.toggleFlipH()
            MenuShortcut { text: "H" }
        }
        MenuItem {
            text: view.theme.menuEntries[26]
            icon.name: "object-flip-vertical-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.toggleFlipV()
            MenuShortcut { text: "V" }
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[32]
            icon.name: "view-list-symbolic"
            checkable: true
            checked: !!view.state.filmstrip
            onTriggered: view.command({ type: "toggle_filmstrip" })
            MenuShortcut { text: "T" }
        }
    }

    Connections {
        target: view
        function onImageIndexChanged() {
            if (view.imageIndex >= 0) {
                strip.positionViewAtIndex(view.imageIndex, ListView.Center);
            }
        }
    }

    Component.onCompleted: {
        view.forceActiveFocus();
        if (view.imageIndex >= 0) {
            strip.positionViewAtIndex(view.imageIndex, ListView.Center);
        }
    }

    property Component toolbar: Component {
        RowLayout {
            spacing: 2

            ToolbarButton {
                theme: view.theme
                icon.name: "go-previous-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Back to browser (Esc/Backspace)")
                onClicked: view.command({ type: "set_workspace", workspace: "browser" })
            }

            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }

            ToolbarButton {
                theme: view.theme
                icon.name: "media-skip-backward-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.images.length > 0
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Previous image (Left)")
                onClicked: view.command({ type: "viewer_previous" })
            }
            Label {
                visible: view.images.length > 0
                text: (view.imageIndex + 1) + " / " + view.images.length
                color: view.theme.textMuted
                padding: 6
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "media-skip-forward-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.images.length > 0
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Next image (Right)")
                onClicked: view.command({ type: "viewer_next" })
            }

            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }

            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom in (+ or scroll wheel)")
                onClicked: view.zoomIn()
            }
            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom out (- or scroll wheel)")
                onClicked: view.zoomOut()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Fit to window (F)")
                onClicked: view.fit()
            }
            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-original-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Actual size at 100% (0/1)")
                onClicked: view.actualSize()
            }

            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }

            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "object-rotate-left-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Rotate left (Shift+R)")
                onClicked: view.rotateLeft()
            }
            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "object-rotate-right-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Rotate right (R)")
                onClicked: view.rotateRight()
            }
            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "object-flip-horizontal-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Flip horizontally (H)")
                onClicked: view.toggleFlipH()
            }
            ToolbarButton {
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "object-flip-vertical-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Flip vertically (V)")
                onClicked: view.toggleFlipV()
            }
            ToolbarButton {
                objectName: "viewerResetView"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "view-refresh-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Reset view")
                onClicked: view.resetView()
            }

            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }

            ToolbarButton {
                objectName: "viewerFilmstripToggle"
                theme: view.theme
                visible: !view.miniToolbar
                checkable: true
                checked: !!view.state.filmstrip
                icon.source: "icons/view-thumbnails.svg"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Toggle thumbnail filmstrip (T)")
                onClicked: view.command({ type: "toggle_filmstrip" })
            }
            Rectangle {
                id: viewerBgSwatch
                objectName: "viewerBgSwatch"
                visible: !view.miniToolbar
                implicitWidth: 24
                implicitHeight: 24
                radius: view.theme.radius
                color: (!view.canvasBgUseTheme && view.canvasBgChecker)
                       ? "transparent"
                       : (view.canvasBgUseTheme ? view.theme.background : view.canvasBgColor)
                border.width: 1
                border.color: viewerBgHover.hovered ? view.theme.accent : view.theme.border
                clip: true

                Checkerboard {
                    anchors.fill: parent
                    visible: !view.canvasBgUseTheme && view.canvasBgChecker
                }
                HoverHandler { id: viewerBgHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: qsTr("Canvas background")
                    onClicked: {
                        viewerBgPopup.transparent = !view.canvasBgUseTheme && view.canvasBgChecker
                        viewerBgPopup.colour = view.canvasBgColor
                        viewerBgPopup.showBelow(viewerBgSwatch)
                    }
                }
            }
            ToolbarButton {
                objectName: "viewerOverflowButton"
                theme: view.theme
                visible: view.miniToolbar
                icon.name: "view-more-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("More viewer actions")
                onClicked: viewerOverflow.popup(this)
            }
        }
    }

    property string viewerRightTab: "info"
    property bool canvasBgUseTheme: true
    property bool canvasBgChecker: false
    property color canvasBgColor: "#ffffff"

    BackgroundPopup {
        id: viewerBgPopup
        objectName: "viewerBgPopup"
        theme: view.theme
        transparent: !view.canvasBgUseTheme && view.canvasBgChecker
        colour: view.canvasBgColor
        onTransparentPicked: {
            view.canvasBgUseTheme = false
            view.canvasBgChecker = true
        }
        onColourPicked: function(value) {
            view.canvasBgUseTheme = false
            view.canvasBgChecker = false
            view.canvasBgColor = value
        }
        onCustomPicked: {
            viewerBgColorDialog.selectedColor = view.canvasBgColor
            viewerBgColorDialog.open()
        }
    }

    ColorPickerDialog {
        id: viewerBgColorDialog
        objectName: "viewerBgColorDialog"
        theme: view.theme
        title: qsTr("Canvas background")
        selectedColor: view.canvasBgColor
        onAccepted: {
            view.canvasBgUseTheme = false
            view.canvasBgChecker = false
            view.canvasBgColor = selectedColor
            view.forceActiveFocus()
        }
    }
}
