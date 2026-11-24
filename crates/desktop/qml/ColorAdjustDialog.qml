import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Floating non-blocking Krita-style Color & Light popup.
/// Supports live WYSIWYG preview respecting active layer vs whole image
/// and any active raster selection mask.
Popup {
    id: dialog
    objectName: "editorColorAdjustPopup"

    property Theme theme: Theme {}
    property bool hasMultipleLayers: false
    property bool hasSelection: false
    property string activeLayerName: ""
    property string applyTarget: "active_layer"
    property bool previewEnabled: true

    signal previewRequested(real brightness, real contrast, real saturation, string target)
    signal previewCleared()
    signal applyRequested(real brightness, real contrast, real saturation, string target)

    modal: false
    dim: false
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: 310
    padding: 0

    property bool _committed: false

    function openAtCanvas(hostWidth, hostHeight) {
        _committed = false
        panel.reset()
        previewEnabled = true
        x = Math.max(16, hostWidth - width - 24)
        y = Math.max(16, Math.min(80, (hostHeight - implicitHeight) / 2))
        open()
    }

    function schedulePreview() {
        if (!dialog.opened) return
        if (!dialog.previewEnabled || !panel.changed) {
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
            if (dialog.opened && dialog.previewEnabled && panel.changed) {
                dialog.previewRequested(
                    panel.brightness,
                    panel.contrast,
                    panel.saturation,
                    dialog.hasMultipleLayers ? dialog.applyTarget : "active_layer"
                )
            }
        }
    }

    onClosed: {
        previewTimer.stop()
        if (!_committed) {
            dialog.previewCleared()
        }
    }

    background: Rectangle {
        color: dialog.theme.surface
        border.width: 1
        border.color: dialog.theme.border
        radius: 8
    }

    contentItem: ColumnLayout {
        spacing: 0

        // Draggable title bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            color: dialog.theme.surfaceAlt
            radius: 8

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 8
                color: dialog.theme.surfaceAlt
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: dialog.theme.border
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeAllCursor
                property real startX: 0
                property real startY: 0
                onPressed: function(mouse) {
                    startX = mouse.x
                    startY = mouse.y
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    dialog.x = Math.round(dialog.x + (mouse.x - startX))
                    dialog.y = Math.round(dialog.y + (mouse.y - startY))
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 6
                spacing: 6

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Color & light")
                    color: dialog.theme.text
                    font.bold: true
                    font.pixelSize: 13
                }

                ToolButton {
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    padding: 0
                    focusPolicy: Qt.NoFocus
                    text: "✕"
                    onClicked: dialog.close()
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 10

            // Target & Selection context indicator
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: dialog.hasMultipleLayers || dialog.hasSelection

                ComboBox {
                    objectName: "colorAdjustTargetCombo"
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
                    Layout.preferredHeight: 22
                    Layout.preferredWidth: selBadge.implicitWidth + 12
                    radius: 4
                    color: dialog.theme.selection
                    border.width: 1
                    border.color: dialog.theme.accent
                    Label {
                        id: selBadge
                        anchors.centerIn: parent
                        text: qsTr("Selection")
                        color: dialog.theme.text
                        font.pixelSize: 10
                        font.bold: true
                    }
                }
            }

            ColorAdjustPanel {
                id: panel
                Layout.fillWidth: true
                theme: dialog.theme
                viewOnly: false
                showReset: false
                onBrightnessChanged: dialog.schedulePreview()
                onContrastChanged: dialog.schedulePreview()
                onSaturationChanged: dialog.schedulePreview()
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                CheckBox {
                    text: qsTr("Preview")
                    focusPolicy: Qt.NoFocus
                    checked: dialog.previewEnabled
                    onToggled: {
                        dialog.previewEnabled = checked
                        dialog.schedulePreview()
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: qsTr("Reset")
                    focusPolicy: Qt.NoFocus
                    enabled: panel.changed
                    onClicked: {
                        panel.reset()
                        dialog.schedulePreview()
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: dialog.theme.border
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                Button {
                    text: qsTr("Cancel")
                    focusPolicy: Qt.NoFocus
                    onClicked: dialog.close()
                }

                Button {
                    objectName: "colorAdjustPopupApply"
                    text: qsTr("Apply")
                    highlighted: true
                    focusPolicy: Qt.NoFocus
                    enabled: panel.changed
                    onClicked: {
                        dialog._committed = true
                        previewTimer.stop()
                        dialog.applyRequested(
                            panel.brightness,
                            panel.contrast,
                            panel.saturation,
                            dialog.hasMultipleLayers ? dialog.applyTarget : "active_layer"
                        )
                        dialog.close()
                    }
                }
            }
        }
    }
}
