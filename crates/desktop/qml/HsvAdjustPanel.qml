import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Krita-style HSV Adjustment panel hosted inside Editor Right Sidebar Tool Options
/// (and seamlessly resizable when Tool Options is popped out into a floating DialogFrame).
ColumnLayout {
    id: panel
    objectName: "editorHsvPanel"
    spacing: 10

    property Theme theme: Theme {}
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
    signal cancelRequested()

    function reset() {
        hue = 0
        saturation = 0
        value = 0
        previewEnabled = true
        previewTimer.stop()
        panel.previewCleared()
    }

    function schedulePreview() {
        if (!panel.visible) return
        if (!panel.previewEnabled || !panel.hasChanges) {
            previewTimer.stop()
            panel.previewCleared()
            return
        }
        if (!previewTimer.running) previewTimer.start()
    }

    Timer {
        id: previewTimer
        interval: 33
        onTriggered: {
            if (panel.visible && panel.previewEnabled && panel.hasChanges) {
                panel.previewRequested(
                    panel.hue,
                    panel.saturation,
                    panel.value,
                    panel.hasMultipleLayers ? panel.applyTarget : "active_layer"
                )
            }
        }
    }

    onVisibleChanged: {
        if (!visible) {
            previewTimer.stop()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        visible: panel.hasMultipleLayers || panel.hasSelection

        ComboBox {
            objectName: "hsvTargetCombo"
            visible: panel.hasMultipleLayers
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            model: [qsTr("Active layer"), qsTr("Whole image")]
            currentIndex: panel.applyTarget === "whole_image" ? 1 : 0
            onActivated: function(idx) {
                panel.applyTarget = idx === 1 ? "whole_image" : "active_layer"
                panel.schedulePreview()
            }
        }

        Rectangle {
            visible: panel.hasSelection
            Layout.preferredHeight: 22
            Layout.preferredWidth: hsvSelLbl.implicitWidth + 12
            radius: 4
            color: panel.theme.selection
            border.width: 1
            border.color: panel.theme.accent
            Label {
                id: hsvSelLbl
                anchors.centerIn: parent
                text: qsTr("Selection")
                color: panel.theme.text
                font.pixelSize: 10
                font.bold: true
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Hue"); color: panel.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: (panel.hue > 0 ? "+" : "") + Math.round(panel.hue) + "°"; color: panel.theme.text; font.bold: true; font.pixelSize: 12 }
        }
        Slider {
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -180; to: 180; stepSize: 1
            value: panel.hue
            onMoved: { panel.hue = Math.round(value); panel.schedulePreview() }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Saturation"); color: panel.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: (panel.saturation > 0 ? "+" : "") + Math.round(panel.saturation * 100) + "%"; color: panel.theme.text; font.bold: true; font.pixelSize: 12 }
        }
        Slider {
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(panel.saturation * 100)
            onMoved: { panel.saturation = Math.round(value) / 100.0; panel.schedulePreview() }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Value"); color: panel.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: (panel.value > 0 ? "+" : "") + Math.round(panel.value * 100) + "%"; color: panel.theme.text; font.bold: true; font.pixelSize: 12 }
        }
        Slider {
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(panel.value * 100)
            onMoved: { panel.value = Math.round(value) / 100.0; panel.schedulePreview() }
        }
    }

    CheckBox {
        text: qsTr("Preview")
        focusPolicy: Qt.NoFocus
        checked: panel.previewEnabled
        onToggled: {
            panel.previewEnabled = checked
            panel.schedulePreview()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        PanelAction {
            Layout.fillWidth: true
            theme: panel.theme
            text: qsTr("Apply")
            primary: true
            enabled: panel.hasChanges
            onClicked: {
                previewTimer.stop()
                panel.applyRequested(
                    panel.hue,
                    panel.saturation,
                    panel.value,
                    panel.hasMultipleLayers ? panel.applyTarget : "active_layer"
                )
                panel.hue = 0
                panel.saturation = 0
                panel.value = 0
            }
        }
        PanelAction {
            Layout.fillWidth: true
            theme: panel.theme
            text: qsTr("Reset")
            enabled: panel.hasChanges
            onClicked: panel.reset()
        }
    }
}
