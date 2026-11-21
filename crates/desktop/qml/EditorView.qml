import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// The Editor workspace.
//
// Core owns the working document and its history; this view renders
// `state.editor` and turns clicks into editor_* commands. It keeps no domain
// state of its own: which image is open, whether undo can do anything and
// whether the document is saved all come from the snapshot, so a command that
// Core rejects leaves the view showing the truth rather than an optimistic
// guess.
//
// The layout is a tool palette and an inspector, not a second copy of the
// toolbar: the left column holds the tools (Pointer, Resize, Crop) and the
// quick edits, the right column shows the document's details, thumbnail and
// history under the pointer or the selected tool's options, and the toolbar
// keeps what is global — open, zoom, save, undo/redo/reset, back and close.
// Core still owns the history and the undo/redo state; the view only draws the
// labels, and only where a tool is not armed.
Item {
    id: view

    // The Editor owns the keyboard while it is the visible workspace: the
    // Krita-style paint keys live here and the text fields consume their own
    // keys before they bubble this far.
    focus: true

    // The paint keys and Space-pan need the view to be the focus item when the
    // Editor opens; a text field or a click takes focus away on purpose.
    Component.onCompleted: view.forceActiveFocus()

    property Theme theme: Theme {}
    /// The shared thumbnail cache (C++ `ThumbnailCache`). Null in the QML test
    /// harness, where the pointer frame stays empty instead of decoding a fake
    /// path.
    property var thumbnails: null
    /// The published Core state; `editor` is null until a document is open.
    property var state: ({})
    /// True while the window is below the full icon row (`Main.qml`): the
    /// toolbar keeps open/save/undo/redo/back/close and folds the rest into
    /// `editorOverflowMenu`.
    property bool miniToolbar: false

    /// Turns Core's `{ code, args }` history lines into sentences.
    UiLines {
        id: uiLines
    }

    /// The lock beside Width, Height and Ratio. A padlock drawn on a Canvas
    /// rather than a glyph or a themed icon: the emoji padlock was blank in this
    /// session's font, and an icon theme is not loaded under the offscreen
    /// platform. `checked` is the locked state, so the button is checkable and
    /// the view keeps the three `cropLock*` properties as the truth.
    component CropLockButton: Button {
        id: lockButton
        property color lockedColor: "#3f7fd6"
        property color unlockedColor: "#8b929c"
        implicitWidth: 26
        implicitHeight: 26
        padding: 0
        checkable: true
        focusPolicy: Qt.NoFocus

        contentItem: Item {
            implicitWidth: 16
            implicitHeight: 18

            Canvas {
                id: lockGlyph
                anchors.centerIn: parent
                width: 16
                height: 18
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var colour = lockButton.checked
                            ? lockButton.lockedColor : lockButton.unlockedColor
                    ctx.strokeStyle = colour
                    ctx.fillStyle = colour
                    ctx.lineWidth = 1.6
                    // Shackle: a half circle over the body.
                    ctx.beginPath()
                    ctx.arc(8, 7, 4, Math.PI, 0, false)
                    ctx.stroke()
                    // Body.
                    ctx.beginPath()
                    ctx.rect(2, 8, 12, 8)
                    ctx.fill()
                    // Keyhole, in the surface behind the button.
                    ctx.fillStyle = "#ffffff"
                    ctx.beginPath()
                    ctx.arc(8, 11, 1.1, 0, Math.PI * 2)
                    ctx.fill()
                    ctx.fillRect(7.45, 11, 1.1, 2.4)
                }
            }
        }

        background: Rectangle {
            radius: 3
            color: lockButton.checked ? lockButton.lockedColor : "transparent"
            border.width: 1
            border.color: lockButton.checked ? lockButton.lockedColor
                                             : lockButton.palette.mid
        }

        onCheckedChanged: lockGlyph.requestPaint()
    }
    property int leftPanelWidth: 220
    property int rightPanelWidth: 260
    /// Which tool is armed on the canvas: `pointer` (no tool), `crop` or
    /// `transform`. The pointer is the default and the no-op tool, so opening
    /// the Editor never leaves an Apply button armed. Resize is not a canvas
    /// tool: it is a dialog (`ResizeDialog.qml`), because choosing a size is a
    /// question with a beginning and an end rather than a mode to stay in.
    property string tool: "pointer"
    /// Crop's shape, as typed: a ratio such as `3:2`, or `free` when the two
    /// sides are independent. A text field rather than a table, so any shape
    /// the user needs is reachable; the presets below still write a concrete
    /// pixel size and its ratio.
    property string cropRatio: "free"
    /// Where the crop rectangle sits when its size changes: the anchor names the
    /// document corner, edge or centre the rectangle keeps. Typing X/Y by hand
    /// leaves it alone — the anchor is a placement shortcut, not a lock.
    property string cropAnchor: "center"
    /// The three locks. A locked field keeps its value: Width and Height pin
    /// that axis, and Ratio pins the shape. Two locks decide what the third
    /// field does: W+H makes the ratio a consequence (so the ratio field is
    /// disabled), W+ratio makes Height the derived side (disabled), and H+ratio
    /// makes Width the derived side. Without locks the ratio links the sides;
    /// without a ratio the sides are independent.
    property bool cropLockWidth: false
    property bool cropLockHeight: false
    property bool cropLockRatio: false
    /// A field is editable unless it is locked, or unless it is the side the
    /// other locked side and the locked ratio derive. W+H locks the shape
    /// outright, so the ratio stops being an input at all.
    readonly property bool cropWidthEditable:
        !view.cropLockWidth && !(view.cropLockHeight && view.cropLockRatio)
    readonly property bool cropHeightEditable:
        !view.cropLockHeight && !(view.cropLockWidth && view.cropLockRatio)
    readonly property bool cropRatioEditable:
        !view.cropLockRatio && !(view.cropLockWidth && view.cropLockHeight)
    /// A frame can only be reshaped while at least one of its three values is
    /// free. Two locks fix the shape; moving the frame is still allowed.
    readonly property bool cropResizable:
        !(view.cropLockWidth && view.cropLockHeight)
        && !(view.cropLockRatio && (view.cropLockWidth || view.cropLockHeight))
    /// The size the last Apply is expected to produce. Core publishes the cut
    /// document before the command returns on the real gateway, and the QML
    /// suite delivers it a turn later; either way the size is what tells the
    /// view that the cut landed, so the fresh frame can cover all of it.
    property var pendingCropResult: null
    /// What a crop may do to the canvas. `center` keeps the rectangle entirely
    /// inside the picture, which is the ordinary cut. `grow` lets it reach past
    /// the edges — `x`/`y` become negative — and paints the new border with
    /// `cropFill`, so a picture can gain a margin without being resized first.
    property string cropMode: "center"
    /// How a grown border is painted: `transparent`, `black`, `white`, `gray`
    /// or `custom` (`cropFillColor`). Only read in `grow` mode.
    property string cropFill: "transparent"
    property color cropFillColor: "#808080"
    /// And for Transform: the canvas shows the straightened frame before Apply.
    property bool transformLivePreview: false
    /// The transform quad in document pixels, clockwise from the top left:
    /// every corner must stay inside the picture, and the four of them are the
    /// whole command. The frame's own corners are the identity, so opening a
    /// document or putting the tool down leaves nothing armed. The four edge
    /// handles are an affordance over this one array: dragging an edge moves
    /// the two corners that form it.
    property var transformCorners: []

    /// Paint is one canvas tool with two modes, the way Krita's freehand brush
    /// and eraser are two tools over one paint engine: `brush` blends
    /// `paintColor` over the picture, `eraser` lowers alpha. One stroke is one
    /// `editor_paint_stroke` command, sent on release, so one undo removes it.
    property string paintMode: "brush"
    /// Krita's foreground and background colours — X swaps them and D resets
    /// them. Stored as `#rrggbb`, which is both the typed command's bytes and
    /// the field's own text, so the swatch and the field cannot disagree.
    property string paintColor: "#000000"
    property string paintBackgroundColor: "#ffffff"
    /// Brush diameter in document pixels; the command carries the radius.
    property real paintSize: 24
    /// The stroke's alpha, 1–100, before it is blended.
    property int paintOpacity: 100
    /// The stroke being drawn, in document pixels. Presentation only: the
    /// canvas draws it while the button is down and the command is sent on
    /// release, so a half-drawn stroke can still be abandoned.
    property var paintStroke: []
    property bool paintStroking: false
    /// Held Space pans on the left button, as in Krita; while it is held the
    /// brush does not paint.
    property bool spacePanning: false
    /// Tab gives the picture the whole canvas by hiding the two side panels.
    property bool panelsHidden: false
    readonly property real minimumPaintSize: 1
    readonly property real maximumPaintSize: 400
    /// A small, fixed palette: enough to pick a colour without a platform
    /// colour dialog (which is a portal question of its own), and the field
    /// stays the way to any other value.
    readonly property var paintSwatches: [
        "#000000", "#ffffff", "#e5484d", "#f5a623",
        "#3fb950", "#2f81f7", "#a371f7", "#8b5e3c"
    ]

    /// Whether a left press paints instead of panning.
    function paintArmed() {
        return view.tool === "paint" && view.documentReady
            && view.previewDraft === null && !view.spacePanning
    }

    /// The three bytes for `paintColor`. Core carries RGB, not a QML colour.
    function paintColorBytes() {
        var match = /^#([0-9a-fA-F]{6})$/.exec(String(view.paintColor))
        if (!match) return [0, 0, 0]
        return [parseInt(match[1].slice(0, 2), 16),
                parseInt(match[1].slice(2, 4), 16),
                parseInt(match[1].slice(4, 6), 16)]
    }

    /// Normalise a typed or picked colour to `#rrggbb`. An illegal value is
    /// ignored rather than sent, so the document never sees a colour the
    /// interface cannot show.
    function setPaintColor(value) {
        var text = String(value).trim()
        if (/^[0-9a-fA-F]{6}$/.test(text)) text = "#" + text
        if (!/^#[0-9a-fA-F]{6}$/.test(text)) return
        view.paintColor = text.toLowerCase()
    }

    /// Krita's X: foreground and background swap places.
    function swapPaintColors() {
        var previous = view.paintColor
        view.paintColor = view.paintBackgroundColor
        view.paintBackgroundColor = previous
    }

    /// Krita's D: black foreground, white background.
    function resetPaintColors() {
        view.paintColor = "#000000"
        view.paintBackgroundColor = "#ffffff"
    }

    /// Krita's [ and ]: one pixel per press, ten with Shift.
    function stepPaintSize(delta) {
        view.paintSize = Math.max(view.minimumPaintSize,
                                  Math.min(view.maximumPaintSize,
                                           view.paintSize + delta))
    }

    /// Pick the paint tool and one of its two modes; the palette's Brush and
    /// Eraser buttons and the B/E keys both land here.
    function selectPaintMode(mode) {
        view.tool = "paint"
        view.paintMode = mode === "eraser" ? "eraser" : "brush"
    }

    /// Begin a stroke at a canvas-host point. A press without a drag is still a
    /// dot, which is why a one-point stroke is a valid command.
    function beginPaintStroke(hostX, hostY) {
        if (!view.paintArmed()) return
        var x = view.hostToDocX(hostX)
        var y = view.hostToDocY(hostY)
        // The matte around the picture is not canvas: a press there would send
        // a stroke Core clips away entirely, which would still cost an undo
        // step and a preview render for no pixels.
        if (x < 0 || y < 0 || x >= view.documentWidth || y >= view.documentHeight)
            return
        view.paintStroking = true
        view.paintStroke = [[x, y]]
        strokePreview.requestPaint()
    }

    /// Add a point to the open stroke. Consecutive points closer than half a
    /// document pixel are the same dab at any zoom the canvas shows, and the
    /// list is capped so a held button cannot build an unbounded command.
    function extendPaintStroke(hostX, hostY) {
        if (!view.paintStroking) return
        var x = view.hostToDocX(hostX)
        var y = view.hostToDocY(hostY)
        var points = view.paintStroke
        if (points.length >= 4096) return
        var last = points[points.length - 1]
        if (last && Math.hypot(x - last[0], y - last[1]) < 0.5) return
        points.push([x, y])
        view.paintStroke = points
        strokePreview.requestPaint()
    }

    /// End the stroke and send it as one command.
    function finishPaintStroke() {
        if (!view.paintStroking) return
        view.paintStroking = false
        var points = view.paintStroke
        view.paintStroke = []
        strokePreview.requestPaint()
        if (points.length === 0) return
        view.command({
            type: "editor_paint_stroke",
            points: points,
            color: view.paintColorBytes(),
            radius: Math.max(0.5, view.paintSize / 2),
            opacity: Math.max(0.01, view.paintOpacity / 100),
            erase: view.paintMode === "eraser"
        })
    }

    function cancelPaintStroke() {
        if (!view.paintStroking) return
        view.paintStroking = false
        view.paintStroke = []
        strokePreview.requestPaint()
    }

    /// The Krita defaults this build maps. Plain keys belong to the view, so a
    /// text field that has focus consumes them first — typing "b" into X must
    /// not arm the brush. Ctrl+Z and Ctrl+Shift+Z are the undo pair; the rest
    /// are bare keys.
    Keys.onPressed: function(event) {
        var control = (event.modifiers & Qt.ControlModifier) !== 0
        var alt = (event.modifiers & Qt.AltModifier) !== 0
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        // Crop owns the arrow keys while it is armed: they nudge the rectangle,
        // Shift steps 10 px and Alt grows or shrinks it. Enter applies and
        // Escape puts the tool down, which is what every crop tool's keyboard
        // does. A focused text field still consumes these first, because this
        // handler runs on the view only while the view has focus.
        if (!control && view.tool === "crop" && view.documentReady) {
            var cropStep = shift ? 10 : 1
            if (event.key === Qt.Key_Escape) {
                view.tool = "pointer"
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (view.cropCanApply()) view.applyCrop()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Left || event.key === Qt.Key_Right
                    || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                if (view.cropHasRect()) {
                    var dx = event.key === Qt.Key_Left ? -cropStep
                             : event.key === Qt.Key_Right ? cropStep : 0
                    var dy = event.key === Qt.Key_Up ? -cropStep
                             : event.key === Qt.Key_Down ? cropStep : 0
                    if (alt) view.resizeCropBy(dx, dy)
                    else view.moveCropBy(dx, dy)
                }
                event.accepted = true
                return
            }
        }
        if (control || alt) {
            if (control && !alt && (event.key === Qt.Key_Z || event.key === Qt.Key_Y)) {
                var redo = event.key === Qt.Key_Y || shift
                view.command({ type: redo ? "editor_redo" : "editor_undo" })
                event.accepted = true
            }
            return
        }
        if (event.isAutoRepeat && event.key === Qt.Key_Tab) return
        switch (event.key) {
        case Qt.Key_B:
            view.selectPaintMode("brush")
            event.accepted = true
            break
        case Qt.Key_E:
            view.selectPaintMode("eraser")
            event.accepted = true
            break
        case Qt.Key_BracketLeft:
            view.stepPaintSize(shift ? -10 : -1)
            event.accepted = true
            break
        case Qt.Key_BracketRight:
            view.stepPaintSize(shift ? 10 : 1)
            event.accepted = true
            break
        case Qt.Key_X:
            view.swapPaintColors()
            event.accepted = true
            break
        case Qt.Key_D:
            view.resetPaintColors()
            event.accepted = true
            break
        case Qt.Key_Space:
            if (view.documentReady) {
                // Space interrupts a stroke rather than swallowing it: the
                // stroke is finished as drawn, then the button pans.
                view.finishPaintStroke()
                view.spacePanning = true
                event.accepted = true
            }
            break
        case Qt.Key_Plus:
        case Qt.Key_Equal:
            if (view.documentReady) {
                view.zoomIn()
                event.accepted = true
            }
            break
        case Qt.Key_Minus:
        case Qt.Key_Underscore:
            if (view.documentReady) {
                view.zoomOut()
                event.accepted = true
            }
            break
        case Qt.Key_Tab:
            view.panelsHidden = !view.panelsHidden
            event.accepted = true
            break
        }
    }
    Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Space) {
            view.spacePanning = false
            event.accepted = true
        }
    }
    // A key release is delivered to the item that has focus, so losing focus
    // mid-stroke would otherwise leave Space stuck down and a half-drawn
    // stroke on screen forever.
    onActiveFocusChanged: {
        if (!activeFocus) {
            view.spacePanning = false
            view.cancelPaintStroke()
        }
    }

    /// The quad that changes nothing: the document's own frame.
    function identityCorners() {
        return [[0, 0],
                [view.documentWidth, 0],
                [view.documentWidth, view.documentHeight],
                [0, view.documentHeight]]
    }

    function resetTransformCorners() {
        view.transformCorners = view.identityCorners()
    }

    function cornerX(index) {
        var corners = view.transformCorners
        return corners && corners.length === 4 ? corners[index][0] : 0
    }

    function cornerY(index) {
        var corners = view.transformCorners
        return corners && corners.length === 4 ? corners[index][1] : 0
    }

    /// Move one corner to a point given in canvas-host coordinates, clamped to
    /// the picture so the command can never name a corner with no pixels.
    function setTransformCorner(index, hostX, hostY) {
        var corners = view.transformCorners
        if (!corners || corners.length !== 4) return
        var x = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(hostX)))
        var y = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(hostY)))
        var next = []
        for (var i = 0; i < 4; ++i) next.push([corners[i][0], corners[i][1]])
        next[index] = [Math.round(x * 10) / 10, Math.round(y * 10) / 10]
        view.transformCorners = next
    }

    /// Move the two corners of edge `index` (from corner `index` to corner
    /// `index + 1`) by the same offset, so the edge follows the pointer and
    /// stays parallel to itself. The offset is clamped for both corners at
    /// once, otherwise one of them could leave the picture and fold the quad.
    function moveTransformEdge(index, hostX, hostY) {
        var corners = view.transformCorners
        if (!corners || corners.length !== 4) return
        var first = index % 4
        var second = (index + 1) % 4
        var midX = (corners[first][0] + corners[second][0]) / 2
        var midY = (corners[first][1] + corners[second][1]) / 2
        var dx = view.hostToDocX(hostX) - midX
        var dy = view.hostToDocY(hostY) - midY
        dx = Math.max(-Math.min(corners[first][0], corners[second][0]),
                Math.min(dx, view.documentWidth - Math.max(corners[first][0], corners[second][0])))
        dy = Math.max(-Math.min(corners[first][1], corners[second][1]),
                Math.min(dy, view.documentHeight - Math.max(corners[first][1], corners[second][1])))
        var next = []
        for (var i = 0; i < 4; ++i) next.push([corners[i][0], corners[i][1]])
        next[first] = [Math.round((corners[first][0] + dx) * 10) / 10,
                       Math.round((corners[first][1] + dy) * 10) / 10]
        next[second] = [Math.round((corners[second][0] + dx) * 10) / 10,
                        Math.round((corners[second][1] + dy) * 10) / 10]
        view.transformCorners = next
    }

    /// Whether the quad is worth sending. Core is the authority and answers a
    /// rejected corner with a translated line; this repeats only the two
    /// geometric guards — inside the picture, clockwise and not folded — so a
    /// quad Core would refuse is never rendered or applied in the first place.
    function transformUsable() {
        var corners = view.transformCorners
        if (!view.documentReady || !corners || corners.length !== 4) return false
        var winding = 0
        for (var index = 0; index < 4; ++index) {
            var point = corners[index]
            if (!(typeof point[0] === "number") || !(typeof point[1] === "number")) return false
            if (point[0] < 0 || point[1] < 0
                    || point[0] > view.documentWidth || point[1] > view.documentHeight) return false
            var a = corners[index]
            var b = corners[(index + 1) % 4]
            var c = corners[(index + 2) % 4]
            var cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            if (Math.abs(cross) < 1e-6) return false
            var turn = cross > 0 ? 1 : -1
            if (winding === 0) winding = turn
            else if (turn !== winding) return false
        }
        return winding > 0
    }

    /// True when at least one corner left the frame, so Apply is not armed for
    /// a transform that would only answer `edit_noop`.
    function transformChanged() {
        var corners = view.transformCorners
        if (!corners || corners.length !== 4) return false
        var frame = view.identityCorners()
        for (var index = 0; index < 4; ++index) {
            if (Math.abs(corners[index][0] - frame[index][0]) > 1e-6
                    || Math.abs(corners[index][1] - frame[index][1]) > 1e-6) return true
        }
        return false
    }

    /// The ratios both size tools offer. `Free` leaves both fields alone,
    /// `Original` keeps the document's shape, `Keep current ratio` keeps whatever
    /// pair is on screen when it is picked, and the common aspect ratios cover
    /// the usual targets. Rare crops (21:9, 5:4, 16:10, 2:3) are deliberately
    /// absent: they made the dropdown longer than it was useful.
    readonly property var sizeRatios: [
        { key: "free", label: qsTr("Free") },
        { key: "original", label: qsTr("Original") },
        { key: "current", label: qsTr("Keep current ratio") },
        { key: "1:1", label: "1:1", width: 1, height: 1 },
        { key: "4:3", label: "4:3", width: 4, height: 3 },
        { key: "3:2", label: "3:2", width: 3, height: 2 },
        { key: "16:9", label: "16:9", width: 16, height: 9 },
        { key: "3:4", label: "3:4", width: 3, height: 4 },
        { key: "9:16", label: "9:16", width: 9, height: 16 }
    ]
    /// Concrete sizes for those ratios: three per ratio, all useful magnitudes
    /// rather than every power of two. Both sides stay multiples of 64, so a
    /// preset never produces fractional pixels at any scale. One flat list:
    /// the label carries the ratio, so the dropdown reads as sizes, not as a
    /// second ratio picker.
    readonly property var sizePresets: [
        { ratio: "1:1", label: "1:1 · 2048 × 2048", width: 2048, height: 2048 },
        { ratio: "1:1", label: "1:1 · 1024 × 1024", width: 1024, height: 1024 },
        { ratio: "1:1", label: "1:1 · 512 × 512", width: 512, height: 512 },
        { ratio: "4:3", label: "4:3 · 2048 × 1536", width: 2048, height: 1536 },
        { ratio: "4:3", label: "4:3 · 1024 × 768", width: 1024, height: 768 },
        { ratio: "4:3", label: "4:3 · 512 × 384", width: 512, height: 384 },
        { ratio: "3:2", label: "3:2 · 1536 × 1024", width: 1536, height: 1024 },
        { ratio: "3:2", label: "3:2 · 768 × 512", width: 768, height: 512 },
        { ratio: "3:2", label: "3:2 · 384 × 256", width: 384, height: 256 },
        { ratio: "16:9", label: "16:9 · 3072 × 1728", width: 3072, height: 1728 },
        { ratio: "16:9", label: "16:9 · 2048 × 1152", width: 2048, height: 1152 },
        { ratio: "16:9", label: "16:9 · 1024 × 576", width: 1024, height: 576 },
        { ratio: "3:4", label: "3:4 · 1536 × 2048", width: 1536, height: 2048 },
        { ratio: "3:4", label: "3:4 · 768 × 1024", width: 768, height: 1024 },
        { ratio: "3:4", label: "3:4 · 384 × 512", width: 384, height: 512 },
        { ratio: "9:16", label: "9:16 · 1728 × 3072", width: 1728, height: 3072 },
        { ratio: "9:16", label: "9:16 · 1152 × 2048", width: 1152, height: 2048 },
        { ratio: "9:16", label: "9:16 · 576 × 1024", width: 576, height: 1024 }
    ]
    /// The nine places a crop rectangle can hold in the document. The glyph
    /// points at the corner or edge the rectangle keeps; `column`/`row` are the
    /// 0/1/2 grid coordinates `applyCropAnchor` uses, so the arrows and the
    /// placement cannot drift apart.
    readonly property var cropAnchors: [
        { key: "top_left", glyph: "\u2196", label: qsTr("Top left"), column: 0, row: 0 },
        { key: "top", glyph: "\u2191", label: qsTr("Top"), column: 1, row: 0 },
        { key: "top_right", glyph: "\u2197", label: qsTr("Top right"), column: 2, row: 0 },
        { key: "left", glyph: "\u2190", label: qsTr("Left"), column: 0, row: 1 },
        { key: "center", glyph: "\u25cf", label: qsTr("Center"), column: 1, row: 1 },
        { key: "right", glyph: "\u2192", label: qsTr("Right"), column: 2, row: 1 },
        { key: "bottom_left", glyph: "\u2199", label: qsTr("Bottom left"), column: 0, row: 2 },
        { key: "bottom", glyph: "\u2193", label: qsTr("Bottom"), column: 1, row: 2 },
        { key: "bottom_right", glyph: "\u2198", label: qsTr("Bottom right"), column: 2, row: 2 }
    ]

    /// Split a QML `color` into the three bytes the typed command carries.
    function colorRgb(color) {
        return [Math.round(color.r * 255), Math.round(color.g * 255),
                Math.round(color.b * 255)]
    }

    /// Crop's two answers to "may the frame leave the picture?": `center` is
    /// the ordinary cut, `grow` a new canvas around the photo.
    readonly property var cropModes: [
        { key: "center", label: qsTr("Center") },
        { key: "grow", label: qsTr("Grow") }
    ]
    /// The colours a grown border can take. `None` is absent on purpose: a grow
    /// always paints *something*, and the transparent choice is how it paints
    /// nothing the eye can see.
    readonly property var cropBackdrops: [
        { key: "transparent", label: qsTr("Transparent") },
        { key: "black", label: qsTr("Black") },
        { key: "white", label: qsTr("White") },
        { key: "gray", label: qsTr("Gray") },
        { key: "custom", label: qsTr("Custom color…") }
    ]

    function cropGrow() {
        return view.cropMode === "grow"
    }

    function cropModeIndex() {
        for (var index = 0; index < view.cropModes.length; ++index) {
            if (view.cropModes[index].key === view.cropMode) return index
        }
        return 0
    }

    function cropFillIndex() {
        for (var index = 0; index < view.cropBackdrops.length; ++index) {
            if (view.cropBackdrops[index].key === view.cropFill) return index
        }
        return 0
    }

    /// Switch between an inside crop and a growing one. Turning Grow off must
    /// pull a rectangle that reached outside back into the picture, or Apply
    /// would stay disabled with no visible reason.
    function setCropMode(mode) {
        view.cropMode = mode
        cropModeBox.currentIndex = view.cropModeIndex()
        if (view.cropGrow()) {
            if (view.cropHasRect()) view.revealCropGrowth()
        } else if (view.cropHasRect()) {
            var rect = view.cropRect
            view.setCropRect(rect.x, rect.y, rect.width, rect.height)
        }
        // The preset list itself depends on the mode (Center only offers sizes
        // the picture can hold), so the mirror is re-read after the switch.
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    /// Grow needs room outside the picture, and the canvas host clips at its
    /// own edge: a fitted picture keeps only 32 px of margin, so a frame handle
    /// could not be dragged outward at all. Step the view back once when Grow
    /// is picked — enough for a border on every side — and leave a view that
    /// already has that room (a hand-chosen zoom) alone.
    function revealCropGrowth() {
        if (!view.hasDocument || !view.hostReady) return
        var hostWidth = canvasHost.width
        var hostHeight = canvasHost.height
        if (hostWidth <= 1 || hostHeight <= 1) return
        var shownWidth = view.displayedWidth * view.zoom
        var shownHeight = view.displayedHeight * view.zoom
        if ((hostWidth - shownWidth) / 2 >= hostWidth * 0.12
                && (hostHeight - shownHeight) / 2 >= hostHeight * 0.12) return
        view.fit()
        view.zoom = Math.max(0.02, view.zoom * 0.72)
        view.autoFit = false
        view.offsetX = 0
        view.offsetY = 0
    }

    /// Pick a border colour; `Custom color…` opens the chooser, and a cancelled
    /// chooser leaves the previous choice on screen.
    function chooseCropFill(index) {
        if (index < 0 || index >= view.cropBackdrops.length) return
        var key = view.cropBackdrops[index].key
        if (key === "custom") {
            cropFillColorDialog.open()
            return
        }
        view.cropFill = key
        cropFillBox.currentIndex = index
        draftDebounce.restart()
    }

    /// The swatch beside the fill dropdown. Transparent has no colour to show,
    /// so it borrows the panel's alternate surface and says "0" instead.
    function cropFillPreviewColor() {
        switch (view.cropFill) {
        case "black": return "#000000"
        case "white": return "#ffffff"
        case "gray": return "#808080"
        case "custom": return view.cropFillColor
        default: return view.theme.surfaceAlt
        }
    }

    /// The border colour the command carries, or `null` for an inside crop.
    /// Core reads a present colour as "the canvas may grow". A Grow rectangle
    /// that still lies inside the picture has no border to paint, so it travels
    /// as an ordinary crop and its history line says Crop, not Grow.
    function cropFillForCommand() {
        if (!view.cropGrow()) return null
        var rect = view.cropRect
        if (rect.x >= 0 && rect.y >= 0
                && rect.x + rect.width <= view.documentWidth
                && rect.y + rect.height <= view.documentHeight) return null
        switch (view.cropFill) {
        case "black": return [0, 0, 0]
        case "white": return [255, 255, 255]
        case "gray": return [128, 128, 128]
        case "custom": return view.colorRgb(view.cropFillColor)
        default: return [0, 0, 0]
        }
    }

    function cropFillAlpha() {
        return view.cropFill === "transparent" ? 0 : 255
    }

    /// The ratio the crop fields are held to, as a pair, or null when the
    /// sides are independent. The field carries text, so any shape is possible;
    /// the presets and the swap button still use the short named list.
    function cropRatioPair() {
        if (view.cropRatio === "free") return null
        return view.parseRatio(view.cropRatio)
    }

    function gcd(a, b) {
        a = Math.abs(Math.round(a))
        b = Math.abs(Math.round(b))
        while (b) {
            var next = a % b
            a = b
            b = next
        }
        return a > 0 ? a : 1
    }

    /// A pair written the way a person writes it: reduced by its greatest
    /// common divisor, so 1024 × 768 shows as `4:3` rather than `1024:768`.
    function reducedRatio(width, height) {
        width = Math.round(width)
        height = Math.round(height)
        if (!(width > 0) || !(height > 0)) return "free"
        var divisor = view.gcd(width, height)
        return (width / divisor) + ":" + (height / divisor)
    }

    /// `3:2`, `3/2`, `3x2` and a bare `2` (meaning 2:1) all parse; anything
    /// else, including an empty string, is not a ratio.
    function parseRatio(text) {
        if (text === undefined || text === null) return null
        var cleaned = String(text).trim()
        if (cleaned === "") return null
        var match = /^(\d+)\s*[:/xX]\s*(\d+)$/.exec(cleaned)
        if (!match) {
            if (/^\d+$/.test(cleaned)) {
                var single = parseInt(cleaned)
                return single > 0 ? { width: single, height: 1 } : null
            }
            return null
        }
        var width = parseInt(match[1])
        var height = parseInt(match[2])
        if (!(width > 0) || !(height > 0)) return null
        return { width: width, height: height }
    }

    /// The ratio the rectangle is currently held to, as width / height, or 0
    /// when the sides are free.
    function cropRatioAspect() {
        var pair = view.cropRatioPair()
        return pair ? pair.width / pair.height : 0
    }

    function cropMaxWidth() {
        return view.cropGrow() ? 20000 : view.documentWidth
    }

    function cropMaxHeight() {
        return view.cropGrow() ? 20000 : view.documentHeight
    }

    /// Round a pair to whole pixels and keep it legal. A linked pair is scaled
    /// as one shape, so fitting it never breaks the ratio; independent sides are
    /// clamped one at a time.
    function clampCropPair(width, height, linked) {
        width = Math.max(1, Math.min(20000, Math.round(width)))
        height = Math.max(1, Math.min(20000, Math.round(height)))
        var maxWidth = view.cropMaxWidth()
        var maxHeight = view.cropMaxHeight()
        if (linked) {
            var scale = Math.min(1, maxWidth / width, maxHeight / height)
            width = Math.max(1, Math.round(width * scale))
            height = Math.max(1, Math.round(height * scale))
        } else {
            width = Math.max(1, Math.min(maxWidth, width))
            height = Math.max(1, Math.min(maxHeight, height))
        }
        return { width: width, height: height }
    }

    /// The ratio field owns its text while it has focus. Every other path that
    /// changes `cropRatio` (a preset, Reset, a locked-side derivation) writes
    /// the field through this, so a typo is never overwritten mid-keystroke.
    function syncCropRatioField() {
        if (typeof cropRatioField === "undefined" || cropRatioField === null) return
        if (cropRatioField.activeFocus) return
        cropRatioField.text = view.cropRatio === "free" ? "" : view.cropRatio
    }

    /// Keep the ratio text honest when an unlocked ratio follows a pair that a
    /// locked side just changed. A locked ratio is never rewritten.
    function setCropRatioFromPair(width, height) {
        if (view.cropLockRatio) return
        if (!(width > 0) || !(height > 0)) return
        view.cropRatio = view.reducedRatio(width, height)
        view.syncCropRatioField()
    }

    /// Pick a ratio from text. An empty field is Free; an unreadable one puts
    /// the previous value back rather than silently changing the shape.
    function setCropRatio(text) {
        if (view.cropLockWidth && view.cropLockHeight) {
            view.syncCropRatioField()
            return
        }
        var cleaned = String(text === undefined || text === null ? "" : text).trim()
        if (cleaned === "" || cleaned.toLowerCase() === "free") {
            view.cropRatio = "free"
            view.syncCropRatioField()
            return
        }
        var pair = view.parseRatio(cleaned)
        if (!pair) {
            view.syncCropRatioField()
            return
        }
        view.cropRatio = view.reducedRatio(pair.width, pair.height)
        view.syncCropRatioField()
        view.applyCropRatio()
    }

    /// Apply the current ratio to the fields. The locked side wins when one is
    /// pinned; otherwise Width is the starting side (Height when Width is
    /// empty). Clamping happens once, on the shape, so a ratio never survives
    /// as a pair the document cannot hold.
    function applyCropRatio() {
        var pair = view.cropRatioPair()
        if (!pair) {
            view.applyCropAnchor()
            cropPreset.currentIndex = view.matchingCropPreset()
            return
        }
        var width = cropWidthField.acceptableInput ? parseInt(cropWidthField.text) : 0
        var height = cropHeightField.acceptableInput ? parseInt(cropHeightField.text) : 0
        if (view.cropLockWidth && width > 0) {
            height = width * pair.height / pair.width
        } else if (view.cropLockHeight && height > 0) {
            width = height * pair.width / pair.height
        } else if (width > 0) {
            height = width * pair.height / pair.width
        } else if (height > 0) {
            width = height * pair.width / pair.height
        } else {
            return
        }
        var clamped = view.clampCropPair(width, height, true)
        cropWidthField.text = String(clamped.width)
        cropHeightField.text = String(clamped.height)
        view.applyCropAnchor()
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    /// Read the ratio field. Called while typing (once the text is a complete
    /// ratio) and when editing finishes (so a bad entry is put back).
    function applyCropRatioText() {
        if (typeof cropRatioField === "undefined" || cropRatioField === null) return
        if (view.cropLockWidth && view.cropLockHeight) {
            view.syncCropRatioField()
            return
        }
        var cleaned = cropRatioField.text.trim()
        if (cleaned === "") {
            view.cropRatio = "free"
            return
        }
        if (!view.parseRatio(cleaned)) return
        view.setCropRatio(cleaned)
    }

    /// Flip one lock and let the other two settle. A third lock is never
    /// allowed to join a pair: W+H makes Ratio a consequence, and Ratio plus a
    /// side makes the other side derived.
    function setCropLock(which, locked) {
        if (which === "width") {
            if (view.cropLockWidth === locked) return
            if (locked && view.cropLockHeight && view.cropLockRatio) return
            view.cropLockWidth = locked
            if (locked && !cropWidthField.acceptableInput && view.hasDocument) {
                cropWidthField.text = String(Math.round(view.documentWidth))
            }
        } else if (which === "height") {
            if (view.cropLockHeight === locked) return
            if (locked && view.cropLockWidth && view.cropLockRatio) return
            view.cropLockHeight = locked
            if (locked && !cropHeightField.acceptableInput && view.hasDocument) {
                cropHeightField.text = String(Math.round(view.documentHeight))
            }
        } else if (which === "ratio") {
            if (view.cropLockRatio === locked) return
            if (locked && view.cropLockWidth && view.cropLockHeight) return
            view.cropLockRatio = locked
            if (locked && view.cropRatio === "free") {
                // Locking a free shape freezes the one on screen; with no frame
                // yet, the document's own shape is the honest starting point.
                if (view.cropHasRect()) {
                    view.cropRatio = view.reducedRatio(
                                parseInt(cropWidthField.text),
                                parseInt(cropHeightField.text))
                } else if (view.hasDocument) {
                    view.cropRatio = view.reducedRatio(view.documentWidth,
                                                       view.documentHeight)
                }
                view.syncCropRatioField()
            }
        } else {
            return
        }
        if (view.cropLockWidth && view.cropLockHeight) {
            // Two pinned sides fix the shape: the ratio becomes a consequence
            // and stops being an input, so its field is disabled and its text
            // follows the pair.
            view.cropLockRatio = false
            if (cropWidthField.acceptableInput && cropHeightField.acceptableInput) {
                view.setCropRatioFromPair(parseInt(cropWidthField.text),
                                          parseInt(cropHeightField.text))
            }
        }
        // A side locked together with the ratio is the only combination where
        // one field is a consequence rather than an input.
        if (view.cropLockRatio && (view.cropLockWidth || view.cropLockHeight)) {
            view.applyCropRatio()
        }
        view.syncCropLockButtons()
        view.syncCropRatioField()
    }

    /// Reset the three toggle buttons from the properties. The controls write
    /// `checked` themselves, so a programmatic Reset cannot rely on a binding.
    function syncCropLockButtons() {
        if (typeof cropLockWidthButton !== "undefined" && cropLockWidthButton !== null)
            cropLockWidthButton.checked = view.cropLockWidth
        if (typeof cropHeightButton !== "undefined" && cropHeightButton !== null)
            cropHeightButton.checked = view.cropLockHeight
        if (typeof cropRatioButton !== "undefined" && cropRatioButton !== null)
            cropRatioButton.checked = view.cropLockRatio
    }

    /// Crop presets are the concrete sizes that fit inside the document. A
    /// preset the document cannot hold is not offered, so picking one always
    /// describes a legal rectangle; a tiny document simply has a shorter list.
    /// A growing crop may hold anything, so it keeps the whole list.
    readonly property var cropPresets: {
        if (!view.hasDocument) return []
        if (view.cropGrow()) return view.sizePresets
        var fits = []
        for (var index = 0; index < view.sizePresets.length; ++index) {
            var preset = view.sizePresets[index]
            if (preset.width <= view.documentWidth && preset.height <= view.documentHeight) {
                fits.push(preset)
            }
        }
        return fits
    }

    /// Index of the crop preset that matches both fields, or -1 for custom.
    function matchingCropPreset() {
        if (!cropWidthField.acceptableInput || !cropHeightField.acceptableInput) return -1
        var w = parseInt(cropWidthField.text)
        var h = parseInt(cropHeightField.text)
        for (var index = 0; index < view.cropPresets.length; ++index) {
            var preset = view.cropPresets[index]
            if (preset.width === w && preset.height === h) return index
        }
        return -1
    }

    /// Place X/Y from the anchor and the current Width/Height. Only the size
    /// moves the rectangle: typing X/Y is the user's own placement and must not
    /// be overwritten. A rectangle smaller than the document keeps the named
    /// corner, edge or centre of the document.
    function applyCropAnchor() {
        if (!view.hasDocument || !cropWidthField.acceptableInput
                || !cropHeightField.acceptableInput) return
        var width = parseInt(cropWidthField.text)
        var height = parseInt(cropHeightField.text)
        if (!(width > 0) || !(height > 0)) return
        var anchor = view.cropAnchors[0]
        for (var index = 0; index < view.cropAnchors.length; ++index) {
            if (view.cropAnchors[index].key === view.cropAnchor) {
                anchor = view.cropAnchors[index]
                break
            }
        }
        cropX.text = String(view.cropGrow()
                            ? Math.round((view.documentWidth - width) * anchor.column / 2)
                            : Math.max(0, Math.round((view.documentWidth - width) * anchor.column / 2)))
        cropY.text = String(view.cropGrow()
                            ? Math.round((view.documentHeight - height) * anchor.row / 2)
                            : Math.max(0, Math.round((view.documentHeight - height) * anchor.row / 2)))
    }

    /// Select an anchor. With no frame yet, this is also a way to create one:
    /// the typed sides (or the document's own shape when nothing is typed) are
    /// placed at the named corner, edge or centre.
    function setCropAnchor(key) {
        view.cropAnchor = key
        view.ensureCropFrame()
        view.applyCropAnchor()
        draftDebounce.restart()
    }

    /// Build a rectangle from what the panel already says, without a drag.
    /// Width then Height is the order fields are normally filled; a missing
    /// side follows the ratio, or the document's shape when the ratio is free.
    function ensureCropFrame() {
        if (view.cropHasRect() || !view.hasDocument) return
        var width = cropWidthField.acceptableInput ? parseInt(cropWidthField.text) : 0
        var height = cropHeightField.acceptableInput ? parseInt(cropHeightField.text) : 0
        var pair = view.cropRatioPair()
        if (!(width > 0) && !(height > 0)) {
            width = view.documentWidth
            height = view.documentHeight
        } else if (!(width > 0)) {
            width = pair ? height * pair.width / pair.height
                        : height * view.documentWidth / view.documentHeight
        } else if (!(height > 0)) {
            height = pair ? width * pair.height / pair.width
                         : width * view.documentHeight / view.documentWidth
        }
        var clamped = view.clampCropPair(width, height, pair !== null)
        cropWidthField.text = String(clamped.width)
        cropHeightField.text = String(clamped.height)
        view.applyCropAnchor()
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    /// Typing one side keeps the other on the chosen ratio. Programmatic writes
    /// (a preset, Reset) do not come through here, so they never feed back.
    /// A crop is re-placed through its anchor even when the ratio is free: the
    /// anchor is about where the rectangle sits, not about linking the sides.
    function linkHeightFromWidth() {
        if (!view.cropWidthEditable) return
        if (!cropWidthField.acceptableInput) return
        var width = parseInt(cropWidthField.text)
        if (!(width > 0)) return
        var pair = view.cropRatioPair()
        var height = cropHeightField.acceptableInput ? parseInt(cropHeightField.text) : 0
        if (pair) {
            if (view.cropLockHeight) {
                // The locked side stays; the unlocked ratio follows the pair.
                if (height > 0) view.setCropRatioFromPair(width, height)
                var held = view.clampCropPair(width, height, false)
                width = held.width
                height = held.height
            } else {
                height = width * pair.height / pair.width
                var linked = view.clampCropPair(width, height, true)
                width = linked.width
                height = linked.height
            }
        } else {
            if (!(height > 0)) height = width * view.documentHeight / view.documentWidth
            var free = view.clampCropPair(width, height, false)
            width = free.width
            height = free.height
        }
        cropWidthField.text = String(width)
        cropHeightField.text = String(height)
        view.applyCropAnchor()
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    function linkWidthFromHeight() {
        if (!view.cropHeightEditable) return
        if (!cropHeightField.acceptableInput) return
        var height = parseInt(cropHeightField.text)
        if (!(height > 0)) return
        var pair = view.cropRatioPair()
        var width = cropWidthField.acceptableInput ? parseInt(cropWidthField.text) : 0
        if (pair) {
            if (view.cropLockWidth) {
                // The locked side stays; the unlocked ratio follows the pair.
                if (width > 0) view.setCropRatioFromPair(width, height)
                var held = view.clampCropPair(width, height, false)
                width = held.width
                height = held.height
            } else {
                width = height * pair.width / pair.height
                var linked = view.clampCropPair(width, height, true)
                width = linked.width
                height = linked.height
            }
        } else {
            if (!(width > 0)) width = height * view.documentWidth / view.documentHeight
            var free = view.clampCropPair(width, height, false)
            width = free.width
            height = free.height
        }
        cropWidthField.text = String(width)
        cropHeightField.text = String(height)
        view.applyCropAnchor()
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    /// Keep the fields on the selected ratio when the ratio itself is picked.
    function relinkFields() {
        if (view.cropRatio === "free") {
            view.applyCropAnchor()
            return
        }
        view.applyCropRatio()
    }

    /// Select Crop's ratio by name. The text field is the real owner; this is
    /// the programmatic entry point the presets, the swap button and the
    /// harness use. `original`/`current` are compatibility spellings for the
    /// document's own shape.
    function setRatio(key) {
        if (key === "original" || key === "current") {
            if (!view.hasDocument) return
            view.setCropRatio(view.reducedRatio(view.documentWidth,
                                               view.documentHeight))
            return
        }
        view.setCropRatio(key)
    }

    /// Apply one of the concrete sizes from Crop's dropdown. `onActivated` calls
    /// this for a real pick; a programmatic `currentIndex` change (the field/link
    /// code mirrors a matching size) must not re-apply it. A locked side keeps
    /// its value: the other side and the shape follow the preset.
    function chooseCropPreset(index) {
        if (index < 0 || index >= view.cropPresets.length) return
        if (!view.cropResizable) return
        var preset = view.cropPresets[index]
        view.cropRatio = preset.ratio
        view.syncCropRatioField()
        var width = view.cropLockWidth
                ? (cropWidthField.acceptableInput ? parseInt(cropWidthField.text)
                                                  : preset.width)
                : preset.width
        var height = view.cropLockHeight
                ? (cropHeightField.acceptableInput ? parseInt(cropHeightField.text)
                                                   : preset.height)
                : preset.height
        if (view.cropLockWidth && !view.cropLockHeight) {
            height = width * preset.height / preset.width
        } else if (view.cropLockHeight && !view.cropLockWidth) {
            width = height * preset.width / preset.height
        }
        var clamped = view.clampCropPair(width, height, true)
        cropWidthField.text = String(clamped.width)
        cropHeightField.text = String(clamped.height)
        view.applyCropAnchor()
        cropPreset.currentIndex = index
        draftDebounce.restart()
    }

    function cropFieldsValid() {
        if (!view.hasDocument || !cropWidthField.acceptableInput
                || !cropHeightField.acceptableInput) return false
        if (!cropX.acceptableInput || !cropY.acceptableInput) return false
        var width = parseInt(cropWidthField.text)
        var height = parseInt(cropHeightField.text)
        if (!(width > 0) || !(height > 0)) return false
        var x = parseInt(cropX.text)
        var y = parseInt(cropY.text)
        if (view.cropGrow()) {
            // Core's grow rule: the canvas may reach outside, but the rectangle
            // must still cover part of the picture — a border, not a blank page.
            return x + width > 0 && y + height > 0
                    && x < view.documentWidth && y < view.documentHeight
                    && width <= 20000 && height <= 20000
        }
        return x >= 0 && y >= 0
                && x + width <= view.documentWidth
                && y + height <= view.documentHeight
    }

    /// The rectangle the canvas frame draws, read from the same four fields the
    /// command is built from — the frame is a second view of one truth, not a
    /// second copy of the rectangle.
    readonly property var cropRect: {
        return {
            x: cropX.acceptableInput ? parseInt(cropX.text) : 0,
            y: cropY.acceptableInput ? parseInt(cropY.text) : 0,
            width: cropWidthField.acceptableInput ? parseInt(cropWidthField.text) : 0,
            height: cropHeightField.acceptableInput ? parseInt(cropHeightField.text) : 0
        }
    }

    function cropHasRect() {
        var rect = view.cropRect
        return rect.width > 0 && rect.height > 0
    }

    /// A crop that keeps every pixel is not an edit: Core would only answer
    /// `edit_noop`, and the Apply button should say so instead of sending it.
    function cropChanged() {
        if (!view.cropHasRect()) return false
        var rect = view.cropRect
        return !(rect.x === 0 && rect.y === 0
                 && rect.width === view.documentWidth
                 && rect.height === view.documentHeight)
    }

    function cropCanApply() {
        return view.cropFieldsValid() && view.cropChanged()
    }

    /// Reshape the rectangle to the chosen ratio, keeping the current width as
    /// the starting point and shrinking both sides if the document cannot hold
    /// that shape. A fixed 16:9 picked on a portrait document therefore lands as
    /// the largest 16:9 rectangle that fits, not as a rectangle Core would
    /// reject. With a locked side, that side is what the shape is fitted to.
    function reshapeCropToRatio() {
        if (!view.hasDocument) return
        view.applyCropRatio()
    }

    /// Turn the rectangle through 90° around its own centre — the crop-tool
    /// "swap orientation" every common editor offers, useful for a portrait
    /// cut out of a landscape frame and back. The pair stays inside the
    /// document; a chosen ratio turns with it. A lock on either axis or on the
    /// ratio would be changed by the turn, so swap is refused then.
    function swapCropOrientation() {
        if (!view.documentReady || !view.cropHasRect()) return
        if (view.cropLockWidth || view.cropLockHeight || view.cropLockRatio) return
        var rect = view.cropRect
        var centreX = rect.x + rect.width / 2
        var centreY = rect.y + rect.height / 2
        var width = Math.max(1, rect.height)
        var height = Math.max(1, rect.width)
        var scale = view.cropGrow()
                ? Math.min(1, 20000 / width, 20000 / height)
                : Math.min(1, view.documentWidth / width, view.documentHeight / height)
        width = Math.max(1, Math.round(width * scale))
        height = Math.max(1, Math.round(height * scale))
        view.setCropRect(Math.round(centreX - width / 2),
                         Math.round(centreY - height / 2), width, height)
        var pair = view.cropRatioPair()
        if (pair) {
            view.cropRatio = view.reducedRatio(pair.height, pair.width)
            view.syncCropRatioField()
        }
        cropPreset.currentIndex = view.matchingCropPreset()
    }

    /// Arrow-key nudges. The rectangle is clamped by `setCropRect`, so holding
    /// a key at an edge stops there instead of walking out of the document.
    function moveCropBy(deltaX, deltaY) {
        if (!view.cropHasRect()) return
        var rect = view.cropRect
        view.setCropRect(rect.x + deltaX, rect.y + deltaY, rect.width, rect.height)
    }

    /// Alt+arrow resize keeps the centre and, with a ratio chosen, the shape:
    /// a width step derives the height (and the other way round), then both
    /// shrink together if the document cannot hold them. A locked side takes
    /// the other axis instead; two locks make the shape fixed, so the step is
    /// refused.
    function resizeCropBy(deltaWidth, deltaHeight) {
        if (!view.cropHasRect() || !view.cropResizable) return
        var rect = view.cropRect
        var aspect = view.cropRatioAspect()
        var width = rect.width
        var height = rect.height
        if (view.cropLockWidth) {
            height = Math.max(1, height + deltaHeight)
        } else if (view.cropLockHeight) {
            width = Math.max(1, width + deltaWidth)
        } else {
            width = Math.max(1, width + deltaWidth)
            height = Math.max(1, height + deltaHeight)
            if (aspect > 0) {
                if (deltaWidth !== 0) height = Math.max(1, Math.round(width / aspect))
                else if (deltaHeight !== 0) width = Math.max(1, Math.round(height * aspect))
            }
        }
        var clamped = view.clampCropPair(width, height, aspect > 0)
        width = clamped.width
        height = clamped.height
        var centreX = rect.x + rect.width / 2
        var centreY = rect.y + rect.height / 2
        view.setCropRect(centreX - width / 2, centreY - height / 2, width, height)
        if (aspect > 0 && !view.cropLockRatio && (view.cropLockWidth || view.cropLockHeight)) {
            view.setCropRatioFromPair(width, height)
        }
    }

    function clearCropFields() {
        cropWidthField.text = ""
        cropHeightField.text = ""
        cropX.text = "0"
        cropY.text = "0"
        cropPreset.currentIndex = -1
    }

    /// Opening Crop never shows a frame: the rectangle is the user's answer,
    /// drawn on the picture, clicked into place, or typed in the panel. Options
    /// that are not about the rectangle (ratio, mode, fill, anchor) survive a
    /// tool switch, so returning to Crop does not lose a colour or a mode.
    function enterCropTool() {
        view.clearCropFields()
        view.releaseCropLocks()
        view.syncCropRatioField()
    }

    /// A new rectangle is a new answer, not an edit of the old one, so drawing
    /// or clicking one releases the three locks: they described a shape that
    /// no longer exists. Clear and a landed Apply do the same.
    function releaseCropLocks() {
        view.cropLockWidth = false
        view.cropLockHeight = false
        view.cropLockRatio = false
        view.syncCropLockButtons()
    }

    /// A click with no drag is not a zero-size crop: it asks for the whole
    /// picture, which is the one rectangle a frame can always start from.
    function createFullCropFrame() {
        if (!view.documentReady) return
        view.releaseCropLocks()
        view.setCropRect(0, 0, view.documentWidth, view.documentHeight)
    }

    /// Clear puts the frame down and returns to the state Crop opens in. The
    /// locks go with it, because they were about the rectangle; the mode, the
    /// border colour, the ratio and the anchor stay.
    function clearCropFrame() {
        view.clearCropFields()
        view.releaseCropLocks()
        view.syncCropRatioField()
    }

    /// Reset puts the panel's options back to their defaults and leaves the
    /// rectangle where it is. The preset goes back to Custom even when the pair
    /// still matches a preset, because Reset is a statement about the panel,
    /// not about the size.
    function resetCropOptions() {
        view.cropRatio = "free"
        view.cropAnchor = "center"
        view.cropMode = "center"
        view.cropFill = "transparent"
        view.cropFillColor = "#808080"
        view.cropLockWidth = false
        view.cropLockHeight = false
        view.cropLockRatio = false
        cropModeBox.currentIndex = view.cropModeIndex()
        cropFillBox.currentIndex = view.cropFillIndex()
        cropPreset.currentIndex = -1
        view.syncCropLockButtons()
        view.syncCropRatioField()
    }

    /// Apply is the only place a crop reaches Core. The result's own size is
    /// recorded first, so the view can tell a landed cut from a refused one:
    /// the fresh frame covers the whole result, and the next crop starts from
    /// what the user can see rather than from pixels that are gone.
    function applyCrop() {
        if (!view.cropCanApply()) return
        var rect = view.cropRect
        var fill = view.cropFillForCommand()
        view.pendingCropResult = { width: rect.width, height: rect.height }
        view.command({
            type: "editor_crop",
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
            fill: fill,
            fill_alpha: fill === null ? 255 : view.cropFillAlpha()
        })
        // The real gateway publishes the new document before `command()`
        // returns; the QML suite delivers it on its next state publish, which
        // calls this again from the size handler.
        view.settleAppliedCrop()
    }

    /// Turn the landed cut into a frame over the whole new picture. A cut that
    /// was refused leaves the old size, so the recorded result never matches
    /// and nothing moves. The three locks described the rectangle that is now
    /// gone, so they are released with it.
    function settleAppliedCrop() {
        if (!view.pendingCropResult) return false
        if (view.documentWidth !== view.pendingCropResult.width
                || view.documentHeight !== view.pendingCropResult.height) return false
        view.pendingCropResult = null
        view.releaseCropLocks()
        view.setCropRect(0, 0, view.documentWidth, view.documentHeight)
        return true
    }

    /// A drag on the empty canvas builds a rectangle from the press to the
    /// pointer. With a ratio chosen, the shape is fitted to that ratio before
    /// it is clamped to the document, so a square drag draws a square.
    function dragCropCreate(startHostX, startHostY, hostX, hostY) {
        if (!view.documentReady) return
        var documentWidth = view.documentWidth
        var documentHeight = view.documentHeight
        var startX = view.hostToDocX(startHostX)
        var startY = view.hostToDocY(startHostY)
        var endX = view.hostToDocX(hostX)
        var endY = view.hostToDocY(hostY)
        if (!view.cropGrow()) {
            startX = Math.max(0, Math.min(documentWidth, startX))
            startY = Math.max(0, Math.min(documentHeight, startY))
            endX = Math.max(0, Math.min(documentWidth, endX))
            endY = Math.max(0, Math.min(documentHeight, endY))
        }
        var width = Math.max(1, Math.abs(endX - startX))
        var height = Math.max(1, Math.abs(endY - startY))
        var aspect = view.cropRatioAspect()
        if (aspect > 0) {
            if (width / height > aspect) width = height * aspect
            else height = width / aspect
            if (view.cropGrow()) {
                // The canvas can grow, so only the protocol's own size ceiling
                // constrains a ratio-locked create-drag.
                var cap = Math.min(1, 20000 / width, 20000 / height)
                width *= cap
                height *= cap
            } else {
                var maxWidth = endX >= startX ? documentWidth - startX : startX
                var maxHeight = endY >= startY ? documentHeight - startY : startY
                var scale = Math.min(1, maxWidth / width, maxHeight / height)
                width *= scale
                height *= scale
            }
        }
        var x = endX >= startX ? startX : startX - width
        var y = endY >= startY ? startY : startY - height
        view.setCropRect(x, y, width, height)
    }

    /// The quad is drawn on the source picture. A transform draft is the
    /// straightened result and fills the canvas, so the corners would describe
    /// pixels that are no longer on screen — the same reason the crop frame
    /// hides while its draft is shown.
    readonly property bool transformFrameShown:
        view.tool === "transform" && view.documentReady
        && view.previewDraft === null
        && view.transformCorners && view.transformCorners.length === 4

    readonly property bool cropFrameShown:
        view.tool === "crop" && view.documentReady
        // A crop draft replaces the canvas with the cut result, so the
        // rectangle would describe pixels that are no longer on screen. The
        // frame is the source's rectangle; the draft is the answer. One at a
        // time, and the toggle is the way between them.
        && view.previewDraft === null
        && view.cropRect.width > 0 && view.cropRect.height > 0

    /// The eight frame handles. `column`/`row` are the same 0/1/2 edge
    /// coordinates the anchor pad uses: 0 is the left or top side, 2 the right
    /// or bottom, 1 the middle of that axis, which moves nothing.
    readonly property var cropHandles: [
        { key: "top_left", column: 0, row: 0 },
        { key: "top", column: 1, row: 0 },
        { key: "top_right", column: 2, row: 0 },
        { key: "left", column: 0, row: 1 },
        { key: "right", column: 2, row: 1 },
        { key: "bottom_left", column: 0, row: 2 },
        { key: "bottom", column: 1, row: 2 },
        { key: "bottom_right", column: 2, row: 2 }
    ]

    /// Write the four fields from a rectangle in document pixels, rounded and
    /// clamped so it always describes a legal, at-least-one-pixel crop. In
    /// `grow` mode the rectangle may reach outside the picture on every side,
    /// so only the 1 px overlap with the picture is enforced there.
    function setCropRect(x, y, width, height) {
        var grow = view.cropGrow()
        var maxWidth = grow ? 20000 : view.documentWidth
        var maxHeight = grow ? 20000 : view.documentHeight
        width = Math.max(1, Math.min(maxWidth, Math.round(width)))
        height = Math.max(1, Math.min(maxHeight, Math.round(height)))
        if (grow) {
            x = Math.min(view.documentWidth - 1,
                         Math.max(1 - width, Math.round(x)))
            y = Math.min(view.documentHeight - 1,
                         Math.max(1 - height, Math.round(y)))
        } else {
            x = Math.max(0, Math.min(view.documentWidth - width, Math.round(x)))
            y = Math.max(0, Math.min(view.documentHeight - height, Math.round(y)))
        }
        cropX.text = String(x)
        cropY.text = String(y)
        cropWidthField.text = String(width)
        cropHeightField.text = String(height)
        // Mirror the pair in the preset dropdown without re-applying it.
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    /// Drag one frame handle. The side the handle owns follows the pointer and
    /// the opposite side stays put, so a corner drag never also moves the
    /// rectangle. With a ratio chosen, a corner keeps the opposite corner fixed
    /// and a side keeps the opposite side fixed while the other axis grows
    /// around the rectangle's centre — the shape is never broken by a drag.
    function dragCropHandle(column, row, hostX, hostY) {
        if (!view.cropFrameShown) return
        if (!view.cropResizable) return
        var rect = view.cropRect
        var documentWidth = view.documentWidth
        var documentHeight = view.documentHeight
        var grow = view.cropGrow()
        var x = rect.x
        var y = rect.y
        var width = rect.width
        var height = rect.height
        var pointerX = view.hostToDocX(hostX)
        var pointerY = view.hostToDocY(hostY)
        if (!grow) {
            pointerX = Math.max(0, Math.min(documentWidth, pointerX))
            pointerY = Math.max(0, Math.min(documentHeight, pointerY))
        }
        // One locked axis leaves the other handle free: a left/right side is
        // pinned with Width, and a top/bottom side is pinned with Height. The
        // corners follow whichever axis is still free.
        if (view.cropLockWidth || view.cropLockHeight) {
            if (view.cropLockWidth) {
                if (row === 1) return
                if (row === 0) {
                    var top = grow
                            ? Math.min(y + height - 1, pointerY)
                            : Math.max(0, Math.min(y + height - 1, pointerY))
                    height = y + height - top
                    y = top
                } else {
                    var bottom = grow
                            ? Math.max(y + 1, pointerY)
                            : Math.max(y + 1, Math.min(documentHeight, pointerY))
                    height = bottom - y
                }
            } else {
                if (column === 1) return
                if (column === 0) {
                    var left = grow
                            ? Math.min(x + width - 1, pointerX)
                            : Math.max(0, Math.min(x + width - 1, pointerX))
                    width = x + width - left
                    x = left
                } else {
                    var right = grow
                            ? Math.max(x + 1, pointerX)
                            : Math.max(x + 1, Math.min(documentWidth, pointerX))
                    width = right - x
                }
            }
            view.setCropRect(x, y, width, height)
            if (view.cropRatio !== "free") {
                view.setCropRatioFromPair(parseInt(cropWidthField.text),
                                          parseInt(cropHeightField.text))
            }
            return
        }
        var aspect = view.cropRatioAspect()
        // A growing rectangle has no picture edge to stop at; only the
        // protocol's own ceiling constrains it.
        var sideLimit = 20000

        if (aspect > 0) {
            if (column !== 1 && row !== 1) {
                // Corner: the opposite corner is the anchor.
                var fixedX = column === 0 ? x + width : x
                var fixedY = row === 0 ? y + height : y
                var rawWidth = Math.max(1, Math.abs(pointerX - fixedX))
                var rawHeight = Math.max(1, Math.abs(pointerY - fixedY))
                if (rawWidth / rawHeight > aspect) rawWidth = rawHeight * aspect
                else rawHeight = rawWidth / aspect
                var limitWidth = grow
                        ? sideLimit
                        : (column === 0 ? fixedX : documentWidth - fixedX)
                var limitHeight = grow
                        ? sideLimit
                        : (row === 0 ? fixedY : documentHeight - fixedY)
                var scale = Math.min(1, limitWidth / rawWidth, limitHeight / rawHeight)
                width = Math.max(1, Math.round(rawWidth * scale))
                height = Math.max(1, Math.round(rawHeight * scale))
                x = column === 0 ? Math.round(fixedX - width) : Math.round(fixedX)
                y = row === 0 ? Math.round(fixedY - height) : Math.round(fixedY)
            } else if (column !== 1) {
                // Left or right side: the opposite side stays, the height grows
                // around the rectangle's vertical centre.
                var fixedXSide = column === 0 ? x + width : x
                var centreY = y + height / 2
                var edgeWidth = Math.max(1, Math.abs(pointerX - fixedXSide))
                var edgeHeight = edgeWidth / aspect
                var edgeLimitWidth = grow
                        ? sideLimit
                        : (column === 0 ? fixedXSide : documentWidth - fixedXSide)
                var edgeScale = Math.min(1, edgeLimitWidth / edgeWidth,
                                         (grow ? sideLimit : documentHeight) / edgeHeight)
                width = Math.max(1, Math.round(edgeWidth * edgeScale))
                height = Math.max(1, Math.round(edgeHeight * edgeScale))
                x = column === 0 ? Math.round(fixedXSide - width) : Math.round(fixedXSide)
                y = grow
                        ? Math.round(centreY - height / 2)
                        : Math.round(Math.max(0, Math.min(documentHeight - height,
                                                            centreY - height / 2)))
            } else {
                // Top or bottom side: the opposite side stays, the width grows
                // around the rectangle's horizontal centre.
                var fixedYSide = row === 0 ? y + height : y
                var centreX = x + width / 2
                var edgeHeightSide = Math.max(1, Math.abs(pointerY - fixedYSide))
                var edgeWidthSide = edgeHeightSide * aspect
                var edgeLimitHeight = grow
                        ? sideLimit
                        : (row === 0 ? fixedYSide : documentHeight - fixedYSide)
                var edgeScaleSide = Math.min(1, edgeLimitHeight / edgeHeightSide,
                                             (grow ? sideLimit : documentWidth) / edgeWidthSide)
                height = Math.max(1, Math.round(edgeHeightSide * edgeScaleSide))
                width = Math.max(1, Math.round(edgeWidthSide * edgeScaleSide))
                y = row === 0 ? Math.round(fixedYSide - height) : Math.round(fixedYSide)
                x = grow
                        ? Math.round(centreX - width / 2)
                        : Math.round(Math.max(0, Math.min(documentWidth - width,
                                                            centreX - width / 2)))
            }
            view.setCropRect(x, y, width, height)
            return
        }

        if (column === 0) {
            var left = grow
                    ? Math.min(x + width - 1, pointerX)
                    : Math.max(0, Math.min(x + width - 1, pointerX))
            width = x + width - left
            x = left
        } else if (column === 2) {
            var right = grow
                    ? Math.max(x + 1, pointerX)
                    : Math.max(x + 1, Math.min(documentWidth, pointerX))
            width = right - x
        }
        if (row === 0) {
            var top = grow
                    ? Math.min(y + height - 1, pointerY)
                    : Math.max(0, Math.min(y + height - 1, pointerY))
            height = y + height - top
            y = top
        } else if (row === 2) {
            var bottom = grow
                    ? Math.max(y + 1, pointerY)
                    : Math.max(y + 1, Math.min(documentHeight, pointerY))
            height = bottom - y
        }
        view.setCropRect(x, y, width, height)
    }

    /// Ask Core to render the selected tool's draft without applying it. The
    /// debounce keeps a typed width from spawning a render per key: the previous
    /// draft stays on screen until the newest one lands. Crop no longer has a
    /// draft: its panel is the rectangle, and the canvas draws that rectangle
    /// directly. Transform still previews the straightened frame before Apply.
    function requestDraft() {
        draftDebounce.stop()
        if (!view.hasDocument) return
        if (view.tool === "transform" && view.transformLivePreview
                && view.transformUsable() && view.transformChanged()) {
            view.command({
                type: "editor_transform_preview",
                corners: view.transformCorners
            })
        }
    }

    /// Raised by the empty state and the toolbar's open button; Main owns the
    /// file chooser so the portal/fallback path stays in one place.
    signal requestOpen()
    /// Raised by Save as…: Main owns the chooser, and the chosen path becomes an
    /// `editor_save_as` command. `view.saveAsPath` carries the suggestion.
    signal requestSaveAs()
    /// Raised by Export's Browse button: Main owns the file chooser.
    signal requestExportPath()
    signal command(var command)

    readonly property var editor: state.editor || null
    /// The steps applied in this session, oldest first; Core publishes them as
    /// labels and still owns undo/redo. The pointer inspector draws the list.
    readonly property var history: editor ? (editor.history || []) : []
    readonly property bool hasDocument: !!(editor && editor.width > 0)
    /// True while the canvas draws the first, reduced decode of an image whose
    /// full frame is still decoding: the picture and its size are already the
    /// document's, the pixels an edit needs are not there yet.
    readonly property bool opening: !!(editor && editor.opening)
    /// Whether the tools may act. Opening counts as a document for drawing and
    /// for the footer, but not for editing: Core has no pixels to work on, so a
    /// click would only earn a `no_editor_document` toast.
    readonly property bool documentReady: hasDocument && !opening
    readonly property bool rendering: !!(editor && editor.rendering)
    readonly property bool modified: !!(editor && editor.modified)
    /// True while the pixels are already on disk at the save path.
    readonly property bool saved: !!(editor && editor.saved)
    /// True while a save is being encoded and written on a worker. Core owns the
    /// flag and publishes it with the document, so the buttons come back when
    /// the write really finished — or failed, with the status line saying why.
    readonly property bool saving: !!(editor && editor.saving)
    /// What the save dialog should suggest: the save path, with the extension
    /// swapped for the format the document is in.
    readonly property string saveAsPath: {
        if (!hasDocument) return ""
        var current = editor.savePath || editor.path || ""
        var dot = current.lastIndexOf(".")
        var base = dot > current.lastIndexOf("/") ? current.slice(0, dot) : current
        return base + (editor.format || ".png")
    }

    /// Where Export would write. Empty until the dialog opens, then the same
    /// suggestion `Save as` uses: a delivery copy starts beside the document.
    property string exportPath: ""
    /// Quality for the lossy encoders. JPEG is the only lossy one here; a
    /// lossless target (PNG, WebP, …) ignores it rather than pretending.
    property int exportQuality: 90
    /// Keep the source's EXIF/XMP/ICC segments. Only JPEG→JPEG can carry them.
    property bool exportMetadata: true
    /// The delivery size: the copy's longer side in pixels, or 0 for the
    /// document's own size. It scales the whole frame — Core never crops an
    /// export — and a limit above the picture's own long edge writes it as it
    /// is rather than upscaling it.
    property int exportLongEdge: 0
    readonly property var exportEdges: [0, 3840, 2560, 1920, 1280, 800]

    /// The preset list's labels. The long edge is the whole promise, so the
    /// dialog does not predict the other side: that is Core's arithmetic.
    function exportEdgeLabel(edge) {
        return edge > 0 ? qsTr("%1 px long edge").arg(edge) : qsTr("Original size")
    }

    /// Pick a delivery size by its index in `exportEdges`. The ComboBox's
    /// `onActivated` calls this, and so does a test: the visible list and the
    /// property behind it must not be able to disagree.
    function chooseExportSize(index) {
        if (index < 0 || index >= view.exportEdges.length) return
        view.exportLongEdge = view.exportEdges[index]
        // The row and the property are the same choice: a preset set from
        // anywhere but the combo box must still show the row it selected.
        if (exportSizeCombo.currentIndex !== index) exportSizeCombo.currentIndex = index
    }
    readonly property bool exportTargetIsJpeg:
        /\.jpe?g$/i.test(view.exportPath)
    readonly property bool exportTargetIsLossy: view.exportTargetIsJpeg
    readonly property bool exportPathValid:
        /\.(png|jpe?g|jpe|jfif|webp|tiff|tif|gif|bmp|tga|qoi)$/i.test(view.exportPath)
    readonly property bool exportKeepsMetadata:
        view.exportMetadata && view.exportTargetIsJpeg
            && /\.jpe?g$/i.test(view.editor ? view.editor.path : "")

    /// Open the Export dialog on a suggested name: the document's file with
    /// `-export` before the extension, so the copy cannot land on the source.
    function openExportDialog() {
        if (!view.hasDocument) return
        var base = view.saveAsPath || (view.editor ? view.editor.path : "")
        var dot = base.lastIndexOf(".")
        view.exportPath = dot > base.lastIndexOf("/")
                ? base.substring(0, dot) + "-export" + base.substring(dot)
                : base + "-export"
        view.exportQuality = 90
        view.exportMetadata = true
        // Every open starts at the document's own size: a delivery copy that
        // silently shrank would be a surprise, and the choice is one click away.
        view.chooseExportSize(0)
        exportDialog.open()
    }

    /// The chooser's answer. Kept apart from `openExportDialog` so a Browse and
    /// a typed path are the same field.
    function applyExportPath(path) {
        if (path) view.exportPath = path
    }

    function confirmExport() {
        if (!view.exportPathValid) return
        view.command({
            type: "editor_export",
            path: view.exportPath,
            quality: view.exportQuality,
            metadata: view.exportKeepsMetadata,
            max_edge: view.exportLongEdge
        })
        exportDialog.close()
    }

    /// True while the pointer rests on the canvas. The pan handler arms itself
    /// on it, so a drag that starts on a sidebar does not move the picture.
    property bool panHover: false

    // ------------------------------------------------ presentation transform
    // Exactly the Viewer's model: Core knows nothing about it and it survives
    // no command. 100 % means one document pixel per screen pixel, so the
    // 2048 px preview texture costs sharpness at high zoom but never changes
    // what the percentage means. `autoFit` keeps the picture fitted while the
    // document's own size changes (rotate, crop, resize) and is dropped the
    // moment the user chooses a zoom.
    property real zoom: 1
    property real offsetX: 0
    property real offsetY: 0
    property bool autoFit: true
    /// False until the canvas host exists; the document's size handlers fire
    /// while the view is still being constructed.
    property bool hostReady: false
    /// Where the last wheel landed, in canvas-host coordinates. Read by the
    /// debug build's `KOGAVIEW_DEV_EDITOR_WHEEL` hook to prove the handler — not
    /// a stand-in for it — received the event; nothing in the UI reads it.
    property real lastWheelX: -1
    property real lastWheelY: -1

    readonly property string documentPath: editor ? (editor.path || "") : ""
    readonly property real documentWidth: hasDocument ? editor.width : 0
    readonly property real documentHeight: hasDocument ? editor.height : 0

    /// The live-preview draft the canvas should be showing, if any. It is
    /// presentation gating on purpose: Core keeps the draft until an edit lands
    /// or the document changes, and leaving the tool must hide it again without
    /// another command. The draft's own `kind` is checked as well, so a switch
    /// from Crop to Transform cannot paint the crop result for a frame. A resize
    /// draft is not here at all: nothing in the window asks for one.
    readonly property var previewDraft: {
        if (!editor || !editor.previewDraft) return null
        var draft = editor.previewDraft
        if (tool === "transform" && transformLivePreview
                && draft.kind === "transform") return draft
        return null
    }
    /// True while the Resize dialog is up. It is the Editor's own modal, not one
    /// the shell owns, so the canvas handlers read it directly: Qt delivers
    /// pointer-handler events to items under a popup overlay, and a wheel or a
    /// drag behind a modal form would move a picture the user cannot see.
    readonly property bool resizeDialogOpen: resizeDialog.visible

    /// Open Resize's dialog. Resize is a question about the document, not a
    /// canvas mode, so any armed tool is put down first: a crop frame left
    /// underneath a modal form would be dragged by the same pointer events the
    /// dialog is meant to own.
    function openResizeDialog() {
        if (!view.documentReady) return
        view.tool = "pointer"
        resizeDialog.open()
    }
    /// What the canvas draws: the draft's target size while an edit is being
    /// previewed, the document's own size otherwise.
    readonly property real displayedWidth: previewDraft ? previewDraft.width : documentWidth
    readonly property real displayedHeight: previewDraft ? previewDraft.height : documentHeight

    // The document is drawn by a scaled `Image`, so a point in document pixels
    // sits `x * zoom` from the picture's visual corner. `Image.scale` grows
    // around the item's centre, so the origin is the item's own x plus half the
    // shrink/grow the scale caused. These three functions are the only place
    // the conversion lives: the transform quad and the crop frame both use
    // them, and neither can drift from the picture.
    readonly property real canvasOriginX:
        canvas.x + canvas.width / 2 * (1 - canvas.scale)
    readonly property real canvasOriginY:
        canvas.y + canvas.height / 2 * (1 - canvas.scale)
    function docToHostX(value) { return view.canvasOriginX + value * view.zoom }
    function docToHostY(value) { return view.canvasOriginY + value * view.zoom }
    function hostToDocX(value) { return view.zoom > 0 ? (value - view.canvasOriginX) / view.zoom : 0 }
    function hostToDocY(value) { return view.zoom > 0 ? (value - view.canvasOriginY) / view.zoom : 0 }

    function sizeLabel() {
        if (!hasDocument) return "—"
        return editor.width + " × " + editor.height
    }

    readonly property int zoomPercent: Math.round(view.zoom * 100)

    function setZoom(value) {
        view.zoom = Math.max(0.02, Math.min(16, value));
        view.autoFit = false;
        view.clampOffsets();
    }

    /// How far a corner of the picture may travel past the canvas edge before
    /// the clamp stops it: enough to clear the canvas, no more. With this
    /// margin a picture smaller than the viewport can still be dragged aside
    /// (the user asked for a pan that does not depend on the picture being
    /// larger than the window), and one larger than the viewport keeps a few
    /// pixels of context instead of ending flush at its edge.
    readonly property real panMargin: 64

    /// Keep the picture reachable rather than pinned.
    ///
    /// A picture wider than the canvas may be dragged until its far edge meets
    /// the canvas edge plus [`panMargin`]; one narrower than the canvas may be
    /// dragged until it is almost off the canvas, which is what makes a pan
    /// feel free instead of snapping back to the centre. The previous rule
    /// pinned each axis that did not overflow to 0, so a 2400 × 1600 photo in a
    /// 786 × 736 host could be panned left and right but not up and down.
    function clampOffsets() {
        if (!hostReady) return
        var shownX = displayedWidth * view.zoom
        var shownY = displayedHeight * view.zoom
        var maxX = Math.max(0, (shownX - canvasHost.width) / 2) + view.panMargin
        var maxY = Math.max(0, (shownY - canvasHost.height) / 2) + view.panMargin
        view.offsetX = Math.max(-maxX, Math.min(maxX, view.offsetX))
        view.offsetY = Math.max(-maxY, Math.min(maxY, view.offsetY))
    }

    function fit() {
        if (!hasDocument || !hostReady || canvasHost.width <= 0 || canvasHost.height <= 0) {
            return
        }
        var pad = 32
        view.zoom = Math.max(0.02, Math.min(16,
            Math.min((canvasHost.width - pad) / displayedWidth,
                     (canvasHost.height - pad) / displayedHeight)))
        view.offsetX = 0
        view.offsetY = 0
        view.autoFit = true
    }

    /// Fit the document to the canvas and *stay* fitted: the host resize
    /// handler below keeps it whole while the window is dragged.
    function refitOrClamp() {
        if (view.autoFit) view.fit()
        else view.clampOffsets()
    }

    function actualSize() {
        if (!hasDocument) return
        view.offsetX = 0
        view.offsetY = 0
        view.setZoom(1)
    }

    function zoomIn() {
        view.setZoom(view.zoom * 1.25)
    }

    function zoomOut() {
        view.setZoom(view.zoom / 1.25)
    }

    /// Zoom with the document point under the cursor nailed to the cursor.
    /// `pointX`/`pointY` are in canvas-host coordinates.
    function zoomAt(factor, pointX, pointY) {
        if (!hasDocument) return
        var previous = view.zoom > 0 ? view.zoom : 1
        var next = Math.max(0.02, Math.min(16, previous * factor))
        if (Math.abs(next - previous) < 0.000001) {
            return
        }
        var centerX = canvasHost.width / 2 + view.offsetX
        var centerY = canvasHost.height / 2 + view.offsetY
        var shift = 1 - next / previous
        view.offsetX += (pointX - centerX) * shift
        view.offsetY += (pointY - centerY) * shift
        view.zoom = next
        view.autoFit = false
        view.clampOffsets()
    }

    /// Double-click: fitted <-> actual size.
    function toggleZoom() {
        if (!hasDocument) return
        if (view.autoFit) {
            view.actualSize()
        } else {
            view.fit()
        }
    }

    onDocumentPathChanged: {
        view.autoFit = true
        view.zoom = 1
        view.offsetX = 0
        view.offsetY = 0
        // A different document is not the result of the crop that was pending.
        view.pendingCropResult = null
        if (view.hostReady) {
            view.fit()
        }
    }

    // An edit that changes the drawn size — a resize or crop landing, or a
    // live-preview draft appearing — keeps a fitted view fitted and leaves a
    // hand-chosen zoom alone (only re-clamping it to the new edges).
    onDisplayedWidthChanged: view.refitOrClamp()
    onDisplayedHeightChanged: view.refitOrClamp()
    // A tool switch keeps one live preview per tool. Arming Transform starts
    // from the document's own frame, so opening the tool never carries a quad
    // from a document that is no longer there. Arming Crop puts the rectangle
    // down: the user draws one, clicks the picture, or types a size — a crop
    // tool does not guess which part of the picture is wanted.
    onToolChanged: {
        draftDebounce.restart()
        if (view.tool === "transform") view.resetTransformCorners()
        if (view.tool === "crop") view.enterCropTool()
    }
    onCropRatioChanged: view.syncCropRatioField()
    // The document changing size (another edit, a new file, an applied crop)
    // invalidates a quad expressed in its pixels, and makes the old crop
    // rectangle describe pixels that are gone. A frame that no longer fits is
    // pulled inside; with no frame there is nothing to pull, and the view stays
    // in the draw-new state. A state publish changes width and height in one
    // write but QML emits one signal at a time, so the refit waits one
    // event-loop turn: fitting from the width change alone would use the
    // previous height.
    onDocumentWidthChanged: {
        if (view.tool === "transform") view.resetTransformCorners()
        if (view.tool === "crop") cropFitDebounce.restart()
    }
    onDocumentHeightChanged: {
        if (view.tool === "transform") view.resetTransformCorners()
        if (view.tool === "crop") cropFitDebounce.restart()
    }

    Timer {
        id: cropFitDebounce
        interval: 0
        onTriggered: if (view.tool === "crop") view.refitCropAfterDocumentChange()
    }

    /// After another edit changed the document's size, a rectangle that no
    /// longer fits names pixels that are gone. Pull it inside in one move, so a
    /// chosen ratio is not broken side by side; a rectangle that still fits is
    /// left where the user put it. No frame means the draw-new state stays.
    function refitCropAfterDocumentChange() {
        // A landed cut is not a rectangle to pull inside: the frame covers the
        // whole result.
        if (view.settleAppliedCrop()) return
        if (!view.documentReady || !view.cropHasRect()) return
        if (view.cropFieldsValid()) return
        var rect = view.cropRect
        var pair = view.clampCropPair(rect.width, rect.height,
                                      view.cropRatio !== "free")
        view.setCropRect(Math.max(0, Math.min(rect.x, view.documentWidth - pair.width)),
                         Math.max(0, Math.min(rect.y, view.documentHeight - pair.height)),
                         pair.width, pair.height)
        if (view.cropRatio !== "free") view.applyCropRatio()
    }

    /// The debounce behind the live preview: typing a width must not render the
    /// whole document on every key.
    Timer {
        id: draftDebounce
        interval: 200
        onTriggered: view.requestDraft()
    }

    /// The pointer inspector's preview comes from the same cache the browser's
    /// grid uses, so it is a fast, small image rather than a second decode of
    /// the full preview.
    ThumbnailBook {
        id: thumbs
        cache: view.thumbnails
    }

    // ------------------------------------------------------------ editor menu
    // The long label serves as the width probe: a regression that cuts labels
    // shows up as "Crop to selection…" losing its ellipsis.
    Menu {
        id: contextMenu
        implicitWidth: view.theme.menuWidth(view.theme.menuLabelWidths,
                                            view.theme.menuShortcutWidths)

        MenuItem {
            text: view.theme.menuEntries[24]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_rotate", degrees: -90 })
        }
        MenuItem {
            text: view.theme.menuEntries[25]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_rotate", degrees: 90 })
        }
        MenuItem {
            text: view.theme.menuEntries[26]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_flip", axis: "horizontal" })
        }
        MenuItem {
            text: view.theme.menuEntries[27]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_flip", axis: "vertical" })
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[28]
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
        MenuItem {
            text: view.theme.menuEntries[29]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_close" })
        }
    }

    // ------------------------------------------------------ editor workspace
    property Component toolbar: Component {
        RowLayout {
            spacing: 2

            ToolbarButton {
                objectName: "editorOpenButton"
                theme: view.theme
                icon.name: "document-open-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Open an image for editing")
                onClicked: view.requestOpen()
            }
            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }
            ToolbarButton {
                objectName: "editorZoomOut"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom out")
                onClicked: view.zoomOut()
            }
            Label {
                objectName: "editorZoomLabel"
                visible: view.hasDocument && !view.miniToolbar
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 48
                text: view.zoomPercent + " %"
                color: view.theme.text
                font.pixelSize: 12
            }
            ToolbarButton {
                objectName: "editorZoomIn"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom in")
                onClicked: view.zoomIn()
            }
            ToolbarButton {
                objectName: "editorFit"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Fit to window")
                onClicked: view.fit()
            }
            ToolbarButton {
                objectName: "editorActualSize"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "zoom-original-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Actual size (100%)")
                onClicked: view.actualSize()
            }
            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }
            ToolbarButton {
                objectName: "editorToolbarSave"
                theme: view.theme
                icon.name: "document-save-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady && !view.saved && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save (Ctrl+S)")
                onClicked: view.command({ type: "editor_save" })
            }
            ToolbarButton {
                objectName: "editorToolbarSaveAs"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "document-save-as-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save as… (Ctrl+Shift+S)")
                onClicked: view.requestSaveAs()
            }
            ToolbarButton {
                objectName: "editorToolbarExport"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "document-send-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Export a copy…")
                onClicked: view.openExportDialog()
            }
            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }
            ToolbarButton {
                objectName: "undoButton"
                theme: view.theme
                icon.name: "edit-undo-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!(view.editor && view.editor.canUndo)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Undo")
                onClicked: view.command({ type: "editor_undo" })
            }
            ToolbarButton {
                objectName: "redoButton"
                theme: view.theme
                icon.name: "edit-redo-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!(view.editor && view.editor.canRedo)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Redo")
                onClicked: view.command({ type: "editor_redo" })
            }
            ToolbarButton {
                objectName: "resetButton"
                theme: view.theme
                visible: !view.miniToolbar
                icon.name: "document-revert-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.modified
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Reset to original")
                onClicked: view.command({ type: "editor_reset" })
            }
            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }
            ToolbarButton {
                objectName: "editorBack"
                theme: view.theme
                icon.name: "go-previous-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Back to browser")
                onClicked: view.command({ type: "set_workspace", workspace: "browser" })
            }
            ToolbarSeparator {
                theme: view.theme
                visible: !view.miniToolbar
            }
            ToolbarButton {
                objectName: "editorClose"
                theme: view.theme
                icon.name: "window-close-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[29]
                onClicked: view.command({ type: "editor_close" })
            }
            ToolbarButton {
                objectName: "editorOverflowButton"
                theme: view.theme
                visible: view.miniToolbar
                icon.name: "view-more-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("More editor actions")
                onClicked: editorOverflow.popup(this)
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // -------------------------------------------------------- tools (left)
        // Every action that changes the picture, plus the two tools whose
        // options the right column shows. The history list is gone: Core still
        // keeps the steps for undo, but a list of past edits is not a tool. The
        // toolbar no longer repeats these actions, so an edit has one home.
        Rectangle {
            objectName: "editorTools"
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            // Tab gives the picture the whole window, as Krita's canvas-only
            // mode does; the side panels and their splitters are the only
            // things this view owns, so the toolbar stays.
            visible: !view.panelsHidden

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Label {
                    objectName: "editsHeading"
                    text: qsTr("Tools")
                    color: view.theme.text
                    font.bold: true
                }

                // The pointer is the no-op tool: it selects nothing, so Core
                // never sees a command from it. It is the tool the Editor
                // opens on, and clicking the selected Resize/Crop again
                // returns to it.
                Button {
                    objectName: "toolPointer"
                    Layout.fillWidth: true
                    text: qsTr("Pointer")
                    highlighted: view.tool === "pointer"
                    focusPolicy: Qt.NoFocus
                    onClicked: view.tool = "pointer"
                }
                // Resize is not a mode: it opens a dialog, and the dialog's own
                // buttons are the way out. The button stays lit while the form
                // is up so the palette says where the question came from.
                Button {
                    objectName: "toolResize"
                    Layout.fillWidth: true
                    text: qsTr("Resize…")
                    highlighted: view.resizeDialogOpen
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    onClicked: view.openResizeDialog()
                }
                Button {
                    objectName: "toolCrop"
                    Layout.fillWidth: true
                    text: qsTr("Crop")
                    highlighted: view.tool === "crop"
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    onClicked: view.tool = view.tool === "crop" ? "pointer" : "crop"
                }
                Button {
                    objectName: "toolTransform"
                    Layout.fillWidth: true
                    text: qsTr("Transform")
                    highlighted: view.tool === "transform"
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Drag the corners onto the picture's edges to straighten it")
                    onClicked: view.tool = view.tool === "transform" ? "pointer" : "transform"
                }
                // Krita's freehand brush and eraser are one paint engine with
                // two modes, so they sit side by side and B/E pick them.
                Button {
                    objectName: "toolBrush"
                    Layout.fillWidth: true
                    text: qsTr("Brush")
                    highlighted: view.tool === "paint" && view.paintMode === "brush"
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Paint freehand (B)")
                    onClicked: {
                        view.selectPaintMode("brush")
                        view.forceActiveFocus()
                    }
                }
                Button {
                    objectName: "toolEraser"
                    Layout.fillWidth: true
                    text: qsTr("Eraser")
                    highlighted: view.tool === "paint" && view.paintMode === "eraser"
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Erase with the brush (E)")
                    onClicked: {
                        view.selectPaintMode("eraser")
                        view.forceActiveFocus()
                    }
                }

                MenuSeparator {}

                // These change pixels the moment they are pressed, so they are
                // actions rather than tools. Undo, Redo and Reset live on the
                // toolbar; the palette keeps the tools and the quick edits.
                Button {
                    objectName: "editsRotateLeft"
                    Layout.fillWidth: true
                    text: qsTr("Rotate left")
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    onClicked: view.command({ type: "editor_rotate", degrees: -90 })
                }
                Button {
                    objectName: "editsRotateRight"
                    Layout.fillWidth: true
                    text: qsTr("Rotate right")
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    onClicked: view.command({ type: "editor_rotate", degrees: 90 })
                }
                Button {
                    objectName: "editsFlipHorizontal"
                    Layout.fillWidth: true
                    text: qsTr("Flip horizontal")
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    onClicked: view.command({ type: "editor_flip", axis: "horizontal" })
                }
                Button {
                    objectName: "editsFlipVertical"
                    Layout.fillWidth: true
                    text: qsTr("Flip vertical")
                    enabled: view.documentReady
                    focusPolicy: Qt.NoFocus
                    onClicked: view.command({ type: "editor_flip", axis: "vertical" })
                }

                Item { Layout.fillHeight: true }
            }
        }

        PanelSplitter {
            objectName: "editorLeftSplitter"
            theme: view.theme
            Layout.fillHeight: true
            value: view.leftPanelWidth
            minimum: 160
            maximum: 360
            visible: !view.panelsHidden
            onMoved: function(width) { view.leftPanelWidth = width }
        }

        // ------------------------------------------------------------- canvas
        Rectangle {
            id: canvasHost
            objectName: "editorCanvasHost"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            color: view.theme.thumb
            // Resizing the window (or the sidebar) resizes the canvas, not the
            // document: a fitted document must refit, a hand-zoomed one only
            // re-clamp. This is what kept a fitted picture at its old scale
            // after the window grew or shrank.
            onWidthChanged: view.refitOrClamp()
            onHeightChanged: view.refitOrClamp()

            Image {
                id: canvas
                objectName: "canvas"
                width: Math.max(1, view.displayedWidth)
                height: Math.max(1, view.displayedHeight)
                scale: view.zoom
                x: (canvasHost.width - width) / 2 + view.offsetX
                y: (canvasHost.height - height) / 2 + view.offsetY
                // The preview is already encoded at the document aspect ratio;
                // the item is the document coordinate system and its scale is
                // purely presentation state.
                fillMode: Image.Stretch
                asynchronous: false
                cache: false
                source: view.previewDraft
                        ? "file://" + view.previewDraft.path
                        : (view.editor && view.editor.previewPath
                           ? "file://" + view.editor.previewPath
                           : "")
                opacity: view.rendering ? 0.65 : 1.0
                Behavior on opacity {
                    NumberAnimation { duration: 120 }
                }
            }

            WheelHandler {
                objectName: "editorWheelHandler"
                acceptedDevices: PointerDevice.AllDevices
                // A modal form owns the pointer while it is up: pointer-handler
                // delivery still reaches handlers under a popup overlay, and a
                // wheel behind the form would zoom a picture the user is not
                // looking at.
                enabled: !view.resizeDialogOpen
                onWheel: function(event) {
                    if (!view.hasDocument) return;
                    var factor = 1;
                    if (event.angleDelta.y !== 0) {
                        factor = Math.pow(1.0015, event.angleDelta.y);
                    } else if (event.pixelDelta.y !== 0) {
                        factor = Math.pow(1.01, event.pixelDelta.y);
                    } else {
                        return;
                    }
                    factor = Math.max(0.5, Math.min(2, factor));
                    view.lastWheelX = event.x;
                    view.lastWheelY = event.y;
                    view.zoomAt(factor, event.x, event.y);
                    event.accepted = true;
                }
            }

            DragHandler {
                id: editorPan
                objectName: "editorPanHandler"
                target: null
                // Arm on the picture only: a drag that begins on a sidebar or
                // a scroll view must keep scrolling. While Crop or Transform
                // is armed the left button belongs to the overlay's own
                // handles and the frame, and while Paint is armed it belongs
                // to the brush; the middle button still pans in all three
                // cases. Holding Space hands Paint's left button back to the
                // pan, the way Krita does. The Resize dialog is modal, so no
                // button pans behind it.
                enabled: view.panHover && !view.resizeDialogOpen
                acceptedDevices: PointerDevice.AllDevices
                acceptedButtons: (view.tool === "crop" || view.tool === "transform"
                                  || (view.tool === "paint" && !view.spacePanning))
                                 ? Qt.MiddleButton
                                 : (Qt.LeftButton | Qt.MiddleButton)
                property real startX: 0
                property real startY: 0

                onActiveChanged: {
                    if (active) {
                        startX = view.offsetX;
                        startY = view.offsetY;
                    }
                }
                onTranslationChanged: {
                    view.offsetX = startX + translation.x;
                    view.offsetY = startY + translation.y;
                    view.clampOffsets();
                }
            }

            HoverHandler {
                id: canvasHover
                onHoveredChanged: view.panHover = hovered
            }

            // A middle-click drag pans as well, the way every viewer does it.
            TapHandler {
                acceptedButtons: Qt.LeftButton
                enabled: !view.resizeDialogOpen
                onDoubleTapped: view.toggleZoom()
            }

            // Only the picture is clickable, so a click on the empty canvas
            // margin does not look like it did nothing.
            MouseArea {
                id: canvasArea
                anchors.fill: canvas
                acceptedButtons: Qt.RightButton
                enabled: view.documentReady
                onClicked: function(mouse) {
                    contextMenu.popup(canvasArea, mouse.x, mouse.y)
                }
            }

            // ---------------------------------------------------- overlays
            // Both frames are drawn in canvas-host coordinates from document
            // pixels, so they follow the picture through zoom, pan and a
            // window resize without a second coordinate model. They are
            // presentation only: a drag writes the rectangle or the quad, and
            // only Apply sends a command.
            Item {
                id: canvasOverlay
                objectName: "canvasOverlay"
                anchors.fill: parent
                z: 2

                // ---------------------------------------------- crop frame
                Item {
                    id: cropOverlay
                    objectName: "cropOverlay"
                    anchors.fill: parent
                    // Same gate as the frame: while the crop draft is on the
                    // canvas, dragging would read the result's coordinates as
                    // if they were the source's, and a new rectangle would be
                    // placed inside the preview instead of the picture.
                    visible: view.tool === "crop" && view.documentReady
                             && view.previewDraft === null
                    enabled: visible

                    // The picture outside the rectangle is dimmed, the way a
                    // crop tool shows what is about to be discarded. It covers
                    // the picture only (not the matte), and every edge is
                    // computed from the same document rectangle the frame and
                    // the command read, so they cannot disagree.
                    Item {
                        id: cropShade
                        objectName: "cropShade"
                        anchors.fill: parent
                        visible: view.cropFrameShown
                        enabled: false
                        readonly property real pictureX: view.docToHostX(0)
                        readonly property real pictureY: view.docToHostY(0)
                        readonly property real pictureWidth: view.displayedWidth * view.zoom
                        readonly property real pictureHeight: view.displayedHeight * view.zoom
                        readonly property real frameLeft: view.docToHostX(view.cropRect.x)
                        readonly property real frameTop: view.docToHostY(view.cropRect.y)
                        readonly property real frameRight:
                            view.docToHostX(view.cropRect.x + view.cropRect.width)
                        readonly property real frameBottom:
                            view.docToHostY(view.cropRect.y + view.cropRect.height)

                        Rectangle {
                            objectName: "cropShadeTop"
                            x: cropShade.pictureX
                            y: cropShade.pictureY
                            width: cropShade.pictureWidth
                            height: Math.max(0, cropShade.frameTop - cropShade.pictureY)
                            color: "#000000"
                            opacity: 0.45
                        }
                        Rectangle {
                            objectName: "cropShadeBottom"
                            x: cropShade.pictureX
                            y: cropShade.frameBottom
                            width: cropShade.pictureWidth
                            height: Math.max(0, cropShade.pictureY
                                                + cropShade.pictureHeight
                                                - cropShade.frameBottom)
                            color: "#000000"
                            opacity: 0.45
                        }
                        Rectangle {
                            objectName: "cropShadeLeft"
                            x: cropShade.pictureX
                            y: cropShade.frameTop
                            width: Math.max(0, cropShade.frameLeft - cropShade.pictureX)
                            height: Math.max(0, cropShade.frameBottom - cropShade.frameTop)
                            color: "#000000"
                            opacity: 0.45
                        }
                        Rectangle {
                            objectName: "cropShadeRight"
                            x: cropShade.frameRight
                            y: cropShade.frameTop
                            width: Math.max(0, cropShade.pictureX
                                               + cropShade.pictureWidth
                                               - cropShade.frameRight)
                            height: Math.max(0, cropShade.frameBottom - cropShade.frameTop)
                            color: "#000000"
                            opacity: 0.45
                        }

                        // Grow: the part of the frame that is not the picture,
                        // painted with the colour the new margin will have. It
                        // is the fill's own preview, so a black border looks
                        // black before Apply and a transparent one reads as an
                        // empty strip rather than a solid swatch.
                        readonly property real growOpacity:
                            view.cropFill === "transparent" ? 0.5 : 0.9
                        readonly property real innerTop:
                            Math.max(cropShade.frameTop, cropShade.pictureY)
                        readonly property real innerBottom:
                            Math.min(cropShade.frameBottom,
                                     cropShade.pictureY + cropShade.pictureHeight)
                        readonly property real innerLeft:
                            Math.max(cropShade.frameLeft, cropShade.pictureX)
                        readonly property real innerRight:
                            Math.min(cropShade.frameRight,
                                     cropShade.pictureX + cropShade.pictureWidth)

                        Rectangle {
                            objectName: "cropGrowTop"
                            visible: view.cropGrow()
                            x: cropShade.frameLeft
                            y: cropShade.frameTop
                            width: Math.max(0, cropShade.frameRight - cropShade.frameLeft)
                            height: Math.max(0, Math.min(cropShade.frameBottom,
                                                        cropShade.pictureY)
                                                - cropShade.frameTop)
                            color: view.cropFillPreviewColor()
                            opacity: cropShade.growOpacity
                        }
                        Rectangle {
                            objectName: "cropGrowBottom"
                            visible: view.cropGrow()
                            x: cropShade.frameLeft
                            y: Math.max(cropShade.frameTop, cropShade.pictureY
                                                          + cropShade.pictureHeight)
                            width: Math.max(0, cropShade.frameRight - cropShade.frameLeft)
                            height: Math.max(0, cropShade.frameBottom
                                                - Math.max(cropShade.frameTop,
                                                           cropShade.pictureY
                                                           + cropShade.pictureHeight))
                            color: view.cropFillPreviewColor()
                            opacity: cropShade.growOpacity
                        }
                        Rectangle {
                            objectName: "cropGrowLeft"
                            visible: view.cropGrow()
                            x: cropShade.frameLeft
                            y: cropShade.innerTop
                            width: Math.max(0, cropShade.innerLeft - cropShade.frameLeft)
                            height: Math.max(0, cropShade.innerBottom - cropShade.innerTop)
                            color: view.cropFillPreviewColor()
                            opacity: cropShade.growOpacity
                        }
                        Rectangle {
                            objectName: "cropGrowRight"
                            visible: view.cropGrow()
                            x: cropShade.innerRight
                            y: cropShade.innerTop
                            width: Math.max(0, cropShade.frameRight - cropShade.innerRight)
                            height: Math.max(0, cropShade.innerBottom - cropShade.innerTop)
                            color: view.cropFillPreviewColor()
                            opacity: cropShade.growOpacity
                        }
                    }

                    // Drawing a new rectangle is the no-frame state: a drag
                    // builds one from the press to the pointer, a click (a
                    // press with no travel) asks for the whole picture. The
                    // frame itself is declared after this area, so once it
                    // exists a press inside it moves it; a press outside does
                    // nothing until Clear puts the frame down again.
                    MouseArea {
                        id: cropCreateArea
                        objectName: "cropCreateArea"
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.CrossCursor
                        enabled: !view.cropHasRect()
                        property real startHostX: 0
                        property real startHostY: 0
                        property bool dragging: false
                        property bool moved: false

                        onPressed: function(mouse) {
                            startHostX = mouse.x
                            startHostY = mouse.y
                            dragging = true
                            moved = false
                            // The new frame is a new answer; the locks that
                            // described the old one go with it.
                            view.releaseCropLocks()
                        }
                        onPositionChanged: function(mouse) {
                            if (!dragging) return
                            // A click is not a zero-size crop: four pixels of
                            // travel is what makes the gesture a drag.
                            if (!moved
                                    && Math.abs(mouse.x - startHostX) < 4
                                    && Math.abs(mouse.y - startHostY) < 4) return
                            moved = true
                            view.dragCropCreate(startHostX, startHostY,
                                                mouse.x, mouse.y)
                        }
                        onReleased: {
                            if (dragging && !moved) view.createFullCropFrame()
                            dragging = false
                        }
                    }

                    Rectangle {
                        id: cropFrame
                        objectName: "cropFrame"
                        visible: view.cropFrameShown
                        x: view.docToHostX(view.cropRect.x)
                        y: view.docToHostY(view.cropRect.y)
                        width: Math.max(1, view.cropRect.width * view.zoom)
                        height: Math.max(1, view.cropRect.height * view.zoom)
                        color: "transparent"
                        border.width: 1
                        border.color: view.theme.accent

                        // Rule-of-thirds guides: the composition aid every crop
                        // tool draws, in the same accent as the frame. Two
                        // verticals and two horizontals, not a dense grid, so
                        // the picture stays readable.
                        Rectangle {
                            objectName: "cropGridVertical1"
                            x: cropFrame.width / 3
                            y: 0
                            width: 1
                            height: cropFrame.height
                            color: view.theme.accent
                            opacity: 0.55
                        }
                        Rectangle {
                            objectName: "cropGridVertical2"
                            x: cropFrame.width * 2 / 3
                            y: 0
                            width: 1
                            height: cropFrame.height
                            color: view.theme.accent
                            opacity: 0.55
                        }
                        Rectangle {
                            objectName: "cropGridHorizontal1"
                            x: 0
                            y: cropFrame.height / 3
                            width: cropFrame.width
                            height: 1
                            color: view.theme.accent
                            opacity: 0.55
                        }
                        Rectangle {
                            objectName: "cropGridHorizontal2"
                            x: 0
                            y: cropFrame.height * 2 / 3
                            width: cropFrame.width
                            height: 1
                            color: view.theme.accent
                            opacity: 0.55
                        }

                        // The frame's inside moves the whole rectangle; the
                        // handles below own the sides and corners.
                        MouseArea {
                            id: cropMoveArea
                            objectName: "cropMoveArea"
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.SizeAllCursor
                            property real startHostX: 0
                            property real startHostY: 0
                            property real startDocX: 0
                            property real startDocY: 0

                            onPressed: function(mouse) {
                                var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                startHostX = point.x
                                startHostY = point.y
                                startDocX = view.cropRect.x
                                startDocY = view.cropRect.y
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed) return
                                var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                view.setCropRect(startDocX + (point.x - startHostX) / view.zoom,
                                                 startDocY + (point.y - startHostY) / view.zoom,
                                                 view.cropRect.width, view.cropRect.height)
                            }
                        }

                        // Eight handles: the four corners and the four edge
                        // midpoints. A corner moves both of its sides; an edge
                        // moves only the one side it owns.
                        Repeater {
                            model: view.cropHandles

                            Rectangle {
                                required property var modelData
                                objectName: "cropHandle_" + modelData.key
                                width: 12
                                height: 12
                                radius: 1
                                color: view.theme.accent
                                border.width: 1
                                border.color: view.theme.surface
                                x: cropFrame.width * modelData.column / 2 - width / 2
                                y: cropFrame.height * modelData.row / 2 - height / 2

                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton
                                    cursorShape: modelData.column === 1
                                                 ? Qt.SizeVerCursor
                                                 : (modelData.row === 1
                                                    ? Qt.SizeHorCursor
                                                    : (modelData.column === modelData.row
                                                       ? Qt.SizeFDiagCursor
                                                       : Qt.SizeBDiagCursor))
                                    onPositionChanged: function(mouse) {
                                        if (!pressed) return
                                        var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                        view.dragCropHandle(modelData.column, modelData.row,
                                                            point.x, point.y)
                                    }
                                }
                            }
                        }
                    }
                }

                // ------------------------------------------- transform quad
                // The four source corners, clockwise from the top left, plus
                // four edge handles that move the two corners of that edge.
                // The protocol carries the corners alone; the edges are a
                // QML affordance over the same array.
                Item {
                    id: transformOverlay
                    objectName: "transformOverlay"
                    anchors.fill: parent
                    visible: view.transformFrameShown
                    enabled: visible

                    // The quad's outline: one thin item per edge, from corner
                    // i to corner i + 1.
                    Repeater {
                        model: 4

                        Rectangle {
                            required property int index
                            x: view.docToHostX(view.cornerX(index))
                            y: view.docToHostY(view.cornerY(index))
                            width: Math.hypot(
                                view.docToHostX(view.cornerX((index + 1) % 4)) - x,
                                view.docToHostY(view.cornerY((index + 1) % 4)) - y)
                            height: 1
                            color: view.theme.accent
                            transformOrigin: Item.Left
                            rotation: Math.atan2(
                                view.docToHostY(view.cornerY((index + 1) % 4)) - y,
                                view.docToHostX(view.cornerX((index + 1) % 4)) - x)
                                * 180 / Math.PI
                        }
                    }

                    // Four corner handles.
                    Repeater {
                        model: 4

                        Rectangle {
                            required property int index
                            objectName: "transformCorner_" + index
                            width: 12
                            height: 12
                            radius: 2
                            color: view.theme.accent
                            border.width: 1
                            border.color: view.theme.surface
                            x: view.docToHostX(view.cornerX(index)) - width / 2
                            y: view.docToHostY(view.cornerY(index)) - height / 2

                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton
                                cursorShape: Qt.CrossCursor
                                onPositionChanged: function(mouse) {
                                    if (!pressed) return
                                    var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                    view.setTransformCorner(index, point.x, point.y)
                                }
                            }
                        }
                    }

                    // Four edge handles, at each edge's midpoint.
                    Repeater {
                        model: 4

                        Rectangle {
                            required property int index
                            objectName: "transformEdge_" + index
                            width: 10
                            height: 10
                            radius: 5
                            color: view.theme.surface
                            border.width: 2
                            border.color: view.theme.accent
                            x: view.docToHostX((view.cornerX(index)
                                                + view.cornerX((index + 1) % 4)) / 2) - width / 2
                            y: view.docToHostY((view.cornerY(index)
                                                + view.cornerY((index + 1) % 4)) / 2) - height / 2

                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton
                                cursorShape: Qt.SizeAllCursor
                                onPositionChanged: function(mouse) {
                                    if (!pressed) return
                                    var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                    view.moveTransformEdge(index, point.x, point.y)
                                }
                            }
                        }
                    }
                }

                // ------------------------------------------------ paint stroke
                // The stroke is drawn here while the button is down, in the
                // same host coordinates the picture uses, and the real pixels
                // are painted by Core when the button comes up. The overlay is
                // presentation only: cancelling it leaves the document alone.
                Item {
                    id: paintOverlay
                    objectName: "paintOverlay"
                    anchors.fill: parent
                    visible: view.tool === "paint" && view.documentReady
                             && view.previewDraft === null
                    enabled: visible && !view.spacePanning

                    Canvas {
                        id: strokePreview
                        objectName: "strokePreview"
                        anchors.fill: parent

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var points = view.paintStroke
                            if (!points || points.length === 0) return
                            ctx.globalAlpha = Math.max(0.05, view.paintOpacity / 100)
                            ctx.strokeStyle = view.paintMode === "eraser"
                                    ? view.theme.thumb : view.paintColor
                            ctx.fillStyle = ctx.strokeStyle
                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"
                            var radius = Math.max(0.5, view.paintSize * view.zoom / 2)
                            ctx.lineWidth = radius * 2
                            if (points.length === 1) {
                                ctx.beginPath()
                                ctx.arc(view.docToHostX(points[0][0]),
                                        view.docToHostY(points[0][1]), radius, 0, 2 * Math.PI)
                                ctx.fill()
                                return
                            }
                            ctx.beginPath()
                            ctx.moveTo(view.docToHostX(points[0][0]),
                                       view.docToHostY(points[0][1]))
                            for (var index = 1; index < points.length; ++index) {
                                ctx.lineTo(view.docToHostX(points[index][0]),
                                           view.docToHostY(points[index][1]))
                            }
                            ctx.stroke()
                        }
                    }

                    MouseArea {
                        id: paintArea
                        objectName: "paintArea"
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.CrossCursor
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            view.beginPaintStroke(mouse.x, mouse.y)
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed) return
                            view.extendPaintStroke(mouse.x, mouse.y)
                        }
                        onReleased: view.finishPaintStroke()
                        onCanceled: view.cancelPaintStroke()
                    }
                }
            }

            Component.onCompleted: {
                view.hostReady = true
                if (view.hasDocument) view.fit()
            }

            Column {
                anchors.centerIn: parent
                spacing: 6
                visible: !view.hasDocument

                BusyIndicator {
                    anchors.horizontalCenter: parent.horizontalCenter
                    running: visible
                    visible: !!view.editor && view.editor.width === 0
                }
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: view.editor && view.editor.width === 0
                          ? qsTr("Opening %1…").arg(view.editor.name)
                          : qsTr("No image open in the editor")
                    color: view.theme.textMuted
                }
                Button {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Open an image…")
                    objectName: "editorOpenButton"
                    onClicked: view.requestOpen()
                }
            }

            // The render spinner never covers the picture; it sits above it.
            BusyIndicator {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 12
                implicitWidth: 24
                implicitHeight: 24
                running: view.rendering
                visible: running
            }
        }

        PanelSplitter {
            objectName: "editorRightSplitter"
            theme: view.theme
            Layout.fillHeight: true
            value: view.rightPanelWidth
            direction: -1
            minimum: 220
            maximum: 400
            visible: !view.panelsHidden
            onMoved: function(width) { view.rightPanelWidth = width }
        }

        // -------------------------------------------------- tool options (right)
        // The options of the tool chosen on the left: a resize needs a new
        // size, a crop needs the rectangle's corner as well. Apply sends the
        // same typed command the palette does; Reset only clears the fields,
        // so a half-entered size never reaches Core. Saving lives on the
        // toolbar, where it is reachable from every tool.
        Rectangle {
            id: inspector
            objectName: "editorInspector"
            property int preferredWidth: view.rightPanelWidth
            property int minimumWidth: 220
            Layout.preferredWidth: view.rightPanelWidth
            Layout.fillHeight: true
            color: view.theme.surface
            visible: !view.panelsHidden

            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: inspector.width - 24
                    spacing: 10

                    // The heading names the tool whose column this is. With the
                    // pointer selected there is no tool, so the column becomes
                    // the document itself.
                    Label {
                        objectName: "toolOptionsHeading"
                        text: view.tool === "pointer"
                              ? qsTr("Pointer")
                              : (view.tool === "crop"
                                 ? qsTr("Crop")
                                 : (view.tool === "transform"
                                    ? qsTr("Transform")
                                    : (view.tool === "paint"
                                       ? (view.paintMode === "eraser" ? qsTr("Eraser") : qsTr("Brush"))
                                       : qsTr("Resize"))))
                        color: view.theme.text
                        font.bold: true
                    }

                    // ------------------------------- pointer: document details
                    // The pointer changes no pixels, so its column shows what
                    // the document is, what it looks like and what has been
                    // done to it in this session — never an Apply button.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: view.tool === "pointer"
                        spacing: 8

                        Label {
                            objectName: "imageHeading"
                            text: qsTr("Image")
                            color: view.theme.text
                            font.bold: true
                        }

                        Label {
                            Layout.fillWidth: true
                            objectName: "imageName"
                            text: view.hasDocument
                                  ? (view.editor.name + (view.modified ? " · " + qsTr("edited") : ""))
                                  : "—"
                            color: view.theme.text
                            elide: Text.ElideMiddle
                        }

                        Label {
                            Layout.fillWidth: true
                            objectName: "imageSize"
                            text: view.sizeLabel()
                            color: view.theme.textMuted
                        }

                        Label {
                            Layout.fillWidth: true
                            objectName: "saveTarget"
                            text: {
                                if (!view.hasDocument) return "—"
                                var where = view.editor.savePath || view.editor.path || ""
                                var name = where.split("/").pop()
                                var style = view.editor.format ? " (" + view.editor.format + ")" : ""
                                var state = view.saved ? qsTr("saved") : qsTr("unsaved changes")
                                return name + style + " · " + state
                            }
                            color: view.saved ? view.theme.textMuted : view.theme.accent
                            font.pixelSize: 11
                            elide: Text.ElideMiddle
                            wrapMode: Text.NoWrap
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            BusyIndicator {
                                Layout.preferredWidth: 18
                                Layout.preferredHeight: 18
                                running: view.saving
                                visible: running
                            }
                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Saving…")
                                visible: view.saving
                                color: view.theme.textMuted
                                font.pixelSize: 11
                            }
                        }

                        // The current preview through the grid's thumbnail
                        // cache, in the same frame the grid uses: a small
                        // cached decode that follows each edit.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(180, width * 0.72)
                            radius: view.theme.radius
                            color: view.theme.thumb
                            clip: true

                            CachedThumbnail {
                                objectName: "pointerThumbnail"
                                anchors.fill: parent
                                anchors.margins: 4
                                book: thumbs
                                // The current preview through the grid's own
                                // thumbnail cache: a small cached decode, and
                                // a new preview path after each edit refreshes
                                // it. The QML harness passes no cache and uses
                                // fake paths, so it draws the placeholder.
                                //
                                // The preview names repeat on every run
                                // (`preview-1.png` …), so the path alone cannot
                                // identify the pixels: `modified`/`fileSize`
                                // carry the file's identity, without which the
                                // cache answered a fresh preview with the
                                // thumbnail of the last run's document.
                                path: view.hasDocument && view.thumbnails
                                      ? (view.editor.previewPath || "") : ""
                                modified: view.editor ? (view.editor.previewModified || 0) : 0
                                fileSize: view.editor ? (view.editor.previewSize || 0) : 0
                                thumbnailable: view.hasDocument
                                fillMode: Image.PreserveAspectFit
                            }
                            Label {
                                anchors.centerIn: parent
                                visible: !view.hasDocument
                                text: qsTr("No image open")
                                color: view.theme.textMuted
                            }
                        }

                        Label {
                            text: qsTr("History")
                            color: view.theme.text
                            font.bold: true
                        }

                        ListView {
                            id: historyList
                            objectName: "historyList"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 220
                            Layout.minimumHeight: 120
                            clip: true
                            model: view.history
                            spacing: 2
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: 26
                                radius: view.theme.radius
                                color: "transparent"

                                Label {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    objectName: "historyLine" + index
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                    color: view.theme.text
                                    font.pixelSize: 12
                                    text: (index + 1) + ". " + uiLines.text(modelData, view.state.language)
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            visible: view.history.length === 0
                            text: view.hasDocument ? qsTr("No edits yet") : qsTr("No image open")
                            color: view.theme.textMuted
                            font.pixelSize: 11
                        }
                    }

                    // ------------------------------- paint: brush and eraser
                    // One engine, two modes. A stroke changes pixels only when
                    // the button comes up, so nothing here is an Apply; the
                    // fields are the brush's own properties, and the [ ] X D
                    // keys reach the same properties as the controls.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: view.tool === "paint"
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Button {
                                objectName: "paintBrushMode"
                                Layout.fillWidth: true
                                text: qsTr("Brush")
                                checkable: true
                                checked: view.paintMode === "brush"
                                enabled: view.documentReady
                                focusPolicy: Qt.NoFocus
                                onClicked: {
                                    view.selectPaintMode("brush")
                                    view.forceActiveFocus()
                                }
                            }
                            Button {
                                objectName: "paintEraserMode"
                                Layout.fillWidth: true
                                text: qsTr("Eraser")
                                checkable: true
                                checked: view.paintMode === "eraser"
                                enabled: view.documentReady
                                focusPolicy: Qt.NoFocus
                                onClicked: {
                                    view.selectPaintMode("eraser")
                                    view.forceActiveFocus()
                                }
                            }
                        }

                        // The colour row is the foreground swatch, its hex
                        // field, the background swatch X swaps with, and the
                        // swap button itself.
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Rectangle {
                                objectName: "paintSwatch"
                                implicitWidth: 22
                                implicitHeight: 22
                                radius: 3
                                color: view.paintColor
                                border.width: 1
                                border.color: view.theme.border
                            }

                            TextField {
                                id: paintColorField
                                objectName: "paintColorField"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: view.paintColor
                                placeholderText: qsTr("#rrggbb")
                                onEditingFinished: {
                                    view.setPaintColor(text)
                                    text = view.paintColor
                                    // Enter belongs to the field; the next key
                                    // should reach the canvas keys again.
                                    view.forceActiveFocus()
                                }
                            }

                            Rectangle {
                                objectName: "paintBackgroundSwatch"
                                implicitWidth: 22
                                implicitHeight: 22
                                radius: 3
                                color: view.paintBackgroundColor
                                border.width: 1
                                border.color: view.theme.border
                            }

                            Button {
                                objectName: "paintSwap"
                                implicitWidth: 30
                                text: qsTr("X")
                                enabled: view.documentReady
                                focusPolicy: Qt.NoFocus
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Swap the foreground and background colours (X)")
                                onClicked: {
                                    view.swapPaintColors()
                                    view.forceActiveFocus()
                                }
                            }
                        }

                        // The field and the swatch follow X and D even after
                        // the field has been typed into, which breaks its
                        // initial binding.
                        Connections {
                            target: view
                            function onPaintColorChanged() {
                                if (!paintColorField.activeFocus)
                                    paintColorField.text = view.paintColor
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 8
                            columnSpacing: 4
                            rowSpacing: 4

                            Repeater {
                                model: view.paintSwatches

                                Rectangle {
                                    required property string modelData
                                    objectName: "paintSwatch_" + modelData.substring(1)
                                    Layout.preferredWidth: 22
                                    Layout.preferredHeight: 22
                                    radius: 3
                                    color: modelData
                                    border.width: view.paintColor === modelData ? 2 : 1
                                    border.color: view.paintColor === modelData
                                                  ? view.theme.accent : view.theme.border

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            view.setPaintColor(modelData)
                                            view.forceActiveFocus()
                                        }
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Label {
                                text: qsTr("Brush size")
                                color: view.theme.textMuted
                            }
                            Slider {
                                id: paintSizeSlider
                                objectName: "paintSize"
                                Layout.fillWidth: true
                                from: view.minimumPaintSize
                                to: view.maximumPaintSize
                                stepSize: 1
                                value: view.paintSize
                                enabled: view.documentReady
                                onMoved: view.paintSize = Math.round(value)
                            }
                            Label {
                                objectName: "paintSizeValue"
                                text: qsTr("%1 px").arg(Math.round(view.paintSize))
                                color: view.theme.text
                                font.pixelSize: 12
                                Layout.preferredWidth: 52
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Label {
                                text: qsTr("Opacity")
                                color: view.theme.textMuted
                            }
                            Slider {
                                id: paintOpacitySlider
                                objectName: "paintOpacity"
                                Layout.fillWidth: true
                                from: 1
                                to: 100
                                stepSize: 1
                                value: view.paintOpacity
                                enabled: view.documentReady
                                onMoved: view.paintOpacity = Math.round(value)
                            }
                            Label {
                                objectName: "paintOpacityValue"
                                text: qsTr("%1 %").arg(Math.round(view.paintOpacity))
                                color: view.theme.text
                                font.pixelSize: 12
                                Layout.preferredWidth: 52
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Drag on the picture to paint. [ and ] change the size, X swaps colours, D resets them, Space pans.")
                            color: view.theme.textMuted
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ------------------------------- crop/transform: tool options
                    // Crop's rectangle is the user's answer: four numbers, a
                    // shape and a place. Width, Height and Ratio each carry a
                    // lock; the locks decide which of the three is an input and
                    // which is derived from the other two. Resize is a dialog
                    // of its own, because a size is a decision, not a mode.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: view.tool === "crop" || view.tool === "transform"
                        spacing: 10

                        GridLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            columns: 3
                            columnSpacing: 6
                            rowSpacing: 4

                            Label {
                                text: qsTr("X")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropX
                                objectName: "cropX"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator {
                                    bottom: view.cropGrow() ? -20000 : 0
                                    top: 20000
                                }
                            }
                            // A place has no lock: the locks are about the
                            // shape, not about where it sits.
                            Item {}

                            Label {
                                text: qsTr("Y")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropY
                                objectName: "cropY"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator {
                                    bottom: view.cropGrow() ? -20000 : 0
                                    top: 20000
                                }
                            }
                            Item {}

                            Label {
                                text: qsTr("Width")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropWidthField
                                objectName: "cropWidth"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                placeholderText: view.hasDocument ? String(view.editor.width) : "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 1; top: 20000 }
                                enabled: view.cropWidthEditable
                                onTextEdited: view.linkHeightFromWidth()
                            }
                            CropLockButton {
                                id: cropLockWidthButton
                                objectName: "cropLockWidth"
                                checked: view.cropLockWidth
                                enabled: view.documentReady
                                Accessible.name: qsTr("Lock width")
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Lock width")
                                onToggled: view.setCropLock("width", checked)
                            }

                            Label {
                                text: qsTr("Height")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropHeightField
                                objectName: "cropHeight"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                placeholderText: view.hasDocument ? String(view.editor.height) : "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 1; top: 20000 }
                                enabled: view.cropHeightEditable
                                onTextEdited: view.linkWidthFromHeight()
                            }
                            CropLockButton {
                                id: cropHeightButton
                                objectName: "cropLockHeight"
                                checked: view.cropLockHeight
                                enabled: view.documentReady
                                Accessible.name: qsTr("Lock height")
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Lock height")
                                onToggled: view.setCropLock("height", checked)
                            }

                            Label {
                                text: qsTr("Ratio")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropRatioField
                                objectName: "cropRatio"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                placeholderText: qsTr("Free")
                                enabled: view.cropRatioEditable
                                onTextEdited: view.applyCropRatioText()
                                onEditingFinished: view.setCropRatio(cropRatioField.text)
                            }
                            CropLockButton {
                                id: cropRatioButton
                                objectName: "cropLockRatio"
                                checked: view.cropLockRatio
                                enabled: view.documentReady
                                Accessible.name: qsTr("Lock ratio")
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Lock ratio")
                                onToggled: view.setCropLock("ratio", checked)
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            visible: view.tool === "crop"
                            color: view.theme.border
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            spacing: 8

                            Label {
                                text: qsTr("Crop mode")
                                color: view.theme.textMuted
                            }
                            ComboBox {
                                id: cropModeBox
                                objectName: "cropMode"
                                Layout.fillWidth: true
                                model: view.cropModes
                                textRole: "label"
                                currentIndex: view.cropModeIndex()
                                onActivated: view.setCropMode(view.cropModes[currentIndex].key)
                            }
                        }

                        // A growing crop needs a colour for the new margin.
                        // Only shown in Grow: in Center there is no leftover to
                        // paint, and an unused control would ask a question the
                        // user cannot answer.
                        RowLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "crop" && view.cropGrow()
                            spacing: 8

                            Label {
                                text: qsTr("Grow fill color")
                                color: view.theme.textMuted
                            }
                            ComboBox {
                                id: cropFillBox
                                objectName: "cropBackground"
                                Layout.fillWidth: true
                                model: view.cropBackdrops
                                textRole: "label"
                                currentIndex: view.cropFillIndex()
                                onActivated: view.chooseCropFill(currentIndex)
                            }
                            Rectangle {
                                objectName: "cropBackgroundSwatch"
                                Layout.preferredWidth: 24
                                Layout.preferredHeight: 24
                                radius: 4
                                color: view.cropFillPreviewColor()
                                border.width: 1
                                border.color: view.theme.border
                                Label {
                                    anchors.centerIn: parent
                                    visible: view.cropFill === "transparent"
                                    text: "0"
                                    color: view.theme.textMuted
                                    font.pixelSize: 10
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            visible: view.tool === "crop"
                            color: view.theme.border
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            spacing: 2

                            Label {
                                text: qsTr("Size preset")
                                color: view.theme.textMuted
                            }
                            ComboBox {
                                id: cropPreset
                                objectName: "cropPreset"
                                Layout.fillWidth: true
                                // This model is filtered by the document, so it
                                // changes when a document arrives; an
                                // `onCurrentIndexChanged` handler would apply
                                // its first row then. Only a real pick counts.
                                currentIndex: -1
                                model: view.cropPresets
                                textRole: "label"
                                displayText: currentIndex < 0 ? qsTr("Custom") : currentText
                                onActivated: view.chooseCropPreset(currentIndex)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            spacing: 8

                            Label {
                                text: qsTr("Anchor")
                                color: view.theme.textMuted
                            }
                            Grid {
                                objectName: "cropAnchorPad"
                                columns: 3
                                columnSpacing: 2
                                rowSpacing: 2

                                Repeater {
                                    // The arrow points at the corner or edge
                                    // of the document the rectangle keeps.
                                    model: view.cropAnchors

                                    Button {
                                        required property var modelData
                                        objectName: "cropAnchor_" + modelData.key
                                        width: 24
                                        height: 24
                                        text: modelData.glyph
                                        font.pixelSize: 12
                                        // The glyph alone in a 24 px square
                                        // needs the button padding removed.
                                        padding: 0
                                        highlighted: view.cropAnchor === modelData.key
                                        enabled: view.documentReady
                                        onClicked: view.setCropAnchor(modelData.key)
                                        Accessible.name: modelData.label
                                        ToolTip.visible: hovered
                                        ToolTip.text: modelData.label
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            visible: view.tool === "crop"
                            color: view.theme.border
                        }

                        // Transform: the quad is the command, so there is
                        // nothing to type. The four corners and four edges on
                        // the canvas are the only controls; the panel names
                        // what they do and offers the two buttons that matter.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "transform"
                            spacing: 6

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Drag a corner, or an edge, onto the picture's own corner to straighten it.")
                                color: view.theme.textMuted
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }

                            Label {
                                Layout.fillWidth: true
                                objectName: "transformSizeHint"
                                text: qsTr("The result keeps the document's size.")
                                color: view.theme.textMuted
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }

                            Label {
                                Layout.fillWidth: true
                                visible: view.tool === "transform"
                                         && view.previewDraft !== null
                                text: qsTr("Turn Live preview off to move the corners on the picture.")
                                color: view.theme.textMuted
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                objectName: "transformLivePreviewButton"
                                Layout.fillWidth: true
                                enabled: view.documentReady
                                text: qsTr("Live preview")
                                checkable: true
                                checked: view.transformLivePreview
                                highlighted: checked
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Show the straightened image before applying it")
                                onToggled: {
                                    view.transformLivePreview = checked
                                    draftDebounce.restart()
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Button {
                                objectName: "applyCrop"
                                text: qsTr("Apply crop (Enter)")
                                Layout.fillWidth: true
                                visible: view.tool === "crop"
                                focusPolicy: Qt.NoFocus
                                enabled: view.cropCanApply()
                                onClicked: view.applyCrop()
                            }
                            Button {
                                objectName: "resetCropOptions"
                                text: qsTr("Reset")
                                visible: view.tool === "crop"
                                focusPolicy: Qt.NoFocus
                                enabled: view.documentReady
                                onClicked: view.resetCropOptions()
                            }
                            Button {
                                objectName: "clearCrop"
                                text: qsTr("Clear")
                                visible: view.tool === "crop"
                                focusPolicy: Qt.NoFocus
                                enabled: view.documentReady
                                onClicked: view.clearCropFrame()
                            }
                            Button {
                                objectName: "applyTransform"
                                text: qsTr("Apply")
                                Layout.fillWidth: true
                                visible: view.tool === "transform"
                                focusPolicy: Qt.NoFocus
                                enabled: view.transformUsable() && view.transformChanged()
                                onClicked: {
                                    view.command({
                                        type: "editor_transform",
                                        corners: view.transformCorners
                                    })
                                    view.transformLivePreview = false
                                    view.resetTransformCorners()
                                }
                            }
                            Button {
                                objectName: "resetTransformFields"
                                text: qsTr("Reset")
                                visible: view.tool === "transform"
                                focusPolicy: Qt.NoFocus
                                enabled: view.documentReady
                                onClicked: view.resetTransformCorners()
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }
        }
    }

    /// Resize is a dialog, not a tool: choosing a size is a question with a
    /// beginning and an end, so the form owns its own fields while the document
    /// under it stays untouched. The palette button opens it; nothing on the
    /// canvas changes mode, and the form draws no preview — the picture does
    /// not move until Apply.
    ResizeDialog {
        id: resizeDialog
        objectName: "resizeDialog"
        theme: view.theme
        documentWidth: view.documentWidth
        documentHeight: view.documentHeight
        documentReady: view.documentReady
        presets: view.sizePresets
        onResizeRequested: function(width, height, fill, fillAlpha, filter) {
            view.command({
                type: "editor_resize",
                width: width,
                height: height,
                fill: fill,
                fill_alpha: fillAlpha,
                filter: filter
            })
        }
    }

    /// The colour chooser for a grown crop border. A cancelled chooser leaves
    /// the previous choice selected rather than pretending a colour was picked.
    ColorDialog {
        id: cropFillColorDialog
        objectName: "cropFillColorDialog"
        title: qsTr("Border color")
        selectedColor: view.cropFillColor
        onAccepted: {
            view.cropFillColor = selectedColor
            view.cropFill = "custom"
            cropFillBox.currentIndex = view.cropFillIndex()
            draftDebounce.restart()
        }
        onRejected: cropFillBox.currentIndex = view.cropFillIndex()
    }

    /// The actions the mini toolbar cannot show. Same actions, labels and keys
    /// as the toolbar buttons it replaces; see `Viewer.qml` for why the labels
    /// come from `Theme.menuEntries`.
    Menu {
        id: editorOverflow
        objectName: "editorOverflowMenu"
        implicitWidth: view.theme.menuWidth(view.theme.menuLabelWidths,
                                            view.theme.menuShortcutWidths)

        MenuItem {
            text: view.theme.menuEntries[32]
            icon.name: "zoom-out-symbolic"
            enabled: view.documentReady
            onTriggered: view.zoomOut()
            MenuShortcut { text: "-" }
        }
        MenuItem {
            text: view.theme.menuEntries[31]
            icon.name: "zoom-in-symbolic"
            enabled: view.documentReady
            onTriggered: view.zoomIn()
            MenuShortcut { text: "+" }
        }
        MenuItem {
            text: view.theme.menuEntries[22]
            icon.name: "zoom-fit-best-symbolic"
            enabled: view.documentReady
            onTriggered: view.fit()
        }
        MenuItem {
            text: view.theme.menuEntries[23]
            icon.name: "zoom-original-symbolic"
            enabled: view.documentReady
            onTriggered: view.actualSize()
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[36]
            icon.name: "document-save-as-symbolic"
            enabled: view.documentReady && !view.saving
            onTriggered: view.requestSaveAs()
            MenuShortcut { text: "Ctrl+Shift+S" }
        }
        MenuItem {
            text: view.theme.menuEntries[37]
            icon.name: "document-send-symbolic"
            enabled: view.documentReady && !view.saving
            onTriggered: view.openExportDialog()
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[38]
            icon.name: "document-revert-symbolic"
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
    }

    /// Export is a delivery copy: it never moves the document's save target.
    /// The options are the ones ADR 0004 deferred — a JPEG quality and the
    /// source's metadata — and the dialog says which target honours them.
    Dialog {
        id: exportDialog
        objectName: "exportDialog"
        title: qsTr("Export image")
        modal: true
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 460
        padding: 12

        contentItem: ColumnLayout {
            spacing: 10

            Label {
                text: qsTr("File")
                color: view.theme.textMuted
                font.pixelSize: 12
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                TextField {
                    id: exportPathField
                    objectName: "exportPathField"
                    Layout.fillWidth: true
                    text: view.exportPath
                    placeholderText: qsTr("Choose where the copy goes")
                    onTextEdited: view.exportPath = text
                }

                Button {
                    objectName: "exportBrowse"
                    text: qsTr("Browse…")
                    onClicked: view.requestExportPath()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Label {
                    text: qsTr("Quality")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                }

                Slider {
                    id: exportQualitySlider
                    objectName: "exportQuality"
                    Layout.fillWidth: true
                    from: 10
                    to: 100
                    stepSize: 1
                    value: view.exportQuality
                    enabled: view.exportTargetIsLossy
                    onMoved: view.exportQuality = Math.round(value)
                }

                Label {
                    objectName: "exportQualityValue"
                    text: String(Math.round(exportQualitySlider.value))
                    color: view.theme.text
                    font.pixelSize: 12
                    Layout.preferredWidth: 32
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Label {
                    // Not the bare "Size": the browser's column header owns that
                    // word, and the catalogue gives one translation per English
                    // string. This row is about the copy's output.
                    text: qsTr("Output size")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                }

                ComboBox {
                    id: exportSizeCombo
                    objectName: "exportSize"
                    Layout.fillWidth: true
                    model: view.exportEdges.length
                    // `currentIndex` is set in `openExportDialog`, never bound:
                    // ComboBox owns the index once the user picks a row, and a
                    // binding would be broken by that first pick.
                    onActivated: view.chooseExportSize(index)
                    delegate: ItemDelegate {
                        required property int index
                        width: exportSizeCombo.width
                        text: view.exportEdgeLabel(view.exportEdges[index])
                        highlighted: exportSizeCombo.highlightedIndex === index
                    }
                    contentItem: Label {
                        leftPadding: 8
                        text: view.exportEdgeLabel(view.exportEdges[exportSizeCombo.currentIndex])
                        color: view.theme.text
                        font.pixelSize: 12
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            CheckBox {
                id: exportMetadataBox
                objectName: "exportMetadata"
                text: qsTr("Keep the source metadata (JPEG only)")
                checked: view.exportMetadata
                enabled: view.exportTargetIsJpeg
                onToggled: view.exportMetadata = checked
            }

            Label {
                Layout.fillWidth: true
                text: {
                    var hint = view.exportTargetIsLossy
                        ? qsTr("Quality applies to JPEG. Other formats are written losslessly.")
                        : qsTr("This format is written losslessly; the quality slider does not apply.")
                    if (view.exportLongEdge > 0 && view.exportKeepsMetadata) {
                        hint += "\n" + qsTr("A resized copy keeps the colour profile but drops EXIF, which would still name the old size.")
                    }
                    return hint
                }
                color: view.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: qsTr("Cancel")
                    onClicked: exportDialog.close()
                }
                Button {
                    objectName: "exportConfirm"
                    text: qsTr("Export")
                    highlighted: true
                    enabled: view.exportPathValid
                    onClicked: view.confirmExport()
                }
            }
        }
    }
}
