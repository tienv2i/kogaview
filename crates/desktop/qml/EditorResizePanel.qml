import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Sidebar options panel for single-image Resize with unit selector (`px` / `%`)
/// and live 60 fps canvas preview.
ColumnLayout {
    id: panel
    objectName: "resizeOptions"
    spacing: 10

    property Theme theme: Theme {}
    property int sourceWidth: 0
    property int sourceHeight: 0
    property int targetWidth: 0
    property int targetHeight: 0
    property bool constraint: true
    property string fitMode: "stretch"
    property string filter: "auto"
    property bool _syncing: false

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

    function _syncFields() {
        widthField.setPixels(targetWidth)
        heightField.setPixels(targetHeight)
    }

    function reset() {
        _syncing = true
        targetWidth = Math.max(1, sourceWidth)
        targetHeight = Math.max(1, sourceHeight)
        constraint = true
        fitMode = "stretch"
        filter = "auto"
        _syncFields()
        _syncing = false
    }

    function setWidthFromField() {
        if (_syncing) return
        var w = widthField.pixels()
        if (w <= 0) return
        _syncing = true
        var clamped = Math.max(1, Math.min(16384, w))
        targetWidth = clamped
        if (constraint && sourceWidth > 0 && sourceHeight > 0) {
            targetHeight = Math.max(1, Math.min(16384, Math.round(clamped * sourceHeight / sourceWidth)))
            heightField.setPixels(targetHeight)
        }
        _syncing = false
    }

    function setHeightFromField() {
        if (_syncing) return
        var h = heightField.pixels()
        if (h <= 0) return
        _syncing = true
        var clamped = Math.max(1, Math.min(16384, h))
        targetHeight = clamped
        if (constraint && sourceWidth > 0 && sourceHeight > 0) {
            targetWidth = Math.max(1, Math.min(16384, Math.round(clamped * sourceWidth / sourceHeight)))
            widthField.setPixels(targetWidth)
        }
        _syncing = false
    }

    function applyScale(factor) {
        if (sourceWidth <= 0 || sourceHeight <= 0) return
        _syncing = true
        targetWidth = Math.max(1, Math.min(16384, Math.round(sourceWidth * factor)))
        targetHeight = Math.max(1, Math.min(16384, Math.round(sourceHeight * factor)))
        _syncFields()
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
            objectName: "resizePanelWidth"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            unitReference: panel.sourceWidth > 0 ? panel.sourceWidth : 1
            minimumPixels: 1
            maximumPixels: 16384
            nextField: heightField
            onTextEdited: panel.setWidthFromField()
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
            objectName: "resizePanelHeight"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            unitReference: panel.sourceHeight > 0 ? panel.sourceHeight : 1
            minimumPixels: 1
            maximumPixels: 16384
            previousField: widthField
            onTextEdited: panel.setHeightFromField()
        }
    }

    CheckBox {
        objectName: "resizePanelLockRatio"
        text: qsTr("Lock aspect ratio")
        checked: panel.constraint
        focusPolicy: Qt.NoFocus
        onToggled: panel.constraint = checked
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
