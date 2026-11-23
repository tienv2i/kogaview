import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Shared Light & Color adjustment panel used by both Viewer (view-only, never
/// saved) and Editor (non-destructive Core edit with live 60 fps GPU preview).
ColumnLayout {
    id: panel
    objectName: "colorAdjustPanel"
    spacing: 12

    property Theme theme: Theme {}
    /// Normalized values in `-1.0..1.0` (`0.0` = unchanged).
    property real brightness: 0.0
    property real contrast: 0.0
    property real saturation: 0.0
    /// True in Viewer: shows a subtle note reminding that adjustments are
    /// view-only and never written to the file.
    property bool viewOnly: false
    /// Show an inline Reset button (used in Viewer; Editor puts Reset in its
    /// pinned tool action bar).
    property bool showReset: false

    readonly property bool changed:
        Math.abs(brightness) > 0.001 || Math.abs(contrast) > 0.001 || Math.abs(saturation) > 0.001

    function reset() {
        brightness = 0.0
        contrast = 0.0
        saturation = 0.0
    }

    function clampNorm(intVal) {
        return Math.max(-100, Math.min(100, Math.round(intVal))) / 100.0
    }

    component AdjustStepper: RowLayout {
        id: stepper
        property int intValue: 0
        property string fieldObjectName: ""
        signal valueEdited(int next)
        spacing: 2

        ToolButton {
            implicitWidth: 24
            implicitHeight: 26
            padding: 0
            text: "−"
            font.pixelSize: 13
            focusPolicy: Qt.NoFocus
            autoRepeat: true
            enabled: stepper.intValue > -100
            onClicked: stepper.valueEdited(Math.max(-100, stepper.intValue - 1))
        }
        TextField {
            id: numInput
            objectName: stepper.fieldObjectName
            implicitWidth: 46
            implicitHeight: 26
            padding: 2
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 12
            validator: IntValidator { bottom: -100; top: 100 }
            Binding {
                target: numInput
                property: "text"
                value: String(stepper.intValue)
                when: !numInput.activeFocus
                restoreMode: Binding.RestoreNone
            }
            onTextEdited: {
                var parsed = parseInt(text.trim())
                if (!isNaN(parsed)) {
                    stepper.valueEdited(Math.max(-100, Math.min(100, parsed)))
                }
            }
            onEditingFinished: {
                var parsed = parseInt(text.trim())
                if (!isNaN(parsed)) {
                    stepper.valueEdited(Math.max(-100, Math.min(100, parsed)))
                }
                text = String(stepper.intValue)
            }
            Keys.onEscapePressed: focus = false
        }
        ToolButton {
            implicitWidth: 24
            implicitHeight: 26
            padding: 0
            text: "+"
            font.pixelSize: 13
            focusPolicy: Qt.NoFocus
            autoRepeat: true
            enabled: stepper.intValue < 100
            onClicked: stepper.valueEdited(Math.min(100, stepper.intValue + 1))
        }
    }

    Rectangle {
        visible: panel.viewOnly
        Layout.fillWidth: true
        implicitHeight: noticeLabel.implicitHeight + 12
        radius: panel.theme.radius
        color: panel.theme.surface
        border.width: 1
        border.color: panel.theme.border

        Label {
            id: noticeLabel
            anchors.fill: parent
            anchors.margins: 6
            text: qsTr("View only — changes are not saved")
            color: panel.theme.textMuted
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }
    }

    // Light section
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
            text: qsTr("Lighting")
            color: panel.theme.textMuted
            font.pixelSize: 11
            font.bold: true
        }

        // Brightness
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: qsTr("Brightness")
                    color: panel.theme.text
                    Layout.fillWidth: true
                }
                AdjustStepper {
                    fieldObjectName: "adjustBrightnessInput"
                    intValue: Math.round(panel.brightness * 100)
                    onValueEdited: function(v) { panel.brightness = panel.clampNorm(v) }
                }
            }
            Slider {
                objectName: "adjustBrightnessSlider"
                Layout.fillWidth: true
                from: -1.0
                to: 1.0
                stepSize: 0.01
                value: panel.brightness
                focusPolicy: Qt.NoFocus
                onMoved: panel.brightness = Math.round(value * 100) / 100
            }
        }

        // Contrast
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: qsTr("Contrast")
                    color: panel.theme.text
                    Layout.fillWidth: true
                }
                AdjustStepper {
                    fieldObjectName: "adjustContrastInput"
                    intValue: Math.round(panel.contrast * 100)
                    onValueEdited: function(v) { panel.contrast = panel.clampNorm(v) }
                }
            }
            Slider {
                objectName: "adjustContrastSlider"
                Layout.fillWidth: true
                from: -1.0
                to: 1.0
                stepSize: 0.01
                value: panel.contrast
                focusPolicy: Qt.NoFocus
                onMoved: panel.contrast = Math.round(value * 100) / 100
            }
        }
    }

    // Color section
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
            text: qsTr("Color")
            color: panel.theme.textMuted
            font.pixelSize: 11
            font.bold: true
        }

        // Saturation
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: qsTr("Saturation")
                    color: panel.theme.text
                    Layout.fillWidth: true
                }
                AdjustStepper {
                    fieldObjectName: "adjustSaturationInput"
                    intValue: Math.round(panel.saturation * 100)
                    onValueEdited: function(v) { panel.saturation = panel.clampNorm(v) }
                }
            }
            Slider {
                objectName: "adjustSaturationSlider"
                Layout.fillWidth: true
                from: -1.0
                to: 1.0
                stepSize: 0.01
                value: panel.saturation
                focusPolicy: Qt.NoFocus
                onMoved: panel.saturation = Math.round(value * 100) / 100
            }
        }
    }

    Button {
        objectName: "adjustResetButton"
        visible: panel.showReset
        Layout.fillWidth: true
        text: qsTr("Reset adjustments")
        focusPolicy: Qt.NoFocus
        enabled: panel.changed
        onClicked: panel.reset()
    }
}
