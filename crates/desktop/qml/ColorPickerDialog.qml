import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// App-themed colour chooser built on `DialogFrame` (shared dialog library).
///
/// Offers a 2D saturation-value spectrum with a vertical hue bar, a screen
/// eyedropper (via XDG Desktop Portal `Screenshot.PickColor`), RGB sliders,
/// a hex input field (`#RRGGBB`), quick preset swatches and a before/after
/// preview chip while wearing KogaView's active Light/Dark theme.
DialogFrame {
    id: dialog
    namePrefix: "colorPicker"
    title: qsTr("Choose color")
    preferredWidth: 420
    fitToContent: true

    property color selectedColor: "#ffffff"
    property color initialColor: "#ffffff"
    property int redValue: 255
    property int greenValue: 255
    property int blueValue: 255
    property real hueValue: 0.0
    property real satValue: 0.0
    property real valValue: 1.0
    property bool _syncing: false

    readonly property bool screenPickerAvailable:
        typeof Platform !== "undefined" && Platform !== null && Platform.portalAvailable

    signal colorAccepted(string hex)

    readonly property var swatches: [
        "#000000", "#404040", "#808080", "#c0c0c0", "#ffffff", "#e53935",
        "#fb8c00", "#fdd835", "#43a047", "#00acc1", "#1e88e5", "#8e24aa"
    ]

    onCloseRequested: dialog.close()

    Connections {
        target: typeof Platform !== "undefined" ? Platform : null
        ignoreUnknownSignals: true
        function onColorPicked(hex) {
            if (!dialog.visible) return
            if (/^#[0-9a-fA-F]{6}$/.test(hex)) {
                dialog._loadFromColor(hex)
                dialog.selectedColor = hex
            }
        }
    }

    function _hex2(v) {
        var n = Math.max(0, Math.min(255, Math.round(v)))
        var s = n.toString(16)
        return s.length < 2 ? "0" + s : s
    }

    function currentHex() {
        return "#" + _hex2(redValue) + _hex2(greenValue) + _hex2(blueValue)
    }

    function _rgbToHsv(r255, g255, b255) {
        var r = r255 / 255.0
        var g = g255 / 255.0
        var b = b255 / 255.0
        var max = Math.max(r, g, b)
        var min = Math.min(r, g, b)
        var d = max - min
        var h = dialog.hueValue
        var s = max === 0 ? 0 : d / max
        var v = max
        if (d > 1e-6) {
            if (max === r) {
                h = ((g - b) / d + (g < b ? 6 : 0)) / 6.0
            } else if (max === g) {
                h = ((b - r) / d + 2) / 6.0
            } else {
                h = ((r - g) / d + 4) / 6.0
            }
        }
        return { h: Math.max(0, Math.min(1, h)), s: s, v: v }
    }

    function _loadFromColor(c) {
        _syncing = true
        var q = Qt.color(c)
        redValue = Math.round(q.r * 255)
        greenValue = Math.round(q.g * 255)
        blueValue = Math.round(q.b * 255)
        var hsv = _rgbToHsv(redValue, greenValue, blueValue)
        hueValue = hsv.h
        satValue = hsv.s
        valValue = hsv.v
        hexField.text = currentHex().toUpperCase()
        _syncing = false
    }

    function _syncFromHsv() {
        if (_syncing) return
        _syncing = true
        var c = Qt.hsva(hueValue, satValue, valValue, 1.0)
        redValue = Math.round(c.r * 255)
        greenValue = Math.round(c.g * 255)
        blueValue = Math.round(c.b * 255)
        selectedColor = Qt.rgba(redValue / 255.0, greenValue / 255.0, blueValue / 255.0, 1.0)
        hexField.text = currentHex().toUpperCase()
        _syncing = false
    }

    function _syncHexFromRgb() {
        if (_syncing) return
        _syncing = true
        var hsv = _rgbToHsv(redValue, greenValue, blueValue)
        hueValue = hsv.h
        satValue = hsv.s
        valValue = hsv.v
        selectedColor = Qt.rgba(redValue / 255.0, greenValue / 255.0, blueValue / 255.0, 1.0)
        hexField.text = currentHex().toUpperCase()
        _syncing = false
    }

    function prepare() {
        initialColor = selectedColor
        _loadFromColor(selectedColor)
    }

    function acceptColor() {
        var hex = currentHex()
        selectedColor = hex
        colorAccepted(hex)
        dialog.accept()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 12

        // 2D Saturation-Value spectrum + vertical Hue bar.
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                id: svField
                objectName: "colorPickerSvField"
                Layout.fillWidth: true
                implicitHeight: 168
                radius: dialog.theme.radius
                color: Qt.hsva(dialog.hueValue, 1.0, 1.0, 1.0)
                border.width: 1
                border.color: dialog.theme.border
                clip: true

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, parent.radius - 1)
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#ffffffff" }
                        GradientStop { position: 1.0; color: "#00ffffff" }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, parent.radius - 1)
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: "#00000000" }
                        GradientStop { position: 1.0; color: "#ff000000" }
                    }
                }

                // Crosshair marker
                Rectangle {
                    x: Math.round(dialog.satValue * (svField.width - 2)) + 1 - width / 2
                    y: Math.round((1.0 - dialog.valValue) * (svField.height - 2)) + 1 - height / 2
                    width: 14
                    height: 14
                    radius: 7
                    color: "transparent"
                    border.width: 2
                    border.color: "#000000"

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 1.5
                        radius: width / 2
                        color: "transparent"
                        border.width: 1.5
                        border.color: "#ffffff"
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    preventStealing: true
                    cursorShape: Qt.CrossCursor
                    function pick(mx, my) {
                        dialog.satValue = Math.max(0.0, Math.min(1.0, mx / Math.max(1, svField.width)))
                        dialog.valValue = Math.max(0.0, Math.min(1.0, 1.0 - my / Math.max(1, svField.height)))
                        dialog._syncFromHsv()
                    }
                    onPressed: function(mouse) { pick(mouse.x, mouse.y) }
                    onPositionChanged: function(mouse) {
                        if (pressed) pick(mouse.x, mouse.y)
                    }
                }
            }

            // Vertical Hue spectrum column
            Rectangle {
                id: hueBar
                objectName: "colorPickerHueBar"
                implicitWidth: 24
                implicitHeight: 168
                radius: dialog.theme.radius
                border.width: 1
                border.color: dialog.theme.border
                clip: true

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, parent.radius - 1)
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.000; color: "#ff0000" }
                        GradientStop { position: 0.167; color: "#ffff00" }
                        GradientStop { position: 0.333; color: "#00ff00" }
                        GradientStop { position: 0.500; color: "#00ffff" }
                        GradientStop { position: 0.667; color: "#0000ff" }
                        GradientStop { position: 0.833; color: "#ff00ff" }
                        GradientStop { position: 1.000; color: "#ff0000" }
                    }
                }

                Rectangle {
                    x: 0
                    y: Math.max(0, Math.min(hueBar.height - height,
                        Math.round(dialog.hueValue * (hueBar.height - 2)) + 1 - height / 2))
                    width: hueBar.width
                    height: 6
                    radius: 2
                    color: "transparent"
                    border.width: 2
                    border.color: "#000000"

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 1.5
                        radius: 1
                        color: "transparent"
                        border.width: 1
                        border.color: "#ffffff"
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    preventStealing: true
                    cursorShape: Qt.PointingHandCursor
                    function pick(my) {
                        dialog.hueValue = Math.max(0.0, Math.min(1.0, my / Math.max(1, hueBar.height)))
                        dialog._syncFromHsv()
                    }
                    onPressed: function(mouse) { pick(mouse.y) }
                    onPositionChanged: function(mouse) {
                        if (pressed) pick(mouse.y)
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            // Before / After preview chip.
            Row {
                spacing: 0
                Rectangle {
                    width: 40
                    height: 32
                    color: dialog.initialColor
                    border.width: 1
                    border.color: dialog.theme.border
                }
                Rectangle {
                    objectName: "colorPickerPreview"
                    width: 40
                    height: 32
                    color: dialog.currentHex()
                    border.width: 1
                    border.color: dialog.theme.border
                }
            }

            Label {
                text: qsTr("Hex")
                color: dialog.theme.textMuted
            }

            TextField {
                id: hexField
                objectName: "colorPickerHex"
                Layout.fillWidth: true
                text: "#FFFFFF"
                maximumLength: 7
                onTextEdited: {
                    var t = text.trim()
                    if (/^#[0-9a-fA-F]{6}$/.test(t)) {
                        dialog._loadFromColor(t)
                        dialog.selectedColor = t
                    }
                }
                onAccepted: dialog.acceptColor()
            }

            ToolbarButton {
                objectName: "colorPickerEyedropper"
                theme: dialog.theme
                implicitWidth: 32
                implicitHeight: 32
                icon.source: "icons/eyedropper.svg"
                icon.color: dialog.theme.text
                enabled: dialog.screenPickerAvailable
                ToolTip.text: qsTr("Pick color from screen")
                onClicked: {
                    if (dialog.screenPickerAvailable) {
                        Platform.requestPickColor()
                    }
                }
            }
        }

        FormSection {
            title: qsTr("RGB")
            theme: dialog.theme

            FormRow {
                label: qsTr("Red")
                theme: dialog.theme
                labelWidth: 56
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Slider {
                        Layout.fillWidth: true
                        from: 0; to: 255; stepSize: 1
                        value: dialog.redValue
                        focusPolicy: Qt.NoFocus
                        onMoved: { dialog.redValue = Math.round(value); dialog._syncHexFromRgb() }
                    }
                    RowLayout {
                        spacing: 2
                        ToolButton {
                            implicitWidth: 22; implicitHeight: 26; padding: 0; text: "−"
                            focusPolicy: Qt.NoFocus; autoRepeat: true
                            enabled: dialog.redValue > 0
                            onClicked: { dialog.redValue = Math.max(0, dialog.redValue - 1); dialog._syncHexFromRgb() }
                        }
                        TextField {
                            id: redField
                            objectName: "colorPickerRedInput"
                            implicitWidth: 42; implicitHeight: 26; padding: 2
                            horizontalAlignment: Text.AlignHCenter
                            validator: IntValidator { bottom: 0; top: 255 }
                            Binding {
                                target: redField; property: "text"
                                value: String(dialog.redValue)
                                when: !redField.activeFocus; restoreMode: Binding.RestoreNone
                            }
                            onTextEdited: {
                                var n = parseInt(text.trim())
                                if (!isNaN(n)) { dialog.redValue = Math.max(0, Math.min(255, n)); dialog._syncHexFromRgb() }
                            }
                            onEditingFinished: text = String(dialog.redValue)
                        }
                        ToolButton {
                            implicitWidth: 22; implicitHeight: 26; padding: 0; text: "+"
                            focusPolicy: Qt.NoFocus; autoRepeat: true
                            enabled: dialog.redValue < 255
                            onClicked: { dialog.redValue = Math.min(255, dialog.redValue + 1); dialog._syncHexFromRgb() }
                        }
                    }
                }
            }

            FormRow {
                label: qsTr("Green")
                theme: dialog.theme
                labelWidth: 56
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Slider {
                        Layout.fillWidth: true
                        from: 0; to: 255; stepSize: 1
                        value: dialog.greenValue
                        focusPolicy: Qt.NoFocus
                        onMoved: { dialog.greenValue = Math.round(value); dialog._syncHexFromRgb() }
                    }
                    RowLayout {
                        spacing: 2
                        ToolButton {
                            implicitWidth: 22; implicitHeight: 26; padding: 0; text: "−"
                            focusPolicy: Qt.NoFocus; autoRepeat: true
                            enabled: dialog.greenValue > 0
                            onClicked: { dialog.greenValue = Math.max(0, dialog.greenValue - 1); dialog._syncHexFromRgb() }
                        }
                        TextField {
                            id: greenField
                            objectName: "colorPickerGreenInput"
                            implicitWidth: 42; implicitHeight: 26; padding: 2
                            horizontalAlignment: Text.AlignHCenter
                            validator: IntValidator { bottom: 0; top: 255 }
                            Binding {
                                target: greenField; property: "text"
                                value: String(dialog.greenValue)
                                when: !greenField.activeFocus; restoreMode: Binding.RestoreNone
                            }
                            onTextEdited: {
                                var n = parseInt(text.trim())
                                if (!isNaN(n)) { dialog.greenValue = Math.max(0, Math.min(255, n)); dialog._syncHexFromRgb() }
                            }
                            onEditingFinished: text = String(dialog.greenValue)
                        }
                        ToolButton {
                            implicitWidth: 22; implicitHeight: 26; padding: 0; text: "+"
                            focusPolicy: Qt.NoFocus; autoRepeat: true
                            enabled: dialog.greenValue < 255
                            onClicked: { dialog.greenValue = Math.min(255, dialog.greenValue + 1); dialog._syncHexFromRgb() }
                        }
                    }
                }
            }

            FormRow {
                label: qsTr("Blue")
                theme: dialog.theme
                labelWidth: 56
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Slider {
                        Layout.fillWidth: true
                        from: 0; to: 255; stepSize: 1
                        value: dialog.blueValue
                        focusPolicy: Qt.NoFocus
                        onMoved: { dialog.blueValue = Math.round(value); dialog._syncHexFromRgb() }
                    }
                    RowLayout {
                        spacing: 2
                        ToolButton {
                            implicitWidth: 22; implicitHeight: 26; padding: 0; text: "−"
                            focusPolicy: Qt.NoFocus; autoRepeat: true
                            enabled: dialog.blueValue > 0
                            onClicked: { dialog.blueValue = Math.max(0, dialog.blueValue - 1); dialog._syncHexFromRgb() }
                        }
                        TextField {
                            id: blueField
                            objectName: "colorPickerBlueInput"
                            implicitWidth: 42; implicitHeight: 26; padding: 2
                            horizontalAlignment: Text.AlignHCenter
                            validator: IntValidator { bottom: 0; top: 255 }
                            Binding {
                                target: blueField; property: "text"
                                value: String(dialog.blueValue)
                                when: !blueField.activeFocus; restoreMode: Binding.RestoreNone
                            }
                            onTextEdited: {
                                var n = parseInt(text.trim())
                                if (!isNaN(n)) { dialog.blueValue = Math.max(0, Math.min(255, n)); dialog._syncHexFromRgb() }
                            }
                            onEditingFinished: text = String(dialog.blueValue)
                        }
                        ToolButton {
                            implicitWidth: 22; implicitHeight: 26; padding: 0; text: "+"
                            focusPolicy: Qt.NoFocus; autoRepeat: true
                            enabled: dialog.blueValue < 255
                            onClicked: { dialog.blueValue = Math.min(255, dialog.blueValue + 1); dialog._syncHexFromRgb() }
                        }
                    }
                }
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 6
            columnSpacing: 6
            rowSpacing: 6

            Repeater {
                model: dialog.swatches
                delegate: Rectangle {
                    required property string modelData
                    Layout.fillWidth: true
                    implicitHeight: 24
                    radius: dialog.theme.radius
                    color: modelData
                    border.width: dialog.currentHex().toLowerCase() === modelData ? 2 : 1
                    border.color: dialog.currentHex().toLowerCase() === modelData
                                  ? dialog.theme.accent : dialog.theme.border
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            dialog._loadFromColor(modelData)
                            dialog.selectedColor = modelData
                        }
                    }
                }
            }
        }
    }

    footer: DialogFooter {
        namePrefix: "colorPicker"
        theme: dialog.theme
        height: dialog.footerHeight

        Item { Layout.fillWidth: true }
        PanelAction {
            objectName: "colorPickerCancel"
            theme: dialog.theme
            text: qsTr("Cancel")
            implicitWidth: 88
            onClicked: dialog.close()
        }
        PanelAction {
            objectName: "colorPickerApply"
            theme: dialog.theme
            text: qsTr("Apply")
            implicitWidth: 88
            primary: true
            onClicked: dialog.acceptColor()
        }
    }
}
