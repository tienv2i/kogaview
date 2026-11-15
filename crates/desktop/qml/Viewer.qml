import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: view

    property Theme theme: Theme {}
    property var state: ({})

    property real zoom: 1
    property real offsetX: 0
    property real offsetY: 0
    // `rotation` is already an Item property; the image rotation must not
    // shadow it, or the whole workspace would rotate.
    property int rotationAngle: 0
    property bool flipH: false
    property bool flipV: false
    property bool autoFit: true

    signal command(var command)

    property string currentPath: view.state.viewerPath || ""
    property var images: view.state.viewerImages || []
    property int imageIndex: (view.state.viewerIndex === undefined
                              || view.state.viewerIndex === null)
                             ? -1 : view.state.viewerIndex

    function setZoom(value) {
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
        var centerX = viewport.width / 2 + view.offsetX;
        var centerY = viewport.height / 2 + view.offsetY;
        var shift = 1 - next / previous;
        view.offsetX += (pointX - centerX) * shift;
        view.offsetY += (pointY - centerY) * shift;
        view.zoom = next;
        view.autoFit = false;
    }

    function zoomIn() {
        view.autoFit = false;
        view.setZoom(view.zoom * 1.25);
    }

    function zoomOut() {
        view.autoFit = false;
        view.setZoom(view.zoom / 1.25);
    }

    function fit() {
        if (viewport.width > 0 && viewport.height > 0
                && image.implicitWidth > 0 && image.implicitHeight > 0) {
            view.zoom = Math.min(viewport.width / image.implicitWidth,
                                 viewport.height / image.implicitHeight) * 0.98;
            view.offsetX = 0;
            view.offsetY = 0;
            view.autoFit = false;
        }
    }

    function actualSize() {
        view.zoom = 1;
        view.offsetX = 0;
        view.offsetY = 0;
        view.autoFit = false;
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

            Label {
                anchors.centerIn: parent
                visible: !view.currentPath
                text: "Open an image to start viewing"
                color: view.theme.textMuted
                font.pixelSize: 16
            }

            Label {
                anchors.centerIn: parent
                visible: image.status === Image.Error
                text: "This image cannot be decoded"
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
                anchors.fill: parent
                anchors.margins: 8
                orientation: ListView.Horizontal
                spacing: 6
                clip: true
                model: view.images
                currentIndex: view.imageIndex
                boundsBehavior: Flickable.StopAtBounds

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

                        Image {
                            anchors.fill: parent
                            anchors.margins: 3
                            source: "file://" + modelData
                            asynchronous: true
                            cache: false
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
                ToolTip.text: "Back to browser"
                onClicked: view.command({ type: "set_workspace", workspace: "browser" })
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                icon.name: "media-skip-backward-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.images.length > 0
                ToolTip.visible: hovered
                ToolTip.text: "Previous image"
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
                ToolTip.text: "Next image"
                onClicked: view.command({ type: "viewer_next" })
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Zoom in (scroll wheel)"
                onClicked: view.zoomIn()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Zoom out (scroll wheel)"
                onClicked: view.zoomOut()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Fit to window"
                onClicked: view.fit()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "zoom-original-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Actual size (100%)"
                onClicked: view.actualSize()
            }

            ToolbarSeparator { theme: view.theme }

            ToolbarButton {
                theme: view.theme
                icon.name: "object-rotate-left-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Rotate left"
                onClicked: view.rotateLeft()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "object-rotate-right-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Rotate right"
                onClicked: view.rotateRight()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "object-flip-horizontal-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Flip horizontally"
                onClicked: view.toggleFlipH()
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "object-flip-vertical-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!view.currentPath
                ToolTip.visible: hovered
                ToolTip.text: "Flip vertically"
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
                ToolTip.text: "Toggle thumbnail filmstrip"
                onClicked: view.command({ type: "toggle_filmstrip" })
            }
        }
    }
}
