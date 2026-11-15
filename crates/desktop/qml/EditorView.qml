import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: view

    property Theme theme: Theme {}
    property var state: ({})

    signal command(var command)

    // Sidebar widths, dragged through the two PanelSplitter handles below.
    property real leftPanelWidth: 240
    property real rightPanelWidth: 240

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            objectName: "leftPanel"
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            border.width: 1
            border.color: view.theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                Label {
                    text: "Tools"
                    color: view.theme.textMuted
                    font.bold: true
                    font.pixelSize: 12
                }

                Repeater {
                    model: ["Crop", "Rotate", "Exposure", "Color", "Filters"]
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        radius: view.theme.radius
                        color: toolHover.hovered ? view.theme.hover : "transparent"
                        opacity: 0.55

                        Label {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData
                            color: view.theme.text
                        }

                        HoverHandler { id: toolHover }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        PanelSplitter {
            objectName: "leftSplitter"
            Layout.fillHeight: true
            theme: view.theme
            value: view.leftPanelWidth
            defaultValue: 240
            direction: 1
            minimum: 180
            maximum: 460
            onMoved: function(width) { view.leftPanelWidth = width }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: view.theme.background

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 10

                    Icon {
                        Layout.alignment: Qt.AlignHCenter
                        iconName: "document-edit-symbolic"
                        iconSize: 56
                        iconColor: view.theme.textMuted
                    }
                    Label {
                        text: "Editor workspace"
                        color: view.theme.text
                        font.pixelSize: 22
                        font.bold: true
                    }
                    Label {
                        text: "Non-destructive editing arrives in a later milestone."
                        color: view.theme.textMuted
                    }
                    Label {
                        visible: !!(view.state.selectionInfo)
                        text: view.state.selectionInfo
                              ? ("Selected: " + view.state.selectionInfo.name)
                              : ""
                        color: view.theme.textMuted
                    }
                }
            }
        }

        PanelSplitter {
            objectName: "rightSplitter"
            Layout.fillHeight: true
            theme: view.theme
            value: view.rightPanelWidth
            defaultValue: 240
            direction: -1
            minimum: 180
            maximum: 460
            onMoved: function(width) { view.rightPanelWidth = width }
        }

        Rectangle {
            objectName: "rightPanel"
            Layout.preferredWidth: view.rightPanelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            border.width: 1
            border.color: view.theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                Label {
                    text: "Adjustments"
                    color: view.theme.textMuted
                    font.bold: true
                    font.pixelSize: 12
                }

                Repeater {
                    model: ["Brightness", "Contrast", "Saturation", "Sharpness", "Vignette"]
                    delegate: ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Label {
                            text: modelData
                            color: view.theme.textMuted
                            font.pixelSize: 12
                        }
                        Slider {
                            Layout.fillWidth: true
                            from: 0
                            to: 100
                            value: 50
                            enabled: false
                            // Disabled controls must not look adjustable.
                            opacity: 0.4
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }

    property Component toolbar: Component {
        RowLayout {
            spacing: 2

            ToolbarButton {
                theme: view.theme
                icon.name: "document-open-symbolic"
                display: AbstractButton.IconOnly
                enabled: false
                ToolTip.visible: hovered
                ToolTip.text: "Open an image for editing (coming later)"
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "edit-undo-symbolic"
                display: AbstractButton.IconOnly
                enabled: false
                ToolTip.visible: hovered
                ToolTip.text: "Undo (coming later)"
            }
            ToolbarButton {
                theme: view.theme
                icon.name: "edit-redo-symbolic"
                display: AbstractButton.IconOnly
                enabled: false
                ToolTip.visible: hovered
                ToolTip.text: "Redo (coming later)"
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                theme: view.theme
                icon.name: "document-save-as-symbolic"
                display: AbstractButton.IconOnly
                enabled: false
                ToolTip.visible: hovered
                ToolTip.text: "Export a copy (coming later)"
            }
            Label {
                text: "Not implemented yet"
                color: view.theme.textMuted
                padding: 6
            }
        }
    }
}
