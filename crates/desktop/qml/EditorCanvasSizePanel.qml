import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Sidebar options panel for Canvas Size (expand/crop canvas without scaling
/// image pixels) with unit selector (`px` / `%`), 3x3 anchor grid and live
/// 60 fps canvas preview.
ColumnLayout {
    id: panel
    objectName: "canvasSizeOptions"
    spacing: 10

    property Theme theme: Theme {}
    property int sourceWidth: 0
    property int sourceHeight: 0
    property int targetWidth: 0
    property int targetHeight: 0
    property string anchor: "center"
    property bool _syncing: false

    readonly property bool valid: targetWidth >= 1 && targetWidth <= 16384
                                  && targetHeight >= 1 && targetHeight <= 16384
    readonly property bool changed: valid
                                    && (targetWidth !== sourceWidth || targetHeight !== sourceHeight)

    readonly property int imageOffsetX: {
        var dw = targetWidth - sourceWidth
        if (anchor === "top_left" || anchor === "left" || anchor === "bottom_left") return 0
        if (anchor === "top_right" || anchor === "right" || anchor === "bottom_right") return dw
        return Math.round(dw / 2)
    }
    readonly property int imageOffsetY: {
        var dh = targetHeight - sourceHeight
        if (anchor === "top_left" || anchor === "top" || anchor === "top_right") return 0
        if (anchor === "bottom_left" || anchor === "bottom" || anchor === "bottom_right") return dh
        return Math.round(dh / 2)
    }

    readonly property var anchorCells: [
        { key: "top_left", glyph: "↖" },
        { key: "top", glyph: "↑" },
        { key: "top_right", glyph: "↗" },
        { key: "left", glyph: "←" },
        { key: "center", glyph: "•" },
        { key: "right", glyph: "→" },
        { key: "bottom_left", glyph: "↙" },
        { key: "bottom", glyph: "↓" },
        { key: "bottom_right", glyph: "↘" }
    ]

    function reset() {
        _syncing = true
        targetWidth = Math.max(1, sourceWidth)
        targetHeight = Math.max(1, sourceHeight)
        anchor = "center"
        widthField.setPixels(targetWidth)
        heightField.setPixels(targetHeight)
        _syncing = false
    }

    onSourceWidthChanged: {
        if (targetWidth <= 0 && sourceWidth > 0) reset()
    }
    onSourceHeightChanged: {
        if (targetHeight <= 0 && sourceHeight > 0) reset()
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
            text: qsTr("Width")
            color: panel.theme.textMuted
            Layout.preferredWidth: 50
        }
        UnitField {
            id: widthField
            objectName: "canvasSizePanelWidth"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            unitReference: panel.sourceWidth > 0 ? panel.sourceWidth : 1
            minimumPixels: 1
            maximumPixels: 16384
            nextField: heightField
            onTextEdited: {
                if (panel._syncing) return
                var w = widthField.pixels()
                if (w > 0) panel.targetWidth = Math.max(1, Math.min(16384, w))
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
            text: qsTr("Height")
            color: panel.theme.textMuted
            Layout.preferredWidth: 50
        }
        UnitField {
            id: heightField
            objectName: "canvasSizePanelHeight"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            unitReference: panel.sourceHeight > 0 ? panel.sourceHeight : 1
            minimumPixels: 1
            maximumPixels: 16384
            previousField: widthField
            onTextEdited: {
                if (panel._syncing) return
                var h = heightField.pixels()
                if (h > 0) panel.targetHeight = Math.max(1, Math.min(16384, h))
            }
        }
    }

    Label {
        text: qsTr("Anchor")
        color: panel.theme.textMuted
    }

    GridLayout {
        Layout.alignment: Qt.AlignHCenter
        columns: 3
        columnSpacing: 4
        rowSpacing: 4

        Repeater {
            model: panel.anchorCells
            delegate: Button {
                required property var modelData
                readonly property bool selected: panel.anchor === modelData.key
                implicitWidth: 36
                implicitHeight: 30
                text: modelData.glyph
                focusPolicy: Qt.NoFocus
                highlighted: selected
                onClicked: panel.anchor = modelData.key
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
            text: qsTr("Delta")
            color: panel.theme.textMuted
            Layout.fillWidth: true
        }
        Label {
            objectName: "canvasSizePanelDelta"
            property int dw: panel.targetWidth - panel.sourceWidth
            property int dh: panel.targetHeight - panel.sourceHeight
            text: (dw >= 0 ? "+" : "") + dw + " × " + (dh >= 0 ? "+" : "") + dh + " px"
            color: panel.theme.text
            font.bold: true
        }
    }
}
