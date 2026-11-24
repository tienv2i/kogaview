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
        if (view.rightTabIndex === 1)
            return historyPage ? historyPage.implicitHeight : 0
        if (view.rightTabIndex === 2)
            return originalPage ? originalPage.implicitHeight : 0
        if (view.rightTabIndex === 0)
            return infoPage ? infoPage.implicitHeight : 0
        return 0
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
    /// True when the open document has more than one raster layer.
    readonly property bool hasMultipleLayers: !!(view.editor && view.editor.layers && view.editor.layers.length > 1)
    /// Currently selected layer ID; switching active layer while Transform is
    /// open automatically snaps the bounding box to the newly selected layer.
    readonly property int activeLayerId: view.editor ? (view.editor.activeLayerId || 0) : 0
    onActiveLayerIdChanged: {
        if (view.tool === "transform") view.resetTransformCorners()
    }
    /// True when a raster selection mask is active on the open document.
    readonly property bool hasSelection: !!(view.editor && view.editor.hasSelection)
    /// Krita-style selection visualization: `"ants"` (animated fine marching ants)
    /// or `"mask"` (translucent red overlay on unselected pixels).
    property string selectionDisplayMode: "ants"
    property bool selectionAntsPhase: false
    readonly property bool isColorFilterTool:
        view.tool === "adjust" || view.tool === "hsv"
        || view.tool === "curves" || view.tool === "colorBalance"
    /// True while any non-blocking Color Adjustment filter dialog is open:
    /// canvas Pan/Zoom stays active while all buttons outside the dialog are locked.
    readonly property bool filterDialogOpen:
        (typeof hsvDialog !== "undefined" && hsvDialog && hsvDialog.opened)
        || (typeof curvesDialog !== "undefined" && curvesDialog && curvesDialog.opened)
        || (typeof colorBalanceDialog !== "undefined" && colorBalanceDialog && colorBalanceDialog.opened)

    Timer {
        interval: 380
        repeat: true
        running: view.visible && view.hasSelection && view.selectionDisplayMode === "ants"
                 && !view.transformFrameShown && !view.rotateFrameShown
                 && !view.resizeFrameShown && !view.canvasSizeFrameShown
        onTriggered: view.selectionAntsPhase = !view.selectionAntsPhase
    }

    /// Krita-style K (darker) / L (lighter) quick foreground value nudge while painting.
    function nudgeForegroundValue(deltaV) {
        var bytes = view.foregroundBytes()
        var r = bytes[0] / 255.0, g = bytes[1] / 255.0, b = bytes[2] / 255.0
        var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
        var h = 0
        if (d > 1e-6) {
            if (max === r) h = 60 * (((g - b) / d) % 6)
            else if (max === g) h = 60 * (((b - r) / d) + 2)
            else h = 60 * (((r - g) / d) + 4)
            if (h < 0) h += 360
        }
        var s = max > 1e-6 ? d / max : 0
        var v = Math.max(0.0, Math.min(1.0, max + deltaV))
        var c = v * s
        var x = c * (1 - Math.abs((h / 60) % 2 - 1))
        var m = v - c
        var nr = 0, ng = 0, nb = 0
        if (h < 60) { nr = c; ng = x }
        else if (h < 120) { nr = x; ng = c }
        else if (h < 180) { ng = c; nb = x }
        else if (h < 240) { ng = x; nb = c }
        else if (h < 300) { nr = x; nb = c }
        else { nr = c; nb = x }
        function hex2(u) {
            var s2 = Math.max(0, Math.min(255, Math.round(u * 255))).toString(16)
            return s2.length < 2 ? "0" + s2 : s2
        }
        view.setForegroundColor("#" + hex2(nr + m) + hex2(ng + m) + hex2(nb + m))
    }
    readonly property string selectionBoundsKey: {
        var sb = view.editor ? view.editor.selectionBounds : null
        return (sb && sb.length === 4) ? sb.join(",") : ""
    }
    onSelectionBoundsKeyChanged: {
        if (view.tool === "transform") view.resetTransformCorners()
    }
    /// Selection tool shape (`"rect"` | `"ellipse"` | `"lasso"` | `"wand"`), combine mode, and feather radius (px).
    property string selectShape: "rect"
    property string selectMode: "replace"
    property int selectFeather: 0
    property int wandTolerance: 32
    property bool wandContiguous: true
    property bool wandSampleAllLayers: true
    property int lastClipboardExportRev: 0
    readonly property int clipboardExportRev: view.editor ? (view.editor.clipboardExportRevision || 0) : 0
    onClipboardExportRevChanged: {
        if (view.clipboardExportRev > view.lastClipboardExportRev
                && view.editor && view.editor.clipboardExportPath) {
            view.lastClipboardExportRev = view.clipboardExportRev
            view.copyImage(view.editor.clipboardExportPath)
        }
    }
    /// Target mode for layer-capable Editor tools (`"active_layer"` | `"whole_image"`).
    property string toolApplyTarget: "active_layer"
    /// Target mode for AI tools (`"active_layer"` | `"whole_image"` | `"new_layer"`).
    property string aiApplyTarget: "active_layer"
    function effectiveToolTarget() {
        return view.hasMultipleLayers ? view.toolApplyTarget : "whole_image"
    }
    function effectiveAiTarget() {
        return view.aiApplyTarget
    }
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
    /// Mode inside the unified Image Size tool (`"resize"` | `"canvasSize"`).
    /// Document-level only: never affected by active layer or selection mask.
    property string imageSizeMode: "resize"
    property string transformMode: "free"
    /// Live rotation angle (degrees) for Transform Free mode.
    property real transformRotation: 0
    /// Keep aspect ratio when editing W/H in the Transform Each panel.
    property bool transformLockRatio: true
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
    /// Krita-inspired brush preset & dynamics parameters.
    property string brushPresetId: "basic_round"
    property string brushTip: "round"
    property int brushHardness: 85
    property int brushFlow: 100
    property int brushSpacing: 15
    property int brushAngle: 35
    property int brushScatter: 0
    property string liquifyMode: "push" // "push" | "bloat" | "pucker" | "twirl_cw" | "twirl_ccw"
    property int liquifyRadius: 60
    property int liquifyStrength: 55
    property bool brushDynamicsExpanded: false
    readonly property var kritaBrushPresets: [
        { id: "basic_round",   label: qsTr("Basic Round"),   tip: "round", hardness: 85,  flow: 100, spacing: 12, angle: 0,   scatter: 0,   opacity: 100 },
        { id: "soft_round",    label: qsTr("Soft Round"),    tip: "round", hardness: 25,  flow: 75,  spacing: 10, angle: 0,   scatter: 0,   opacity: 90  },
        { id: "airbrush",      label: qsTr("Airbrush"),      tip: "round", hardness: 5,   flow: 30,  spacing: 8,  angle: 0,   scatter: 0,   opacity: 70  },
        { id: "hard_round",    label: qsTr("Hard Round"),    tip: "round", hardness: 100, flow: 100, spacing: 10, angle: 0,   scatter: 0,   opacity: 100 },
        { id: "ink_pen",       label: qsTr("Ink Pen"),       tip: "round", hardness: 100, flow: 100, spacing: 6,  angle: 0,   scatter: 0,   opacity: 100 },
        { id: "watercolor",    label: qsTr("Watercolor"),    tip: "round", hardness: 15,  flow: 22,  spacing: 12, angle: 0,   scatter: 0,   opacity: 55  },
        { id: "calligraphy",   label: qsTr("Calligraphy"),   tip: "flat",  hardness: 95,  flow: 100, spacing: 8,  angle: 35,  scatter: 0,   opacity: 100 },
        { id: "marker",        label: qsTr("Marker"),        tip: "flat",  hardness: 90,  flow: 65,  spacing: 8,  angle: 20,  scatter: 0,   opacity: 70  },
        { id: "highlighter",   label: qsTr("Highlighter"),   tip: "flat",  hardness: 95,  flow: 35,  spacing: 6,  angle: 0,   scatter: 0,   opacity: 45  },
        { id: "flat_oil",      label: qsTr("Flat Oil"),      tip: "flat",  hardness: 65,  flow: 90,  spacing: 12, angle: -20, scatter: 0,   opacity: 95  },
        { id: "pencil",        label: qsTr("Sketch Pencil"), tip: "chalk", hardness: 60,  flow: 55,  spacing: 14, angle: 0,   scatter: 6,   opacity: 85  },
        { id: "charcoal",      label: qsTr("Charcoal"),      tip: "chalk", hardness: 30,  flow: 85,  spacing: 18, angle: 0,   scatter: 18,  opacity: 95  },
        { id: "pastel",        label: qsTr("Pastel"),        tip: "chalk", hardness: 45,  flow: 75,  spacing: 16, angle: 0,   scatter: 12,  opacity: 90  },
        { id: "chalk",         label: qsTr("Chalk"),         tip: "chalk", hardness: 35,  flow: 80,  spacing: 22, angle: 0,   scatter: 15,  opacity: 95  },
        { id: "dry_brush",     label: qsTr("Dry Brush"),     tip: "chalk", hardness: 70,  flow: 45,  spacing: 28, angle: 0,   scatter: 10,  opacity: 80  },
        { id: "spray",         label: qsTr("Spray Paint"),   tip: "spray", hardness: 55,  flow: 55,  spacing: 30, angle: 0,   scatter: 110, opacity: 80  },
        { id: "splatter",      label: qsTr("Splatter"),      tip: "spray", hardness: 85,  flow: 85,  spacing: 45, angle: 0,   scatter: 160, opacity: 95  },
        { id: "pixel_art",     label: qsTr("Pixel Art"),     tip: "pixel", hardness: 100, flow: 100, spacing: 15, angle: 0,   scatter: 0,   opacity: 100 }
    ]
    function applyBrushPreset(preset) {
        view.brushPresetId = preset.id
        view.brushTip = preset.tip
        view.brushHardness = preset.hardness
        view.brushFlow = preset.flow
        view.brushSpacing = preset.spacing
        view.brushAngle = preset.angle
        view.brushScatter = preset.scatter
        view.paintOpacity = preset.opacity
    }
    readonly property bool editingActiveLayerMask: {
        var ed = view.editor
        if (!ed || !ed.layers) return false
        for (var i = 0; i < ed.layers.length; ++i) {
            if (ed.layers[i].id === ed.activeLayerId) {
                return !!(ed.layers[i].hasMask && ed.layers[i].editingMask)
            }
        }
        return false
    }

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
    /// Active Krita-style drawing sub-tool when `tool === "draw"`:
    /// `"line"`, `"polyline"`, `"bezier"`, `"rect"`, `"ellipse"`, `"polygon"`, or `"star"`.
    property string drawShape: "line"
    property bool drawStarIsPolygon: false // Inkscape Star vs Regular Polygon toggle
    property int drawStarCorners: 5        // 3..24 points/sides
    property real drawStarSpokeRatio: 0.45 // 0.10..0.95 inner/outer radius ratio for stars
    property string drawOutlineMode: "foreground"
    property string drawFillMode: "none"
    property int drawStrokeWidth: 4
    property int drawStrokeOpacity: 100
    property int drawFillOpacity: 100
    property bool drawBezierClosed: false

    /// Krita-style Fill (Paint Bucket) tool options.
    property string fillSource: "foreground" // "foreground" | "background"
    property int fillTolerance: 24
    property int fillGrow: 0
    property int fillOpacity: 100
    property bool fillContiguous: true
    property bool fillSampleAllLayers: false

    /// Krita-style Gradient tool options.
    property string gradientShape: "linear" // "linear" | "bilinear" | "radial" | "square" | "conical" | "spiral"
    property string gradientColorMode: "fg_to_bg" // "fg_to_bg" | "fg_to_transparent" | "custom"
    property string gradientPresetId: "fg_to_bg"
    property var gradientStops: [] // [{ pos: 0..1, hex: "#rrggbb", alpha: 0..1 }]
    property int gradientSelectedStop: 0
    property string gradientRepeat: "none" // "none" | "forwards" | "alternating"
    property bool gradientReverse: false
    property bool gradientDither: true
    property string gradientBlendMode: "normal"
    property bool gradientInteractive: true
    property int gradientOpacity: 100
    /// Left-rail Zoom tool mode (`"in"` or `"out"`).
    property string zoomToolMode: "in"

    readonly property var gradientPresets: [
        { id: "fg_to_bg",          label: qsTr("FG → BG"),     mode: "fg_to_bg",          stops: [] },
        { id: "fg_to_transparent", label: qsTr("FG → Clear"),  mode: "fg_to_transparent", stops: [] },
        { id: "rainbow",           label: qsTr("Rainbow"),     mode: "custom", stops: [
            { pos: 0.0,  hex: "#ff2a2a", alpha: 1.0 },
            { pos: 0.2,  hex: "#ffaa00", alpha: 1.0 },
            { pos: 0.4,  hex: "#ffee00", alpha: 1.0 },
            { pos: 0.6,  hex: "#22cc44", alpha: 1.0 },
            { pos: 0.8,  hex: "#2288ff", alpha: 1.0 },
            { pos: 1.0,  hex: "#aa33ff", alpha: 1.0 }
        ]},
        { id: "sunset",            label: qsTr("Sunset"),      mode: "custom", stops: [
            { pos: 0.0,  hex: "#2b1055", alpha: 1.0 },
            { pos: 0.45, hex: "#b5179e", alpha: 1.0 },
            { pos: 0.78, hex: "#f77f00", alpha: 1.0 },
            { pos: 1.0,  hex: "#fcbf49", alpha: 1.0 }
        ]},
        { id: "ocean",             label: qsTr("Ocean"),       mode: "custom", stops: [
            { pos: 0.0,  hex: "#03045e", alpha: 1.0 },
            { pos: 0.5,  hex: "#0077b6", alpha: 1.0 },
            { pos: 1.0,  hex: "#90e0ef", alpha: 1.0 }
        ]},
        { id: "fire",              label: qsTr("Fire"),        mode: "custom", stops: [
            { pos: 0.0,  hex: "#140404", alpha: 1.0 },
            { pos: 0.35, hex: "#c1121f", alpha: 1.0 },
            { pos: 0.7,  hex: "#ff9f1c", alpha: 1.0 },
            { pos: 1.0,  hex: "#fff8d6", alpha: 1.0 }
        ]},
        { id: "chrome",            label: qsTr("Chrome"),      mode: "custom", stops: [
            { pos: 0.0,  hex: "#243040", alpha: 1.0 },
            { pos: 0.45, hex: "#e6eef8", alpha: 1.0 },
            { pos: 0.5,  hex: "#3a2e25", alpha: 1.0 },
            { pos: 0.75, hex: "#d4c3a3", alpha: 1.0 },
            { pos: 1.0,  hex: "#ffffff", alpha: 1.0 }
        ]},
        { id: "vignette",          label: qsTr("Vignette"),    mode: "custom", stops: [
            { pos: 0.0,  hex: "#000000", alpha: 0.0 },
            { pos: 0.65, hex: "#000000", alpha: 0.15 },
            { pos: 1.0,  hex: "#000000", alpha: 0.85 }
        ]}
    ]

    function applyGradientPreset(preset) {
        view.gradientPresetId = preset.id
        view.gradientColorMode = preset.mode
        var copy = []
        for (var i = 0; i < preset.stops.length; ++i) {
            var s = preset.stops[i]
            copy.push({ pos: s.pos, hex: s.hex, alpha: s.alpha })
        }
        view.gradientStops = copy
        view.gradientSelectedStop = 0
        if (typeof gradientOverlay !== "undefined") gradientOverlay.repaintPreview()
    }

    function rawGradientStops() {
        var list = []
        if (view.gradientColorMode === "custom" && view.gradientStops.length >= 2) {
            for (var i = 0; i < view.gradientStops.length; ++i) {
                var s = view.gradientStops[i]
                list.push({ pos: s.pos, hex: s.hex, alpha: s.alpha })
            }
        } else if (view.gradientColorMode === "fg_to_transparent") {
            list.push({ pos: 0.0, hex: view.foregroundColor, alpha: 1.0 })
            list.push({ pos: 1.0, hex: view.foregroundColor, alpha: 0.0 })
        } else {
            list.push({ pos: 0.0, hex: view.foregroundColor, alpha: 1.0 })
            list.push({ pos: 1.0, hex: view.backgroundColor, alpha: 1.0 })
        }
        return list
    }

    function resolvedGradientStops() {
        var list = view.rawGradientStops()
        list.sort(function(a, b) { return a.pos - b.pos })
        return list
    }

    function ensureCustomGradientStops() {
        if (view.gradientColorMode !== "custom" || view.gradientStops.length < 2) {
            view.gradientStops = view.resolvedGradientStops()
            view.gradientColorMode = "custom"
            view.gradientPresetId = "custom"
        }
    }

    function updateGradientStop(index, patch) {
        view.ensureCustomGradientStops()
        if (index < 0 || index >= view.gradientStops.length) return
        var next = view.gradientStops.slice()
        var cur = next[index]
        next[index] = {
            pos: patch.pos !== undefined ? Math.max(0, Math.min(1, patch.pos)) : cur.pos,
            hex: patch.hex !== undefined ? patch.hex : cur.hex,
            alpha: patch.alpha !== undefined ? Math.max(0, Math.min(1, patch.alpha)) : cur.alpha
        }
        view.gradientStops = next
        if (typeof gradientOverlay !== "undefined") gradientOverlay.repaintPreview()
    }

    function addGradientStopAt(pos) {
        view.ensureCustomGradientStops()
        var clamped = Math.max(0, Math.min(1, pos))
        var next = view.gradientStops.slice()
        next.push({ pos: clamped, hex: view.foregroundColor, alpha: 1.0 })
        view.gradientStops = next
        view.gradientSelectedStop = next.length - 1
        if (typeof gradientOverlay !== "undefined") gradientOverlay.repaintPreview()
    }

    function removeSelectedGradientStop() {
        if (view.gradientColorMode !== "custom" || view.gradientStops.length <= 2) return
        var idx = view.gradientSelectedStop
        if (idx < 0 || idx >= view.gradientStops.length) return
        var next = view.gradientStops.slice()
        next.splice(idx, 1)
        view.gradientStops = next
        view.gradientSelectedStop = Math.min(idx, next.length - 1)
        if (typeof gradientOverlay !== "undefined") gradientOverlay.repaintPreview()
    }

    function drawColorForMode(mode) {
        if (mode === "foreground") return view.colorBytes(view.foregroundColor)
        if (mode === "background") return view.backgroundTransparent ? null : view.colorBytes(view.backgroundColor)
        return null
    }
    function drawHexForMode(mode) {
        if (mode === "foreground") return view.foregroundColor
        if (mode === "background") return view.backgroundTransparent ? "" : view.backgroundColor
        return ""
    }
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

    /// Sample a `#rrggbb` colour directly from the open Editor canvas (in-RAM
    /// when available, falling back to `previewPath`) at canvas-host `(hostX, hostY)`.
    function pickCanvasColor(hostX, hostY) {
        if (!view.documentReady || !view.editor) return ""
        var samplePath = (view.editor.ramCanvasRevision || 0) > 0
                         ? "ram://canvas"
                         : (view.editor.previewPath || "")
        if (!samplePath) return ""
        if (view.documentWidth <= 0 || view.documentHeight <= 0) return ""
        var docX = view.hostToDocX(hostX)
        var docY = view.hostToDocY(hostY)
        if (docX < 0 || docY < 0 || docX >= view.documentWidth || docY >= view.documentHeight)
            return ""
        var hex = Platform.sampleImageColor(
            samplePath,
            docX / Math.max(1, view.documentWidth),
            docY / Math.max(1, view.documentHeight))
        if (hex && hex.length === 7) {
            view.setForegroundColor(hex)
            return hex
        }
        return ""
    }

    /// Krita's [ and ]: smart step per press, 10 px with Shift.
    function stepPaintSize(delta) {
        view.paintSize = Math.max(view.minimumPaintSize,
                                  Math.min(view.maximumPaintSize,
                                           Math.round(view.paintSize + delta)))
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
        view._livePaintPending = []
        if (view.editor && (view.editor.ramCanvasRevision || 0) > 0) {
            view._livePaintActive = true
            view.command({
                type: "editor_live_stroke_begin",
                kind: "paint",
                x: x,
                y: y,
                color: view.foregroundBytes(),
                radius: Math.max(0.5, view.paintSize / 2),
                opacity: Math.max(0.01, view.paintOpacity / 100),
                erase: view.paintMode === "eraser",
                tip: view.brushTip,
                hardness: view.brushHardness / 100.0,
                flow: Math.max(0.05, view.brushFlow / 100.0),
                spacing: Math.max(0.05, view.brushSpacing / 100.0),
                angle: view.brushAngle,
                scatter: view.brushScatter / 100.0
            })
            livePaintFlushTimer.start()
        } else {
            view._livePaintActive = false
            strokePreview.requestPaint()
        }
    }

    property bool _livePaintActive: false
    property var _livePaintPending: []

    Timer {
        id: livePaintFlushTimer
        interval: 24
        repeat: true
        onTriggered: {
            if (!view._livePaintActive || view._livePaintPending.length === 0) return
            var batch = view._livePaintPending.slice()
            view._livePaintPending = []
            view.command({ type: "editor_live_stroke_step", points: batch })
        }
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
        if (view._livePaintActive) {
            view._livePaintPending.push([x, y])
        } else {
            strokePreview.requestPaint()
        }
    }

    /// End the stroke and commit it as one Undo step.
    function finishPaintStroke() {
        if (!view.paintStroking) return
        view.paintStroking = false
        var points = view.paintStroke
        view.paintStroke = []
        if (view._livePaintActive) {
            livePaintFlushTimer.stop()
            if (view._livePaintPending.length > 0) {
                var batch = view._livePaintPending.slice()
                view._livePaintPending = []
                view.command({ type: "editor_live_stroke_step", points: batch })
            }
            view._livePaintActive = false
            view.command({ type: "editor_live_stroke_end", commit: true })
            return
        }
        strokePreview.requestPaint()
        if (points.length === 0) return
        view.command({
            type: "editor_paint_stroke",
            points: points,
            color: view.foregroundBytes(),
            radius: Math.max(0.5, view.paintSize / 2),
            opacity: Math.max(0.01, view.paintOpacity / 100),
            erase: view.paintMode === "eraser",
            tip: view.brushTip,
            hardness: view.brushHardness / 100.0,
            flow: Math.max(0.05, view.brushFlow / 100.0),
            spacing: Math.max(0.05, view.brushSpacing / 100.0),
            angle: view.brushAngle,
            scatter: view.brushScatter / 100.0
        })
    }

    function cancelPaintStroke() {
        if (!view.paintStroking) return
        view.paintStroking = false
        view.paintStroke = []
        if (view._livePaintActive) {
            livePaintFlushTimer.stop()
            view._livePaintPending = []
            view._livePaintActive = false
            view.command({ type: "editor_live_stroke_end", commit: false })
            return
        }
        strokePreview.requestPaint()
    }

    // Global Editor shortcuts (disabled while a color filter dialog owns the session).
    Shortcut {
        sequence: "Ctrl+D"
        enabled: view.visible && view.documentReady && view.hasSelection && !view.filterDialogOpen
        onActivated: view.command({ type: "editor_select_clear" })
    }
    Shortcut {
        sequence: "Ctrl+U"
        enabled: view.visible && view.documentReady && !view.filterDialogOpen
        onActivated: view.activateFilterTool("hsv")
    }
    Shortcut {
        sequence: "Ctrl+M"
        enabled: view.visible && view.documentReady && !view.filterDialogOpen
        onActivated: view.activateFilterTool("curves")
    }
    Shortcut {
        sequence: "Ctrl+B"
        enabled: view.visible && view.documentReady && !view.filterDialogOpen
        onActivated: view.activateFilterTool("colorBalance")
    }

    function activateFilterTool(toolKey) {
        if (!view.documentReady) return
        if (view.tool !== toolKey) {
            view.tool = toolKey
        }
        inspector.topTab = "options"
        inspector.topCollapsed = false
        if (toolKey === "adjust") adjustOptionsPanel.reset()
        else if (toolKey === "hsv") hsvOptionsPanel.reset()
        else if (toolKey === "curves") curvesOptionsPanel.reset()
        else if (toolKey === "colorBalance") colorBalanceOptionsPanel.reset()
    }

    Timer {
        id: adjustPreviewTimer
        interval: 35
        onTriggered: {
            if (view.tool === "adjust" && view.documentReady && adjustOptionsPanel.changed) {
                view.command({
                    type: "editor_preview_filter",
                    clear: false,
                    kind: "color",
                    brightness: adjustOptionsPanel.brightness,
                    contrast: adjustOptionsPanel.contrast,
                    saturation: adjustOptionsPanel.saturation,
                    target: view.effectiveToolTarget()
                })
            }
        }
    }

    function scheduleAdjustPreview() {
        if (view.tool !== "adjust" || !view.documentReady) return
        if (!adjustOptionsPanel.changed) {
            adjustPreviewTimer.stop()
            view.command({ type: "editor_preview_filter", clear: true })
            return
        }
        adjustPreviewTimer.restart()
    }

    /// The Krita defaults this build maps. Plain keys belong to the view, so a
    /// text field that has focus consumes them first — typing "b" into X must
    /// not arm the brush. Ctrl+Z and Ctrl+Shift+Z are the undo pair; the rest
    /// are bare keys.
    Keys.onPressed: function(event) {
        if (view.filterDialogOpen) return
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
            } else if (control && !alt && !shift && event.key === Qt.Key_A && view.documentReady) {
                view.command({ type: "editor_select_all" })
                event.accepted = true
            } else if (control && !alt && !shift && event.key === Qt.Key_D && view.documentReady) {
                view.command({ type: "editor_select_clear" })
                event.accepted = true
            } else if (control && !alt && shift && event.key === Qt.Key_I && view.documentReady) {
                view.command({ type: "editor_select_invert" })
                event.accepted = true
            } else if (control && !alt && !shift && event.key === Qt.Key_J && view.documentReady) {
                if (view.hasSelection) {
                    view.command({ type: "editor_selection_duplicate_layer" })
                } else if (view.activeLayerId > 0) {
                    view.command({ type: "editor_layer_duplicate", id: view.activeLayerId })
                }
                event.accepted = true
            } else if (control && !alt && !shift && event.key === Qt.Key_C && view.documentReady) {
                view.command({ type: "editor_selection_copy", cut: false })
                event.accepted = true
            } else if (control && !alt && !shift && event.key === Qt.Key_X && view.documentReady) {
                view.command({ type: "editor_selection_copy", cut: true })
                event.accepted = true
            } else if (control && !alt && !shift && event.key === Qt.Key_T && view.documentReady) {
                if (view.tool === "transform") {
                    view.tool = "pointer"
                } else {
                    view.tool = "transform"
                    view.resetTransformCorners()
                }
                event.accepted = true
            }
            return
        }
        if (view.tool === "transform" && view.documentReady) {
            var nudge = shift ? 10 : 1
            if (event.key === Qt.Key_Left || event.key === Qt.Key_Right
                    || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                var r = view.transformRect()
                if (r) {
                    var nx = r.x + (event.key === Qt.Key_Left ? -nudge : (event.key === Qt.Key_Right ? nudge : 0))
                    var ny = r.y + (event.key === Qt.Key_Up ? -nudge : (event.key === Qt.Key_Down ? nudge : 0))
                    view.setTransformFrame(nx, ny, r.width, r.height)
                }
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (view.transformUsable() && view.transformChanged()) {
                    view.applyTransform()
                }
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Escape) {
                view.resetTransformCorners()
                view.tool = "pointer"
                event.accepted = true
                return
            }
        }
        if ((view.tool === "select" || view.tool === "pointer") && view.hasSelection && view.documentReady) {
            var selNudge = shift ? 10 : 1
            if (event.key === Qt.Key_Left || event.key === Qt.Key_Right
                    || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                var sdx = event.key === Qt.Key_Left ? -selNudge : (event.key === Qt.Key_Right ? selNudge : 0)
                var sdy = event.key === Qt.Key_Up ? -selNudge : (event.key === Qt.Key_Down ? selNudge : 0)
                view.command({ type: "editor_select_move", dx: sdx, dy: sdy })
                event.accepted = true
                return
            }
        }
        if (view.tool === "select" && view.documentReady) {
            if (selectOverlay.polyPoints.length > 0 || selectOverlay.bezierNodes.length > 0) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (selectOverlay.bezierNodes.length > 0) selectOverlay.finishBezier()
                    else selectOverlay.finishPolygon()
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Backspace || (!control && shift && event.key === Qt.Key_Z)) {
                    if (selectOverlay.bezierNodes.length > 0) selectOverlay.popBezierNode()
                    else selectOverlay.popPolygonPoint()
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Escape) {
                    if (selectOverlay.bezierNodes.length > 0) selectOverlay.cancelBezier()
                    else selectOverlay.cancelPolygon()
                    event.accepted = true
                    return
                }
            }
            if (event.key === Qt.Key_R) {
                view.selectMode = "replace"
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_A) {
                view.selectMode = shift ? "intersect" : "add"
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_S) {
                view.selectMode = "subtract"
                event.accepted = true
                return
            }
        }
        if (view.tool === "gradient" && view.documentReady && gradientOverlay.hasDraft) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                gradientOverlay.applyDraft()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Escape) {
                gradientOverlay.cancelDraft()
                event.accepted = true
                return
            }
        }
        if (view.tool === "draw" && view.documentReady) {
            if (drawOverlay.hasDraftPath) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    drawOverlay.finishPath()
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Backspace || (!control && shift && event.key === Qt.Key_Z)) {
                    drawOverlay.popLastPoint()
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Escape) {
                    drawOverlay.cancelDraft()
                    event.accepted = true
                    return
                }
            }
            if (event.key === Qt.Key_BracketLeft) {
                view.drawStrokeWidth = Math.max(1, view.drawStrokeWidth - (view.drawStrokeWidth > 20 ? 4 : 1))
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_BracketRight) {
                view.drawStrokeWidth = Math.min(120, view.drawStrokeWidth + (view.drawStrokeWidth >= 20 ? 4 : 1))
                event.accepted = true
                return
            }
        }
        if (view.tool === "paint" && view.documentReady) {
            // Krita Paint brush color shortcuts:
            // K = darker (-8% value), L = lighter (+8% value), C = quick color popup at cursor.
            if (event.key === Qt.Key_K) {
                view.nudgeForegroundValue(-0.08)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_L) {
                view.nudgeForegroundValue(0.08)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_C) {
                quickBrushColorPopup.openAtCursor(paintArea.hoverInside ? paintArea.hoverX : canvasHost.width / 2,
                                                  paintArea.hoverInside ? paintArea.hoverY : canvasHost.height / 2)
                event.accepted = true
                return
            }
        }
        switch (event.key) {
        case Qt.Key_U:
            if (view.documentReady) {
                if (view.tool === "draw" && shift) {
                    var modes = ["line", "polyline", "bezier", "rect", "ellipse", "polygon"]
                    var nextIdx = (modes.indexOf(view.drawShape) + 1) % modes.length
                    view.drawShape = modes[nextIdx]
                } else {
                    view.tool = view.tool === "draw" ? "pointer" : "draw"
                }
                event.accepted = true
            }
            break
        case Qt.Key_G:
            if (view.documentReady) {
                view.tool = view.tool === "gradient" ? "pointer" : "gradient"
                event.accepted = true
            }
            break
        case Qt.Key_Q:
            if (view.documentReady) {
                view.tool = view.tool === "liquify" ? "pointer" : "liquify"
                event.accepted = true
            }
            break
        case Qt.Key_Z:
            if (!control && !shift && view.documentReady) {
                view.tool = view.tool === "zoom" ? "pointer" : "zoom"
                event.accepted = true
            }
            break
        case Qt.Key_M:
            if (view.documentReady) {
                if (view.tool === "select") {
                    view.selectShape = view.selectShape === "rect" ? "ellipse" : "rect"
                } else {
                    view.tool = "select"
                    view.selectShape = "rect"
                }
                event.accepted = true
            }
            break
        case Qt.Key_L:
            if (view.documentReady) {
                if (view.tool === "select") {
                    view.selectShape = view.selectShape === "lasso" ? "polygon" : "lasso"
                } else {
                    view.tool = "select"
                    view.selectShape = "lasso"
                }
                event.accepted = true
            }
            break
        case Qt.Key_W:
            if (view.documentReady) {
                view.tool = "select"
                view.selectShape = "wand"
                event.accepted = true
            }
            break
        case Qt.Key_Delete:
        case Qt.Key_Backspace:
            if (view.documentReady && view.hasSelection) {
                view.command({ type: "editor_selection_delete" })
                event.accepted = true
            }
            break
        case Qt.Key_Escape:
            if (view.documentReady && view.hasSelection) {
                view.command({ type: "editor_select_clear" })
                event.accepted = true
            }
            break
        case Qt.Key_B:
            if (view.documentReady) {
                view.tool = "paint"
                view.selectPaintMode("brush")
                event.accepted = true
            }
            break
        case Qt.Key_E:
            if (view.documentReady) {
                view.tool = "paint"
                view.selectPaintMode("eraser")
                event.accepted = true
            }
            break
        case Qt.Key_I:
            if (view.documentReady) {
                view.tool = "eyedropper"
                event.accepted = true
            }
            break
        case Qt.Key_BracketLeft:
            if (view.documentReady) {
                if (view.tool === "liquify") {
                    view.liquifyRadius = Math.max(10, view.liquifyRadius - (shift ? 20 : 8))
                } else {
                    var dec = shift ? 10 : (view.paintSize > 40 ? 5 : (view.paintSize > 12 ? 2 : 1))
                    view.stepPaintSize(-dec)
                }
                event.accepted = true
            }
            break
        case Qt.Key_BracketRight:
            if (view.documentReady) {
                if (view.tool === "liquify") {
                    view.liquifyRadius = Math.min(300, view.liquifyRadius + (shift ? 20 : 8))
                } else {
                    var inc = shift ? 10 : (view.paintSize >= 40 ? 5 : (view.paintSize >= 12 ? 2 : 1))
                    view.stepPaintSize(inc)
                }
                event.accepted = true
            }
            break
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

    /// The active layer's summary object (`{ id, name, offsetX, offsetY, width, height, ... }`), or null.
    function activeLayerSummary() {
        if (!view.editor || !view.editor.layers) return null
        var aid = view.editor.activeLayerId
        for (var i = 0; i < view.editor.layers.length; ++i) {
            if (view.editor.layers[i].id === aid) return view.editor.layers[i]
        }
        return null
    }

    /// The quad that changes nothing:
    /// 1. When a selection is active, hugs `selectionBounds` so Transform
    ///    floats and transforms only the selected pixels.
    /// 2. Otherwise, hugs the active layer's bounds when targeting `active_layer`.
    /// 3. Otherwise, hugs the full document canvas.
    function identityCorners() {
        if (view.hasSelection && view.editor && view.editor.selectionBounds
                && view.editor.selectionBounds.length === 4) {
            var sb = view.editor.selectionBounds
            return [[sb[0], sb[1]],
                    [sb[0] + sb[2], sb[1]],
                    [sb[0] + sb[2], sb[1] + sb[3]],
                    [sb[0], sb[1] + sb[3]]]
        }
        if (view.transformMode === "free"
                && (!view.hasMultipleLayers || view.effectiveToolTarget() === "active_layer")) {
            var layer = view.activeLayerSummary()
            if (layer && layer.width > 0 && layer.height > 0) {
                var ox = layer.offsetX || 0
                var oy = layer.offsetY || 0
                return [[ox, oy],
                        [ox + layer.width, oy],
                        [ox + layer.width, oy + layer.height],
                        [ox, oy + layer.height]]
            }
        }
        return [[0, 0],
                [view.documentWidth, 0],
                [view.documentWidth, view.documentHeight],
                [0, view.documentHeight]]
    }

    function resetTransformCorners() {
        view.transformCorners = view.identityCorners()
        view.transformRotation = 0
    }

    /// Proportionally fit the current Transform box inside the canvas and center it.
    function fitTransformToCanvas() {
        var r = view.transformRect()
        if (!r || !view.documentReady || view.documentWidth <= 0 || view.documentHeight <= 0) return
        var scale = Math.min(view.documentWidth / Math.max(1, r.width),
                             view.documentHeight / Math.max(1, r.height))
        var nw = Math.max(1, Math.round(r.width * scale))
        var nh = Math.max(1, Math.round(r.height * scale))
        var nx = Math.round((view.documentWidth - nw) / 2)
        var ny = Math.round((view.documentHeight - nh) / 2)
        view.setTransformFrame(nx, ny, nw, nh)
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
        var docX = view.hostToDocX(hostX)
        var docY = view.hostToDocY(hostY)
        var angleDeg = view.transformRotation || 0
        if (Math.abs(angleDeg) < 0.05) {
            var next = view.computeBoxHandleDrag(
                base, column, row, docX, docY,
                {
                    keepAspect: shift,
                    aspect: base.height > 0 ? base.width / base.height : 1,
                    fromCenter: alt,
                    snap: ctrl,
                    clampToDoc: false,
                    maxDim: 16384
                })
            view.setTransformFrame(next.x, next.y, next.width, next.height)
            return
        }
        // Rotation-aware handle drag: project pointer into the rotated box's
        // local axes, keep the opposite edge/corner pinned (or scale from
        // center with Alt), then rotate the center shift back to canvas space.
        var theta = angleDeg * Math.PI / 180.0
        var cosT = Math.cos(theta)
        var sinT = Math.sin(theta)
        var startCx = base.x + base.width / 2.0
        var startCy = base.y + base.height / 2.0
        var relX = docX - startCx
        var relY = docY - startCy
        var locX = relX * cosT + relY * sinT
        var locY = -relX * sinT + relY * cosT
        var halfW = base.width / 2.0
        var halfH = base.height / 2.0
        var newL = -halfW
        var newR = halfW
        var newT = -halfH
        var newB = halfH
        if (column === 0) {
            newL = Math.min(newR - 1, locX)
            if (alt) newR = Math.max(1, -newL)
        } else if (column === 2) {
            newR = Math.max(newL + 1, locX)
            if (alt) newL = Math.min(-1, -newR)
        }
        if (row === 0) {
            newT = Math.min(newB - 1, locY)
            if (alt) newB = Math.max(1, -newT)
        } else if (row === 2) {
            newB = Math.max(newT + 1, locY)
            if (alt) newT = Math.min(-1, -newB)
        }
        var newW = Math.max(1, newR - newL)
        var newH = Math.max(1, newB - newT)
        if (shift && base.height > 0 && base.width > 0) {
            var aspect = base.width / base.height
            if (column !== 1 && row !== 1) {
                if (newW / base.width >= newH / base.height) {
                    newH = Math.max(1, newW / aspect)
                } else {
                    newW = Math.max(1, newH * aspect)
                }
                if (alt) {
                    newL = -newW / 2; newR = newW / 2; newT = -newH / 2; newB = newH / 2
                } else {
                    if (column === 0) newL = newR - newW; else newR = newL + newW
                    if (row === 0) newT = newB - newH; else newB = newT + newH
                }
            }
        }
        var shiftLocX = (newL + newR) / 2.0
        var shiftLocY = (newT + newB) / 2.0
        var newCx = startCx + shiftLocX * cosT - shiftLocY * sinT
        var newCy = startCy + shiftLocX * sinT + shiftLocY * cosT
        view.setTransformFrame(newCx - newW / 2.0, newCy - newH / 2.0, newW, newH)
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
        var base = view.identityCorners()
        var bx = Math.round(base[0][0])
        var by = Math.round(base[0][1])
        var bw = Math.round(base[1][0] - base[0][0])
        var bh = Math.round(base[2][1] - base[0][1])
        return Math.round(rect.x) !== bx
                || Math.round(rect.y) !== by
                || Math.round(rect.width) !== bw
                || Math.round(rect.height) !== bh
                || Math.abs(view.transformRotation) >= 0.05
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
                rotation: view.transformRotation,
                fill: view.backgroundTransparent ? null : view.backgroundBytes(),
                fill_alpha: view.backgroundAlpha(),
                target: view.hasMultipleLayers ? view.effectiveToolTarget() : "active_layer"
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
        // When a selection is active, seed the crop frame directly from the
        // selection's bounding box so the user doesn't have to redraw it.
        if (view.documentReady && view.hasSelection
                && view.editor && view.editor.selectionBounds
                && view.editor.selectionBounds.length === 4) {
            var sb = view.editor.selectionBounds
            if (sb[2] > 0 && sb[3] > 0) {
                view.cropHeightAuto = false
                view.cropWidthAuto = false
                view.setCropRect(sb[0], sb[1], sb[2], sb[3])
            }
        }
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
    signal requestSave()
    signal requestNewImage()
    signal requestPasteImage()
    /// Raised by Export's Browse button: Main owns the file chooser.
    signal requestExportPath()
    /// Raised by the Close editor button; Main checks unsaved changes first.
    signal requestClose()
    /// The user dragged the dock's splitter: the shell keeps one width for all
    /// three workspaces, so the view reports the number rather than owning it.
    /// A layout interaction — a splitter, the rail's columns, a reference tab
    /// or panel — as a patch the shell merges into the saved layout. A layout
    /// is Core state (`set_layout`), so the view never writes it.
    signal layoutRequested(var patch)
    /// Show a folder in the desktop's file manager. The shell owns the platform
    /// call, so the view only names the path.
    signal revealPath(string path)
    signal copyImage(string path)
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
        var ext = view.hasMultipleLayers ? ".ora" : (editor.format || ".png")
        return base + ext
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
            fill_alpha: view.backgroundAlpha(),
            target: view.effectiveToolTarget()
        })
        view.rotateAngle = 0
    }

    readonly property bool resizeFrameShown: view.tool === "resize" && view.imageSizeMode === "resize" && view.documentReady && resizeOptionsPanel.valid
    readonly property bool canvasSizeFrameShown: view.tool === "resize" && view.imageSizeMode === "canvasSize" && view.documentReady && canvasSizeOptionsPanel.valid

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
        if (canvasSizeOptionsPanel.customOffset) {
            var cx = -canvasSizeOptionsPanel.customOffsetX
            var cy = -canvasSizeOptionsPanel.customOffsetY
            var cw = canvasSizeOptionsPanel.targetWidth
            var ch = canvasSizeOptionsPanel.targetHeight
            view.command({
                type: "editor_crop",
                x: cx,
                y: cy,
                width: cw,
                height: ch,
                fill: view.backgroundTransparent ? [0, 0, 0] : view.backgroundBytes(),
                fill_alpha: view.backgroundAlpha()
            })
        } else {
            view.command({
                type: "editor_canvas_size",
                width: canvasSizeOptionsPanel.targetWidth,
                height: canvasSizeOptionsPanel.targetHeight,
                anchor: canvasSizeOptionsPanel.anchor,
                fill: view.backgroundTransparent ? null : view.backgroundBytes(),
                fill_alpha: view.backgroundAlpha()
            })
        }
        view.tool = "pointer"
    }

    function applyColorAdjust() {
        if (!view.documentReady || !adjustOptionsPanel.changed) return
        view.command({
            type: "editor_adjust_color",
            brightness: adjustOptionsPanel.brightness,
            contrast: adjustOptionsPanel.contrast,
            saturation: adjustOptionsPanel.saturation,
            target: view.effectiveToolTarget()
        })
        adjustOptionsPanel.reset()
    }

    function openResizeDialog() {
        if (!view.documentReady) return
        resizeOptionsPanel.reset()
        canvasSizeOptionsPanel.reset()
        view.tool = view.tool === "resize" ? "pointer" : "resize"
        view.forceActiveFocus()
    }

    function openCanvasSizeDialog() {
        if (!view.documentReady) return
        view.imageSizeMode = "canvasSize"
        canvasSizeOptionsPanel.reset()
        view.tool = "resize"
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

    // Interactive watermark region rectangle (document pixel coordinates),
    // shared between the on-canvas overlay, the Region tab, and AI Manual mode.
    property int wmRegionX: 0
    property int wmRegionY: 0
    property int wmRegionW: 0
    property int wmRegionH: 0
    // Freehand brush mask strokes for AI Inpainting: [{ radius, points: [[x,y], ...] }]
    property var wmBrushStrokes: []
    property int wmBrushRadius: 24

    function clearWmBrushMask() {
        view.wmBrushStrokes = []
        if (typeof wmBrushCanvas !== "undefined" && wmBrushCanvas) {
            wmBrushCanvas.requestPaint()
        }
    }

    function setWmRegion(x, y, w, h) {
        var dw = Math.max(1, Math.round(view.documentWidth))
        var dh = Math.max(1, Math.round(view.documentHeight))
        var nw = Math.max(8, Math.min(dw, Math.round(w)))
        var nh = Math.max(8, Math.min(dh, Math.round(h)))
        var nx = Math.max(0, Math.min(dw - nw, Math.round(x)))
        var ny = Math.max(0, Math.min(dh - nh, Math.round(y)))
        view.wmRegionX = nx
        view.wmRegionY = ny
        view.wmRegionW = nw
        view.wmRegionH = nh
    }

    function setWmCornerPreset(corner) {
        var dw = Math.max(1, Math.round(view.documentWidth))
        var dh = Math.max(1, Math.round(view.documentHeight))
        var rw = Math.max(24, Math.round(dw * 0.18))
        var rh = Math.max(24, Math.round(dh * 0.10))
        var pad = Math.min(16, Math.floor(Math.min(dw, dh) * 0.03))
        if (corner === "br") view.setWmRegion(dw - rw - pad, dh - rh - pad, rw, rh)
        else if (corner === "bl") view.setWmRegion(pad, dh - rh - pad, rw, rh)
        else if (corner === "tr") view.setWmRegion(dw - rw - pad, pad, rw, rh)
        else view.setWmRegion(pad, pad, rw, rh)
    }

    function ensureWmRegionInitialized() {
        if (view.documentWidth > 0 && view.documentHeight > 0 && (view.wmRegionW <= 0 || view.wmRegionH <= 0)) {
            view.setWmCornerPreset("br")
        }
    }

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
        view.wmRegionW = 0
        view.wmRegionH = 0
        view.clearWmBrushMask()
        if (watermarkRegionOverlay.visible) view.ensureWmRegionInitialized()
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
        if (typeof resizeCanvasLayer !== "undefined" && resizeCanvasLayer) {
            resizeCanvasLayer.dragActive = false
        }
        if (typeof adjustPreviewTimer !== "undefined" && adjustPreviewTimer) {
            adjustPreviewTimer.stop()
        }
        if (view.documentReady && !view.isColorFilterTool) {
            view.command({ type: "editor_preview_filter", clear: true })
        }
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
            onTriggered: view.command({ type: "editor_rotate", degrees: -90, target: "whole_image" })
        }
        MenuItem {
            text: view.theme.menuEntries[24]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_rotate", degrees: 90, target: "whole_image" })
        }
        MenuItem {
            text: view.theme.menuEntries[25]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_flip", axis: "horizontal", target: "whole_image" })
        }
        MenuItem {
            text: view.theme.menuEntries[26]
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_flip", axis: "vertical", target: "whole_image" })
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[27]
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
    }

    // ------------------------------------------------------ editor workspace
    property Component toolbar: Component {
        RowLayout {
            spacing: 2
            enabled: !view.filterDialogOpen
            opacity: view.filterDialogOpen ? 0.55 : 1.0

            ToolbarButton {
                id: fileToolbarBtn
                objectName: "editorFileMenuButton"
                theme: view.theme
                text: qsTr("File") + " ▾"
                display: AbstractButton.TextOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("File actions (New, Open, Save, Export, Reset, Close)")
                onClicked: editorFileMenu.popup(fileToolbarBtn, 0, fileToolbarBtn.height)
            }
            ToolbarButton {
                id: editToolbarBtn
                objectName: "editorEditMenuButton"
                theme: view.theme
                text: qsTr("Edit") + " ▾"
                display: AbstractButton.TextOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Edit actions (Undo, Redo, Cut, Copy, Paste, Delete, Fill)")
                onClicked: editorEditMenu.popup(editToolbarBtn, 0, editToolbarBtn.height)
            }
            ToolbarButton {
                id: selectToolbarBtn
                objectName: "editorSelectMenuButton"
                theme: view.theme
                text: qsTr("Select") + " ▾"
                display: AbstractButton.TextOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Selection actions (All, Clear, Invert, Grow, Shrink, Border, Smooth, Fill, Crop…)")
                onClicked: editorSelectMenu.popup(selectToolbarBtn, 0, selectToolbarBtn.height)
            }
            ToolbarButton {
                id: filterToolbarBtn
                objectName: "editorFilterMenuButton"
                theme: view.theme
                text: qsTr("Filter") + " ▾"
                display: AbstractButton.TextOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Image filters & color adjustments")
                onClicked: filterMenu.popup(filterToolbarBtn, 0, filterToolbarBtn.height)
            }
            ToolbarButton {
                id: pluginsToolbarBtn
                objectName: "editorPluginsMenuButton"
                theme: view.theme
                text: qsTr("Plugins") + " ▾"
                display: AbstractButton.TextOnly
                enabled: view.documentReady
                ToolTip.visible: hovered
                ToolTip.text: qsTr("AI & utility plugins (Remove BG, Watermark, Caption)")
                onClicked: editorPluginsMenu.popup(pluginsToolbarBtn, 0, pluginsToolbarBtn.height)
            }
            ToolbarSeparator {
                theme: view.theme
            }
            // Essential Quick Actions only: Save, Export, Undo, Redo + compact zoom readout
            ToolbarButton {
                objectName: "editorToolbarSave"
                theme: view.theme
                icon.name: "document-save-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.documentReady && !view.saved && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save (Ctrl+S)")
                onClicked: view.requestSave()
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
            }
            ToolbarButton {
                objectName: "undoButton"
                theme: view.theme
                icon.name: "edit-undo-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!(view.editor && view.editor.canUndo)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Undo (Ctrl+Z)")
                onClicked: view.command({ type: "editor_undo" })
            }
            ToolbarButton {
                objectName: "redoButton"
                theme: view.theme
                icon.name: "edit-redo-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!(view.editor && view.editor.canRedo)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Redo (Ctrl+Shift+Z)")
                onClicked: view.command({ type: "editor_redo" })
            }
            ToolbarButton {
                objectName: "editorZoomBadge"
                theme: view.theme
                visible: view.hasDocument && !view.miniToolbar
                text: view.zoomPercent + "%"
                display: AbstractButton.TextOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom tool (Z) — click to open Zoom options")
                onClicked: {
                    view.tool = "zoom"
                    view.forceActiveFocus()
                }
            }
            ToolbarButton {
                objectName: "editorOverflowButton"
                theme: view.theme
                visible: view.miniToolbar
                icon.name: "view-more-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("More editor actions")
                onClicked: editorOverflow.toggleFrom(this)
            }
        }
    }

    AppMenu {
        id: editorEditMenu
        objectName: "editorEditMenu"
        theme: view.theme
        implicitWidth: 230
        MenuItem {
            text: qsTr("Undo (Ctrl+Z)")
            icon.name: "edit-undo-symbolic"
            enabled: !!(view.editor && view.editor.canUndo)
            onTriggered: view.command({ type: "editor_undo" })
        }
        MenuItem {
            text: qsTr("Redo (Ctrl+Shift+Z)")
            icon.name: "edit-redo-symbolic"
            enabled: !!(view.editor && view.editor.canRedo)
            onTriggered: view.command({ type: "editor_redo" })
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Cut (Ctrl+X)")
            icon.name: "edit-cut-symbolic"
            enabled: view.documentReady && view.hasSelection
            onTriggered: view.command({ type: "editor_selection_copy", cut: true })
        }
        MenuItem {
            text: qsTr("Copy (Ctrl+C)")
            icon.name: "edit-copy-symbolic"
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_selection_copy", cut: false })
        }
        MenuItem {
            text: qsTr("Paste as new layer (Ctrl+V)")
            icon.name: "edit-paste-symbolic"
            onTriggered: view.requestPasteImage()
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Delete (Del)")
            icon.name: "edit-delete-symbolic"
            enabled: view.documentReady && view.hasSelection
            onTriggered: view.command({ type: "editor_selection_delete" })
        }
        MenuItem {
            text: qsTr("Fill selection…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectionFillDialog.openDialog()
        }
        MenuItem {
            text: qsTr("Stroke selection…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectionStrokeDialog.openDialog()
        }
        MenuItem {
            text: qsTr("Duplicate selection to layer")
            enabled: view.documentReady && view.hasSelection
            onTriggered: view.command({ type: "editor_selection_duplicate_layer" })
        }
    }

    AppMenu {
        id: editorSelectMenu
        objectName: "editorSelectMenu"
        theme: view.theme
        MenuItem {
            text: qsTr("Select all (Ctrl+A)")
            enabled: view.documentReady
            onTriggered: view.command({ type: "editor_select_all" })
        }
        MenuItem {
            text: qsTr("Deselect (Ctrl+D)")
            enabled: view.documentReady && view.hasSelection
            onTriggered: view.command({ type: "editor_select_clear" })
        }
        MenuItem {
            text: qsTr("Invert selection (Ctrl+Shift+I)")
            enabled: view.documentReady && view.hasSelection
            onTriggered: view.command({ type: "editor_select_invert" })
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Grow…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectModifyDialog.openFor("grow", qsTr("Grow Selection"), qsTr("Expand by"))
        }
        MenuItem {
            text: qsTr("Shrink…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectModifyDialog.openFor("shrink", qsTr("Shrink Selection"), qsTr("Contract by"))
        }
        MenuItem {
            text: qsTr("Border…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectModifyDialog.openFor("border", qsTr("Border Selection"), qsTr("Border width"))
        }
        MenuItem {
            text: qsTr("Feather…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectModifyDialog.openFor("feather", qsTr("Feather Selection"), qsTr("Feather radius"))
        }
        MenuItem {
            text: qsTr("Smooth…")
            enabled: view.documentReady && view.hasSelection
            onTriggered: selectModifyDialog.openFor("smooth", qsTr("Smooth Selection"), qsTr("Smooth radius"))
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Crop to selection")
            enabled: view.documentReady && view.hasSelection
            onTriggered: view.command({ type: "editor_selection_crop" })
        }
    }

    AppMenu {
        id: editorPluginsMenu
        objectName: "editorPluginsMenu"
        theme: view.theme
        implicitWidth: 230

        MenuItem {
            text: qsTr("Remove background (AI)")
            icon.source: "icons/ai-rembg.svg"
            enabled: view.documentReady
            onTriggered: {
                view.tool = "removeBg"
                view.forceActiveFocus()
            }
        }
        MenuItem {
            text: qsTr("Remove watermark (Gemini / Region)")
            icon.source: "icons/eraser.svg"
            enabled: view.documentReady
            onTriggered: {
                view.tool = "watermark"
                view.forceActiveFocus()
            }
        }
        MenuItem {
            text: qsTr("Caption && tags (.txt)")
            icon.source: "icons/info.svg"
            enabled: view.documentReady
            onTriggered: {
                view.tool = "caption"
                view.forceActiveFocus()
            }
        }
    }

    AppMenu {
        id: editorFileMenu
        objectName: "editorFileMenu"
        theme: view.theme
        implicitWidth: 220

        MenuItem {
            text: qsTr("New image… (Ctrl+N)")
            icon.name: "document-new-symbolic"
            onTriggered: view.requestNewImage()
        }
        MenuItem {
            text: qsTr("Open image…")
            icon.name: "document-open-symbolic"
            onTriggered: view.requestOpen()
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Save (Ctrl+S)")
            icon.name: "document-save-symbolic"
            enabled: view.documentReady && !view.saved && !view.saving
            onTriggered: view.requestSave()
        }
        MenuItem {
            text: qsTr("Save as… (Ctrl+Shift+S)")
            icon.name: "document-save-as-symbolic"
            enabled: view.documentReady && !view.saving
            onTriggered: view.requestSaveAs()
        }
        MenuItem {
            text: qsTr("Export a copy…")
            icon.name: "document-send-symbolic"
            enabled: view.documentReady && !view.saving
            onTriggered: view.openExportDialog()
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Reset to original")
            icon.name: "document-revert-symbolic"
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
        MenuItem {
            text: qsTr("Close editor")
            icon.name: "window-close-symbolic"
            enabled: view.hasDocument && !view.saving
            onTriggered: view.requestClose()
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

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
            enabled: !view.filterDialogOpen
            opacity: view.filterDialogOpen ? 0.55 : 1.0
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
                        objectName: "toolZoom"
                        theme: view.theme
                        iconSource: "icons/zoom.svg"
                        tooltip: qsTr("Zoom (Z)")
                        active: view.tool === "zoom"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "zoom" ? "pointer" : "zoom"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolBrush"
                        theme: view.theme
                        iconSource: "icons/brush.svg"
                        tooltip: qsTr("Brush (B)")
                        active: view.tool === "paint" && view.paintMode === "brush"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = "paint"
                            view.selectPaintMode("brush")
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolEraser"
                        theme: view.theme
                        iconSource: "icons/eraser.svg"
                        tooltip: qsTr("Eraser (E)")
                        active: view.tool === "paint" && view.paintMode === "eraser"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = "paint"
                            view.selectPaintMode("eraser")
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolDraw"
                        theme: view.theme
                        iconSource: "icons/draw-shapes.svg"
                        tooltip: qsTr("Shapes & Curves (U)")
                        active: view.tool === "draw"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "draw" ? "pointer" : "draw"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolFill"
                        theme: view.theme
                        iconSource: "icons/fill.svg"
                        tooltip: qsTr("Fill / Paint Bucket")
                        active: view.tool === "fill"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "fill" ? "pointer" : "fill"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolGradient"
                        theme: view.theme
                        iconSource: "icons/gradient.svg"
                        tooltip: qsTr("Gradient (G)")
                        active: view.tool === "gradient"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "gradient" ? "pointer" : "gradient"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolLiquify"
                        theme: view.theme
                        iconSource: "icons/liquify.svg"
                        tooltip: qsTr("Liquify (Q)")
                        active: view.tool === "liquify"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "liquify" ? "pointer" : "liquify"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolEyedropper"
                        theme: view.theme
                        iconSource: "icons/eyedropper.svg"
                        tooltip: qsTr("Color picker / Eyedropper (I)")
                        active: view.tool === "eyedropper"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "eyedropper" ? "pointer" : "eyedropper"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolSelect"
                        theme: view.theme
                        iconSource: "icons/select.svg"
                        tooltip: qsTr("Select (M)")
                        active: view.tool === "select"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "select" ? "pointer" : "select"
                            view.forceActiveFocus()
                        }
                    }
                    ToolRailButton {
                        objectName: "toolResize"
                        theme: view.theme
                        iconSource: "icons/resize.svg"
                        tooltip: qsTr("Image size — resize or canvas size")
                        active: view.tool === "resize"
                        enabled: view.documentReady
                        onClicked: view.openResizeDialog()
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
                        tooltip: qsTr("Transform — move, scale, rotate and flip")
                        active: view.tool === "transform"
                        enabled: view.documentReady
                        onClicked: {
                            view.tool = view.tool === "transform" ? "pointer" : "transform"
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
                        onClicked: view.command({ type: "editor_rotate", degrees: -90, target: "whole_image" })
                    }
                    ToolRailButton {
                        objectName: "editsRotateRight"
                        theme: view.theme
                        iconSource: "icons/rotate-right.svg"
                        tooltip: qsTr("Rotate right")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_rotate", degrees: 90, target: "whole_image" })
                    }
                    ToolRailButton {
                        objectName: "editsFlipHorizontal"
                        theme: view.theme
                        iconSource: "icons/flip-horizontal.svg"
                        tooltip: qsTr("Flip horizontal")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_flip", axis: "horizontal", target: "whole_image" })
                    }
                    ToolRailButton {
                        objectName: "editsFlipVertical"
                        theme: view.theme
                        iconSource: "icons/flip-vertical.svg"
                        tooltip: qsTr("Flip vertical")
                        enabled: view.documentReady
                        onClicked: view.command({ type: "editor_flip", axis: "vertical", target: "whole_image" })
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
            allowLeftPan: view.filterDialogOpen || view.isColorFilterTool || view.tool === "hand" || view.spacePanning
            allowMiddlePan: true
            allowDoubleTapZoom: !view.filterDialogOpen && (view.tool === "pointer" || view.tool === "hand") && !view.spacePanning

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
                source: {
                    if (!view.editor) return ""
                    if ((view.editor.ramCanvasRevision || 0) > 0) {
                        return "image://editor/canvas?rev=" + view.editor.ramCanvasRevision
                    }
                    return view.editor.previewPath ? ("file://" + view.editor.previewPath) : ""
                }
                onStatusChanged: {
                    if (status === Image.Ready && view.autoFit && view.hostReady) {
                        view.fit()
                    }
                }
                // Only dim while the initial full-resolution decode is still opening;
                // synchronous edits update directly from RAM with zero flicker!
                opacity: (view.editor && view.editor.opening) ? 0.65 : 1.0
            }

            // Live 60 fps GPU preview for Resize (Stretch / Cover / Pad) with
            // interactive 8-handle direct canvas resizing (anchors opposite edge/corner;
            // hold Alt to resize symmetrically around center).
            Item {
                id: resizeCanvasLayer
                objectName: "resizeCanvasLayer"
                anchors.fill: parent
                visible: view.resizeFrameShown

                property bool dragActive: false
                property real dragDocX: 0
                property real dragDocY: 0

                readonly property real previewW: Math.max(1, resizeOptionsPanel.targetWidth * view.zoom)
                readonly property real previewH: Math.max(1, resizeOptionsPanel.targetHeight * view.zoom)
                readonly property real frameX: dragActive
                                               ? Math.round(view.docToHostX(dragDocX))
                                               : Math.round(canvasHost.width / 2 + canvasHost.offsetX - previewW / 2)
                readonly property real frameY: dragActive
                                               ? Math.round(view.docToHostY(dragDocY))
                                               : Math.round(canvasHost.height / 2 + canvasHost.offsetY - previewH / 2)

                onVisibleChanged: if (!visible) dragActive = false

                Item {
                    x: resizeCanvasLayer.frameX
                    y: resizeCanvasLayer.frameY
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

                // 8 interactive drag handles (4 corners + 4 edges) for live Resize.
                Repeater {
                    model: [
                        { col: -1, row: -1 }, { col: 0, row: -1 }, { col: 1, row: -1 },
                        { col: 1, row: 0 },
                        { col: 1, row: 1 }, { col: 0, row: 1 }, { col: -1, row: 1 },
                        { col: -1, row: 0 }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        width: 12
                        height: 12
                        radius: (modelData.col !== 0 && modelData.row !== 0) ? 2 : 6
                        color: view.theme.accent
                        border.width: 1
                        border.color: view.theme.surface
                        x: resizeCanvasLayer.frameX
                           + (modelData.col === -1 ? 0 : (modelData.col === 1 ? resizeCanvasLayer.previewW : resizeCanvasLayer.previewW / 2))
                           - width / 2
                        y: resizeCanvasLayer.frameY
                           + (modelData.row === -1 ? 0 : (modelData.row === 1 ? resizeCanvasLayer.previewH : resizeCanvasLayer.previewH / 2))
                           - height / 2

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -3
                            acceptedButtons: Qt.LeftButton
                            cursorShape: modelData.col === 0
                                         ? Qt.SizeVerCursor
                                         : (modelData.row === 0
                                            ? Qt.SizeHorCursor
                                            : (modelData.col === modelData.row ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor))
                            property real startHostX: 0
                            property real startHostY: 0
                            property real startLeftDoc: 0
                            property real startTopDoc: 0
                            property real startW: 1
                            property real startH: 1
                            onPressed: function(mouse) {
                                var pt = mapToItem(resizeCanvasLayer, mouse.x, mouse.y)
                                startHostX = pt.x
                                startHostY = pt.y
                                startW = Math.max(1, resizeOptionsPanel.targetWidth)
                                startH = Math.max(1, resizeOptionsPanel.targetHeight)
                                startLeftDoc = view.hostToDocX(resizeCanvasLayer.frameX)
                                startTopDoc = view.hostToDocY(resizeCanvasLayer.frameY)
                                resizeCanvasLayer.dragDocX = startLeftDoc
                                resizeCanvasLayer.dragDocY = startTopDoc
                                resizeCanvasLayer.dragActive = true
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed) return
                                var pt = mapToItem(resizeCanvasLayer, mouse.x, mouse.y)
                                var dxDoc = (pt.x - startHostX) / Math.max(0.01, view.zoom)
                                var dyDoc = (pt.y - startHostY) / Math.max(0.01, view.zoom)
                                var fromCenter = (mouse.modifiers & Qt.AltModifier) !== 0
                                var mult = fromCenter ? 2.0 : 1.0
                                var newW = Math.max(1, Math.min(16384, startW + modelData.col * mult * dxDoc))
                                var newH = Math.max(1, Math.min(16384, startH + modelData.row * mult * dyDoc))
                                var keepRatio = resizeOptionsPanel.constraint || ((mouse.modifiers & Qt.ShiftModifier) !== 0)
                                if (keepRatio && startW > 0 && startH > 0) {
                                    var ratio = startW / startH
                                    if (modelData.col !== 0 && modelData.row !== 0) {
                                        if (Math.abs(newW - startW) / startW >= Math.abs(newH - startH) / startH) {
                                            newH = Math.max(1, Math.min(16384, newW / ratio))
                                            newW = Math.max(1, Math.min(16384, newH * ratio))
                                        } else {
                                            newW = Math.max(1, Math.min(16384, newH * ratio))
                                            newH = Math.max(1, Math.min(16384, newW / ratio))
                                        }
                                    } else if (modelData.col !== 0) {
                                        newH = Math.max(1, Math.min(16384, newW / ratio))
                                    } else if (modelData.row !== 0) {
                                        newW = Math.max(1, Math.min(16384, newH * ratio))
                                    }
                                }
                                newW = Math.round(newW)
                                newH = Math.round(newH)
                                // Keep the opposite edge/corner pinned on screen (or center when Alt is held).
                                var nextLeft = startLeftDoc
                                var nextTop = startTopDoc
                                if (fromCenter) {
                                    nextLeft = startLeftDoc + (startW - newW) / 2.0
                                    nextTop = startTopDoc + (startH - newH) / 2.0
                                } else {
                                    if (modelData.col === -1) nextLeft = startLeftDoc + (startW - newW)
                                    else if (modelData.col === 0) nextLeft = startLeftDoc + (startW - newW) / 2.0
                                    if (modelData.row === -1) nextTop = startTopDoc + (startH - newH)
                                    else if (modelData.row === 0) nextTop = startTopDoc + (startH - newH) / 2.0
                                }
                                resizeCanvasLayer.dragDocX = nextLeft
                                resizeCanvasLayer.dragDocY = nextTop
                                resizeOptionsPanel.setDimensions(newW, newH)
                            }
                        }
                    }
                }
            }

            // Live 60 fps GPU preview for Canvas Size: original image stays
            // fixed 1:1 while the outer canvas frame expands/shrinks with
            // background fill and interactive 8-handle dragging.
            Item {
                id: canvasSizeLayer
                objectName: "canvasSizeLayer"
                anchors.fill: parent
                visible: view.canvasSizeFrameShown

                readonly property real baseX: view.docToHostX(0)
                readonly property real baseY: view.docToHostY(0)
                readonly property real targetW: Math.max(1, canvasSizeOptionsPanel.targetWidth * view.zoom)
                readonly property real targetH: Math.max(1, canvasSizeOptionsPanel.targetHeight * view.zoom)
                readonly property real frameX: Math.round(baseX - canvasSizeOptionsPanel.effectiveOffsetX * view.zoom)
                readonly property real frameY: Math.round(baseY - canvasSizeOptionsPanel.effectiveOffsetY * view.zoom)

                // Dimmed ghost of original image so cropped edges stay visible when shrinking.
                Image {
                    x: canvasSizeLayer.baseX
                    y: canvasSizeLayer.baseY
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
                        x: canvasSizeOptionsPanel.effectiveOffsetX * view.zoom
                        y: canvasSizeOptionsPanel.effectiveOffsetY * view.zoom
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

                // 8 interactive drag handles (4 corners + 4 edges) for Canvas Size.
                Repeater {
                    model: [
                        { col: -1, row: -1 }, { col: 0, row: -1 }, { col: 1, row: -1 },
                        { col: 1, row: 0 },
                        { col: 1, row: 1 }, { col: 0, row: 1 }, { col: -1, row: 1 },
                        { col: -1, row: 0 }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        width: 12
                        height: 12
                        radius: (modelData.col !== 0 && modelData.row !== 0) ? 2 : 6
                        color: view.theme.accent
                        border.width: 1
                        border.color: view.theme.surface
                        x: canvasSizeLayer.frameX
                           + (modelData.col === -1 ? 0 : (modelData.col === 1 ? canvasSizeLayer.targetW : canvasSizeLayer.targetW / 2))
                           - width / 2
                        y: canvasSizeLayer.frameY
                           + (modelData.row === -1 ? 0 : (modelData.row === 1 ? canvasSizeLayer.targetH : canvasSizeLayer.targetH / 2))
                           - height / 2

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -3
                            acceptedButtons: Qt.LeftButton
                            cursorShape: modelData.col === 0
                                         ? Qt.SizeVerCursor
                                         : (modelData.row === 0
                                            ? Qt.SizeHorCursor
                                            : (modelData.col === modelData.row ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor))
                            property real startHostX: 0
                            property real startHostY: 0
                            property real startLeft: 0
                            property real startTop: 0
                            property real startRight: 1
                            property real startBottom: 1
                            onPressed: function(mouse) {
                                var pt = mapToItem(canvasSizeLayer, mouse.x, mouse.y)
                                startHostX = pt.x
                                startHostY = pt.y
                                startLeft = -canvasSizeOptionsPanel.effectiveOffsetX
                                startTop = -canvasSizeOptionsPanel.effectiveOffsetY
                                startRight = startLeft + Math.max(1, canvasSizeOptionsPanel.targetWidth)
                                startBottom = startTop + Math.max(1, canvasSizeOptionsPanel.targetHeight)
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed) return
                                var pt = mapToItem(canvasSizeLayer, mouse.x, mouse.y)
                                var dxDoc = (pt.x - startHostX) / Math.max(0.01, view.zoom)
                                var dyDoc = (pt.y - startHostY) / Math.max(0.01, view.zoom)
                                var fromCenter = (mouse.modifiers & Qt.AltModifier) !== 0
                                var keepRatio = canvasSizeOptionsPanel.lockRatio || ((mouse.modifiers & Qt.ShiftModifier) !== 0)
                                var startW = Math.max(1, startRight - startLeft)
                                var startH = Math.max(1, startBottom - startTop)
                                var left = startLeft
                                var right = startRight
                                var top = startTop
                                var bottom = startBottom
                                if (fromCenter) {
                                    if (modelData.col === -1) {
                                        left = Math.round(startLeft + dxDoc)
                                        right = Math.round(startRight - dxDoc)
                                    } else if (modelData.col === 1) {
                                        right = Math.round(startRight + dxDoc)
                                        left = Math.round(startLeft - dxDoc)
                                    }
                                    if (modelData.row === -1) {
                                        top = Math.round(startTop + dyDoc)
                                        bottom = Math.round(startBottom - dyDoc)
                                    } else if (modelData.row === 1) {
                                        bottom = Math.round(startBottom + dyDoc)
                                        top = Math.round(startTop - dyDoc)
                                    }
                                    if (right <= left) { var mx = Math.round((startLeft + startRight) / 2); left = mx; right = mx + 1 }
                                    if (bottom <= top) { var my = Math.round((startTop + startBottom) / 2); top = my; bottom = my + 1 }
                                } else {
                                    if (modelData.col === -1) left = Math.min(right - 1, Math.round(startLeft + dxDoc))
                                    if (modelData.col === 1) right = Math.max(left + 1, Math.round(startRight + dxDoc))
                                    if (modelData.row === -1) top = Math.min(bottom - 1, Math.round(startTop + dyDoc))
                                    if (modelData.row === 1) bottom = Math.max(top + 1, Math.round(startBottom + dyDoc))
                                }
                                if (keepRatio && startW > 0 && startH > 0) {
                                    var ratio = startW / startH
                                    var w = Math.max(1, right - left)
                                    var h = Math.max(1, bottom - top)
                                    if (modelData.col !== 0 && modelData.row !== 0) {
                                        if (Math.abs(w - startW) / startW >= Math.abs(h - startH) / startH) {
                                            h = Math.max(1, Math.round(w / ratio))
                                        } else {
                                            w = Math.max(1, Math.round(h * ratio))
                                        }
                                    } else if (modelData.col !== 0) {
                                        h = Math.max(1, Math.round(w / ratio))
                                    } else if (modelData.row !== 0) {
                                        w = Math.max(1, Math.round(h * ratio))
                                    }
                                    if (fromCenter) {
                                        var cx = (startLeft + startRight) / 2.0
                                        var cy = (startTop + startBottom) / 2.0
                                        left = Math.round(cx - w / 2.0); right = left + w
                                        top = Math.round(cy - h / 2.0); bottom = top + h
                                    } else {
                                        if (modelData.col === -1) left = right - w
                                        else if (modelData.col === 1) right = left + w
                                        else { var mcx = (startLeft + startRight) / 2.0; left = Math.round(mcx - w / 2.0); right = left + w }
                                        if (modelData.row === -1) top = bottom - h
                                        else if (modelData.row === 1) bottom = top + h
                                        else { var mcy = (startTop + startBottom) / 2.0; top = Math.round(mcy - h / 2.0); bottom = top + h }
                                    }
                                }
                                // Keep at least 1 px overlap with original document so Crop/Grow is always valid.
                                if (left >= view.documentWidth) left = view.documentWidth - 1
                                if (right <= 0) right = 1
                                if (top >= view.documentHeight) top = view.documentHeight - 1
                                if (bottom <= 0) bottom = 1
                                canvasSizeOptionsPanel.setCustomFrame(
                                    Math.max(1, right - left),
                                    Math.max(1, bottom - top),
                                    -left,
                                    -top
                                )
                            }
                        }
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
                // the document bounds. On multi-layer documents targeting
                // `active_layer`, render exact 3-part split previews
                // (below + moving active layer + above) so sibling layers
                // stay rock-solid stationary while transforming!
                Item {
                    id: freeTransformFrame
                    objectName: "freeTransformFrame"
                    visible: view.transformMode === "free"
                    clip: true
                    x: view.docToHostX(0)
                    y: view.docToHostY(0)
                    width: Math.max(1, view.documentWidth * view.zoom)
                    height: Math.max(1, view.documentHeight * view.zoom)

                    readonly property bool useSelectionSplitPreview:
                        view.hasSelection
                        && !!(view.editor && (view.editor.ramSelectionRevision || 0) > 0)
                    readonly property bool useLayerSplitPreview:
                        !view.hasSelection
                        && (!view.hasMultipleLayers || view.effectiveToolTarget() === "active_layer")
                        && !!(view.editor && ((view.editor.ramLayerRevision || 0) > 0 || view.editor.activeLayerPreviewPath))
                    readonly property var activeSummary: view.activeLayerSummary()

                    Checkerboard {
                        anchors.fill: parent
                        visible: freeTransformFrame.useLayerSplitPreview
                                 || freeTransformFrame.useSelectionSplitPreview
                                 || !view.hasMultipleLayers
                                 || view.backgroundTransparent
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: !freeTransformFrame.useLayerSplitPreview
                                 && !freeTransformFrame.useSelectionSplitPreview
                                 && view.hasMultipleLayers
                                 && !view.backgroundTransparent
                        color: view.backgroundColor
                    }

                    // Selection Transform live 60 fps preview: stationary base (punched out)
                    // + floating selected pixels moving/scaling/rotating live!
                    Image {
                        visible: freeTransformFrame.useSelectionSplitPreview
                        anchors.fill: parent
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: freeTransformFrame.useSelectionSplitPreview
                                ? ("image://editor/sel_base?rev=" + view.editor.ramSelectionRevision)
                                : ""
                    }
                    Image {
                        id: selectionFloatTransformImage
                        objectName: "selectionFloatTransformImage"
                        visible: freeTransformFrame.useSelectionSplitPreview
                        x: transformCanvasLayer.activeRect.x * view.zoom
                        y: transformCanvasLayer.activeRect.y * view.zoom
                        width: Math.max(1, transformCanvasLayer.activeRect.width * view.zoom)
                        height: Math.max(1, transformCanvasLayer.activeRect.height * view.zoom)
                        rotation: view.transformRotation
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: freeTransformFrame.useSelectionSplitPreview
                                ? ("image://editor/sel_float?rev=" + view.editor.ramSelectionRevision)
                                : ""
                    }

                    // 1. Layers strictly BELOW active layer + solid canvas background (stationary)
                    Image {
                        visible: freeTransformFrame.useLayerSplitPreview
                                 && !!(view.editor && ((view.editor.ramLayerRevision || 0) > 0 || view.editor.belowActivePreviewPath))
                        anchors.fill: parent
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: {
                            if (!freeTransformFrame.useLayerSplitPreview || !view.editor) return ""
                            if ((view.editor.ramLayerRevision || 0) > 0) {
                                return "image://editor/below?rev=" + view.editor.ramLayerRevision
                            }
                            return view.editor.belowActivePreviewPath
                                   ? "file://" + view.editor.belowActivePreviewPath + "?rev=" + (view.editor.layerPreviewRevision || 0)
                                   : ""
                        }
                    }
                    // 2. ONLY the active layer (moves, scales, and rotates live — works on 1-layer and multi-layer!)
                    Image {
                        id: activeLayerTransformImage
                        objectName: "activeLayerTransformImage"
                        visible: freeTransformFrame.useLayerSplitPreview
                        x: transformCanvasLayer.activeRect.x * view.zoom
                        y: transformCanvasLayer.activeRect.y * view.zoom
                        width: Math.max(1, transformCanvasLayer.activeRect.width * view.zoom)
                        height: Math.max(1, transformCanvasLayer.activeRect.height * view.zoom)
                        rotation: view.transformRotation
                        opacity: (freeTransformFrame.activeSummary && freeTransformFrame.activeSummary.visible === false)
                                 ? 0.0
                                 : (freeTransformFrame.activeSummary && freeTransformFrame.activeSummary.opacity !== undefined
                                    ? freeTransformFrame.activeSummary.opacity : 1.0)
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: {
                            if (!freeTransformFrame.useLayerSplitPreview || !view.editor) return ""
                            if ((view.editor.ramLayerRevision || 0) > 0) {
                                return "image://editor/active?rev=" + view.editor.ramLayerRevision
                            }
                            return view.editor.activeLayerPreviewPath
                                   ? "file://" + view.editor.activeLayerPreviewPath + "?rev=" + (view.editor.layerPreviewRevision || 0)
                                   : ""
                        }
                    }
                    // 3. Layers strictly ABOVE active layer (stationary)
                    Image {
                        visible: freeTransformFrame.useLayerSplitPreview
                                 && !!(view.editor && ((view.editor.ramLayerRevision || 0) > 0 || view.editor.aboveActivePreviewPath))
                        anchors.fill: parent
                        fillMode: Image.Stretch
                        asynchronous: false
                        cache: false
                        source: {
                            if (!freeTransformFrame.useLayerSplitPreview || !view.editor) return ""
                            if ((view.editor.ramLayerRevision || 0) > 0) {
                                return "image://editor/above?rev=" + view.editor.ramLayerRevision
                            }
                            return view.editor.aboveActivePreviewPath
                                   ? "file://" + view.editor.aboveActivePreviewPath + "?rev=" + (view.editor.layerPreviewRevision || 0)
                                   : ""
                        }
                    }

                    // WholeImage / legacy fallback preview
                    Image {
                        id: freeTransformImage
                        objectName: "freeTransformImage"
                        visible: !freeTransformFrame.useLayerSplitPreview && !freeTransformFrame.useSelectionSplitPreview
                        x: view.hasSelection ? 0 : transformCanvasLayer.activeRect.x * view.zoom
                        y: view.hasSelection ? 0 : transformCanvasLayer.activeRect.y * view.zoom
                        width: Math.max(1, (view.hasSelection ? view.documentWidth : transformCanvasLayer.activeRect.width) * view.zoom)
                        height: Math.max(1, (view.hasSelection ? view.documentHeight : transformCanvasLayer.activeRect.height) * view.zoom)
                        rotation: view.hasSelection ? 0 : view.transformRotation
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
                enabled: !view.filterDialogOpen

                // ---------------------------------------------- interactive watermark region box
                Item {
                    id: watermarkRegionOverlay
                    objectName: "watermarkRegionOverlay"
                    anchors.fill: parent
                    visible: view.tool === "watermark" && view.documentReady
                             && (watermarkOptionsPanel.wmMode === "region"
                                 || (watermarkOptionsPanel.wmMode === "ai"
                                     && aiDetectorCombo.keys[aiDetectorCombo.currentIndex] === "none"))
                    enabled: visible && !view.spacePanning

                    onVisibleChanged: {
                        if (visible) view.ensureWmRegionInitialized()
                    }

                    // Drag anywhere on the canvas to draw a new watermark region.
                    MouseArea {
                        id: wmDrawArea
                        anchors.fill: parent
                        cursorShape: Qt.CrossCursor
                        property real startDocX: 0
                        property real startDocY: 0
                        onPressed: function(mouse) {
                            startDocX = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(mouse.x)))
                            startDocY = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(mouse.y)))
                            view.setWmRegion(startDocX, startDocY, 8, 8)
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed) return
                            var curX = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(mouse.x)))
                            var curY = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(mouse.y)))
                            var x1 = Math.min(startDocX, curX)
                            var y1 = Math.min(startDocY, curY)
                            var x2 = Math.max(startDocX, curX)
                            var y2 = Math.max(startDocY, curY)
                            view.setWmRegion(x1, y1, Math.max(8, x2 - x1), Math.max(8, y2 - y1))
                        }
                    }

                    // Visual watermark selection box with move & 4-corner resize handles.
                    Rectangle {
                        id: wmBox
                        objectName: "watermarkRegionBox"
                        visible: view.wmRegionW > 0 && view.wmRegionH > 0
                        x: view.docToHostX(view.wmRegionX)
                        y: view.docToHostY(view.wmRegionY)
                        width: Math.max(12, view.wmRegionW * view.zoom)
                        height: Math.max(12, view.wmRegionH * view.zoom)
                        color: "#38ef4444"
                        border.color: "#ef4444"
                        border.width: 2

                        // Size badge above the box
                        Rectangle {
                            x: 0
                            y: Math.max(-wmBox.y + 4, -height - 4)
                            width: wmBadgeLabel.implicitWidth + 10
                            height: wmBadgeLabel.implicitHeight + 4
                            radius: 3
                            color: "#d9ef4444"
                            Label {
                                id: wmBadgeLabel
                                anchors.centerIn: parent
                                text: view.wmRegionW + " × " + view.wmRegionH + " px"
                                color: "#ffffff"
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }

                        // Drag inside box to move it
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: 6
                            cursorShape: Qt.SizeAllCursor
                            property real dragStartX: 0
                            property real dragStartY: 0
                            property int origX: 0
                            property int origY: 0
                            onPressed: function(mouse) {
                                var p = mapToItem(watermarkRegionOverlay, mouse.x, mouse.y)
                                dragStartX = view.hostToDocX(p.x)
                                dragStartY = view.hostToDocY(p.y)
                                origX = view.wmRegionX
                                origY = view.wmRegionY
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed) return
                                var p = mapToItem(watermarkRegionOverlay, mouse.x, mouse.y)
                                var dx = view.hostToDocX(p.x) - dragStartX
                                var dy = view.hostToDocY(p.y) - dragStartY
                                view.setWmRegion(origX + dx, origY + dy, view.wmRegionW, view.wmRegionH)
                            }
                        }

                        // 4 corner resize handles
                        Repeater {
                            model: [
                                { corner: "tl", cx: 0, cy: 0, cursor: Qt.SizeFDiagCursor },
                                { corner: "tr", cx: 1, cy: 0, cursor: Qt.SizeBDiagCursor },
                                { corner: "bl", cx: 0, cy: 1, cursor: Qt.SizeBDiagCursor },
                                { corner: "br", cx: 1, cy: 1, cursor: Qt.SizeFDiagCursor }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: 12
                                height: 12
                                radius: 2
                                x: modelData.cx === 0 ? -6 : wmBox.width - 6
                                y: modelData.cy === 0 ? -6 : wmBox.height - 6
                                color: "#ffffff"
                                border.color: "#ef4444"
                                border.width: 2
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    cursorShape: modelData.cursor
                                    property int anchorX: 0
                                    property int anchorY: 0
                                    onPressed: {
                                        anchorX = modelData.cx === 0 ? (view.wmRegionX + view.wmRegionW) : view.wmRegionX
                                        anchorY = modelData.cy === 0 ? (view.wmRegionY + view.wmRegionH) : view.wmRegionY
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (!pressed) return
                                        var p = mapToItem(watermarkRegionOverlay, mouse.x, mouse.y)
                                        var curX = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(p.x)))
                                        var curY = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(p.y)))
                                        var x1 = Math.min(anchorX, curX)
                                        var y1 = Math.min(anchorY, curY)
                                        var x2 = Math.max(anchorX, curX)
                                        var y2 = Math.max(anchorY, curY)
                                        view.setWmRegion(x1, y1, Math.max(8, x2 - x1), Math.max(8, y2 - y1))
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------------------------------------------- interactive watermark brush mask
                Item {
                    id: watermarkBrushOverlay
                    objectName: "watermarkBrushOverlay"
                    anchors.fill: parent
                    visible: view.tool === "watermark" && view.documentReady
                             && watermarkOptionsPanel.wmMode === "ai"
                             && aiDetectorCombo.keys[aiDetectorCombo.currentIndex] === "brush"
                    enabled: visible && !view.spacePanning

                    Canvas {
                        id: wmBrushCanvas
                        anchors.fill: parent
                        renderStrategy: Canvas.Threaded
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var strokes = view.wmBrushStrokes || []
                            if (strokes.length === 0) return
                            ctx.strokeStyle = "rgba(239, 68, 68, 0.50)"
                            ctx.fillStyle = "rgba(239, 68, 68, 0.50)"
                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"
                            for (var i = 0; i < strokes.length; ++i) {
                                var s = strokes[i]
                                var pts = s.points || []
                                if (pts.length === 0) continue
                                var r = Math.max(1, s.radius * view.zoom)
                                if (pts.length === 1) {
                                    ctx.beginPath()
                                    ctx.arc(view.docToHostX(pts[0][0]), view.docToHostY(pts[0][1]), r, 0, Math.PI * 2)
                                    ctx.fill()
                                } else {
                                    ctx.lineWidth = r * 2
                                    ctx.beginPath()
                                    ctx.moveTo(view.docToHostX(pts[0][0]), view.docToHostY(pts[0][1]))
                                    for (var j = 1; j < pts.length; ++j) {
                                        ctx.lineTo(view.docToHostX(pts[j][0]), view.docToHostY(pts[j][1]))
                                    }
                                    ctx.stroke()
                                }
                            }
                        }
                    }

                    Connections {
                        target: view
                        function onZoomChanged() { if (watermarkBrushOverlay.visible) wmBrushCanvas.requestPaint() }
                        function onOffsetXChanged() { if (watermarkBrushOverlay.visible) wmBrushCanvas.requestPaint() }
                        function onOffsetYChanged() { if (watermarkBrushOverlay.visible) wmBrushCanvas.requestPaint() }
                        function onWmBrushStrokesChanged() { if (watermarkBrushOverlay.visible) wmBrushCanvas.requestPaint() }
                    }

                    onVisibleChanged: if (visible) wmBrushCanvas.requestPaint()

                    MouseArea {
                        id: wmBrushArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: containsMouse ? Qt.BlankCursor : Qt.ArrowCursor
                        property real hoverX: -1000
                        property real hoverY: -1000

                        onPressed: function(mouse) {
                            hoverX = mouse.x
                            hoverY = mouse.y
                            var dx = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(mouse.x)))
                            var dy = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(mouse.y)))
                            var next = (view.wmBrushStrokes || []).slice()
                            next.push({ radius: view.wmBrushRadius, points: [[dx, dy]] })
                            view.wmBrushStrokes = next
                            wmBrushCanvas.requestPaint()
                        }
                        onPositionChanged: function(mouse) {
                            hoverX = mouse.x
                            hoverY = mouse.y
                            if (!pressed) return
                            var strokes = view.wmBrushStrokes || []
                            if (strokes.length === 0) return
                            var dx = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(mouse.x)))
                            var dy = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(mouse.y)))
                            strokes[strokes.length - 1].points.push([dx, dy])
                            wmBrushCanvas.requestPaint()
                        }
                        onExited: {
                            hoverX = -1000
                            hoverY = -1000
                        }
                    }

                    // Live circular brush cursor preview
                    Rectangle {
                        visible: wmBrushArea.containsMouse
                        width: Math.max(6, view.wmBrushRadius * 2 * view.zoom)
                        height: width
                        radius: width / 2
                        x: wmBrushArea.hoverX - width / 2
                        y: wmBrushArea.hoverY - height / 2
                        color: "#22ef4444"
                        border.color: "#ef4444"
                        border.width: 1.5
                    }
                }

                // ---------------------------------------------- interactive Remove-BG refine brush (Erase BG / Restore FG)
                Item {
                    id: rembgBrushOverlay
                    objectName: "rembgBrushOverlay"
                    anchors.fill: parent
                    visible: view.tool === "removeBg" && view.documentReady
                             && removeBgOptionsPanel.rembgBrushMode !== "off"
                    enabled: visible && !view.spacePanning

                    property var activePoints: []
                    readonly property bool isRestore: removeBgOptionsPanel.rembgBrushMode === "restore"

                    Canvas {
                        id: rembgBrushCanvas
                        anchors.fill: parent
                        renderStrategy: Canvas.Threaded
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var pts = rembgBrushOverlay.activePoints || []
                            if (pts.length === 0) return
                            var col = rembgBrushOverlay.isRestore ? "rgba(34, 197, 94, 0.50)" : "rgba(239, 68, 68, 0.50)"
                            ctx.strokeStyle = col
                            ctx.fillStyle = col
                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"
                            var r = Math.max(1, removeBgOptionsPanel.rembgBrushRadius * view.zoom)
                            if (pts.length === 1) {
                                ctx.beginPath()
                                ctx.arc(view.docToHostX(pts[0][0]), view.docToHostY(pts[0][1]), r, 0, Math.PI * 2)
                                ctx.fill()
                            } else {
                                ctx.lineWidth = r * 2
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(pts[0][0]), view.docToHostY(pts[0][1]))
                                for (var j = 1; j < pts.length; ++j) {
                                    ctx.lineTo(view.docToHostX(pts[j][0]), view.docToHostY(pts[j][1]))
                                }
                                ctx.stroke()
                            }
                        }
                    }

                    MouseArea {
                        id: rembgBrushArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: containsMouse ? Qt.BlankCursor : Qt.ArrowCursor
                        property real hoverX: -1000
                        property real hoverY: -1000

                        onPressed: function(mouse) {
                            hoverX = mouse.x
                            hoverY = mouse.y
                            var dx = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(mouse.x)))
                            var dy = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(mouse.y)))
                            rembgBrushOverlay.activePoints = [[dx, dy]]
                            rembgBrushCanvas.requestPaint()
                        }
                        onPositionChanged: function(mouse) {
                            hoverX = mouse.x
                            hoverY = mouse.y
                            if (!pressed) return
                            var dx = Math.max(0, Math.min(view.documentWidth, view.hostToDocX(mouse.x)))
                            var dy = Math.max(0, Math.min(view.documentHeight, view.hostToDocY(mouse.y)))
                            rembgBrushOverlay.activePoints.push([dx, dy])
                            rembgBrushCanvas.requestPaint()
                        }
                        onReleased: {
                            var pts = rembgBrushOverlay.activePoints || []
                            rembgBrushOverlay.activePoints = []
                            rembgBrushCanvas.requestPaint()
                            if (pts.length === 0) return
                            var stroke = [{ radius: removeBgOptionsPanel.rembgBrushRadius, points: pts }]
                            view.command({
                                type: "editor_refine_alpha",
                                erase_strokes: rembgBrushOverlay.isRestore ? [] : stroke,
                                restore_strokes: rembgBrushOverlay.isRestore ? stroke : [],
                                softness: removeBgOptionsPanel.rembgBrushSoftness
                            })
                        }
                        onExited: {
                            hoverX = -1000
                            hoverY = -1000
                        }
                    }

                    Rectangle {
                        visible: rembgBrushArea.containsMouse
                        width: Math.max(6, removeBgOptionsPanel.rembgBrushRadius * 2 * view.zoom)
                        height: width
                        radius: width / 2
                        x: rembgBrushArea.hoverX - width / 2
                        y: rembgBrushArea.hoverY - height / 2
                        color: rembgBrushOverlay.isRestore ? "#2222c55e" : "#22ef4444"
                        border.color: rembgBrushOverlay.isRestore ? "#22c55e" : "#ef4444"
                        border.width: 1.5
                    }
                }

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
                // Unified rotated bounding box: outline, move area, 4 corners,
                // 4 edge handles, and top rotate handle all share ONE rotated
                // container (`transformOrigin: Item.Center`, `rotation: view.transformRotation`)
                // so Move, Scale, and Rotate stay 100% synchronized at any angle.
                Item {
                    id: transformOverlay
                    objectName: "transformOverlay"
                    anchors.fill: parent
                    visible: view.transformFrameShown
                    enabled: visible && !view.spacePanning

                    readonly property var box: view.transformRect()
                                               || ({ x: 0, y: 0,
                                                     width: view.documentWidth,
                                                     height: view.documentHeight })

                    Item {
                        id: transformBoxContainer
                        objectName: "transformBoxContainer"
                        x: view.docToHostX(transformOverlay.box.x)
                        y: view.docToHostY(transformOverlay.box.y)
                        width: Math.max(1, transformOverlay.box.width * view.zoom)
                        height: Math.max(1, transformOverlay.box.height * view.zoom)
                        transformOrigin: Item.Center
                        rotation: view.transformRotation

                        // Inside-box drag repositions the box in unrotated canvas space
                        // (Shift locks axis, Ctrl snaps to edges/centre/10 px).
                        MouseArea {
                            id: transformMoveArea
                            objectName: "transformMoveArea"
                            anchors.fill: parent
                            visible: view.transformMode === "free"
                            enabled: visible
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.SizeAllCursor
                            property real startHostX: 0
                            property real startHostY: 0
                            property var startRect: null

                            onPressed: function(mouse) {
                                view.forceActiveFocus()
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

                        // Bounding box outline.
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"
                            border.width: 1.5
                            border.color: view.theme.accent
                        }

                        // Rotate handle stem + round knob above top-center.
                        Rectangle {
                            x: transformBoxContainer.width / 2 - 0.75
                            y: -24
                            width: 1.5
                            height: 24
                            color: view.theme.accent
                        }
                        Rectangle {
                            id: transformRotateHandle
                            objectName: "transformRotateHandle"
                            x: transformBoxContainer.width / 2 - width / 2
                            y: -32
                            width: 14
                            height: 14
                            radius: 7
                            color: view.theme.surface
                            border.width: 2
                            border.color: view.theme.accent

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -4
                                acceptedButtons: Qt.LeftButton
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                property real centerHostX: 0
                                property real centerHostY: 0
                                property real startMouseAngle: 0
                                property real startRotation: 0
                                onPressed: function(mouse) {
                                    view.forceActiveFocus()
                                    var r = view.transformRect()
                                    if (!r) return
                                    centerHostX = view.docToHostX(r.x + r.width / 2.0)
                                    centerHostY = view.docToHostY(r.y + r.height / 2.0)
                                    var pt = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                    startMouseAngle = Math.atan2(pt.y - centerHostY, pt.x - centerHostX) * 180.0 / Math.PI
                                    startRotation = view.transformRotation
                                }
                                onPositionChanged: function(mouse) {
                                    if (!pressed) return
                                    var pt = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                    var curAngle = Math.atan2(pt.y - centerHostY, pt.x - centerHostX) * 180.0 / Math.PI
                                    var next = startRotation + (curAngle - startMouseAngle)
                                    while (next > 180) next -= 360
                                    while (next < -180) next += 360
                                    if ((mouse.modifiers & Qt.ShiftModifier) !== 0) {
                                        next = Math.round(next / 15.0) * 15.0
                                    } else {
                                        next = Math.round(next * 2.0) / 2.0
                                    }
                                    view.transformRotation = next
                                }
                            }
                        }

                        // Four corner handles.
                        Repeater {
                            model: [
                                { idx: 0, rx: 0, ry: 0 },
                                { idx: 1, rx: 1, ry: 0 },
                                { idx: 2, rx: 1, ry: 1 },
                                { idx: 3, rx: 0, ry: 1 }
                            ]

                            Rectangle {
                                required property var modelData
                                objectName: "transformCorner_" + modelData.idx
                                width: 12
                                height: 12
                                radius: 2
                                color: view.theme.accent
                                border.width: 1
                                border.color: view.theme.surface
                                x: modelData.rx * transformBoxContainer.width - width / 2
                                y: modelData.ry * transformBoxContainer.height - height / 2

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -3
                                    acceptedButtons: Qt.LeftButton
                                    cursorShape: (modelData.idx === 0 || modelData.idx === 2)
                                                 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                                    property var startRect: null
                                    onPressed: {
                                        view.forceActiveFocus()
                                        startRect = view.transformRect()
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (!pressed) return
                                        var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                        view.dragTransformCorner(modelData.idx, point.x, point.y,
                                                                 mouse.modifiers, startRect)
                                    }
                                }
                            }
                        }

                        // Four edge handles, at each edge's midpoint.
                        Repeater {
                            model: [
                                { idx: 0, rx: 0.5, ry: 0 },
                                { idx: 1, rx: 1,   ry: 0.5 },
                                { idx: 2, rx: 0.5, ry: 1 },
                                { idx: 3, rx: 0,   ry: 0.5 }
                            ]

                            Rectangle {
                                required property var modelData
                                objectName: "transformEdge_" + modelData.idx
                                width: 10
                                height: 10
                                radius: 5
                                color: view.theme.surface
                                border.width: 2
                                border.color: view.theme.accent
                                x: modelData.rx * transformBoxContainer.width - width / 2
                                y: modelData.ry * transformBoxContainer.height - height / 2

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -3
                                    acceptedButtons: Qt.LeftButton
                                    cursorShape: (modelData.idx === 0 || modelData.idx === 2)
                                                 ? Qt.SizeVerCursor : Qt.SizeHorCursor
                                    property var startRect: null
                                    onPressed: {
                                        view.forceActiveFocus()
                                        startRect = view.transformRect()
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (!pressed) return
                                        var point = mapToItem(canvasOverlay, mouse.x, mouse.y)
                                        view.dragTransformEdge(modelData.idx, point.x, point.y,
                                                               mouse.modifiers, startRect)
                                    }
                                }
                            }
                        }
                    }
                }

                // Left-click outside the image (on the matte) while Pointer tool
                // is active quickly deselects any active selection.
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    enabled: view.documentReady && view.tool === "pointer" && view.hasSelection
                    onTapped: function(eventPoint) {
                        var dx = view.hostToDocX(eventPoint.position.x)
                        var dy = view.hostToDocY(eventPoint.position.y)
                        if (dx < 0 || dy < 0 || dx >= view.documentWidth || dy >= view.documentHeight) {
                            view.command({ type: "editor_select_clear" })
                        }
                    }
                }

                // Right-click canvas context menu (clipboard, layer & selection actions).
                // TapHandler on RightButton never steals left-button drags.
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    enabled: view.documentReady
                    onTapped: function(eventPoint) {
                        canvasContextMenu.popup(eventPoint.position.x, eventPoint.position.y)
                    }
                }

                AppMenu {
                    id: canvasContextMenu
                    objectName: "editorCanvasContextMenu"
                    theme: view.theme
                    implicitWidth: 220

                    MenuItem {
                        text: qsTr("Copy")
                        enabled: view.documentReady
                        onTriggered: view.command({ type: "editor_selection_copy", cut: false })
                    }
                    MenuItem {
                        text: qsTr("Cut")
                        enabled: view.documentReady
                        onTriggered: view.command({ type: "editor_selection_copy", cut: true })
                    }
                    MenuItem {
                        text: qsTr("Paste")
                        enabled: view.documentReady
                        onTriggered: view.requestPasteImage()
                    }
                    MenuItem {
                        text: view.hasSelection ? qsTr("To new layer") : qsTr("Duplicate layer")
                        enabled: view.documentReady
                        onTriggered: {
                            if (view.hasSelection) {
                                view.command({ type: "editor_selection_duplicate_layer" })
                            } else if (view.activeLayerId > 0) {
                                view.command({ type: "editor_layer_duplicate", id: view.activeLayerId })
                            }
                        }
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Transform")
                        enabled: view.documentReady
                        onTriggered: {
                            view.tool = "transform"
                            view.resetTransformCorners()
                        }
                    }
                    MenuItem {
                        text: qsTr("Select all")
                        enabled: view.documentReady
                        onTriggered: view.command({ type: "editor_select_all" })
                    }
                    MenuItem {
                        text: qsTr("Deselect")
                        enabled: view.documentReady && view.hasSelection
                        onTriggered: view.command({ type: "editor_select_clear" })
                    }
                    MenuItem {
                        text: qsTr("Invert")
                        enabled: view.documentReady && view.hasSelection
                        onTriggered: view.command({ type: "editor_select_invert" })
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Fill…")
                        enabled: view.documentReady && view.hasSelection
                        onTriggered: selectionFillDialog.openDialog()
                    }
                    MenuItem {
                        text: qsTr("Stroke…")
                        enabled: view.documentReady && view.hasSelection
                        onTriggered: selectionStrokeDialog.openDialog()
                    }
                    MenuItem {
                        text: qsTr("Delete")
                        enabled: view.documentReady && view.hasSelection
                        onTriggered: view.command({ type: "editor_selection_delete" })
                    }
                    MenuItem {
                        text: qsTr("Crop")
                        enabled: view.documentReady && view.hasSelection
                        onTriggered: view.command({ type: "editor_selection_crop" })
                    }
                }

                // ------------------------------------------------ active selection overlay
                // Marching-ants contour rendered by Core, visible across every tool
                // (so Brush/Eraser clearly show the exact masked boundary).
                Image {
                    id: selectionOverlayImage
                    objectName: "selectionOverlayImage"
                    visible: view.hasSelection && view.editor
                             && ((view.editor.ramSelectionRevision || 0) > 0 || !!view.editor.selectionOverlayPath)
                             && !view.transformFrameShown && !view.rotateFrameShown
                             && !view.resizeFrameShown && !view.canvasSizeFrameShown
                    x: view.docToHostX(0) + selectOverlay.moveDx * view.zoom
                    y: view.docToHostY(0) + selectOverlay.moveDy * view.zoom
                    width: Math.max(1, view.displayedWidth * view.zoom)
                    height: Math.max(1, view.displayedHeight * view.zoom)
                    fillMode: Image.Stretch
                    asynchronous: false
                    cache: false
                    smooth: true
                    mipmap: true
                    source: {
                        if (!view.editor) return ""
                        if ((view.editor.ramSelectionRevision || 0) > 0) {
                            if (view.selectionDisplayMode === "mask") {
                                return "image://editor/sel_red?rev=" + view.editor.ramSelectionRevision
                            }
                            return (view.selectionAntsPhase
                                    ? "image://editor/selection2?rev="
                                    : "image://editor/selection?rev=")
                                   + view.editor.ramSelectionRevision
                        }
                        return view.editor.selectionOverlayPath
                               ? "file://" + view.editor.selectionOverlayPath + "?rev=" + (view.editor.selectionRevision || 0)
                               : ""
                    }
                }

                // ------------------------------------------------ selection tool drag
                Item {
                    id: selectOverlay
                    objectName: "selectOverlay"
                    anchors.fill: parent
                    visible: view.tool === "select" && view.documentReady
                    enabled: visible && !view.spacePanning

                    property bool dragging: false
                    property bool movingSelection: false
                    property real moveStartDocX: 0
                    property real moveStartDocY: 0
                    property real moveDx: 0
                    property real moveDy: 0
                    property string activeDragMode: "replace"
                    property real startDocX: 0
                    property real startDocY: 0
                    property real curDocX: 0
                    property real curDocY: 0
                    property var lassoPoints: []
                    property var polyPoints: []
                    property var bezierNodes: []
                    property bool bezierDraggingHandle: false
                    property real polyHoverDocX: 0
                    property real polyHoverDocY: 0
                    property bool polyHoveringClose: false
                    property string polyDragMode: "replace"

                    onVisibleChanged: {
                        if (!visible && polyPoints.length > 0) cancelPolygon()
                        if (!visible && bezierNodes.length > 0) cancelBezier()
                    }
                    Connections {
                        target: view
                        function onSelectShapeChanged() {
                            if (selectOverlay.polyPoints.length > 0) selectOverlay.cancelPolygon()
                            if (selectOverlay.bezierNodes.length > 0) selectOverlay.cancelBezier()
                        }
                    }

                    function finishBezier() {
                        var nodes = selectOverlay.bezierNodes
                        selectOverlay.bezierNodes = []
                        selectOverlay.bezierDraggingHandle = false
                        selectOverlay.polyHoveringClose = false
                        selectDragCanvas.requestPaint()
                        if (nodes.length >= 3) {
                            var pts = drawOverlay.tessellateBezier(nodes, true)
                            if (pts.length >= 3) {
                                view.command({
                                    type: "editor_select_lasso",
                                    points: pts,
                                    mode: selectOverlay.polyDragMode,
                                    feather: view.selectFeather
                                })
                            }
                        }
                    }

                    function cancelBezier() {
                        selectOverlay.bezierNodes = []
                        selectOverlay.bezierDraggingHandle = false
                        selectOverlay.polyHoveringClose = false
                        selectDragCanvas.requestPaint()
                    }

                    function popBezierNode() {
                        if (selectOverlay.bezierNodes.length === 0) return
                        selectOverlay.bezierNodes = selectOverlay.bezierNodes.slice(0, selectOverlay.bezierNodes.length - 1)
                        selectOverlay.bezierDraggingHandle = false
                        selectOverlay.polyHoveringClose = false
                        selectDragCanvas.requestPaint()
                    }

                    function finishPolygon() {
                        var pts = selectOverlay.polyPoints
                        selectOverlay.polyPoints = []
                        selectOverlay.polyHoveringClose = false
                        selectDragCanvas.requestPaint()
                        if (pts.length >= 3) {
                            view.command({
                                type: "editor_select_lasso",
                                points: pts,
                                mode: selectOverlay.polyDragMode,
                                feather: view.selectFeather
                            })
                        }
                    }

                    function cancelPolygon() {
                        selectOverlay.polyPoints = []
                        selectOverlay.polyHoveringClose = false
                        selectDragCanvas.requestPaint()
                    }

                    function popPolygonPoint() {
                        if (selectOverlay.polyPoints.length === 0) return
                        var pts = selectOverlay.polyPoints.slice(0, selectOverlay.polyPoints.length - 1)
                        selectOverlay.polyPoints = pts
                        selectOverlay.polyHoveringClose = false
                        selectDragCanvas.requestPaint()
                    }

                    function pointInSelectionBounds(docX, docY) {
                        var sb = view.editor ? view.editor.selectionBounds : null
                        if (!sb || sb.length !== 4) return false
                        return docX >= sb[0] && docY >= sb[1]
                               && docX <= sb[0] + sb[2] && docY <= sb[1] + sb[3]
                    }

                    Canvas {
                        id: selectDragCanvas
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            if (view.selectShape === "bezier" && selectOverlay.bezierNodes.length > 0) {
                                var bnodes = selectOverlay.bezierNodes
                                var bn = bnodes.length
                                ctx.save()
                                ctx.lineWidth = 1.5
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(bnodes[0].x), view.docToHostY(bnodes[0].y))
                                for (var bi = 1; bi < bn; ++bi) {
                                    var ba = bnodes[bi - 1]
                                    var bb = bnodes[bi]
                                    ctx.bezierCurveTo(
                                        view.docToHostX(ba.outX), view.docToHostY(ba.outY),
                                        view.docToHostX(bb.inX), view.docToHostY(bb.inY),
                                        view.docToHostX(bb.x), view.docToHostY(bb.y))
                                }
                                if (bn >= 3 && selectOverlay.polyHoveringClose) {
                                    var bl = bnodes[bn - 1]
                                    var bf = bnodes[0]
                                    ctx.bezierCurveTo(
                                        view.docToHostX(bl.outX), view.docToHostY(bl.outY),
                                        view.docToHostX(bf.inX), view.docToHostY(bf.inY),
                                        view.docToHostX(bf.x), view.docToHostY(bf.y))
                                    ctx.closePath()
                                } else if (!selectOverlay.bezierDraggingHandle) {
                                    var bt = bnodes[bn - 1]
                                    ctx.bezierCurveTo(
                                        view.docToHostX(bt.outX), view.docToHostY(bt.outY),
                                        view.docToHostX(selectOverlay.polyHoverDocX), view.docToHostY(selectOverlay.polyHoverDocY),
                                        view.docToHostX(selectOverlay.polyHoverDocX), view.docToHostY(selectOverlay.polyHoverDocY))
                                }
                                ctx.strokeStyle = "#d0000000"
                                ctx.stroke()
                                ctx.setLineDash([5, 5])
                                ctx.strokeStyle = "#f0ffffff"
                                ctx.stroke()
                                ctx.setLineDash([])
                                for (var bni = 0; bni < bn; ++bni) {
                                    var bnd = bnodes[bni]
                                    var bax = view.docToHostX(bnd.x)
                                    var bay = view.docToHostY(bnd.y)
                                    var binX = view.docToHostX(bnd.inX)
                                    var binY = view.docToHostY(bnd.inY)
                                    var boutX = view.docToHostX(bnd.outX)
                                    var boutY = view.docToHostY(bnd.outY)
                                    ctx.strokeStyle = "#4a9eff"
                                    ctx.lineWidth = 1.2
                                    if (Math.hypot(binX - bax, binY - bay) > 1.5) {
                                        ctx.beginPath(); ctx.moveTo(bax, bay); ctx.lineTo(binX, binY); ctx.stroke()
                                        ctx.fillStyle = "#ffffff"; ctx.beginPath(); ctx.arc(binX, binY, 3, 0, Math.PI * 2); ctx.fill(); ctx.stroke()
                                    }
                                    if (Math.hypot(boutX - bax, boutY - bay) > 1.5) {
                                        ctx.beginPath(); ctx.moveTo(bax, bay); ctx.lineTo(boutX, boutY); ctx.stroke()
                                        ctx.fillStyle = "#ffffff"; ctx.beginPath(); ctx.arc(boutX, boutY, 3, 0, Math.PI * 2); ctx.fill(); ctx.stroke()
                                    }
                                    var bFirstClose = bni === 0 && bn >= 3 && selectOverlay.polyHoveringClose
                                    ctx.fillStyle = bFirstClose ? view.theme.accent : "#ffffff"
                                    ctx.strokeStyle = "#111111"
                                    ctx.fillRect(bax - 3.5, bay - 3.5, 7, 7)
                                    ctx.strokeRect(bax - 3.5, bay - 3.5, 7, 7)
                                }
                                ctx.restore()
                                return
                            }
                            if (view.selectShape === "polygon" && selectOverlay.polyPoints.length > 0) {
                                var ppts = selectOverlay.polyPoints
                                ctx.save()
                                ctx.lineWidth = 1.5
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(ppts[0][0]), view.docToHostY(ppts[0][1]))
                                for (var pi = 1; pi < ppts.length; ++pi) {
                                    ctx.lineTo(view.docToHostX(ppts[pi][0]), view.docToHostY(ppts[pi][1]))
                                }
                                ctx.lineTo(view.docToHostX(selectOverlay.polyHoverDocX),
                                           view.docToHostY(selectOverlay.polyHoverDocY))
                                ctx.strokeStyle = "#d0000000"
                                ctx.stroke()
                                ctx.setLineDash([5, 5])
                                ctx.strokeStyle = "#f0ffffff"
                                ctx.stroke()
                                ctx.setLineDash([])
                                for (var vi = 0; vi < ppts.length; ++vi) {
                                    var vx = view.docToHostX(ppts[vi][0])
                                    var vy = view.docToHostY(ppts[vi][1])
                                    var isFirstClose = vi === 0 && ppts.length >= 3 && selectOverlay.polyHoveringClose
                                    ctx.beginPath()
                                    ctx.arc(vx, vy, isFirstClose ? 6 : 3.5, 0, Math.PI * 2)
                                    ctx.fillStyle = isFirstClose ? view.theme.accent : "#ffffff"
                                    ctx.fill()
                                    ctx.strokeStyle = "#111111"
                                    ctx.lineWidth = 1.2
                                    ctx.stroke()
                                }
                                ctx.restore()
                                return
                            }
                            if (!selectOverlay.dragging) return
                            ctx.save()
                            ctx.lineWidth = 1.5
                            if (view.selectShape === "lasso") {
                                var pts = selectOverlay.lassoPoints
                                if (!pts || pts.length < 2) { ctx.restore(); return }
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(pts[0][0]), view.docToHostY(pts[0][1]))
                                for (var i = 1; i < pts.length; ++i) {
                                    ctx.lineTo(view.docToHostX(pts[i][0]), view.docToHostY(pts[i][1]))
                                }
                                ctx.closePath()
                                ctx.strokeStyle = "#d0000000"
                                ctx.stroke()
                                ctx.setLineDash([5, 5])
                                ctx.strokeStyle = "#f0ffffff"
                                ctx.stroke()
                            } else {
                                var x0 = view.docToHostX(Math.min(selectOverlay.startDocX, selectOverlay.curDocX))
                                var y0 = view.docToHostY(Math.min(selectOverlay.startDocY, selectOverlay.curDocY))
                                var rw = Math.abs(view.docToHostX(selectOverlay.curDocX) - view.docToHostX(selectOverlay.startDocX))
                                var rh = Math.abs(view.docToHostY(selectOverlay.curDocY) - view.docToHostY(selectOverlay.startDocY))
                                ctx.beginPath()
                                if (view.selectShape === "ellipse") {
                                    ctx.ellipse(x0, y0, Math.max(1, rw), Math.max(1, rh))
                                } else {
                                    ctx.rect(x0, y0, Math.max(1, rw), Math.max(1, rh))
                                }
                                ctx.strokeStyle = "#d0000000"
                                ctx.stroke()
                                ctx.setLineDash([5, 5])
                                ctx.strokeStyle = "#f0ffffff"
                                ctx.stroke()
                            }
                            ctx.restore()
                        }
                    }

                    MouseArea {
                        id: selectArea
                        objectName: "selectArea"
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        property bool hoverInsideSelection: false
                        cursorShape: (selectOverlay.movingSelection
                                      || (hoverInsideSelection
                                          && view.hasSelection
                                          && view.selectShape !== "wand"
                                          && view.selectMode === "replace"))
                                     ? Qt.SizeAllCursor : Qt.CrossCursor
                        onExited: hoverInsideSelection = false
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            var rawDx = view.hostToDocX(mouse.x)
                            var rawDy = view.hostToDocY(mouse.y)
                            var dx = Math.max(0, Math.min(view.documentWidth - 1, rawDx))
                            var dy = Math.max(0, Math.min(view.documentHeight - 1, rawDy))
                            var shift = (mouse.modifiers & Qt.ShiftModifier) !== 0
                            var alt = (mouse.modifiers & Qt.AltModifier) !== 0
                            var mode = (shift && alt)
                                     ? "intersect"
                                     : (alt
                                        ? "subtract"
                                        : ((shift && view.hasSelection) ? "add" : view.selectMode))
                            if (view.selectShape === "wand" || view.selectShape === "similar") {
                                if (rawDx < 0 || rawDy < 0 || rawDx >= view.documentWidth || rawDy >= view.documentHeight) {
                                    if (view.hasSelection) view.command({ type: "editor_select_clear" })
                                    return
                                }
                                view.command({
                                    type: "editor_select_magic_wand",
                                    x: Math.floor(dx),
                                    y: Math.floor(dy),
                                    tolerance: view.wandTolerance,
                                    contiguous: view.selectShape === "similar" ? false : view.wandContiguous,
                                    sample_all_layers: view.wandSampleAllLayers,
                                    mode: mode,
                                    feather: view.selectFeather
                                })
                                return
                            }
                            if (view.selectShape === "bezier") {
                                if (selectOverlay.bezierNodes.length === 0) {
                                    selectOverlay.polyDragMode = mode
                                }
                                var bnodes = selectOverlay.bezierNodes.slice()
                                if (bnodes.length >= 3) {
                                    var bfx = view.docToHostX(bnodes[0].x)
                                    var bfy = view.docToHostY(bnodes[0].y)
                                    if (Math.hypot(mouse.x - bfx, mouse.y - bfy) <= 10) {
                                        selectOverlay.finishBezier()
                                        return
                                    }
                                }
                                bnodes.push({ x: dx, y: dy, inX: dx, inY: dy, outX: dx, outY: dy })
                                selectOverlay.bezierNodes = bnodes
                                selectOverlay.bezierDraggingHandle = true
                                selectOverlay.polyHoverDocX = dx
                                selectOverlay.polyHoverDocY = dy
                                selectDragCanvas.requestPaint()
                                return
                            }
                            if (view.selectShape === "polygon") {
                                // Starting a new polygon captures the active combine mode; clicking
                                // near the first vertex (>= 3 points) closes the polygon cleanly.
                                if (selectOverlay.polyPoints.length === 0) {
                                    // Still allow dragging inside an existing selection to move its frame
                                    // if the user drags, or clicking to start a polygon vertex.
                                    selectOverlay.polyDragMode = mode
                                }
                                var ppts = selectOverlay.polyPoints.slice()
                                if (ppts.length >= 3) {
                                    var fx = view.docToHostX(ppts[0][0])
                                    var fy = view.docToHostY(ppts[0][1])
                                    if (Math.hypot(mouse.x - fx, mouse.y - fy) <= 10) {
                                        selectOverlay.finishPolygon()
                                        return
                                    }
                                }
                                ppts.push([dx, dy])
                                selectOverlay.polyPoints = ppts
                                selectOverlay.polyHoverDocX = dx
                                selectOverlay.polyHoverDocY = dy
                                selectDragCanvas.requestPaint()
                                return
                            }
                            // Dragging inside an existing selection in Replace mode (no Shift/Alt)
                            // moves the selection boundary itself at 60 fps without moving pixels.
                            if (mode === "replace" && !shift && !alt && view.hasSelection
                                    && selectOverlay.pointInSelectionBounds(rawDx, rawDy)) {
                                selectOverlay.movingSelection = true
                                selectOverlay.moveStartDocX = rawDx
                                selectOverlay.moveStartDocY = rawDy
                                selectOverlay.moveDx = 0
                                selectOverlay.moveDy = 0
                                return
                            }
                            selectOverlay.activeDragMode = mode
                            selectOverlay.dragging = true
                            selectOverlay.startDocX = dx
                            selectOverlay.startDocY = dy
                            selectOverlay.curDocX = dx
                            selectOverlay.curDocY = dy
                            selectOverlay.lassoPoints = [[dx, dy]]
                            selectDragCanvas.requestPaint()
                        }
                        onDoubleClicked: function(mouse) {
                            if (view.selectShape === "polygon" && selectOverlay.polyPoints.length >= 3) {
                                selectOverlay.finishPolygon()
                            } else if (view.selectShape === "bezier" && selectOverlay.bezierNodes.length >= 3) {
                                if (selectOverlay.bezierNodes.length > 3) {
                                    selectOverlay.bezierNodes = selectOverlay.bezierNodes.slice(0, selectOverlay.bezierNodes.length - 1)
                                }
                                selectOverlay.finishBezier()
                            }
                        }
                        onPositionChanged: function(mouse) {
                            var rawDx = view.hostToDocX(mouse.x)
                            var rawDy = view.hostToDocY(mouse.y)
                            if (view.selectShape === "bezier" && selectOverlay.bezierNodes.length > 0) {
                                var cdx = Math.max(0, Math.min(view.documentWidth, rawDx))
                                var cdy = Math.max(0, Math.min(view.documentHeight, rawDy))
                                selectOverlay.polyHoverDocX = cdx
                                selectOverlay.polyHoverDocY = cdy
                                if (selectOverlay.bezierDraggingHandle) {
                                    var bnodes = selectOverlay.bezierNodes.slice()
                                    var last = bnodes[bnodes.length - 1]
                                    var breakSym = (mouse.modifiers & Qt.AltModifier) !== 0
                                    bnodes[bnodes.length - 1] = {
                                        x: last.x, y: last.y,
                                        inX: breakSym ? last.inX : (last.x - (cdx - last.x)),
                                        inY: breakSym ? last.inY : (last.y - (cdy - last.y)),
                                        outX: cdx, outY: cdy
                                    }
                                    selectOverlay.bezierNodes = bnodes
                                } else if (selectOverlay.bezierNodes.length >= 3) {
                                    var b0 = selectOverlay.bezierNodes[0]
                                    selectOverlay.polyHoveringClose =
                                        Math.hypot(mouse.x - view.docToHostX(b0.x), mouse.y - view.docToHostY(b0.y)) <= 10
                                }
                                selectDragCanvas.requestPaint()
                                return
                            }
                            if (view.selectShape === "polygon" && selectOverlay.polyPoints.length > 0) {
                                selectOverlay.polyHoverDocX = Math.max(0, Math.min(view.documentWidth, rawDx))
                                selectOverlay.polyHoverDocY = Math.max(0, Math.min(view.documentHeight, rawDy))
                                var firstPt = selectOverlay.polyPoints[0]
                                selectOverlay.polyHoveringClose = selectOverlay.polyPoints.length >= 3
                                    && Math.hypot(mouse.x - view.docToHostX(firstPt[0]),
                                                  mouse.y - view.docToHostY(firstPt[1])) <= 10
                                selectDragCanvas.requestPaint()
                                return
                            }
                            if (!pressed) {
                                hoverInsideSelection = view.hasSelection
                                                       && selectOverlay.pointInSelectionBounds(rawDx, rawDy)
                                return
                            }
                            if (selectOverlay.movingSelection) {
                                var mdx = Math.round(rawDx - selectOverlay.moveStartDocX)
                                var mdy = Math.round(rawDy - selectOverlay.moveStartDocY)
                                if ((mouse.modifiers & Qt.ShiftModifier) !== 0) {
                                    if (Math.abs(mdx) >= Math.abs(mdy)) mdy = 0
                                    else mdx = 0
                                }
                                selectOverlay.moveDx = mdx
                                selectOverlay.moveDy = mdy
                                return
                            }
                            if (!selectOverlay.dragging) return
                            var dx = Math.max(0, Math.min(view.documentWidth, rawDx))
                            var dy = Math.max(0, Math.min(view.documentHeight, rawDy))
                            if (view.selectShape === "lasso") {
                                var pts = selectOverlay.lassoPoints
                                var last = pts[pts.length - 1]
                                if (!last || Math.hypot(dx - last[0], dy - last[1]) >= 2.0) {
                                    pts.push([dx, dy])
                                    selectOverlay.lassoPoints = pts
                                }
                            } else {
                                if ((mouse.modifiers & Qt.ShiftModifier) !== 0) {
                                    var side = Math.max(Math.abs(dx - selectOverlay.startDocX),
                                                        Math.abs(dy - selectOverlay.startDocY))
                                    dx = selectOverlay.startDocX + (dx >= selectOverlay.startDocX ? side : -side)
                                    dy = selectOverlay.startDocY + (dy >= selectOverlay.startDocY ? side : -side)
                                }
                                selectOverlay.curDocX = dx
                                selectOverlay.curDocY = dy
                            }
                            selectDragCanvas.requestPaint()
                        }
                        onReleased: function(mouse) {
                            if (view.selectShape === "bezier" && selectOverlay.bezierDraggingHandle) {
                                selectOverlay.bezierDraggingHandle = false
                                selectDragCanvas.requestPaint()
                                return
                            }
                            if (selectOverlay.movingSelection) {
                                selectOverlay.movingSelection = false
                                var mdx = Math.round(selectOverlay.moveDx)
                                var mdy = Math.round(selectOverlay.moveDy)
                                selectOverlay.moveDx = 0
                                selectOverlay.moveDy = 0
                                if (Math.abs(mdx) >= 1 || Math.abs(mdy) >= 1) {
                                    view.command({ type: "editor_select_move", dx: mdx, dy: mdy })
                                } else if (view.hasSelection) {
                                    view.command({ type: "editor_select_clear" })
                                }
                                return
                            }
                            if (!selectOverlay.dragging) return
                            selectOverlay.dragging = false
                            selectDragCanvas.requestPaint()
                            var mode = selectOverlay.activeDragMode
                            if (view.selectShape === "lasso") {
                                var pts = selectOverlay.lassoPoints
                                selectOverlay.lassoPoints = []
                                if (pts.length >= 3) {
                                    view.command({
                                        type: "editor_select_lasso",
                                        points: pts,
                                        mode: mode,
                                        feather: view.selectFeather
                                    })
                                } else if (mode === "replace" && view.hasSelection) {
                                    view.command({ type: "editor_select_clear" })
                                }
                                return
                            }
                            var x = Math.round(Math.min(selectOverlay.startDocX, selectOverlay.curDocX))
                            var y = Math.round(Math.min(selectOverlay.startDocY, selectOverlay.curDocY))
                            var w = Math.round(Math.abs(selectOverlay.curDocX - selectOverlay.startDocX))
                            var h = Math.round(Math.abs(selectOverlay.curDocY - selectOverlay.startDocY))
                            if (w < 2 || h < 2) {
                                if (mode === "replace" && view.hasSelection) {
                                    view.command({ type: "editor_select_clear" })
                                }
                                return
                            }
                            view.command({
                                type: view.selectShape === "ellipse" ? "editor_select_ellipse" : "editor_select_rect",
                                x: x,
                                y: y,
                                width: w,
                                height: h,
                                mode: mode,
                                feather: view.selectFeather
                            })
                        }
                        onCanceled: {
                            selectOverlay.movingSelection = false
                            selectOverlay.moveDx = 0
                            selectOverlay.moveDy = 0
                            selectOverlay.dragging = false
                            selectOverlay.lassoPoints = []
                            selectDragCanvas.requestPaint()
                        }
                    }
                }

                // ------------------------------------------ Liquify warp tool (live RAM warp)
                Item {
                    id: liquifyOverlay
                    objectName: "liquifyOverlay"
                    anchors.fill: parent
                    visible: view.tool === "liquify" && view.documentReady
                    enabled: visible && !view.spacePanning

                    property var pendingPts: []
                    property var lastDocPt: null
                    property bool dragging: false
                    property real cursorX: -1000
                    property real cursorY: -1000
                    property bool cursorInside: false

                    Timer {
                        id: liquifyFlushTimer
                        interval: 24
                        repeat: true
                        onTriggered: {
                            if (!liquifyOverlay.dragging) return
                            if (liquifyOverlay.pendingPts.length > 0) {
                                var batch = liquifyOverlay.pendingPts.slice()
                                liquifyOverlay.pendingPts = []
                                view.command({ type: "editor_live_stroke_step", points: batch })
                            } else if (view.liquifyMode !== "push" && liquifyOverlay.lastDocPt) {
                                // Continuous Bloat / Pucker / Twirl while holding mouse stationary
                                view.command({ type: "editor_live_stroke_step", points: [liquifyOverlay.lastDocPt] })
                            }
                        }
                    }

                    // Circular Liquify brush cursor
                    Rectangle {
                        visible: liquifyOverlay.cursorInside
                        readonly property real d: Math.max(8, view.liquifyRadius * 2 * view.zoom)
                        width: d
                        height: d
                        radius: d / 2
                        x: liquifyOverlay.cursorX - d / 2
                        y: liquifyOverlay.cursorY - d / 2
                        color: "transparent"
                        border.width: 1.5
                        border.color: "#ffffff"
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: width / 2
                            color: "transparent"
                            border.width: 1
                            border.color: Qt.rgba(0, 0, 0, 0.65)
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 4; height: 4; radius: 2
                            color: view.theme.accent
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.BlankCursor
                        onEntered: liquifyOverlay.cursorInside = true
                        onExited: liquifyOverlay.cursorInside = false
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            liquifyOverlay.cursorX = mouse.x
                            liquifyOverlay.cursorY = mouse.y
                            var dx = view.hostToDocX(mouse.x)
                            var dy = view.hostToDocY(mouse.y)
                            liquifyOverlay.lastDocPt = [dx, dy]
                            liquifyOverlay.pendingPts = []
                            liquifyOverlay.dragging = true
                            view.command({
                                type: "editor_live_stroke_begin",
                                kind: "liquify",
                                mode: view.liquifyMode,
                                radius: view.liquifyRadius,
                                strength: view.liquifyStrength / 100.0,
                                x: dx,
                                y: dy
                            })
                            liquifyFlushTimer.start()
                        }
                        onPositionChanged: function(mouse) {
                            liquifyOverlay.cursorX = mouse.x
                            liquifyOverlay.cursorY = mouse.y
                            liquifyOverlay.cursorInside = true
                            if (!liquifyOverlay.dragging) return
                            var dx = view.hostToDocX(mouse.x)
                            var dy = view.hostToDocY(mouse.y)
                            var last = liquifyOverlay.lastDocPt
                            if (!last || Math.hypot(dx - last[0], dy - last[1]) >= 2.0) {
                                liquifyOverlay.lastDocPt = [dx, dy]
                                liquifyOverlay.pendingPts.push([dx, dy])
                            }
                        }
                        onReleased: {
                            if (!liquifyOverlay.dragging) return
                            liquifyFlushTimer.stop()
                            liquifyOverlay.dragging = false
                            if (liquifyOverlay.pendingPts.length > 0) {
                                var batch = liquifyOverlay.pendingPts.slice()
                                liquifyOverlay.pendingPts = []
                                view.command({ type: "editor_live_stroke_step", points: batch })
                            }
                            liquifyOverlay.lastDocPt = null
                            view.command({ type: "editor_live_stroke_end", commit: true })
                        }
                        onCanceled: {
                            if (!liquifyOverlay.dragging) return
                            liquifyFlushTimer.stop()
                            liquifyOverlay.dragging = false
                            liquifyOverlay.pendingPts = []
                            liquifyOverlay.lastDocPt = null
                            view.command({ type: "editor_live_stroke_end", commit: false })
                        }
                    }
                }

                // ------------------------------------------ Zoom tool (click & scrubby drag)
                Item {
                    id: zoomOverlay
                    objectName: "zoomOverlay"
                    anchors.fill: parent
                    visible: view.tool === "zoom" && view.documentReady
                    enabled: visible && !view.spacePanning

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.CrossCursor
                        property real pressX: 0
                        property real pressY: 0
                        property real lastX: 0
                        property bool scrubbed: false
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            pressX = mouse.x
                            pressY = mouse.y
                            lastX = mouse.x
                            scrubbed = false
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed || mouse.button === Qt.RightButton) return
                            var dx = mouse.x - lastX
                            if (!scrubbed && Math.abs(mouse.x - pressX) < 5) return
                            scrubbed = true
                            lastX = mouse.x
                            if (Math.abs(dx) >= 1) {
                                var factor = Math.pow(1.01, dx)
                                view.zoomAt(factor, pressX, pressY)
                            }
                        }
                        onReleased: function(mouse) {
                            if (scrubbed) return
                            var alt = (mouse.modifiers & Qt.AltModifier) !== 0
                            var zoomOut = (mouse.button === Qt.RightButton)
                                          || (view.zoomToolMode === "out" ? !alt : alt)
                            view.zoomAt(zoomOut ? (1 / 1.25) : 1.25, mouse.x, mouse.y)
                        }
                    }
                }

                // ------------------------------------------ Krita Fill (Paint Bucket)
                Item {
                    id: fillOverlay
                    objectName: "fillOverlay"
                    anchors.fill: parent
                    visible: view.tool === "fill" && view.documentReady
                    enabled: visible && !view.spacePanning

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.CrossCursor
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            var docX = Math.floor(view.hostToDocX(mouse.x))
                            var docY = Math.floor(view.hostToDocY(mouse.y))
                            if (docX < 0 || docY < 0 || docX >= view.documentWidth || docY >= view.documentHeight) return
                            var col = view.fillSource === "background"
                                      ? view.backgroundBytes()
                                      : view.foregroundBytes()
                            view.command({
                                type: "editor_flood_fill",
                                x: docX,
                                y: docY,
                                color: col,
                                opacity: Math.max(0.01, view.fillOpacity / 100.0),
                                tolerance: view.fillTolerance,
                                grow: view.fillGrow,
                                contiguous: view.fillContiguous,
                                sample_all_layers: view.fillSampleAllLayers
                            })
                        }
                    }
                }

                // ------------------------------------------ Krita Gradient tool
                Item {
                    id: gradientOverlay
                    objectName: "gradientOverlay"
                    anchors.fill: parent
                    visible: view.tool === "gradient" && view.documentReady
                    enabled: visible && !view.spacePanning

                    property bool dragging: false
                    property string dragTarget: "new" // "new" | "start" | "end"
                    property bool hasDraft: false
                    property real startDocX: 0
                    property real startDocY: 0
                    property real endDocX: 0
                    property real endDocY: 0
                    property bool shiftHeld: false

                    onVisibleChanged: if (!visible && hasDraft) cancelDraft()
                    Connections {
                        target: view
                        function onGradientShapeChanged() { gradientOverlay.repaintPreview() }
                        function onGradientColorModeChanged() { gradientOverlay.repaintPreview() }
                        function onGradientStopsChanged() { gradientOverlay.repaintPreview() }
                        function onGradientReverseChanged() { gradientOverlay.repaintPreview() }
                        function onGradientOpacityChanged() { gradientOverlay.repaintPreview() }
                        function onForegroundColorChanged() { gradientOverlay.repaintPreview() }
                        function onBackgroundColorChanged() { gradientOverlay.repaintPreview() }
                        function onZoomChanged() { gradientOverlay.repaintPreview() }
                        function onOffsetXChanged() { gradientOverlay.repaintPreview() }
                        function onOffsetYChanged() { gradientOverlay.repaintPreview() }
                    }

                    function repaintPreview() {
                        if (gradientOverlay.visible) gradientPreviewCanvas.requestPaint()
                    }

                    function cancelDraft() {
                        gradientOverlay.dragging = false
                        gradientOverlay.hasDraft = false
                        gradientPreviewCanvas.requestPaint()
                    }

                    function applyDraft() {
                        if (!gradientOverlay.hasDraft) return
                        var sx = gradientOverlay.startDocX
                        var sy = gradientOverlay.startDocY
                        var ex = gradientOverlay.endDocX
                        var ey = gradientOverlay.endDocY
                        gradientOverlay.hasDraft = false
                        gradientOverlay.dragging = false
                        gradientPreviewCanvas.requestPaint()
                        if (Math.hypot(ex - sx, ey - sy) < 1.0) return
                        var resolved = view.resolvedGradientStops()
                        var wireStops = []
                        for (var i = 0; i < resolved.length; ++i) {
                            wireStops.push({
                                pos: resolved[i].pos,
                                color: view.colorBytes(resolved[i].hex),
                                alpha: resolved[i].alpha
                            })
                        }
                        var first = wireStops[0]
                        var last = wireStops[wireStops.length - 1]
                        view.command({
                            type: "editor_gradient",
                            start: [sx, sy],
                            end: [ex, ey],
                            start_color: first.color,
                            start_alpha: first.alpha,
                            end_color: last.color,
                            end_alpha: last.alpha,
                            stops: wireStops,
                            opacity: Math.max(0.01, view.gradientOpacity / 100.0),
                            shape: view.gradientShape,
                            repeat: view.gradientRepeat,
                            reverse: view.gradientReverse,
                            dither: view.gradientDither,
                            blend_mode: view.gradientBlendMode
                        })
                    }

                    Canvas {
                        id: gradientPreviewCanvas
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            if (!gradientOverlay.dragging && !gradientOverlay.hasDraft) return

                            var x0 = view.docToHostX(gradientOverlay.startDocX)
                            var y0 = view.docToHostY(gradientOverlay.startDocY)
                            var x1 = view.docToHostX(gradientOverlay.endDocX)
                            var y1 = view.docToHostY(gradientOverlay.endDocY)
                            var imgL = view.docToHostX(0)
                            var imgT = view.docToHostY(0)
                            var imgW = view.docToHostX(view.displayedWidth) - imgL
                            var imgH = view.docToHostY(view.displayedHeight) - imgT

                            function rgbaCss(hex, alpha) {
                                var b = view.colorBytes(hex)
                                return "rgba(" + b[0] + "," + b[1] + "," + b[2] + "," + alpha.toFixed(3) + ")"
                            }

                            var stops = view.resolvedGradientStops()
                            if (view.gradientReverse) {
                                var rev = []
                                for (var ri = stops.length - 1; ri >= 0; --ri) {
                                    rev.push({ pos: 1.0 - stops[ri].pos, hex: stops[ri].hex, alpha: stops[ri].alpha })
                                }
                                stops = rev
                            }

                            // 1. Live clipped gradient preview over document frame
                            if (Math.hypot(x1 - x0, y1 - y0) >= 2 && imgW > 1 && imgH > 1) {
                                ctx.save()
                                ctx.beginPath()
                                ctx.rect(imgL, imgT, imgW, imgH)
                                ctx.clip()
                                ctx.globalAlpha = Math.max(0.05, view.gradientOpacity / 100.0)
                                var grad = null
                                if (view.gradientShape === "radial") {
                                    var rad = Math.hypot(x1 - x0, y1 - y0)
                                    grad = ctx.createRadialGradient(x0, y0, 0, x0, y0, Math.max(1, rad))
                                    for (var si = 0; si < stops.length; ++si) {
                                        grad.addColorStop(stops[si].pos, rgbaCss(stops[si].hex, stops[si].alpha))
                                    }
                                } else if (view.gradientShape === "bilinear") {
                                    var bx0 = x0 - (x1 - x0)
                                    var by0 = y0 - (y1 - y0)
                                    grad = ctx.createLinearGradient(bx0, by0, x1, y1)
                                    for (var bi = stops.length - 1; bi >= 0; --bi) {
                                        grad.addColorStop(0.5 - stops[bi].pos * 0.5, rgbaCss(stops[bi].hex, stops[bi].alpha))
                                    }
                                    for (var bi2 = 0; bi2 < stops.length; ++bi2) {
                                        grad.addColorStop(0.5 + stops[bi2].pos * 0.5, rgbaCss(stops[bi2].hex, stops[bi2].alpha))
                                    }
                                } else {
                                    grad = ctx.createLinearGradient(x0, y0, x1, y1)
                                    for (var li = 0; li < stops.length; ++li) {
                                        grad.addColorStop(stops[li].pos, rgbaCss(stops[li].hex, stops[li].alpha))
                                    }
                                }
                                if (grad) {
                                    ctx.fillStyle = grad
                                    ctx.fillRect(imgL, imgT, imgW, imgH)
                                }
                                ctx.restore()
                            }

                            // 2. Guide vector & draggable Start/End handles
                            ctx.save()
                            ctx.beginPath()
                            ctx.moveTo(x0, y0)
                            ctx.lineTo(x1, y1)
                            ctx.strokeStyle = "#cc000000"
                            ctx.lineWidth = 2.5
                            ctx.stroke()
                            ctx.strokeStyle = "#ffffff"
                            ctx.lineWidth = 1.2
                            ctx.setLineDash([4, 4])
                            ctx.stroke()
                            ctx.setLineDash([])

                            function drawKnob(kx, ky, stop, isStart) {
                                ctx.beginPath()
                                ctx.arc(kx, ky, 7, 0, Math.PI * 2)
                                ctx.fillStyle = rgbaCss(stop.hex, Math.max(0.25, stop.alpha))
                                ctx.fill()
                                ctx.strokeStyle = "#111111"
                                ctx.lineWidth = 2.2
                                ctx.stroke()
                                ctx.strokeStyle = isStart ? "#4a9eff" : "#ffffff"
                                ctx.lineWidth = 1.3
                                ctx.stroke()
                            }
                            if (stops.length >= 2) {
                                drawKnob(x0, y0, stops[0], true)
                                drawKnob(x1, y1, stops[stops.length - 1], false)
                            }
                            ctx.restore()
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        cursorShape: Qt.CrossCursor
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            var dx = view.hostToDocX(mouse.x)
                            var dy = view.hostToDocY(mouse.y)
                            gradientOverlay.shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
                            // Allow grabbing existing Start or End handle when interactive draft is active
                            if (gradientOverlay.hasDraft) {
                                var sx = view.docToHostX(gradientOverlay.startDocX)
                                var sy = view.docToHostY(gradientOverlay.startDocY)
                                var ex = view.docToHostX(gradientOverlay.endDocX)
                                var ey = view.docToHostY(gradientOverlay.endDocY)
                                if (Math.hypot(mouse.x - sx, mouse.y - sy) <= 12) {
                                    gradientOverlay.dragTarget = "start"
                                    gradientOverlay.dragging = true
                                    return
                                }
                                if (Math.hypot(mouse.x - ex, mouse.y - ey) <= 12) {
                                    gradientOverlay.dragTarget = "end"
                                    gradientOverlay.dragging = true
                                    return
                                }
                            }
                            gradientOverlay.dragTarget = "new"
                            gradientOverlay.dragging = true
                            gradientOverlay.hasDraft = true
                            gradientOverlay.startDocX = dx
                            gradientOverlay.startDocY = dy
                            gradientOverlay.endDocX = dx
                            gradientOverlay.endDocY = dy
                            gradientPreviewCanvas.requestPaint()
                        }
                        onPositionChanged: function(mouse) {
                            if (!gradientOverlay.dragging) return
                            var dx = view.hostToDocX(mouse.x)
                            var dy = view.hostToDocY(mouse.y)
                            var shift = (mouse.modifiers & Qt.ShiftModifier) !== 0
                            gradientOverlay.shiftHeld = shift
                            if (gradientOverlay.dragTarget === "start") {
                                var sp = shift
                                         ? drawOverlay.snapAngle(gradientOverlay.endDocX, gradientOverlay.endDocY, dx, dy)
                                         : [dx, dy]
                                gradientOverlay.startDocX = sp[0]
                                gradientOverlay.startDocY = sp[1]
                            } else {
                                var ep = shift
                                         ? drawOverlay.snapAngle(gradientOverlay.startDocX, gradientOverlay.startDocY, dx, dy)
                                         : [dx, dy]
                                gradientOverlay.endDocX = ep[0]
                                gradientOverlay.endDocY = ep[1]
                            }
                            gradientPreviewCanvas.requestPaint()
                        }
                        onReleased: function(mouse) {
                            if (!gradientOverlay.dragging) return
                            gradientOverlay.dragging = false
                            if (Math.hypot(gradientOverlay.endDocX - gradientOverlay.startDocX,
                                           gradientOverlay.endDocY - gradientOverlay.startDocY) < 1.0) {
                                gradientOverlay.hasDraft = false
                                gradientPreviewCanvas.requestPaint()
                                return
                            }
                            if (!view.gradientInteractive) {
                                gradientOverlay.applyDraft()
                            } else {
                                gradientPreviewCanvas.requestPaint()
                            }
                        }
                        onDoubleClicked: function(mouse) {
                            if (gradientOverlay.hasDraft) gradientOverlay.applyDraft()
                        }
                    }
                }

                // ------------------------------------------ Krita shapes & curves
                // Interactive vector/shape preview overlay for Line, Polyline,
                // Bezier Curve, Rectangle, Ellipse, and Polygon tools. Commits
                // one `editor_draw_shape` command to Core so active layer offset
                // and active selection masking are applied atomically.
                Item {
                    id: drawOverlay
                    objectName: "drawOverlay"
                    anchors.fill: parent
                    visible: view.tool === "draw" && view.documentReady
                    enabled: visible && !view.spacePanning

                    property bool dragging: false
                    property real startDocX: 0
                    property real startDocY: 0
                    property real curDocX: 0
                    property real curDocY: 0
                    property bool shiftHeld: false
                    property bool altHeld: false
                    // Multi-point vertices for Polyline / Polygon: [[x, y], ...]
                    property var pathPoints: []
                    // Cubic Bezier anchors: [{ x, y, inX, inY, outX, outY }, ...]
                    property var bezierNodes: []
                    property bool bezierDraggingHandle: false
                    property real hoverDocX: 0
                    property real hoverDocY: 0
                    property bool hoverInside: false
                    property bool hoveringClose: false
                    readonly property bool hasDraftPath: pathPoints.length > 0 || bezierNodes.length > 0

                    onVisibleChanged: if (!visible && hasDraftPath) cancelDraft()
                    Connections {
                        target: view
                        function onDrawShapeChanged() {
                            if (drawOverlay.hasDraftPath) drawOverlay.cancelDraft()
                        }
                        function onZoomChanged() { if (drawOverlay.visible) drawPreviewCanvas.requestPaint() }
                        function onOffsetXChanged() { if (drawOverlay.visible) drawPreviewCanvas.requestPaint() }
                        function onOffsetYChanged() { if (drawOverlay.visible) drawPreviewCanvas.requestPaint() }
                    }

                    function snapAngle(ax, ay, bx, by) {
                        var dx = bx - ax
                        var dy = by - ay
                        var len = Math.sqrt(dx * dx + dy * dy)
                        if (len < 1e-4) return [bx, by]
                        var step = Math.PI / 12 // 15 deg
                        var angle = Math.round(Math.atan2(dy, dx) / step) * step
                        return [ax + Math.cos(angle) * len, ay + Math.sin(angle) * len]
                    }

                    function computeBoxEndpoints(ax, ay, bx, by, square, fromCenter) {
                        var dx = bx - ax
                        var dy = by - ay
                        if (square) {
                            var side = Math.max(Math.abs(dx), Math.abs(dy))
                            dx = dx >= 0 ? side : -side
                            dy = dy >= 0 ? side : -side
                        }
                        if (fromCenter) {
                            return [[ax - dx, ay - dy], [ax + dx, ay + dy]]
                        }
                        return [[ax, ay], [ax + dx, ay + dy]]
                    }

                    /// Inkscape-style Regular Polygon / Star vertex generator centered at (cx, cy).
                    function computeStarPolygonPoints(cx, cy, ex, ey, snap) {
                        var endPt = snap ? drawOverlay.snapAngle(cx, cy, ex, ey) : [ex, ey]
                        var outerR = Math.hypot(endPt[0] - cx, endPt[1] - cy)
                        if (outerR < 0.5) return []
                        var baseAngle = Math.atan2(endPt[1] - cy, endPt[0] - cx)
                        var n = Math.max(3, Math.min(24, view.drawStarCorners))
                        var pts = []
                        if (view.drawStarIsPolygon) {
                            for (var i = 0; i < n; ++i) {
                                var a = baseAngle + (Math.PI * 2 * i) / n
                                pts.push([cx + Math.cos(a) * outerR, cy + Math.sin(a) * outerR])
                            }
                        } else {
                            var innerR = outerR * Math.max(0.1, Math.min(0.95, view.drawStarSpokeRatio))
                            var total = n * 2
                            for (var j = 0; j < total; ++j) {
                                var ang = baseAngle + (Math.PI * 2 * j) / total
                                var r = (j % 2 === 0) ? outerR : innerR
                                pts.push([cx + Math.cos(ang) * r, cy + Math.sin(ang) * r])
                            }
                        }
                        return pts
                    }

                    function tessellateBezier(nodes, closed) {
                        var pts = []
                        var n = nodes.length
                        if (n === 0) return pts
                        if (n === 1) return [[nodes[0].x, nodes[0].y]]
                        var segCount = closed ? n : (n - 1)
                        for (var i = 0; i < segCount; ++i) {
                            var a = nodes[i]
                            var b = nodes[(i + 1) % n]
                            var p0x = a.x, p0y = a.y
                            var p1x = a.outX, p1y = a.outY
                            var p2x = b.inX, p2y = b.inY
                            var p3x = b.x, p3y = b.y
                            var chord = Math.hypot(p3x - p0x, p3y - p0y)
                            var ctrl = Math.hypot(p1x - p0x, p1y - p0y)
                                     + Math.hypot(p2x - p1x, p2y - p1y)
                                     + Math.hypot(p3x - p2x, p3y - p2y)
                            var approxLen = 0.5 * (chord + ctrl)
                            var steps = Math.max(8, Math.min(96, Math.ceil(approxLen / 2.0)))
                            var startJ = (i === 0) ? 0 : 1
                            for (var j = startJ; j <= steps; ++j) {
                                var t = j / steps
                                var u = 1 - t
                                var u2 = u * u
                                var t2 = t * t
                                var x = u2 * u * p0x + 3 * u2 * t * p1x + 3 * u * t2 * p2x + t2 * t * p3x
                                var y = u2 * u * p0y + 3 * u2 * t * p1y + 3 * u * t2 * p2y + t2 * t * p3y
                                pts.push([x, y])
                            }
                        }
                        return pts
                    }

                    function commitShape(kind, points, closed) {
                        var strokeColor = view.drawColorForMode(view.drawOutlineMode)
                        var fillAllowed = (kind === "rect" || kind === "ellipse" || kind === "polygon"
                                           || (kind === "bezier" && closed))
                        var fillColor = fillAllowed ? view.drawColorForMode(view.drawFillMode) : null
                        if (!strokeColor && !fillColor) return
                        var cmd = {
                            type: "editor_draw_shape",
                            kind: kind,
                            points: points,
                            closed: !!closed,
                            stroke_width: view.drawStrokeWidth,
                            stroke_opacity: view.drawStrokeOpacity / 100.0,
                            fill_opacity: view.drawFillOpacity / 100.0
                        }
                        if (strokeColor) cmd.stroke_color = strokeColor
                        if (fillColor) cmd.fill_color = fillColor
                        view.command(cmd)
                    }

                    function finishPath(forceClose) {
                        if (view.drawShape === "polyline") {
                            var pts = drawOverlay.pathPoints
                            drawOverlay.pathPoints = []
                            drawOverlay.hoveringClose = false
                            drawPreviewCanvas.requestPaint()
                            if (pts.length >= 2) {
                                drawOverlay.commitShape("polyline", pts, false)
                            }
                        } else if (view.drawShape === "polygon") {
                            var ppts = drawOverlay.pathPoints
                            drawOverlay.pathPoints = []
                            drawOverlay.hoveringClose = false
                            drawPreviewCanvas.requestPaint()
                            if (ppts.length >= 3) {
                                drawOverlay.commitShape("polygon", ppts, true)
                            }
                        } else if (view.drawShape === "bezier") {
                            var nodes = drawOverlay.bezierNodes
                            drawOverlay.bezierNodes = []
                            drawOverlay.bezierDraggingHandle = false
                            drawOverlay.hoveringClose = false
                            drawPreviewCanvas.requestPaint()
                            if (nodes.length >= 2) {
                                var closed = !!forceClose || view.drawBezierClosed
                                var sampled = drawOverlay.tessellateBezier(nodes, closed)
                                drawOverlay.commitShape("bezier", sampled, closed)
                            }
                        }
                    }

                    function popLastPoint() {
                        if (drawOverlay.pathPoints.length > 0) {
                            drawOverlay.pathPoints = drawOverlay.pathPoints.slice(0, drawOverlay.pathPoints.length - 1)
                            drawOverlay.hoveringClose = false
                            drawPreviewCanvas.requestPaint()
                        } else if (drawOverlay.bezierNodes.length > 0) {
                            drawOverlay.bezierNodes = drawOverlay.bezierNodes.slice(0, drawOverlay.bezierNodes.length - 1)
                            drawOverlay.bezierDraggingHandle = false
                            drawOverlay.hoveringClose = false
                            drawPreviewCanvas.requestPaint()
                        }
                    }

                    function cancelDraft() {
                        drawOverlay.dragging = false
                        drawOverlay.pathPoints = []
                        drawOverlay.bezierNodes = []
                        drawOverlay.bezierDraggingHandle = false
                        drawOverlay.hoveringClose = false
                        drawPreviewCanvas.requestPaint()
                    }

                    Canvas {
                        id: drawPreviewCanvas
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var strokeHex = view.drawHexForMode(view.drawOutlineMode)
                            var fillHex = view.drawHexForMode(view.drawFillMode)
                            var strokeW = Math.max(1, view.drawStrokeWidth * view.zoom)
                            var strokeOp = view.drawStrokeOpacity / 100.0
                            var fillOp = view.drawFillOpacity / 100.0

                            // Helper to draw filled + stroked current path
                            function paintPath(allowFill) {
                                if (allowFill && fillHex) {
                                    ctx.save()
                                    ctx.globalAlpha = fillOp
                                    ctx.fillStyle = fillHex
                                    ctx.fill()
                                    ctx.restore()
                                }
                                if (strokeHex) {
                                    ctx.save()
                                    ctx.globalAlpha = strokeOp
                                    ctx.strokeStyle = strokeHex
                                    ctx.lineWidth = strokeW
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.stroke()
                                    ctx.restore()
                                } else {
                                    // Guide outline when outline is disabled so user sees shape
                                    ctx.save()
                                    ctx.strokeStyle = "#4a9eff"
                                    ctx.lineWidth = 1.25
                                    ctx.setLineDash([4, 4])
                                    ctx.stroke()
                                    ctx.restore()
                                }
                            }

                            // 1. Drag shapes: Line / Rect / Ellipse
                            if (drawOverlay.dragging) {
                                if (view.drawShape === "line") {
                                    var endPt = drawOverlay.shiftHeld
                                                ? drawOverlay.snapAngle(drawOverlay.startDocX, drawOverlay.startDocY,
                                                                        drawOverlay.curDocX, drawOverlay.curDocY)
                                                : [drawOverlay.curDocX, drawOverlay.curDocY]
                                    ctx.beginPath()
                                    ctx.moveTo(view.docToHostX(drawOverlay.startDocX), view.docToHostY(drawOverlay.startDocY))
                                    ctx.lineTo(view.docToHostX(endPt[0]), view.docToHostY(endPt[1]))
                                    paintPath(false)
                                } else if (view.drawShape === "rect" || view.drawShape === "ellipse") {
                                    var box = drawOverlay.computeBoxEndpoints(
                                        drawOverlay.startDocX, drawOverlay.startDocY,
                                        drawOverlay.curDocX, drawOverlay.curDocY,
                                        drawOverlay.shiftHeld, drawOverlay.altHeld)
                                    var hx0 = view.docToHostX(Math.min(box[0][0], box[1][0]))
                                    var hy0 = view.docToHostY(Math.min(box[0][1], box[1][1]))
                                    var hx1 = view.docToHostX(Math.max(box[0][0], box[1][0]))
                                    var hy1 = view.docToHostY(Math.max(box[0][1], box[1][1]))
                                    ctx.beginPath()
                                    if (view.drawShape === "rect") {
                                        ctx.rect(hx0, hy0, hx1 - hx0, hy1 - hy0)
                                    } else {
                                        var cx = (hx0 + hx1) * 0.5
                                        var cy = (hy0 + hy1) * 0.5
                                        var rx = Math.max(0.5, (hx1 - hx0) * 0.5)
                                        var ry = Math.max(0.5, (hy1 - hy0) * 0.5)
                                        ctx.save()
                                        ctx.translate(cx, cy)
                                        ctx.scale(rx, ry)
                                        ctx.arc(0, 0, 1, 0, Math.PI * 2)
                                        ctx.restore()
                                    }
                                    paintPath(true)
                                } else if (view.drawShape === "star") {
                                    var spts = drawOverlay.computeStarPolygonPoints(
                                        drawOverlay.startDocX, drawOverlay.startDocY,
                                        drawOverlay.curDocX, drawOverlay.curDocY,
                                        drawOverlay.shiftHeld)
                                    if (spts.length >= 3) {
                                        ctx.beginPath()
                                        ctx.moveTo(view.docToHostX(spts[0][0]), view.docToHostY(spts[0][1]))
                                        for (var si = 1; si < spts.length; ++si) {
                                            ctx.lineTo(view.docToHostX(spts[si][0]), view.docToHostY(spts[si][1]))
                                        }
                                        ctx.closePath()
                                        paintPath(true)
                                    }
                                }
                                return
                            }

                            // 2. Polyline / Polygon
                            if ((view.drawShape === "polyline" || view.drawShape === "polygon")
                                    && drawOverlay.pathPoints.length > 0) {
                                var pts = drawOverlay.pathPoints
                                var isPoly = view.drawShape === "polygon"
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(pts[0][0]), view.docToHostY(pts[0][1]))
                                for (var i = 1; i < pts.length; ++i) {
                                    ctx.lineTo(view.docToHostX(pts[i][0]), view.docToHostY(pts[i][1]))
                                }
                                if (drawOverlay.hoverInside) {
                                    var lastP = pts[pts.length - 1]
                                    var hp = drawOverlay.shiftHeld
                                             ? drawOverlay.snapAngle(lastP[0], lastP[1], drawOverlay.hoverDocX, drawOverlay.hoverDocY)
                                             : [drawOverlay.hoverDocX, drawOverlay.hoverDocY]
                                    ctx.lineTo(view.docToHostX(hp[0]), view.docToHostY(hp[1]))
                                }
                                if (isPoly && pts.length >= 2) {
                                    ctx.closePath()
                                }
                                paintPath(isPoly && pts.length >= 3)

                                // Draw vertices
                                for (var vi = 0; vi < pts.length; ++vi) {
                                    var vx = view.docToHostX(pts[vi][0])
                                    var vy = view.docToHostY(pts[vi][1])
                                    ctx.fillStyle = (vi === 0 && drawOverlay.hoveringClose) ? "#4a9eff" : "#ffffff"
                                    ctx.strokeStyle = "#111111"
                                    ctx.lineWidth = 1.5
                                    ctx.fillRect(vx - 3.5, vy - 3.5, 7, 7)
                                    ctx.strokeRect(vx - 3.5, vy - 3.5, 7, 7)
                                }
                                return
                            }

                            // 3. Krita Bezier Curve
                            if (view.drawShape === "bezier" && drawOverlay.bezierNodes.length > 0) {
                                var nodes = drawOverlay.bezierNodes
                                var n = nodes.length
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(nodes[0].x), view.docToHostY(nodes[0].y))
                                for (var bi = 1; bi < n; ++bi) {
                                    var a = nodes[bi - 1]
                                    var b = nodes[bi]
                                    ctx.bezierCurveTo(
                                        view.docToHostX(a.outX), view.docToHostY(a.outY),
                                        view.docToHostX(b.inX), view.docToHostY(b.inY),
                                        view.docToHostX(b.x), view.docToHostY(b.y))
                                }
                                var closePreview = (view.drawBezierClosed || drawOverlay.hoveringClose) && n >= 3
                                if (closePreview) {
                                    var lastN = nodes[n - 1]
                                    var firstN = nodes[0]
                                    ctx.bezierCurveTo(
                                        view.docToHostX(lastN.outX), view.docToHostY(lastN.outY),
                                        view.docToHostX(firstN.inX), view.docToHostY(firstN.inY),
                                        view.docToHostX(firstN.x), view.docToHostY(firstN.y))
                                    ctx.closePath()
                                }
                                paintPath(closePreview)

                                // Live rubber-band curve to hover point when not dragging handle
                                if (!drawOverlay.bezierDraggingHandle && drawOverlay.hoverInside && !drawOverlay.hoveringClose) {
                                    var tail = nodes[n - 1]
                                    ctx.save()
                                    ctx.beginPath()
                                    ctx.moveTo(view.docToHostX(tail.x), view.docToHostY(tail.y))
                                    ctx.bezierCurveTo(
                                        view.docToHostX(tail.outX), view.docToHostY(tail.outY),
                                        view.docToHostX(drawOverlay.hoverDocX), view.docToHostY(drawOverlay.hoverDocY),
                                        view.docToHostX(drawOverlay.hoverDocX), view.docToHostY(drawOverlay.hoverDocY))
                                    ctx.strokeStyle = "#4a9eff"
                                    ctx.lineWidth = 1.25
                                    ctx.setLineDash([4, 4])
                                    ctx.stroke()
                                    ctx.restore()
                                }

                                // Draw Bezier tangent handles and anchor squares
                                for (var ni = 0; ni < n; ++ni) {
                                    var nd = nodes[ni]
                                    var ax = view.docToHostX(nd.x)
                                    var ay = view.docToHostY(nd.y)
                                    var inX = view.docToHostX(nd.inX)
                                    var inY = view.docToHostY(nd.inY)
                                    var outX = view.docToHostX(nd.outX)
                                    var outY = view.docToHostY(nd.outY)

                                    ctx.strokeStyle = "#4a9eff"
                                    ctx.lineWidth = 1.2
                                    if (Math.hypot(inX - ax, inY - ay) > 1.5) {
                                        ctx.beginPath()
                                        ctx.moveTo(ax, ay)
                                        ctx.lineTo(inX, inY)
                                        ctx.stroke()
                                        ctx.fillStyle = "#ffffff"
                                        ctx.beginPath()
                                        ctx.arc(inX, inY, 3.2, 0, Math.PI * 2)
                                        ctx.fill()
                                        ctx.stroke()
                                    }
                                    if (Math.hypot(outX - ax, outY - ay) > 1.5) {
                                        ctx.beginPath()
                                        ctx.moveTo(ax, ay)
                                        ctx.lineTo(outX, outY)
                                        ctx.stroke()
                                        ctx.fillStyle = "#ffffff"
                                        ctx.beginPath()
                                        ctx.arc(outX, outY, 3.2, 0, Math.PI * 2)
                                        ctx.fill()
                                        ctx.stroke()
                                    }
                                    ctx.fillStyle = (ni === 0 && drawOverlay.hoveringClose) ? "#4a9eff" : "#ffffff"
                                    ctx.strokeStyle = "#111111"
                                    ctx.lineWidth = 1.5
                                    ctx.fillRect(ax - 3.5, ay - 3.5, 7, 7)
                                    ctx.strokeRect(ax - 3.5, ay - 3.5, 7, 7)
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: drawMouseArea
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        cursorShape: Qt.CrossCursor

                        onExited: {
                            drawOverlay.hoverInside = false
                            drawPreviewCanvas.requestPaint()
                        }

                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            var docX = view.hostToDocX(mouse.x)
                            var docY = view.hostToDocY(mouse.y)
                            drawOverlay.shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
                            drawOverlay.altHeld = (mouse.modifiers & Qt.AltModifier) !== 0

                            if (view.drawShape === "line" || view.drawShape === "rect"
                                    || view.drawShape === "ellipse" || view.drawShape === "star") {
                                drawOverlay.dragging = true
                                drawOverlay.startDocX = docX
                                drawOverlay.startDocY = docY
                                drawOverlay.curDocX = docX
                                drawOverlay.curDocY = docY
                                drawPreviewCanvas.requestPaint()
                                return
                            }

                            if (view.drawShape === "polyline" || view.drawShape === "polygon") {
                                var pts = drawOverlay.pathPoints.slice()
                                if (view.drawShape === "polygon" && pts.length >= 3) {
                                    var fx = view.docToHostX(pts[0][0])
                                    var fy = view.docToHostY(pts[0][1])
                                    if (Math.hypot(mouse.x - fx, mouse.y - fy) <= 10) {
                                        drawOverlay.finishPath(true)
                                        return
                                    }
                                }
                                var pt = [docX, docY]
                                if (drawOverlay.shiftHeld && pts.length > 0) {
                                    var prev = pts[pts.length - 1]
                                    pt = drawOverlay.snapAngle(prev[0], prev[1], docX, docY)
                                }
                                pts.push(pt)
                                drawOverlay.pathPoints = pts
                                drawPreviewCanvas.requestPaint()
                                return
                            }

                            if (view.drawShape === "bezier") {
                                var nodes = drawOverlay.bezierNodes.slice()
                                if (nodes.length >= 3) {
                                    var bfx = view.docToHostX(nodes[0].x)
                                    var bfy = view.docToHostY(nodes[0].y)
                                    if (Math.hypot(mouse.x - bfx, mouse.y - bfy) <= 10) {
                                        drawOverlay.finishPath(true)
                                        return
                                    }
                                }
                                nodes.push({
                                    x: docX, y: docY,
                                    inX: docX, inY: docY,
                                    outX: docX, outY: docY
                                })
                                drawOverlay.bezierNodes = nodes
                                drawOverlay.bezierDraggingHandle = true
                                drawPreviewCanvas.requestPaint()
                            }
                        }

                        onPositionChanged: function(mouse) {
                            var docX = view.hostToDocX(mouse.x)
                            var docY = view.hostToDocY(mouse.y)
                            drawOverlay.hoverInside = true
                            drawOverlay.hoverDocX = docX
                            drawOverlay.hoverDocY = docY
                            drawOverlay.shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
                            drawOverlay.altHeld = (mouse.modifiers & Qt.AltModifier) !== 0

                            if (drawOverlay.dragging) {
                                drawOverlay.curDocX = docX
                                drawOverlay.curDocY = docY
                                drawPreviewCanvas.requestPaint()
                                return
                            }

                            if (view.drawShape === "bezier" && drawOverlay.bezierDraggingHandle
                                    && drawOverlay.bezierNodes.length > 0) {
                                var nodes = drawOverlay.bezierNodes.slice()
                                var last = nodes[nodes.length - 1]
                                var dx = docX - last.x
                                var dy = docY - last.y
                                var updated = {
                                    x: last.x,
                                    y: last.y,
                                    inX: drawOverlay.altHeld ? last.inX : (last.x - dx),
                                    inY: drawOverlay.altHeld ? last.inY : (last.y - dy),
                                    outX: docX,
                                    outY: docY
                                }
                                nodes[nodes.length - 1] = updated
                                drawOverlay.bezierNodes = nodes
                                drawPreviewCanvas.requestPaint()
                                return
                            }

                            if (view.drawShape === "polygon" && drawOverlay.pathPoints.length >= 3) {
                                var p0 = drawOverlay.pathPoints[0]
                                drawOverlay.hoveringClose =
                                    Math.hypot(mouse.x - view.docToHostX(p0[0]), mouse.y - view.docToHostY(p0[1])) <= 10
                                drawPreviewCanvas.requestPaint()
                            } else if (view.drawShape === "polyline" && drawOverlay.pathPoints.length > 0) {
                                drawPreviewCanvas.requestPaint()
                            } else if (view.drawShape === "bezier" && drawOverlay.bezierNodes.length > 0) {
                                if (drawOverlay.bezierNodes.length >= 3) {
                                    var b0 = drawOverlay.bezierNodes[0]
                                    drawOverlay.hoveringClose =
                                        Math.hypot(mouse.x - view.docToHostX(b0.x), mouse.y - view.docToHostY(b0.y)) <= 10
                                } else {
                                    drawOverlay.hoveringClose = false
                                }
                                drawPreviewCanvas.requestPaint()
                            }
                        }

                        onReleased: function(mouse) {
                            drawOverlay.shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
                            drawOverlay.altHeld = (mouse.modifiers & Qt.AltModifier) !== 0
                            if (drawOverlay.dragging) {
                                drawOverlay.dragging = false
                                var endX = view.hostToDocX(mouse.x)
                                var endY = view.hostToDocY(mouse.y)
                                drawPreviewCanvas.requestPaint()
                                if (Math.hypot(endX - drawOverlay.startDocX, endY - drawOverlay.startDocY) < 0.5) {
                                    return
                                }
                                if (view.drawShape === "line") {
                                    var endPt = drawOverlay.shiftHeld
                                                ? drawOverlay.snapAngle(drawOverlay.startDocX, drawOverlay.startDocY, endX, endY)
                                                : [endX, endY]
                                    drawOverlay.commitShape("line", [[drawOverlay.startDocX, drawOverlay.startDocY], endPt], false)
                                } else if (view.drawShape === "rect" || view.drawShape === "ellipse") {
                                    var box = drawOverlay.computeBoxEndpoints(
                                        drawOverlay.startDocX, drawOverlay.startDocY,
                                        endX, endY, drawOverlay.shiftHeld, drawOverlay.altHeld)
                                    drawOverlay.commitShape(view.drawShape, box, true)
                                } else if (view.drawShape === "star") {
                                    var starPts = drawOverlay.computeStarPolygonPoints(
                                        drawOverlay.startDocX, drawOverlay.startDocY,
                                        endX, endY, drawOverlay.shiftHeld)
                                    if (starPts.length >= 3) {
                                        drawOverlay.commitShape("polygon", starPts, true)
                                    }
                                }
                                return
                            }
                            if (view.drawShape === "bezier" && drawOverlay.bezierDraggingHandle) {
                                drawOverlay.bezierDraggingHandle = false
                                drawPreviewCanvas.requestPaint()
                            }
                        }

                        onDoubleClicked: function(mouse) {
                            if (view.drawShape === "polyline" || view.drawShape === "polygon") {
                                // Double-click fired a duplicate point on the 2nd press: drop it before committing.
                                if (drawOverlay.pathPoints.length > 2) {
                                    drawOverlay.pathPoints = drawOverlay.pathPoints.slice(0, drawOverlay.pathPoints.length - 1)
                                }
                                drawOverlay.finishPath(false)
                            } else if (view.drawShape === "bezier") {
                                if (drawOverlay.bezierNodes.length > 2) {
                                    drawOverlay.bezierNodes = drawOverlay.bezierNodes.slice(0, drawOverlay.bezierNodes.length - 1)
                                }
                                drawOverlay.finishPath(false)
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

                    // Visible intersection of the document frame with the viewport.
                    // Sizing the preview canvas & mask FBOs to this intersection keeps
                    // GPU textures <= viewport size even at 3200% zoom while strictly
                    // clipping live strokes to the exact image boundaries.
                    readonly property real imgLeft: view.docToHostX(0)
                    readonly property real imgTop: view.docToHostY(0)
                    readonly property real imgRight: view.docToHostX(view.displayedWidth)
                    readonly property real imgBottom: view.docToHostY(view.displayedHeight)
                    readonly property real clipX: Math.max(0, Math.floor(imgLeft))
                    readonly property real clipY: Math.max(0, Math.floor(imgTop))
                    readonly property real clipRight: Math.min(width, Math.ceil(imgRight))
                    readonly property real clipBottom: Math.min(height, Math.ceil(imgBottom))
                    readonly property bool imgVisible: clipRight > clipX && clipBottom > clipY
                    readonly property real clipW: Math.max(1, clipRight - clipX)
                    readonly property real clipH: Math.max(1, clipBottom - clipY)

                    Item {
                        id: strokeClipBox
                        objectName: "strokeClipBox"
                        visible: paintOverlay.imgVisible && !view._livePaintActive
                        x: paintOverlay.clipX
                        y: paintOverlay.clipY
                        width: paintOverlay.clipW
                        height: paintOverlay.clipH
                        clip: true

                        // Selection alpha mask aligned 1:1 with strokeClipBox.
                        // Keeping sourceItem visible while hideSource: true on
                        // ShaderEffectSource is the official Qt 6 pattern so the
                        // mask texture is always rendered for MultiEffect.
                        Item {
                            id: paintMaskContainer
                            anchors.fill: parent
                            clip: true
                            visible: view.hasSelection

                            Image {
                                id: paintMaskImage
                                x: paintOverlay.imgLeft - paintOverlay.clipX
                                y: paintOverlay.imgTop - paintOverlay.clipY
                                width: Math.max(1, view.displayedWidth * view.zoom)
                                height: Math.max(1, view.displayedHeight * view.zoom)
                                fillMode: Image.Stretch
                                asynchronous: false
                                cache: false
                                source: (view.hasSelection && view.editor && (view.editor.ramSelectionRevision || 0) > 0)
                                        ? ("image://editor/sel_mask?rev=" + view.editor.ramSelectionRevision)
                                        : ""
                            }
                        }

                        ShaderEffectSource {
                            id: paintMaskSource
                            anchors.fill: parent
                            sourceItem: paintMaskContainer
                            hideSource: true
                            live: true
                            visible: false
                        }

                        Canvas {
                            id: strokePreview
                            objectName: "strokePreview"
                            anchors.fill: parent
                            onWidthChanged: if (view.paintStroking) requestPaint()
                            onHeightChanged: if (view.paintStroking) requestPaint()

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                var points = view.paintStroke
                                if (!points || points.length === 0) return
                                var ox = paintOverlay.clipX
                                var oy = paintOverlay.clipY
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
                                    ctx.arc(view.docToHostX(points[0][0]) - ox,
                                            view.docToHostY(points[0][1]) - oy, radius, 0, 2 * Math.PI)
                                    ctx.fill()
                                    return
                                }
                                ctx.beginPath()
                                ctx.moveTo(view.docToHostX(points[0][0]) - ox,
                                           view.docToHostY(points[0][1]) - oy)
                                for (var index = 1; index < points.length; ++index) {
                                    ctx.lineTo(view.docToHostX(points[index][0]) - ox,
                                               view.docToHostY(points[index][1]) - oy)
                                }
                                ctx.stroke()
                            }
                        }

                        ShaderEffectSource {
                            id: strokePreviewSource
                            anchors.fill: parent
                            sourceItem: strokePreview
                            hideSource: view.hasSelection
                            live: true
                            visible: false
                        }

                        MultiEffect {
                            id: strokeMaskedOutput
                            anchors.fill: parent
                            visible: view.hasSelection
                            source: strokePreviewSource
                            maskEnabled: true
                            maskSource: paintMaskSource
                            maskThresholdMin: 0.004
                            maskSpreadAtMin: 0.996
                        }
                    }

                    MouseArea {
                        id: paintArea
                        objectName: "paintArea"
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        property bool hoverInside: false
                        property real hoverX: 0
                        property real hoverY: 0
                        property bool shiftResizing: false
                        property real resizeStartX: 0
                        property real resizeStartSize: 24
                        property real resizeAnchorX: 0
                        property real resizeAnchorY: 0
                        property bool altPicking: false
                        property string pickedHex: ""
                        property string prevFgHex: "#000000"

                        readonly property real cursorDiameter: Math.max(4, view.paintSize * view.zoom)
                        cursorShape: altPicking ? Qt.CrossCursor
                                   : (cursorDiameter >= 12 ? Qt.BlankCursor : Qt.CrossCursor)

                        onEntered: hoverInside = true
                        onExited: {
                            hoverInside = false
                            altPicking = false
                        }
                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            hoverInside = true
                            hoverX = mouse.x
                            hoverY = mouse.y
                            // Krita Paint: Ctrl+Click (and Alt+Click) samples color directly from canvas!
                            if ((mouse.modifiers & (Qt.ControlModifier | Qt.AltModifier)) !== 0) {
                                altPicking = true
                                prevFgHex = view.foregroundColor
                                pickedHex = view.pickCanvasColor(mouse.x, mouse.y)
                                return
                            }
                            if ((mouse.modifiers & Qt.ShiftModifier) !== 0) {
                                shiftResizing = true
                                resizeStartX = mouse.x
                                resizeStartSize = view.paintSize
                                resizeAnchorX = mouse.x
                                resizeAnchorY = mouse.y
                                return
                            }
                            view.beginPaintStroke(mouse.x, mouse.y)
                        }
                        onPositionChanged: function(mouse) {
                            hoverInside = true
                            hoverX = mouse.x
                            hoverY = mouse.y
                            if (!pressed) return
                            if (altPicking) {
                                pickedHex = view.pickCanvasColor(mouse.x, mouse.y)
                                return
                            }
                            if (shiftResizing) {
                                var delta = (mouse.x - resizeStartX) / Math.max(0.25, view.zoom)
                                view.paintSize = Math.max(view.minimumPaintSize,
                                                          Math.min(view.maximumPaintSize,
                                                                   Math.round(resizeStartSize + delta)))
                                return
                            }
                            view.extendPaintStroke(mouse.x, mouse.y)
                        }
                        onReleased: {
                            if (altPicking) {
                                altPicking = false
                                pickedHex = ""
                                return
                            }
                            if (shiftResizing) {
                                shiftResizing = false
                                return
                            }
                            view.finishPaintStroke()
                        }
                        onCanceled: {
                            altPicking = false
                            shiftResizing = false
                            pickedHex = ""
                            view.cancelPaintStroke()
                        }
                    }

                    // Dual-ring brush/eraser outline showing exact scaled size & shape.
                    Item {
                        id: brushCursor
                        objectName: "brushCursor"
                        visible: (paintArea.hoverInside || paintArea.shiftResizing) && !paintArea.altPicking
                        readonly property real cx: paintArea.shiftResizing ? paintArea.resizeAnchorX : paintArea.hoverX
                        readonly property real cy: paintArea.shiftResizing ? paintArea.resizeAnchorY : paintArea.hoverY
                        readonly property real diameter: Math.max(4, view.paintSize * view.zoom)
                        x: Math.round(cx - diameter / 2)
                        y: Math.round(cy - diameter / 2)
                        width: Math.round(diameter)
                        height: Math.round(diameter)

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: "transparent"
                            border.width: 1
                            border.color: "#d0000000"
                        }
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: width / 2
                            color: "transparent"
                            border.width: 1
                            border.color: view.paintMode === "eraser" ? "#f0ff9f9f" : "#f0ffffff"
                        }
                        // Center pixel crosshair dot when the ring is wide enough.
                        Rectangle {
                            visible: brushCursor.diameter >= 12
                            anchors.centerIn: parent
                            width: 3
                            height: 3
                            radius: 1.5
                            color: "#f0ffffff"
                            border.width: 0.75
                            border.color: "#d0000000"
                        }
                    }

                    // Live size badge while Shift+Dragging to resize brush.
                    Rectangle {
                        visible: paintArea.shiftResizing
                        x: Math.min(parent.width - width - 8, paintArea.resizeAnchorX + brushCursor.diameter / 2 + 10)
                        y: Math.max(8, paintArea.resizeAnchorY - height / 2)
                        width: shiftSizeLabel.implicitWidth + 14
                        height: shiftSizeLabel.implicitHeight + 8
                        radius: 4
                        color: view.theme.surfaceAlt
                        border.width: 1
                        border.color: view.theme.border
                        Label {
                            id: shiftSizeLabel
                            anchors.centerIn: parent
                            text: Math.round(view.paintSize) + " px"
                            color: view.theme.text
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }

                    // Krita-style dual-half color comparison ring while Ctrl/Alt-sampling color.
                    Item {
                        visible: paintArea.altPicking && paintArea.pickedHex !== ""
                        x: Math.round(paintArea.hoverX - 22)
                        y: Math.round(paintArea.hoverY - 22)
                        width: 44
                        height: 44

                        Canvas {
                            anchors.fill: parent
                            property string newCol: paintArea.pickedHex
                            property string oldCol: paintArea.prevFgHex
                            onNewColChanged: requestPaint()
                            onOldColChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                // Top half = newly sampled color; bottom half = previous foreground color
                                ctx.lineWidth = 6
                                ctx.beginPath()
                                ctx.arc(22, 22, 18, Math.PI, 0, false)
                                ctx.strokeStyle = newCol || "#000000"
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(22, 22, 18, 0, Math.PI, false)
                                ctx.strokeStyle = oldCol || "#000000"
                                ctx.stroke()
                                ctx.lineWidth = 1
                                ctx.beginPath()
                                ctx.arc(22, 22, 21, 0, Math.PI * 2)
                                ctx.strokeStyle = "rgba(0,0,0,0.75)"
                                ctx.stroke()
                            }
                        }
                    }

                    // Live color swatch badge while Ctrl/Alt+Click/Dragging to pick color.
                    Rectangle {
                        visible: paintArea.altPicking && paintArea.pickedHex !== ""
                        x: Math.min(parent.width - width - 8, paintArea.hoverX + 16)
                        y: Math.max(8, paintArea.hoverY - height - 10)
                        width: altPickRow.implicitWidth + 14
                        height: altPickRow.implicitHeight + 8
                        radius: 4
                        color: view.theme.surfaceAlt
                        border.width: 1
                        border.color: view.theme.border
                        RowLayout {
                            id: altPickRow
                            anchors.centerIn: parent
                            spacing: 6
                            Rectangle {
                                width: 14
                                height: 14
                                radius: 3
                                color: paintArea.pickedHex || "#000000"
                                border.width: 1
                                border.color: view.theme.border
                            }
                            Label {
                                text: (paintArea.pickedHex || "").toUpperCase()
                                color: view.theme.text
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }
                    }
                }

                // ------------------------------------------------ eyedropper tool
                Item {
                    id: eyedropperOverlay
                    objectName: "eyedropperOverlay"
                    anchors.fill: parent
                    visible: view.tool === "eyedropper" && view.documentReady
                    enabled: visible && !view.spacePanning

                    MouseArea {
                        id: eyedropperArea
                        objectName: "eyedropperArea"
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        cursorShape: Qt.CrossCursor
                        property real hoverX: 0
                        property real hoverY: 0
                        property string sampledHex: ""

                        onPressed: function(mouse) {
                            view.forceActiveFocus()
                            hoverX = mouse.x
                            hoverY = mouse.y
                            sampledHex = view.pickCanvasColor(mouse.x, mouse.y)
                        }
                        onPositionChanged: function(mouse) {
                            hoverX = mouse.x
                            hoverY = mouse.y
                            if (pressed) {
                                sampledHex = view.pickCanvasColor(mouse.x, mouse.y)
                            }
                        }
                        onReleased: sampledHex = ""
                        onCanceled: sampledHex = ""
                    }

                    Rectangle {
                        visible: eyedropperArea.pressed && eyedropperArea.sampledHex !== ""
                        x: Math.min(parent.width - width - 8, eyedropperArea.hoverX + 16)
                        y: Math.max(8, eyedropperArea.hoverY - height - 10)
                        width: eyedropperPill.implicitWidth + 14
                        height: eyedropperPill.implicitHeight + 8
                        radius: 4
                        color: view.theme.surfaceAlt
                        border.width: 1
                        border.color: view.theme.border
                        RowLayout {
                            id: eyedropperPill
                            anchors.centerIn: parent
                            spacing: 6
                            Rectangle {
                                width: 14
                                height: 14
                                radius: 3
                                color: eyedropperArea.sampledHex || "#000000"
                                border.width: 1
                                border.color: view.theme.border
                            }
                            Label {
                                text: (eyedropperArea.sampledHex || "").toUpperCase()
                                color: view.theme.text
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }
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

            // Floating compact selection pill at top-center of canvas so the user
            // can switch Krita Ants / Red Mask mode and Deselect (Ctrl+D) from any tool.
            Rectangle {
                id: selectionFloatingBar
                objectName: "selectionFloatingBar"
                visible: view.documentReady && view.hasSelection && !view.filterDialogOpen
                z: 4
                anchors.top: parent.top
                anchors.topMargin: 10
                anchors.horizontalCenter: parent.horizontalCenter
                width: selBarRow.implicitWidth + 16
                height: 28
                radius: 14
                color: view.theme.surfaceAlt
                border.width: 1
                border.color: view.theme.border
                opacity: 0.94

                RowLayout {
                    id: selBarRow
                    anchors.centerIn: parent
                    spacing: 6

                    Label {
                        text: {
                            var sb = view.editor ? view.editor.selectionBounds : null
                            return (sb && sb.length === 4)
                                   ? (sb[2] + " × " + sb[3] + " px")
                                   : qsTr("Selection")
                        }
                        color: view.theme.textMuted
                        font.pixelSize: 11
                    }

                    ToolButton {
                        objectName: "selectionDisplayModeBtn"
                        implicitHeight: 22
                        leftPadding: 7
                        rightPadding: 7
                        topPadding: 0
                        bottomPadding: 0
                        focusPolicy: Qt.NoFocus
                        text: view.selectionDisplayMode === "mask" ? qsTr("Mask") : qsTr("Ants")
                        font.pixelSize: 11
                        onClicked: view.selectionDisplayMode = view.selectionDisplayMode === "mask" ? "ants" : "mask"
                    }

                    ToolButton {
                        objectName: "selectionQuickDeselectBtn"
                        implicitHeight: 22
                        leftPadding: 8
                        rightPadding: 8
                        topPadding: 0
                        bottomPadding: 0
                        focusPolicy: Qt.NoFocus
                        text: qsTr("Deselect") + " (Ctrl+D)"
                        font.pixelSize: 11
                        onClicked: view.command({ type: "editor_select_clear" })
                    }
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
            visible: view.sidebarShown && !(inspector.topDetached && inspector.bottomDetached)
            enabled: !view.filterDialogOpen
            opacity: view.filterDialogOpen ? 0.55 : 1.0

            /// The heading row is the tool zone's minimum.
            readonly property int headerHeight: 34
            readonly property int collapsedRowHeight: 38
            readonly property int rowGap: 10
            readonly property int minExpandedTop: 96
            readonly property int minExpandedBottom: 110
            property bool topCollapsed: false
            property bool bottomCollapsed: false
            property bool topDetached: false
            property bool bottomDetached: false

            function setTopDetached(detached) {
                if (topDetached === detached) return
                topDetached = detached
                if (detached) {
                    topCollapsed = false
                    floatingToolDialog.open()
                } else if (floatingToolDialog.opened) {
                    floatingToolDialog.close()
                }
            }

            function setBottomDetached(detached) {
                if (bottomDetached === detached) return
                bottomDetached = detached
                if (detached) {
                    bottomCollapsed = false
                    floatingLayersDialog.open()
                } else if (floatingLayersDialog.opened) {
                    floatingLayersDialog.close()
                }
            }
            /// Whether each docked zone is currently occupying space in the sidebar.
            readonly property bool topZoneActive: view.toolOptionsVisible && !inspector.topDetached
            readonly property bool bottomZoneActive: view.shownReferenceCount > 0 && !inspector.bottomDetached
            /// Action buttons (Apply / Reset / Clear) now live inside the
            /// options ScrollView right below each tool's fields, so no extra
            /// pinned footer height needs to be subtracted from `optionsCap`.
            readonly property int actionRowHeight: 0
            /// Maximum height Row 2 may grow to while Row 1 keeps its scrollable floor.
            readonly property real referenceCap:
                Math.max(minExpandedBottom, height - minExpandedTop - rowGap - 8)
            /// Effective height of Row 2 (Layers or Reference):
            /// - Collapsed -> title bar only (`collapsedRowHeight`), Row 1 expands to max.
            /// - Row 1 hidden, detached, or collapsed -> Row 2 expands to fill the sidebar.
            /// - Both expanded -> user-dragged height (or 42% default), clamped so neither covers the other.
            readonly property real referenceShownHeight: {
                if (view.shownReferenceCount <= 0) return 0
                if (inspector.bottomCollapsed) return inspector.collapsedRowHeight
                if (!inspector.topZoneActive) {
                    return Math.max(inspector.minExpandedBottom, inspector.height)
                }
                if (inspector.topCollapsed) {
                    return Math.max(inspector.minExpandedBottom,
                                    inspector.height - inspector.collapsedRowHeight - inspector.rowGap - 8)
                }
                var wanted = view.referenceHeight > 0
                             ? view.referenceHeight
                             : Math.max(220, Math.round(inspector.height * 0.42))
                return Math.max(inspector.minExpandedBottom, Math.min(wanted, referenceCap))
            }
            /// Remaining scrollable height inside Row 1 above the divider.
            readonly property real optionsCap: Math.max(
                40,
                Math.max(0, height - referenceShownHeight - headerHeight - 40
                            - actionRowHeight - rowGap - 8))
            readonly property bool toolOptionsShown:
                view.tool !== "pointer" && view.tool !== "hand" && view.tool !== "eyedropper" && view.toolOptionsVisible
            /// Top row active tab: `"options"` (Tool options) or `"history"` (Interactive History).
            property string topTab: "options"
            /// Bottom row active panel: `"layers"` (default dedicated Layers panel) or `"reference"` (Info / Original).
            property string bottomPanel: "layers"
            /// The tool's name for the heading. The sentence is "… options", so
            /// the heading says whose column this is whether or not a tool is
            /// armed.
            readonly property string toolName:
                view.tool === "pointer"
                ? qsTr("Pointer")
                : (view.tool === "hand"
                   ? qsTr("Hand")
                   : (view.tool === "zoom"
                      ? qsTr("Zoom")
                      : (view.tool === "crop"
                      ? qsTr("Crop")
                      : (view.tool === "transform"
                         ? qsTr("Transform")
                         : (view.tool === "rotate"
                            ? qsTr("Rotate")
                            : (view.tool === "paint"
                               ? (view.paintMode === "eraser" ? qsTr("Eraser") : qsTr("Brush"))
                               : (view.tool === "draw"
                                  ? qsTr("Shapes & Curves")
                                  : (view.tool === "fill"
                                     ? qsTr("Fill")
                                     : (view.tool === "gradient"
                                        ? qsTr("Gradient")
                                        : (view.tool === "liquify"
                                           ? qsTr("Liquify")
                                           : (view.tool === "canvasSize"
                                     ? qsTr("Canvas size")
                                     : (view.tool === "adjust"
                                        ? qsTr("Brightness / Contrast")
                                        : (view.tool === "hsv"
                                           ? qsTr("HSV Adjustment")
                                           : (view.tool === "curves"
                                              ? qsTr("Curves")
                                              : (view.tool === "colorBalance"
                                                 ? qsTr("Color balance")
                                                 : (view.tool === "removeBg"
                                                    ? qsTr("Remove background")
                                                    : (view.tool === "watermark"
                                                       ? qsTr("Remove watermark")
                                                       : (view.tool === "caption"
                                                          ? qsTr("Caption & tags")
                                                          : (view.tool === "select"
                                                             ? qsTr("Selection")
                                                             : qsTr("Image size"))))))))))))))))))))
            /// Under this width the tab labels no longer fit in two languages;
            /// the icons and their tooltips carry the tab instead.
            readonly property bool tabsCompact: width < 240

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // ------------------------------------------ tool zone (top)
                // Dock slot in the Right Sidebar; when `inspector.topDetached`
                // is true, `toolZone` reparents seamlessly into `floatingToolDialog`
                // (a resizable `DialogFrame`).
                Item {
                    id: topDockSlot
                    Layout.fillWidth: true
                    visible: view.toolOptionsVisible && !inspector.topDetached
                    clip: true
                    Layout.fillHeight: !inspector.topCollapsed
                    Layout.preferredHeight: inspector.topCollapsed ? inspector.collapsedRowHeight : -1
                    Layout.minimumHeight: inspector.topCollapsed ? inspector.collapsedRowHeight : inspector.minExpandedTop
                    Layout.maximumHeight: inspector.topCollapsed ? inspector.collapsedRowHeight : 100000

                ColumnLayout {
                    id: toolZone
                    objectName: "editorToolZone"
                    parent: inspector.topDetached ? floatingToolHost : topDockSlot
                    anchors.fill: parent
                    visible: view.toolOptionsVisible
                    clip: true
                    spacing: 0

                    // Row 1 header: [Tool options | History] tabs + popout + collapse
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 8
                        Layout.rightMargin: 6
                        Layout.topMargin: 6
                        Layout.bottomMargin: 2
                        spacing: 4

                        PanelTabs {
                            id: topZoneTabs
                            objectName: "editorTopTabs"
                            Layout.fillWidth: true
                            theme: view.theme
                            compact: inspector.tabsCompact
                            keyPrefix: "editorTopTab"
                            currentKey: inspector.topTab
                            tabs: [
                                { key: "options", label: qsTr("Tool options"), icon: "icons/preferences.svg", shown: true },
                                { key: "history", label: qsTr("History"), icon: "icons/history.svg", shown: true }
                            ]
                            onActivated: function(key) {
                                inspector.topTab = key
                                if (inspector.topCollapsed) inspector.topCollapsed = false
                            }
                        }

                        ToolButton {
                            objectName: "topRowPopoutBtn"
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            padding: 0
                            focusPolicy: Qt.NoFocus
                            text: inspector.topDetached ? "↙" : "↗"
                            ToolTip.visible: hovered
                            ToolTip.text: inspector.topDetached ? qsTr("Dock panel") : qsTr("Pop out panel")
                            onClicked: inspector.setTopDetached(!inspector.topDetached)
                        }

                        ToolButton {
                            objectName: "topRowCollapseBtn"
                            visible: !inspector.topDetached
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            padding: 0
                            focusPolicy: Qt.NoFocus
                            text: inspector.topCollapsed ? "▸" : "▾"
                            onClicked: inspector.topCollapsed = !inspector.topCollapsed
                        }
                    }

                    RowLayout {
                        visible: !inspector.topCollapsed && inspector.topTab === "options"
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

                    // Interactive History directly in Row 1 (click any step to Undo/Redo jump)
                    HistoryPanel {
                        id: topHistoryPanel
                        objectName: "editorTopHistoryPanel"
                        visible: !inspector.topCollapsed && inspector.topTab === "history"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.margins: 10
                        theme: view.theme
                        history: view.history
                        redoHistory: view.editor ? (view.editor.redoHistory || []) : []
                        hasDocument: view.hasDocument
                        historyTrimmed: !!(view.editor && view.editor.historyTrimmed)
                        language: view.state.language || ""
                        listObjectName: "topHistoryList"
                        onJumpRequested: function(targetIndex) {
                            view.command({ type: "editor_history_jump", target_index: targetIndex })
                        }
                        onResetRequested: view.command({ type: "editor_reset" })
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
                        visible: !inspector.topCollapsed && inspector.topTab === "options" && (view.tool === "pointer" || view.tool === "hand")
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
                        visible: !inspector.topCollapsed && inspector.topTab === "options" && inspector.toolOptionsShown
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        clip: true

                        ScrollView {
                            id: toolOptionsScroll
                            objectName: "toolOptionsScroll"
                            anchors.fill: parent
                            clip: true
                            contentWidth: availableWidth
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ScrollBar.vertical.policy: ScrollBar.AsNeeded

                            ColumnLayout {
                                id: toolOptionsColumn
                                width: toolOptionsScroll.availableWidth
                                spacing: 10

                            // ------------------------------- liquify options
                            ColumnLayout {
                                objectName: "liquifyOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "liquify"
                                spacing: 6

                                Label { text: qsTr("Warp mode"); color: view.theme.textMuted; font.pixelSize: 11 }
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    columnSpacing: 4
                                    rowSpacing: 4
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Push");      primary: view.liquifyMode === "push";      onClicked: view.liquifyMode = "push" }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Bloat");     primary: view.liquifyMode === "bloat";     onClicked: view.liquifyMode = "bloat" }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Pucker");    primary: view.liquifyMode === "pucker";    onClicked: view.liquifyMode = "pucker" }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Twirl CW");  primary: view.liquifyMode === "twirl_cw";  onClicked: view.liquifyMode = "twirl_cw" }
                                    PanelAction { Layout.fillWidth: true; Layout.columnSpan: 2; theme: view.theme; text: qsTr("Twirl CCW"); primary: view.liquifyMode === "twirl_ccw"; onClicked: view.liquifyMode = "twirl_ccw" }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Radius"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                    Slider {
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        from: 10; to: 300; stepSize: 1
                                        value: view.liquifyRadius
                                        onMoved: view.liquifyRadius = Math.round(value)
                                    }
                                    Label { text: view.liquifyRadius + " px"; color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Strength"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                    Slider {
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        from: 5; to: 100; stepSize: 1
                                        value: view.liquifyStrength
                                        onMoved: view.liquifyStrength = Math.round(value)
                                    }
                                    Label { text: view.liquifyStrength + "%"; color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: view.theme.textMuted
                                    font.pixelSize: 10
                                    text: qsTr("Drag to warp pixels · [ ] adjust radius · Respects active selection")
                                }
                            }

                            // ------------------------------- zoom tool options
                            ColumnLayout {
                                objectName: "zoomOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "zoom"
                                spacing: 8

                                Label { text: qsTr("Click mode"); color: view.theme.textMuted; font.pixelSize: 12 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true; theme: view.theme
                                        text: qsTr("Zoom In (+)")
                                        primary: view.zoomToolMode === "in"
                                        onClicked: view.zoomToolMode = "in"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true; theme: view.theme
                                        text: qsTr("Zoom Out (−)")
                                        primary: view.zoomToolMode === "out"
                                        onClicked: view.zoomToolMode = "out"
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("Zoom"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: view.zoomPercent + "%"; color: view.theme.text; font.pixelSize: 12; font.bold: true }
                                }
                                Slider {
                                    Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                    from: 10; to: 800; stepSize: 5
                                    value: Math.max(10, Math.min(800, view.zoomPercent))
                                    onMoved: view.setZoom(Math.round(value) / 100.0)
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2; columnSpacing: 4; rowSpacing: 4
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Zoom In");  onClicked: view.zoomIn() }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Zoom Out"); onClicked: view.zoomOut() }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Fit (F)");  onClicked: view.fit() }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("100% (1)"); onClicked: view.actualSize() }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: "50%";  onClicked: view.setZoom(0.5) }
                                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: "200%"; onClicked: view.setZoom(2.0) }
                                }

                                Label {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    color: view.theme.textMuted; font.pixelSize: 11
                                    text: qsTr("Click to zoom at cursor · Alt+click or right-click reverses · Drag left/right for scrubby zoom")
                                }
                            }

                            // ------------------------------- fill (paint bucket) options
                            ColumnLayout {
                                objectName: "fillOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "fill"
                                spacing: 8

                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: view.editingActiveLayerMask
                                    implicitHeight: fillMaskHint.implicitHeight + 10
                                    radius: view.theme.radius
                                    color: view.theme.surfaceAlt
                                    border.width: 1
                                    border.color: view.theme.accent
                                    Label {
                                        id: fillMaskHint
                                        anchors.fill: parent
                                        anchors.margins: 5
                                        text: qsTr("Filling Layer Mask · White reveals, Black hides")
                                        color: view.theme.accent
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                Label { text: qsTr("Fill color"); color: view.theme.textMuted; font.pixelSize: 12 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true; theme: view.theme
                                        text: qsTr("Foreground")
                                        primary: view.fillSource === "foreground"
                                        onClicked: view.fillSource = "foreground"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true; theme: view.theme
                                        text: qsTr("Background")
                                        primary: view.fillSource === "background"
                                        onClicked: view.fillSource = "background"
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("Tolerance"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: String(view.fillTolerance); color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                    from: 0; to: 255; stepSize: 1
                                    value: view.fillTolerance
                                    onMoved: view.fillTolerance = Math.round(value)
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("Grow fill"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: view.fillGrow + " px"; color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                    from: 0; to: 8; stepSize: 1
                                    value: view.fillGrow
                                    onMoved: view.fillGrow = Math.round(value)
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("Opacity"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: view.fillOpacity + "%"; color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                    from: 1; to: 100; stepSize: 1
                                    value: view.fillOpacity
                                    onMoved: view.fillOpacity = Math.round(value)
                                }

                                CheckBox {
                                    text: qsTr("Contiguous")
                                    focusPolicy: Qt.NoFocus
                                    checked: view.fillContiguous
                                    onToggled: view.fillContiguous = checked
                                }
                                CheckBox {
                                    text: qsTr("Sample all layers")
                                    focusPolicy: Qt.NoFocus
                                    checked: view.fillSampleAllLayers
                                    onToggled: view.fillSampleAllLayers = checked
                                }
                            }

                            // ------------------------------- gradient options
                            ColumnLayout {
                                objectName: "gradientOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "gradient"
                                spacing: 6

                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: view.editingActiveLayerMask
                                    implicitHeight: gradMaskHint.implicitHeight + 8
                                    radius: view.theme.radius
                                    color: view.theme.surfaceAlt
                                    border.width: 1
                                    border.color: view.theme.accent
                                    Label {
                                        id: gradMaskHint
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        text: qsTr("Gradient on Layer Mask · Smooth fade")
                                        color: view.theme.accent
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                // Preset selector + Reverse toggle on one compact row
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    ComboBox {
                                        id: gradPresetCombo
                                        objectName: "gradientPresetCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        model: view.gradientPresets.map(function(p) { return p.label })
                                        currentIndex: {
                                            for (var i = 0; i < view.gradientPresets.length; ++i) {
                                                if (view.gradientPresets[i].id === view.gradientPresetId) return i
                                            }
                                            return 0
                                        }
                                        onActivated: function(idx) {
                                            if (idx >= 0 && idx < view.gradientPresets.length) {
                                                view.applyGradientPreset(view.gradientPresets[idx])
                                            }
                                        }
                                    }
                                    PanelAction {
                                        Layout.preferredWidth: 32
                                        theme: view.theme
                                        text: "⇄"
                                        primary: view.gradientReverse
                                        ToolTip.visible: hovered
                                        ToolTip.text: qsTr("Reverse gradient")
                                        onClicked: view.gradientReverse = !view.gradientReverse
                                    }
                                }

                                // Live interactive multi-stop gradient bar (click to add stop)
                                Item {
                                    id: gradBarHost
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 34

                                    Rectangle {
                                        id: gradBarRect
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        height: 20
                                        radius: 4
                                        border.width: 1
                                        border.color: view.theme.border
                                        clip: true

                                        Checkerboard { anchors.fill: parent; square: 5 }

                                        Canvas {
                                            id: gradBarCanvas
                                            anchors.fill: parent
                                            Connections {
                                                target: view
                                                function onGradientStopsChanged() { gradBarCanvas.requestPaint() }
                                                function onGradientColorModeChanged() { gradBarCanvas.requestPaint() }
                                                function onGradientReverseChanged() { gradBarCanvas.requestPaint() }
                                                function onForegroundColorChanged() { gradBarCanvas.requestPaint() }
                                                function onBackgroundColorChanged() { gradBarCanvas.requestPaint() }
                                            }
                                            onWidthChanged: requestPaint()
                                            onPaint: {
                                                var ctx = getContext("2d")
                                                ctx.clearRect(0, 0, width, height)
                                                var stops = view.resolvedGradientStops()
                                                if (stops.length < 2) return
                                                var g = ctx.createLinearGradient(0, 0, width, 0)
                                                for (var i = 0; i < stops.length; ++i) {
                                                    var s = stops[i]
                                                    var p = view.gradientReverse ? (1.0 - s.pos) : s.pos
                                                    var b = view.colorBytes(s.hex)
                                                    g.addColorStop(Math.max(0, Math.min(1, p)),
                                                                   "rgba(" + b[0] + "," + b[1] + "," + b[2] + "," + s.alpha.toFixed(3) + ")")
                                                }
                                                ctx.fillStyle = g
                                                ctx.fillRect(0, 0, width, height)
                                            }
                                        }

                                        MouseArea {
                                            id: gradBarMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            ToolTip.visible: containsMouse
                                            ToolTip.text: qsTr("Click to add stop · Drag markers below to move")
                                            onClicked: function(mouse) {
                                                if (width > 1) view.addGradientStopAt(mouse.x / width)
                                            }
                                        }
                                    }

                                    // Draggable stop markers below the bar.
                                    // Uses integer count as `model` so updating a stop's `pos`
                                    // never destroys and recreates the active MouseArea mid-drag.
                                    Repeater {
                                        model: view.rawGradientStops().length
                                        Rectangle {
                                            required property int index
                                            readonly property var stopData: {
                                                var arr = view.rawGradientStops()
                                                return (index >= 0 && index < arr.length) ? arr[index] : null
                                            }
                                            readonly property bool selected: view.gradientSelectedStop === index
                                            width: 12; height: 12; radius: 6
                                            x: stopData ? Math.max(0, Math.min(gradBarHost.width - width, stopData.pos * (gradBarHost.width - width))) : 0
                                            y: 22
                                            z: selected ? 2 : 1
                                            color: stopData ? stopData.hex : "#ffffff"
                                            border.width: selected ? 2 : 1
                                            border.color: selected ? view.theme.accent : view.theme.border

                                            MouseArea {
                                                anchors.fill: parent
                                                anchors.margins: -3
                                                cursorShape: Qt.SizeHorCursor
                                                preventStealing: true
                                                onPressed: {
                                                    view.ensureCustomGradientStops()
                                                    view.gradientSelectedStop = index
                                                }
                                                onDoubleClicked: {
                                                    view.ensureCustomGradientStops()
                                                    view.gradientSelectedStop = index
                                                    var arr = view.rawGradientStops()
                                                    var cur = (index >= 0 && index < arr.length) ? arr[index] : null
                                                    gradientStopColorDialog.selectedColor = cur ? cur.hex : view.foregroundColor
                                                    gradientStopColorDialog.open()
                                                }
                                                onPositionChanged: function(mouse) {
                                                    if (!pressed) return
                                                    var pt = mapToItem(gradBarHost, mouse.x, 0)
                                                    var pos = Math.max(0, Math.min(1, pt.x / Math.max(1, gradBarHost.width)))
                                                    view.updateGradientStop(index, { pos: pos })
                                                }
                                            }
                                        }
                                    }
                                }

                                // Selected stop color picker & quick controls (always accessible)
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    // Clickable stop color swatch -> opens ColorPickerDialog
                                    Rectangle {
                                        id: gradStopColorBtn
                                        objectName: "gradientStopColorBtn"
                                        Layout.preferredWidth: 34
                                        Layout.preferredHeight: 26
                                        radius: view.theme.radius
                                        border.width: 1
                                        border.color: gradStopSwatchHover.containsMouse ? view.theme.accent : view.theme.border
                                        clip: true

                                        readonly property var curStop: {
                                            var arr = view.rawGradientStops()
                                            var idx = Math.max(0, Math.min(arr.length - 1, view.gradientSelectedStop))
                                            return arr.length > 0 ? arr[idx] : null
                                        }

                                        Checkerboard { anchors.fill: parent; square: 4 }
                                        Rectangle {
                                            anchors.fill: parent
                                            color: gradStopColorBtn.curStop ? gradStopColorBtn.curStop.hex : view.foregroundColor
                                            opacity: gradStopColorBtn.curStop ? gradStopColorBtn.curStop.alpha : 1.0
                                        }
                                        MouseArea {
                                            id: gradStopSwatchHover
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            ToolTip.visible: containsMouse
                                            ToolTip.text: qsTr("Pick color for selected stop (or double-click stop)")
                                            onClicked: {
                                                view.ensureCustomGradientStops()
                                                var cur = gradStopColorBtn.curStop
                                                gradientStopColorDialog.selectedColor = cur ? cur.hex : view.foregroundColor
                                                gradientStopColorDialog.open()
                                            }
                                        }
                                    }

                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: {
                                            var cur = gradStopColorBtn.curStop
                                            return cur && cur.alpha < 0.5 ? qsTr("α: 0%") : qsTr("α: 100%")
                                        }
                                        ToolTip.visible: hovered
                                        ToolTip.text: qsTr("Toggle stop opacity (100% / 0%)")
                                        onClicked: {
                                            view.ensureCustomGradientStops()
                                            var cur = view.gradientStops[view.gradientSelectedStop]
                                            var nextA = cur && cur.alpha > 0.5 ? 0.0 : 1.0
                                            view.updateGradientStop(view.gradientSelectedStop, { alpha: nextA })
                                        }
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("= FG")
                                        ToolTip.visible: hovered
                                        ToolTip.text: qsTr("Set selected stop to foreground color")
                                        onClicked: view.updateGradientStop(view.gradientSelectedStop, { hex: view.foregroundColor })
                                    }
                                    PanelAction {
                                        Layout.preferredWidth: 30
                                        theme: view.theme
                                        text: "✕"
                                        enabled: view.gradientColorMode === "custom" && view.gradientStops.length > 2
                                        ToolTip.visible: hovered
                                        ToolTip.text: qsTr("Delete selected stop")
                                        onClicked: view.removeSelectedGradientStop()
                                    }
                                }

                                // Shape + Repeat side by side
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    columnSpacing: 6
                                    rowSpacing: 4

                                    Label { text: qsTr("Shape"); color: view.theme.textMuted; font.pixelSize: 11 }
                                    Label { text: qsTr("Repeat"); color: view.theme.textMuted; font.pixelSize: 11 }

                                    ComboBox {
                                        objectName: "gradientShapeCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["linear", "bilinear", "radial", "square", "conical", "spiral"]
                                        model: [qsTr("Linear"), qsTr("Bi-Linear"), qsTr("Radial"), qsTr("Square"), qsTr("Conical"), qsTr("Spiral")]
                                        currentIndex: Math.max(0, keys.indexOf(view.gradientShape))
                                        onActivated: function(idx) { view.gradientShape = keys[idx] || "linear" }
                                    }

                                    ComboBox {
                                        objectName: "gradientRepeatCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["none", "forwards", "alternating"]
                                        model: [qsTr("None"), qsTr("Forwards"), qsTr("Alternating")]
                                        currentIndex: Math.max(0, keys.indexOf(view.gradientRepeat))
                                        onActivated: function(idx) { view.gradientRepeat = keys[idx] || "none" }
                                    }
                                }

                                // Blend mode inline
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Blend"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 44 }
                                    ComboBox {
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["normal", "multiply", "screen", "overlay", "darken", "lighten", "difference"]
                                        model: [qsTr("Normal"), qsTr("Multiply"), qsTr("Screen"), qsTr("Overlay"), qsTr("Darken"), qsTr("Lighten"), qsTr("Difference")]
                                        currentIndex: Math.max(0, keys.indexOf(view.gradientBlendMode))
                                        onActivated: function(idx) { view.gradientBlendMode = keys[idx] || "normal" }
                                    }
                                }

                                // Opacity inline
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Opacity"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 44 }
                                    Slider {
                                        Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                        from: 1; to: 100; stepSize: 1
                                        value: view.gradientOpacity
                                        onMoved: view.gradientOpacity = Math.round(value)
                                    }
                                    Label { text: view.gradientOpacity + "%"; color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 32; horizontalAlignment: Text.AlignRight }
                                }

                                // Dither + Interactive handles on one row
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    CheckBox {
                                        text: qsTr("Dither")
                                        focusPolicy: Qt.NoFocus
                                        checked: view.gradientDither
                                        onToggled: view.gradientDither = checked
                                    }
                                    CheckBox {
                                        text: qsTr("Interactive")
                                        focusPolicy: Qt.NoFocus
                                        checked: view.gradientInteractive
                                        ToolTip.visible: hovered
                                        ToolTip.text: qsTr("Drag handles on canvas · Enter apply · Esc cancel")
                                        onToggled: view.gradientInteractive = checked
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: gradientOverlay.hasDraft
                                    spacing: 6
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        primary: true
                                        text: qsTr("Apply")
                                        onClicked: gradientOverlay.applyDraft()
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Cancel")
                                        onClicked: gradientOverlay.cancelDraft()
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    color: view.theme.textMuted; font.pixelSize: 10
                                    text: qsTr("Drag canvas · Shift 15° · Enter apply · Esc cancel")
                                }
                            }

                            // ------------------------------- draw shapes & curves options
                            ColumnLayout {
                                objectName: "drawOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "draw"
                                spacing: 8

                                Label {
                                    text: qsTr("Tool")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    columnSpacing: 4
                                    rowSpacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Line")
                                        primary: view.drawShape === "line"
                                        onClicked: view.drawShape = "line"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Polyline")
                                        primary: view.drawShape === "polyline"
                                        onClicked: view.drawShape = "polyline"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Bezier")
                                        primary: view.drawShape === "bezier"
                                        onClicked: view.drawShape = "bezier"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Rect")
                                        primary: view.drawShape === "rect"
                                        onClicked: view.drawShape = "rect"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Ellipse")
                                        primary: view.drawShape === "ellipse"
                                        onClicked: view.drawShape = "ellipse"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Polygon")
                                        primary: view.drawShape === "polygon"
                                        onClicked: view.drawShape = "polygon"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        Layout.columnSpan: 2
                                        theme: view.theme
                                        text: qsTr("Star / Regular Poly")
                                        primary: view.drawShape === "star"
                                        onClicked: view.drawShape = "star"
                                    }
                                }

                                // Inkscape-style Star / Regular Polygon controls
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: view.drawShape === "star"
                                    spacing: 6

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4
                                        PanelAction {
                                            Layout.fillWidth: true; theme: view.theme
                                            text: qsTr("Star ★")
                                            primary: !view.drawStarIsPolygon
                                            onClicked: view.drawStarIsPolygon = false
                                        }
                                        PanelAction {
                                            Layout.fillWidth: true; theme: view.theme
                                            text: qsTr("Regular Poly ⬡")
                                            primary: view.drawStarIsPolygon
                                            onClicked: view.drawStarIsPolygon = true
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Label { text: qsTr("Corners"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: String(view.drawStarCorners); color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                        from: 3; to: 24; stepSize: 1
                                        value: view.drawStarCorners
                                        onMoved: view.drawStarCorners = Math.round(value)
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: !view.drawStarIsPolygon
                                        Label { text: qsTr("Spoke ratio"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: Math.round(view.drawStarSpokeRatio * 100) + "%"; color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        Layout.fillWidth: true; focusPolicy: Qt.NoFocus
                                        visible: !view.drawStarIsPolygon
                                        from: 10; to: 95; stepSize: 1
                                        value: Math.round(view.drawStarSpokeRatio * 100)
                                        onMoved: view.drawStarSpokeRatio = Math.round(value) / 100.0
                                    }
                                }

                                Label {
                                    text: qsTr("Outline")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("FG")
                                        primary: view.drawOutlineMode === "foreground"
                                        onClicked: view.drawOutlineMode = "foreground"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("BG")
                                        primary: view.drawOutlineMode === "background"
                                        onClicked: view.drawOutlineMode = "background"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("None")
                                        primary: view.drawOutlineMode === "none"
                                        onClicked: view.drawOutlineMode = "none"
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: view.drawOutlineMode !== "none"
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Label { text: qsTr("Width"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: view.drawStrokeWidth + " px"; color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        Layout.fillWidth: true
                                        from: 1
                                        to: 120
                                        stepSize: 1
                                        value: view.drawStrokeWidth
                                        onMoved: view.drawStrokeWidth = Math.round(value)
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Label { text: qsTr("Outline opacity"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: view.drawStrokeOpacity + "%"; color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        Layout.fillWidth: true
                                        from: 1
                                        to: 100
                                        stepSize: 1
                                        value: view.drawStrokeOpacity
                                        onMoved: view.drawStrokeOpacity = Math.round(value)
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: view.drawShape === "rect" || view.drawShape === "ellipse"
                                             || view.drawShape === "polygon" || view.drawShape === "star"
                                             || view.drawShape === "bezier"
                                    spacing: 6

                                    CheckBox {
                                        visible: view.drawShape === "bezier"
                                        text: qsTr("Close curve")
                                        checked: view.drawBezierClosed
                                        onToggled: view.drawBezierClosed = checked
                                    }

                                    Label {
                                        text: qsTr("Fill")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4
                                        PanelAction {
                                            Layout.fillWidth: true
                                            theme: view.theme
                                            text: qsTr("None")
                                            primary: view.drawFillMode === "none"
                                            onClicked: view.drawFillMode = "none"
                                        }
                                        PanelAction {
                                            Layout.fillWidth: true
                                            theme: view.theme
                                            text: qsTr("BG")
                                            primary: view.drawFillMode === "background"
                                            onClicked: view.drawFillMode = "background"
                                        }
                                        PanelAction {
                                            Layout.fillWidth: true
                                            theme: view.theme
                                            text: qsTr("FG")
                                            primary: view.drawFillMode === "foreground"
                                            onClicked: view.drawFillMode = "foreground"
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: view.drawFillMode !== "none"
                                        Label { text: qsTr("Fill opacity"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: view.drawFillOpacity + "%"; color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        Layout.fillWidth: true
                                        visible: view.drawFillMode !== "none"
                                        from: 1
                                        to: 100
                                        stepSize: 1
                                        value: view.drawFillOpacity
                                        onMoved: view.drawFillOpacity = Math.round(value)
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: drawOverlay.hasDraftPath
                                    spacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        primary: true
                                        text: qsTr("Finish")
                                        onClicked: drawOverlay.finishPath(false)
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Undo pt")
                                        onClicked: drawOverlay.popLastPoint()
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Cancel")
                                        onClicked: drawOverlay.cancelDraft()
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: view.theme.textMuted
                                    font.pixelSize: 11
                                    text: view.drawShape === "bezier"
                                          ? qsTr("Click for corner · Drag for curve · Alt+Drag breaks handle · Shift+Z undo point · Enter finish · Esc cancel")
                                          : (view.drawShape === "polyline" || view.drawShape === "polygon"
                                             ? qsTr("Click to add points · Shift snaps 15° · Shift+Z undo point · Enter/double-click finish · Esc cancel")
                                             : (view.drawShape === "line"
                                                ? qsTr("Drag to draw · Hold Shift to snap 15°")
                                                : qsTr("Drag to draw · Shift = 1:1 · Alt = from center")))
                                }
                            }

                            // ------------------------------- selection options
                            ColumnLayout {
                                objectName: "selectOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "select"
                                spacing: 8

                                Label {
                                    text: qsTr("Shape")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    columnSpacing: 4
                                    rowSpacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Rect")
                                        primary: view.selectShape === "rect"
                                        onClicked: view.selectShape = "rect"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Ellipse")
                                        primary: view.selectShape === "ellipse"
                                        onClicked: view.selectShape = "ellipse"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Lasso")
                                        primary: view.selectShape === "lasso"
                                        onClicked: view.selectShape = "lasso"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Polygon")
                                        primary: view.selectShape === "polygon"
                                        onClicked: view.selectShape = "polygon"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Bezier")
                                        primary: view.selectShape === "bezier"
                                        onClicked: view.selectShape = "bezier"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Magic Wand")
                                        primary: view.selectShape === "wand"
                                        onClicked: view.selectShape = "wand"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        Layout.columnSpan: 2
                                        theme: view.theme
                                        text: qsTr("Similar Color")
                                        primary: view.selectShape === "similar"
                                        onClicked: view.selectShape = "similar"
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: view.selectShape === "wand" || view.selectShape === "similar"
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Label { text: qsTr("Tolerance"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: String(view.wandTolerance); color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        from: 0; to: 255; stepSize: 1
                                        value: view.wandTolerance
                                        onMoved: view.wandTolerance = Math.round(value)
                                    }
                                    CheckBox {
                                        visible: view.selectShape === "wand"
                                        text: qsTr("Contiguous")
                                        focusPolicy: Qt.NoFocus
                                        checked: view.wandContiguous
                                        onToggled: view.wandContiguous = checked
                                    }
                                    CheckBox {
                                        text: qsTr("Sample all layers")
                                        focusPolicy: Qt.NoFocus
                                        checked: view.wandSampleAllLayers
                                        onToggled: view.wandSampleAllLayers = checked
                                    }
                                }

                                Label {
                                    text: qsTr("Mode")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    columnSpacing: 4
                                    rowSpacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Replace")
                                        primary: view.selectMode === "replace"
                                        onClicked: view.selectMode = "replace"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Add")
                                        primary: view.selectMode === "add"
                                        onClicked: view.selectMode = "add"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Subtract")
                                        primary: view.selectMode === "subtract"
                                        onClicked: view.selectMode = "subtract"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Intersect")
                                        primary: view.selectMode === "intersect"
                                        onClicked: view.selectMode = "intersect"
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: view.theme.textMuted
                                    font.pixelSize: 10
                                    text: qsTr("R/A/S: mode · Shift: Add · Alt: Subtract · Shift+Alt: Intersect · Drag inside / Arrows: move frame")
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("Feather"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: view.selectFeather + " px"; color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.NoFocus
                                    from: 0; to: 40; stepSize: 1
                                    value: view.selectFeather
                                    onMoved: view.selectFeather = Math.round(value)
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Button {
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        text: qsTr("Invert")
                                        enabled: view.documentReady && view.hasSelection
                                        onClicked: view.command({ type: "editor_select_invert" })
                                    }
                                    Button {
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        text: qsTr("Clear")
                                        enabled: view.documentReady && view.hasSelection
                                        onClicked: view.command({ type: "editor_select_clear" })
                                    }
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
                                spacing: 6

                                // Mode: Brush / Eraser
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

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

                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: view.editingActiveLayerMask
                                    implicitHeight: maskHintLbl.implicitHeight + 8
                                    radius: view.theme.radius
                                    color: view.theme.surfaceAlt
                                    border.width: 1
                                    border.color: view.theme.accent
                                    Label {
                                        id: maskHintLbl
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        text: qsTr("Editing Layer Mask · White reveals, Black hides")
                                        color: view.theme.accent
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                // Preset (18 Krita-style brushes) + Tip selector on one row
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    ComboBox {
                                        objectName: "brushPresetCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        model: view.kritaBrushPresets.map(function(p) { return p.label })
                                        currentIndex: {
                                            for (var i = 0; i < view.kritaBrushPresets.length; ++i) {
                                                if (view.kritaBrushPresets[i].id === view.brushPresetId) return i
                                            }
                                            return 0
                                        }
                                        onActivated: function(idx) {
                                            if (idx >= 0 && idx < view.kritaBrushPresets.length) {
                                                view.applyBrushPreset(view.kritaBrushPresets[idx])
                                            }
                                        }
                                    }
                                    ComboBox {
                                        objectName: "brushTipCombo"
                                        Layout.preferredWidth: 82
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["round", "flat", "chalk", "spray", "pixel"]
                                        model: [qsTr("Round"), qsTr("Flat"), qsTr("Chalk"), qsTr("Spray"), qsTr("Pixel")]
                                        currentIndex: Math.max(0, keys.indexOf(view.brushTip))
                                        onActivated: function(idx) { view.brushTip = keys[idx] || "round" }
                                    }
                                }

                                // Compact FG hex + optional ColourPair (when rail hidden)
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

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

                                    Label {
                                        text: qsTr("Color")
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                    }

                                    TextField {
                                        id: foregroundColorField
                                        objectName: "foregroundColorField"
                                        Layout.preferredWidth: 94
                                        Layout.maximumWidth: 94
                                        font.pixelSize: 11
                                        text: view.foregroundColor
                                        placeholderText: qsTr("#rrggbb")
                                        onEditingFinished: {
                                            view.setForegroundColor(text)
                                            text = view.foregroundColor
                                            view.forceActiveFocus()
                                        }
                                    }

                                    Item { Layout.fillWidth: true }
                                }

                                Connections {
                                    target: view
                                    function onForegroundColorChanged() {
                                        if (!foregroundColorField.activeFocus)
                                        foregroundColorField.text = view.foregroundColor
                                    }
                                }

                                // Compact swatch grid
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 8
                                    columnSpacing: 3
                                    rowSpacing: 3

                                    Repeater {
                                        model: view.paintSwatches

                                        Rectangle {
                                            required property string modelData
                                            objectName: "paintSwatch_" + modelData.substring(1)
                                            Layout.preferredWidth: 19
                                            Layout.preferredHeight: 19
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

                                // Primary sliders: Size, Opacity, Hardness
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Size"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
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
                                        font.pixelSize: 11
                                        Layout.preferredWidth: 44
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Opacity"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
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
                                        font.pixelSize: 11
                                        Layout.preferredWidth: 44
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Hardness"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                    Slider {
                                        Layout.fillWidth: true
                                        from: 0; to: 100; stepSize: 1
                                        value: view.brushHardness
                                        enabled: view.documentReady
                                        onMoved: view.brushHardness = Math.round(value)
                                    }
                                    Label {
                                        text: qsTr("%1 %").arg(view.brushHardness)
                                        color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight
                                    }
                                }

                                // Collapsible Dynamics (Flow, Spacing, Angle, Scatter)
                                ToolButton {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 24
                                    padding: 0
                                    focusPolicy: Qt.NoFocus
                                    onClicked: view.brushDynamicsExpanded = !view.brushDynamicsExpanded
                                    contentItem: RowLayout {
                                        spacing: 4
                                        Label {
                                            text: (view.brushDynamicsExpanded ? "▾ " : "▸ ") + qsTr("Dynamics")
                                            color: view.theme.textMuted
                                            font.pixelSize: 11
                                            font.bold: true
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            text: qsTr("Flow %1% · Space %2%").arg(view.brushFlow).arg(view.brushSpacing)
                                            color: view.theme.textMuted
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignRight
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: view.brushDynamicsExpanded
                                    spacing: 4

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Label { text: qsTr("Flow"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                        Slider {
                                            Layout.fillWidth: true
                                            from: 5; to: 100; stepSize: 1
                                            value: view.brushFlow
                                            enabled: view.documentReady
                                            onMoved: view.brushFlow = Math.round(value)
                                        }
                                        Label {
                                            text: qsTr("%1 %").arg(view.brushFlow)
                                            color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Label { text: qsTr("Spacing"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                        Slider {
                                            Layout.fillWidth: true
                                            from: 5; to: 100; stepSize: 1
                                            value: view.brushSpacing
                                            enabled: view.documentReady
                                            onMoved: view.brushSpacing = Math.round(value)
                                        }
                                        Label {
                                            text: qsTr("%1 %").arg(view.brushSpacing)
                                            color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: view.brushTip === "flat"
                                        spacing: 6
                                        Label { text: qsTr("Angle"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                        Slider {
                                            Layout.fillWidth: true
                                            from: -90; to: 90; stepSize: 1
                                            value: view.brushAngle
                                            enabled: view.documentReady
                                            onMoved: view.brushAngle = Math.round(value)
                                        }
                                        Label {
                                            text: view.brushAngle + "°"
                                            color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: view.brushTip === "chalk" || view.brushTip === "spray"
                                        spacing: 6
                                        Label { text: qsTr("Scatter"); color: view.theme.textMuted; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                        Slider {
                                            Layout.fillWidth: true
                                            from: 0; to: 200; stepSize: 1
                                            value: view.brushScatter
                                            enabled: view.documentReady
                                            onMoved: view.brushScatter = Math.round(value)
                                        }
                                        Label {
                                            text: qsTr("%1 %").arg(view.brushScatter)
                                            color: view.theme.text; font.pixelSize: 11; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight
                                        }
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("[ ] size · X swap · D reset · Space pan")
                                    color: view.theme.textMuted
                                    font.pixelSize: 10
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

                            // Unified Transform (Illustrator/CorelDRAW Transform Each style):
                            // numeric X/Y/W/H + Lock ratio + Scale % + Angle + Quick Rotate/Flip.
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: view.tool === "transform"
                                spacing: 8

                                readonly property var curRect: view.transformRect()
                                                               || ({ x: 0, y: 0, width: 1, height: 1 })

                                Label {
                                    objectName: "transformSizeReadout"
                                    Layout.fillWidth: true
                                    color: view.theme.textMuted
                                    font.pixelSize: 11
                                    visible: view.hasSelection
                                    text: qsTr("Transforming active selection")
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 4
                                    columnSpacing: 4
                                    rowSpacing: 6

                                    Label { text: "X"; color: view.theme.textMuted; font.pixelSize: 12 }
                                    TextField {
                                        objectName: "transformFieldX"
                                        Layout.fillWidth: true
                                        validator: IntValidator { bottom: -16384; top: 16384 }
                                        text: activeFocus ? text : String(Math.round(parent.parent.curRect.x))
                                        onEditingFinished: {
                                            var r = view.transformRect()
                                            var v = parseInt(text, 10)
                                            if (r && !isNaN(v)) view.setTransformFrame(v, r.y, r.width, r.height)
                                            view.forceActiveFocus()
                                        }
                                    }
                                    Label { text: "Y"; color: view.theme.textMuted; font.pixelSize: 12 }
                                    TextField {
                                        objectName: "transformFieldY"
                                        Layout.fillWidth: true
                                        validator: IntValidator { bottom: -16384; top: 16384 }
                                        text: activeFocus ? text : String(Math.round(parent.parent.curRect.y))
                                        onEditingFinished: {
                                            var r = view.transformRect()
                                            var v = parseInt(text, 10)
                                            if (r && !isNaN(v)) view.setTransformFrame(r.x, v, r.width, r.height)
                                            view.forceActiveFocus()
                                        }
                                    }

                                    Label { text: "W"; color: view.theme.textMuted; font.pixelSize: 12 }
                                    TextField {
                                        objectName: "transformFieldW"
                                        Layout.fillWidth: true
                                        validator: IntValidator { bottom: 1; top: 16384 }
                                        text: activeFocus ? text : String(Math.round(parent.parent.curRect.width))
                                        onEditingFinished: {
                                            var r = view.transformRect()
                                            var v = parseInt(text, 10)
                                            if (r && !isNaN(v) && v >= 1) {
                                                var newH = view.transformLockRatio && r.width > 0
                                                         ? Math.max(1, Math.round(r.height * v / r.width))
                                                         : r.height
                                                view.setTransformFrame(r.x, r.y, v, newH)
                                            }
                                            view.forceActiveFocus()
                                        }
                                    }
                                    Label { text: "H"; color: view.theme.textMuted; font.pixelSize: 12 }
                                    TextField {
                                        objectName: "transformFieldH"
                                        Layout.fillWidth: true
                                        validator: IntValidator { bottom: 1; top: 16384 }
                                        text: activeFocus ? text : String(Math.round(parent.parent.curRect.height))
                                        onEditingFinished: {
                                            var r = view.transformRect()
                                            var v = parseInt(text, 10)
                                            if (r && !isNaN(v) && v >= 1) {
                                                var newW = view.transformLockRatio && r.height > 0
                                                         ? Math.max(1, Math.round(r.width * v / r.height))
                                                         : r.width
                                                view.setTransformFrame(r.x, r.y, newW, v)
                                            }
                                            view.forceActiveFocus()
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    CheckBox {
                                        text: qsTr("Keep aspect ratio")
                                        focusPolicy: Qt.NoFocus
                                        checked: view.transformLockRatio
                                        onToggled: view.transformLockRatio = checked
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    Repeater {
                                        model: [
                                            { label: "50%", factor: 0.5 },
                                            { label: "100%", factor: 1.0 },
                                            { label: "150%", factor: 1.5 },
                                            { label: "200%", factor: 2.0 }
                                        ]
                                        delegate: Button {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            focusPolicy: Qt.NoFocus
                                            padding: 4
                                            onClicked: {
                                                var base = view.identityCorners()
                                                var r = view.transformRect()
                                                if (!base || !r) return
                                                var bw = Math.max(1, base[1][0] - base[0][0])
                                                var bh = Math.max(1, base[2][1] - base[0][1])
                                                var nw = Math.max(1, Math.round(bw * modelData.factor))
                                                var nh = Math.max(1, Math.round(bh * modelData.factor))
                                                var cx = r.x + r.width / 2.0
                                                var cy = r.y + r.height / 2.0
                                                view.setTransformFrame(cx - nw / 2.0, cy - nh / 2.0, nw, nh)
                                            }
                                        }
                                    }
                                }

                                Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: view.theme.textMuted
                                    font.pixelSize: 11
                                    text: qsTr("Shift: ratio / 15° · Alt: center · Arrows: nudge")
                                }

                                Button {
                                    objectName: "transformFitToCanvas"
                                    Layout.fillWidth: true
                                    enabled: view.documentReady
                                    focusPolicy: Qt.NoFocus
                                    text: qsTr("Fit to canvas")
                                    onClicked: view.fitTransformToCanvas()
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label {
                                        text: qsTr("Angle")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        objectName: "transformAngleValue"
                                        text: view.transformRotation.toFixed(1) + "°"
                                        color: view.theme.text
                                        font.bold: true
                                    }
                                }

                                Slider {
                                    objectName: "transformAngleSlider"
                                    Layout.fillWidth: true
                                    from: -180
                                    to: 180
                                    stepSize: 0.5
                                    value: view.transformRotation
                                    focusPolicy: Qt.NoFocus
                                    onMoved: view.transformRotation = Math.round(value * 2) / 2
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
                                                var next = view.transformRotation + modelData
                                                while (next > 180) next -= 360
                                                while (next < -180) next += 360
                                                view.transformRotation = next
                                            }
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    ToolRailButton {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        iconSource: "icons/rotate-left.svg"
                                        tooltip: qsTr("Rotate left")
                                        enabled: view.documentReady
                                        onClicked: view.command({ type: "editor_rotate", degrees: -90, target: "active_layer" })
                                    }
                                    ToolRailButton {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        iconSource: "icons/rotate-right.svg"
                                        tooltip: qsTr("Rotate right")
                                        enabled: view.documentReady
                                        onClicked: view.command({ type: "editor_rotate", degrees: 90, target: "active_layer" })
                                    }
                                    ToolRailButton {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        iconSource: "icons/flip-horizontal.svg"
                                        tooltip: qsTr("Flip horizontal")
                                        enabled: view.documentReady
                                        onClicked: view.command({ type: "editor_flip", axis: "horizontal", target: "active_layer" })
                                    }
                                    ToolRailButton {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        iconSource: "icons/flip-vertical.svg"
                                        tooltip: qsTr("Flip vertical")
                                        enabled: view.documentReady
                                        onClicked: view.command({ type: "editor_flip", axis: "vertical", target: "active_layer" })
                                    }
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

                            // Unified Image Size panel: Resize (scale pixels) vs
                            // Canvas size (expand/crop frame with background fill).
                            // Document-level only: immune to selection and active layer.
                            ColumnLayout {
                                objectName: "imageSizeOptionsPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "resize"
                                spacing: 10

                                RowLayout {
                                    objectName: "imageSizeModeSwitch"
                                    Layout.fillWidth: true
                                    spacing: 4
                                    PanelAction {
                                        objectName: "imageSizeModeResize"
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Resize")
                                        primary: view.imageSizeMode === "resize"
                                        onClicked: view.imageSizeMode = "resize"
                                    }
                                    PanelAction {
                                        objectName: "imageSizeModeCanvas"
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Canvas size")
                                        primary: view.imageSizeMode === "canvasSize"
                                        onClicked: view.imageSizeMode = "canvasSize"
                                    }
                                }

                                EditorResizePanel {
                                    id: resizeOptionsPanel
                                    Layout.fillWidth: true
                                    visible: view.imageSizeMode === "resize"
                                    theme: view.theme
                                    sourceWidth: view.documentWidth
                                    sourceHeight: view.documentHeight
                                }

                                EditorCanvasSizePanel {
                                    id: canvasSizeOptionsPanel
                                    Layout.fillWidth: true
                                    visible: view.imageSizeMode === "canvasSize"
                                    theme: view.theme
                                    sourceWidth: view.documentWidth
                                    sourceHeight: view.documentHeight
                                }
                            }

                            ColorAdjustPanel {
                                id: adjustOptionsPanel
                                objectName: "editorColorAdjustPanel"
                                Layout.fillWidth: true
                                visible: view.tool === "adjust"
                                theme: view.theme
                                viewOnly: false
                                showReset: false
                                onBrightnessChanged: view.scheduleAdjustPreview()
                                onContrastChanged: view.scheduleAdjustPreview()
                                onSaturationChanged: view.scheduleAdjustPreview()
                            }

                            HsvAdjustPanel {
                                id: hsvOptionsPanel
                                Layout.fillWidth: true
                                visible: view.tool === "hsv"
                                theme: view.theme
                                hasMultipleLayers: view.hasMultipleLayers
                                hasSelection: view.hasSelection
                                applyTarget: view.toolApplyTarget
                                onPreviewRequested: function(h, s, v, target) {
                                    view.command({
                                        type: "editor_preview_filter",
                                        clear: false,
                                        kind: "hsv",
                                        hue: h,
                                        saturation: s,
                                        value: v,
                                        target: target
                                    })
                                }
                                onPreviewCleared: {
                                    if (view.documentReady) {
                                        view.command({ type: "editor_preview_filter", clear: true })
                                    }
                                }
                                onApplyRequested: function(h, s, v, target) {
                                    view.command({
                                        type: "editor_adjust_hsv",
                                        hue: h,
                                        saturation: s,
                                        value: v,
                                        target: target
                                    })
                                }
                                onCancelRequested: view.tool = "pointer"
                            }

                            CurvesPanel {
                                id: curvesOptionsPanel
                                Layout.fillWidth: true
                                visible: view.tool === "curves"
                                theme: view.theme
                                hasMultipleLayers: view.hasMultipleLayers
                                hasSelection: view.hasSelection
                                applyTarget: view.toolApplyTarget
                                onPreviewRequested: function(rgb, red, green, blue, target) {
                                    view.command({
                                        type: "editor_preview_filter",
                                        clear: false,
                                        kind: "curves",
                                        rgb: rgb,
                                        red: red,
                                        green: green,
                                        blue: blue,
                                        target: target
                                    })
                                }
                                onPreviewCleared: {
                                    if (view.documentReady) {
                                        view.command({ type: "editor_preview_filter", clear: true })
                                    }
                                }
                                onApplyRequested: function(rgb, red, green, blue, target) {
                                    view.command({
                                        type: "editor_adjust_curves",
                                        rgb: rgb,
                                        red: red,
                                        green: green,
                                        blue: blue,
                                        target: target
                                    })
                                }
                                onCancelRequested: view.tool = "pointer"
                            }

                            ColorBalancePanel {
                                id: colorBalanceOptionsPanel
                                Layout.fillWidth: true
                                visible: view.tool === "colorBalance"
                                theme: view.theme
                                hasMultipleLayers: view.hasMultipleLayers
                                hasSelection: view.hasSelection
                                applyTarget: view.toolApplyTarget
                                onPreviewRequested: function(sh, md, hi, preserveLum, target) {
                                    view.command({
                                        type: "editor_preview_filter",
                                        clear: false,
                                        kind: "color_balance",
                                        shadows: sh,
                                        midtones: md,
                                        highlights: hi,
                                        preserve_luminosity: preserveLum,
                                        target: target
                                    })
                                }
                                onPreviewCleared: {
                                    if (view.documentReady) {
                                        view.command({ type: "editor_preview_filter", clear: true })
                                    }
                                }
                                onApplyRequested: function(sh, md, hi, preserveLum, target) {
                                    view.command({
                                        type: "editor_color_balance",
                                        shadows: sh,
                                        midtones: md,
                                        highlights: hi,
                                        preserve_luminosity: preserveLum,
                                        target: target
                                    })
                                }
                                onCancelRequested: view.tool = "pointer"
                            }

                            ColumnLayout {
                                id: removeBgOptionsPanel
                                objectName: "editorRemoveBgPanel"
                                Layout.fillWidth: true
                                spacing: 10
                                visible: view.tool === "removeBg"

                                readonly property var models: {
                                    var all = (view.state && view.state.aiModels) || []
                                    var out = []
                                    for (var i = 0; i < all.length; ++i) {
                                        var t = (all[i].tier || "").toLowerCase()
                                        if (t !== "ocr" && t !== "upscale" && t !== "caption"
                                            && t !== "detector" && t !== "inpaint") out.push(all[i])
                                    }
                                    return out
                                }
                                property string rembgBrushMode: "off" // "off" | "erase" | "restore"
                                property int rembgBrushRadius: 24
                                property real rembgBrushSoftness: 0.30
                                readonly property var activeTask: (view.state && view.state.aiTask) || null
                                readonly property bool aiBusy: !!(activeTask && activeTask.running)
                                readonly property var selectedModel: {
                                    if (models.length === 0) return null
                                    var idx = Math.max(0, Math.min(models.length - 1, rembgModelCombo.currentIndex))
                                    return models[idx]
                                }

                                Label {
                                    text: qsTr("Model")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                ComboBox {
                                    id: rembgModelCombo
                                    objectName: "rembgModelCombo"
                                    Layout.fillWidth: true
                                    currentIndex: 1
                                    model: {
                                        var list = removeBgOptionsPanel.models
                                        var labels = []
                                        for (var i = 0; i < list.length; ++i) {
                                            var m = list[i]
                                            labels.push(m.name + (m.installed ? "" : " (" + qsTr("Not downloaded") + ")"))
                                        }
                                        return labels
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Label {
                                        text: qsTr("Edge feather")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        text: rembgFeatherSlider.value + " px"
                                        color: view.theme.text
                                        font.pixelSize: 12
                                    }
                                }
                                Slider {
                                    id: rembgFeatherSlider
                                    Layout.fillWidth: true
                                    from: 0
                                    to: 20
                                    stepSize: 1
                                    value: 0
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: removeBgOptionsPanel.aiBusy

                                    Label {
                                        text: removeBgOptionsPanel.activeTask ? removeBgOptionsPanel.activeTask.stage : ""
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                    ProgressBar {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: 100
                                        value: removeBgOptionsPanel.activeTask ? removeBgOptionsPanel.activeTask.percent : 0
                                    }
                                }

                                Label {
                                    visible: !!(removeBgOptionsPanel.activeTask
                                                && !removeBgOptionsPanel.activeTask.running
                                                && removeBgOptionsPanel.activeTask.error)
                                    text: removeBgOptionsPanel.activeTask && removeBgOptionsPanel.activeTask.error
                                          ? removeBgOptionsPanel.activeTask.error : ""
                                    color: view.theme.danger
                                    font.pixelSize: 11
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }

                                Button {
                                    objectName: "rembgDownloadButton"
                                    Layout.fillWidth: true
                                    visible: !!(removeBgOptionsPanel.selectedModel
                                                && !removeBgOptionsPanel.selectedModel.installed
                                                && !removeBgOptionsPanel.aiBusy)
                                    text: qsTr("Download model (%1)")
                                        .arg(view.theme.formatBytes(removeBgOptionsPanel.selectedModel
                                                                    ? (removeBgOptionsPanel.selectedModel.sizeBytes || 0) : 0))
                                    focusPolicy: Qt.NoFocus
                                    onClicked: {
                                        if (removeBgOptionsPanel.selectedModel) {
                                            view.command({
                                                type: "ai_download_model",
                                                model_id: removeBgOptionsPanel.selectedModel.id
                                            })
                                        }
                                    }
                                }

                                RowLayout {
                                    objectName: "rembgApplyTargetRow"
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Label {
                                        text: qsTr("Apply to")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    ComboBox {
                                        objectName: "rembgApplyTargetCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["active_layer", "whole_image", "new_layer"]
                                        model: [qsTr("Active layer"), qsTr("Whole image"), qsTr("New layer")]
                                        currentIndex: Math.max(0, keys.indexOf(view.aiApplyTarget))
                                        onActivated: function(idx) {
                                            view.aiApplyTarget = keys[idx] || "active_layer"
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Button {
                                        objectName: "rembgRunButton"
                                        Layout.fillWidth: true
                                        text: qsTr("Remove background")
                                        focusPolicy: Qt.NoFocus
                                        enabled: view.documentReady
                                                 && !removeBgOptionsPanel.aiBusy
                                                 && !!(removeBgOptionsPanel.selectedModel
                                                       && removeBgOptionsPanel.selectedModel.installed)
                                        onClicked: {
                                            if (removeBgOptionsPanel.selectedModel) {
                                                view.command({
                                                    type: "editor_ai_remove_background",
                                                    model_id: removeBgOptionsPanel.selectedModel.id,
                                                    feather: Math.round(rembgFeatherSlider.value),
                                                    target: view.effectiveAiTarget()
                                                })
                                            }
                                        }
                                    }

                                    Button {
                                        objectName: "rembgCancelButton"
                                        visible: removeBgOptionsPanel.aiBusy
                                        text: qsTr("Cancel")
                                        focusPolicy: Qt.NoFocus
                                        onClicked: view.command({ type: "ai_cancel" })
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 1
                                    Layout.topMargin: 4
                                    Layout.bottomMargin: 2
                                    color: view.theme.border
                                }

                                Label {
                                    text: qsTr("Refine mask (Brush)")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Off")
                                        primary: removeBgOptionsPanel.rembgBrushMode === "off"
                                        onClicked: removeBgOptionsPanel.rembgBrushMode = "off"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Erase BG")
                                        primary: removeBgOptionsPanel.rembgBrushMode === "erase"
                                        onClicked: removeBgOptionsPanel.rembgBrushMode = "erase"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Restore FG")
                                        primary: removeBgOptionsPanel.rembgBrushMode === "restore"
                                        onClicked: removeBgOptionsPanel.rembgBrushMode = "restore"
                                    }
                                }

                                Label {
                                    visible: removeBgOptionsPanel.rembgBrushMode !== "off"
                                    text: removeBgOptionsPanel.rembgBrushMode === "restore"
                                        ? qsTr("Paint on the image to restore cut subject pixels from original (Ctrl+Z to undo)")
                                        : qsTr("Paint on the image to erase leftover background to transparent (Ctrl+Z to undo)")
                                    color: view.theme.textMuted
                                    font.pixelSize: 11
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: removeBgOptionsPanel.rembgBrushMode !== "off"
                                    Label { text: qsTr("Mask brush size"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: removeBgOptionsPanel.rembgBrushRadius + " px"; color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    Layout.fillWidth: true
                                    visible: removeBgOptionsPanel.rembgBrushMode !== "off"
                                    focusPolicy: Qt.NoFocus
                                    from: 6; to: 120; stepSize: 2
                                    value: removeBgOptionsPanel.rembgBrushRadius
                                    onMoved: removeBgOptionsPanel.rembgBrushRadius = Math.round(value)
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: removeBgOptionsPanel.rembgBrushMode !== "off"
                                    Label { text: qsTr("Brush softness"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: Math.round(removeBgOptionsPanel.rembgBrushSoftness * 100) + "%"; color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    Layout.fillWidth: true
                                    visible: removeBgOptionsPanel.rembgBrushMode !== "off"
                                    focusPolicy: Qt.NoFocus
                                    from: 0.0; to: 1.0; stepSize: 0.05
                                    value: removeBgOptionsPanel.rembgBrushSoftness
                                    onMoved: removeBgOptionsPanel.rembgBrushSoftness = value
                                }
                            }

                            // ------------------------------------------- Watermark Remover (Gemini + General Region)
                            ColumnLayout {
                                id: watermarkOptionsPanel
                                objectName: "editorWatermarkPanel"
                                Layout.fillWidth: true
                                spacing: 10
                                visible: view.tool === "watermark"

                                property string wmMode: "ai" // "ai" | "gemini" | "region"
                                readonly property var activeTask: (view.state && view.state.aiTask) || null
                                readonly property bool wmBusy: !!(activeTask && activeTask.running)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("AI Auto")
                                        primary: watermarkOptionsPanel.wmMode === "ai"
                                        onClicked: watermarkOptionsPanel.wmMode = "ai"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Gemini")
                                        primary: watermarkOptionsPanel.wmMode === "gemini"
                                        onClicked: watermarkOptionsPanel.wmMode = "gemini"
                                    }
                                    PanelAction {
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Region")
                                        primary: watermarkOptionsPanel.wmMode === "region"
                                        onClicked: watermarkOptionsPanel.wmMode = "region"
                                    }
                                }

                                RowLayout {
                                    objectName: "watermarkApplyTargetRow"
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Label {
                                        text: qsTr("Apply to")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    ComboBox {
                                        objectName: "watermarkApplyTargetCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["active_layer", "whole_image", "new_layer"]
                                        model: [qsTr("Active layer"), qsTr("Whole image"), qsTr("New layer")]
                                        currentIndex: Math.max(0, keys.indexOf(view.aiApplyTarget))
                                        onActivated: function(idx) {
                                            view.aiApplyTarget = keys[idx] || "active_layer"
                                        }
                                    }
                                }

                                // Mode 0: AI Watermark Detector (YOLO26 / YOLO11) + Inpainter (MI-GAN / LaMa)
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: watermarkOptionsPanel.wmMode === "ai"

                                    readonly property string detKey: aiDetectorCombo.keys[aiDetectorCombo.currentIndex] || "watermark-yolo26"
                                    readonly property bool manualMode: detKey === "none"
                                    readonly property bool brushMode: detKey === "brush"
                                    readonly property bool autoDetectMode: !manualMode && !brushMode

                                    Label {
                                        text: qsTr("Detector model")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    ComboBox {
                                        id: aiDetectorCombo
                                        objectName: "editorAiDetectorCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["watermark-yolo26", "watermark-yolo11", "brush", "none"]
                                        model: [
                                            qsTr("YOLO26 Watermark (Fast, 9.8 MB)"),
                                            qsTr("YOLO11 Watermark (Balanced, 11 MB)"),
                                            qsTr("Brush mask (Paint on image)"),
                                            qsTr("Manual region (No detector)")
                                        ]
                                        currentIndex: 0
                                    }

                                    Label {
                                        text: qsTr("Inpainter model")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    ComboBox {
                                        id: aiInpainterCombo
                                        objectName: "editorAiInpainterCombo"
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["migan-pipeline-v2", "lama-fp32"]
                                        model: [
                                            qsTr("MI-GAN v2 (Fast CPU, 28 MB)"),
                                            qsTr("LaMa FFC (High Quality, 208 MB)")
                                        ]
                                        currentIndex: 0
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: parent.autoDetectMode
                                        Label {
                                            text: qsTr("Confidence")
                                            color: view.theme.textMuted
                                            font.pixelSize: 12
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: Math.round(aiConfSlider.value * 100) + "%"
                                            color: view.theme.text
                                            font.pixelSize: 12
                                        }
                                    }
                                    Slider {
                                        id: aiConfSlider
                                        Layout.fillWidth: true
                                        visible: parent.autoDetectMode
                                        focusPolicy: Qt.NoFocus
                                        from: 0.15
                                        to: 0.90
                                        stepSize: 0.05
                                        value: 0.45
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: parent.autoDetectMode
                                        Label {
                                            text: qsTr("Mask padding")
                                            color: view.theme.textMuted
                                            font.pixelSize: 12
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: Math.round(aiPadSlider.value) + " px"
                                            color: view.theme.text
                                            font.pixelSize: 12
                                        }
                                    }
                                    Slider {
                                        id: aiPadSlider
                                        Layout.fillWidth: true
                                        visible: parent.autoDetectMode
                                        focusPolicy: Qt.NoFocus
                                        from: 0
                                        to: 32
                                        stepSize: 2
                                        value: 8
                                    }

                                    // Freehand brush mask controls when detector == "brush"
                                    Label {
                                        visible: parent.brushMode
                                        text: qsTr("Paint directly over the watermark on the image")
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: parent.brushMode
                                        Label {
                                            text: qsTr("Mask brush size")
                                            color: view.theme.textMuted
                                            font.pixelSize: 12
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: view.wmBrushRadius + " px"
                                            color: view.theme.text
                                            font.pixelSize: 12
                                        }
                                    }
                                    Slider {
                                        id: aiBrushRadiusSlider
                                        Layout.fillWidth: true
                                        visible: parent.brushMode
                                        focusPolicy: Qt.NoFocus
                                        from: 6
                                        to: 120
                                        stepSize: 2
                                        value: view.wmBrushRadius
                                        onMoved: view.wmBrushRadius = Math.round(value)
                                    }
                                    PanelAction {
                                        visible: parent.brushMode
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        text: qsTr("Clear mask")
                                        enabled: (view.wmBrushStrokes || []).length > 0
                                        onClicked: view.clearWmBrushMask()
                                    }

                                    // Manual region inputs when detector == "none"
                                    Label {
                                        visible: parent.manualMode
                                        text: qsTr("Drag on the image to mark the watermark area")
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4
                                        visible: parent.manualMode
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↘"; onClicked: view.setWmCornerPreset("br") }
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↙"; onClicked: view.setWmCornerPreset("bl") }
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↗"; onClicked: view.setWmCornerPreset("tr") }
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↖"; onClicked: view.setWmCornerPreset("tl") }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6; visible: parent.manualMode
                                        Label { text: "X"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionX)
                                            onEditingFinished: view.setWmRegion(parseInt(text) || 0, view.wmRegionY, view.wmRegionW, view.wmRegionH)
                                            Keys.onEscapePressed: focus = false
                                        }
                                        Label { text: "Y"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionY)
                                            onEditingFinished: view.setWmRegion(view.wmRegionX, parseInt(text) || 0, view.wmRegionW, view.wmRegionH)
                                            Keys.onEscapePressed: focus = false
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6; visible: parent.manualMode
                                        Label { text: "W"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionW)
                                            onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, parseInt(text) || 24, view.wmRegionH)
                                            Keys.onEscapePressed: focus = false
                                        }
                                        Label { text: "H"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionH)
                                            onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, view.wmRegionW, parseInt(text) || 24)
                                            Keys.onEscapePressed: focus = false
                                        }
                                    }

                                    PanelAction {
                                        objectName: "editorAiInpaintRunBtn"
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        primary: true
                                        text: parent.brushMode ? qsTr("Inpaint painted mask (AI)")
                                            : parent.manualMode ? qsTr("Inpaint region (AI)")
                                            : qsTr("Detect & remove watermark (AI)")
                                        enabled: view.documentReady && !watermarkOptionsPanel.wmBusy
                                                 && (!parent.brushMode || (view.wmBrushStrokes || []).length > 0)
                                        onClicked: {
                                            view.command({
                                                type: "editor_ai_inpaint",
                                                detector_model: aiDetectorCombo.keys[aiDetectorCombo.currentIndex] || "watermark-yolo26",
                                                inpainter_model: aiInpainterCombo.keys[aiInpainterCombo.currentIndex] || "migan-pipeline-v2",
                                                confidence: aiConfSlider.value,
                                                mask_padding: Math.round(aiPadSlider.value),
                                                region_x: view.wmRegionX,
                                                region_y: view.wmRegionY,
                                                region_width: Math.max(8, view.wmRegionW),
                                                region_height: Math.max(8, view.wmRegionH),
                                                brush_strokes: view.wmBrushStrokes || [],
                                                target: view.effectiveAiTarget()
                                            })
                                        }
                                    }
                                }

                                // Mode 1: Gemini Reverse Alpha Blending (Advanced)
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: watermarkOptionsPanel.wmMode === "gemini"

                                    Label {
                                        text: qsTr("Logo size")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    ComboBox {
                                        id: geminiSizeCombo
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        readonly property var keys: ["auto", "small", "large"]
                                        model: [qsTr("Auto (48 / 96 px)"), "48 × 48 px", "96 × 96 px"]
                                        currentIndex: 0
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Label {
                                            text: qsTr("Logo brightness")
                                            color: view.theme.textMuted
                                            font.pixelSize: 12
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: Math.round(geminiLogoSlider.value)
                                            color: view.theme.text
                                            font.pixelSize: 12
                                        }
                                    }
                                    Slider {
                                        id: geminiLogoSlider
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        from: 200
                                        to: 255
                                        stepSize: 1
                                        value: 255
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Label { text: "dX"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            id: geminiOffX
                                            Layout.fillWidth: true
                                            text: "0"
                                            inputMethodHints: Qt.ImhDigitsOnly
                                            Keys.onEscapePressed: focus = false
                                        }
                                        Label { text: "dY"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            id: geminiOffY
                                            Layout.fillWidth: true
                                            text: "0"
                                            inputMethodHints: Qt.ImhDigitsOnly
                                            Keys.onEscapePressed: focus = false
                                        }
                                    }

                                    CheckBox {
                                        id: geminiForceCheck
                                        text: qsTr("Force remove (skip detection)")
                                        checked: false
                                        focusPolicy: Qt.NoFocus
                                    }

                                    PanelAction {
                                        objectName: "editorGeminiRunBtn"
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        primary: true
                                        text: qsTr("Remove Gemini logo")
                                        enabled: view.documentReady && !watermarkOptionsPanel.wmBusy
                                        onClicked: {
                                            view.command({
                                                type: "editor_dewatermark_gemini",
                                                size: geminiSizeCombo.keys[geminiSizeCombo.currentIndex] || "auto",
                                                logo_value: geminiLogoSlider.value,
                                                force: geminiForceCheck.checked,
                                                offset_x: parseInt(geminiOffX.text) || 0,
                                                offset_y: parseInt(geminiOffY.text) || 0,
                                                target: view.effectiveAiTarget()
                                            })
                                        }
                                    }
                                }

                                // Mode 2: General Watermark Region Inpaint
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: watermarkOptionsPanel.wmMode === "region"

                                    Label {
                                        text: qsTr("Drag on the image to mark the watermark area")
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        text: qsTr("Quick corner presets")
                                        color: view.theme.textMuted
                                        font.pixelSize: 12
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↘"; onClicked: view.setWmCornerPreset("br") }
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↙"; onClicked: view.setWmCornerPreset("bl") }
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↗"; onClicked: view.setWmCornerPreset("tr") }
                                        PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↖"; onClicked: view.setWmCornerPreset("tl") }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Label { text: "X"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionX)
                                            onEditingFinished: view.setWmRegion(parseInt(text) || 0, view.wmRegionY, view.wmRegionW, view.wmRegionH)
                                            Keys.onEscapePressed: focus = false
                                        }
                                        Label { text: "Y"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionY)
                                            onEditingFinished: view.setWmRegion(view.wmRegionX, parseInt(text) || 0, view.wmRegionW, view.wmRegionH)
                                            Keys.onEscapePressed: focus = false
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Label { text: "W"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionW)
                                            onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, parseInt(text) || 24, view.wmRegionH)
                                            Keys.onEscapePressed: focus = false
                                        }
                                        Label { text: "H"; color: view.theme.textMuted; font.pixelSize: 12 }
                                        TextField {
                                            Layout.fillWidth: true; text: String(view.wmRegionH)
                                            onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, view.wmRegionW, parseInt(text) || 24)
                                            Keys.onEscapePressed: focus = false
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Label { text: qsTr("Edge blend"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                        Label { text: Math.round(inpaintFeatherSlider.value) + " px"; color: view.theme.text; font.pixelSize: 12 }
                                    }
                                    Slider {
                                        id: inpaintFeatherSlider
                                        Layout.fillWidth: true
                                        focusPolicy: Qt.NoFocus
                                        from: 0
                                        to: 20
                                        stepSize: 1
                                        value: 4
                                    }

                                    PanelAction {
                                        objectName: "editorInpaintRunBtn"
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        primary: true
                                        text: qsTr("Remove watermark region")
                                        enabled: view.documentReady && !watermarkOptionsPanel.wmBusy
                                        onClicked: {
                                            view.command({
                                                type: "editor_inpaint_region",
                                                x: view.wmRegionX,
                                                y: view.wmRegionY,
                                                width: Math.max(8, view.wmRegionW),
                                                height: Math.max(8, view.wmRegionH),
                                                feather: Math.round(inpaintFeatherSlider.value),
                                                target: view.effectiveAiTarget()
                                            })
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    visible: watermarkOptionsPanel.wmBusy
                                    Label {
                                        Layout.fillWidth: true
                                        text: watermarkOptionsPanel.activeTask && watermarkOptionsPanel.activeTask.stage
                                            ? watermarkOptionsPanel.activeTask.stage : qsTr("Working…")
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ProgressBar {
                                            Layout.fillWidth: true
                                            from: 0; to: 100
                                            value: watermarkOptionsPanel.activeTask ? watermarkOptionsPanel.activeTask.percent : 0
                                        }
                                        Button {
                                            text: qsTr("Cancel")
                                            focusPolicy: Qt.NoFocus
                                            onClicked: view.command({ type: "ai_cancel" })
                                        }
                                    }
                                }

                                Label {
                                    visible: !!(watermarkOptionsPanel.activeTask && !watermarkOptionsPanel.wmBusy && watermarkOptionsPanel.activeTask.error)
                                    text: watermarkOptionsPanel.activeTask && watermarkOptionsPanel.activeTask.error ? watermarkOptionsPanel.activeTask.error : ""
                                    color: view.theme.danger
                                    font.pixelSize: 11
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }

                            // ------------------------------------------- AI Caption & .txt Editor (Advanced)
                            ColumnLayout {
                                id: captionOptionsPanel
                                objectName: "editorCaptionPanel"
                                Layout.fillWidth: true
                                spacing: 10
                                visible: view.tool === "caption"

                                readonly property var activeTask: (view.state && view.state.aiTask) || null
                                readonly property bool capBusy: !!(activeTask && activeTask.running)
                                readonly property string savedCaption: (view.state && view.state.editorCaption) || ""
                                property string _lastAppliedCap: ""

                                onSavedCaptionChanged: {
                                    if (!captionTextArea.activeFocus) {
                                        captionTextArea.text = savedCaption
                                    }
                                }

                                onActiveTaskChanged: {
                                    if (!activeTask || activeTask.running || !activeTask.captionText) return
                                    if (activeTask.captionText === _lastAppliedCap) return
                                    _lastAppliedCap = activeTask.captionText
                                    if (captionAppendCheck.checked && captionTextArea.text.trim().length > 0) {
                                        captionTextArea.text = captionTextArea.text.trim() + ", " + activeTask.captionText
                                    } else {
                                        captionTextArea.text = activeTask.captionText
                                    }
                                }

                                Label {
                                    text: qsTr("Caption model")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                ComboBox {
                                    id: captionModelCombo
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.NoFocus
                                    readonly property var ids: ["wd-vit-tagger-v3", "wd-swinv2-tagger-v3"]
                                    model: ["WD-ViT v3 (Fast)", "WD-SwinV2 v3 (Accurate)"]
                                    currentIndex: 0
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("General threshold"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: captionGenThresh.value.toFixed(2); color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    id: captionGenThresh
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.NoFocus
                                    from: 0.15
                                    to: 0.85
                                    stepSize: 0.05
                                    value: 0.35
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Label { text: qsTr("Character threshold"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                                    Label { text: captionCharThresh.value.toFixed(2); color: view.theme.text; font.pixelSize: 12 }
                                }
                                Slider {
                                    id: captionCharThresh
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.NoFocus
                                    from: 0.30
                                    to: 0.95
                                    stepSize: 0.05
                                    value: 0.85
                                }

                                TextField {
                                    id: captionPrefixField
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("Prefix tags (optional)")
                                    Keys.onEscapePressed: focus = false
                                }
                                TextField {
                                    id: captionExcludeField
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("Exclude tags (comma-separated)")
                                    Keys.onEscapePressed: focus = false
                                }

                                CheckBox {
                                    id: captionSpacesCheck
                                    text: qsTr("Replace underscores with spaces")
                                    checked: true
                                    focusPolicy: Qt.NoFocus
                                }
                                CheckBox {
                                    id: captionAppendCheck
                                    text: qsTr("Append to existing caption")
                                    checked: false
                                    focusPolicy: Qt.NoFocus
                                }

                                PanelAction {
                                    objectName: "editorCaptionGenerateBtn"
                                    Layout.fillWidth: true
                                    theme: view.theme
                                    primary: true
                                    text: qsTr("Generate caption (AI)")
                                    enabled: view.documentReady && !captionOptionsPanel.capBusy
                                    onClicked: {
                                        captionOptionsPanel._lastAppliedCap = ""
                                        view.command({
                                            type: "editor_generate_caption",
                                            model_id: captionModelCombo.ids[captionModelCombo.currentIndex] || "wd-vit-tagger-v3",
                                            general_threshold: captionGenThresh.value,
                                            character_threshold: captionCharThresh.value,
                                            replace_underscores: captionSpacesCheck.checked,
                                            prefix: captionPrefixField.text,
                                            suffix: "",
                                            exclude_tags: captionExcludeField.text
                                        })
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    visible: captionOptionsPanel.capBusy
                                    Label {
                                        Layout.fillWidth: true
                                        text: captionOptionsPanel.activeTask && captionOptionsPanel.activeTask.stage
                                            ? captionOptionsPanel.activeTask.stage : qsTr("Working…")
                                        color: view.theme.textMuted
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        ProgressBar {
                                            Layout.fillWidth: true
                                            from: 0; to: 100
                                            value: captionOptionsPanel.activeTask ? captionOptionsPanel.activeTask.percent : 0
                                        }
                                        Button {
                                            text: qsTr("Cancel")
                                            focusPolicy: Qt.NoFocus
                                            onClicked: view.command({ type: "ai_cancel" })
                                        }
                                    }
                                }

                                Label {
                                    visible: !!(captionOptionsPanel.activeTask && !captionOptionsPanel.capBusy && captionOptionsPanel.activeTask.error)
                                    text: captionOptionsPanel.activeTask && captionOptionsPanel.activeTask.error ? captionOptionsPanel.activeTask.error : ""
                                    color: view.theme.danger
                                    font.pixelSize: 11
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }

                                Label {
                                    text: qsTr("Caption (.txt)")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }

                                ScrollView {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 140
                                    clip: true
                                    TextArea {
                                        id: captionTextArea
                                        objectName: "editorCaptionTextArea"
                                        wrapMode: TextArea.Wrap
                                        placeholderText: qsTr("Edit or type tags / caption here…")
                                        text: captionOptionsPanel.savedCaption
                                        color: view.theme.text
                                        Keys.onEscapePressed: focus = false
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    PanelAction {
                                        objectName: "editorCaptionSaveBtn"
                                        Layout.fillWidth: true
                                        theme: view.theme
                                        primary: true
                                        text: qsTr("Save .txt")
                                        enabled: view.documentReady
                                        onClicked: view.command({ type: "editor_save_caption", text: captionTextArea.text })
                                    }
                                    PanelAction {
                                        theme: view.theme
                                        text: qsTr("Clear")
                                        enabled: view.documentReady && (captionTextArea.text.length > 0 || captionOptionsPanel.savedCaption.length > 0)
                                        onClicked: {
                                            captionTextArea.text = ""
                                            view.command({ type: "editor_save_caption", text: "" })
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                objectName: "toolApplyTargetRow"
                                visible: !inspector.topCollapsed && inspector.topTab === "options"
                                         && view.hasMultipleLayers && !view.hasSelection
                                         && ((view.tool === "transform" && view.transformMode === "free")
                                             || view.tool === "rotate"
                                             || view.tool === "adjust")
                                         && view.toolOptionsVisible
                                Layout.fillWidth: true
                                spacing: 8
                                Label {
                                    text: qsTr("Apply to")
                                    color: view.theme.textMuted
                                    font.pixelSize: 12
                                }
                                ComboBox {
                                    objectName: "toolApplyTargetCombo"
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.NoFocus
                                    readonly property var keys: ["active_layer", "whole_image"]
                                    model: [qsTr("Active layer"), qsTr("Whole image")]
                                    currentIndex: Math.max(0, keys.indexOf(view.toolApplyTarget))
                                    onActivated: function(idx) {
                                        view.toolApplyTarget = keys[idx] || "active_layer"
                                        if (view.tool === "transform") view.resetTransformCorners()
                                    }
                                }
                            }

                            GridLayout {
                                id: cropActions
                                objectName: "cropActions"
                                visible: !inspector.topCollapsed && inspector.topTab === "options"
                                         && (view.tool === "crop" || view.tool === "transform" || view.tool === "rotate"
                                             || view.tool === "resize" || view.tool === "canvasSize"
                                             || view.tool === "adjust")
                                         && view.toolOptionsVisible
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                Layout.bottomMargin: 8
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
                                    visible: view.tool === "resize" && view.imageSizeMode === "resize"
                                    focusPolicy: Qt.NoFocus
                                    enabled: view.documentReady && resizeOptionsPanel.changed
                                    onClicked: view.applyResizePanel()
                                }
                                Button {
                                    objectName: "resetResizePanel"
                                    text: qsTr("Reset")
                                    Layout.fillWidth: true
                                    visible: view.tool === "resize" && view.imageSizeMode === "resize"
                                    focusPolicy: Qt.NoFocus
                                    enabled: view.documentReady && resizeOptionsPanel.changed
                                    onClicked: resizeOptionsPanel.reset()
                                }
                                Button {
                                    objectName: "applyCanvasSizePanel"
                                    text: qsTr("Apply")
                                    Layout.fillWidth: true
                                    visible: view.tool === "resize" && view.imageSizeMode === "canvasSize"
                                    focusPolicy: Qt.NoFocus
                                    enabled: view.documentReady && canvasSizeOptionsPanel.changed
                                    onClicked: view.applyCanvasSizePanel()
                                }
                                Button {
                                    objectName: "resetCanvasSizePanel"
                                    text: qsTr("Reset")
                                    Layout.fillWidth: true
                                    visible: view.tool === "resize" && view.imageSizeMode === "canvasSize"
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
                        }
                    }
                    }

                    // Only fill remaining height when no scrollable body is
                    // shown (e.g. Pointer / Hand "This tool has no options."),
                    // so neither `toolOptionsHost` nor `topHistoryPanel` ever
                    // splits height 50/50 with this spacer.
                    Item {
                        objectName: "toolZoneSpacer"
                        visible: !inspector.topCollapsed && inspector.topTab === "options" && !inspector.toolOptionsShown
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
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
                    Layout.preferredHeight: Math.max(8, implicitHeight)
                    Layout.topMargin: 4
                    Layout.bottomMargin: 4
                    orientation: Qt.Vertical
                    visible: view.toolOptionsVisible && view.shownReferenceCount > 0
                             && !inspector.topDetached && !inspector.bottomDetached
                    enabled: !inspector.topCollapsed && !inspector.bottomCollapsed
                    value: inspector.referenceShownHeight
                    defaultValue: Math.max(220, Math.round(inspector.height * 0.42))
                    direction: -1
                    minimum: inspector.minExpandedBottom
                    maximum: inspector.referenceCap
                    onMoved: function(height) {
                        view.referenceDragging = true
                        view.referenceHeight = Math.max(inspector.minExpandedBottom, Math.round(height))
                    }
                    onReleased: function(height) {
                        view.referenceDragging = false
                        view.layoutRequested({ editorReferenceHeight: Math.max(inspector.minExpandedBottom, Math.round(height)) })
                    }
                }

                // -------------------------------------- Row 2: Dedicated Layers panel (default)
                Item {
                    id: bottomDockSlot
                    Layout.fillWidth: true
                    Layout.fillHeight: (!inspector.topZoneActive || inspector.topCollapsed) && !inspector.bottomCollapsed
                    Layout.alignment: inspector.bottomCollapsed ? Qt.AlignTop : Qt.AlignBottom
                    Layout.preferredHeight: inspector.referenceShownHeight
                    Layout.minimumHeight: inspector.bottomCollapsed ? inspector.collapsedRowHeight : inspector.minExpandedBottom
                    Layout.maximumHeight: ((!inspector.topZoneActive || inspector.topCollapsed) && !inspector.bottomCollapsed) ? 100000 : inspector.referenceShownHeight
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    Layout.topMargin: 4
                    Layout.bottomMargin: 8
                    clip: true
                    visible: view.shownReferenceCount > 0 && inspector.bottomPanel === "layers" && !inspector.bottomDetached

                LayersPanel {
                    id: layersZone
                    objectName: "editorLayersPanel"
                    parent: inspector.bottomDetached ? floatingLayersHost : bottomDockSlot
                    anchors.fill: parent
                    clip: true
                    hasSelection: view.hasSelection
                    thumbRevision: (view.editor && view.editor.ramCanvasRevision) || 0
                    visible: view.shownReferenceCount > 0 && (inspector.bottomDetached || inspector.bottomPanel === "layers")
                    collapsed: !inspector.bottomDetached && inspector.bottomCollapsed
                    detached: inspector.bottomDetached
                    theme: view.theme
                    layers: view.editor ? (view.editor.layers || []) : []
                    activeLayerId: view.editor ? (view.editor.activeLayerId || 0) : 0
                    canvasBackground: view.editor ? (view.editor.canvasBackground || null) : null
                    hasDocument: view.hasDocument
                    onCommandRequested: function(cmd) { view.command(cmd) }
                    onPasteRequested: view.requestPasteImage()
                    onCanvasBackgroundPopupRequested: function(anchor) {
                        var bg = view.editor ? view.editor.canvasBackground : null
                        docCanvasBgPopup.transparent = !(bg && bg.length === 3)
                        docCanvasBgPopup.colour = layersZone.bgColorHex()
                        docCanvasBgPopup.showBelow(anchor)
                    }
                    onToggleCollapsed: inspector.bottomCollapsed = !inspector.bottomCollapsed
                    onToggleDetached: inspector.setBottomDetached(!inspector.bottomDetached)
                }
                }

                // -------------------------------------- Secondary reference zone (Info / Original on demand)
                RightDock {
                    id: referenceDock
                    objectName: "editorReferenceDock"
                    Layout.fillWidth: true
                    Layout.fillHeight: (!inspector.topZoneActive || inspector.topCollapsed) && !inspector.bottomCollapsed
                    Layout.alignment: inspector.bottomCollapsed ? Qt.AlignTop : Qt.AlignBottom
                    Layout.preferredHeight: inspector.referenceShownHeight
                    Layout.minimumHeight: inspector.bottomCollapsed ? inspector.collapsedRowHeight : Math.min(140, inspector.referenceShownHeight)
                    Layout.maximumHeight: ((!inspector.topZoneActive || inspector.topCollapsed) && !inspector.bottomCollapsed) ? 100000 : inspector.referenceShownHeight
                    visible: view.shownReferenceCount > 0 && inspector.bottomPanel === "reference"
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
                            redoHistory: view.editor ? (view.editor.redoHistory || []) : []
                            hasDocument: view.hasDocument
                            historyTrimmed: !!(view.editor && view.editor.historyTrimmed)
                            language: view.state.language || ""
                            onJumpRequested: function(targetIndex) {
                                view.command({ type: "editor_history_jump", target_index: targetIndex })
                            }
                            onResetRequested: view.command({ type: "editor_reset" })
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

                // Whenever all visible docked zones are collapsed, push their
                // title bars cleanly to the top instead of letting ColumnLayout
                // spread them across empty vertical space.
                Item {
                    objectName: "inspectorCollapsedSpacer"
                    visible: (!inspector.topZoneActive || inspector.topCollapsed)
                             && (!inspector.bottomZoneActive || inspector.bottomCollapsed)
                             && (inspector.topZoneActive || inspector.bottomZoneActive)
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
            }
        }

        SidePanelRail {
            objectName: "editorRightRail"
            edge: "right"
            theme: view.theme
            buttonPrefix: "editorRail"
            anyActive: view.toolOptionsVisible || view.infoVisible
                       || view.historyVisible || view.originalVisible
            entries: [
                { key: "options", label: qsTr("Tool options"), icon: "icons/preferences.svg",
                  active: view.toolOptionsVisible && !inspector.topCollapsed && inspector.topTab === "options" },
                { key: "history", label: qsTr("History"), icon: "icons/history.svg",
                  active: view.toolOptionsVisible && !inspector.topCollapsed && inspector.topTab === "history" },
                { key: "layers", label: qsTr("Layers"), icon: "icons/view-details.svg",
                  separatorBefore: true,
                  active: view.shownReferenceCount > 0 && !inspector.bottomCollapsed && inspector.bottomPanel === "layers" },
                { key: "info", label: qsTr("Info"), icon: "icons/info.svg",
                  active: view.shownReferenceCount > 0 && !inspector.bottomCollapsed && inspector.bottomPanel === "reference" && view.rightTabIndex === 0 },
                { key: "original", label: qsTr("Original"), icon: "icons/original.svg",
                  active: view.shownReferenceCount > 0 && !inspector.bottomCollapsed && inspector.bottomPanel === "reference" && view.rightTabIndex === 2 }
            ]
            onToggled: function(key) {
                // Group 1 (Top zone): Tool options / History
                if (key === "options" || key === "history") {
                    var topAlreadyActive = view.toolOptionsVisible
                                           && !inspector.topCollapsed
                                           && inspector.topTab === key
                    if (topAlreadyActive) {
                        if (inspector.topDetached) inspector.setTopDetached(false)
                        view.setPanelVisible("options", false)
                    } else {
                        inspector.topTab = key
                        inspector.topCollapsed = false
                        if (!view.toolOptionsVisible) view.setPanelVisible("options", true)
                    }
                    return
                }
                // Group 2 (Bottom zone): Layers / Info / Original
                var isLayers = (key === "layers")
                var bottomAlreadyActive = view.shownReferenceCount > 0
                    && !inspector.bottomCollapsed
                    && (isLayers
                        ? (inspector.bottomPanel === "layers")
                        : (inspector.bottomPanel === "reference"
                           && ((key === "info" && view.rightTabIndex === 0)
                               || (key === "original" && view.rightTabIndex === 2))))
                if (bottomAlreadyActive) {
                    if (inspector.bottomDetached) inspector.setBottomDetached(false)
                    view.layoutRequested({
                        panels: {
                            "editor.info": false,
                            "editor.history": false,
                            "editor.original": false
                        }
                    })
                    return
                }
                if (!isLayers && inspector.bottomDetached) inspector.setBottomDetached(false)
                inspector.bottomCollapsed = false
                inspector.bottomPanel = isLayers ? "layers" : "reference"
                var req = {
                    panels: {
                        "editor.info": true,
                        "editor.history": true,
                        "editor.original": true
                    }
                }
                if (!isLayers) req.editorReferenceTab = key
                view.layoutRequested(req)
            }
            onHideAll: {
                if (inspector.topDetached) inspector.setTopDetached(false)
                if (inspector.bottomDetached) inspector.setBottomDetached(false)
                view.layoutRequested({
                    panels: {
                        "editor.options": false,
                        "editor.info": false,
                        "editor.history": false,
                        "editor.original": false
                    }
                })
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

    // Krita-style quick pop-up color selector triggered by pressing `C` while painting.
    Popup {
        id: quickBrushColorPopup
        objectName: "quickBrushColorPopup"
        parent: canvasHost
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 10
        width: 230

        property real selH: 0
        property real selS: 1
        property real selV: 1

        function syncFromForeground() {
            var b = view.foregroundBytes()
            var r = b[0] / 255.0, g = b[1] / 255.0, bl = b[2] / 255.0
            var max = Math.max(r, g, bl), min = Math.min(r, g, bl), d = max - min
            var h = 0
            if (d > 1e-6) {
                if (max === r) h = 60 * (((g - bl) / d) % 6)
                else if (max === g) h = 60 * (((bl - r) / d) + 2)
                else h = 60 * (((r - g) / d) + 4)
                if (h < 0) h += 360
            }
            selH = h
            selS = max > 1e-6 ? d / max : 0
            selV = max
        }

        function applyHsv() {
            var c = selV * selS
            var x = c * (1 - Math.abs((selH / 60) % 2 - 1))
            var m = selV - c
            var nr = 0, ng = 0, nb = 0
            if (selH < 60) { nr = c; ng = x }
            else if (selH < 120) { nr = x; ng = c }
            else if (selH < 180) { ng = c; nb = x }
            else if (selH < 240) { ng = x; nb = c }
            else if (selH < 300) { nr = x; nb = c }
            else { nr = c; nb = x }
            function hex2(u) {
                var s2 = Math.max(0, Math.min(255, Math.round(u * 255))).toString(16)
                return s2.length < 2 ? "0" + s2 : s2
            }
            view.setForegroundColor("#" + hex2(nr + m) + hex2(ng + m) + hex2(nb + m))
        }

        function openAtCursor(cx, cy) {
            syncFromForeground()
            x = Math.max(8, Math.min(canvasHost.width - width - 8, Math.round(cx - width / 2)))
            y = Math.max(8, Math.min(canvasHost.height - 240, Math.round(cy - 110)))
            open()
        }

        background: Rectangle {
            color: view.theme.surface
            border.width: 1
            border.color: view.theme.border
            radius: 8
        }

        contentItem: ColumnLayout {
            spacing: 8

            // Saturation-Value square
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 140

                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: Qt.hsva(quickBrushColorPopup.selH / 360.0, 1.0, 1.0, 1.0)
                    Rectangle {
                        anchors.fill: parent
                        radius: 4
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#ffffffff" }
                            GradientStop { position: 1.0; color: "#00ffffff" }
                        }
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 4
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 1.0; color: "#ff000000" }
                        }
                    }
                }
                Rectangle {
                    width: 12; height: 12; radius: 6
                    x: quickBrushColorPopup.selS * parent.width - 6
                    y: (1.0 - quickBrushColorPopup.selV) * parent.height - 6
                    color: "transparent"
                    border.width: 2
                    border.color: "#ffffff"
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: function(m) {
                        quickBrushColorPopup.selS = Math.max(0, Math.min(1, m.x / Math.max(1, width)))
                        quickBrushColorPopup.selV = Math.max(0, Math.min(1, 1.0 - m.y / Math.max(1, height)))
                        quickBrushColorPopup.applyHsv()
                    }
                    onPositionChanged: function(m) {
                        if (!pressed) return
                        quickBrushColorPopup.selS = Math.max(0, Math.min(1, m.x / Math.max(1, width)))
                        quickBrushColorPopup.selV = Math.max(0, Math.min(1, 1.0 - m.y / Math.max(1, height)))
                        quickBrushColorPopup.applyHsv()
                    }
                }
            }

            // Hue spectrum bar
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.00; color: "#ff0000" }
                        GradientStop { position: 0.17; color: "#ffff00" }
                        GradientStop { position: 0.33; color: "#00ff00" }
                        GradientStop { position: 0.50; color: "#00ffff" }
                        GradientStop { position: 0.67; color: "#0000ff" }
                        GradientStop { position: 0.83; color: "#ff00ff" }
                        GradientStop { position: 1.00; color: "#ff0000" }
                    }
                }
                Rectangle {
                    width: 6; height: 18; radius: 2
                    x: (quickBrushColorPopup.selH / 360.0) * parent.width - 3
                    y: -1
                    color: "#ffffff"
                    border.width: 1
                    border.color: "#111111"
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: function(m) {
                        quickBrushColorPopup.selH = Math.max(0, Math.min(359.9, (m.x / Math.max(1, width)) * 360.0))
                        quickBrushColorPopup.applyHsv()
                    }
                    onPositionChanged: function(m) {
                        if (!pressed) return
                        quickBrushColorPopup.selH = Math.max(0, Math.min(359.9, (m.x / Math.max(1, width)) * 360.0))
                        quickBrushColorPopup.applyHsv()
                    }
                }
            }

            // Quick swatches
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: view.paintSwatches
                    delegate: Rectangle {
                        required property string modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: 20
                        radius: 3
                        color: modelData
                        border.width: view.foregroundColor === modelData ? 2 : 1
                        border.color: view.foregroundColor === modelData ? view.theme.accent : view.theme.border
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                view.setForegroundColor(modelData)
                                quickBrushColorPopup.close()
                                view.forceActiveFocus()
                            }
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ filter menu
    AppMenu {
        id: filterMenu
        objectName: "editorFilterMenu"
        theme: view.theme
        implicitWidth: 245

        MenuItem {
            objectName: "filterColorLightItem"
            text: qsTr("Brightness / Contrast…")
            enabled: view.documentReady
            onTriggered: view.activateFilterTool("adjust")
        }
        MenuItem {
            objectName: "filterHsvItem"
            text: qsTr("HSV Adjustment… (Ctrl+U)")
            enabled: view.documentReady
            onTriggered: view.activateFilterTool("hsv")
        }
        MenuItem {
            objectName: "filterCurvesItem"
            text: qsTr("Curves… (Ctrl+M)")
            enabled: view.documentReady
            onTriggered: view.activateFilterTool("curves")
        }
        MenuItem {
            objectName: "filterColorBalanceItem"
            text: qsTr("Color balance… (Ctrl+B)")
            enabled: view.documentReady
            onTriggered: view.activateFilterTool("colorBalance")
        }
    }

    // Resizable floating DialogFrames for popped-out Right Sidebar panels
    // (reuses the app's shared `DialogFrame` + `DialogFooter` chrome).
    DialogFrame {
        id: floatingToolDialog
        objectName: "floatingToolDialog"
        namePrefix: "floatingTool"
        title: inspector.topTab === "history" ? qsTr("History") : qsTr("%1 options").arg(inspector.toolName)
        theme: view.theme
        modal: false
        dim: false
        showFooter: false
        resizable: true
        fitToContent: false
        preferredWidth: 360
        preferredHeight: 540
        minWidth: 280
        minHeight: 280
        onCloseRequested: inspector.setTopDetached(false)
        onClosed: if (inspector.topDetached) inspector.topDetached = false

        Item {
            id: floatingToolHost
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(200, floatingToolDialog.bodyRoom() - 2 * floatingToolDialog.bodyPadding)
        }
    }

    DialogFrame {
        id: floatingLayersDialog
        objectName: "floatingLayersDialog"
        namePrefix: "floatingLayers"
        title: qsTr("Layers")
        theme: view.theme
        modal: false
        dim: false
        showFooter: false
        resizable: true
        fitToContent: false
        preferredWidth: 320
        preferredHeight: 420
        minWidth: 260
        minHeight: 240
        onCloseRequested: inspector.setBottomDetached(false)
        onClosed: if (inspector.bottomDetached) inspector.bottomDetached = false

        Item {
            id: floatingLayersHost
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(160, floatingLayersDialog.bodyRoom() - 2 * floatingLayersDialog.bodyPadding)
        }
    }

    HsvAdjustDialog {
        id: hsvDialog
        theme: view.theme
        hasMultipleLayers: view.hasMultipleLayers
        hasSelection: view.hasSelection
        onPreviewRequested: function(h, s, v, target) {
            view.command({
                type: "editor_preview_filter",
                clear: false,
                kind: "hsv",
                hue: h,
                saturation: s,
                value: v,
                target: target
            })
        }
        onPreviewCleared: {
            if (view.documentReady) {
                view.command({ type: "editor_preview_filter", clear: true })
            }
        }
        onApplyRequested: function(h, s, v, target) {
            view.command({
                type: "editor_adjust_hsv",
                hue: h,
                saturation: s,
                value: v,
                target: target
            })
        }
    }

    CurvesDialog {
        id: curvesDialog
        theme: view.theme
        hasMultipleLayers: view.hasMultipleLayers
        hasSelection: view.hasSelection
        onPreviewRequested: function(rgb, red, green, blue, target) {
            view.command({
                type: "editor_preview_filter",
                clear: false,
                kind: "curves",
                rgb: rgb,
                red: red,
                green: green,
                blue: blue,
                target: target
            })
        }
        onPreviewCleared: {
            if (view.documentReady) {
                view.command({ type: "editor_preview_filter", clear: true })
            }
        }
        onApplyRequested: function(rgb, red, green, blue, target) {
            view.command({
                type: "editor_adjust_curves",
                rgb: rgb,
                red: red,
                green: green,
                blue: blue,
                target: target
            })
        }
    }

    ColorBalanceDialog {
        id: colorBalanceDialog
        theme: view.theme
        hasMultipleLayers: view.hasMultipleLayers
        hasSelection: view.hasSelection
        onPreviewRequested: function(sh, md, hi, preserveLum, target) {
            view.command({
                type: "editor_preview_filter",
                clear: false,
                kind: "color_balance",
                shadows: sh,
                midtones: md,
                highlights: hi,
                preserve_luminosity: preserveLum,
                target: target
            })
        }
        onPreviewCleared: {
            if (view.documentReady) {
                view.command({ type: "editor_preview_filter", clear: true })
            }
        }
        onApplyRequested: function(sh, md, hi, preserveLum, target) {
            view.command({
                type: "editor_color_balance",
                shadows: sh,
                midtones: md,
                highlights: hi,
                preserve_luminosity: preserveLum,
                target: target
            })
        }
    }

    /// Document-wide Canvas Background popup (Krita / Affinity style, from LayersPanel).
    BackgroundPopup {
        id: docCanvasBgPopup
        objectName: "docCanvasBgPopup"
        theme: view.theme
        transparent: !(view.editor && view.editor.canvasBackground && view.editor.canvasBackground.length === 3)
        colour: layersZone.bgColorHex()
        alphaLostWarning: view.documentIsJpeg
        onTransparentPicked: view.command({
            type: "editor_set_canvas_background",
            transparent: true
        })
        onColourPicked: function(value) {
            view.command({
                type: "editor_set_canvas_background",
                transparent: false,
                color: view.colorBytes(value)
            })
        }
        onCustomPicked: {
            docCanvasBgColorDialog.selectedColor = layersZone.bgColorHex()
            docCanvasBgColorDialog.open()
        }
    }

    ColorPickerDialog {
        id: docCanvasBgColorDialog
        objectName: "docCanvasBgColorDialog"
        theme: view.theme
        title: qsTr("Canvas background")
        selectedColor: "#ffffff"
        onAccepted: {
            view.command({
                type: "editor_set_canvas_background",
                transparent: false,
                color: view.colorBytes(view.colorText(selectedColor))
            })
            view.forceActiveFocus()
        }
    }

    ColorPickerDialog {
        id: gradientStopColorDialog
        objectName: "gradientStopColorDialog"
        theme: view.theme
        title: qsTr("Gradient stop color")
        selectedColor: "#ffffff"
        onAccepted: {
            view.updateGradientStop(view.gradientSelectedStop, { hex: view.colorText(selectedColor) })
            view.forceActiveFocus()
        }
    }

    DialogFrame {
        id: selectModifyDialog
        objectName: "selectModifyDialog"
        namePrefix: "selectModify"
        theme: view.theme
        preferredWidth: 340
        resizable: false

        property string opKey: "grow"
        property string fieldLabel: qsTr("Amount")
        property int amountVal: 4
        property var lastValues: ({ grow: 4, shrink: 4, border: 4, feather: 8, smooth: 2 })

        function openFor(op, dialogTitle, label) {
            opKey = op
            title = dialogTitle
            fieldLabel = label
            amountVal = lastValues[op] || 4
            selectModifyField.text = String(amountVal)
            open()
            selectModifyField.forceActiveFocus()
            selectModifyField.selectAll()
        }

        function apply() {
            var n = Math.max(1, Math.min(200, parseInt(selectModifyField.text) || amountVal || 1))
            amountVal = n
            var next = Object.assign({}, lastValues)
            next[opKey] = n
            lastValues = next
            close()
            view.command({ type: "editor_select_modify", op: opKey, amount: n })
            view.forceActiveFocus()
        }

        onCloseRequested: close()

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: selectModifyDialog.fieldLabel
                    color: view.theme.textMuted
                    font.pixelSize: 12
                }

                TextField {
                    id: selectModifyField
                    objectName: "selectModifyAmountField"
                    Layout.preferredWidth: 74
                    text: String(selectModifyDialog.amountVal)
                    validator: IntValidator { bottom: 1; top: 200 }
                    onTextEdited: {
                        var v = parseInt(text)
                        if (!isNaN(v)) selectModifyDialog.amountVal = Math.max(1, Math.min(200, v))
                    }
                    onAccepted: selectModifyDialog.apply()
                }

                Label {
                    text: qsTr("px")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                }

                Slider {
                    Layout.fillWidth: true
                    focusPolicy: Qt.NoFocus
                    from: 1; to: 100; stepSize: 1
                    value: Math.min(100, selectModifyDialog.amountVal)
                    onMoved: {
                        selectModifyDialog.amountVal = Math.round(value)
                        selectModifyField.text = String(selectModifyDialog.amountVal)
                    }
                }
            }
        }

        footer: DialogFooter {
            namePrefix: "selectModify"
            theme: view.theme
            height: selectModifyDialog.footerHeight
            Item { Layout.fillWidth: true }
            PanelAction {
                theme: view.theme
                text: qsTr("Cancel")
                implicitWidth: 80
                onClicked: selectModifyDialog.close()
            }
            PanelAction {
                objectName: "selectModifyApplyBtn"
                theme: view.theme
                text: qsTr("Apply")
                primary: true
                implicitWidth: 80
                onClicked: selectModifyDialog.apply()
            }
        }
    }

    ColorPickerDialog {
        id: selActionColorDialog
        objectName: "selActionColorDialog"
        theme: view.theme
        title: qsTr("Choose color")
        property string targetDialog: "fill"
        selectedColor: "#000000"
        onAccepted: {
            var hex = view.colorText(selectedColor)
            if (targetDialog === "stroke") {
                selectionStrokeDialog.customHex = hex
                selectionStrokeDialog.colorSource = "custom"
            } else {
                selectionFillDialog.customHex = hex
                selectionFillDialog.colorSource = "custom"
            }
        }
    }

    DialogFrame {
        id: selectionFillDialog
        objectName: "selectionFillDialog"
        namePrefix: "selectionFill"
        theme: view.theme
        title: qsTr("Fill Selection")
        preferredWidth: 350
        resizable: false

        property string colorSource: "fg" // "fg" | "bg" | "custom"
        property string customHex: "#2f81f7"
        property int fillOpacity: 100

        function effectiveHex() {
            if (colorSource === "bg") return view.backgroundColor
            if (colorSource === "custom") return customHex
            return view.foregroundColor
        }

        function openDialog() {
            open()
        }

        function apply() {
            close()
            view.command({
                type: "editor_selection_fill",
                color: view.colorBytes(effectiveHex()),
                opacity: Math.max(0.01, fillOpacity / 100.0)
            })
            view.forceActiveFocus()
        }

        onCloseRequested: close()

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: qsTr("Color"); color: view.theme.textMuted; font.pixelSize: 12; Layout.preferredWidth: 56 }
                ComboBox {
                    Layout.fillWidth: true
                    focusPolicy: Qt.NoFocus
                    readonly property var keys: ["fg", "bg", "custom"]
                    model: [qsTr("Foreground"), qsTr("Background"), qsTr("Custom color…")]
                    currentIndex: Math.max(0, keys.indexOf(selectionFillDialog.colorSource))
                    onActivated: function(idx) {
                        var k = keys[idx] || "fg"
                        selectionFillDialog.colorSource = k
                        if (k === "custom") {
                            selActionColorDialog.targetDialog = "fill"
                            selActionColorDialog.selectedColor = selectionFillDialog.customHex
                            selActionColorDialog.open()
                        }
                    }
                }
                Rectangle {
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 26
                    radius: view.theme.radius
                    color: selectionFillDialog.effectiveHex()
                    border.width: 1
                    border.color: view.theme.border
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            selActionColorDialog.targetDialog = "fill"
                            selActionColorDialog.selectedColor = selectionFillDialog.effectiveHex()
                            selActionColorDialog.open()
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: qsTr("Opacity"); color: view.theme.textMuted; font.pixelSize: 12; Layout.preferredWidth: 56 }
                Slider {
                    Layout.fillWidth: true
                    focusPolicy: Qt.NoFocus
                    from: 1; to: 100; stepSize: 1
                    value: selectionFillDialog.fillOpacity
                    onMoved: selectionFillDialog.fillOpacity = Math.round(value)
                }
                Label { text: selectionFillDialog.fillOpacity + "%"; color: view.theme.text; font.pixelSize: 12; Layout.preferredWidth: 38; horizontalAlignment: Text.AlignRight }
            }
        }

        footer: DialogFooter {
            namePrefix: "selectionFill"
            theme: view.theme
            height: selectionFillDialog.footerHeight
            Item { Layout.fillWidth: true }
            PanelAction { theme: view.theme; text: qsTr("Cancel"); implicitWidth: 80; onClicked: selectionFillDialog.close() }
            PanelAction { objectName: "selectionFillApplyBtn"; theme: view.theme; text: qsTr("Fill"); primary: true; implicitWidth: 80; onClicked: selectionFillDialog.apply() }
        }
    }

    DialogFrame {
        id: selectionStrokeDialog
        objectName: "selectionStrokeDialog"
        namePrefix: "selectionStroke"
        theme: view.theme
        title: qsTr("Stroke Selection")
        preferredWidth: 360
        resizable: false

        property int strokeWidth: 4
        property string strokePos: "center" // "inside" | "center" | "outside"
        property string colorSource: "fg"   // "fg" | "bg" | "custom"
        property string customHex: "#000000"
        property int strokeOpacity: 100

        function effectiveHex() {
            if (colorSource === "bg") return view.backgroundColor
            if (colorSource === "custom") return customHex
            return view.foregroundColor
        }

        function openDialog() {
            strokeWidthField.text = String(strokeWidth)
            open()
            strokeWidthField.forceActiveFocus()
            strokeWidthField.selectAll()
        }

        function apply() {
            var w = Math.max(1, Math.min(200, parseInt(strokeWidthField.text) || strokeWidth || 1))
            strokeWidth = w
            close()
            view.command({
                type: "editor_selection_stroke",
                color: view.colorBytes(effectiveHex()),
                width: w,
                position: strokePos,
                opacity: Math.max(0.01, strokeOpacity / 100.0)
            })
            view.forceActiveFocus()
        }

        onCloseRequested: close()

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: qsTr("Width"); color: view.theme.textMuted; font.pixelSize: 12; Layout.preferredWidth: 56 }
                TextField {
                    id: strokeWidthField
                    objectName: "selectionStrokeWidthField"
                    Layout.preferredWidth: 64
                    text: String(selectionStrokeDialog.strokeWidth)
                    validator: IntValidator { bottom: 1; top: 200 }
                    onTextEdited: {
                        var v = parseInt(text)
                        if (!isNaN(v)) selectionStrokeDialog.strokeWidth = Math.max(1, Math.min(200, v))
                    }
                    onAccepted: selectionStrokeDialog.apply()
                }
                Label { text: qsTr("px"); color: view.theme.textMuted; font.pixelSize: 12 }
                Slider {
                    Layout.fillWidth: true
                    focusPolicy: Qt.NoFocus
                    from: 1; to: 100; stepSize: 1
                    value: Math.min(100, selectionStrokeDialog.strokeWidth)
                    onMoved: {
                        selectionStrokeDialog.strokeWidth = Math.round(value)
                        strokeWidthField.text = String(selectionStrokeDialog.strokeWidth)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: qsTr("Position"); color: view.theme.textMuted; font.pixelSize: 12; Layout.preferredWidth: 56 }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Inside");  primary: selectionStrokeDialog.strokePos === "inside";  onClicked: selectionStrokeDialog.strokePos = "inside" }
                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Center");  primary: selectionStrokeDialog.strokePos === "center";  onClicked: selectionStrokeDialog.strokePos = "center" }
                    PanelAction { Layout.fillWidth: true; theme: view.theme; text: qsTr("Outside"); primary: selectionStrokeDialog.strokePos === "outside"; onClicked: selectionStrokeDialog.strokePos = "outside" }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: qsTr("Color"); color: view.theme.textMuted; font.pixelSize: 12; Layout.preferredWidth: 56 }
                ComboBox {
                    Layout.fillWidth: true
                    focusPolicy: Qt.NoFocus
                    readonly property var keys: ["fg", "bg", "custom"]
                    model: [qsTr("Foreground"), qsTr("Background"), qsTr("Custom color…")]
                    currentIndex: Math.max(0, keys.indexOf(selectionStrokeDialog.colorSource))
                    onActivated: function(idx) {
                        var k = keys[idx] || "fg"
                        selectionStrokeDialog.colorSource = k
                        if (k === "custom") {
                            selActionColorDialog.targetDialog = "stroke"
                            selActionColorDialog.selectedColor = selectionStrokeDialog.customHex
                            selActionColorDialog.open()
                        }
                    }
                }
                Rectangle {
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 26
                    radius: view.theme.radius
                    color: selectionStrokeDialog.effectiveHex()
                    border.width: 1
                    border.color: view.theme.border
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            selActionColorDialog.targetDialog = "stroke"
                            selActionColorDialog.selectedColor = selectionStrokeDialog.effectiveHex()
                            selActionColorDialog.open()
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: qsTr("Opacity"); color: view.theme.textMuted; font.pixelSize: 12; Layout.preferredWidth: 56 }
                Slider {
                    Layout.fillWidth: true
                    focusPolicy: Qt.NoFocus
                    from: 1; to: 100; stepSize: 1
                    value: selectionStrokeDialog.strokeOpacity
                    onMoved: selectionStrokeDialog.strokeOpacity = Math.round(value)
                }
                Label { text: selectionStrokeDialog.strokeOpacity + "%"; color: view.theme.text; font.pixelSize: 12; Layout.preferredWidth: 38; horizontalAlignment: Text.AlignRight }
            }
        }

        footer: DialogFooter {
            namePrefix: "selectionStroke"
            theme: view.theme
            height: selectionStrokeDialog.footerHeight
            Item { Layout.fillWidth: true }
            PanelAction { theme: view.theme; text: qsTr("Cancel"); implicitWidth: 80; onClicked: selectionStrokeDialog.close() }
            PanelAction { objectName: "selectionStrokeApplyBtn"; theme: view.theme; text: qsTr("Stroke"); primary: true; implicitWidth: 80; onClicked: selectionStrokeDialog.apply() }
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
        MenuItem {
            text: view.theme.menuEntries[28]
            icon.name: "window-close-symbolic"
            enabled: view.hasDocument && !view.saving
            onTriggered: view.requestClose()
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
