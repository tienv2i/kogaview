import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Effects
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
    onVisibleChanged: {
        if (visible && view.autoFit && view.hasDocument && view.hostReady) {
            Qt.callLater(view.fit)
        }
    }

    property Theme theme: Theme {}
    /// The shared thumbnail cache (C++ `ThumbnailCache`). Null in the QML test
    /// harness, where the pointer frame stays empty instead of decoding a fake
    /// path.
    property var thumbnails: null
    /// The folder tree's listing for the left dock: C++ in the app, a stub in
    /// the QML suite.
    property var listFolders: function(path) { return { ok: false, folders: [] }; }
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
                    // On a checked button the background is the accent, so the
                    // padlock itself is drawn in the surface colour; an accent
                    // glyph on an accent chip is a square, not a lock.
                    var colour = lockButton.checked
                            ? "#ffffff" : lockButton.unlockedColor
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
                    ctx.fillStyle = lockButton.checked
                            ? lockButton.lockedColor : "#ffffff"
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
    /// The saved layout. The shell owns one copy for the three workspaces, so
    /// a width or a tab chosen here is the one the Browser opens with next
    /// time; the view reads it and reports every change through
    /// `layoutRequested`, never by writing it.
    property var layout: ({})
    readonly property var panels: view.layout.panels || ({})
    function panelShown(key) { return view.panels[key] !== false }
    readonly property bool quickAccessShown: view.panelShown("editor.quickAccess")
    readonly property bool explorerShown: view.panelShown("editor.explorer")
    readonly property bool leftDockShown: view.quickAccessShown || view.explorerShown
    /// The tool rail is a panel like any other: it can be put away from
    /// Settings › Appearance and comes back the same way.
    readonly property bool toolsShown: view.panelShown("editor.tools")

    /// The icon rail's shape: two columns, or one for a narrow window. It is a
    /// layout choice, so the rail's own toggle asks for it and the next launch
    /// opens the same way.
    readonly property int toolColumns: view.layout.editorToolColumns === 1 ? 1 : 2
    /// 8 px of margin on each side, a 34 px button per column, and the 4 px
    /// gap between two columns. Written as one sum so the rail and its
    /// buttons cannot disagree.
    readonly property int toolRailWidth:
        16 + toolColumns * 34 + (toolColumns - 1) * 4
    /// The pinned Crop action row shows Apply, Reset and Clear on one line only
    /// while their words fit. The sentences are translated, so the rule is the
    /// measured sum of the three labels plus the two 6 px gaps, not a dock
    /// width: the 260 px Vietnamese dock elided `Bỏ khung` to `Bỏ khu…`.
    readonly property bool cropActionsStack: tool === "crop"
                                             && applyCropButton.parent.width > 0
                                             && applyCropButton.parent.width
                                                  < (applyCropButton.implicitWidth
                                                     + resetCropButton.implicitWidth
                                                     + clearCropButton.implicitWidth
                                                     + 12)

    // Widths. The saved layout is the source; a drag keeps a local value while
    // the pointer is down and the shell saves the result once it comes up. A
    // splitter therefore writes one `set_layout`, not one per pixel, and a
    // width chosen in the Browser is the width the Editor opens at.
    property real leftPanelWidth: view.layout.leftWidth || 240
    property bool leftDragging: false
    Binding {
        target: view
        property: "leftPanelWidth"
        value: view.layout.leftWidth || 240
        when: !view.leftDragging
        restoreMode: Binding.RestoreNone
    }
    property real rightPanelWidth: view.layout.rightWidth || 300
    property bool rightDragging: false
    Binding {
        target: view
        property: "rightPanelWidth"
        value: view.layout.rightWidth || 300
        when: !view.rightDragging
        restoreMode: Binding.RestoreNone
    }
    /// What this dock draws: the Editor's own range, applied to the shared
    /// width so a Browser drag past it cannot make the tool column wider than
    /// its splitter allows.
    readonly property real dockWidth:
        Math.max(220, Math.min(400, rightPanelWidth))

    /// Which panels the dock shows. They are the saved layout's answer, edited
    /// in Settings › Appearance; a hidden panel keeps its page in the stack, so
    /// hiding one never renumbers the others.
    readonly property bool toolOptionsVisible: view.panelShown("editor.options")
    readonly property bool infoVisible: view.panelShown("editor.info")
    readonly property bool historyVisible: view.panelShown("editor.history")
    readonly property bool originalVisible: view.panelShown("editor.original")

    /// The reference dock's height once the user has dragged the divider; `0`
    /// is the default answer, "only as tall as the open page needs". It is
    /// remembered with the rest of the layout.
    property real referenceHeight: view.layout.editorReferenceHeight || 0
    property bool referenceDragging: false
    Binding {
        target: view
        property: "referenceHeight"
        value: view.layout.editorReferenceHeight || 0
        when: !view.referenceDragging
        restoreMode: Binding.RestoreNone
    }

    /// The open reference tab, from the saved layout. An unknown key reads as
    /// `info`, the same fallback `LayoutState::sanitized` writes.
    readonly property string rightTab: {
        var key = view.layout.editorReferenceTab || "info"
        return (key === "history" || key === "original") ? key : "info"
    }
    /// The tabs and the words they draw. `shown` is the panel checklist; a
    /// hidden tab keeps its page in the stack but draws no button. The labels
    /// are translated here, in `EditorView`'s context, so `PanelTabs.qml` keeps
    /// no string of its own.
    readonly property var rightTabEntries: [
        { key: "info", label: qsTr("Info"), icon: "icons/info.svg",
          shown: view.infoVisible },
        { key: "history", label: qsTr("History"), icon: "icons/history.svg",
          shown: view.historyVisible },
        { key: "original", label: qsTr("Original"), icon: "icons/original.svg",
          shown: view.originalVisible }
    ]
    /// How many reference tabs the panel checklist is showing.
    readonly property int shownReferenceCount:
        (view.infoVisible ? 1 : 0) + (view.historyVisible ? 1 : 0)
        + (view.originalVisible ? 1 : 0)
    /// The whole right dock. Hiding every panel hides the column; showing any
    /// one brings it back. There is no separate "show sidebar" switch.
    readonly property bool sidebarShown:
        view.toolOptionsVisible || view.shownReferenceCount > 0
    /// The `StackLayout` index for `rightTab`. An unknown or hidden key falls
    /// back to the first visible tab instead of leaving the pages without a
    /// current index.
    readonly property int rightTabIndex: {
        for (var index = 0; index < rightTabEntries.length; ++index) {
            if (rightTabEntries[index].key === rightTab
                && rightTabEntries[index].shown !== false) return index
        }
        for (var fallback = 0; fallback < rightTabEntries.length; ++fallback) {
            if (rightTabEntries[fallback].shown !== false) return fallback
        }
        return -1
    }
    /// The open reference page's own height, for a dock that fits its content.
    /// The pages are measured here because the view owns them and knows which
    /// one the stack is drawing.
    readonly property real referencePageHeight: {
        if (view.rightTab === "history" && view.historyVisible)
            return historyPage ? historyPage.implicitHeight : 0
        if (view.rightTab === "original" && view.originalVisible)
            return originalPage ? originalPage.implicitHeight : 0
        return infoPage ? infoPage.implicitHeight : 0
    }
    /// The first reference tab the checklist leaves visible once `hidden` is
    /// taken away. Hiding the open page needs the answer *after* the toggle,
    /// or the old firstShownTab would name the page being hidden.
    function firstShownTab(hidden) {
        if (view.infoVisible && hidden !== "info") return "info"
        if (view.historyVisible && hidden !== "history") return "history"
        if (view.originalVisible && hidden !== "original") return "original"
        return ""
    }
    /// One panel row was toggled in Settings › Appearance. The layout is
    /// Core's, so the view only says which key changed; hiding the page that is
    /// open names its replacement in the same patch, so the strip cannot say
    /// History while drawing Info.
    function setPanelVisible(key, visible) {
        var keys = ["quickAccess", "explorer", "tools", "options", "info",
                    "history", "original"]
        if (keys.indexOf(key) < 0) return
        var patch = { panels: {} }
        patch.panels["editor." + key] = visible
        var isReference = key === "info" || key === "history" || key === "original"
        if (!visible && isReference && view.rightTab === key) {
            // The page being closed names its replacement in the same patch,
            // so the strip never says one tab while drawing another.
            patch.editorReferenceTab = view.firstShownTab(key)
        } else if (visible && isReference) {
            // Showing a page that the saved tab was not naming opens it; a
            // still-hidden tab is not left as the strip's answer.
            var named = view.rightTab
            if (named !== key && !view.panelShown("editor." + named)) {
                patch.editorReferenceTab = key
            }
        }
        view.layoutRequested(patch)
    }
    /// The strip's tab click. A tab is a layout choice, so it is saved.
    function showRightTab(key) { view.layoutRequested({ editorReferenceTab: key }) }
    function setToolColumns(columns) {
        view.layoutRequested({ editorToolColumns: columns === 1 ? 1 : 2 })
    }
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
    /// While a free-shape frame is being created by typing one side, the other
    /// side follows the document's own aspect for every keystroke. Once the
    /// user types that side, it is theirs and stops following. A preset, a
    /// drag, a click or a ratio writes both sides and clears the flags.
    property bool cropHeightAuto: false
    property bool cropWidthAuto: false
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
    /// the Editor's background, so a picture can gain a margin without being
    /// resized first.
    property string cropMode: "center"
    /// How a grown border is painted is not this tool's question: the new
    /// canvas takes the Editor's own background (`backgroundColor` /
    /// `backgroundTransparent`), the same one a resize pads with. Only read in
    /// `grow` mode.
    /// How Transform reshapes the picture:
    /// - `free`: Free Transform — scale and reposition the image inside the
    ///   document's fixed `W × H` frame; uncovered canvas takes the Editor's
    ///   background (`backgroundColor` / `backgroundTransparent`).
    /// - `scale`: Scale Canvas — drag the bounding box to resize the document's
    ///   own `W × H` dimensions directly while keeping the current viewport zoom.
    property string transformMode: "free"
    /// The transform bounding box as four clockwise corners in document pixels
    /// (`[[x, y], [x+w, y], [x+w, y+h], [x, y+h]]`). Identity is the document's
    /// own frame.
    property var transformCorners: []

    /// Paint is one canvas tool with two modes, the way Krita's freehand brush
    /// and eraser are two tools over one paint engine: `brush` blends
    /// `foregroundColor` over the picture, `eraser` lowers alpha. One stroke is
    /// one `editor_paint_stroke` command, sent on release, so one undo removes
    /// it.
    property string paintMode: "brush"

    // ------------------------------------------------- foreground/background
    // One pair for the whole Editor, not the brush's private colours. The two
    // roles answer two questions, and every tool that has a colour reads the
    // role it needs:
    //
    // - **Foreground** — the colour of a mark placed *inside* the picture. The
    //   brush is the only tool that places one today.
    // - **Background** — the material of *new canvas*: resizing into a bigger
    //   frame, the border a grown crop adds, and later the corners an
    //   arbitrary-angle rotate would leave.
    //
    // Both are `#rrggbb`, which is both the typed command's bytes and the hex
    // field's own text, so a box and the field cannot disagree. The pair is
    // presentation state, like the zoom: it is not saved, and each launch
    // starts black over white.
    property string foregroundColor: "#000000"
    property string backgroundColor: "#ffffff"
    /// New canvas that is painted with nothing at all. It travels as any colour
    /// plus `fill_alpha: 0`, which is how the wire already says "clear", so the
    /// protocol needs no third state.
    property bool backgroundTransparent: false
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
        return view.tool === "paint" && view.documentReady && !view.spacePanning
    }

    /// The three bytes for a `#rrggbb` colour. Core carries RGB, not a QML
    /// colour, and an unreadable string is black rather than a crash.
    function colorBytes(text) {
        var match = /^#([0-9a-fA-F]{6})$/.exec(String(text))
        if (!match) return [0, 0, 0]
        return [parseInt(match[1].slice(0, 2), 16),
                parseInt(match[1].slice(2, 4), 16),
                parseInt(match[1].slice(4, 6), 16)]
    }

    /// The three bytes a stroke carries: the foreground and nothing else. A
    /// transparent foreground would be a second, invisible eraser, so the
    /// foreground role has no transparency — the eraser's own `erase` is how a
    /// mark is removed.
    function foregroundBytes() {
        return view.colorBytes(view.foregroundColor)
    }

    /// The three bytes new canvas is painted with. Transparent travels as the
    /// colour plus `fill_alpha: 0`, so this is the colour even when nothing is
    /// painted.
    function backgroundBytes() {
        return view.colorBytes(view.backgroundColor)
    }

    /// The alpha that goes with `backgroundBytes()`.
    function backgroundAlpha() {
        return view.backgroundTransparent ? 0 : 255
    }

    /// What a canvas strip drawn for new canvas shows: the background colour,
    /// or the matte when the background paints nothing (the strip is drawn at
    /// half opacity then, so it reads as an empty area rather than as a colour).
    function backgroundPreviewColor() {
        return view.backgroundTransparent ? view.theme.thumb : view.backgroundColor
    }

    /// Normalise a typed or picked colour to `#rrggbb`. An illegal value is
    /// ignored rather than sent, so the document never sees a colour the
    /// interface cannot show.
    function normalizedColor(value) {
        var text = String(value).trim()
        if (/^[0-9a-fA-F]{6}$/.test(text)) text = "#" + text
        if (!/^#[0-9a-fA-F]{6}$/.test(text)) return ""
        return text.toLowerCase()
    }

    function setForegroundColor(value) {
        var text = view.normalizedColor(value)
        if (text === "") return
        view.foregroundColor = text
    }

    /// A concrete background colour. Choosing one also leaves the transparent
    /// state: the list says "this colour", not "still nothing".
    function setBackgroundColor(value) {
        var text = view.normalizedColor(value)
        if (text === "") return
        view.backgroundColor = text
        view.backgroundTransparent = false
        view.backgroundChanged()
    }

    /// `Transparent` in the background list. The colour is remembered, so
    /// switching back to a colour returns to the one that was there.
    function setBackgroundTransparent(value) {
        view.backgroundTransparent = value === true
        view.backgroundChanged()
    }

    /// New canvas is previewed on the canvas, so a background change repaints
    /// the draft the way a typed side does.
    function backgroundChanged() {
        draftDebounce.restart()
    }

    /// A `ColorDialog` answers with a `color`, whose `toString()` carries an
    /// alpha byte (`#ff1e2d3c`) when the chooser leaves one set. The commands
    /// carry three bytes, so every colour is written as `#rrggbb` and no alpha
    /// ever reaches one.
    function colorText(color) {
        function byte(value) {
            var text = Math.round(value * 255).toString(16)
            return text.length < 2 ? "0" + text : text
        }
        return "#" + byte(color.r) + byte(color.g) + byte(color.b)
    }

    /// Krita's X, now Editor-wide: the two colours swap places. Transparency
    /// belongs to the background *role*, not to a colour, so a transparent
    /// background keeps its transparency and the colours trade sides — a swap
    /// can never make the foreground clear.
    function swapColours() {
        var previous = view.foregroundColor
        view.foregroundColor = view.backgroundColor
        view.backgroundColor = previous
        view.backgroundChanged()
    }

    /// Krita's D: black foreground, white background, nothing transparent.
    function resetColours() {
        view.foregroundColor = "#000000"
        view.backgroundColor = "#ffffff"
        view.backgroundTransparent = false
        view.backgroundChanged()
    }

    /// The foreground's chooser, opened from either pair. Seeded on the click:
    /// a `ColorDialog` writes `selectedColor` itself while the user drags,
    /// which ends the binding, so a pair that changed since (X, D or a typed
    /// hex) would otherwise reopen on the old colour.
    function openForegroundChooser() {
        foregroundColorDialog.selectedColor = view.foregroundColor
        foregroundColorDialog.open()
    }

    /// The background's list, opened under the swatch that was clicked. A
    /// `ColorDialog` cannot say "no colour", so the background has a popup of
    /// its own and `Custom color…` reaches the chooser from inside it.
    function openBackgroundPopup(anchor) {
        if (!anchor) return
        backgroundPopup.transparent = view.backgroundTransparent
        backgroundPopup.colour = view.backgroundColor
        backgroundPopup.showBelow(anchor)
    }

    /// The chooser behind `Custom color…` in the background list.
    function openBackgroundChooser() {
        backgroundColorDialog.selectedColor = view.backgroundColor
        backgroundColorDialog.open()
    }

    // Canvas backdrop colour (presentation-only: theme default, checkerboard,
    // white, black, gray, or a custom colour drawn across the viewport and
    // behind the document).
    property bool canvasBgUseTheme: true
    property bool canvasBgChecker: false
    property color canvasBgColor: "#ffffff"
    function openCanvasBgPopup(anchor) {
        if (!anchor) return
        canvasBgPopup.transparent = !view.canvasBgUseTheme && view.canvasBgChecker
        canvasBgPopup.colour = view.canvasBgColor
        canvasBgPopup.showBelow(anchor)
    }
    function openCanvasBgChooser() {
        canvasBgColorDialog.selectedColor = view.canvasBgColor
        canvasBgColorDialog.open()
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
            color: view.foregroundBytes(),
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
        if (!control && view.tool === "transform" && view.documentReady) {
            if (event.key === Qt.Key_Escape) {
                view.tool = "pointer"
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (view.transformUsable() && view.transformChanged()) view.applyTransform()
                event.accepted = true
                return
            }
        }
        if (!control && view.tool === "rotate" && view.documentReady) {
            if (event.key === Qt.Key_Escape) {
                view.tool = "pointer"
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (view.rotateHasChange()) view.applyRotateAngle()
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
        switch (event.key) {
        case Qt.Key_H:
            view.tool = "hand"
            event.accepted = true
            break
        case Qt.Key_X:
            view.swapColours()
            event.accepted = true
            break
        case Qt.Key_D:
            view.resetColours()
            event.accepted = true
            break
        case Qt.Key_Space:
            if (view.documentReady) {
                if (!event.isAutoRepeat) {
                    // Space interrupts a stroke rather than swallowing it: the
                    // stroke is finished as drawn, then the button pans.
                    view.finishPaintStroke()
                    view.spacePanning = true
                }
                event.accepted = true
            }
            break
        case Qt.Key_1:
            if (view.documentReady) {
                view.actualSize()
                event.accepted = true
            }
            break
        case Qt.Key_2:
            if (view.documentReady) {
                view.fit()
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
        }
    }
    Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
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

    /// The frame is the preview's input: a corner or an edge moving asks Core
    /// for the straightened result through the debounce a typed crop side uses,
    /// so a drag renders once per pause instead of once per pixel. The identity
    // ------------------------------------------- shared bounding-box helpers
    // Used by both Crop and Transform so keyboard modifiers behave identically:
    // - Shift: lock aspect ratio (or lock horizontal/vertical axis while moving)
    // - Alt:   resize symmetrically around the box centre
    // - Ctrl:  snap to document edges/centre or 10 px steps

    function snapDocCoord(value, maxDim, snapEnabled) {
        if (!snapEnabled) return value
        var threshold = Math.max(8, 10 / Math.max(0.05, view.zoom))
        var guides = [0, maxDim / 2, maxDim]
        for (var i = 0; i < guides.length; ++i) {
            if (Math.abs(value - guides[i]) <= threshold) return guides[i]
        }
        return Math.round(value / 10) * 10
    }

    function computeBoxHandleDrag(startRect, column, row, pointerX, pointerY, options) {
        var opts = options || ({})
        var clampToDoc = !!opts.clampToDoc
        var maxDim = opts.maxDim || 16384
        var fromCenter = !!opts.fromCenter
        var keepAspect = !!opts.keepAspect
        var aspect = opts.aspect || 0
        var snap = !!opts.snap

        var px = view.snapDocCoord(pointerX, view.documentWidth, snap)
        var py = view.snapDocCoord(pointerY, view.documentHeight, snap)
        if (clampToDoc) {
            px = Math.max(0, Math.min(view.documentWidth, px))
            py = Math.max(0, Math.min(view.documentHeight, py))
        }

        var x = startRect.x
        var y = startRect.y
        var w = startRect.width
        var h = startRect.height

        if (fromCenter) {
            var cx = startRect.x + startRect.width / 2
            var cy = startRect.y + startRect.height / 2
            var hw = column === 0 ? Math.max(0.5, cx - px)
                   : (column === 2 ? Math.max(0.5, px - cx) : startRect.width / 2)
            var hh = row === 0 ? Math.max(0.5, cy - py)
                   : (row === 2 ? Math.max(0.5, py - cy) : startRect.height / 2)
            w = hw * 2
            h = hh * 2
            if (keepAspect && aspect > 0) {
                if (column !== 1 && row !== 1) {
                    if (w / h > aspect) w = h * aspect
                    else h = w / aspect
                } else if (row === 1) {
                    h = w / aspect
                } else if (column === 1) {
                    w = h * aspect
                }
            }
            if (clampToDoc) {
                var maxW = Math.max(1, 2 * Math.min(cx, view.documentWidth - cx))
                var maxH = Math.max(1, 2 * Math.min(cy, view.documentHeight - cy))
                if (keepAspect && aspect > 0) {
                    var fit = Math.min(1, maxW / w, maxH / h)
                    w *= fit
                    h *= fit
                } else {
                    w = Math.min(w, maxW)
                    h = Math.min(h, maxH)
                }
            }
            if (keepAspect && aspect > 0) {
                var cap = Math.min(1, maxDim / w, maxDim / h)
                w *= cap
                h *= cap
            } else {
                w = Math.min(w, maxDim)
                h = Math.min(h, maxDim)
            }
            w = Math.max(1, w)
            h = Math.max(1, h)
            x = cx - w / 2
            y = cy - h / 2
            return { x: Math.round(x), y: Math.round(y),
                     width: Math.max(1, Math.round(w)), height: Math.max(1, Math.round(h)) }
        }

        if (keepAspect && aspect > 0) {
            if (column !== 1 && row !== 1) {
                var fixedX = column === 0 ? startRect.x + startRect.width : startRect.x
                var fixedY = row === 0 ? startRect.y + startRect.height : startRect.y
                var rawW = Math.max(1, Math.abs(px - fixedX))
                var rawH = Math.max(1, Math.abs(py - fixedY))
                if (rawW / rawH > aspect) rawW = rawH * aspect
                else rawH = rawW / aspect
                var limW = clampToDoc ? (column === 0 ? fixedX : view.documentWidth - fixedX) : maxDim
                var limH = clampToDoc ? (row === 0 ? fixedY : view.documentHeight - fixedY) : maxDim
                var scale = Math.min(1, limW / rawW, limH / rawH, maxDim / rawW, maxDim / rawH)
                w = Math.max(1, rawW * scale)
                h = Math.max(1, rawH * scale)
                x = column === 0 ? fixedX - w : fixedX
                y = row === 0 ? fixedY - h : fixedY
            } else if (row === 1) {
                var sideX = column === 0 ? startRect.x + startRect.width : startRect.x
                var midY = startRect.y + startRect.height / 2
                w = Math.max(1, column === 0 ? sideX - px : px - sideX)
                h = w / aspect
                var maxSideW = clampToDoc ? (column === 0 ? sideX : view.documentWidth - sideX) : maxDim
                var maxSideH = clampToDoc ? view.documentHeight : maxDim
                var sH = Math.min(1, maxSideW / w, maxSideH / h, maxDim / w, maxDim / h)
                w = Math.max(1, w * sH)
                h = Math.max(1, h * sH)
                x = column === 0 ? sideX - w : sideX
                y = clampToDoc ? Math.max(0, Math.min(view.documentHeight - h, midY - h / 2))
                               : midY - h / 2
            } else {
                var sideY = row === 0 ? startRect.y + startRect.height : startRect.y
                var midX = startRect.x + startRect.width / 2
                h = Math.max(1, row === 0 ? sideY - py : py - sideY)
                w = h * aspect
                var maxVertH = clampToDoc ? (row === 0 ? sideY : view.documentHeight - sideY) : maxDim
                var maxVertW = clampToDoc ? view.documentWidth : maxDim
                var sV = Math.min(1, maxVertW / w, maxVertH / h, maxDim / w, maxDim / h)
                w = Math.max(1, w * sV)
                h = Math.max(1, h * sV)
                y = row === 0 ? sideY - h : sideY
                x = clampToDoc ? Math.max(0, Math.min(view.documentWidth - w, midX - w / 2))
                               : midX - w / 2
            }
            return { x: Math.round(x), y: Math.round(y),
                     width: Math.max(1, Math.round(w)), height: Math.max(1, Math.round(h)) }
        }

        if (column === 0) {
            var rightEdge = startRect.x + startRect.width
            x = Math.min(px, rightEdge - 1)
            w = Math.min(maxDim, rightEdge - x)
            x = rightEdge - w
        } else if (column === 2) {
            w = Math.max(1, Math.min(maxDim, px - startRect.x))
        }
        if (row === 0) {
            var bottomEdge = startRect.y + startRect.height
            y = Math.min(py, bottomEdge - 1)
            h = Math.min(maxDim, bottomEdge - y)
            y = bottomEdge - h
        } else if (row === 2) {
            h = Math.max(1, Math.min(maxDim, py - startRect.y))
        }
        return { x: Math.round(x), y: Math.round(y),
                 width: Math.max(1, Math.round(w)), height: Math.max(1, Math.round(h)) }
    }

    function computeBoxMoveDrag(startRect, dxDoc, dyDoc, modifiers) {
        var mods = modifiers || 0
        var shift = (mods & Qt.ShiftModifier) !== 0
        var snap = (mods & Qt.ControlModifier) !== 0
        var dx = dxDoc
        var dy = dyDoc
        if (shift) {
            if (Math.abs(dx) >= Math.abs(dy)) dy = 0
            else dx = 0
        }
        var nx = startRect.x + dx
        var ny = startRect.y + dy
        if (snap) {
            var threshold = Math.max(8, 10 / Math.max(0.05, view.zoom))
            var xSnapped = false
            var ySnapped = false
            // Snap left, centre, or right edge to document 0 / mid / max.
            var docMidX = view.documentWidth / 2
            var docMidY = view.documentHeight / 2
            if (Math.abs(nx) <= threshold) { nx = 0; xSnapped = true }
            else if (Math.abs(nx + startRect.width - view.documentWidth) <= threshold) {
                nx = view.documentWidth - startRect.width; xSnapped = true
            } else if (Math.abs(nx + startRect.width / 2 - docMidX) <= threshold) {
                nx = docMidX - startRect.width / 2; xSnapped = true
            }
            if (!xSnapped) nx = Math.round(nx / 10) * 10

            if (Math.abs(ny) <= threshold) { ny = 0; ySnapped = true }
            else if (Math.abs(ny + startRect.height - view.documentHeight) <= threshold) {
                ny = view.documentHeight - startRect.height; ySnapped = true
            } else if (Math.abs(ny + startRect.height / 2 - docMidY) <= threshold) {
                ny = docMidY - startRect.height / 2; ySnapped = true
            }
            if (!ySnapped) ny = Math.round(ny / 10) * 10
        }
        return { x: Math.round(nx), y: Math.round(ny) }
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

    /// The transform bounding box in document pixels.
    function transformRect() {
        var corners = view.transformCorners
        if (!corners || corners.length !== 4) return null
        var left = Math.min(corners[0][0], corners[3][0])
        var top = Math.min(corners[0][1], corners[1][1])
        var right = Math.max(corners[1][0], corners[2][0])
        var bottom = Math.max(corners[2][1], corners[3][1])
        return { x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) }
    }

    /// Write the transform bounding box from a rectangle in document pixels.
    /// In `free` mode the image may be placed partially off-canvas (clipped on
    /// apply); in `scale` mode the box describes the target `W × H` (anchored at
    /// `x, y` during drag so the opposite side stays put visually).
    function setTransformFrame(x, y, width, height) {
        var maxDim = 16384
        var w = Math.min(Math.max(1, Math.round(width)), maxDim)
        var h = Math.min(Math.max(1, Math.round(height)), maxDim)
        var left = Math.round(x)
        var top = Math.round(y)
        view.transformCorners = [[left, top],
                                 [left + w, top],
                                 [left + w, top + h],
                                 [left, top + h]]
    }

    readonly property var transformFrameHandles: [
        { column: 0, row: 0 }, { column: 2, row: 0 },
        { column: 2, row: 2 }, { column: 0, row: 2 },
        { column: 1, row: 0 }, { column: 2, row: 1 },
        { column: 1, row: 2 }, { column: 0, row: 1 }
    ]

    function dragFrameHandle(column, row, hostX, hostY, modifiers, startRect) {
        var base = startRect || view.transformRect()
        if (!base) return
        var mods = modifiers || 0
        var shift = (mods & Qt.ShiftModifier) !== 0
        var alt = (mods & Qt.AltModifier) !== 0
        var ctrl = (mods & Qt.ControlModifier) !== 0
        var next = view.computeBoxHandleDrag(
            base, column, row,
            view.hostToDocX(hostX), view.hostToDocY(hostY),
            {
                keepAspect: shift,
                aspect: base.height > 0 ? base.width / base.height : 1,
                fromCenter: alt,
                snap: ctrl,
                clampToDoc: false,
                maxDim: 16384
            })
        view.setTransformFrame(next.x, next.y, next.width, next.height)
    }

    function setTransformMode(mode) {
        if (mode !== "free" && mode !== "scale") return
        if (view.transformMode === mode) return
        view.transformMode = mode
        view.resetTransformCorners()
    }

    function dragTransformCorner(index, hostX, hostY, modifiers, startRect) {
        var handle = view.transformFrameHandles[index]
        if (!handle) return
        view.dragFrameHandle(handle.column, handle.row, hostX, hostY, modifiers, startRect)
    }

    function dragTransformEdge(index, hostX, hostY, modifiers, startRect) {
        var handle = view.transformFrameHandles[4 + index]
        if (!handle) return
        view.dragFrameHandle(handle.column, handle.row, hostX, hostY, modifiers, startRect)
    }

    function moveTransformBox(startRect, dxDoc, dyDoc, modifiers) {
        if (!startRect || view.transformMode !== "free") return
        var pos = view.computeBoxMoveDrag(startRect, dxDoc, dyDoc, modifiers)
        view.setTransformFrame(pos.x, pos.y, startRect.width, startRect.height)
    }

    function cornerX(index) {
        var corners = view.transformCorners
        return corners && corners.length === 4 ? corners[index][0] : 0
    }

    function cornerY(index) {
        var corners = view.transformCorners
        return corners && corners.length === 4 ? corners[index][1] : 0
    }

    function transformUsable() {
        var rect = view.transformRect()
        if (!view.documentReady || !rect) return false
        return rect.width >= 1 && rect.height >= 1
                && rect.width <= 16384 && rect.height <= 16384
    }

    function transformChanged() {
        var rect = view.transformRect()
        if (!rect) return false
        if (view.transformMode === "scale") {
            return Math.round(rect.width) !== Math.round(view.documentWidth)
                    || Math.round(rect.height) !== Math.round(view.documentHeight)
        }
        return Math.round(rect.x) !== 0
                || Math.round(rect.y) !== 0
                || Math.round(rect.width) !== Math.round(view.documentWidth)
                || Math.round(rect.height) !== Math.round(view.documentHeight)
    }

    /// Commit the live Transform bounding box as one typed Core command.
    function applyTransform() {
        var rect = view.transformRect()
        if (!rect || !view.transformUsable() || !view.transformChanged()) return
        if (view.transformMode === "scale") {
            view.command({
                type: "editor_resize",
                width: Math.round(rect.width),
                height: Math.round(rect.height),
                mode: "stretch",
                filter: "auto"
            })
        } else {
            view.command({
                type: "editor_free_transform",
                x: Math.round(rect.x),
                y: Math.round(rect.y),
                width: Math.round(rect.width),
                height: Math.round(rect.height),
                fill: view.backgroundTransparent ? null : view.backgroundBytes(),
                fill_alpha: view.backgroundAlpha()
            })
        }
        view.resetTransformCorners()
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

    /// Crop's two answers to "may the frame leave the picture?": `center` is
    /// the ordinary cut, `grow` a new canvas around the photo.
    readonly property var cropModes: [
        { key: "center", label: qsTr("Center") },
        { key: "grow", label: qsTr("Grow") }
    ]
    /// The colours a grown border can take are the Editor's background list,
    /// not this panel's: `BackgroundPopup.qml` is the one list, and the border
    /// is painted with whatever the pair holds.

    function cropGrow() {
        return view.cropMode === "grow"
    }

    function cropModeIndex() {
        for (var index = 0; index < view.cropModes.length; ++index) {
            if (view.cropModes[index].key === view.cropMode) return index
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

    /// The border colour the command carries, or `null` for an inside crop.
    /// Core reads a present colour as "the canvas may grow", and the colour is
    /// the Editor's background: transparent travels as `[0,0,0]` with
    /// `fill_alpha: 0`, which is what the command already means by clear. A
    /// Grow rectangle that still lies inside the picture has no border to
    /// paint, so it travels as an ordinary crop and its history line says
    /// Crop, not Grow.
    function cropFillForCommand() {
        if (!view.cropGrow()) return null
        var rect = view.cropRect
        if (rect.x >= 0 && rect.y >= 0
                && rect.x + rect.width <= view.documentWidth
                && rect.y + rect.height <= view.documentHeight) return null
        return view.backgroundBytes()
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

    /// Most recently edited size axis (`"width"` or `"height"`), so typing a
    /// ratio keeps the axis the user just touched unless the other is locked.
    property string cropLastAxis: "width"

    /// `3:2`, `3/2`, `3x2`, and decimals (`1.5`, `1.777`, `0.75`) all parse;
    /// anything else, including an empty string, is not a ratio.
    function parseRatio(text) {
        if (text === undefined || text === null) return null
        var cleaned = String(text).trim()
        if (cleaned === "") return null
        var match = /^(\d+(?:\.\d+)?)\s*[:/xX]\s*(\d+(?:\.\d+)?)$/.exec(cleaned)
        if (match) {
            var width = parseFloat(match[1])
            var height = parseFloat(match[2])
            if (!isFinite(width) || !isFinite(height) || !(width > 0) || !(height > 0)) return null
            return { width: width, height: height }
        }
        if (/^\d+(?:\.\d+)?$/.test(cleaned)) {
            var single = parseFloat(cleaned)
            if (!isFinite(single) || !(single > 0)) return null
            return { width: single, height: 1 }
        }
        return null
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
        view.cropHeightAuto = false
        view.cropWidthAuto = false
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
        if (Math.abs(pair.width - Math.round(pair.width)) < 1e-6
                && Math.abs(pair.height - Math.round(pair.height)) < 1e-6) {
            view.cropRatio = view.reducedRatio(Math.round(pair.width), Math.round(pair.height))
        } else {
            view.cropRatio = cleaned
        }
        view.syncCropRatioField()
        view.applyCropRatio()
    }

    /// Apply the current ratio to the fields. The locked side wins when one is
    /// pinned; otherwise the most recently edited axis (`cropLastAxis`) is kept.
    function applyCropRatio() {
        var pair = view.cropRatioPair()
        if (!pair) {
            view.applyCropAnchor()
            cropPreset.currentIndex = view.matchingCropPreset()
            return
        }
        var width = cropWidthField.acceptableInput ? cropWidthField.pixels() : 0
        var height = cropHeightField.acceptableInput ? cropHeightField.pixels() : 0
        if (view.cropLockWidth && width > 0) {
            height = width * pair.height / pair.width
        } else if (view.cropLockHeight && height > 0) {
            width = height * pair.width / pair.height
        } else if (view.cropLastAxis === "height" && height > 0) {
            width = height * pair.width / pair.height
        } else if (width > 0) {
            height = width * pair.height / pair.width
        } else if (height > 0) {
            width = height * pair.width / pair.height
        } else {
            return
        }
        var clamped = view.clampCropPair(width, height, true)
        view.cropHeightAuto = false
        view.cropWidthAuto = false
        cropWidthField.setPixels(clamped.width)
        cropHeightField.setPixels(clamped.height)
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
            if (view.cropLockWidth === locked) {
                view.syncCropLockButtons()
                return
            }
            if (locked && view.cropLockHeight && view.cropLockRatio) {
                view.syncCropLockButtons()
                return
            }
            view.cropLockWidth = locked
            if (locked && !cropWidthField.acceptableInput && view.hasDocument) {
                cropWidthField.setPixels(Math.round(view.documentWidth))
            }
        } else if (which === "height") {
            if (view.cropLockHeight === locked) {
                view.syncCropLockButtons()
                return
            }
            if (locked && view.cropLockWidth && view.cropLockRatio) {
                view.syncCropLockButtons()
                return
            }
            view.cropLockHeight = locked
            if (locked && !cropHeightField.acceptableInput && view.hasDocument) {
                cropHeightField.setPixels(Math.round(view.documentHeight))
            }
        } else if (which === "ratio") {
            if (view.cropLockRatio === locked) {
                view.syncCropLockButtons()
                return
            }
            if (locked && view.cropLockWidth && view.cropLockHeight) {
                view.syncCropLockButtons()
                return
            }
            view.cropLockRatio = locked
            if (locked) {
                // Lock the ratio currently displayed in the field (or the
                // current crop rectangle's ratio) — never snap back to the
                // original document ratio when a current ratio exists.
                var typed = (typeof cropRatioField !== "undefined" && cropRatioField !== null)
                            ? cropRatioField.text.trim() : ""
                var parsedTyped = view.parseRatio(typed)
                if (parsedTyped) {
                    if (Math.abs(parsedTyped.width - Math.round(parsedTyped.width)) < 1e-6
                            && Math.abs(parsedTyped.height - Math.round(parsedTyped.height)) < 1e-6) {
                        view.cropRatio = view.reducedRatio(Math.round(parsedTyped.width),
                                                           Math.round(parsedTyped.height))
                    } else {
                        view.cropRatio = typed
                    }
                } else if (view.cropRatio === "free") {
                    if (view.cropHasRect()) {
                        view.cropRatio = view.reducedRatio(
                                    cropWidthField.pixels(),
                                    cropHeightField.pixels())
                    } else if (view.hasDocument) {
                        view.cropRatio = view.reducedRatio(view.documentWidth,
                                                           view.documentHeight)
                    }
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
                view.setCropRatioFromPair(cropWidthField.pixels(),
                                          cropHeightField.pixels())
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
        var w = cropWidthField.pixels()
        var h = cropHeightField.pixels()
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
        var width = cropWidthField.pixels()
        var height = cropHeightField.pixels()
        if (!(width > 0) || !(height > 0)) return
        var anchor = view.cropAnchors[0]
        for (var index = 0; index < view.cropAnchors.length; ++index) {
            if (view.cropAnchors[index].key === view.cropAnchor) {
                anchor = view.cropAnchors[index]
                break
            }
        }
        cropX.setPixels(view.cropGrow()
                            ? Math.round((view.documentWidth - width) * anchor.column / 2)
                            : Math.max(0, Math.round((view.documentWidth - width) * anchor.column / 2)))
        cropY.setPixels(view.cropGrow()
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
        view.cropHeightAuto = false
        view.cropWidthAuto = false
        var width = cropWidthField.acceptableInput ? cropWidthField.pixels() : 0
        var height = cropHeightField.acceptableInput ? cropHeightField.pixels() : 0
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
        cropWidthField.setPixels(clamped.width)
        cropHeightField.setPixels(clamped.height)
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
        var width = cropWidthField.pixels()
        if (!(width > 0)) return
        view.cropLastAxis = "width"
        var pair = view.cropLockRatio ? view.cropRatioPair() : null
        var height = cropHeightField.acceptableInput ? cropHeightField.pixels() : 0
        if (pair && !view.cropLockHeight) {
            height = width * pair.height / pair.width
            var linked = view.clampCropPair(width, height, true)
            width = linked.width
            height = linked.height
        } else {
            if (!(height > 0) || view.cropHeightAuto) {
                height = width * view.documentHeight / view.documentWidth
                view.cropHeightAuto = true
            }
            var free = view.clampCropPair(width, height, false)
            width = free.width
            height = free.height
            if (width > 0 && height > 0) view.setCropRatioFromPair(width, height)
        }
        cropWidthField.setPixels(width)
        cropHeightField.setPixels(height)
        view.applyCropAnchor()
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    function linkWidthFromHeight() {
        if (!view.cropHeightEditable) return
        if (!cropHeightField.acceptableInput) return
        var height = cropHeightField.pixels()
        if (!(height > 0)) return
        view.cropLastAxis = "height"
        var pair = view.cropLockRatio ? view.cropRatioPair() : null
        var width = cropWidthField.acceptableInput ? cropWidthField.pixels() : 0
        if (pair && !view.cropLockWidth) {
            width = height * pair.width / pair.height
            var linked = view.clampCropPair(width, height, true)
            width = linked.width
            height = linked.height
        } else {
            view.cropHeightAuto = false
            if (!(width > 0) || view.cropWidthAuto) {
                width = height * view.documentWidth / view.documentHeight
                view.cropWidthAuto = true
            }
            var free = view.clampCropPair(width, height, false)
            width = free.width
            height = free.height
            if (width > 0 && height > 0) view.setCropRatioFromPair(width, height)
        }
        cropWidthField.setPixels(width)
        cropHeightField.setPixels(height)
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
                ? (cropWidthField.acceptableInput ? cropWidthField.pixels()
                                                  : preset.width)
                : preset.width
        var height = view.cropLockHeight
                ? (cropHeightField.acceptableInput ? cropHeightField.pixels()
                                                   : preset.height)
                : preset.height
        if (view.cropLockWidth && !view.cropLockHeight) {
            height = width * preset.height / preset.width
        } else if (view.cropLockHeight && !view.cropLockWidth) {
            width = height * preset.width / preset.height
        }
        var clamped = view.clampCropPair(width, height, true)
        view.cropHeightAuto = false
        view.cropWidthAuto = false
        cropWidthField.setPixels(clamped.width)
        cropHeightField.setPixels(clamped.height)
        view.applyCropAnchor()
        cropPreset.currentIndex = index
        draftDebounce.restart()
    }

    function cropFieldsValid() {
        if (!view.hasDocument || !cropWidthField.acceptableInput
                || !cropHeightField.acceptableInput) return false
        if (!cropX.acceptableInput || !cropY.acceptableInput) return false
        var width = cropWidthField.pixels()
        var height = cropHeightField.pixels()
        if (!(width > 0) || !(height > 0)) return false
        var x = cropX.pixels()
        var y = cropY.pixels()
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
            x: cropX.acceptableInput ? cropX.pixels() : 0,
            y: cropY.acceptableInput ? cropY.pixels() : 0,
            width: cropWidthField.acceptableInput ? cropWidthField.pixels() : 0,
            height: cropHeightField.acceptableInput ? cropHeightField.pixels() : 0
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
        cropX.setPixels(0)
        cropY.setPixels(0)
        cropPreset.currentIndex = -1
        view.cropHeightAuto = false
        view.cropWidthAuto = false
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
        view.cropHeightAuto = false
        view.cropWidthAuto = false
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
        // The border colour is not a panel option any more: the background
        // pair belongs to the Editor, so Reset leaves it alone.
        view.cropLockWidth = false
        view.cropLockHeight = false
        view.cropLockRatio = false
        cropModeBox.currentIndex = view.cropModeIndex()
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
            fill_alpha: fill === null ? 255 : view.backgroundAlpha()
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
        view.cropHeightAuto = false
        view.cropWidthAuto = false
        view.setCropRect(0, 0, view.documentWidth, view.documentHeight)
        return true
    }

    /// A drag on the empty canvas builds a rectangle from the press to the
    /// pointer. With a ratio chosen (or Shift held for a 1:1 square), the shape
    /// is fitted to that ratio before clamping. Alt grows symmetrically around
    /// the press point; Ctrl snaps to document guides or 10 px steps.
    function dragCropCreate(startHostX, startHostY, hostX, hostY, modifiers) {
        if (!view.documentReady) return
        var mods = modifiers || 0
        var shift = (mods & Qt.ShiftModifier) !== 0
        var alt = (mods & Qt.AltModifier) !== 0
        var ctrl = (mods & Qt.ControlModifier) !== 0
        var documentWidth = view.documentWidth
        var documentHeight = view.documentHeight
        var startX = view.snapDocCoord(view.hostToDocX(startHostX), documentWidth, ctrl)
        var startY = view.snapDocCoord(view.hostToDocY(startHostY), documentHeight, ctrl)
        var endX = view.snapDocCoord(view.hostToDocX(hostX), documentWidth, ctrl)
        var endY = view.snapDocCoord(view.hostToDocY(hostY), documentHeight, ctrl)
        if (!view.cropGrow()) {
            startX = Math.max(0, Math.min(documentWidth, startX))
            startY = Math.max(0, Math.min(documentHeight, startY))
            endX = Math.max(0, Math.min(documentWidth, endX))
            endY = Math.max(0, Math.min(documentHeight, endY))
        }
        var aspect = view.cropLockRatio ? view.cropRatioAspect() : 0
        if (aspect <= 0 && shift) aspect = 1.0
        var width = Math.max(1, alt ? Math.abs(endX - startX) * 2 : Math.abs(endX - startX))
        var height = Math.max(1, alt ? Math.abs(endY - startY) * 2 : Math.abs(endY - startY))
        if (aspect > 0) {
            if (width / height > aspect) width = height * aspect
            else height = width / aspect
            if (view.cropGrow()) {
                var cap = Math.min(1, 20000 / width, 20000 / height)
                width *= cap
                height *= cap
            } else {
                var maxWidth = alt ? 2 * Math.min(startX, documentWidth - startX)
                                   : (endX >= startX ? documentWidth - startX : startX)
                var maxHeight = alt ? 2 * Math.min(startY, documentHeight - startY)
                                    : (endY >= startY ? documentHeight - startY : startY)
                var scale = Math.min(1, Math.max(1, maxWidth) / width, Math.max(1, maxHeight) / height)
                width *= scale
                height *= scale
            }
        } else if (alt && !view.cropGrow()) {
            width = Math.min(width, Math.max(1, 2 * Math.min(startX, documentWidth - startX)))
            height = Math.min(height, Math.max(1, 2 * Math.min(startY, documentHeight - startY)))
        }
        var x = alt ? startX - width / 2 : (endX >= startX ? startX : startX - width)
        var y = alt ? startY - height / 2 : (endY >= startY ? startY : startY - height)
        view.cropHeightAuto = false
        view.cropWidthAuto = false
        view.setCropRect(x, y, width, height)
    }

    /// The frame is drawn on the canvas and stays there while the answer is
    /// drawn under it: the result is on the canvas (`transformPreview`), and the
    /// eight handles are what the next drag grabs. Hiding them for a draft is
    /// what made the old live preview a switch — the picture arrived and the
    /// thing you aimed with left.
    readonly property bool transformFrameShown:
        view.tool === "transform" && view.documentReady
        && view.transformCorners && view.transformCorners.length === 4

    readonly property bool cropFrameShown:
        view.tool === "crop" && view.documentReady
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
        cropX.setPixels(x)
        cropY.setPixels(y)
        cropWidthField.setPixels(width)
        cropHeightField.setPixels(height)
        if (!view.cropLockRatio && width > 0 && height > 0) {
            view.setCropRatioFromPair(width, height)
        }
        // Mirror the pair in the preset dropdown without re-applying it.
        cropPreset.currentIndex = view.matchingCropPreset()
        draftDebounce.restart()
    }

    /// Drag one crop frame handle. Supports the shared bounding-box modifiers:
    /// Shift locks aspect ratio (using the panel ratio or the starting rect's
    /// ratio), Alt resizes symmetrically around the centre, Ctrl snaps to
    /// document guides / 10 px steps.
    function dragCropHandle(column, row, hostX, hostY, modifiers, startRect) {
        if (!view.cropFrameShown) return
        if (!view.cropResizable) return
        var rect = startRect || view.cropRect
        var mods = modifiers || 0
        var shift = (mods & Qt.ShiftModifier) !== 0
        var alt = (mods & Qt.AltModifier) !== 0
        var ctrl = (mods & Qt.ControlModifier) !== 0
        var documentWidth = view.documentWidth
        var documentHeight = view.documentHeight
        var grow = view.cropGrow()
        var pointerX = view.hostToDocX(hostX)
        var pointerY = view.hostToDocY(hostY)
        // One locked axis leaves the other handle free: a left/right side is
        // pinned with Width, and a top/bottom side is pinned with Height. The
        // corners follow whichever axis is still free.
        if (view.cropLockWidth || view.cropLockHeight) {
            pointerX = view.snapDocCoord(pointerX, documentWidth, ctrl)
            pointerY = view.snapDocCoord(pointerY, documentHeight, ctrl)
            if (!grow) {
                pointerX = Math.max(0, Math.min(documentWidth, pointerX))
                pointerY = Math.max(0, Math.min(documentHeight, pointerY))
            }
            var x = rect.x
            var y = rect.y
            var width = rect.width
            var height = rect.height
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
                view.setCropRatioFromPair(cropWidthField.pixels(),
                                          cropHeightField.pixels())
            }
            return
        }
        var aspect = view.cropLockRatio ? view.cropRatioAspect() : 0
        var keepAspect = aspect > 0 || shift
        var effectiveAspect = aspect > 0 ? aspect : (rect.height > 0 ? rect.width / rect.height : 1)
        var next = view.computeBoxHandleDrag(rect, column, row, pointerX, pointerY, {
            keepAspect: keepAspect,
            aspect: effectiveAspect,
            fromCenter: alt,
            snap: ctrl,
            clampToDoc: !grow,
            maxDim: 20000
        })
        view.setCropRect(next.x, next.y, next.width, next.height)
    }

    /// Draft preview hook (Crop draws its own frame and Transform previews live
    /// on the GPU canvas without round-tripping Core).
    function requestDraft() {
        draftDebounce.stop()
    }

    /// Raised by the empty state and the toolbar's open button; Main owns the
    /// file chooser so the portal/fallback path stays in one place.
    signal requestOpen()
    /// Raised by Save as…: Main owns the chooser, and the chosen path becomes an
    /// `editor_save_as` command. `view.saveAsPath` carries the suggestion.
    signal requestSaveAs()
    /// Raised by Export's Browse button: Main owns the file chooser.
    signal requestExportPath()
    /// The user dragged the dock's splitter: the shell keeps one width for all
    /// three workspaces, so the view reports the number rather than owning it.
    /// A layout interaction — a splitter, the rail's columns, a reference tab
    /// or panel — as a patch the shell merges into the saved layout. A layout
    /// is Core state (`set_layout`), so the view never writes it.
    signal layoutRequested(var patch)
    /// Show a folder in the desktop's file manager. The shell owns the platform
    /// call, so the view only names the path.
    signal revealPath(string path)
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

    /// Whether this document's own file is a JPEG. The encoder composites alpha
    /// over white (`crates/app-editor/src/codec.rs`), so a transparent
    /// background is drawn as the checkerboard on screen and written as white
    /// on disk. Nothing can be done about that — JPEG has no alpha — so the
    /// background list says it at the moment the choice is made instead of
    /// losing it silently on the next save.
    readonly property bool documentIsJpeg: {
        var format = String((editor && editor.format) || "").toLowerCase()
        return format === ".jpg" || format === ".jpeg"
                || format === "jpg" || format === "jpeg"
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
    /// The same list, as the words the combo box draws. A string model lets the
    /// field and its rows be the platform's own: the closed box needs a matching
    /// ink/background pair, and only the style that paints the field knows it.
    /// Written as a `Label` in the theme's ink, the value was near-white on the
    /// style's white field on the real window — the choice was invisible.
    readonly property var exportEdgeLabels: exportEdges.map(function(edge) {
        return view.exportEdgeLabel(edge)
    })

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
    property alias panHover: canvasHost.hovered

    // ------------------------------------------------ presentation transform
    // Shared through `ImageCanvas.qml`: Core knows nothing about it and it
    // survives no command. Tight clamping (`panMargin = 0`) keeps fitted
    // documents centred and restricts pan strictly to the document edges.
    property alias zoom: canvasHost.zoom
    property alias offsetX: canvasHost.offsetX
    property alias offsetY: canvasHost.offsetY
    property alias autoFit: canvasHost.autoFit
    /// False until the canvas host exists; the document's size handlers fire
    /// while the view is still being constructed.
    property bool hostReady: false
    property alias lastWheelX: canvasHost.lastWheelX
    property alias lastWheelY: canvasHost.lastWheelY

    readonly property string documentPath: editor ? (editor.path || "") : ""
    readonly property real documentWidth: hasDocument ? editor.width : 0
    readonly property real documentHeight: hasDocument ? editor.height : 0

    /// The straightened result Core rendered for the frame on screen. Live
    /// preview is not an option any more: the answer is drawn on the canvas as
    /// soon as the frame leaves the identity, because a frame whose result you
    /// have to ask for is a frame you are aiming blind. The corners stay drawn
    /// on top of it (`transformFrameShown`), so the result can be watched and
    /// dragged at once.
    ///
    /// The gating is presentation-only: Core keeps the draft until an edit lands
    /// or the document changes, so the tool being put down, a draft of another
    /// kind, or a frame back on the identity all hide it here without sending a
    /// command. A stale draft therefore cannot outlive the frame it answers.
    readonly property var transformPreview: {
        if (!editor || !editor.previewDraft) return null
        var draft = editor.previewDraft
        if (view.tool !== "transform") return null
        if (draft.kind !== "transform") return null
        if (!view.transformUsable() || !view.transformChanged()) return null
        return draft
    }
    /// True while the Resize dialog is up. It is the Editor's own modal, not one
    /// the shell owns, so the canvas handlers read it directly: Qt delivers
    /// pointer-handler events to items under a popup overlay, and a wheel or a
    /// drag behind a modal form would move a picture the user cannot see.
    readonly property bool resizeDialogOpen: resizeDialog.visible
    readonly property bool canvasSizeDialogOpen: canvasSizeDialog.visible

    // Custom live rotate state (clockwise degrees, -180..+180). Uses the
    // Editor's shared background colour directly.
    property real rotateAngle: 0
    readonly property bool rotateFrameShown: view.tool === "rotate" && view.documentReady
    readonly property real rotatedWidth: {
        if (!view.hasDocument) return 0
        var rad = view.rotateAngle * Math.PI / 180
        return Math.max(1, Math.min(16384, Math.ceil(
            Math.abs(view.documentWidth * Math.cos(rad))
            + Math.abs(view.documentHeight * Math.sin(rad)))))
    }
    readonly property real rotatedHeight: {
        if (!view.hasDocument) return 0
        var rad = view.rotateAngle * Math.PI / 180
        return Math.max(1, Math.min(16384, Math.ceil(
            Math.abs(view.documentWidth * Math.sin(rad))
            + Math.abs(view.documentHeight * Math.cos(rad)))))
    }
    function rotateHasChange() {
        var norm = ((view.rotateAngle % 360) + 360) % 360
        return norm > 0.01 && (360 - norm) > 0.01
    }
    function applyRotateAngle() {
        if (!view.documentReady || !view.rotateHasChange()) return
        view.command({
            type: "editor_rotate_angle",
            degrees: view.rotateAngle,
            fill: view.backgroundTransparent ? null : view.backgroundBytes(),
            fill_alpha: view.backgroundAlpha()
        })
        view.rotateAngle = 0
    }

    readonly property bool resizeFrameShown: view.tool === "resize" && view.documentReady && resizeOptionsPanel.valid
    readonly property bool canvasSizeFrameShown: view.tool === "canvasSize" && view.documentReady && canvasSizeOptionsPanel.valid

    function applyResizePanel() {
        if (!view.documentReady || !resizeOptionsPanel.changed) return
        var isPad = resizeOptionsPanel.fitMode === "pad"
        view.command({
            type: "editor_resize",
            width: resizeOptionsPanel.targetWidth,
            height: resizeOptionsPanel.targetHeight,
            mode: resizeOptionsPanel.fitMode,
            filter: resizeOptionsPanel.filter,
            fill: isPad && !view.backgroundTransparent ? view.backgroundBytes() : null,
            fill_alpha: isPad ? view.backgroundAlpha() : 255
        })
        view.tool = "pointer"
    }

    function applyCanvasSizePanel() {
        if (!view.documentReady || !canvasSizeOptionsPanel.changed) return
        view.command({
            type: "editor_canvas_size",
            width: canvasSizeOptionsPanel.targetWidth,
            height: canvasSizeOptionsPanel.targetHeight,
            anchor: canvasSizeOptionsPanel.anchor,
            fill: view.backgroundTransparent ? null : view.backgroundBytes(),
            fill_alpha: view.backgroundAlpha()
        })
        view.tool = "pointer"
    }

    function applyColorAdjust() {
        if (!view.documentReady || !adjustOptionsPanel.changed) return
        view.command({
            type: "editor_adjust_color",
            brightness: adjustOptionsPanel.brightness,
            contrast: adjustOptionsPanel.contrast,
            saturation: adjustOptionsPanel.saturation
        })
        adjustOptionsPanel.reset()
    }

    function openResizeDialog() {
        if (!view.documentReady) return
        resizeOptionsPanel.reset()
        view.tool = view.tool === "resize" ? "pointer" : "resize"
        view.forceActiveFocus()
    }

    function openCanvasSizeDialog() {
        if (!view.documentReady) return
        canvasSizeOptionsPanel.reset()
        view.tool = view.tool === "canvasSize" ? "pointer" : "canvasSize"
        view.forceActiveFocus()
    }
    /// What the canvas draws: the draft while Transform has one, the document
    /// otherwise. The draft keeps the document's size (a warp is remapped onto
    /// the document's own frame), so both numbers describe the same rectangle —
    /// they are read from the draft anyway, so the two cannot drift apart.
    readonly property real displayedWidth: transformPreview ? transformPreview.width : documentWidth
    readonly property real displayedHeight: transformPreview ? transformPreview.height : documentHeight

    readonly property real canvasOriginX: canvasHost.canvasOriginX
    readonly property real canvasOriginY: canvasHost.canvasOriginY
    function docToHostX(value) { return canvasHost.docToHostX(value) }
    function docToHostY(value) { return canvasHost.docToHostY(value) }
    function hostToDocX(value) { return canvasHost.hostToDocX(value) }
    function hostToDocY(value) { return canvasHost.hostToDocY(value) }

    function sizeLabel() {
        if (!hasDocument) return "—"
        return editor.width + " × " + editor.height
    }

    readonly property int zoomPercent: Math.round(view.zoom * 100)

    function setZoom(value) { canvasHost.setZoom(value) }
    function clampOffsets() { if (hostReady) canvasHost.clampOffsets() }
    function fit() { if (hasDocument && hostReady) canvasHost.fit() }
    function refitOrClamp() { if (hostReady) canvasHost.refitOrClamp() }
    function actualSize() { if (hasDocument) canvasHost.actualSize() }
    function zoomIn() { canvasHost.zoomIn() }
    function zoomOut() { canvasHost.zoomOut() }
    function zoomAt(factor, pointX, pointY) { if (hasDocument) canvasHost.zoomAt(factor, pointX, pointY) }
    function toggleZoom() { if (hasDocument) canvasHost.toggleZoom() }

    onDocumentPathChanged: {
        view.autoFit = true
        view.offsetX = 0
        view.offsetY = 0
        // A different document is not the result of the crop that was pending.
        view.pendingCropResult = null
        if (view.hostReady && view.hasDocument) {
            view.fit()
            Qt.callLater(view.fit)
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
        // The tool panel is where a tool is configured. A user who put it
        // away and then arms a tool gets the panel back; the pointer is the
        // no-op tool, so it never forces the panel open. Panel visibility is
        // Core's layout, so asking for it is a patch, not a local write.
        if (view.tool !== "pointer" && view.tool !== "hand" && !view.toolOptionsVisible)
            view.layoutRequested({ panels: { "editor.options": true } })
        if (view.tool === "transform") view.resetTransformCorners()
        if (view.tool === "crop") view.enterCropTool()
        if (view.tool === "rotate") view.rotateAngle = 0
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
                                      view.cropLockRatio && view.cropRatio !== "free")
        view.setCropRect(Math.max(0, Math.min(rect.x, view.documentWidth - pair.width)),
                         Math.max(0, Math.min(rect.y, view.documentHeight - pair.height)),
                         pair.width, pair.height)
        if (view.cropLockRatio && view.cropRatio !== "free") view.applyCropRatio()
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

    /// The left dock's folder menu in this workspace: go to the folder in the
    /// Browser, or show it in the desktop's file manager. The Browser keeps its
    /// own, longer menu because it can also create and organise folders here.
    FolderMenu {
        id: folderMenu
        theme: view.theme
        onOpenInBrowser: view.command({ type: "open_folder", path: folderMenu.path })
        onReveal: view.revealPath(folderMenu.path)
    }

    // ------------------------------------------------------------ editor menu
    // The long label serves as the width probe: a regression that cuts labels
    // shows up as "Crop to selection…" losing its ellipsis.
    AppMenu {
        id: contextMenu
        theme: view.theme
        implicitWidth: view.theme.menuWidth(view.theme.menuLabelWidths,
                                            view.theme.menuShortcutWidths)

        MenuItem {
            text: view.theme.menuEntries[23]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_rotate", degrees: -90 })
        }
        MenuItem {
            text: view.theme.menuEntries[24]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_rotate", degrees: 90 })
        }
        MenuItem {
            text: view.theme.menuEntries[25]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_flip", axis: "horizontal" })
        }
        MenuItem {
            text: view.theme.menuEntries[26]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_flip", axis: "vertical" })
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[27]
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
        MenuItem {
            text: view.theme.menuEntries[28]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_close" })
        }
    }

    // ------------------------------------------------------ editor workspace
    property Component toolbar: Component {
        RowLayout {
            spacing: 2

            // The way out of the workspace sits first, as it does in the
            // Viewer: escaping an editor must not mean hunting for the button
            // at the far end of a row whose length depends on the document.
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
                objectName: "editorClose"
                theme: view.theme
                icon.name: "window-close-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[28]
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

        // --------------------------------------------------------- files (left)
        // The same two panels the Browser and the Viewer show, in the same
        // order. A folder click opens it in the Browser: re-rooting the file
        // list would replace the document the Editor is holding.
        LeftDock {
            objectName: "editorLeftPanel"
            visible: view.leftDockShown
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            theme: view.theme
            state: view.state
            quickAccessShown: view.quickAccessShown
            explorerShown: view.explorerShown
            listFolders: view.listFolders
            onOpenFolder: function(path) { view.command({ type: "open_folder", path: path }) }
            onNavigateTo: function(path) { view.command({ type: "open_folder", path: path }) }
            onOpenMenu: function(path) { view.folderMenu.path = path; view.folderMenu.popup() }
            onQuickMenu: function(path) { view.folderMenu.path = path; view.folderMenu.popup() }
        }

        PanelSplitter {
            objectName: "editorLeftSplitter"
            visible: view.leftDockShown
            Layout.fillHeight: true
            theme: view.theme
            value: view.leftPanelWidth
            defaultValue: 240
            direction: 1
            minimum: 180
            maximum: 560
            onMoved: function(width) {
                view.leftDragging = true
                view.leftPanelWidth = width
            }
            onReleased: function(width) {
                view.leftDragging = false
                view.layoutRequested({ leftWidth: Math.round(width) })
            }
        }

        // -------------------------------------------------------- tools (left)
        // An icon rail, the way Krita's toolbox and Photoshop's toolbar are: the
        // picture keeps the width, and a tool is a drawing with its sentence in
        // a tooltip. The rail folds between two columns (the default) and one
        // for a narrow window; that is presentation state like the zoom, so it
        // sends nothing to Core and is not remembered.
        //
        // The icons are this repository's own (`qml/icons/`, registered by
        // `icons.qrc`) because the desktop themes disagree: Breeze ships crop,
        // brush and eraser drawings, Adwaita and Papirus do not, and a missing
        // icon in an icon-only rail is an empty button.
        Rectangle {
            objectName: "editorTools"
            Layout.preferredWidth: view.toolRailWidth
            Layout.fillHeight: true
            color: view.theme.sidebar
            // The rail is a panel of its own: it is a column beside the
            // canvas, so Settings › Appearance can put it away, and the canvas
            // takes its width when it does.
            visible: view.toolsShown

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Label {
                    objectName: "editsHeading"
                    // A one-column rail is narrower than the word; the tooltips
                    // already name everything, so the heading goes rather than
                    // eliding to "T…".
                    visible: view.toolColumns === 2
                    text: qsTr("Tools")
                    color: view.theme.text
                    font.bold: true
                }

                // The tools. The pointer selects nothing, so Core never sees a
                // command from it; Crop, Transform and Paint write the canvas
                // and their options live in the right column. Resize is not a
                // canvas mode: it opens a dialog, and its button stays lit
                // while that form is up so the rail still says where the
                // question came from.
                GridLayout {
                    objectName: "editorToolGrid"
                    Layout.fillWidth: true
                    columns: view.toolColumns
                    columnSpacing: 4
                    rowSpacing: 4

                    ToolRailButton {
                        objectName: "toolPointer"
                        theme: view.theme
                        iconSource: "icons/pointer.svg"
                        tooltip: qsTr("Pointer")
                        active: view.tool === "pointer"
                        onClicked: {
                            view.tool = "pointer"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolHand"
                        theme: view.theme
                        iconSource: "icons/hand.svg"
                        tooltip: qsTr("Hand (H)")
                        active: view.tool === "hand"
                        onClicked: {
                            view.tool = "hand"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolResize"
                        theme: view.theme
                        iconSource: "icons/resize.svg"
                        tooltip: qsTr("Resize…")
                        active: view.tool === "resize"
                        enabled: view.documentReady
                        onClicked: view.openResizeDialog()
                    }
                    ToolRailButton {
                        objectName: "toolCanvasSize"
                        theme: view.theme
                        iconSource: "icons/canvas-size.svg"
                        tooltip: qsTr("Canvas size…")
                        active: view.tool === "canvasSize"
                        enabled: view.documentReady
                        onClicked: view.openCanvasSizeDialog()
                    }
                    ToolRailButton {
                        objectName: "toolCrop"
                        theme: view.theme
                        iconSource: "icons/crop.svg"
                        tooltip: qsTr("Crop")
                        active: view.tool === "crop"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "crop" ? "pointer" : "crop"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolTransform"
                        theme: view.theme
                        iconSource: "icons/transform.svg"
                        tooltip: qsTr("Straighten the picture by dragging the frame's corners and edges")
                        active: view.tool === "transform"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "transform" ? "pointer" : "transform"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolRotateAngle"
                        theme: view.theme
                        iconSource: "icons/rotate-angle.svg"
                        tooltip: qsTr("Rotate by angle")
                        active: view.tool === "rotate"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "rotate" ? "pointer" : "rotate"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolAdjust"
                        theme: view.theme
                        iconSource: "icons/adjust.svg"
                        tooltip: qsTr("Color & light")
                        active: view.tool === "adjust"
                        enabled: view.documentReady
                        onClicked: {
                            adjustOptionsPanel.reset()
                            view.tool = view.tool === "adjust" ? "pointer" : "adjust"
                            view.forceActiveFocus()
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    color: view.theme.border
                }

                // These change pixels the moment they are pressed, so they are
                // actions rather than tools. Undo, Redo and Reset live on the
                // toolbar; the rail keeps the tools and the quick edits.
                GridLayout {
                    objectName: "editorEditGrid"
                    Layout.fillWidth: true
                    columns: view.toolColumns
                    columnSpacing: 4
                    rowSpacing: 4

                    ToolRailButton {
                        objectName: "editsRotateLeft"
                        theme: view.theme
                        iconSource: "icons/rotate-left.svg"
                        tooltip: qsTr("Rotate left")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_rotate", degrees: -90 })
                    }
                    ToolRailButton {
                        objectName: "editsRotateRight"
                        theme: view.theme
                        iconSource: "icons/rotate-right.svg"
                        tooltip: qsTr("Rotate right")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_rotate", degrees: 90 })
                    }
                    ToolRailButton {
                        objectName: "editsFlipHorizontal"
                        theme: view.theme
                        iconSource: "icons/flip-horizontal.svg"
                        tooltip: qsTr("Flip horizontal")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_flip", axis: "horizontal" })
                    }
                    ToolRailButton {
                        objectName: "editsFlipVertical"
                        theme: view.theme
                        iconSource: "icons/flip-vertical.svg"
                        tooltip: qsTr("Flip vertical")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_flip", axis: "vertical" })
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    color: view.theme.border
                }

                // The pair is the Editor's, not the brush's: it sits under the
                // tools because every tool that takes a colour reads one of
                // its two roles, and it stays visible with no document open —
                // dimmed — so the rail does not grow and shrink a row at a
                // time.
                Item {
                    objectName: "colourPairRow"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34

                    ColourPair {
                        id: railColourPair
                        objectName: "colourPair"
                        anchors.horizontalCenter: parent.horizontalCenter
                        enabled: view.documentReady
                        theme: view.theme
                        foreground: view.foregroundColor
                        background: view.backgroundColor
                        backgroundTransparent: view.backgroundTransparent
                        onForegroundClicked: view.openForegroundChooser()
                        onBackgroundClicked:
                            view.openBackgroundPopup(railColourPair.backgroundBox)
                        onSwapRequested: {
                            view.swapColours()
                            view.forceActiveFocus()
                        }
                        onResetRequested: {
                            view.resetColours()
                            view.forceActiveFocus()
                        }
                    }
                }

                // Canvas background swatch: full width of the rail (2 columns
                // wide in normal mode, 1 column in compact mode), directly below
                // the foreground/background pair.
                Rectangle {
                    id: canvasBgSwatch
                    objectName: "canvasBgSwatch"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 22
                    radius: view.theme.radius
                    color: (!view.canvasBgUseTheme && view.canvasBgChecker)
                           ? "transparent"
                           : (view.canvasBgUseTheme ? view.theme.thumb : view.canvasBgColor)
                    border.width: 1
                    border.color: canvasBgHover.hovered ? view.theme.accent : view.theme.border
                    clip: true

                    Checkerboard {
                        anchors.fill: parent
                        visible: !view.canvasBgUseTheme && view.canvasBgChecker
                    }
                    HoverHandler { id: canvasBgHover; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: qsTr("Canvas background")
                        onClicked: view.openCanvasBgPopup(canvasBgSwatch)
                    }
                }

                Item { Layout.fillHeight: true }

                // The rail's own width is its one control: no splitter, because
                // a rail dragged wide is a column again.
                ToolRailButton {
                    objectName: "toolRailColumns"
                    theme: view.theme
                    iconSource: view.toolColumns === 2 ? "icons/columns-one.svg"
                                                       : "icons/columns-two.svg"
                    tooltip: view.toolColumns === 2 ? qsTr("One column")
                                                    : qsTr("Two columns")
                    onClicked: view.setToolColumns(view.toolColumns === 2 ? 1 : 2)
                }
            }
        }

        // ------------------------------------------------------------- canvas
        ImageCanvas {
            id: canvasHost
            objectName: "editorCanvasHost"
            wheelHandlerName: "editorWheelHandler"
            panHandlerName: "editorPanHandler"
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: view.canvasBgUseTheme
                   ? view.theme.thumb
                   : (view.canvasBgChecker ? "transparent" : view.canvasBgColor)
            hasContent: view.hasDocument
            contentWidth: view.displayedWidth
            contentHeight: view.displayedHeight
            minZoom: 0.02
            maxZoom: 16
            fitPadding: 32
            fitScaleFactor: 1.0
            fitCapAtOne: true
            roundPosition: true
            // Allow Krita-style free pan with Hand tool or Space even when fitted,
            // while keeping the image reachable inside the viewport.
            panMargin: Math.max(64, Math.round(Math.min(width, height) * 0.35))
            inputBlocked: view.resizeDialogOpen || view.canvasSizeDialogOpen
                          || foregroundColorDialog.visible || backgroundColorDialog.visible
                          || canvasBgColorDialog.visible
            requireHoverToPan: true
            allowLeftPan: view.tool === "hand" || view.spacePanning
            allowMiddlePan: true
            allowDoubleTapZoom: (view.tool === "pointer" || view.tool === "hand") && !view.spacePanning

            // Full-viewport checkerboard when the user explicitly selects
            // checkerboard as the canvas backdrop.
            Checkerboard {
                objectName: "editorViewportCheckerboard"
                anchors.fill: parent
                square: 12
                visible: !view.canvasBgUseTheme && view.canvasBgChecker
            }

            // Document backdrop: checkerboard, white, black, or custom colour
            // drawn behind the picture so transparent pixels stay visible.
            Item {
                id: canvasBackdrop
                objectName: "canvasBackdrop"
                visible: view.hasDocument && !view.transformFrameShown && !view.rotateFrameShown
                         && !view.resizeFrameShown && !view.canvasSizeFrameShown
                x: view.docToHostX(0)
                y: view.docToHostY(0)
                width: Math.max(1, view.displayedWidth * view.zoom)
                height: Math.max(1, view.displayedHeight * view.zoom)
                clip: true

                Checkerboard {
                    anchors.fill: parent
                    square: 10
                    visible: view.canvasBgUseTheme || view.canvasBgChecker
                }
                Rectangle {
                    anchors.fill: parent
                    visible: !view.canvasBgUseTheme && !view.canvasBgChecker
                    color: view.canvasBgColor
                }
            }

            Image {
                id: canvas
                objectName: "canvas"
                // While Transform, Rotate, Resize or Canvas Size is armed,
                // its live GPU preview layer draws directly on the canvas at 60 fps.
                visible: !view.transformFrameShown && !view.rotateFrameShown
                         && !view.resizeFrameShown && !view.canvasSizeFrameShown
                width: Math.max(1, view.displayedWidth)
                height: Math.max(1, view.displayedHeight)
                scale: canvasHost.zoom
                x: canvasHost.itemX
                y: canvasHost.itemY
                fillMode: Image.Stretch
                asynchronous: false
                cache: false
                smooth: view.state.antiAliasing !== false
                mipmap: view.state.antiAliasing !== false
                source: view.editor && view.editor.previewPath
                        ? "file://" + view.editor.previewPath
                        : ""
                // Live 60 fps GPU preview when the Color & light tool is active.
                layer.enabled: view.tool === "adjust" && adjustOptionsPanel.changed
                layer.effect: MultiEffect {
                    brightness: adjustOptionsPanel.brightness
                    contrast: adjustOptionsPanel.contrast
                    saturation: adjustOptionsPanel.saturation
                }
                onStatusChanged: {
                    if (status === Image.Ready && view.autoFit && view.hostReady) {
                        view.fit()
                    }
                }
                opacity: view.rendering ? 0.65 : 1.0
                Behavior on opacity {
                    NumberAnimation { duration: 120 }
                }
            }

            // Live 60 fps GPU preview for Resize (Stretch / Cover / Pad).
            Item {
                id: resizeCanvasLayer
                objectName: "resizeCanvasLayer"
                anchors.fill: parent
                visible: view.resizeFrameShown

                readonly property real previewW: Math.max(1, resizeOptionsPanel.targetWidth * view.zoom)
                readonly property real previewH: Math.max(1, resizeOptionsPanel.targetHeight * view.zoom)

                Item {
                    x: Math.round(canvasHost.width / 2 + canvasHost.offsetX - resizeCanvasLayer.previewW / 2)
                    y: Math.round(canvasHost.height / 2 + canvasHost.offsetY - resizeCanvasLayer.previewH / 2)
                    width: resizeCanvasLayer.previewW
                    height: resizeCanvasLayer.previewH
                    clip: true

                    Checkerboard {
                        anchors.fill: parent
                        square: 10
                        visible: resizeOptionsPanel.fitMode === "pad"
                                 ? view.backgroundTransparent
                                 : (view.canvasBgUseTheme || view.canvasBgChecker)
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: resizeOptionsPanel.fitMode === "pad"
                                 ? !view.backgroundTransparent
                                 : (!view.canvasBgUseTheme && !view.canvasBgChecker)
                        color: resizeOptionsPanel.fitMode === "pad"
                               ? view.backgroundColor
                               : view.canvasBgColor
                    }
                    Image {
                        anchors.fill: parent
                        source: canvas.source
                        asynchronous: false
                        cache: false
                        smooth: resizeOptionsPanel.filter !== "nearest"
                        fillMode: resizeOptionsPanel.fitMode === "cover"
                                  ? Image.PreserveAspectCrop
                                  : (resizeOptionsPanel.fitMode === "pad"
                                     ? Image.PreserveAspectFit
                                     : Image.Stretch)
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1.5
                        border.color: view.theme.accent
                    }
                }
            }

            // Live 60 fps GPU preview for Canvas Size (anchor-positioned image
            // inside the new canvas dimensions, using the shared background).
            Item {
                id: canvasSizeLayer
                objectName: "canvasSizeLayer"
                anchors.fill: parent
                visible: view.canvasSizeFrameShown

                readonly property real targetW: Math.max(1, canvasSizeOptionsPanel.targetWidth * view.zoom)
                readonly property real targetH: Math.max(1, canvasSizeOptionsPanel.targetHeight * view.zoom)
                readonly property real frameX: Math.round(canvasHost.width / 2 + canvasHost.offsetX - targetW / 2)
                readonly property real frameY: Math.round(canvasHost.height / 2 + canvasHost.offsetY - targetH / 2)

                // Dimmed ghost of original image so cropped edges stay visible when shrinking.
                Image {
                    x: canvasSizeLayer.frameX + canvasSizeOptionsPanel.imageOffsetX * view.zoom
                    y: canvasSizeLayer.frameY + canvasSizeOptionsPanel.imageOffsetY * view.zoom
                    width: Math.max(1, view.displayedWidth * view.zoom)
                    height: Math.max(1, view.displayedHeight * view.zoom)
                    source: canvas.source
                    asynchronous: false
                    cache: false
                    fillMode: Image.Stretch
                    opacity: 0.25
                }

                Item {
                    x: canvasSizeLayer.frameX
                    y: canvasSizeLayer.frameY
                    width: canvasSizeLayer.targetW
                    height: canvasSizeLayer.targetH
                    clip: true

                    Checkerboard {
                        anchors.fill: parent
                        square: 10
                        visible: view.backgroundTransparent
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: !view.backgroundTransparent
                        color: view.backgroundColor
                    }
                    Image {
                        x: canvasSizeOptionsPanel.imageOffsetX * view.zoom
                        y: canvasSizeOptionsPanel.imageOffsetY * view.zoom
                        width: Math.max(1, view.displayedWidth * view.zoom)
                        height: Math.max(1, view.displayedHeight * view.zoom)
                        source: canvas.source
                        asynchronous: false
                        cache: false
                        fillMode: Image.Stretch
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1.5
                        border.color: view.theme.accent
                    }
                }
            }

            // Live 60 fps GPU preview for Transform (Free Transform and Scale
            // Canvas). Uses the same <= 2048 px preview texture as `canvas` so
            // even 50 MP documents transform smoothly; full-resolution pixels
            // are only resampled by Core when Apply is pressed.
            Item {
                id: transformCanvasLayer
                objectName: "transformCanvasLayer"
                anchors.fill: parent
                visible: view.transformFrameShown

                readonly property var activeRect: view.transformRect()
                                                  || ({ x: 0, y: 0,
                                                        width: view.documentWidth,
                                                        height: view.documentHeight })

                // Free Transform: fixed document frame with background fill
                // (or checkerboard) behind the transformed image, clipped to
                // the document bounds.
                Item {
                    id: freeTransformFrame
                    objectName: "freeTransformFrame"
                    visible: view.transformMode === "free"
                    clip: true
                    x: view.docToHostX(0)
                    y: view.docToHostY(0)
                    width: Math.max(1, view.documentWidth * view.zoom)
                    height: Math.max(1, view.documentHeight * view.zoom)

                    Checkerboard {
                        anchors.fill: parent
                        visible: view.backgroundTransparent
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: !view.backgroundTransparent
                        color: view.backgroundColor
                    }
                    Image {
                        id: freeTransformImage
                        objectName: "freeTransformImage"
                        x: transformCanvasLayer.activeRect.x * view.zoom
                        y: transformCanvasLayer.activeRect.y * view.zoom
                        width: Math.max(1, transformCanvasLayer.activeRect.width * view.zoom)
                        height: Math.max(1, transformCanvasLayer.activeRect.height * view.zoom)
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: canvas.source
                    }
                }

                // Scale Canvas: the image scales directly to the bounding box
                // at the current zoom without triggering `autoFit`.
                Image {
                    id: scaleTransformImage
                    objectName: "scaleTransformImage"
                    visible: view.transformMode === "scale"
                    x: view.docToHostX(transformCanvasLayer.activeRect.x)
                    y: view.docToHostY(transformCanvasLayer.activeRect.y)
                    width: Math.max(1, transformCanvasLayer.activeRect.width * view.zoom)
                    height: Math.max(1, transformCanvasLayer.activeRect.height * view.zoom)
                    fillMode: Image.Stretch
                    asynchronous: false
                    cache: false
                    source: canvas.source
                }
            }

            // Live 60 fps GPU preview for Custom Rotate: expands the background
            // canvas to the rotated bounding box using the Editor's shared background.
            Item {
                id: rotateCanvasLayer
                objectName: "rotateCanvasLayer"
                anchors.fill: parent
                visible: view.rotateFrameShown

                readonly property real centerX: view.docToHostX(view.documentWidth / 2)
                readonly property real centerY: view.docToHostY(view.documentHeight / 2)
                readonly property real boxW: Math.max(1, view.rotatedWidth * view.zoom)
                readonly property real boxH: Math.max(1, view.rotatedHeight * view.zoom)

                Item {
                    id: rotateBoundsFrame
                    objectName: "rotateBoundsFrame"
                    x: rotateCanvasLayer.centerX - width / 2
                    y: rotateCanvasLayer.centerY - height / 2
                    width: rotateCanvasLayer.boxW
                    height: rotateCanvasLayer.boxH
                    clip: true

                    Checkerboard {
                        anchors.fill: parent
                        visible: view.backgroundTransparent
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: !view.backgroundTransparent
                        color: view.backgroundColor
                    }
                    Image {
                        id: rotatePreviewImage
                        objectName: "rotatePreviewImage"
                        anchors.centerIn: parent
                        width: Math.max(1, view.documentWidth * view.zoom)
                        height: Math.max(1, view.documentHeight * view.zoom)
                        rotation: view.rotateAngle
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: canvas.source
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: view.theme.accent
                    }
                }
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
                    // Space-panning takes priority over crop frame creation and
                    // handle drags (Krita-style navigation).
                    visible: view.tool === "crop" && view.documentReady
                    enabled: visible && !view.spacePanning

                    // The picture outside the rectangle is dimmed, the way a
                    // crop tool shows what is about to be discarded. It covers
                    // the picture only (not the matte), and every edge is
                    // computed from the same document rectangle the frame and
                    // the command read, so they cannot disagree. With no
                    // rectangle yet, the whole picture is dimmed: nothing is
                    // selected, and a bright picture would read as chosen.
                    Item {
                        id: cropShade
                        objectName: "cropShade"
                        anchors.fill: parent
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
                            objectName: "cropShadeEmpty"
                            x: cropShade.pictureX
                            y: cropShade.pictureY
                            width: cropShade.pictureWidth
                            height: cropShade.pictureHeight
                            color: "#000000"
                            opacity: 0.45
                            visible: !view.cropFrameShown
                        }

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
                            view.backgroundTransparent ? 0.5 : 0.9
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
                            color: view.backgroundPreviewColor()
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
                            color: view.backgroundPreviewColor()
                            opacity: cropShade.growOpacity
                        }
                        Rectangle {
                            objectName: "cropGrowLeft"
                            visible: view.cropGrow()
                            x: cropShade.frameLeft
                            y: cropShade.innerTop
                            width: Math.max(0, cropShade.innerLeft - cropShade.frameLeft)
                            height: Math.max(0, cropShade.innerBottom - cropShade.innerTop)
                            color: view.backgroundPreviewColor()
                            opacity: cropShade.growOpacity
                        }
                        Rectangle {
                            objectName: "cropGrowRight"
                            visible: view.cropGrow()
                            x: cropShade.innerRight
                            y: cropShade.innerTop
                            width: Math.max(0, cropShade.frameRight - cropShade.innerRight)
                            height: Math.max(0, cropShade.innerBottom - cropShade.innerTop)
                            color: view.backgroundPreviewColor()
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
                                                mouse.x, mouse.y, mouse.modifiers)
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
                            property var startRect: null

                            onPressed: function(mouse) {
                                var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                startHostX = point.x
                                startHostY = point.y
                                startDocX = view.cropRect.x
                                startDocY = view.cropRect.y
                                startRect = {
                                    x: view.cropRect.x,
                                    y: view.cropRect.y,
                                    width: view.cropRect.width,
                                    height: view.cropRect.height
                                }
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed || !startRect) return
                                var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                var pos = view.computeBoxMoveDrag(
                                    startRect,
                                    (point.x - startHostX) / view.zoom,
                                    (point.y - startHostY) / view.zoom,
                                    mouse.modifiers)
                                view.setCropRect(pos.x, pos.y, startRect.width, startRect.height)
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
                                    property var startRect: null
                                    onPressed: {
                                        startRect = {
                                            x: view.cropRect.x,
                                            y: view.cropRect.y,
                                            width: view.cropRect.width,
                                            height: view.cropRect.height
                                        }
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (!pressed) return
                                        var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                        view.dragCropHandle(modelData.column, modelData.row,
                                                            point.x, point.y,
                                                            mouse.modifiers, startRect)
                                    }
                                }
                            }
                        }
                    }
                }

                // ------------------------------------------- transform frame
                Item {
                    id: transformOverlay
                    objectName: "transformOverlay"
                    anchors.fill: parent
                    visible: view.transformFrameShown
                    enabled: visible && !view.spacePanning

                    // Inside-box drag repositions the image in Free Transform
                    // mode (Shift locks axis, Ctrl snaps to edges/centre/10 px).
                    MouseArea {
                        id: transformMoveArea
                        objectName: "transformMoveArea"
                        visible: view.transformMode === "free"
                        enabled: visible
                        x: view.docToHostX(view.cornerX(0))
                        y: view.docToHostY(view.cornerY(0))
                        width: Math.max(1, view.docToHostX(view.cornerX(1)) - x)
                        height: Math.max(1, view.docToHostY(view.cornerY(2)) - y)
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.SizeAllCursor
                        property real startHostX: 0
                        property real startHostY: 0
                        property var startRect: null

                        onPressed: function(mouse) {
                            var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                            startHostX = point.x
                            startHostY = point.y
                            startRect = view.transformRect()
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed || !startRect) return
                            var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                            view.moveTransformBox(startRect,
                                                  (point.x - startHostX) / view.zoom,
                                                  (point.y - startHostY) / view.zoom,
                                                  mouse.modifiers)
                        }
                    }

                    // The bounding box outline: one thin item per edge.
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
                                cursorShape: (index === 0 || index === 2)
                                             ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                                property var startRect: null
                                onPressed: startRect = view.transformRect()
                                onPositionChanged: function(mouse) {
                                    if (!pressed) return
                                    var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                    view.dragTransformCorner(index, point.x, point.y,
                                                             mouse.modifiers, startRect)
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
                                cursorShape: (index === 0 || index === 2)
                                             ? Qt.SizeVerCursor : Qt.SizeHorCursor
                                property var startRect: null
                                onPressed: startRect = view.transformRect()
                                onPositionChanged: function(mouse) {
                                    if (!pressed) return
                                    var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                    view.dragTransformEdge(index, point.x, point.y,
                                                           mouse.modifiers, startRect)
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
                                    ? view.theme.thumb : view.foregroundColor
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
            value: view.dockWidth
            defaultValue: 300
            direction: -1
            minimum: 220
            maximum: 400
            visible: view.sidebarShown
            onMoved: function(width) {
                view.rightDragging = true
                view.rightPanelWidth = width
            }
            onReleased: function(width) {
                view.rightDragging = false
                view.layoutRequested({ rightWidth: Math.round(width) })
            }
        }

        // -------------------------------------------------- tool options (right)
        // The dock is two places, not one. The top is the armed tool's frame;
        // below it is the document itself — what it is, what was done to it,
        // and the file on disk — as three reference tabs.
        //
        // The reference takes only the height its open page needs and sits at
        // the bottom, so a two-line Info page does not leave a tall empty
        // column, and the tool frame above keeps the rest. The divider is how
        // the user overrules that: it writes a reference height, which is saved
        // with the layout and restored on the next launch. Inside the frame the
        // options start at the top and their verbs sit directly under them; the
        // frame is the same height for every tool, so arming Crop does not move
        // the divider.
        Rectangle {
            id: inspector
            objectName: "editorInspector"
            Layout.preferredWidth: view.dockWidth
            Layout.fillHeight: true
            color: view.theme.surface
            visible: view.sidebarShown

            /// The heading row is the tool zone's minimum.
            readonly property int headerHeight: 34
            /// Height the pinned action row adds, so the options can be capped
            /// before the tabs lose their floor. A hidden tool zone or a tool
            /// with no verbs adds nothing.
            readonly property int actionRowHeight:
                view.toolOptionsVisible
                && (view.tool === "crop" || view.tool === "transform" || view.tool === "rotate"
                    || view.tool === "resize" || view.tool === "canvasSize" || view.tool === "adjust")
                ? cropActions.implicitHeight + 10 : 0
            /// What the reference dock is offered: its page's own height
            /// unless the user dragged the divider, and never more than the
            /// dock can give while the tool frame keeps its room.
            readonly property real referenceCap: Math.max(140, height - 240)
            readonly property real referenceShownHeight: {
                var wanted = view.referenceHeight > 0
                             ? view.referenceHeight : referenceDock.contentHeight
                return Math.max(140, Math.min(wanted, referenceCap))
            }
            /// How tall the options may be: their own content, unless the
            /// frame cannot also keep the action row and 140 px of reference.
            /// Only then do they scroll.
            readonly property real optionsCap: Math.max(
                40,
                Math.max(0, height - referenceShownHeight - headerHeight
                            - actionRowHeight - 10))
            readonly property bool toolOptionsShown:
                view.tool !== "pointer" && view.tool !== "hand" && view.toolOptionsVisible
            /// The tool's name for the heading. The sentence is "… options", so
            /// the heading says whose column this is whether or not a tool is
            /// armed.
            readonly property string toolName:
                view.tool === "pointer"
                ? qsTr("Pointer")
                : (view.tool === "hand"
                   ? qsTr("Hand")
                   : (view.tool === "crop"
                      ? qsTr("Crop")
                      : (view.tool === "transform"
                         ? qsTr("Transform")
                         : (view.tool === "rotate"
                            ? qsTr("Rotate")
                            : (view.tool === "paint"
                               ? (view.paintMode === "eraser" ? qsTr("Eraser") : qsTr("Brush"))
                               : (view.tool === "canvasSize"
                                  ? qsTr("Canvas size")
                                  : (view.tool === "adjust"
                                     ? qsTr("Color & light")
                                     : qsTr("Resize"))))))))
            /// Under this width the tab labels no longer fit in two languages;
            /// the icons and their tooltips carry the tab instead.
            readonly property bool tabsCompact: width < 240

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // ------------------------------------------ tool zone (top)
                // One frame for every tool. Its height is a property of the
                // dock, not of the tool, so arming Crop, Brush or the pointer
                // never moves the reference pages below it. The options and
                // their verbs start at the top of the frame; whatever height
                // the tool does not need stays blank under the verbs, and the
                // divider at the frame's bottom lets the user trade that blank
                // space for reference room.
                ColumnLayout {
                    id: toolZone
                    objectName: "editorToolZone"
                    Layout.fillWidth: true
                    // Settings › Appearance hides this panel like any other; the
                    // reference pages then take the whole dock.
                    visible: view.toolOptionsVisible
                    // The reference dock below is content-sized and pinned to
                    // the bottom, so this frame takes the rest: one height for
                    // every tool, and the divider is where the user moves it.
                    Layout.fillHeight: true
                    Layout.minimumHeight: inspector.headerHeight
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 4
                        Layout.preferredHeight: inspector.headerHeight
                        implicitHeight: inspector.headerHeight
                        spacing: 2

                        // The heading names whose column this is. With the
                        // pointer selected there is no tool, so the header
                        // reports the pointer and the line below says why it is
                        // empty.
                        Label {
                            objectName: "toolOptionsHeading"
                            Layout.fillWidth: true
                            text: qsTr("%1 options").arg(inspector.toolName)
                            color: view.theme.text
                            font.bold: true
                            elide: Text.ElideRight
                        }
                    }

                    // The pointer is a tool with nothing to configure. Saying
                    // so is better than an empty column that reads as a panel
                    // that failed to load.
                    Label {
                        objectName: "pointerNoOptions"
                        Layout.fillWidth: true
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        Layout.bottomMargin: 10
                        visible: view.tool === "pointer" || view.tool === "hand"
                        text: qsTr("This tool has no options.")
                        color: view.theme.textMuted
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }

                    // The options column is wrapped in an Item because a
                    // ScrollView answers a layout with its content's implicit
                    // height: a `Layout.maximumHeight` on it was ignored and a
                    // 430 px window still drew a 362 px ScrollView, pushing the
                    // tabs out of the dock. The host owns the height; the
                    // ScrollView fills it.
                    Item {
                        id: toolOptionsHost
                        objectName: "toolOptionsHost"
                        visible: inspector.toolOptionsShown
                        Layout.fillWidth: true
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        // Natural height, capped by the frame's own room for
                        // options. The 10 px is the gap under the last field,
                        // which a content layout's own margin does not add
                        // inside a ScrollView.
                        Layout.preferredHeight: {
                            if (!visible) return 0
                            return Math.max(40, Math.min(toolOptionsColumn.implicitHeight + 10,
                                                         inspector.optionsCap))
                        }
                        Layout.maximumHeight: Layout.preferredHeight
                        clip: true

                        ScrollView {
                            id: toolOptionsScroll
                            objectName: "toolOptionsScroll"
                            anchors.fill: parent
                            clip: true
                            contentWidth: availableWidth

                            ColumnLayout {
                                id: toolOptionsColumn
                                width: toolOptionsScroll.availableWidth
                                spacing: 10

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

                                // The pair itself lives in the rail; with the
                                // rail showing, this row is the field that
                                // edits the foreground's exact value — a
                                // chooser cannot say `#2f81f7`. With the rail
                                // hidden (Settings › Appearance can put it
                                // away) the compact pair is drawn here too, from
                                // the same component and the same two
                                // properties, so the colours are never
                                // unreachable.
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    ColourPair {
                                        id: optionsColourPair
                                        objectName: "optionsColourPair"
                                        visible: !view.toolsShown
                                        enabled: view.documentReady
                                        theme: view.theme
                                        foreground: view.foregroundColor
                                        background: view.backgroundColor
                                        backgroundTransparent: view.backgroundTransparent
                                        onForegroundClicked: view.openForegroundChooser()
                                        onBackgroundClicked:
                                            view.openBackgroundPopup(optionsColourPair.backgroundBox)
                                        onSwapRequested: {
                                            view.swapColours()
                                            view.forceActiveFocus()
                                        }
                                        onResetRequested: {
                                            view.resetColours()
                                            view.forceActiveFocus()
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Label {
                                            text: qsTr("Foreground")
                                            color: view.theme.textMuted
                                            font.pixelSize: 11
                                        }

                                        // The field is the pair's value, not a
                                        // spacer: the hex text is seven
                                        // characters, so it keeps a field's
                                        // width instead of stretching across the
                                        // panel as a white bar.
                                        TextField {
                                            id: foregroundColorField
                                            objectName: "foregroundColorField"
                                            Layout.preferredWidth: 118
                                            Layout.maximumWidth: 118
                                            font.pixelSize: 12
                                            text: view.foregroundColor
                                            placeholderText: qsTr("#rrggbb")
                                            onEditingFinished: {
                                                view.setForegroundColor(text)
                                                text = view.foregroundColor
                                                // Enter belongs to the field; the next key
                                                // should reach the canvas keys again.
                                                view.forceActiveFocus()
                                            }
                                        }
                                    }
                                }

                                // The field and the swatch follow X and D even after
                                // the field has been typed into, which breaks its
                                // initial binding.
                                Connections {
                                    target: view
                                    function onForegroundColorChanged() {
                                        if (!foregroundColorField.activeFocus)
                                        foregroundColorField.text = view.foregroundColor
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
                                            border.width: view.foregroundColor === modelData ? 2 : 1
                                            border.color: view.foregroundColor === modelData
                                            ? view.theme.accent : view.theme.border

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    view.setForegroundColor(modelData)
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
                                // Each tool's options are one block that is
                                // hidden as a whole: a layout keeps the space of
                                // a hidden child inside a visible column, so a
                                // shared block left the transform panel below
                                // three hundred pixels of invisible crop fields.
                                visible: view.tool === "crop"
                                spacing: 10

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 3
                                    columnSpacing: 6
                                    rowSpacing: 4

                                    Label {
                                        text: qsTr("X")
                                        color: view.theme.textMuted
                                    }
                                    UnitField {
                                        id: cropX
                                        objectName: "cropX"
                                        Layout.fillWidth: true
                                        font.pixelSize: 12
                                        text: "0"
                                        // A place is a pixel coordinate, never a
                                        // fraction of the picture.
                                        unitsVisible: false
                                        minimumPixels: view.cropGrow() ? -20000 : 0
                                        maximumPixels: 20000
                                    }
                                    // A place has no lock: the locks are about the
                                    // shape, not about where it sits.
                                    Item {}

                                    Label {
                                        text: qsTr("Y")
                                        color: view.theme.textMuted
                                    }
                                    UnitField {
                                        id: cropY
                                        objectName: "cropY"
                                        Layout.fillWidth: true
                                        font.pixelSize: 12
                                        text: "0"
                                        unitsVisible: false
                                        minimumPixels: view.cropGrow() ? -20000 : 0
                                        maximumPixels: 20000
                                    }
                                    Item {}

                                    Label {
                                        text: qsTr("Width")
                                        color: view.theme.textMuted
                                    }
                                    UnitField {
                                        id: cropWidthField
                                        objectName: "cropWidth"
                                        Layout.fillWidth: true
                                        font.pixelSize: 12
                                        placeholderText: cropWidthField.percent
                                        ? "100" : (view.hasDocument ? String(view.editor.width) : "0")
                                        unitReference: view.documentWidth
                                        minimumPixels: 1
                                        maximumPixels: 20000
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
                                    UnitField {
                                        id: cropHeightField
                                        objectName: "cropHeight"
                                        Layout.fillWidth: true
                                        font.pixelSize: 12
                                        placeholderText: cropHeightField.percent
                                        ? "100" : (view.hasDocument ? String(view.editor.height) : "0")
                                        unitReference: view.documentHeight
                                        minimumPixels: 1
                                        maximumPixels: 20000
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

                                // A growing crop paints its new margin with the
                                // Editor's background — the same colour a resize
                                // pads with, so "the stuff added around the
                                // picture" is one answer rather than a list per
                                // tool. Only shown in Grow: in Center there is no
                                // leftover to paint, and an unused control would
                                // ask a question the user cannot answer. The
                                // swatch is the way to change it from here; the
                                // pair in the rail is the other.
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: view.tool === "crop" && view.cropGrow()
                                    spacing: 8

                                    Label {
                                        text: qsTr("Grow fill color")
                                        color: view.theme.textMuted
                                    }
                                    Item { Layout.fillWidth: true }
                                    Rectangle {
                                        id: cropBackgroundSwatch
                                        objectName: "cropBackgroundSwatch"
                                        Layout.preferredWidth: 24
                                        Layout.preferredHeight: 24
                                        radius: 4
                                        color: view.backgroundTransparent
                                               ? "transparent" : view.backgroundColor
                                        border.width: cropSwatchArea.containsMouse ? 2 : 1
                                        border.color: cropSwatchArea.containsMouse
                                                      ? view.theme.accent : view.theme.border
                                        Accessible.role: Accessible.Button
                                        Accessible.name: qsTr("Background color (new canvas)")
                                        Checkerboard {
                                            objectName: "cropBackgroundCheckerboard"
                                            anchors.fill: parent
                                            visible: view.backgroundTransparent
                                            square: 5
                                        }
                                        MouseArea {
                                            id: cropSwatchArea
                                            objectName: "cropBackgroundArea"
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            ToolTip.visible: containsMouse
                                            ToolTip.delay: 500
                                            ToolTip.text: qsTr("Background color (new canvas)")
                                            onClicked: view.openBackgroundPopup(cropBackgroundSwatch)
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
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                visible: view.tool === "crop"
                                color: view.theme.border
                            }

                            // Transform: Krita-style icon mode selector (Free
                            // Transform vs Scale Canvas), live bounding-box
                            // dimensions, and background fill for Free mode.
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: view.tool === "transform"
                                spacing: 8

                                RowLayout {
                                    objectName: "transformModeSwitch"
                                    Layout.fillWidth: true
                                    spacing: 6

                                    ToolRailButton {
                                        objectName: "transformModeFree"
                                        theme: view.theme
                                        iconSource: "icons/transform-free.svg"
                                        active: view.transformMode === "free"
                                        enabled: view.documentReady
                                        tooltip: qsTr("Free transform — scale and move inside the canvas")
                                        onClicked: view.setTransformMode("free")
                                    }
                                    ToolRailButton {
                                        objectName: "transformModeScale"
                                        theme: view.theme
                                        iconSource: "icons/transform-scale.svg"
                                        active: view.transformMode === "scale"
                                        enabled: view.documentReady
                                        tooltip: qsTr("Scale canvas — resize image dimensions directly")
                                        onClicked: view.setTransformMode("scale")
                                    }
                                    Item { Layout.fillWidth: true }
                                }

                                Label {
                                    objectName: "transformSizeReadout"
                                    Layout.fillWidth: true
                                    color: view.theme.text
                                    font.pixelSize: 12
                                    text: {
                                        var r = view.transformRect()
                                        if (!r) return "—"
                                        var size = Math.round(r.width) + " × " + Math.round(r.height) + " px"
                                        if (view.transformMode === "free") {
                                            return size + "  (" + Math.round(r.x) + ", " + Math.round(r.y) + ")"
                                        }
                                        return size
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: view.theme.textMuted
                                    font.pixelSize: 11
                                    text: qsTr("Shift: ratio · Alt: center · Ctrl: snap")
                                }
                            }

                            // Custom rotate options (uses the Editor's shared
                            // background colour directly — no separate swatch).
                            ColumnLayout {
                                objectName: "rotateOptions"
                                Layout.fillWidth: true
                                spacing: 10
                                visible: view.tool === "rotate"

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Label {
                                        text: qsTr("Angle")
                                        color: view.theme.textMuted
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        objectName: "rotateAngleValue"
                                        text: view.rotateAngle.toFixed(1) + "°"
                                        color: view.theme.text
                                        font.bold: true
                                    }
                                }

                                Slider {
                                    id: rotateAngleSlider
                                    objectName: "rotateAngleSlider"
                                    Layout.fillWidth: true
                                    from: -180
                                    to: 180
                                    stepSize: 0.5
                                    value: view.rotateAngle
                                    focusPolicy: Qt.NoFocus
                                    onMoved: view.rotateAngle = Math.round(value * 2) / 2
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Repeater {
                                        model: [-45, -15, 15, 45]
                                        delegate: Button {
                                            required property int modelData
                                            Layout.fillWidth: true
                                            text: (modelData > 0 ? "+" : "") + modelData + "°"
                                            focusPolicy: Qt.NoFocus
                                            padding: 4
                                            onClicked: {
                                                var next = view.rotateAngle + modelData
                                                while (next > 180) next -= 360
                                                while (next < -180) next += 360
                                                view.rotateAngle = next
                                            }
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Label {
                                        text: qsTr("Output size")
                                        color: view.theme.textMuted
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        objectName: "rotateOutputSize"
                                        text: view.rotatedWidth + " × " + view.rotatedHeight
                                        color: view.theme.text
                                    }
                                }
                            }

                            EditorResizePanel {
                                id: resizeOptionsPanel
                                Layout.fillWidth: true
                                visible: view.tool === "resize"
                                theme: view.theme
                                sourceWidth: view.documentWidth
                                sourceHeight: view.documentHeight
                            }

                            EditorCanvasSizePanel {
                                id: canvasSizeOptionsPanel
                                Layout.fillWidth: true
                                visible: view.tool === "canvasSize"
                                theme: view.theme
                                sourceWidth: view.documentWidth
                                sourceHeight: view.documentHeight
                            }

                            ColorAdjustPanel {
                                id: adjustOptionsPanel
                                objectName: "editorColorAdjustPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "adjust"
                                theme: view.theme
                                viewOnly: false
                                showReset: false
                            }
                        }
                    }
                    }

                    GridLayout {
                        id: cropActions
                        objectName: "cropActions"
                        visible: (view.tool === "crop" || view.tool === "transform" || view.tool === "rotate"
                                  || view.tool === "resize" || view.tool === "canvasSize"
                                  || view.tool === "adjust")
                                 && view.toolOptionsVisible
                        Layout.fillWidth: true
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        Layout.topMargin: 6
                        Layout.bottomMargin: 10
                        columns: (view.tool === "transform" || view.tool === "rotate"
                                  || view.tool === "resize" || view.tool === "canvasSize"
                                  || view.tool === "adjust")
                                 ? 2
                                 : (view.cropActionsStack ? 2 : 3)
                        columnSpacing: 6
                        rowSpacing: 6

                        Button {
                            id: applyCropButton
                            objectName: "applyCrop"
                            text: qsTr("Apply")
                            Layout.fillWidth: true
                            Layout.columnSpan: view.cropActionsStack ? 2 : 1
                            visible: view.tool === "crop"
                            focusPolicy: Qt.NoFocus
                            enabled: view.cropCanApply()
                            onClicked: view.applyCrop()
                        }
                        Button {
                            id: resetCropButton
                            objectName: "resetCropOptions"
                            text: qsTr("Reset")
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady
                            onClicked: view.resetCropOptions()
                        }
                        Button {
                            id: clearCropButton
                            objectName: "clearCrop"
                            text: qsTr("Clear")
                            Layout.fillWidth: true
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
                            onClicked: view.applyTransform()
                        }
                        Button {
                            objectName: "resetTransformFields"
                            text: qsTr("Reset")
                            Layout.fillWidth: true
                            visible: view.tool === "transform"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady
                            onClicked: view.resetTransformCorners()
                        }
                        Button {
                            objectName: "applyRotateAngle"
                            text: qsTr("Apply")
                            Layout.fillWidth: true
                            visible: view.tool === "rotate"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && view.rotateHasChange()
                            onClicked: view.applyRotateAngle()
                        }
                        Button {
                            objectName: "resetRotateAngle"
                            text: qsTr("Reset")
                            Layout.fillWidth: true
                            visible: view.tool === "rotate"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && view.rotateHasChange()
                            onClicked: view.rotateAngle = 0
                        }
                        Button {
                            objectName: "applyResizePanel"
                            text: qsTr("Apply")
                            Layout.fillWidth: true
                            visible: view.tool === "resize"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && resizeOptionsPanel.changed
                            onClicked: view.applyResizePanel()
                        }
                        Button {
                            objectName: "resetResizePanel"
                            text: qsTr("Reset")
                            Layout.fillWidth: true
                            visible: view.tool === "resize"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && resizeOptionsPanel.changed
                            onClicked: resizeOptionsPanel.reset()
                        }
                        Button {
                            objectName: "applyCanvasSizePanel"
                            text: qsTr("Apply")
                            Layout.fillWidth: true
                            visible: view.tool === "canvasSize"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && canvasSizeOptionsPanel.changed
                            onClicked: view.applyCanvasSizePanel()
                        }
                        Button {
                            objectName: "resetCanvasSizePanel"
                            text: qsTr("Reset")
                            Layout.fillWidth: true
                            visible: view.tool === "canvasSize"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && canvasSizeOptionsPanel.changed
                            onClicked: canvasSizeOptionsPanel.reset()
                        }
                        Button {
                            objectName: "applyColorAdjust"
                            text: qsTr("Apply")
                            Layout.fillWidth: true
                            visible: view.tool === "adjust"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && adjustOptionsPanel.changed
                            onClicked: view.applyColorAdjust()
                        }
                        Button {
                            objectName: "resetColorAdjust"
                            text: qsTr("Reset")
                            Layout.fillWidth: true
                            visible: view.tool === "adjust"
                            focusPolicy: Qt.NoFocus
                            enabled: view.documentReady && adjustOptionsPanel.changed
                            onClicked: adjustOptionsPanel.reset()
                        }
                    }

                    // Whatever the frame leaves after the fields and their
                    // verbs is blank, above the divider and the reference
                    // pages. A short tool therefore keeps its buttons under its
                    // own options instead of against the bottom edge.
                    Item {
                        objectName: "toolZoneSpacer"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }

                // The handle between the two halves of the dock. It writes the
                // height of the reference dock *below* it (hence `direction:
                // -1`): dragging up gives the pages more room, down gives the
                // tool frame more. A double-click goes back to 0, the default
                // answer "as tall as the open page needs". The number is saved
                // with the layout, once, when the drag ends.
                PanelSplitter {
                    objectName: "editorToolZoneDivider"
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    orientation: Qt.Vertical
                    // Nothing to divide against when the tool frame is hidden
                    // or every reference page is hidden.
                    visible: view.toolOptionsVisible && view.shownReferenceCount > 0
                    value: view.referenceHeight
                    defaultValue: 0
                    direction: -1
                    minimum: 0
                    maximum: Math.max(0, inspector.height - 240)
                    onMoved: function(height) {
                        view.referenceDragging = true
                        view.referenceHeight = Math.max(0, Math.round(height))
                    }
                    onReleased: function(height) {
                        view.referenceDragging = false
                        view.layoutRequested({ editorReferenceHeight: Math.max(0, Math.round(height)) })
                    }
                }

                // -------------------------------------- reference zone (tabs)
                // The shared dock: a strip and one page at a time. It takes
                // only the height of the page it is showing (or the height the
                // divider remembers) and sits at the bottom of the column, so a
                // short Info page does not grow into the tool frame above it. A
                // hidden page keeps its slot inside the dock, so the checklist
                // never renumbers the other pages.
                RightDock {
                    id: referenceDock
                    objectName: "editorReferenceDock"
                    Layout.fillWidth: true
                    // Not `fillHeight`: the dock asks for the page's own height
                    // and the tool frame above absorbs the rest.
                    Layout.fillHeight: false
                    Layout.alignment: Qt.AlignBottom
                    Layout.preferredHeight: inspector.referenceShownHeight
                    Layout.minimumHeight: Math.min(140, inspector.referenceShownHeight)
                    visible: view.shownReferenceCount > 0
                    theme: view.theme
                    backgroundColor: "transparent"
                    borderColor: "transparent"
                    tabs: view.rightTabEntries
                    currentKey: view.rightTab
                    compact: inspector.tabsCompact
                    stripObjectName: "editorRightTabs"
                    pagesObjectName: "editorReferencePages"
                    /// The open page's natural height, measured by the view
                    /// because it owns the pages and knows which one is drawn.
                    pageContentHeight: view.referencePageHeight
                    onActivated: function(key) { view.showRightTab(key) }

                    // ------------------------------------ Info
                    // What the document is: name, size, save target. The words
                    // are the same the pointer column carried; they just live
                    // in a tab now so a tool cannot hide them.
                    ScrollView {
                        id: infoPanel
                        objectName: "infoPanel"
                        contentWidth: availableWidth
                        clip: true

                        InfoPanel {
                            id: infoPage
                            width: infoPanel.availableWidth
                            theme: view.theme
                            editor: view.editor
                            hasDocument: view.hasDocument
                            sizeText: view.sizeLabel()
                            saving: view.saving
                        }
                    }

                    // ------------------------------------ History
                    // The steps applied in this session, oldest first. Core
                    // owns the list and the undo/redo state; the panel only
                    // draws the translated labels.
                    Item {
                        objectName: "historyPanel"

                        HistoryPanel {
                            id: historyPage
                            anchors.fill: parent
                            theme: view.theme
                            history: view.history
                            hasDocument: view.hasDocument
                            language: view.state.language || ""
                        }
                    }

                    // ------------------------------------ Original
                    // The file on disk: the source until a save moves it, and
                    // the rewritten file after every save. This is not the
                    // working preview — the preview is what Core holds in
                    // memory, this is what a file manager would show.
                    ScrollView {
                        id: originalPanel
                        objectName: "originalPanel"
                        contentWidth: availableWidth
                        clip: true

                        PreviewPanel {
                            id: originalPage
                            width: originalPanel.availableWidth
                            theme: view.theme
                            book: thumbs
                            path: view.hasDocument ? (view.editor.savePath || "") : ""
                            modified: view.editor ? (view.editor.fileModified || 0) : 0
                            fileSize: view.editor ? (view.editor.fileSize || 0) : 0
                            thumbnailable: view.hasDocument
                            heading: qsTr("Saved file")
                            caption: {
                                if (!view.hasDocument) return ""
                                var name = (view.editor.savePath || "").split("/").pop()
                                return name + " · "
                                       + view.theme.formatBytes(view.editor.fileSize || 0)
                            }
                            captionObjectName: "originalCaption"
                            thumbnailObjectName: "originalThumbnail"
                            placeholder: qsTr("No saved file yet")
                        }
                    }
                }
            }
        }
    }

    /// Resize is a dialog, not a tool: choosing a size is a question with a
    /// beginning and an end, so the form owns its own fields while the document
    /// under it stays untouched. The palette button opens it; nothing on the
    /// canvas changes mode, and the form draws no preview — the picture does
    /// not move until Apply.
    CanvasSizeDialog {
        id: canvasSizeDialog
        objectName: "canvasSizeDialog"
        theme: view.theme
        documentWidth: view.documentWidth
        documentHeight: view.documentHeight
        documentReady: view.documentReady
        backgroundColor: view.backgroundColor
        backgroundTransparent: view.backgroundTransparent
        documentIsJpeg: view.documentIsJpeg
        onBackgroundTransparentRequested: view.setBackgroundTransparent()
        onBackgroundColorRequested: function(value) { view.setBackgroundColor(value) }
        onApplyRequested: function(width, height, anchor) {
            view.command({
                type: "editor_canvas_size",
                width: width,
                height: height,
                anchor: anchor,
                fill: view.backgroundTransparent ? null : view.backgroundBytes(),
                fill_alpha: view.backgroundAlpha()
            })
        }
    }

    ResizeDialog {
        id: resizeDialog
        objectName: "resizeDialog"
        theme: view.theme
        documentWidth: view.documentWidth
        documentHeight: view.documentHeight
        documentReady: view.documentReady
        presets: view.sizePresets
        // The form does not own a background: it names the role the padding
        // plays and every answer is stored on the Editor's one pair.
        backgroundColor: view.backgroundColor
        backgroundTransparent: view.backgroundTransparent
        documentIsJpeg: view.documentIsJpeg
        onBackgroundTransparentRequested: view.setBackgroundTransparent(true)
        onBackgroundColorRequested: function(value) { view.setBackgroundColor(value) }
        onResizeRequested: function(width, height, fill, fillAlpha, filter, mode) {
            view.command({
                type: "editor_resize",
                width: width,
                height: height,
                fill: fill,
                fill_alpha: fillAlpha,
                mode: mode,
                filter: filter
            })
        }
    }

    /// The foreground's chooser. One instance for every pair, because there is
    /// one foreground: a click says which role is being changed, never which
    /// copy of it. A cancelled chooser changes nothing, and the box keeps
    /// showing what the next mark would get.
    ColorPickerDialog {
        id: foregroundColorDialog
        objectName: "foregroundColorDialog"
        theme: view.theme
        title: qsTr("Foreground color")
        selectedColor: view.foregroundColor
        onAccepted: {
            view.setForegroundColor(view.colorText(selectedColor))
            view.forceActiveFocus()
        }
    }

    /// New canvas, as a list: transparent, three named colours, or the chooser.
    /// One instance serves the rail, the Crop panel and the Resize form, so a
    /// border grown by hand and a padded resize cannot describe two different
    /// backgrounds.
    BackgroundPopup {
        id: backgroundPopup
        objectName: "backgroundPopup"
        theme: view.theme
        transparent: view.backgroundTransparent
        colour: view.backgroundColor
        alphaLostWarning: view.documentIsJpeg
        onTransparentPicked: view.setBackgroundTransparent(true)
        onColourPicked: function(value) { view.setBackgroundColor(value) }
        onCustomPicked: view.openBackgroundChooser()
    }

    /// The chooser behind `Custom color…`. Uses the shared `ColorPickerDialog`
    /// built on `DialogFrame`.
    ColorPickerDialog {
        id: backgroundColorDialog
        objectName: "backgroundColorDialog"
        theme: view.theme
        title: qsTr("Background color")
        selectedColor: view.backgroundColor
        onAccepted: {
            view.setBackgroundColor(view.colorText(selectedColor))
            view.forceActiveFocus()
        }
    }

    /// Canvas backdrop list (checkerboard, white, black, gray, custom).
    BackgroundPopup {
        id: canvasBgPopup
        objectName: "canvasBgPopup"
        theme: view.theme
        transparent: !view.canvasBgUseTheme && view.canvasBgChecker
        colour: view.canvasBgColor
        onTransparentPicked: {
            view.canvasBgUseTheme = false
            view.canvasBgChecker = true
        }
        onColourPicked: function(value) {
            view.canvasBgUseTheme = false
            view.canvasBgChecker = false
            view.canvasBgColor = value
        }
        onCustomPicked: view.openCanvasBgChooser()
    }

    ColorPickerDialog {
        id: canvasBgColorDialog
        objectName: "canvasBgColorDialog"
        theme: view.theme
        title: qsTr("Canvas background")
        selectedColor: view.canvasBgColor
        onAccepted: {
            view.canvasBgUseTheme = false
            view.canvasBgChecker = false
            view.canvasBgColor = view.colorText(selectedColor)
            view.forceActiveFocus()
        }
    }

    /// The actions the mini toolbar cannot show. Same actions, labels and keys
    /// as the toolbar buttons it replaces; see `Viewer.qml` for why the labels
    /// come from `Theme.menuEntries`.
    AppMenu {
        id: editorOverflow
        objectName: "editorOverflowMenu"
        theme: view.theme
        implicitWidth: view.theme.menuWidth(view.theme.menuLabelWidths,
                                            view.theme.menuShortcutWidths)

        MenuItem {
            text: view.theme.menuEntries[31]
            icon.name: "zoom-out-symbolic"
            enabled: view.documentReady
            onTriggered: view.zoomOut()
            MenuShortcut { text: "-" }
        }
        MenuItem {
            text: view.theme.menuEntries[30]
            icon.name: "zoom-in-symbolic"
            enabled: view.documentReady
            onTriggered: view.zoomIn()
            MenuShortcut { text: "+" }
        }
        MenuItem {
            text: view.theme.menuEntries[21]
            icon.name: "zoom-fit-best-symbolic"
            enabled: view.documentReady
            onTriggered: view.fit()
        }
        MenuItem {
            text: view.theme.menuEntries[22]
            icon.name: "zoom-original-symbolic"
            enabled: view.documentReady
            onTriggered: view.actualSize()
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[35]
            icon.name: "document-save-as-symbolic"
            enabled: view.documentReady && !view.saving
            onTriggered: view.requestSaveAs()
            MenuShortcut { text: "Ctrl+Shift+S" }
        }
        MenuItem {
            text: view.theme.menuEntries[36]
            icon.name: "document-send-symbolic"
            enabled: view.documentReady && !view.saving
            onTriggered: view.openExportDialog()
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[37]
            icon.name: "document-revert-symbolic"
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
    }

    /// Export is a delivery copy: it never moves the document's save target.
    /// The options are the ones ADR 0004 deferred — a JPEG quality and the
    /// source's metadata — and the dialog says which target honours them.
    DialogFrame {
        id: exportDialog
        objectName: "exportDialog"
        namePrefix: "export"
        title: qsTr("Export image")
        preferredWidth: 460
        onCloseRequested: exportDialog.close()

        /// The copy's destination and name. Browse asks the shell, which owns
        /// the platform chooser; a typed path and a chosen one are the same
        /// field.
        FormRow {
            theme: view.theme
            label: qsTr("File")
            labelWidth: exportDialog.labelWidth
            Layout.fillWidth: true

            TextField {
                id: exportPathField
                objectName: "exportPathField"
                Layout.fillWidth: true
                text: view.exportPath
                placeholderText: qsTr("Choose where the copy goes")
                onTextEdited: view.exportPath = text
            }
            PanelAction {
                objectName: "exportBrowse"
                theme: view.theme
                text: qsTr("Browse…")
                implicitWidth: 88
                onClicked: view.requestExportPath()
            }
        }

        FormRow {
            theme: view.theme
            label: qsTr("Quality")
            labelWidth: exportDialog.labelWidth
            Layout.fillWidth: true

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

        FormRow {
            theme: view.theme
            // Not the bare "Size": the browser's column header owns that
            // word, and the catalogue gives one translation per English
            // string. This row is about the copy's output.
            label: qsTr("Output size")
            labelWidth: exportDialog.labelWidth
            Layout.fillWidth: true

            ComboBox {
                id: exportSizeCombo
                objectName: "exportSize"
                Layout.fillWidth: true
                model: view.exportEdgeLabels
                // `currentIndex` is set in `openExportDialog`, never bound:
                // ComboBox owns the index once the user picks a row, and a
                // binding would be broken by that first pick.
                onActivated: view.chooseExportSize(index)
            }
        }

        FormCheck {
            id: exportMetadataBox
            theme: view.theme
            objectName: "exportMetadata"
            Layout.fillWidth: true
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

        footer: DialogFooter {
            namePrefix: "export"
            theme: view.theme
            height: exportDialog.footerHeight

            Item { Layout.fillWidth: true }
            PanelAction {
                objectName: "exportCancel"
                theme: view.theme
                text: qsTr("Cancel")
                implicitWidth: 88
                onClicked: exportDialog.close()
            }
            PanelAction {
                objectName: "exportConfirm"
                theme: view.theme
                text: qsTr("Export")
                implicitWidth: 88
                primary: true
                enabled: view.exportPathValid
                onClicked: view.confirmExport()
            }
        }
    }
}
