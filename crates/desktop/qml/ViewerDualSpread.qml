import QtQuick
import QtQuick.Effects

/// Two-page book / manga spread renderer placed inside Viewer's shared
/// `ImageCanvas` so zoom-at-cursor, free pan, double-click Fit/100%, and
/// Color & Light GPU effects work identically to Single mode at 60 fps.
///
/// Smart spread pairing uses fast header-only `Platform.imageSize(path)`:
/// - Page 0 stands alone when `separateCover` is enabled.
/// - Any landscape page (`width > height`) stands alone as a solo spread so
///   panoramic double-page artwork never shifts subsequent pairs off by one.
Item {
    id: dual

    property var images: []
    property int currentIndex: -1
    property bool rtl: false
    property bool separateCover: true
    property int pageGap: 8
    property bool smoothFiltering: true
    property bool colorAdjustActive: false
    property real brightness: 0
    property real contrast: 0
    property real saturation: 0

    /// Cached header dimensions `{ path: { w, h } }` so rebuilding spreads on
    /// option toggles never re-opens files.
    property var _sizeCache: ({})

    function probeSize(path) {
        if (!path) return { w: 0, h: 0 }
        if (dual._sizeCache[path]) return dual._sizeCache[path]
        var w = 0
        var h = 0
        if (typeof Platform !== "undefined" && Platform && Platform.imageSize) {
            var sz = Platform.imageSize(path)
            if (sz && sz.width > 0 && sz.height > 0) {
                w = sz.width
                h = sz.height
            }
        }
        var entry = { w: w, h: h }
        dual._sizeCache[path] = entry
        return entry
    }

    onImagesChanged: {
        dual._sizeCache = ({})
    }

    /// Precomputed array of spreads: `[[0], [1, 2], [3], [4, 5], ...]`.
    readonly property var spreads: {
        var list = dual.images || []
        var count = list.length
        if (count === 0) return []
        var result = []
        var i = 0
        if (dual.separateCover && count > 1) {
            result.push([0])
            i = 1
        }
        while (i < count) {
            var szA = dual.probeSize(list[i])
            var aLandscape = szA.w > 0 && szA.h > 0 && szA.w > szA.h
            if (aLandscape || i + 1 >= count) {
                result.push([i])
                i += 1
            } else {
                var szB = dual.probeSize(list[i + 1])
                var bLandscape = szB.w > 0 && szB.h > 0 && szB.w > szB.h
                if (bLandscape) {
                    result.push([i])
                    i += 1
                } else {
                    result.push([i, i + 1])
                    i += 2
                }
            }
        }
        return result
    }

    readonly property int spreadIndex: {
        var sp = dual.spreads
        var idx = dual.currentIndex
        for (var s = 0; s < sp.length; ++s) {
            var pair = sp[s]
            for (var k = 0; k < pair.length; ++k) {
                if (pair[k] === idx) return s
            }
        }
        return sp.length > 0 ? 0 : -1
    }

    readonly property var currentSpread:
        (dual.spreadIndex >= 0 && dual.spreadIndex < dual.spreads.length)
        ? dual.spreads[dual.spreadIndex] : []

    /// Ordered visual slots: `[leftIndex, rightIndex]` where `rightIndex` is -1
    /// for a solo spread. In RTL mode the newer page sits on the left.
    readonly property int leftPageIndex: {
        var sp = dual.currentSpread
        if (sp.length === 0) return -1
        if (sp.length === 1) return sp[0]
        return dual.rtl ? sp[1] : sp[0]
    }
    readonly property int rightPageIndex: {
        var sp = dual.currentSpread
        if (sp.length < 2) return -1
        return dual.rtl ? sp[0] : sp[1]
    }

    readonly property string leftPath:
        (dual.leftPageIndex >= 0 && dual.leftPageIndex < dual.images.length)
        ? dual.images[dual.leftPageIndex] : ""
    readonly property string rightPath:
        (dual.rightPageIndex >= 0 && dual.rightPageIndex < dual.images.length)
        ? dual.images[dual.rightPageIndex] : ""

    /// Returns the first image index of the neighbouring spread (`delta = +1`
    /// advances forward in reading order, `-1` goes backward), with wrap-around.
    function targetIndexForSpreadStep(delta) {
        var sp = dual.spreads
        if (sp.length === 0) return -1
        var cur = dual.spreadIndex >= 0 ? dual.spreadIndex : 0
        var next = (cur + delta + sp.length) % sp.length
        return sp[next][0]
    }

    /// Natural dimensions of both pages, captured imperatively on Image.Ready
    /// (avoiding QML implicitWidth/width binding-loop checks) and normalized so
    /// the top and bottom edges of a 2-page spread align cleanly.
    property real leftNatW: 0
    property real leftNatH: 0
    property real rightNatW: 0
    property real rightNatH: 0

    readonly property bool hasRight: dual.rightPath.length > 0
    readonly property real targetHeight:
        dual.hasRight
        ? Math.max(dual.leftNatH, dual.rightNatH)
        : dual.leftNatH

    readonly property real leftDisplayW:
        (dual.leftNatH > 0 && dual.targetHeight > 0)
        ? Math.round(dual.leftNatW * (dual.targetHeight / dual.leftNatH))
        : dual.leftNatW
    readonly property real rightDisplayW:
        (dual.hasRight && dual.rightNatH > 0 && dual.targetHeight > 0)
        ? Math.round(dual.rightNatW * (dual.targetHeight / dual.rightNatH))
        : 0

    readonly property real contentWidth:
        dual.hasRight && dual.rightDisplayW > 0
        ? dual.leftDisplayW + dual.pageGap + dual.rightDisplayW
        : dual.leftDisplayW
    readonly property real contentHeight: dual.targetHeight

    readonly property bool ready:
        dual.leftPath.length > 0 && leftImg.status === Image.Ready
        && (!dual.hasRight || rightImg.status === Image.Ready)

    signal spreadReady()
    signal geometryChanged()

    onReadyChanged: {
        if (dual.ready) dual.spreadReady()
    }
    onContentWidthChanged: {
        if (dual.ready) dual.geometryChanged()
    }
    onContentHeightChanged: {
        if (dual.ready) dual.geometryChanged()
    }
    onSeparateCoverChanged: {
        if (dual.ready) dual.geometryChanged()
    }
    onRtlChanged: {
        if (dual.ready) dual.geometryChanged()
    }
    onPageGapChanged: {
        if (dual.ready) dual.geometryChanged()
    }

    width: dual.contentWidth
    height: dual.contentHeight

    layer.enabled: dual.colorAdjustActive
    layer.effect: MultiEffect {
        brightness: dual.brightness
        contrast: dual.contrast
        saturation: dual.saturation
    }

    Image {
        id: leftImg
        objectName: "dualLeftImage"
        x: 0
        y: 0
        width: dual.leftDisplayW
        height: dual.targetHeight
        source: (dual.visible && dual.leftPath) ? "file://" + dual.leftPath : ""
        asynchronous: true
        cache: false
        smooth: dual.smoothFiltering
        mipmap: dual.smoothFiltering
        fillMode: Image.PreserveAspectFit
        onStatusChanged: {
            if (status === Image.Ready) {
                dual.leftNatW = implicitWidth
                dual.leftNatH = implicitHeight
            } else {
                dual.leftNatW = 0
                dual.leftNatH = 0
            }
        }
    }

    Image {
        id: rightImg
        objectName: "dualRightImage"
        visible: dual.hasRight
        x: dual.leftDisplayW + dual.pageGap
        y: 0
        width: dual.rightDisplayW
        height: dual.targetHeight
        source: (dual.visible && dual.rightPath) ? "file://" + dual.rightPath : ""
        asynchronous: true
        cache: false
        smooth: dual.smoothFiltering
        mipmap: dual.smoothFiltering
        fillMode: Image.PreserveAspectFit
        onStatusChanged: {
            if (status === Image.Ready) {
                dual.rightNatW = implicitWidth
                dual.rightNatH = implicitHeight
            } else {
                dual.rightNatW = 0
                dual.rightNatH = 0
            }
        }
    }
}
