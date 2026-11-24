import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Sidebar options panel for Canvas Size (expand/crop canvas without scaling
/// image pixels) using the shared Crop-style Width / Height / Ratio grid
/// (`DimensionRatioGrid`), 3x3 anchor grid, and live 60 fps canvas preview.
ColumnLayout {
    id: panel
    objectName: "canvasSizeOptions"
    spacing: 10

    property Theme theme: Theme {}
    property int sourceWidth: 0
    property int sourceHeight: 0
    property alias targetWidth: dimGrid.targetWidth
    property alias targetHeight: dimGrid.targetHeight
    property alias lockRatio: dimGrid.lockRatio
    property string anchor: "center"
    /// True when the user dragged canvas handles directly on the viewport;
    /// stores the exact image offset inside the new canvas frame so pulling one
    /// edge never shifts the opposite edge. Reset when an Anchor is clicked.
    property bool customOffset: false
    property int customOffsetX: 0
    property int customOffsetY: 0

    readonly property bool valid: targetWidth >= 1 && targetWidth <= 16384
                                  && targetHeight >= 1 && targetHeight <= 16384
    readonly property bool changed: valid
                                    && (targetWidth !== sourceWidth
                                        || targetHeight !== sourceHeight
                                        || (customOffset && (customOffsetX !== 0 || customOffsetY !== 0)))

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
    readonly property int effectiveOffsetX: customOffset ? customOffsetX : imageOffsetX
    readonly property int effectiveOffsetY: customOffset ? customOffsetY : imageOffsetY

    function setCustomFrame(w, h, offsetX, offsetY) {
        customOffset = true
        customOffsetX = Math.round(offsetX)
        customOffsetY = Math.round(offsetY)
        dimGrid.setDimensions(Math.max(1, Math.min(16384, Math.round(w))),
                              Math.max(1, Math.min(16384, Math.round(h))))
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
        anchor = "center"
        customOffset = false
        customOffsetX = 0
        customOffsetY = 0
        dimGrid.reset(Math.max(1, sourceWidth), Math.max(1, sourceHeight), false)
    }

    onSourceWidthChanged: {
        if (targetWidth <= 0 && sourceWidth > 0) reset()
    }
    onSourceHeightChanged: {
        if (targetHeight <= 0 && sourceHeight > 0) reset()
    }

    DimensionRatioGrid {
        id: dimGrid
        Layout.fillWidth: true
        theme: panel.theme
        namePrefix: "canvasSizePanel"
        sourceWidth: panel.sourceWidth
        sourceHeight: panel.sourceHeight
        lockRatio: false
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
                onClicked: {
                    panel.customOffset = false
                    panel.anchor = modelData.key
                }
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
