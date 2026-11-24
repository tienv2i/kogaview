import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Sidebar options panel for single-image Resize using the shared Crop-style
/// Width / Height / Ratio grid (`DimensionRatioGrid`) and live 60 fps preview.
ColumnLayout {
    id: panel
    objectName: "resizeOptions"
    spacing: 10

    property Theme theme: Theme {}
    property int sourceWidth: 0
    property int sourceHeight: 0
    property alias targetWidth: dimGrid.targetWidth
    property alias targetHeight: dimGrid.targetHeight
    property alias constraint: dimGrid.lockRatio
    property string fitMode: "stretch"
    property string filter: "auto"

    readonly property bool valid: targetWidth >= 1 && targetWidth <= 16384
                                  && targetHeight >= 1 && targetHeight <= 16384
    readonly property bool changed: valid
                                    && (targetWidth !== sourceWidth || targetHeight !== sourceHeight)

    readonly property var fitModes: [
        { key: "stretch", label: qsTr("Stretch to size") },
        { key: "cover", label: qsTr("Crop to fill") },
        { key: "pad", label: qsTr("Fit with background") }
    ]
    readonly property var filters: [
        { key: "auto", label: qsTr("Automatic") },
        { key: "lanczos3", label: qsTr("Lanczos 3") },
        { key: "catmull_rom", label: qsTr("Catmull-Rom") },
        { key: "nearest", label: qsTr("Nearest") }
    ]

    function reset() {
        fitMode = "stretch"
        filter = "auto"
        dimGrid.reset(Math.max(1, sourceWidth), Math.max(1, sourceHeight), true)
    }

    function applyScale(factor) {
        if (sourceWidth <= 0 || sourceHeight <= 0) return
        dimGrid.setDimensions(Math.round(sourceWidth * factor),
                              Math.round(sourceHeight * factor))
    }

    function setDimensions(w, h) {
        dimGrid.setDimensions(Math.max(1, Math.min(16384, Math.round(w))),
                              Math.max(1, Math.min(16384, Math.round(h))))
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
        namePrefix: "resizePanel"
        sourceWidth: panel.sourceWidth
        sourceHeight: panel.sourceHeight
        lockRatio: true
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: [
                { label: "50%", factor: 0.5 },
                { label: "75%", factor: 0.75 },
                { label: "150%", factor: 1.5 },
                { label: "200%", factor: 2.0 }
            ]
            delegate: Button {
                required property var modelData
                Layout.fillWidth: true
                text: modelData.label
                focusPolicy: Qt.NoFocus
                padding: 4
                onClicked: panel.applyScale(modelData.factor)
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
            text: qsTr("Fit")
            color: panel.theme.textMuted
            Layout.preferredWidth: 50
        }
        ComboBox {
            objectName: "resizePanelFit"
            Layout.fillWidth: true
            model: panel.fitModes
            textRole: "label"
            focusPolicy: Qt.NoFocus
            currentIndex: {
                for (var i = 0; i < panel.fitModes.length; ++i) {
                    if (panel.fitModes[i].key === panel.fitMode) return i
                }
                return 0
            }
            onActivated: function(idx) {
                if (idx >= 0 && idx < panel.fitModes.length) {
                    panel.fitMode = panel.fitModes[idx].key
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
            text: qsTr("Filter")
            color: panel.theme.textMuted
            Layout.preferredWidth: 50
        }
        ComboBox {
            objectName: "resizePanelFilter"
            Layout.fillWidth: true
            model: panel.filters
            textRole: "label"
            focusPolicy: Qt.NoFocus
            currentIndex: {
                for (var i = 0; i < panel.filters.length; ++i) {
                    if (panel.filters[i].key === panel.filter) return i
                }
                return 0
            }
            onActivated: function(idx) {
                if (idx >= 0 && idx < panel.filters.length) {
                    panel.filter = panel.filters[idx].key
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
            text: qsTr("Output size")
            color: panel.theme.textMuted
            Layout.fillWidth: true
        }
        Label {
            objectName: "resizePanelOutputSize"
            text: panel.targetWidth + " × " + panel.targetHeight + " px"
            color: panel.theme.text
            font.bold: true
        }
    }
}
