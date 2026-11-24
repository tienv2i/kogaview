import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Krita-style Color Adjustment Curves dialog built on the shared
/// `DialogFrame` + `DialogFooter`. Supports RGB / Red / Green / Blue channels
/// with Fritsch-Carlson monotone cubic Hermite splines, click-to-add,
/// right-click or drag-out to remove, presets, and live in-RAM preview
/// respecting active layer vs whole image and any active selection mask.
DialogFrame {
    id: dialog
    objectName: "editorCurvesDialog"
    namePrefix: "curves"
    title: qsTr("Curves")
    modal: false
    dim: false
    preferredWidth: 380
    minWidth: 340
    fitToContent: true

    property bool hasMultipleLayers: false
    property bool hasSelection: false
    property string applyTarget: "active_layer"
    property bool previewEnabled: true

    property string activeChannel: "rgb"
    property var curves: ({
        rgb: [[0, 0], [1, 1]],
        red: [[0, 0], [1, 1]],
        green: [[0, 0], [1, 1]],
        blue: [[0, 0], [1, 1]]
    })
    property int selectedIndex: -1

    signal previewRequested(var rgb, var red, var green, var blue, string target)
    signal previewCleared()
    signal applyRequested(var rgb, var red, var green, var blue, string target)

    property bool _committed: false

    function defaultCurves() {
        return {
            rgb: [[0, 0], [1, 1]],
            red: [[0, 0], [1, 1]],
            green: [[0, 0], [1, 1]],
            blue: [[0, 0], [1, 1]]
        }
    }

    function isChannelIdentity(pts) {
        if (!pts || pts.length !== 2) return false
        return Math.abs(pts[0][0]) < 1e-4 && Math.abs(pts[0][1]) < 1e-4
               && Math.abs(pts[1][0] - 1.0) < 1e-4 && Math.abs(pts[1][1] - 1.0) < 1e-4
    }

    readonly property bool hasChanges: {
        var c = dialog.curves
        return !isChannelIdentity(c.rgb) || !isChannelIdentity(c.red)
               || !isChannelIdentity(c.green) || !isChannelIdentity(c.blue)
    }

    function prepare() {
        _committed = false
        curves = defaultCurves()
        activeChannel = "rgb"
        selectedIndex = -1
        previewEnabled = true
        if (parent) {
            x = Math.max(16, parent.width - width - 24)
            y = Math.max(16, Math.min(56, Math.round((parent.height - height) / 2)))
            moved = true
        }
        curveCanvas.requestPaint()
    }

    function setChannelPoints(channel, pts) {
        var next = {
            rgb: dialog.curves.rgb.slice(),
            red: dialog.curves.red.slice(),
            green: dialog.curves.green.slice(),
            blue: dialog.curves.blue.slice()
        }
        next[channel] = pts
        dialog.curves = next
        curveCanvas.requestPaint()
        dialog.schedulePreview()
    }

    function resetActiveChannel() {
        selectedIndex = -1
        setChannelPoints(activeChannel, [[0, 0], [1, 1]])
    }

    function resetAll() {
        selectedIndex = -1
        curves = defaultCurves()
        curveCanvas.requestPaint()
        schedulePreview()
    }

    function applyPreset(key) {
        var pts = [[0, 0], [1, 1]]
        if (key === "scurve") {
            pts = [[0, 0], [0.25, 0.18], [0.5, 0.5], [0.75, 0.82], [1, 1]]
        } else if (key === "lighter") {
            pts = [[0, 0], [0.5, 0.65], [1, 1]]
        } else if (key === "darker") {
            pts = [[0, 0], [0.5, 0.35], [1, 1]]
        } else if (key === "invert") {
            pts = [[0, 1], [1, 0]]
        }
        selectedIndex = -1
        setChannelPoints(activeChannel, pts)
    }

    function schedulePreview() {
        if (!dialog.opened) return
        if (!dialog.previewEnabled || !dialog.hasChanges) {
            previewTimer.stop()
            dialog.previewCleared()
            return
        }
        previewTimer.restart()
    }

    Timer {
        id: previewTimer
        interval: 35
        onTriggered: {
            if (dialog.opened && dialog.previewEnabled && dialog.hasChanges) {
                dialog.previewRequested(
                    dialog.curves.rgb,
                    dialog.curves.red,
                    dialog.curves.green,
                    dialog.curves.blue,
                    dialog.hasMultipleLayers ? dialog.applyTarget : "active_layer"
                )
            }
        }
    }

    onCloseRequested: dialog.close()
    onClosed: {
        previewTimer.stop()
        if (!_committed) {
            dialog.previewCleared()
        }
    }

    function sampleCurve(points, steps) {
        var pts = (points || []).slice().sort(function(a, b) { return a[0] - b[0] })
        var dedup = []
        for (var i = 0; i < pts.length; ++i) {
            if (dedup.length > 0 && Math.abs(pts[i][0] - dedup[dedup.length - 1][0]) < 1e-4) {
                dedup[dedup.length - 1] = [dedup[dedup.length - 1][0], pts[i][1]]
            } else {
                dedup.push([pts[i][0], pts[i][1]])
            }
        }
        var n = dedup.length
        var out = []
        if (n < 2) {
            for (var s = 0; s <= steps; ++s) {
                var v = s / steps
                out.push([v, v])
            }
            return out
        }
        var h = []
        var d = []
        for (var j = 0; j < n - 1; ++j) {
            h.push(Math.max(1e-6, dedup[j + 1][0] - dedup[j][0]))
            d.push((dedup[j + 1][1] - dedup[j][1]) / h[j])
        }
        var m = new Array(n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for (var k = 1; k < n - 1; ++k) {
            if (d[k - 1] * d[k] <= 0) m[k] = 0
            else {
                var w1 = 2 * h[k] + h[k - 1]
                var w2 = h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
            }
        }
        for (var p = 0; p < n - 1; ++p) {
            if (Math.abs(d[p]) < 1e-9) {
                m[p] = 0; m[p + 1] = 0
            } else {
                var a = m[p] / d[p]
                var b = m[p + 1] / d[p]
                var sum = a * a + b * b
                if (sum > 9.0) {
                    var tau = 3.0 / Math.sqrt(sum)
                    m[p] = tau * a * d[p]
                    m[p + 1] = tau * b * d[p]
                }
            }
        }
        var seg = 0
        for (var step = 0; step <= steps; ++step) {
            var x = step / steps
            var y = x
            if (x <= dedup[0][0]) y = dedup[0][1]
            else if (x >= dedup[n - 1][0]) y = dedup[n - 1][1]
            else {
                while (seg + 1 < n - 1 && x > dedup[seg + 1][0]) seg++
                var hi = h[seg]
                var t = Math.max(0, Math.min(1, (x - dedup[seg][0]) / hi))
                var t2 = t * t
                var t3 = t2 * t
                y = (2 * t3 - 3 * t2 + 1) * dedup[seg][1]
                    + (t3 - 2 * t2 + t) * hi * m[seg]
                    + (-2 * t3 + 3 * t2) * dedup[seg + 1][1]
                    + (t3 - t2) * hi * m[seg + 1]
            }
            out.push([x, Math.max(0, Math.min(1, y))])
        }
        return out
    }

    function channelColor(ch) {
        if (ch === "red") return "#ef4444"
        if (ch === "green") return "#22c55e"
        if (ch === "blue") return "#3b82f6"
        return dialog.theme.text
    }

    // Channel chips: RGB | Red | Green | Blue
    RowLayout {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: [
                { key: "rgb", label: "RGB" },
                { key: "red", label: qsTr("Red") },
                { key: "green", label: qsTr("Green") },
                { key: "blue", label: qsTr("Blue") }
            ]
            delegate: PanelAction {
                required property var modelData
                objectName: "curveChannel_" + modelData.key
                Layout.fillWidth: true
                theme: dialog.theme
                text: modelData.label
                primary: dialog.activeChannel === modelData.key
                onClicked: {
                    dialog.activeChannel = modelData.key
                    dialog.selectedIndex = -1
                    curveCanvas.requestPaint()
                }
            }
        }
    }

    // Target & Selection context bar
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: dialog.hasMultipleLayers || dialog.hasSelection

        ComboBox {
            objectName: "curvesTargetCombo"
            visible: dialog.hasMultipleLayers
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            model: [qsTr("Active layer"), qsTr("Whole image")]
            currentIndex: dialog.applyTarget === "whole_image" ? 1 : 0
            onActivated: function(idx) {
                dialog.applyTarget = idx === 1 ? "whole_image" : "active_layer"
                dialog.schedulePreview()
            }
        }

        Rectangle {
            visible: dialog.hasSelection
            Layout.preferredHeight: 24
            Layout.preferredWidth: curveSelBadge.implicitWidth + 14
            radius: 4
            color: dialog.theme.selection
            border.width: 1
            border.color: dialog.theme.accent
            Label {
                id: curveSelBadge
                anchors.centerIn: parent
                text: qsTr("Selection")
                color: dialog.theme.text
                font.pixelSize: 11
                font.bold: true
            }
        }
    }

    // Interactive Curve Graph
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 240
        radius: 4
        color: dialog.theme.dark ? "#17191d" : "#f4f6f9"
        border.width: 1
        border.color: dialog.theme.border
        clip: true

        Canvas {
            id: curveCanvas
            objectName: "curveGraphCanvas"
            anchors.fill: parent
            anchors.margins: 10

            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                if (width <= 2 || height <= 2) return

                ctx.strokeStyle = dialog.theme.dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.10)"
                ctx.lineWidth = 1
                for (var g = 0; g <= 4; ++g) {
                    var gx = Math.round(width * g / 4) + 0.5
                    var gy = Math.round(height * g / 4) + 0.5
                    ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, height); ctx.stroke()
                    ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(width, gy); ctx.stroke()
                }

                ctx.save()
                ctx.setLineDash([4, 4])
                ctx.strokeStyle = dialog.theme.dark ? "rgba(255,255,255,0.22)" : "rgba(0,0,0,0.22)"
                ctx.beginPath()
                ctx.moveTo(0, height)
                ctx.lineTo(width, 0)
                ctx.stroke()
                ctx.restore()

                var channels = ["rgb", "red", "green", "blue"]
                for (var cIdx = 0; cIdx < channels.length; ++cIdx) {
                    var ch = channels[cIdx]
                    if (ch === dialog.activeChannel) continue
                    var cPts = dialog.curves[ch]
                    if (dialog.isChannelIdentity(cPts)) continue
                    var cSamples = dialog.sampleCurve(cPts, 128)
                    ctx.save()
                    ctx.globalAlpha = 0.35
                    ctx.strokeStyle = dialog.channelColor(ch)
                    ctx.lineWidth = 1.5
                    ctx.beginPath()
                    for (var si = 0; si < cSamples.length; ++si) {
                        var sx = cSamples[si][0] * width
                        var sy = (1.0 - cSamples[si][1]) * height
                        if (si === 0) ctx.moveTo(sx, sy)
                        else ctx.lineTo(sx, sy)
                    }
                    ctx.stroke()
                    ctx.restore()
                }

                var activePts = dialog.curves[dialog.activeChannel] || [[0, 0], [1, 1]]
                var samples = dialog.sampleCurve(activePts, 160)
                ctx.strokeStyle = dialog.channelColor(dialog.activeChannel)
                ctx.lineWidth = 2.2
                ctx.beginPath()
                for (var i = 0; i < samples.length; ++i) {
                    var px = samples[i][0] * width
                    var py = (1.0 - samples[i][1]) * height
                    if (i === 0) ctx.moveTo(px, py)
                    else ctx.lineTo(px, py)
                }
                ctx.stroke()

                for (var k = 0; k < activePts.length; ++k) {
                    var kx = activePts[k][0] * width
                    var ky = (1.0 - activePts[k][1]) * height
                    var isSel = k === dialog.selectedIndex
                    ctx.beginPath()
                    ctx.arc(kx, ky, isSel ? 5.5 : 4.2, 0, Math.PI * 2)
                    ctx.fillStyle = isSel ? dialog.theme.accent : dialog.theme.surface
                    ctx.fill()
                    ctx.lineWidth = 1.8
                    ctx.strokeStyle = dialog.channelColor(dialog.activeChannel)
                    ctx.stroke()
                }
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -8
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.CrossCursor
                property int dragIndex: -1

                function toNorm(mx, my) {
                    return [(mx - 8) / Math.max(1, curveCanvas.width),
                            1.0 - (my - 8) / Math.max(1, curveCanvas.height)]
                }

                function hitPoint(pts, mx, my) {
                    var best = -1
                    var bestDist = 13
                    for (var i = 0; i < pts.length; ++i) {
                        var px = pts[i][0] * curveCanvas.width + 8
                        var py = (1.0 - pts[i][1]) * curveCanvas.height + 8
                        var d = Math.hypot(mx - px, my - py)
                        if (d < bestDist) { bestDist = d; best = i }
                    }
                    return best
                }

                onPressed: function(mouse) {
                    var pts = (dialog.curves[dialog.activeChannel] || [[0, 0], [1, 1]]).slice()
                    var hit = hitPoint(pts, mouse.x, mouse.y)
                    if (mouse.button === Qt.RightButton) {
                        if (hit > 0 && hit < pts.length - 1) {
                            pts.splice(hit, 1)
                            dialog.selectedIndex = -1
                            dialog.setChannelPoints(dialog.activeChannel, pts)
                        }
                        return
                    }
                    if (hit >= 0) {
                        dragIndex = hit
                        dialog.selectedIndex = hit
                        curveCanvas.requestPaint()
                        return
                    }
                    var norm = toNorm(mouse.x, mouse.y)
                    var nx = Math.max(0.01, Math.min(0.99, norm[0]))
                    var ny = Math.max(0.0, Math.min(1.0, norm[1]))
                    pts.push([nx, ny])
                    pts.sort(function(a, b) { return a[0] - b[0] })
                    var inserted = 0
                    for (var i = 0; i < pts.length; ++i) {
                        if (Math.abs(pts[i][0] - nx) < 1e-6 && Math.abs(pts[i][1] - ny) < 1e-6) {
                            inserted = i; break
                        }
                    }
                    dragIndex = inserted
                    dialog.selectedIndex = inserted
                    dialog.setChannelPoints(dialog.activeChannel, pts)
                }

                onPositionChanged: function(mouse) {
                    if (!pressed || dragIndex < 0) return
                    var pts = (dialog.curves[dialog.activeChannel] || [[0, 0], [1, 1]]).slice()
                    if (dragIndex >= pts.length) return
                    var norm = toNorm(mouse.x, mouse.y)
                    var nx = norm[0]
                    var ny = Math.max(0.0, Math.min(1.0, norm[1]))
                    if (dragIndex > 0 && dragIndex < pts.length - 1
                            && (nx < -0.15 || nx > 1.15 || norm[1] < -0.20 || norm[1] > 1.20)) {
                        pts.splice(dragIndex, 1)
                        dragIndex = -1
                        dialog.selectedIndex = -1
                        dialog.setChannelPoints(dialog.activeChannel, pts)
                        return
                    }
                    if (dragIndex === 0) nx = 0.0
                    else if (dragIndex === pts.length - 1) nx = 1.0
                    else nx = Math.max(pts[dragIndex - 1][0] + 0.01, Math.min(pts[dragIndex + 1][0] - 0.01, nx))
                    pts[dragIndex] = [nx, ny]
                    dialog.setChannelPoints(dialog.activeChannel, pts)
                }

                onReleased: dragIndex = -1
            }
        }
    }

    Label {
        Layout.fillWidth: true
        color: dialog.theme.textMuted
        font.pixelSize: 11
        wrapMode: Text.WordWrap
        text: {
            var pts = dialog.curves[dialog.activeChannel] || []
            if (dialog.selectedIndex >= 0 && dialog.selectedIndex < pts.length) {
                var p = pts[dialog.selectedIndex]
                return qsTr("Input: %1 · Output: %2")
                    .arg(Math.round(p[0] * 255))
                    .arg(Math.round(p[1] * 255))
            }
            return qsTr("Click curve to add point · Right-click or drag out to remove")
        }
    }

    // Quick presets
    RowLayout {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: [
                { key: "scurve", label: qsTr("S-Curve") },
                { key: "lighter", label: qsTr("Lighter") },
                { key: "darker", label: qsTr("Darker") },
                { key: "invert", label: qsTr("Invert") }
            ]
            delegate: PanelAction {
                required property var modelData
                Layout.fillWidth: true
                theme: dialog.theme
                text: modelData.label
                onClicked: dialog.applyPreset(modelData.key)
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        CheckBox {
            text: qsTr("Preview")
            focusPolicy: Qt.NoFocus
            checked: dialog.previewEnabled
            onToggled: {
                dialog.previewEnabled = checked
                dialog.schedulePreview()
            }
        }

        Item { Layout.fillWidth: true }

        PanelAction {
            theme: dialog.theme
            text: qsTr("Reset channel")
            onClicked: dialog.resetActiveChannel()
        }
    }

    footer: DialogFooter {
        theme: dialog.theme
        namePrefix: dialog.namePrefix

        PanelAction {
            theme: dialog.theme
            text: qsTr("Reset all")
            enabled: dialog.hasChanges
            onClicked: dialog.resetAll()
        }

        Item { Layout.fillWidth: true }

        PanelAction {
            theme: dialog.theme
            text: qsTr("Cancel")
            onClicked: dialog.close()
        }

        PanelAction {
            objectName: "curvesDialogApply"
            theme: dialog.theme
            text: qsTr("Apply")
            primary: true
            enabled: dialog.hasChanges
            onClicked: {
                dialog._committed = true
                previewTimer.stop()
                dialog.applyRequested(
                    dialog.curves.rgb,
                    dialog.curves.red,
                    dialog.curves.green,
                    dialog.curves.blue,
                    dialog.hasMultipleLayers ? dialog.applyTarget : "active_layer"
                )
                dialog.close()
            }
        }
    }
}
