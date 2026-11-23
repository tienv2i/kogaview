import QtQuick

/// The look of "no colour".
///
/// A `Rectangle` cannot draw alpha, so a swatch that means *transparent* draws
/// the checkerboard every image editor uses for a clear pixel instead of a
/// colour: two greys in `square`-pixel tiles, starting light at the top left.
///
/// The tiles are one `Canvas` rather than a grid of rectangles: a 22 px chip is
/// 25 squares, and a popup that is rebuilt on every open does not need that
/// many items for one swatch.
Item {
    id: checkerboard

    property color light: "#9aa1ac"
    property color dark: "#5b6370"
    /// Tile size in pixels; 2 is the floor, so a tiny chip still reads as a
    /// checkerboard rather than as one grey.
    property int square: 5

    clip: true

    Canvas {
        id: tiles
        objectName: "checkerboardTiles"
        anchors.fill: parent

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var step = Math.max(2, Math.round(checkerboard.square))
            ctx.fillStyle = checkerboard.light
            ctx.fillRect(0, 0, width, height)
            ctx.fillStyle = checkerboard.dark
            for (var y = 0; y < height; y += step) {
                for (var x = 0; x < width; x += step) {
                    if ((Math.floor(x / step) + Math.floor(y / step)) % 2 === 1)
                        ctx.fillRect(x, y, step, step)
                }
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()
    }

    Connections {
        target: checkerboard
        function onSquareChanged() { tiles.requestPaint() }
        function onLightChanged() { tiles.requestPaint() }
        function onDarkChanged() { tiles.requestPaint() }
    }
}
