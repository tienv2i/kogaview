import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Krita-style HSV Adjustment dialog built on the shared `DialogFrame` + `DialogFooter`.
/// Non-blocking (`modal: false`, `dim: false`) with live in-RAM preview respecting
/// active layer vs whole image and any active raster selection mask.
DialogFrame {
    id: dialog
    objectName: "editorHsvDialog"
    namePrefix: "hsvAdjust"
    title: qsTr("HSV Adjustment")
    modal: false
    dim: false
    preferredWidth: 390
    minWidth: 340
    fitToContent: true

    property bool hasMultipleLayers: false
    property bool hasSelection: false
    property string applyTarget: "active_layer"
    property bool previewEnabled: true

    property real hue: 0
    property real saturation: 0
    property real value: 0

    readonly property bool hasChanges:
        Math.abs(hue) > 0.01 || Math.abs(saturation) > 0.001 || Math.abs(value) > 0.001

    signal previewRequested(real hue, real saturation, real value, string target)
    signal previewCleared()
    signal applyRequested(real hue, real saturation, real value, string target)

    property bool _committed: false

    function resetValues() {
        hue = 0
        saturation = 0
        value = 0
        schedulePreview()
    }

    function prepare() {
        _committed = false
        hue = 0
        saturation = 0
        value = 0
        previewEnabled = true
        if (parent) {
            x = Math.max(16, parent.width - width - 24)
            y = Math.max(16, Math.min(72, Math.round((parent.height - height) / 2)))
            moved = true
        }
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
                    dialog.hue,
                    dialog.saturation,
                    dialog.value,
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

    // Target & Selection context bar
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: dialog.hasMultipleLayers || dialog.hasSelection

        ComboBox {
            objectName: "hsvTargetCombo"
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
            Layout.preferredWidth: hsvSelBadge.implicitWidth + 14
            radius: 4
            color: dialog.theme.selection
            border.width: 1
            border.color: dialog.theme.accent
            Label {
                id: hsvSelBadge
                anchors.centerIn: parent
                text: qsTr("Selection")
                color: dialog.theme.text
                font.pixelSize: 11
                font.bold: true
            }
        }
    }

    // Hue (-180°..+180°)
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Hue"); color: dialog.theme.textMuted; Layout.fillWidth: true }
            Label {
                text: (dialog.hue > 0 ? "+" : "") + Math.round(dialog.hue) + "°"
                color: dialog.theme.text
                font.bold: true
            }
        }
        Slider {
            objectName: "hsvHueSlider"
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -180; to: 180; stepSize: 1
            value: dialog.hue
            onMoved: {
                dialog.hue = Math.round(value)
                dialog.schedulePreview()
            }
        }
    }

    // Saturation (-100..+100%)
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Saturation"); color: dialog.theme.textMuted; Layout.fillWidth: true }
            Label {
                text: (dialog.saturation > 0 ? "+" : "") + Math.round(dialog.saturation * 100) + "%"
                color: dialog.theme.text
                font.bold: true
            }
        }
        Slider {
            objectName: "hsvSatSlider"
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(dialog.saturation * 100)
            onMoved: {
                dialog.saturation = Math.round(value) / 100.0
                dialog.schedulePreview()
            }
        }
    }

    // Value (-100..+100%)
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Value"); color: dialog.theme.textMuted; Layout.fillWidth: true }
            Label {
                text: (dialog.value > 0 ? "+" : "") + Math.round(dialog.value * 100) + "%"
                color: dialog.theme.text
                font.bold: true
            }
        }
        Slider {
            objectName: "hsvValSlider"
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(dialog.value * 100)
            onMoved: {
                dialog.value = Math.round(value) / 100.0
                dialog.schedulePreview()
            }
        }
    }

    CheckBox {
        text: qsTr("Preview")
        focusPolicy: Qt.NoFocus
        checked: dialog.previewEnabled
        onToggled: {
            dialog.previewEnabled = checked
            dialog.schedulePreview()
        }
    }

    footer: DialogFooter {
        theme: dialog.theme
        namePrefix: dialog.namePrefix

        PanelAction {
            theme: dialog.theme
            text: qsTr("Reset")
            enabled: dialog.hasChanges
            onClicked: dialog.resetValues()
        }

        Item { Layout.fillWidth: true }

        PanelAction {
            theme: dialog.theme
            text: qsTr("Cancel")
            onClicked: dialog.close()
        }

        PanelAction {
            objectName: "hsvDialogApply"
            theme: dialog.theme
            text: qsTr("Apply")
            primary: true
            enabled: dialog.hasChanges
            onClicked: {
                dialog._committed = true
                previewTimer.stop()
                dialog.applyRequested(
                    dialog.hue,
                    dialog.saturation,
                    dialog.value,
                    dialog.hasMultipleLayers ? dialog.applyTarget : "active_layer"
                )
                dialog.close()
            }
        }
    }
}
