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

    property Theme theme: Theme {}
    /// The shared thumbnail cache (C++ `ThumbnailCache`). Null in the QML test
    /// harness, where the pointer frame stays empty instead of decoding a fake
    /// path.
    property var thumbnails: null
    /// The published Core state; `editor` is null until a document is open.
    property var state: ({})
    property int leftPanelWidth: 220
    property int rightPanelWidth: 260
    /// Which tool is selected: `pointer` (no tool), `resize` or `crop`. The
    /// pointer is the default and the no-op tool, so opening the Editor never
    /// leaves an Apply button armed.
    property string tool: "pointer"
    /// Resize links Width and Height through this ratio, so the two fields can
    /// never describe a different shape than the one the user picked. `free` is
    /// the only unlinked choice; `original` follows the document's own aspect
    /// and `current` the pair the user had on screen when it was picked.
    property string resizeRatio: "original"
    /// Crop links Width and Height the same way. `original` keeps the document's
    /// shape, which is the safest default for a crop.
    property string cropRatio: "original"
    /// The pair captured when "Keep current ratio" was picked, one per tool so a
    /// crop choice does not change the next resize. Zero means "not captured
    /// yet": the document's aspect is the fallback.
    property var resizeCurrentRatio: ({ width: 0, height: 0 })
    property var cropCurrentRatio: ({ width: 0, height: 0 })
    /// Where the crop rectangle sits when its size changes: the anchor names the
    /// document corner, edge or centre the rectangle keeps. Typing X/Y by hand
    /// leaves it alone — the anchor is a placement shortcut, not a lock.
    property string cropAnchor: "center"
    /// Resize pads the shorter side to the longer edge with this colour before
    /// cropping and scaling. Centred: Resize has no anchor.
    property bool resizePadSquare: false
    property color resizeFillColor: "#ffffff"
    /// Live preview: each valid Width/Height change asks Core for a rendered
    /// draft at the target size, which the canvas shows without applying it.
    property bool resizeLivePreview: false
    /// The same draft idea for Crop: the canvas shows the rectangle Core would
    /// cut, while the document, its history and its save target stay put.
    property bool cropLivePreview: false

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

    /// The factor for a ratio key, or null when the sides are not linked.
    function ratioFactor(key) {
        for (var index = 0; index < view.sizeRatios.length; ++index) {
            var entry = view.sizeRatios[index]
            if (entry.key !== key) continue
            if (entry.key === "free") return null
            if (entry.key === "current") {
                var captured = view.tool === "crop" ? view.cropCurrentRatio
                                                     : view.resizeCurrentRatio
                if (captured && captured.width > 0 && captured.height > 0) return captured
                if (!view.hasDocument) return null
                return { width: view.documentWidth, height: view.documentHeight }
            }
            if (entry.key === "original") {
                if (!view.hasDocument) return null
                return { width: view.editor.width, height: view.editor.height }
            }
            return entry
        }
        return null
    }

    /// Index of a ratio key in the dropdown, so a combo can be synced without
    /// binding its `currentIndex` (which the control writes itself).
    function ratioIndexFor(key) {
        for (var index = 0; index < view.sizeRatios.length; ++index) {
            if (view.sizeRatios[index].key === key) return index
        }
        return -1
    }

    readonly property int resizeRatioIndex: view.ratioIndexFor(view.resizeRatio)
    readonly property int cropRatioIndex: view.ratioIndexFor(view.cropRatio)

    /// The ratio key the selected tool is using.
    readonly property string activeRatio: view.tool === "crop" ? view.cropRatio : view.resizeRatio

    /// Index of the resize preset that matches both fields, or -1 for custom.
    function matchingPreset() {
        if (!widthField.acceptableInput || !heightField.acceptableInput) return -1
        var w = parseInt(widthField.text)
        var h = parseInt(heightField.text)
        for (var index = 0; index < view.sizePresets.length; ++index) {
            var preset = view.sizePresets[index]
            if (preset.width === w && preset.height === h) return index
        }
        return -1
    }

    /// Crop presets are the concrete sizes that fit inside the document. A
    /// preset the document cannot hold is not offered, so picking one always
    /// describes a legal rectangle; a tiny document simply has a shorter list.
    readonly property var cropPresets: {
        var fits = []
        if (!view.hasDocument) return fits
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
        if (!widthField.acceptableInput || !heightField.acceptableInput) return -1
        var w = parseInt(widthField.text)
        var h = parseInt(heightField.text)
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
        if (!view.hasDocument || !widthField.acceptableInput || !heightField.acceptableInput) return
        var width = parseInt(widthField.text)
        var height = parseInt(heightField.text)
        if (!(width > 0) || !(height > 0)) return
        var anchor = view.cropAnchors[0]
        for (var index = 0; index < view.cropAnchors.length; ++index) {
            if (view.cropAnchors[index].key === view.cropAnchor) {
                anchor = view.cropAnchors[index]
                break
            }
        }
        cropX.text = String(Math.max(0, Math.round((view.documentWidth - width) * anchor.column / 2)))
        cropY.text = String(Math.max(0, Math.round((view.documentHeight - height) * anchor.row / 2)))
    }

    /// Select an anchor and move the rectangle to it.
    function setCropAnchor(key) {
        view.cropAnchor = key
        view.applyCropAnchor()
        draftDebounce.restart()
    }

    /// Typing one side keeps the other on the chosen ratio. Programmatic writes
    /// (a preset, Reset) do not come through here, so they never feed back.
    /// A crop is re-placed through its anchor even when the ratio is free: the
    /// anchor is about where the rectangle sits, not about linking the sides.
    function linkHeightFromWidth() {
        if (!widthField.acceptableInput) return
        var width = parseInt(widthField.text)
        if (!(width > 0)) return
        var factor = view.ratioFactor(view.activeRatio)
        if (factor) {
            heightField.text = String(Math.max(1, Math.round(width * factor.height / factor.width)))
        }
        if (view.tool === "crop") {
            view.applyCropAnchor()
            cropPreset.currentIndex = view.matchingCropPreset()
        } else {
            sizePreset.currentIndex = view.matchingPreset()
        }
    }

    function linkWidthFromHeight() {
        if (!heightField.acceptableInput) return
        var height = parseInt(heightField.text)
        if (!(height > 0)) return
        var factor = view.ratioFactor(view.activeRatio)
        if (factor) {
            widthField.text = String(Math.max(1, Math.round(height * factor.width / factor.height)))
        }
        if (view.tool === "crop") {
            view.applyCropAnchor()
            cropPreset.currentIndex = view.matchingCropPreset()
        } else {
            sizePreset.currentIndex = view.matchingPreset()
        }
    }

    /// Keep the fields on the selected ratio when the ratio itself is picked:
    /// a 16:9 choice with 1024 × 1024 typed must not leave a square pair on a
    /// 16:9 label. The first typed side wins, width first.
    function relinkFields() {
        if (widthField.acceptableInput && parseInt(widthField.text) > 0) {
            view.linkHeightFromWidth()
        } else if (heightField.acceptableInput && parseInt(heightField.text) > 0) {
            view.linkWidthFromHeight()
        }
    }

    /// Freeze the pair on screen as the "Keep current ratio" shape. Both fields must
    /// hold a usable number; otherwise the document's own aspect is the honest
    /// fallback, because that is what the empty placeholders show.
    function captureCurrentRatio() {
        var width = widthField.acceptableInput ? parseInt(widthField.text) : 0
        var height = heightField.acceptableInput ? parseInt(heightField.text) : 0
        if (!(width > 0) || !(height > 0)) {
            if (!view.hasDocument) return
            width = view.documentWidth
            height = view.documentHeight
        }
        var captured = { width: width, height: height }
        if (view.tool === "crop") {
            view.cropCurrentRatio = captured
        } else {
            view.resizeCurrentRatio = captured
        }
    }

    /// Select a ratio for the active tool and mirror it in the right dropdown.
    /// The dropdown index is written imperatively because ComboBox owns
    /// `currentIndex` itself. Picking "Keep current ratio" snapshots the pair before
    /// relinking, so the fields the user is looking at become the locked shape.
    function setRatio(key) {
        if (key === "current") view.captureCurrentRatio()
        if (view.tool === "crop") {
            view.cropRatio = key
            cropRatioBox.currentIndex = view.cropRatioIndex
        } else {
            view.resizeRatio = key
            resizeRatioBox.currentIndex = view.resizeRatioIndex
        }
    }

    /// One click of a field's +/- stepper. An empty field starts from the size
    /// its placeholder shows, so the first nudge moves the document's own
    /// dimension rather than jumping to 1. The other side follows the selected
    /// ratio exactly as typing it would.
    function stepField(field, delta, isWidth) {
        var current = parseInt(field.text)
        if (!(current > 0)) {
            current = Math.round(isWidth ? view.documentWidth : view.documentHeight)
        }
        if (!(current > 0)) current = 1
        field.text = String(Math.max(1, Math.min(20000, current + delta)))
        if (isWidth) {
            view.linkHeightFromWidth()
        } else {
            view.linkWidthFromHeight()
        }
        draftDebounce.restart()
    }

    function resizeFieldsValid() {
        return !!view.hasDocument && widthField.acceptableInput && heightField.acceptableInput
                && parseInt(widthField.text) > 0 && parseInt(heightField.text) > 0
    }

    /// A crop is only sendable when its rectangle really fits the document, so
    /// Apply and the draft both answer the same question Core will ask.
    function cropFieldsValid() {
        if (!resizeFieldsValid()) return false
        if (!cropX.acceptableInput || !cropY.acceptableInput) return false
        var width = parseInt(widthField.text)
        var height = parseInt(heightField.text)
        var x = parseInt(cropX.text)
        var y = parseInt(cropY.text)
        return x >= 0 && y >= 0
                && x + width <= view.documentWidth
                && y + height <= view.documentHeight
    }

    /// Ask Core to render the selected tool's draft without applying it. The
    /// debounce keeps a typed width from spawning a render per key: the previous
    /// draft stays on screen until the newest one lands. The draft carries its
    /// tool, so a switch cannot paint the other tool's result.
    function requestDraft() {
        draftDebounce.stop()
        if (!view.hasDocument) return
        if (view.tool === "resize" && view.resizeLivePreview && view.resizeFieldsValid()) {
            view.command({
                type: "editor_resize_preview",
                width: parseInt(widthField.text),
                height: parseInt(heightField.text),
                fill: view.resizePadSquare ? view.colorRgb(view.resizeFillColor) : null
            })
        } else if (view.tool === "crop" && view.cropLivePreview && view.cropFieldsValid()) {
            view.command({
                type: "editor_crop_preview",
                x: parseInt(cropX.text),
                y: parseInt(cropY.text),
                width: parseInt(widthField.text),
                height: parseInt(heightField.text)
            })
        }
    }

    /// Raised by the empty state and the toolbar's open button; Main owns the
    /// file chooser so the portal/fallback path stays in one place.
    signal requestOpen()
    /// Raised by Save as…: Main owns the chooser, and the chosen path becomes an
    /// `editor_save_as` command. `view.saveAsPath` carries the suggestion.
    signal requestSaveAs()
    signal command(var command)

    readonly property var editor: state.editor || null
    /// The steps applied in this session, oldest first; Core publishes them as
    /// labels and still owns undo/redo. The pointer inspector draws the list.
    readonly property var history: editor ? (editor.history || []) : []
    readonly property bool hasDocument: !!(editor && editor.width > 0)
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
    /// from Crop to Resize cannot paint the crop result for a frame.
    readonly property var previewDraft: {
        if (!editor || !editor.previewDraft) return null
        var draft = editor.previewDraft
        if (tool === "resize" && resizeLivePreview && draft.kind === "resize") return draft
        if (tool === "crop" && cropLivePreview && draft.kind === "crop") return draft
        return null
    }
    /// What the canvas draws: the draft's target size while an edit is being
    /// previewed, the document's own size otherwise.
    readonly property real displayedWidth: previewDraft ? previewDraft.width : documentWidth
    readonly property real displayedHeight: previewDraft ? previewDraft.height : documentHeight

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
        if (view.hostReady) {
            view.fit()
        }
    }

    // An edit that changes the drawn size — a resize or crop landing, or a
    // live-preview draft appearing — keeps a fitted view fitted and leaves a
    // hand-chosen zoom alone (only re-clamping it to the new edges).
    onDisplayedWidthChanged: view.refitOrClamp()
    onDisplayedHeightChanged: view.refitOrClamp()
    // A tool switch keeps one live preview per tool: the newly selected tool's
    // toggle decides whether Core is asked for a draft of its own.
    onToolChanged: draftDebounce.restart()

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
        implicitWidth: view.theme.menuWidth(view.theme.menuLabelWidths)

        MenuItem {
            text: view.theme.menuEntries[24]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_rotate", degrees: -90 })
        }
        MenuItem {
            text: view.theme.menuEntries[25]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_rotate", degrees: 90 })
        }
        MenuItem {
            text: view.theme.menuEntries[26]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_flip", axis: "horizontal" })
        }
        MenuItem {
            text: view.theme.menuEntries[27]
            enabled: view.hasDocument
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
            enabled: view.hasDocument
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
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorZoomOut"
                theme: view.theme
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom out")
                onClicked: view.zoomOut()
            }
            Label {
                objectName: "editorZoomLabel"
                visible: view.hasDocument
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 48
                text: view.zoomPercent + " %"
                color: view.theme.text
                font.pixelSize: 12
            }
            ToolbarButton {
                objectName: "editorZoomIn"
                theme: view.theme
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom in")
                onClicked: view.zoomIn()
            }
            ToolbarButton {
                objectName: "editorFit"
                theme: view.theme
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Fit to window")
                onClicked: view.fit()
            }
            ToolbarButton {
                objectName: "editorActualSize"
                theme: view.theme
                icon.name: "zoom-original-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Actual size (100%)")
                onClicked: view.actualSize()
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorToolbarSave"
                theme: view.theme
                icon.name: "document-save-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument && !view.saved && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save (Ctrl+S)")
                onClicked: view.command({ type: "editor_save" })
            }
            ToolbarButton {
                objectName: "editorToolbarSaveAs"
                theme: view.theme
                icon.name: "document-save-as-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save as… (Ctrl+Shift+S)")
                onClicked: view.requestSaveAs()
            }
            ToolbarSeparator { theme: view.theme }
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
                icon.name: "document-revert-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.modified
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Reset to original")
                onClicked: view.command({ type: "editor_reset" })
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorBack"
                theme: view.theme
                icon.name: "go-previous-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Back to browser")
                onClicked: view.command({ type: "set_workspace", workspace: "browser" })
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorClose"
                theme: view.theme
                icon.name: "window-close-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[29]
                onClicked: view.command({ type: "editor_close" })
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
                    onClicked: view.tool = "pointer"
                }
                Button {
                    objectName: "toolResize"
                    Layout.fillWidth: true
                    text: qsTr("Resize")
                    highlighted: view.tool === "resize"
                    enabled: view.hasDocument
                    onClicked: view.tool = view.tool === "resize" ? "pointer" : "resize"
                }
                Button {
                    objectName: "toolCrop"
                    Layout.fillWidth: true
                    text: qsTr("Crop")
                    highlighted: view.tool === "crop"
                    enabled: view.hasDocument
                    onClicked: view.tool = view.tool === "crop" ? "pointer" : "crop"
                }

                MenuSeparator {}

                // These change pixels the moment they are pressed, so they are
                // actions rather than tools. Undo, Redo and Reset live on the
                // toolbar; the palette keeps the tools and the quick edits.
                Button {
                    objectName: "editsRotateLeft"
                    Layout.fillWidth: true
                    text: qsTr("Rotate left")
                    enabled: view.hasDocument
                    onClicked: view.command({ type: "editor_rotate", degrees: -90 })
                }
                Button {
                    objectName: "editsRotateRight"
                    Layout.fillWidth: true
                    text: qsTr("Rotate right")
                    enabled: view.hasDocument
                    onClicked: view.command({ type: "editor_rotate", degrees: 90 })
                }
                Button {
                    objectName: "editsFlipHorizontal"
                    Layout.fillWidth: true
                    text: qsTr("Flip horizontal")
                    enabled: view.hasDocument
                    onClicked: view.command({ type: "editor_flip", axis: "horizontal" })
                }
                Button {
                    objectName: "editsFlipVertical"
                    Layout.fillWidth: true
                    text: qsTr("Flip vertical")
                    enabled: view.hasDocument
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
                // a scroll view must keep scrolling.
                enabled: view.panHover
                acceptedDevices: PointerDevice.AllDevices
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
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
                onDoubleTapped: view.toggleZoom()
            }

            // Only the picture is clickable, so a click on the empty canvas
            // margin does not look like it did nothing.
            MouseArea {
                id: canvasArea
                anchors.fill: canvas
                acceptedButtons: Qt.RightButton
                enabled: view.hasDocument
                onClicked: function(mouse) {
                    contextMenu.popup(canvasArea, mouse.x, mouse.y)
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
                              : (view.tool === "crop" ? qsTr("Crop") : qsTr("Resize"))
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
                                required property string modelData
                                required property int index
                                width: ListView.view.width
                                height: 26
                                radius: view.theme.radius
                                color: "transparent"

                                Label {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                    color: view.theme.text
                                    font.pixelSize: 12
                                    text: (index + 1) + ". " + modelData
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

                    // ------------------------------- resize/crop: tool options
                    // The two tools share Width/Height; only the selected one
                    // shows its own fields and Apply button. Reset clears the
                    // fields without sending anything.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: view.tool !== "pointer"
                        spacing: 10

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 3
                            columnSpacing: 6
                            rowSpacing: 4

                            Label {
                                text: qsTr("X")
                                visible: view.tool === "crop"
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropX
                                objectName: "cropX"
                                Layout.fillWidth: true
                                visible: view.tool === "crop"
                                font.pixelSize: 12
                                text: "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 0; top: 20000 }
                            }
                            // X/Y have no steppers; the cell keeps the three
                            // columns aligned without leaving a gap.
                            Item { visible: view.tool === "crop" }
                            Label {
                                text: qsTr("Y")
                                visible: view.tool === "crop"
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: cropY
                                objectName: "cropY"
                                Layout.fillWidth: true
                                visible: view.tool === "crop"
                                font.pixelSize: 12
                                text: "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 0; top: 20000 }
                            }
                            Item { visible: view.tool === "crop" }
                            Label {
                                text: qsTr("Width")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: widthField
                                objectName: "widthField"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                placeholderText: view.hasDocument ? String(view.editor.width) : "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 1; top: 20000 }
                                onTextEdited: {
                                    view.linkHeightFromWidth()
                                    draftDebounce.restart()
                                }
                            }
                            // The steppers are the small +/- pair every size
                            // field has: one pixel per click, and the linked
                            // side follows because this is the same path as
                            // typing. A single column keeps them inside the
                            // 260 px panel next to a full-width field.
                            Column {
                                spacing: 0

                                Button {
                                    objectName: "widthStepUp"
                                    implicitWidth: 22
                                    implicitHeight: 14
                                    padding: 0
                                    font.pixelSize: 8
                                    text: "\u25b2"
                                    enabled: view.hasDocument
                                    Accessible.name: qsTr("Increase width")
                                    ToolTip.visible: hovered
                                    ToolTip.text: qsTr("Increase width")
                                    onClicked: view.stepField(widthField, 1, true)
                                }
                                Button {
                                    objectName: "widthStepDown"
                                    implicitWidth: 22
                                    implicitHeight: 14
                                    padding: 0
                                    font.pixelSize: 8
                                    text: "\u25bc"
                                    enabled: view.hasDocument
                                    Accessible.name: qsTr("Decrease width")
                                    ToolTip.visible: hovered
                                    ToolTip.text: qsTr("Decrease width")
                                    onClicked: view.stepField(widthField, -1, true)
                                }
                            }
                            Label {
                                text: qsTr("Height")
                                color: view.theme.textMuted
                            }
                            TextField {
                                id: heightField
                                objectName: "heightField"
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                placeholderText: view.hasDocument ? String(view.editor.height) : "0"
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 1; top: 20000 }
                                onTextEdited: {
                                    view.linkWidthFromHeight()
                                    draftDebounce.restart()
                                }
                            }
                            Column {
                                spacing: 0

                                Button {
                                    objectName: "heightStepUp"
                                    implicitWidth: 22
                                    implicitHeight: 14
                                    padding: 0
                                    font.pixelSize: 8
                                    text: "\u25b2"
                                    enabled: view.hasDocument
                                    Accessible.name: qsTr("Increase height")
                                    ToolTip.visible: hovered
                                    ToolTip.text: qsTr("Increase height")
                                    onClicked: view.stepField(heightField, 1, false)
                                }
                                Button {
                                    objectName: "heightStepDown"
                                    implicitWidth: 22
                                    implicitHeight: 14
                                    padding: 0
                                    font.pixelSize: 8
                                    text: "\u25bc"
                                    enabled: view.hasDocument
                                    Accessible.name: qsTr("Decrease height")
                                    ToolTip.visible: hovered
                                    ToolTip.text: qsTr("Decrease height")
                                    onClicked: view.stepField(heightField, -1, false)
                                }
                            }
                        }

                        // Resize: the ratio that links Width/Height, a list of
                        // concrete sizes, and the optional square pad. No
                        // anchor: where the result sits is a Crop decision.
                        RowLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "resize"
                            spacing: 8

                            Label {
                                text: qsTr("Ratio")
                                color: view.theme.textMuted
                            }
                            ComboBox {
                                id: resizeRatioBox
                                objectName: "resizeRatio"
                                Layout.fillWidth: true
                                model: view.sizeRatios
                                textRole: "label"
                                // Set imperatively: ComboBox owns currentIndex,
                                // so a binding here would break on the first
                                // pick. `setRatio` keeps the two in step.
                                currentIndex: view.resizeRatioIndex
                                Component.onCompleted: currentIndex = view.resizeRatioIndex
                                onActivated: {
                                    view.setRatio(view.sizeRatios[currentIndex].key)
                                    view.relinkFields()
                                    draftDebounce.restart()
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "resize"
                            spacing: 2

                            Label {
                                text: qsTr("Size preset")
                                color: view.theme.textMuted
                            }
                            ComboBox {
                                id: sizePreset
                                objectName: "sizePreset"
                                Layout.fillWidth: true
                                // No preset is applied until the user picks
                                // one: an automatically selected preset would
                                // arm Apply with a size the user never chose.
                                // A matching pick is still reflected when the
                                // typed size happens to be one of these.
                                currentIndex: -1
                                model: view.sizePresets
                                textRole: "label"
                                displayText: currentIndex < 0 ? qsTr("Custom") : currentText
                                onCurrentIndexChanged: {
                                    if (currentIndex < 0 || !view.sizePresets[currentIndex])
                                        return
                                    var preset = view.sizePresets[currentIndex]
                                    widthField.text = String(preset.width)
                                    heightField.text = String(preset.height)
                                    view.setRatio(preset.ratio)
                                    draftDebounce.restart()
                                }
                            }
                        }

                        CheckBox {
                            objectName: "padSquare"
                            Layout.fillWidth: true
                            visible: view.tool === "resize"
                            text: qsTr("Pad to square")
                            checked: view.resizePadSquare
                            enabled: view.hasDocument
                            onToggled: {
                                view.resizePadSquare = checked
                                draftDebounce.restart()
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "resize" && view.resizePadSquare
                            spacing: 6

                            Rectangle {
                                objectName: "fillColorSwatch"
                                Layout.preferredWidth: 24
                                Layout.preferredHeight: 24
                                radius: 4
                                color: view.resizeFillColor
                                border.width: 1
                                border.color: view.theme.border
                            }
                            Button {
                                objectName: "fillColorButton"
                                text: qsTr("Fill color")
                                onClicked: fillColorDialog.open()
                            }
                            Label {
                                Layout.fillWidth: true
                                text: view.resizeFillColor.toString()
                                color: view.theme.textMuted
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            visible: view.tool === "resize" && view.resizePadSquare
                            text: qsTr("Pads the shorter side to the longer one.")
                            color: view.theme.textMuted
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }

                        Button {
                            objectName: "livePreviewButton"
                            Layout.fillWidth: true
                            visible: view.tool === "resize"
                            enabled: view.hasDocument
                            text: qsTr("Live preview")
                            checkable: true
                            checked: view.resizeLivePreview
                            // Checked is the state; highlighted is the visible
                            // one. A plain checked Button is too quiet on this
                            // style, and "is the preview live?" must be obvious.
                            highlighted: checked
                            ToolTip.visible: hovered
                            ToolTip.text: qsTr("Show the resized image before applying it")
                            onToggled: {
                                view.resizeLivePreview = checked
                                draftDebounce.restart()
                            }
                        }

                        // Crop: the same linked sides, but the rectangle has a
                        // place as well as a size. The preset list only offers
                        // sizes the document can hold, and the anchor pad moves
                        // the rectangle to a document corner, edge or centre.
                        RowLayout {
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            spacing: 8

                            Label {
                                text: qsTr("Ratio")
                                color: view.theme.textMuted
                            }
                            ComboBox {
                                id: cropRatioBox
                                objectName: "cropRatio"
                                Layout.fillWidth: true
                                model: view.sizeRatios
                                textRole: "label"
                                currentIndex: view.cropRatioIndex
                                Component.onCompleted: currentIndex = view.cropRatioIndex
                                onActivated: {
                                    view.setRatio(view.sizeRatios[currentIndex].key)
                                    view.relinkFields()
                                    draftDebounce.restart()
                                }
                            }
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
                                currentIndex: -1
                                model: view.cropPresets
                                textRole: "label"
                                displayText: currentIndex < 0 ? qsTr("Custom") : currentText
                                onCurrentIndexChanged: {
                                    if (currentIndex < 0 || !view.cropPresets[currentIndex])
                                        return
                                    var preset = view.cropPresets[currentIndex]
                                    widthField.text = String(preset.width)
                                    heightField.text = String(preset.height)
                                    view.setRatio(preset.ratio)
                                    view.applyCropAnchor()
                                    draftDebounce.restart()
                                }
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
                                        enabled: view.hasDocument
                                        onClicked: view.setCropAnchor(modelData.key)
                                        Accessible.name: modelData.label
                                        ToolTip.visible: hovered
                                        ToolTip.text: modelData.label
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }

                        Button {
                            objectName: "cropLivePreviewButton"
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            enabled: view.hasDocument
                            text: qsTr("Live preview")
                            checkable: true
                            checked: view.cropLivePreview
                            highlighted: checked
                            ToolTip.visible: hovered
                            ToolTip.text: qsTr("Show the cropped image before applying it")
                            onToggled: {
                                view.cropLivePreview = checked
                                draftDebounce.restart()
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Button {
                                objectName: "applyResize"
                                text: qsTr("Apply")
                                Layout.fillWidth: true
                                visible: view.tool === "resize"
                                enabled: view.hasDocument
                                         && widthField.acceptableInput
                                         && heightField.acceptableInput
                                         && parseInt(widthField.text) > 0
                                         && parseInt(heightField.text) > 0
                                onClicked: {
                                    view.command({
                                        type: "editor_resize",
                                        width: parseInt(widthField.text),
                                        height: parseInt(heightField.text),
                                        fill: view.resizePadSquare
                                              ? view.colorRgb(view.resizeFillColor)
                                              : null
                                    })
                                    widthField.text = ""
                                    heightField.text = ""
                                    sizePreset.currentIndex = -1
                                }
                            }
                            Button {
                                objectName: "applyCrop"
                                text: qsTr("Apply crop")
                                Layout.fillWidth: true
                                visible: view.tool === "crop"
                                enabled: view.cropFieldsValid()
                                onClicked: {
                                    view.command({
                                        type: "editor_crop",
                                        x: parseInt(cropX.text),
                                        y: parseInt(cropY.text),
                                        width: parseInt(widthField.text),
                                        height: parseInt(heightField.text)
                                    })
                                    widthField.text = ""
                                    heightField.text = ""
                                    cropX.text = "0"
                                    cropY.text = "0"
                                    sizePreset.currentIndex = -1
                                    cropPreset.currentIndex = -1
                                }
                            }
                            Button {
                                objectName: "resetToolFields"
                                text: qsTr("Reset")
                                enabled: view.hasDocument
                                onClicked: {
                                    widthField.text = ""
                                    heightField.text = ""
                                    cropX.text = "0"
                                    cropY.text = "0"
                                    sizePreset.currentIndex = -1
                                    cropPreset.currentIndex = -1
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            visible: view.tool === "crop"
                            text: qsTr("The anchor keeps the chosen corner, edge or centre of the document.")
                            color: view.theme.textMuted
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }
        }
    }

    ColorDialog {
        id: fillColorDialog
        objectName: "fillColorDialog"
        title: qsTr("Fill color")
        selectedColor: view.resizeFillColor
        onAccepted: {
            view.resizeFillColor = selectedColor
            draftDebounce.restart()
        }
    }
}
