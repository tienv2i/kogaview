import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Krita-style Color Balance panel hosted inside Editor Right Sidebar Tool Options
/// (and seamlessly resizable when Tool Options is popped out into a DialogFrame).
ColumnLayout {
    id: panel
    objectName: "editorColorBalancePanel"
    spacing: 8

    property Theme theme: Theme {}
    property bool hasMultipleLayers: false
    property bool hasSelection: false
    property string applyTarget: "active_layer"
    property bool previewEnabled: true
    property bool preserveLuminosity: true

    property string activeRange: "midtones"
    property var shadows: [0, 0, 0]
    property var midtones: [0, 0, 0]
    property var highlights: [0, 0, 0]

    readonly property var currentTriple:
        activeRange === "shadows" ? shadows
        : (activeRange === "highlights" ? highlights : midtones)

    readonly property bool hasChanges: {
        var all = shadows.concat(midtones, highlights)
        for (var i = 0; i < all.length; ++i) {
            if (Math.abs(all[i]) > 0.001) return true
        }
        return false
    }

    signal previewRequested(var shadows, var midtones, var highlights, bool preserveLuminosity, string target)
    signal previewCleared()
    signal applyRequested(var shadows, var midtones, var highlights, bool preserveLuminosity, string target)
    signal cancelRequested()

    function setAxis(axisIndex, normalizedValue) {
        var cur = currentTriple.slice()
        cur[axisIndex] = Math.max(-1.0, Math.min(1.0, normalizedValue))
        if (activeRange === "shadows") shadows = cur
        else if (activeRange === "highlights") highlights = cur
        else midtones = cur
        schedulePreview()
    }

    function resetRange() {
        if (activeRange === "shadows") shadows = [0, 0, 0]
        else if (activeRange === "highlights") highlights = [0, 0, 0]
        else midtones = [0, 0, 0]
        schedulePreview()
    }

    function reset() {
        activeRange = "midtones"
        shadows = [0, 0, 0]
        midtones = [0, 0, 0]
        highlights = [0, 0, 0]
        preserveLuminosity = true
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
                    panel.shadows,
                    panel.midtones,
                    panel.highlights,
                    panel.preserveLuminosity,
                    panel.hasMultipleLayers ? panel.applyTarget : "active_layer"
                )
            }
        }
    }

    onVisibleChanged: {
        if (!visible) previewTimer.stop()
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        visible: panel.hasMultipleLayers || panel.hasSelection

        ComboBox {
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
            Layout.preferredWidth: cbSelLbl.implicitWidth + 12
            radius: 4
            color: panel.theme.selection
            border.width: 1
            border.color: panel.theme.accent
            Label {
                id: cbSelLbl
                anchors.centerIn: parent
                text: qsTr("Selection")
                color: panel.theme.text
                font.pixelSize: 10
                font.bold: true
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: [
                { key: "shadows", label: qsTr("Shadows") },
                { key: "midtones", label: qsTr("Midtones") },
                { key: "highlights", label: qsTr("Highlights") }
            ]
            delegate: PanelAction {
                required property var modelData
                Layout.fillWidth: true
                theme: panel.theme
                text: modelData.label
                primary: panel.activeRange === modelData.key
                onClicked: panel.activeRange = modelData.key
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Cyan"); color: "#06b6d4"; font.pixelSize: 11 }
            Label { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: (panel.currentTriple[0] > 0 ? "+" : "") + Math.round(panel.currentTriple[0] * 100); color: panel.theme.text; font.bold: true; font.pixelSize: 11 }
            Label { text: qsTr("Red"); color: "#ef4444"; font.pixelSize: 11 }
        }
        Slider {
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(panel.currentTriple[0] * 100)
            onMoved: panel.setAxis(0, Math.round(value) / 100.0)
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Magenta"); color: "#d946ef"; font.pixelSize: 11 }
            Label { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: (panel.currentTriple[1] > 0 ? "+" : "") + Math.round(panel.currentTriple[1] * 100); color: panel.theme.text; font.bold: true; font.pixelSize: 11 }
            Label { text: qsTr("Green"); color: "#22c55e"; font.pixelSize: 11 }
        }
        Slider {
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(panel.currentTriple[1] * 100)
            onMoved: panel.setAxis(1, Math.round(value) / 100.0)
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Yellow"); color: "#eab308"; font.pixelSize: 11 }
            Label { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: (panel.currentTriple[2] > 0 ? "+" : "") + Math.round(panel.currentTriple[2] * 100); color: panel.theme.text; font.bold: true; font.pixelSize: 11 }
            Label { text: qsTr("Blue"); color: "#3b82f6"; font.pixelSize: 11 }
        }
        Slider {
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(panel.currentTriple[2] * 100)
            onMoved: panel.setAxis(2, Math.round(value) / 100.0)
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        CheckBox {
            text: qsTr("Preserve luminosity")
            focusPolicy: Qt.NoFocus
            checked: panel.preserveLuminosity
            onToggled: { panel.preserveLuminosity = checked; panel.schedulePreview() }
        }
        CheckBox {
            text: qsTr("Preview")
            focusPolicy: Qt.NoFocus
            checked: panel.previewEnabled
            onToggled: { panel.previewEnabled = checked; panel.schedulePreview() }
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
                    panel.shadows,
                    panel.midtones,
                    panel.highlights,
                    panel.preserveLuminosity,
                    panel.hasMultipleLayers ? panel.applyTarget : "active_layer"
                )
                panel.shadows = [0, 0, 0]
                panel.midtones = [0, 0, 0]
                panel.highlights = [0, 0, 0]
            }
        }
        PanelAction {
            Layout.fillWidth: true
            theme: panel.theme
            text: qsTr("Reset range")
            onClicked: panel.resetRange()
        }
    }
}
