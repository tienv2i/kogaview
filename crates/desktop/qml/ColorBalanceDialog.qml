import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Krita-style Color Balance dialog built on the shared `DialogFrame` + `DialogFooter`.
/// Supports Shadows / Midtones / Highlights tonal ranges with Cyan-Red,
/// Magenta-Green, Yellow-Blue sliders, Preserve luminosity, and live in-RAM preview
/// respecting active layer vs whole image and any active selection mask.
DialogFrame {
    id: dialog
    objectName: "editorColorBalanceDialog"
    namePrefix: "colorBalance"
    title: qsTr("Color balance")
    modal: false
    dim: false
    preferredWidth: 410
    minWidth: 350
    fitToContent: true

    property bool hasMultipleLayers: false
    property bool hasSelection: false
    property string applyTarget: "active_layer"
    property bool previewEnabled: true
    property bool preserveLuminosity: true

    /// Active tonal range: `"shadows"` | `"midtones"` | `"highlights"`
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

    property bool _committed: false

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

    function resetAll() {
        shadows = [0, 0, 0]
        midtones = [0, 0, 0]
        highlights = [0, 0, 0]
        preserveLuminosity = true
        schedulePreview()
    }

    function prepare() {
        _committed = false
        activeRange = "midtones"
        shadows = [0, 0, 0]
        midtones = [0, 0, 0]
        highlights = [0, 0, 0]
        preserveLuminosity = true
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
                    dialog.shadows,
                    dialog.midtones,
                    dialog.highlights,
                    dialog.preserveLuminosity,
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
            objectName: "colorBalanceTargetCombo"
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
            Layout.preferredWidth: cbSelBadge.implicitWidth + 14
            radius: 4
            color: dialog.theme.selection
            border.width: 1
            border.color: dialog.theme.accent
            Label {
                id: cbSelBadge
                anchors.centerIn: parent
                text: qsTr("Selection")
                color: dialog.theme.text
                font.pixelSize: 11
                font.bold: true
            }
        }
    }

    // Tonal range tabs: Shadows | Midtones | Highlights
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
                objectName: "cbRange_" + modelData.key
                Layout.fillWidth: true
                theme: dialog.theme
                text: modelData.label
                primary: dialog.activeRange === modelData.key
                onClicked: dialog.activeRange = modelData.key
            }
        }
    }

    // Cyan <-> Red
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Cyan"); color: "#06b6d4"; font.pixelSize: 12 }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: (dialog.currentTriple[0] > 0 ? "+" : "") + Math.round(dialog.currentTriple[0] * 100)
                color: dialog.theme.text
                font.bold: true
            }
            Label { text: qsTr("Red"); color: "#ef4444"; font.pixelSize: 12 }
        }
        Slider {
            objectName: "cbCyanRedSlider"
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(dialog.currentTriple[0] * 100)
            onMoved: dialog.setAxis(0, Math.round(value) / 100.0)
        }
    }

    // Magenta <-> Green
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Magenta"); color: "#d946ef"; font.pixelSize: 12 }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: (dialog.currentTriple[1] > 0 ? "+" : "") + Math.round(dialog.currentTriple[1] * 100)
                color: dialog.theme.text
                font.bold: true
            }
            Label { text: qsTr("Green"); color: "#22c55e"; font.pixelSize: 12 }
        }
        Slider {
            objectName: "cbMagentaGreenSlider"
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(dialog.currentTriple[1] * 100)
            onMoved: dialog.setAxis(1, Math.round(value) / 100.0)
        }
    }

    // Yellow <-> Blue
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Yellow"); color: "#eab308"; font.pixelSize: 12 }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: (dialog.currentTriple[2] > 0 ? "+" : "") + Math.round(dialog.currentTriple[2] * 100)
                color: dialog.theme.text
                font.bold: true
            }
            Label { text: qsTr("Blue"); color: "#3b82f6"; font.pixelSize: 12 }
        }
        Slider {
            objectName: "cbYellowBlueSlider"
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: -100; to: 100; stepSize: 1
            value: Math.round(dialog.currentTriple[2] * 100)
            onMoved: dialog.setAxis(2, Math.round(value) / 100.0)
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        CheckBox {
            text: qsTr("Preserve luminosity")
            focusPolicy: Qt.NoFocus
            checked: dialog.preserveLuminosity
            onToggled: {
                dialog.preserveLuminosity = checked
                dialog.schedulePreview()
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
    }

    footer: DialogFooter {
        theme: dialog.theme
        namePrefix: dialog.namePrefix

        PanelAction {
            theme: dialog.theme
            text: qsTr("Reset range")
            onClicked: dialog.resetRange()
        }

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
            objectName: "colorBalanceDialogApply"
            theme: dialog.theme
            text: qsTr("Apply")
            primary: true
            enabled: dialog.hasChanges
            onClicked: {
                dialog._committed = true
                previewTimer.stop()
                dialog.applyRequested(
                    dialog.shadows,
                    dialog.midtones,
                    dialog.highlights,
                    dialog.preserveLuminosity,
                    dialog.hasMultipleLayers ? dialog.applyTarget : "active_layer"
                )
                dialog.close()
            }
        }
    }
}
