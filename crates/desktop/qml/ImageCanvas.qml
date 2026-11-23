import QtQuick

// Shared image viewport for both Viewer and Editor.
//
// Owns presentation-only zoom, pan, tight canvas clamping (panMargin = 0:
// images smaller than or equal to the viewport stay centred; zoomed images pan
// strictly up to the image edges), scroll-to-zoom at the cursor, drag-to-pan,
// double-click fit/100% toggle, and document <-> viewport coordinate helpers.
Rectangle {
    id: host
    clip: true

    property bool hasContent: false
    property real contentWidth: 0
    property real contentHeight: 0

    // Presentation transform state.
    property real zoom: 1
    property real offsetX: 0
    property real offsetY: 0
    property bool autoFit: true

    // Fitting & zoom bounds.
    property real minZoom: 0.02
    property real maxZoom: 16
    property real fitPadding: 0
    property real fitScaleFactor: 1.0
    property bool fitCapAtOne: false
    property bool roundPosition: false
    property bool clampOnZoom: true
    /// Extra pan freedom past the image edges (0 = strict edge clamp for Viewer;
    /// positive = Krita-style free pan for Editor while keeping the image reachable).
    property real panMargin: 0

    // Optional presentation rotation/flip (used by Viewer).
    property int rotationAngle: 0
    property bool flipH: false
    property bool flipV: false

    // Input gating (Editor gates left-pan to Hand tool / Space; Viewer allows it always).
    property bool inputBlocked: false
    property bool allowLeftPan: true
    property bool allowMiddlePan: true
    property bool allowDoubleTapZoom: true
    property bool requireHoverToPan: false
    property bool hovered: false

    // Preserved objectNames for QML tests and dev harness probes.
    property alias wheelHandlerName: wheelHandler.objectName
    property alias panHandlerName: panHandler.objectName
    property real lastWheelX: -1
    property real lastWheelY: -1

    readonly property bool panning: panHandler.active
    readonly property bool turned: (rotationAngle % 180) !== 0
    readonly property real effectiveWidth: turned ? contentHeight : contentWidth
    readonly property real effectiveHeight: turned ? contentWidth : contentHeight
    readonly property bool canPan: hasContent
                                   && (effectiveWidth * zoom > width + 0.5
                                       || effectiveHeight * zoom > height + 0.5)

    // Unscaled top-left of the centred content item (before Item.scale around centre).
    readonly property real itemX: roundPosition
                                  ? Math.round((width - Math.max(1, contentWidth)) / 2 + offsetX)
                                  : ((width - Math.max(1, contentWidth)) / 2 + offsetX)
    readonly property real itemY: roundPosition
                                  ? Math.round((height - Math.max(1, contentHeight)) / 2 + offsetY)
                                  : ((height - Math.max(1, contentHeight)) / 2 + offsetY)

    // Visual top-left of the scaled content in host coordinates (for Editor overlays).
    readonly property real canvasOriginX:
        itemX + Math.max(1, contentWidth) / 2 * (1 - zoom)
    readonly property real canvasOriginY:
        itemY + Math.max(1, contentHeight) / 2 * (1 - zoom)

    function docToHostX(value) { return host.canvasOriginX + value * host.zoom }
    function docToHostY(value) { return host.canvasOriginY + value * host.zoom }
    function hostToDocX(value) { return host.zoom > 0 ? (value - host.canvasOriginX) / host.zoom : 0 }
    function hostToDocY(value) { return host.zoom > 0 ? (value - host.canvasOriginY) / host.zoom : 0 }

    /// Tight canvas clamping (`panMargin = 0`): a fitted/smaller image stays
    /// centred; a zoomed image pans strictly up to its own edges.
    function clampOffsets() {
        if (width <= 0 || height <= 0) return
        var isTurned = (host.rotationAngle % 180) !== 0
        var effW = isTurned ? host.contentHeight : host.contentWidth
        var effH = isTurned ? host.contentWidth : host.contentHeight
        var shownX = effW * host.zoom
        var shownY = effH * host.zoom
        var maxX = Math.max(0, (shownX - host.width) / 2) + host.panMargin
        var maxY = Math.max(0, (shownY - host.height) / 2) + host.panMargin
        host.offsetX = Math.max(-maxX, Math.min(maxX, host.offsetX))
        host.offsetY = Math.max(-maxY, Math.min(maxY, host.offsetY))
    }

    function fittedZoom() {
        var isTurned = (host.rotationAngle % 180) !== 0
        var effW = isTurned ? host.contentHeight : host.contentWidth
        var effH = isTurned ? host.contentWidth : host.contentHeight
        if (effW <= 0 || effH <= 0
                || host.width <= host.fitPadding || host.height <= host.fitPadding) {
            return host.zoom
        }
        var raw = Math.min(
            (host.width - host.fitPadding) / effW,
            (host.height - host.fitPadding) / effH
        ) * host.fitScaleFactor
        if (host.fitCapAtOne) raw = Math.min(1, raw)
        return Math.max(host.minZoom, Math.min(host.maxZoom, raw))
    }

    function fit() {
        var isTurned = (host.rotationAngle % 180) !== 0
        var effW = isTurned ? host.contentHeight : host.contentWidth
        var effH = isTurned ? host.contentWidth : host.contentHeight
        if (!host.hasContent || host.width <= host.fitPadding || host.height <= host.fitPadding
                || effW <= 0 || effH <= 0) {
            return
        }
        host.autoFit = true
        host.zoom = host.fittedZoom()
        host.offsetX = 0
        host.offsetY = 0
    }

    function refitOrClamp() {
        if (host.autoFit) host.fit()
        else host.clampOffsets()
    }

    function setZoom(value) {
        host.autoFit = false
        host.zoom = Math.max(host.minZoom, Math.min(host.maxZoom, value))
        host.clampOffsets()
    }

    function actualSize() {
        if (!host.hasContent) return
        host.autoFit = false
        host.offsetX = 0
        host.offsetY = 0
        host.zoom = 1
        host.clampOffsets()
    }

    function zoomIn() { host.setZoom(host.zoom * 1.25) }
    function zoomOut() { host.setZoom(host.zoom / 1.25) }

    /// Zoom while keeping the content point under `(pointX, pointY)` fixed.
    function zoomAt(factor, pointX, pointY) {
        if (!host.hasContent) return
        var previous = host.zoom > 0 ? host.zoom : 1
        var next = Math.max(host.minZoom, Math.min(host.maxZoom, previous * factor))
        if (Math.abs(next - previous) < 0.000001) return
        host.autoFit = false
        var centerX = host.width / 2 + host.offsetX
        var centerY = host.height / 2 + host.offsetY
        var shift = 1 - next / previous
        host.offsetX += (pointX - centerX) * shift
        host.offsetY += (pointY - centerY) * shift
        host.zoom = next
        if (host.clampOnZoom) host.clampOffsets()
    }

    function toggleZoom() {
        if (!host.hasContent) return
        if (host.autoFit) host.actualSize()
        else host.fit()
    }

    function panBy(dx, dy) {
        host.offsetX += dx
        host.offsetY += dy
        host.clampOffsets()
    }

    onWidthChanged: host.refitOrClamp()
    onHeightChanged: host.refitOrClamp()
    onRotationAngleChanged: host.refitOrClamp()

    // Child content (the image item itself plus any workspace overlays).
    default property alias content: contentSlot.data
    Item {
        id: contentSlot
        anchors.fill: parent
    }

    WheelHandler {
        id: wheelHandler
        objectName: "imageCanvasWheelHandler"
        acceptedDevices: PointerDevice.AllDevices
        enabled: !host.inputBlocked
        onWheel: function(event) {
            if (!host.hasContent) return
            var factor = 1
            if (event.angleDelta.y !== 0) {
                factor = Math.pow(1.0015, event.angleDelta.y)
            } else if (event.pixelDelta.y !== 0) {
                factor = Math.pow(1.01, event.pixelDelta.y)
            } else {
                return
            }
            factor = Math.max(0.5, Math.min(2, factor))
            host.lastWheelX = event.x
            host.lastWheelY = event.y
            host.zoomAt(factor, event.x, event.y)
            event.accepted = true
        }
    }

    DragHandler {
        id: panHandler
        objectName: "imageCanvasPanHandler"
        target: null
        acceptedDevices: PointerDevice.AllDevices
        enabled: !host.inputBlocked
                 && (!host.requireHoverToPan || host.hovered)
                 && (host.allowLeftPan || host.allowMiddlePan)
        acceptedButtons: (host.allowLeftPan && host.allowMiddlePan)
                         ? (Qt.LeftButton | Qt.MiddleButton)
                         : (host.allowLeftPan ? Qt.LeftButton : Qt.MiddleButton)
        property real startX: 0
        property real startY: 0

        onActiveChanged: {
            if (active) {
                startX = host.offsetX
                startY = host.offsetY
            }
        }
        onTranslationChanged: {
            host.offsetX = startX + translation.x
            host.offsetY = startY + translation.y
            host.clampOffsets()
        }
    }

    HoverHandler {
        id: hoverHandler
        onHoveredChanged: host.hovered = hovered
        cursorShape: panHandler.active
                     ? Qt.ClosedHandCursor
                     : ((host.allowLeftPan && !host.inputBlocked && host.hasContent)
                        ? Qt.OpenHandCursor : Qt.ArrowCursor)
    }

    TapHandler {
        id: doubleTapHandler
        acceptedButtons: Qt.LeftButton
        enabled: !host.inputBlocked && host.allowDoubleTapZoom
        onDoubleTapped: host.toggleZoom()
    }
}
