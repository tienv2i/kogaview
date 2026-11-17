import QtQuick
import QtQuick.Controls
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

    property real zoom: 1
    property real offsetX: 0
    property real offsetY: 0
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
    property bool autoFit: true

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

    /// The widths `Main.qml` measured for `Theme.menuEntryLabels`, so the canvas
    /// menu is as wide as the longest label it can show instead of the style's
    /// fixed 200 px. Empty in the QML harness, where the theme's floor applies.
    property var menuLabelWidths: []
    property real menuWidth: theme.menuWidth(menuLabelWidths)

    property string currentPath: view.state.viewerPath || ""
    property var images: view.viewerImages || []
    property int imageIndex: (view.state.viewerIndex === undefined
                              || view.state.viewerIndex === null)
                             ? -1 : view.state.viewerIndex

    function setZoom(value) {
        // A typed or stepped zoom is a deliberate one; it leaves auto fit.
        view.autoFit = false;
        view.zoom = Math.max(0.05, Math.min(16, value));
    }

    // Zoom while keeping the image point under the cursor fixed.
    // `pointX`/`pointY` are in viewport coordinates.
    function zoomAt(factor, pointX, pointY) {
        var previous = view.zoom > 0 ? view.zoom : 1;
        var next = Math.max(0.05, Math.min(16, previous * factor));
        if (Math.abs(next - previous) < 0.000001) {
            return;
        }
        // A deliberate zoom is the user leaving auto fit; the wheel would
        // otherwise be undone by the next window resize.
        view.autoFit = false;
        var centerX = viewport.width / 2 + view.offsetX;
        var centerY = viewport.height / 2 + view.offsetY;
        var shift = 1 - next / previous;
        view.offsetX += (pointX - centerX) * shift;
        view.offsetY += (pointY - centerY) * shift;
        view.zoom = next;
    }

    function zoomIn() {
        view.setZoom(view.zoom * 1.25);
    }

    function zoomOut() {
        view.setZoom(view.zoom / 1.25);
    }

    /// Scale the picture so it fits the viewport, and stay in that mode: the
    /// view refits itself when the window or the picture changes size.
    function fit() {
        if (viewport.width > 0 && viewport.height > 0
                && image.implicitWidth > 0 && image.implicitHeight > 0) {
            view.autoFit = true;
            view.zoom = fittedZoom();
            view.offsetX = 0;
            view.offsetY = 0;
        }
    }

    /// The zoom that shows the whole picture in the viewport, leaving a 2 %
    /// margin so a fit does not look flush against the edge.
    function fittedZoom() {
        if (image.implicitWidth <= 0 || image.implicitHeight <= 0) {
            return view.zoom;
        }
        // A quarter-turned picture is as wide as it is tall, so the viewport
        // axis it must fit is not the one the source dimensions suggest.
        var turned = view.rotationAngle % 180 !== 0;
        var sourceWidth = turned ? image.implicitHeight : image.implicitWidth;
        var sourceHeight = turned ? image.implicitWidth : image.implicitHeight;
        return Math.min(viewport.width / sourceWidth,
                        viewport.height / sourceHeight) * 0.98;
    }

    /// Re-apply the view's own rule after something that could invalidate the
    /// current view: fitted views refit, hand-chosen ones only re-clamp.
    function refitOrClamp() {
        if (view.autoFit) {
            view.fit();
        } else {
            view.clampOffsets();
        }
    }

    /// Keep the pan reachable after the viewport or the zoom changed.
    function clampOffsets() {
        var shownX = image.implicitWidth * view.zoom;
        var shownY = image.implicitHeight * view.zoom;
        var maxX = Math.max(0, (shownX - viewport.width) / 2);
        var maxY = Math.max(0, (shownY - viewport.height) / 2);
        view.offsetX = Math.max(-maxX, Math.min(maxX, view.offsetX));
        view.offsetY = Math.max(-maxY, Math.min(maxY, view.offsetY));
    }

    function actualSize() {
        view.autoFit = false;
        view.zoom = 1;
        view.offsetX = 0;
        view.offsetY = 0;
    }

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

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item {
            id: viewport
            objectName: "viewerViewport"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            // The area the picture is fitted into changes on a window resize,
            // a panel split and a filmstrip toggle; fitting here covers all
            // three, not just the window.
            onWidthChanged: view.refitOrClamp()
            onHeightChanged: view.refitOrClamp()

            Rectangle {
                anchors.fill: parent
                color: view.theme.background
            }

            Item {
                id: canvas
                objectName: "viewerCanvas"
                width: Math.max(1, image.implicitWidth)
                height: Math.max(1, image.implicitHeight)
                // `scale` and `rotation` pivot on the item centre, so the
                // position is the unscaled top-left that centres the item in
                // the viewport. Multiplying `width` by `scale` here would
                // count the scale twice and push the image down/right.
                scale: view.zoom
                rotation: view.rotationAngle
                x: (viewport.width - width) / 2 + view.offsetX
                y: (viewport.height - height) / 2 + view.offsetY

                // A `Scale` transform pivots on its `origin`, which defaults to
                // the item's top-left corner; mirroring there would throw the
                // image out of the viewport, so flip around the centre.
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
                    source: view.currentPath ? "file://" + view.currentPath : ""
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectFit

                    onStatusChanged: {
                        if (status === Image.Ready && view.autoFit) {
                            view.fit();
                        }
                    }
                }
            }

            WheelHandler {
                objectName: "viewerWheelHandler"
                acceptedDevices: PointerDevice.AllDevices
                onWheel: function(event) {
                    if (!view.currentPath) return;
                    // A mouse wheel reports `angleDelta`; Wayland touchpads
                    // report continuous `pixelDelta` with angleDelta 0, so both
                    // must be supported or scrolling does nothing on a laptop.
                    var factor = 1;
                    if (event.angleDelta.y !== 0) {
                        factor = Math.pow(1.0015, event.angleDelta.y);
                    } else if (event.pixelDelta.y !== 0) {
                        factor = Math.pow(1.01, event.pixelDelta.y);
                    } else {
                        return;
                    }
                    // Keep a single event from jumping wildly on high-resolution
                    // wheels or very fast trackpad gestures.
                    factor = Math.max(0.5, Math.min(2, factor));
                    view.zoomAt(factor, event.x, event.y);
                    event.accepted = true;
                }
            }

            DragHandler {
                id: pan
                target: null
                property real startX: 0
                property real startY: 0

                onActiveChanged: {
                    if (active) {
                        startX = view.offsetX;
                        startY = view.offsetY;
                    }
                }
                onTranslationChanged: {
                    view.offsetX = startX + translation.x;
                    view.offsetY = startY + translation.y;
                }
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: {
                    if (view.autoFit) view.actualSize();
                    else view.fit();
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
        }

        Rectangle {
            visible: !!view.state.filmstrip
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

    // ------------------------------------------------------------- canvas menu
    /// The right-click menu on the image itself. The first block is the file
    /// actions the browser's file menu already offers (the image is on screen,
    /// so there is no "Open" entry — it is already open); the last block is the
    /// viewer's own presentation state, which Qt owns and which therefore runs
    /// the same functions the toolbar buttons call.
    Menu {
        id: canvasMenu
        objectName: "viewerMenu"
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
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy image content")
            icon.name: "edit-copy-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.copyImage(view.currentPath)
        }
        MenuItem {
            text: qsTr("Copy file path")
            icon.name: "edit-copy-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.copyText(view.currentPath)
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
        }
        MenuItem {
            text: qsTr("Actual size")
            icon.name: "zoom-original-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.actualSize()
        }
        MenuItem {
            text: qsTr("Rotate left")
            icon.name: "object-rotate-left-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.rotateLeft()
        }
        MenuItem {
            text: qsTr("Rotate right")
            icon.name: "object-rotate-right-symbolic"
            enabled: !!view.currentPath
            onTriggered: view.rotateRight()
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
                ToolTip.text: qsTr("Back to browser")
                onClicked: view.command({ type: "set_workspace", workspace: "browser" })
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                icon.name: "media-skip-backward-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.images.length > 0
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Previous image")
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
                ToolTip.text: qsTr("Next image")
                onClicked: view.command({ type: "viewer_next" })
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom in (scroll wheel)")
                onClicked: view.zoomIn()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom out (scroll wheel)")
                onClicked: view.zoomOut()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Fit to window")
                onClicked: view.fit()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-original-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Actual size (100%)")
                onClicked: view.actualSize()
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                icon.name: "object-rotate-left-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Rotate left")
                onClicked: view.rotateLeft()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "object-rotate-right-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Rotate right")
                onClicked: view.rotateRight()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "object-flip-horizontal-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Flip horizontally")
                onClicked: view.toggleFlipH()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "object-flip-vertical-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Flip vertically")
                onClicked: view.toggleFlipV()
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                checkable: true
                checked: !!view.state.filmstrip
                icon.name: "view-list-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Toggle thumbnail filmstrip")
                onClicked: view.command({ type: "toggle_filmstrip" })
            }
        }
    }
}
