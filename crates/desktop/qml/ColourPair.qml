import QtQuick
import QtQuick.Controls

/// The Editor's one foreground/background pair, drawn as Photoshop draws it:
/// the foreground box raised over the background one, with the swap arrow
/// (Krita's `X`) and the tiny black-over-white reset square (`D`) inside the
/// same 34 × 34.
///
/// The pair is Editor-wide, not the brush's. The two roles answer two different
/// questions:
///
/// - **Foreground** — the colour of a mark placed *inside* the picture. The
///   brush is the only tool that places one today; a bucket, text, a line or a
///   shape would use the same colour.
/// - **Background** — the material of *new canvas*: resize padding, the border a
///   grown crop adds, and later the corners an arbitrary-angle rotate would
///   leave. `backgroundTransparent` is a valid background and is drawn as the
///   checkerboard, because a `Rectangle` cannot draw "no colour".
///
/// The component only draws and emits. The colours live on the Editor view, so
/// every reader — the boxes, the hex field, the palette, the commands — shows
/// the same two values and no box can display a colour the next command would
/// not use.
Item {
    id: pair

    property Theme theme: Theme {}
    /// `#rrggbb` as a colour; the view keeps the string, so a box and the field
    /// beside it cannot disagree about the text.
    property color foreground: "#000000"
    property color background: "#ffffff"
    /// New canvas that is painted with nothing at all.
    property bool backgroundTransparent: false

    signal foregroundClicked()
    signal backgroundClicked()
    signal swapRequested()
    signal resetRequested()

    /// The two boxes, for a caller that has to open a chooser beside one: a
    /// popup needs an item to be placed against, and only the pair knows where
    /// its boxes ended up.
    readonly property alias foregroundBox: foregroundBox
    readonly property alias backgroundBox: backgroundBox

    implicitWidth: 34
    implicitHeight: 34
    // A disabled pair is dimmed rather than hidden: with no document open the
    // two colours still say what they are, and a gap in the rail would read as
    // a missing tool.
    opacity: enabled ? 1.0 : 0.45

    // The boxes' object names are the pair's own name plus a role
    // (`colourPairForegroundSwatch`): the same component is drawn in the rail
    // and in the paint options when the rail is hidden, and a test or a dev hook
    // that reads "the foreground box" must not be able to land on the copy that
    // happens not to be on screen.
    //
    // The background box is behind the foreground one, offset down and to the
    // right, which is what makes the pair read as two colours rather than as a
    // single swatch with a border.
    Rectangle {
        id: backgroundBox
        objectName: pair.objectName + "BackgroundSwatch"
        x: 12
        y: 12
        width: 22
        height: 22
        radius: 3
        color: pair.backgroundTransparent ? "transparent" : pair.background
        border.width: backgroundArea.containsMouse ? 2 : 1
        border.color: backgroundArea.containsMouse
                      ? pair.theme.accent : pair.theme.border
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Background color (new canvas)")

        Checkerboard {
            objectName: pair.objectName + "BackgroundSwatchCheckerboard"
            anchors.fill: parent
            visible: pair.backgroundTransparent
            square: 5
        }

        MouseArea {
            id: backgroundArea
            objectName: pair.objectName + "BackgroundArea"
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: qsTr("Background color (new canvas)")
            onClicked: pair.backgroundClicked()
        }
    }

    Rectangle {
        id: foregroundBox
        objectName: pair.objectName + "ForegroundSwatch"
        width: 22
        height: 22
        radius: 3
        color: pair.foreground
        border.width: foregroundArea.containsMouse ? 2 : 1
        border.color: foregroundArea.containsMouse
                      ? pair.theme.accent : pair.theme.border
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Foreground color")

        MouseArea {
            id: foregroundArea
            objectName: pair.objectName + "ForegroundArea"
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: qsTr("Foreground color")
            onClicked: pair.foregroundClicked()
        }
    }

    // Krita's X, drawn as Photoshop's arrow: two arrowheads, so a swap reads as
    // an exchange rather than as a direction.
    Item {
        objectName: pair.objectName + "Swap"
        x: 24
        y: 0
        width: 10
        height: 10

        Canvas {
            id: swapCanvas
            anchors.fill: parent
            Connections {
                target: swapArea
                function onContainsMouseChanged() { swapCanvas.requestPaint() }
            }
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.strokeStyle = swapArea.containsMouse
                        ? pair.theme.accent : pair.theme.textMuted
                ctx.lineWidth = 1.1
                ctx.lineCap = "round"
                // Top arrow pointing right, bottom arrow pointing left.
                ctx.beginPath()
                ctx.moveTo(1, 3); ctx.lineTo(9, 3)
                ctx.moveTo(7, 1); ctx.lineTo(9, 3); ctx.lineTo(7, 5)
                ctx.moveTo(9, 7); ctx.lineTo(1, 7)
                ctx.moveTo(3, 5); ctx.lineTo(1, 7); ctx.lineTo(3, 9)
                ctx.stroke()
            }
        }

        MouseArea {
            id: swapArea
            objectName: pair.objectName + "SwapArea"
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Swap the foreground and background colours (X)")
            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: qsTr("Swap the foreground and background colours (X)")
            onClicked: pair.swapRequested()
        }
    }

    // Krita's D: the colours as they start, black over white.
    Item {
        objectName: pair.objectName + "Reset"
        x: 0
        y: 24
        width: 10
        height: 10

        Rectangle {
            x: 0; y: 0; width: 7; height: 7
            color: "#ffffff"
            border.width: 1
            border.color: resetArea.containsMouse
                          ? pair.theme.accent : pair.theme.border
        }
        Rectangle {
            x: 3; y: 3; width: 7; height: 7
            color: "#000000"
            border.width: 1
            border.color: resetArea.containsMouse
                          ? pair.theme.accent : pair.theme.border
        }
        MouseArea {
            id: resetArea
            objectName: pair.objectName + "ResetArea"
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Reset the colours to black and white (D)")
            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: qsTr("Reset the colours to black and white (D)")
            onClicked: pair.resetRequested()
        }
    }
}
