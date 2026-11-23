import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Change the document canvas dimensions without scaling the source image.
///
/// Growing adds a border painted with the Editor's shared background colour (or
/// transparency); shrinking crops the document around the chosen 3×3 anchor.
DialogFrame {
    id: dialog
    namePrefix: "canvasSize"
    title: qsTr("Canvas size")
    preferredWidth: 480

    property real documentWidth: 0
    property real documentHeight: 0
    property bool documentReady: false
    property color backgroundColor: "#ffffff"
    property bool backgroundTransparent: false
    property bool documentIsJpeg: false
    property string anchor: "center"

    signal backgroundTransparentRequested()
    signal backgroundColorRequested(string value)
    signal applyRequested(int width, int height, string anchor)

    readonly property var anchorsList: [
        { key: "top_left", glyph: "\u2196", label: qsTr("Top left") },
        { key: "top", glyph: "\u2191", label: qsTr("Top") },
        { key: "top_right", glyph: "\u2197", label: qsTr("Top right") },
        { key: "left", glyph: "\u2190", label: qsTr("Left") },
        { key: "center", glyph: "\u25cf", label: qsTr("Center") },
        { key: "right", glyph: "\u2192", label: qsTr("Right") },
        { key: "bottom_left", glyph: "\u2199", label: qsTr("Bottom left") },
        { key: "bottom", glyph: "\u2193", label: qsTr("Bottom") },
        { key: "bottom_right", glyph: "\u2198", label: qsTr("Bottom right") }
    ]

    onCloseRequested: dialog.close()

    function fillFromDocument() {
        widthField.unit = "px"
        heightField.unit = "px"
        var width = Math.max(1, Math.round(dialog.documentWidth))
        var height = Math.max(1, Math.round(dialog.documentHeight))
        widthField.setPixels(width)
        heightField.setPixels(height)
        dialog.anchor = "center"
    }

    function fieldsValid() {
        return !!dialog.documentReady
                && widthField.acceptableInput && heightField.acceptableInput
                && widthField.pixels() > 0 && heightField.pixels() > 0
                && widthField.pixels() <= 16384 && heightField.pixels() <= 16384
    }

    function changed() {
        if (!dialog.fieldsValid()) return false
        return widthField.pixels() !== Math.round(dialog.documentWidth)
                || heightField.pixels() !== Math.round(dialog.documentHeight)
    }

    function submit() {
        if (!dialog.changed()) return
        dialog.applyRequested(widthField.pixels(), heightField.pixels(), dialog.anchor)
        dialog.close()
    }

    function prepare() {
        dialog.fillFromDocument()
        Qt.callLater(function() {
            widthField.inputField.forceActiveFocus()
            widthField.inputField.selectAll()
        })
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 12

        FormSection {
            title: qsTr("Dimensions")
            theme: dialog.theme

            FormRow {
                label: qsTr("Width")
                theme: dialog.theme

                UnitField {
                    id: widthField
                    objectName: "canvasWidthField"
                    Layout.fillWidth: true
                    unitReference: Math.max(1, Math.round(dialog.documentWidth))
                    maximumPixels: 16384
                    onAccepted: dialog.submit()
                }
            }

            FormRow {
                label: qsTr("Height")
                theme: dialog.theme

                UnitField {
                    id: heightField
                    objectName: "canvasHeightField"
                    Layout.fillWidth: true
                    unitReference: Math.max(1, Math.round(dialog.documentHeight))
                    maximumPixels: 16384
                    onAccepted: dialog.submit()
                }
            }
        }

        FormSection {
            title: qsTr("Anchor")
            theme: dialog.theme

            FormRow {
                label: qsTr("Position")
                theme: dialog.theme

                GridLayout {
                    objectName: "canvasAnchorGrid"
                    columns: 3
                    columnSpacing: 4
                    rowSpacing: 4

                    Repeater {
                        model: dialog.anchorsList

                        delegate: Button {
                            required property var modelData
                            objectName: "canvasAnchor_" + modelData.key
                            text: modelData.glyph
                            implicitWidth: 32
                            implicitHeight: 28
                            padding: 0
                            checkable: true
                            checked: dialog.anchor === modelData.key
                            focusPolicy: Qt.NoFocus
                            ToolTip.visible: hovered
                            ToolTip.text: modelData.label
                            onClicked: dialog.anchor = modelData.key

                            contentItem: Label {
                                text: parent.text
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: parent.checked ? "#ffffff" : dialog.theme.text
                                font.pixelSize: 13
                            }
                            background: Rectangle {
                                radius: dialog.theme.radius
                                color: parent.checked ? dialog.theme.accent
                                     : parent.hovered ? dialog.theme.hover
                                     : dialog.theme.surfaceAlt
                                border.width: 1
                                border.color: parent.checked ? dialog.theme.accent : dialog.theme.border
                            }
                        }
                    }
                }
            }
        }

        FormSection {
            title: qsTr("Extension colour")
            theme: dialog.theme

            FormRow {
                label: qsTr("Background")
                theme: dialog.theme

                RowLayout {
                    spacing: 8

                    AbstractButton {
                        id: bgButton
                        objectName: "canvasBgButton"
                        implicitWidth: 36
                        implicitHeight: 26
                        focusPolicy: Qt.NoFocus
                        onClicked: bgPopup.openNear(bgButton)

                        background: Rectangle {
                            radius: dialog.theme.radius
                            color: dialog.backgroundTransparent ? "transparent" : dialog.backgroundColor
                            border.width: 1
                            border.color: dialog.theme.border
                            clip: true

                            Checkerboard {
                                anchors.fill: parent
                                visible: dialog.backgroundTransparent
                            }
                        }
                    }

                    Label {
                        text: dialog.backgroundTransparent
                              ? qsTr("Transparent")
                              : ("" + dialog.backgroundColor).toUpperCase()
                        color: dialog.theme.textMuted
                        font.pixelSize: 12
                    }
                }
            }
        }
    }

    BackgroundPopup {
        id: bgPopup
        objectName: "canvasBgPopup"
        theme: dialog.theme
        colour: dialog.backgroundColor
        transparent: dialog.backgroundTransparent
        alphaLostWarning: dialog.documentIsJpeg
        onTransparentPicked: dialog.backgroundTransparentRequested()
        onColourPicked: function(value) { dialog.backgroundColorRequested(value) }
    }

    footer: DialogFooter {
        namePrefix: "canvasSize"
        theme: dialog.theme
        height: dialog.footerHeight

        PanelAction {
            objectName: "canvasSizeReset"
            theme: dialog.theme
            text: qsTr("Reset")
            enabled: dialog.changed() || dialog.anchor !== "center"
            onClicked: dialog.fillFromDocument()
        }
        Item { Layout.fillWidth: true }
        PanelAction {
            objectName: "canvasSizeCancel"
            theme: dialog.theme
            text: qsTr("Cancel")
            implicitWidth: 88
            onClicked: dialog.close()
        }
        PanelAction {
            objectName: "canvasSizeApply"
            theme: dialog.theme
            text: qsTr("Apply")
            implicitWidth: 88
            primary: true
            enabled: dialog.changed()
            onClicked: dialog.submit()
        }
    }
}
