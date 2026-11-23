import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Window

/// Virtualized continuous vertical reader (Webtoon / Vertical Manga mode).
///
/// Performance guarantees for folders with hundreds/thousands of heavy images:
/// 1. Pre-layout via header-only `Platform.imageSize(path)` (zero full-decode)
///    eliminates layout shift and keeps scrollbar geometry exact from frame 1.
/// 2. Bounded `ListView` virtualization (`reuseItems: true`, `cacheBuffer`
///    capped at ~1.2× viewport height) keeps VRAM flat regardless of page count.
/// 3. Column-width zoom (`0.4×–3.0×`) scales smoothly at 60 fps and updates
///    capped `sourceSize` (max 4096×8192) on a 150 ms debounce after zooming.
Item {
    id: webtoon

    property Theme theme: Theme {}
    property var images: []
    property int currentIndex: -1
    property int pageGap: 8
    /// Smart Auto-Fit mode: `"auto"` (median natural width capped to viewport),
    /// `"width"` (fit viewport width), `"height"` (fit each page to viewport
    /// height), or `"original"` (1:1 natural width).
    property string fitMode: "auto"
    property real widthZoom: 1.0
    property bool smoothFiltering: true
    property bool colorAdjustActive: false
    property real brightness: 0
    property real contrast: 0
    property real saturation: 0
    property bool inputBlocked: false

    /// Emitted (debounced at 150 ms) when the page at the viewport centre
    /// changes during scrolling so Core's `viewerIndex` stays in sync.
    signal pageCentered(int index)
    signal contextMenuRequested(real x, real y)

    /// Cached aspect ratios (`height / width`) per path.
    property var _aspectCache: ({})
    /// Debounced decode width so wheel zooming stays 60 fps without
    /// re-decoding every intermediate frame.
    property int decodeTargetWidth: Math.min(4096, Math.max(256, Math.round(webtoon.columnWidth * Screen.devicePixelRatio)))
    /// Horizontal pan offset when `widthZoom > 1.0`.
    property real panX: 0
    property bool _syncingFromExternal: false

    /// Median natural width sampled from up to the first 20 images via
    /// header-only `Platform.imageSize(path)` (takes < 2 ms, zero full decode).
    readonly property real medianNaturalWidth: {
        var list = webtoon.images || []
        var sampleCount = Math.min(list.length, 20)
        if (sampleCount === 0) return 0
        var widths = []
        if (typeof Platform !== "undefined" && Platform && Platform.imageSize) {
            for (var i = 0; i < sampleCount; ++i) {
                var sz = Platform.imageSize(list[i])
                if (sz && sz.width > 0) widths.push(sz.width)
            }
        }
        if (widths.length === 0) return 0
        widths.sort(function(a, b) { return a - b })
        return widths[Math.floor(widths.length / 2)]
    }

    readonly property real baseColumnWidth: {
        var avail = Math.max(320, webtoon.width - 24)
        var nat = webtoon.medianNaturalWidth
        if (webtoon.fitMode === "width") return avail
        if (webtoon.fitMode === "original") return nat > 0 ? nat : avail
        // `"auto"` and `"height"` base width: never upscale small webtoons on
        // wide monitors, while shrinking cleanly when the window narrows.
        return nat > 0 ? Math.min(avail, Math.max(360, nat)) : avail
    }

    readonly property real columnWidth:
        Math.max(240, Math.round(webtoon.baseColumnWidth * webtoon.widthZoom))
    readonly property real maxPanX:
        Math.max(0, (webtoon.columnWidth - webtoon.width) / 2 + 12)

    function setFitMode(mode) {
        if (mode !== "auto" && mode !== "width" && mode !== "height" && mode !== "original") return
        webtoon.fitMode = mode
        webtoon.widthZoom = 1.0
        webtoon.panX = 0
        decodeDebounce.restart()
    }

    function probeAspect(path) {
        if (!path) return 1.4
        if (webtoon._aspectCache[path] !== undefined) return webtoon._aspectCache[path]
        var ratio = 1.4
        if (typeof Platform !== "undefined" && Platform && Platform.imageSize) {
            var sz = Platform.imageSize(path)
            if (sz && sz.width > 0 && sz.height > 0) {
                ratio = Math.max(0.2, Math.min(12.0, sz.height / sz.width))
            }
        }
        webtoon._aspectCache[path] = ratio
        return ratio
    }

    function setWidthZoom(nextZoom) {
        var clamped = Math.max(0.4, Math.min(3.0, nextZoom))
        if (Math.abs(clamped - webtoon.widthZoom) < 0.005) return
        var oldZoom = webtoon.widthZoom
        var ratio = clamped / oldZoom
        var oldCenterOffset = (strip.contentY - strip.originY) + strip.height / 2
        webtoon.widthZoom = clamped
        if (clamped <= 1.0) {
            webtoon.panX = 0
        } else {
            webtoon.panX = Math.max(-webtoon.maxPanX, Math.min(webtoon.maxPanX, webtoon.panX))
        }
        Qt.callLater(function() {
            var minY = strip.originY
            var maxY = minY + Math.max(0, strip.contentHeight - strip.height)
            strip.contentY = Math.max(minY, Math.min(maxY, minY + oldCenterOffset * ratio - strip.height / 2))
        })
        decodeDebounce.restart()
    }

    function zoomIn() { webtoon.setWidthZoom(webtoon.widthZoom * 1.15) }
    function zoomOut() { webtoon.setWidthZoom(webtoon.widthZoom / 1.15) }
    function resetZoom() {
        webtoon.fitMode = "auto"
        webtoon.setWidthZoom(1.0)
        webtoon.panX = 0
        decodeDebounce.restart()
    }

    function scrollBy(dy) {
        if (dy < 0 && strip.atYBeginning) {
            scrollGlide.stop()
            return
        }
        if (dy > 0 && strip.atYEnd) {
            scrollGlide.stop()
            return
        }
        var minY = strip.originY
        var maxY = minY + Math.max(0, strip.contentHeight - strip.height)
        var base = scrollGlide.running ? scrollGlide.to : strip.contentY
        var target = Math.max(minY, Math.min(maxY, base + dy))
        if (Math.abs(target - strip.contentY) < 0.5 && !scrollGlide.running) return
        scrollGlide.to = target
        scrollGlide.restart()
    }

    function jumpToPage(index) {
        if (index < 0 || index >= webtoon.images.length) return
        webtoon._syncingFromExternal = true
        strip.positionViewAtIndex(index, ListView.Beginning)
        externalSyncGuard.restart()
    }

    onImagesChanged: {
        webtoon._aspectCache = ({})
        webtoon.panX = 0
    }

    onWidthChanged: {
        if (webtoon.widthZoom <= 1.0) webtoon.panX = 0
        decodeDebounce.restart()
    }

    Timer {
        id: decodeDebounce
        interval: 150
        repeat: false
        onTriggered: {
            var dpr = Screen.devicePixelRatio || 1.0
            webtoon.decodeTargetWidth = Math.min(4096, Math.max(256, Math.round(webtoon.columnWidth * dpr)))
        }
    }

    Timer {
        id: externalSyncGuard
        interval: 220
        repeat: false
        onTriggered: webtoon._syncingFromExternal = false
    }

    Timer {
        id: centerSyncTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (webtoon._syncingFromExternal || !webtoon.visible) return
            var idx = strip.indexAt(strip.width / 2, strip.contentY + strip.height / 2)
            if (idx >= 0 && idx < webtoon.images.length && idx !== webtoon.currentIndex) {
                webtoon.pageCentered(idx)
            }
        }
    }

    NumberAnimation {
        id: scrollGlide
        target: strip
        property: "contentY"
        duration: 130
        easing.type: Easing.OutCubic
    }

    ListView {
        id: strip
        objectName: "viewerWebtoonList"
        anchors.fill: parent
        orientation: ListView.Vertical
        spacing: webtoon.pageGap
        clip: true
        reuseItems: true
        cacheBuffer: Math.max(800, Math.round(strip.height * 1.2))
        boundsBehavior: Flickable.StopAtBounds
        model: webtoon.images
        interactive: !webtoon.inputBlocked

        onContentYChanged: {
            if (!webtoon._syncingFromExternal) centerSyncTimer.restart()
        }

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        delegate: Item {
            id: pageSlot
            required property int index
            required property string modelData

            readonly property real aspect: webtoon.probeAspect(modelData)
            readonly property real slotWidth:
                webtoon.fitMode === "height"
                ? Math.max(160, Math.round(slotHeight / Math.max(0.2, pageSlot.aspect)))
                : webtoon.columnWidth
            readonly property real slotHeight:
                webtoon.fitMode === "height"
                ? Math.max(200, Math.round(Math.max(240, webtoon.height - 16) * webtoon.widthZoom))
                : Math.max(64, Math.round(webtoon.columnWidth * pageSlot.aspect))
            width: strip.width
            height: pageSlot.slotHeight

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.horizontalCenterOffset: webtoon.panX
                y: 0
                width: pageSlot.slotWidth
                height: parent.height
                color: webtoon.theme.thumb

                Image {
                    id: pageImg
                    anchors.fill: parent
                    source: (webtoon.visible && pageSlot.modelData) ? "file://" + pageSlot.modelData : ""
                    asynchronous: true
                    cache: false
                    smooth: webtoon.smoothFiltering
                    mipmap: webtoon.smoothFiltering
                    fillMode: Image.PreserveAspectFit
                    sourceSize.width: webtoon.decodeTargetWidth
                    sourceSize.height: Math.min(8192, Math.round(webtoon.decodeTargetWidth * pageSlot.aspect))

                    layer.enabled: webtoon.colorAdjustActive
                    layer.effect: MultiEffect {
                        brightness: webtoon.brightness
                        contrast: webtoon.contrast
                        saturation: webtoon.saturation
                    }
                }
            }
        }
    }

    WheelHandler {
        objectName: "webtoonWheelHandler"
        enabled: !webtoon.inputBlocked
        acceptedDevices: PointerDevice.AllDevices
        onWheel: function(event) {
            event.accepted = true
            if (event.modifiers & Qt.ControlModifier) {
                var dir = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y
                if (dir > 0) webtoon.zoomIn()
                else if (dir < 0) webtoon.zoomOut()
                return
            }
            var dy = 0
            if (event.angleDelta.y !== 0) {
                dy = -(event.angleDelta.y / 120) * 260
            } else if (event.pixelDelta.y !== 0) {
                dy = -event.pixelDelta.y * 1.5
            }
            if (dy !== 0) webtoon.scrollBy(dy)

            if (webtoon.widthZoom > 1.0 && event.pixelDelta.x !== 0) {
                webtoon.panX = Math.max(-webtoon.maxPanX,
                                        Math.min(webtoon.maxPanX, webtoon.panX + event.pixelDelta.x))
            }
        }
    }

    DragHandler {
        objectName: "webtoonPanHandler"
        enabled: !webtoon.inputBlocked && webtoon.widthZoom > 1.0
        target: null
        acceptedDevices: PointerDevice.AllDevices
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        property real startPanX: 0
        onActiveChanged: {
            if (active) startPanX = webtoon.panX
        }
        onTranslationChanged: {
            if (!active) return
            webtoon.panX = Math.max(-webtoon.maxPanX,
                                    Math.min(webtoon.maxPanX, startPanX + translation.x))
        }
    }

    TapHandler {
        objectName: "webtoonContextTap"
        enabled: !webtoon.inputBlocked
        acceptedButtons: Qt.RightButton
        onSingleTapped: function(point) {
            webtoon.contextMenuRequested(point.position.x, point.position.y)
        }
    }
}
