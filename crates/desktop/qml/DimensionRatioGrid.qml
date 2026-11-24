import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Shared Width / Height / Ratio control grid matching the Editor Crop tool's
/// layout and 2-of-3 lock semantics, reused by Resize and Canvas Size panels.
GridLayout {
    id: grid

    property Theme theme: Theme {}
    property int sourceWidth: 0
    property int sourceHeight: 0
    property int targetWidth: 0
    property int targetHeight: 0
    property int minimumPixels: 1
    property int maximumPixels: 16384

    property bool lockWidth: false
    property bool lockHeight: false
    property bool lockRatio: false
    property string ratioText: ""

    /// Object name prefix for fields & lock buttons (e.g. `"resizePanel"` or `"canvasSizePanel"`).
    property string namePrefix: "dimGrid"

    property bool _syncing: false

    readonly property bool widthEditable: !grid.lockWidth
    readonly property bool heightEditable: !grid.lockHeight
    readonly property bool ratioEditable: !(grid.lockWidth && grid.lockHeight)

    columns: 3
    columnSpacing: 6
    rowSpacing: 8

    component LockToggle: Button {
        id: lockBtn
        property color lockedColor: grid.theme.accent
        property color unlockedColor: grid.theme.textMuted
        implicitWidth: 26
        implicitHeight: 26
        padding: 0
        checkable: true
        focusPolicy: Qt.NoFocus

        contentItem: Item {
            implicitWidth: 16
            implicitHeight: 18

            Canvas {
                id: glyph
                anchors.centerIn: parent
                width: 16
                height: 18
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var colour = lockBtn.checked ? "#ffffff" : lockBtn.unlockedColor
                    ctx.strokeStyle = colour
                    ctx.fillStyle = colour
                    ctx.lineWidth = 1.6
                    ctx.beginPath()
                    ctx.arc(8, 7, 4, Math.PI, 0, false)
                    ctx.stroke()
                    ctx.beginPath()
                    ctx.rect(2, 8, 12, 8)
                    ctx.fill()
                    ctx.fillStyle = lockBtn.checked ? lockBtn.lockedColor : grid.theme.surface
                    ctx.beginPath()
                    ctx.arc(8, 11, 1.1, 0, Math.PI * 2)
                    ctx.fill()
                    ctx.fillRect(7.45, 11, 1.1, 2.4)
                }
            }
        }

        background: Rectangle {
            radius: 3
            color: lockBtn.checked ? lockBtn.lockedColor : "transparent"
            border.width: 1
            border.color: lockBtn.checked ? lockBtn.lockedColor : grid.theme.border
        }

        onCheckedChanged: glyph.requestPaint()
        Connections {
            target: grid.theme
            function onDarkChanged() { glyph.requestPaint() }
        }
    }

    function gcd(a, b) {
        a = Math.abs(Math.round(a))
        b = Math.abs(Math.round(b))
        while (b !== 0) {
            var t = a % b
            a = b
            b = t
        }
        return a > 0 ? a : 1
    }

    function reducedRatio(w, h) {
        if (w <= 0 || h <= 0) return ""
        var d = grid.gcd(w, h)
        return Math.round(w / d) + ":" + Math.round(h / d)
    }

    function parseRatio(raw) {
        var text = (raw || "").trim()
        if (text.length === 0) return null
        var sep = text.indexOf(":") >= 0 ? ":" : (text.indexOf("/") >= 0 ? "/" : "")
        if (sep.length > 0) {
            var parts = text.split(sep)
            if (parts.length !== 2) return null
            var a = Number(parts[0].trim())
            var b = Number(parts[1].trim())
            if (!(a > 0) || !(b > 0)) return null
            return a / b
        }
        var dec = Number(text)
        if (!(dec > 0)) return null
        return dec
    }

    function activeAspect() {
        var parsed = grid.parseRatio(grid.ratioText)
        if (parsed && parsed > 0) return parsed
        if (grid.sourceWidth > 0 && grid.sourceHeight > 0) {
            return grid.sourceWidth / grid.sourceHeight
        }
        if (grid.targetWidth > 0 && grid.targetHeight > 0) {
            return grid.targetWidth / grid.targetHeight
        }
        return 1.0
    }

    function clampPx(v) {
        return Math.max(grid.minimumPixels, Math.min(grid.maximumPixels, Math.round(v)))
    }

    function syncFields() {
        grid._syncing = true
        widthField.setPixels(grid.targetWidth)
        heightField.setPixels(grid.targetHeight)
        if (!ratioField.activeFocus) {
            ratioField.text = grid.ratioText
        }
        grid._syncing = false
    }

    function setDimensions(w, h) {
        grid._syncing = true
        grid.targetWidth = grid.clampPx(w)
        grid.targetHeight = grid.clampPx(h)
        if (!grid.lockRatio) {
            grid.ratioText = grid.reducedRatio(grid.targetWidth, grid.targetHeight)
        }
        widthField.setPixels(grid.targetWidth)
        heightField.setPixels(grid.targetHeight)
        if (!ratioField.activeFocus) {
            ratioField.text = grid.ratioText
        }
        grid._syncing = false
    }

    function reset(w, h, defaultLockRatio) {
        grid._syncing = true
        grid.lockWidth = false
        grid.lockHeight = false
        grid.lockRatio = !!defaultLockRatio
        grid.targetWidth = grid.clampPx(Math.max(1, w))
        grid.targetHeight = grid.clampPx(Math.max(1, h))
        grid.ratioText = grid.reducedRatio(grid.targetWidth, grid.targetHeight)
        widthField.setPixels(grid.targetWidth)
        heightField.setPixels(grid.targetHeight)
        ratioField.text = grid.ratioText
        grid._syncing = false
    }

    function setLock(which, locked) {
        if (which === "width") {
            grid.lockWidth = locked
            if (locked && grid.lockHeight && grid.lockRatio) grid.lockRatio = false
        } else if (which === "height") {
            grid.lockHeight = locked
            if (locked && grid.lockWidth && grid.lockRatio) grid.lockRatio = false
        } else if (which === "ratio") {
            grid.lockRatio = locked
            if (locked && grid.lockWidth && grid.lockHeight) grid.lockHeight = false
            if (locked && grid.ratioText.trim().length === 0) {
                grid.ratioText = grid.reducedRatio(grid.targetWidth, grid.targetHeight)
                if (!ratioField.activeFocus) ratioField.text = grid.ratioText
            }
        }
    }

    function applyWidthFromField() {
        if (grid._syncing) return
        var w = widthField.pixels()
        if (w <= 0) return
        grid._syncing = true
        var clampedW = grid.clampPx(w)
        grid.targetWidth = clampedW
        if (grid.lockRatio && !grid.lockHeight) {
            var aspect = grid.activeAspect()
            grid.targetHeight = grid.clampPx(clampedW / aspect)
            heightField.setPixels(grid.targetHeight)
        } else if (!grid.lockRatio) {
            grid.ratioText = grid.reducedRatio(grid.targetWidth, grid.targetHeight)
            if (!ratioField.activeFocus) ratioField.text = grid.ratioText
        }
        grid._syncing = false
    }

    function applyHeightFromField() {
        if (grid._syncing) return
        var h = heightField.pixels()
        if (h <= 0) return
        grid._syncing = true
        var clampedH = grid.clampPx(h)
        grid.targetHeight = clampedH
        if (grid.lockRatio && !grid.lockWidth) {
            var aspect = grid.activeAspect()
            grid.targetWidth = grid.clampPx(clampedH * aspect)
            widthField.setPixels(grid.targetWidth)
        } else if (!grid.lockRatio) {
            grid.ratioText = grid.reducedRatio(grid.targetWidth, grid.targetHeight)
            if (!ratioField.activeFocus) ratioField.text = grid.ratioText
        }
        grid._syncing = false
    }

    function applyRatioFromField(commitFormat) {
        if (grid._syncing) return
        var raw = ratioField.text.trim()
        if (raw.length === 0) {
            grid.ratioText = ""
            grid.lockRatio = false
            return
        }
        var aspect = grid.parseRatio(raw)
        if (!aspect || aspect <= 0) return
        grid._syncing = true
        grid.ratioText = raw
        if (grid.lockHeight && !grid.lockWidth) {
            grid.targetWidth = grid.clampPx(grid.targetHeight * aspect)
            widthField.setPixels(grid.targetWidth)
        } else if (!grid.lockHeight) {
            grid.targetHeight = grid.clampPx(grid.targetWidth / aspect)
            heightField.setPixels(grid.targetHeight)
        }
        if (commitFormat) {
            ratioField.text = grid.ratioText
        }
        grid._syncing = false
    }

    Label {
        text: qsTr("Width")
        color: grid.theme.textMuted
        Layout.preferredWidth: 50
    }
    UnitField {
        id: widthField
        objectName: grid.namePrefix + "Width"
        Layout.fillWidth: true
        Layout.preferredHeight: 30
        font.pixelSize: 12
        unitReference: grid.sourceWidth > 0 ? grid.sourceWidth : 1
        minimumPixels: grid.minimumPixels
        maximumPixels: grid.maximumPixels
        enabled: grid.widthEditable
        nextField: heightField
        onTextEdited: grid.applyWidthFromField()
    }
    LockToggle {
        objectName: grid.namePrefix + "LockWidth"
        checked: grid.lockWidth
        Accessible.name: qsTr("Lock width")
        ToolTip.visible: hovered
        ToolTip.text: qsTr("Lock width")
        onToggled: grid.setLock("width", checked)
    }

    Label {
        text: qsTr("Height")
        color: grid.theme.textMuted
        Layout.preferredWidth: 50
    }
    UnitField {
        id: heightField
        objectName: grid.namePrefix + "Height"
        Layout.fillWidth: true
        Layout.preferredHeight: 30
        font.pixelSize: 12
        unitReference: grid.sourceHeight > 0 ? grid.sourceHeight : 1
        minimumPixels: grid.minimumPixels
        maximumPixels: grid.maximumPixels
        enabled: grid.heightEditable
        previousField: widthField
        onTextEdited: grid.applyHeightFromField()
    }
    LockToggle {
        objectName: grid.namePrefix + "LockHeight"
        checked: grid.lockHeight
        Accessible.name: qsTr("Lock height")
        ToolTip.visible: hovered
        ToolTip.text: qsTr("Lock height")
        onToggled: grid.setLock("height", checked)
    }

    Label {
        text: qsTr("Ratio")
        color: grid.theme.textMuted
        Layout.preferredWidth: 50
    }
    TextField {
        id: ratioField
        objectName: grid.namePrefix + "Ratio"
        Layout.fillWidth: true
        Layout.preferredHeight: 30
        font.pixelSize: 12
        placeholderText: qsTr("Free")
        enabled: grid.ratioEditable
        Keys.onEscapePressed: focus = false
        onTextEdited: grid.applyRatioFromField(false)
        onEditingFinished: grid.applyRatioFromField(true)
    }
    LockToggle {
        objectName: grid.namePrefix + "LockRatio"
        checked: grid.lockRatio
        Accessible.name: qsTr("Lock ratio")
        ToolTip.visible: hovered
        ToolTip.text: qsTr("Lock ratio")
        onToggled: grid.setLock("ratio", checked)
    }
}
