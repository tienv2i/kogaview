//! Command envelope, typed commands, queries, UI text, and protocol errors.

use serde::{Deserialize, Serialize};

use crate::*;
use crate::editor_types::{default_fill_tolerance, default_one_f64};
use crate::plugins::{default_canvas_anchor, default_true};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MoveDirection {
    Up,
    Down,
}

/// A command envelope. The id is echoed back and recorded in the journal.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub id: String,
    #[serde(default = "default_protocol")]
    pub protocol: u32,
    pub command: Command,
}

fn default_protocol() -> u32 {
    PROTOCOL_VERSION
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    OpenFile {
        paths: Vec<String>,
    },
    OpenFolder {
        path: String,
    },
    Navigate {
        path: String,
    },
    Refresh,
    Select {
        paths: Vec<String>,
    },
    SetWorkspace {
        workspace: Workspace,
    },
    SetTheme {
        theme: Theme,
    },
    SetSettings {
        theme: Theme,
        remember_last_folder: bool,
        background_thumbnails: bool,
        #[serde(default)]
        language: Language,
        #[serde(default = "default_true")]
        hardware_acceleration: bool,
        #[serde(default = "default_true")]
        anti_aliasing: bool,
    },
    ToggleTheme,
    /// Set the interface language (`system`, `editor`, `en` or `vi`).
    SetLanguage {
        language: Language,
    },
    ToggleLeftPanel,
    /// Replace the persisted layout: which panels each workspace shows, the two
    /// dock widths and the Editor's split. A layout is a preference, so it is
    /// written to `config.json` immediately rather than waiting for a form.
    SetLayout {
        layout: LayoutState,
    },
    /// Show or hide the right panel of a workspace.
    ///
    /// Each workspace owns its own preference, because a narrow Viewer wants
    /// its information panel while a Browser with a wide preview does not, and
    /// hiding one must not hide the other. `workspace` names the one whose
    /// panel is toggled; an older client that omits it toggles the workspace
    /// that is open, which is what a toolbar button means.
    ToggleRightPanel {
        #[serde(default)]
        workspace: Option<Workspace>,
    },
    ToggleFilmstrip,
    NewFolder {
        parent: String,
        name: String,
    },
    CopyTo {
        paths: Vec<String>,
        destination: String,
    },
    MoveTo {
        paths: Vec<String>,
        destination: String,
    },
    Trash {
        paths: Vec<String>,
    },
    DeletePermanently {
        paths: Vec<String>,
    },
    AddFavorite {
        path: String,
    },
    RemoveFavorite {
        path: String,
    },
    MoveFavorite {
        path: String,
        direction: MoveDirection,
    },
    ViewerNext,
    ViewerPrevious,
    ViewerOpen {
        path: String,
    },
    /// Load an image into the Editor workspace. The source file is never
    /// modified; all edits live in a working document in Core.
    EditorOpen {
        path: String,
    },
    /// Write the working document over its own source file. Core refuses when
    /// the source changed on disk since it was opened, and keeps a `.bak`
    /// copy of the previous bytes. Never the default: the UI asks twice.
    EditorSave,
    /// Write the working document to another file, leaving the source alone.
    /// The extension of `path` picks the encoding (PNG, JPEG, WebP, …).
    EditorSaveAs {
        path: String,
    },
    /// Write a copy for delivery, leaving the document exactly as it is: the
    /// save target, the saved flag and the history do not move. `quality`
    /// (1–100) applies to the lossy encoders (JPEG today); `metadata` keeps the
    /// source's EXIF/XMP/ICC segments when both files are JPEG. `max_edge`, when
    /// given, scales the copy down so its longer side is at most that many
    /// pixels, aspect kept and never upscaled — the delivery size, not an edit.
    /// Exporting onto the document's own file is refused — that is what
    /// `editor_save` is for.
    EditorExport {
        path: String,
        #[serde(default)]
        quality: Option<u8>,
        #[serde(default)]
        metadata: bool,
        #[serde(default)]
        max_edge: Option<u32>,
    },
    /// Scale the working document to exactly `width` × `height`.
    ///
    /// `mode` decides what happens when the target's shape differs from the
    /// source's: `stretch` (the default) scales the whole frame and loses
    /// nothing, `cover` keeps the source's shape by discarding a centred
    /// rectangle of it, and `pad` fits the whole frame inside and fills the
    /// leftover with `fill`. An older payload that carries only `fill` keeps
    /// its pad; one that carries no `fill` used to mean `cover` and now means
    /// `stretch`, because discarding pixels is a choice the caller must make.
    /// Resize is not anchored: where the result sits is a Crop decision, not a
    /// Resize one.
    EditorResize {
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        /// Alpha for `fill`: 255 is an opaque pad, 0 the transparent one the
        /// form's background dropdown offers. Older payloads are opaque.
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        /// Absent in a payload from before the three modes existed; see
        /// [`ResizeMode::for_payload`] for what an absent value means.
        #[serde(default)]
        mode: Option<ResizeMode>,
        #[serde(default)]
        filter: ResizeFilter,
    },
    /// Render the resize in the canvas without changing the document: the
    /// pixels, the history and the save target stay as they are until
    /// `EditorResize` is applied. The draft preview is published as
    /// `editor.previewDraft`.
    EditorResizePreview {
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        #[serde(default)]
        mode: Option<ResizeMode>,
        #[serde(default)]
        filter: ResizeFilter,
    },
    /// Cut the working document to the given rectangle, in document pixels.
    ///
    /// Without a `fill` the rectangle must lie inside the picture: that is the
    /// ordinary crop, and a larger rectangle is refused. With a `fill` the
    /// canvas may **grow** — `x`/`y` go negative and the rectangle may reach
    /// past the picture's right and bottom edges — and every pixel outside the
    /// picture is painted with that RGB colour at `fill_alpha`. The rectangle
    /// must still overlap the picture, so a grow is a border around the photo
    /// and never an empty coloured page.
    EditorCrop {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        /// Alpha for `fill`: 255 is an opaque grow border, 0 the transparent
        /// one. Older payloads are opaque, and `None` never reads it.
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Render the crop in the canvas without cutting the document: the pixels,
    /// the history and the save target stay as they are until `EditorCrop` is
    /// applied. The draft is published as `editor.previewDraft` with
    /// `kind: "crop"`.
    EditorCropPreview {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Straighten the frame: the four corners of the quadrilateral inside the
    /// working document that should become the whole output. `corners` are in
    /// document pixels, clockwise in the document's own winding — top-left,
    /// top-right, bottom-right, bottom-left — and the output keeps the
    /// document's width and height. An identity quad (the document's own frame)
    /// changes nothing, so a client cannot record an empty step.
    EditorTransform {
        corners: [[f64; 2]; 4],
    },
    /// Free-transform the working document inside its existing `W × H` frame:
    /// scale the image to `width × height`, place it at `(x, y)` (clipping any
    /// overflow), and fill the uncovered canvas with `fill` / `fill_alpha`.
    EditorFreeTransform {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        rotation: f64,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Render the transform in the canvas without reshaping the document: the
    /// pixels, the history and the save target stay as they are until
    /// `EditorTransform` is applied. The draft is published as
    /// `editor.previewDraft` with `kind: "transform"`.
    EditorTransformPreview {
        corners: [[f64; 2]; 4],
    },
    /// Grow or shrink the canvas without scaling the image pixels.
    /// `anchor` is one of the 9 positions (`top_left`, `top`, `top_right`,
    /// `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`);
    /// uncovered pixels are painted with `fill` / `fill_alpha`.
    EditorCanvasSize {
        width: u32,
        height: u32,
        #[serde(default = "default_canvas_anchor")]
        anchor: String,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Rotate the working document clockwise by an arbitrary angle in degrees.
    /// The canvas expands to hold the rotated bounding box and uncovered
    /// corners are filled with `fill` / `fill_alpha`.
    EditorRotateAngle {
        degrees: f64,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Adjust brightness, contrast and saturation of the working document.
    /// Values are normalized in `-1.0..=1.0` (`0.0` = unchanged).
    EditorAdjustColor {
        #[serde(default)]
        brightness: f64,
        #[serde(default)]
        contrast: f64,
        #[serde(default)]
        saturation: f64,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Apply per-channel tonal curves (Krita/Photoshop-style RGB / R / G / B)
    /// defined by normalized control points `[x, y]` in `0.0..=1.0`.
    EditorAdjustCurves {
        #[serde(default)]
        rgb: Vec<[f64; 2]>,
        #[serde(default)]
        red: Vec<[f64; 2]>,
        #[serde(default)]
        green: Vec<[f64; 2]>,
        #[serde(default)]
        blue: Vec<[f64; 2]>,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Krita-style HSV adjustment (`hue` in `-180..=180` degrees, `saturation` and `value` in `-1.0..=1.0`).
    EditorAdjustHsv {
        #[serde(default)]
        hue: f64,
        #[serde(default)]
        saturation: f64,
        #[serde(default)]
        value: f64,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Krita/Photoshop-style Color Balance across Shadows, Midtones, and Highlights
    /// (`[cyan_red, magenta_green, yellow_blue]` each in `-1.0..=1.0`).
    EditorColorBalance {
        #[serde(default)]
        shadows: [f64; 3],
        #[serde(default)]
        midtones: [f64; 3],
        #[serde(default)]
        highlights: [f64; 3],
        #[serde(default = "default_preserve_luminosity")]
        preserve_luminosity: bool,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Update or clear the in-RAM live preview for a non-committed filter dialog
    /// (HSV, Curves, Color Balance, or Color & light). Never mutates document or Undo history.
    EditorPreviewFilter {
        #[serde(default)]
        clear: bool,
        #[serde(default)]
        kind: String,
        #[serde(default)]
        brightness: f64,
        #[serde(default)]
        contrast: f64,
        #[serde(default)]
        hue: f64,
        #[serde(default)]
        saturation: f64,
        #[serde(default)]
        value: f64,
        #[serde(default)]
        shadows: [f64; 3],
        #[serde(default)]
        midtones: [f64; 3],
        #[serde(default)]
        highlights: [f64; 3],
        #[serde(default = "default_preserve_luminosity")]
        preserve_luminosity: bool,
        #[serde(default)]
        rgb: Vec<[f64; 2]>,
        #[serde(default)]
        red: Vec<[f64; 2]>,
        #[serde(default)]
        green: Vec<[f64; 2]>,
        #[serde(default)]
        blue: Vec<[f64; 2]>,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Rotate the working document clockwise; degrees must be 90, 180 or 270
    /// (negative values rotate counter-clockwise).
    EditorRotate {
        degrees: i32,
        #[serde(default)]
        target: ApplyTarget,
    },
    EditorFlip {
        axis: FlipAxis,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Paint one freehand stroke onto the working document. `points` are in
    /// document pixels in drawing order; the whole list is one history step, so
    /// one undo removes the stroke. `radius` is half the brush's width in
    /// document pixels, `opacity` is 0–1 and `erase` clears alpha instead of
    /// blending `color`. A single point paints a dot.
    EditorPaintStroke {
        points: Vec<[f64; 2]>,
        color: [u8; 3],
        radius: f64,
        opacity: f64,
        #[serde(default)]
        erase: bool,
        #[serde(flatten, default)]
        brush: BrushSettings,
    },
    /// Rasterize a geometric shape or path (line, rectangle, ellipse, polygon,
    /// polyline, or tessellated Bezier curve) onto the active layer, clipped by
    /// the active selection mask if present.
    EditorDrawShape {
        kind: DrawShapeKind,
        points: Vec<[f64; 2]>,
        #[serde(default)]
        closed: bool,
        #[serde(default)]
        stroke_color: Option<[u8; 3]>,
        #[serde(default)]
        stroke_width: f64,
        #[serde(default = "default_one_f64")]
        stroke_opacity: f64,
        #[serde(default)]
        fill_color: Option<[u8; 3]>,
        #[serde(default = "default_one_f64")]
        fill_opacity: f64,
    },
    /// Krita-style Paint Bucket flood fill starting at `(x, y)` in document pixels.
    EditorFloodFill {
        x: i32,
        y: i32,
        color: [u8; 3],
        #[serde(default = "default_one_f64")]
        opacity: f64,
        #[serde(default = "default_fill_tolerance")]
        tolerance: u8,
        #[serde(default)]
        grow: u32,
        #[serde(default = "default_true")]
        contiguous: bool,
        #[serde(default)]
        sample_all_layers: bool,
    },
    /// Krita-style Gradient fill between `start` and `end` in document pixels.
    EditorGradient {
        start: [f64; 2],
        end: [f64; 2],
        start_color: [u8; 3],
        #[serde(default = "default_one_f64")]
        start_alpha: f64,
        end_color: [u8; 3],
        #[serde(default = "default_one_f64")]
        end_alpha: f64,
        #[serde(default)]
        stops: Vec<GradientStop>,
        #[serde(default = "default_one_f64")]
        opacity: f64,
        #[serde(default)]
        shape: GradientShape,
        #[serde(default)]
        repeat: GradientRepeat,
        #[serde(default)]
        reverse: bool,
        #[serde(default = "default_true")]
        dither: bool,
        #[serde(default)]
        blend_mode: String,
    },
    EditorUndo,
    EditorRedo,
    /// Discard every edit and return the working document to the source image.
    EditorReset,
    /// Drop the working document. The source file is untouched.
    EditorClose,
    /// Run one operation over a list of images on a worker thread.
    ///
    /// The job is bounded (`MAX_BATCH_FILES`), cancellable
    /// (`cancel_operation`) and observable: Core publishes a `batch` slot with
    /// the count and the file being written. The sources are never modified
    /// unless `output.overwrite` says so.
    BatchRun {
        operation: BatchOperation,
        source: BatchSource,
        #[serde(default)]
        output: BatchOutput,
    },
    /// Rescan `$XDG_DATA_HOME/kogaview[-dev]/plugins/` manifests and model files.
    AiRefreshPlugins,
    /// Persist AI execution device (`cpu` / `auto` / `gpu`) and idle auto-unload.
    AiSetSettings {
        device: AiDevice,
        #[serde(default = "default_ai_auto_unload_secs")]
        auto_unload_secs: u32,
    },
    /// Download a catalog AI model on demand into `$XDG_DATA_HOME/.../models/`.
    AiDownloadModel {
        model_id: String,
    },
    /// Remove a previously downloaded AI model file to reclaim disk space.
    AiDeleteModel {
        model_id: String,
    },
    /// Point a model slot at a user-provided local `.onnx` file (empty clears override).
    AiSetCustomModel {
        model_id: String,
        path: String,
    },
    /// Cancel an active AI model download or inference worker task.
    AiCancel,
    /// Run the Remove Background AI plugin on the open Editor document and push
    /// the transparent RGBA result as a single undoable `EditOperation`.
    EditorAiRemoveBackground {
        #[serde(default = "default_rembg_model_id")]
        model_id: String,
        #[serde(default)]
        feather: u8,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Run a plugin-contributed Quick Action from Browser or Viewer context menus.
    /// Non-destructive: writes a new sibling output file rather than overwriting the source.
    QuickActionRun {
        plugin_id: String,
        action_id: String,
        paths: Vec<String>,
    },
    /// Translate an entire image or a cropped `[x, y, w, h]` region in Viewer
    /// via the `viewer.translate` plugin (OCR + Google Translate).
    ViewerTranslate {
        path: String,
        #[serde(default = "default_translate_source")]
        source_lang: String,
        #[serde(default = "default_translate_target")]
        target_lang: String,
        /// Optional `[x, y, width, height]` in document pixels.
        #[serde(default)]
        region: Option<[i32; 4]>,
        /// OCR engine: `"tesseract"` (default), `"manga_ocr"`, or `"rapidocr"`.
        #[serde(default)]
        ocr_engine: String,
    },
    /// Persist Viewer translation bubbles to `<dir>/.kogaview/translation/<file>.json`.
    ViewerSaveTranslation {
        path: String,
        #[serde(default)]
        blocks: Vec<TranslationBlock>,
    },
    /// Delete the persisted `<dir>/.kogaview/translation/<file>.json` sidecar file.
    ViewerDeleteTranslation {
        path: String,
    },
    /// Remove the Gemini/Imagen corner logo from the open Editor document via
    /// Reverse Alpha Blending (`kogaview-plugin-dewatermark`).
    EditorDewatermarkGemini {
        #[serde(default = "default_wm_size")]
        size: String,
        #[serde(default = "default_wm_logo_value")]
        logo_value: f32,
        #[serde(default)]
        force: bool,
        #[serde(default)]
        offset_x: i32,
        #[serde(default)]
        offset_y: i32,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Remove an arbitrary rectangular watermark region from the open Editor
    /// document via harmonic diffusion inpainting (`kogaview-plugin-dewatermark`).
    EditorInpaintRegion {
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        #[serde(default = "default_inpaint_feather")]
        feather: u32,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Detect & remove watermarks from the open Editor document using selectable
    /// YOLO detector + MI-GAN / LaMa ONNX inpainter (`kogaview-plugin-ai-inpaint`).
    EditorAiInpaint {
        #[serde(default = "default_ai_detector")]
        detector_model: String,
        #[serde(default = "default_ai_inpainter")]
        inpainter_model: String,
        #[serde(default = "default_ai_confidence")]
        confidence: f32,
        #[serde(default = "default_ai_mask_padding")]
        mask_padding: u32,
        #[serde(default)]
        region_x: i32,
        #[serde(default)]
        region_y: i32,
        #[serde(default)]
        region_width: i32,
        #[serde(default)]
        region_height: i32,
        #[serde(default)]
        brush_strokes: Vec<AiMaskStroke>,
        #[serde(default)]
        target: ApplyTarget,
    },
    /// Refine transparency mask on the open Editor document using freehand
    /// Erase (alpha -> 0) and/or Restore (copy from original) brush strokes.
    EditorRefineAlpha {
        #[serde(default)]
        erase_strokes: Vec<AiMaskStroke>,
        #[serde(default)]
        restore_strokes: Vec<AiMaskStroke>,
        #[serde(default = "default_refine_softness")]
        softness: f32,
    },
    /// Generate AI tags/caption for the open Editor document with custom parameters
    /// (`kogaview-plugin-caption`).
    EditorGenerateCaption {
        #[serde(default = "default_caption_model")]
        model_id: String,
        #[serde(default = "default_caption_gen_thresh")]
        general_threshold: f32,
        #[serde(default = "default_caption_char_thresh")]
        character_threshold: f32,
        #[serde(default = "default_true")]
        replace_underscores: bool,
        #[serde(default)]
        prefix: String,
        #[serde(default)]
        suffix: String,
        #[serde(default)]
        exclude_tags: String,
    },
    /// Save or delete the `<stem>.txt` caption file beside the open Editor image.
    EditorSaveCaption {
        text: String,
    },
    /// Jump directly to `target_index` in the Editor's Undo/Redo history stack
    /// (`0` = before all edits, `k` = after step `k`).
    EditorHistoryJump {
        target_index: usize,
    },
    /// Add an empty transparent raster layer above the active layer.
    EditorLayerAdd {
        #[serde(default)]
        name: String,
    },
    /// Duplicate a layer (`id`) above itself.
    EditorLayerDuplicate {
        id: u64,
    },
    /// Delete a layer (`id`), refusing the last remaining or locked layer.
    EditorLayerDelete {
        id: u64,
    },
    /// Select the active layer (`id`).
    EditorLayerSelect {
        id: u64,
    },
    /// Reorder a layer (`id`) to `new_index` (0 = bottom, len-1 = top).
    EditorLayerReorder {
        id: u64,
        new_index: usize,
    },
    /// Update properties of a layer (`name`, `visible`, `locked`, `opacity`,
    /// `blend_mode`, `offset_x`, `offset_y`).
    EditorLayerSetProps {
        id: u64,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        visible: Option<bool>,
        #[serde(default)]
        locked: Option<bool>,
        #[serde(default)]
        opacity: Option<f32>,
        #[serde(default)]
        blend_mode: Option<String>,
        #[serde(default)]
        offset_x: Option<i32>,
        #[serde(default)]
        offset_y: Option<i32>,
    },
    /// Merge a layer (`id`) down onto the layer directly underneath it.
    EditorLayerMergeDown {
        id: u64,
    },
    /// Flatten all visible layers into a single Background layer.
    EditorLayerFlatten,
    /// Attach a non-destructive transparency mask to layer `id`.
    EditorLayerMaskAdd {
        id: u64,
        #[serde(default = "default_true")]
        reveal_all: bool,
        #[serde(default)]
        from_selection: bool,
    },
    /// Remove the transparency mask from layer `id`.
    EditorLayerMaskDelete {
        id: u64,
    },
    /// Bake the transparency mask permanently into layer `id`'s alpha channel.
    EditorLayerMaskApply {
        id: u64,
    },
    /// Invert layer `id`'s transparency mask (`v -> 255 - v`).
    EditorLayerMaskInvert {
        id: u64,
    },
    /// Enable or temporarily bypass layer `id`'s transparency mask.
    EditorLayerMaskSetEnabled {
        id: u64,
        enabled: bool,
    },
    /// Switch paint/shape editing target between layer `id`'s pixels and its mask.
    EditorLayerMaskSetEditing {
        id: u64,
        editing: bool,
    },
    /// Link or unlink layer `id`'s pixels and its transparency mask during moves.
    EditorLayerMaskSetLinked {
        id: u64,
        linked: bool,
    },
    /// Add a non-destructive Adjustment Layer above the active layer.
    EditorLayerAddAdjustment {
        #[serde(default)]
        name: String,
        adjustment: LayerAdjustment,
    },
    /// Update the live parameters of an existing Adjustment Layer.
    EditorLayerUpdateAdjustment {
        id: u64,
        adjustment: LayerAdjustment,
    },
    /// Set the document-wide canvas background underneath all layers
    /// (`transparent: true` = checkerboard/alpha, `false` = solid RGB color).
    EditorSetCanvasBackground {
        #[serde(default)]
        color: Option<[u8; 3]>,
        #[serde(default)]
        transparent: bool,
    },
    /// Create a brand-new blank Editor canvas in memory (not written until Save).
    EditorNew {
        width: u32,
        height: u32,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
        #[serde(default)]
        name: String,
    },
    /// Paste an image file (e.g. from the system clipboard) as a new centered
    /// layer in the open Editor document, or open it as a new document when
    /// the Editor is empty.
    EditorPasteImage {
        path: String,
        #[serde(default)]
        name: String,
        #[serde(default)]
        mode: PasteMode,
    },
    /// Create or combine a rectangular selection mask.
    EditorSelectRect {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        mode: SelectionMode,
        #[serde(default)]
        feather: u32,
    },
    /// Create or combine an elliptical selection mask.
    EditorSelectEllipse {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        mode: SelectionMode,
        #[serde(default)]
        feather: u32,
    },
    /// Create or combine a freehand polygon (lasso) selection mask.
    EditorSelectLasso {
        points: Vec<[f64; 2]>,
        #[serde(default)]
        mode: SelectionMode,
        #[serde(default)]
        feather: u32,
    },
    /// Flood-fill or color-match selection starting at `(x, y)` in document pixels.
    EditorSelectMagicWand {
        x: i32,
        y: i32,
        #[serde(default = "default_wand_tolerance")]
        tolerance: u8,
        #[serde(default = "default_true")]
        contiguous: bool,
        #[serde(default = "default_true")]
        sample_all_layers: bool,
        #[serde(default)]
        mode: SelectionMode,
        #[serde(default)]
        feather: u32,
    },
    /// Select the entire canvas.
    EditorSelectAll,
    /// Clear the active selection.
    EditorSelectClear,
    /// Invert the active selection mask.
    EditorSelectInvert,
    /// Modify the active selection mask (Grow, Shrink, Border, Feather, Smooth).
    EditorSelectModify {
        op: SelectionModifyOp,
        amount: u32,
    },
    /// Translate the active selection mask by `(dx, dy)` document pixels without moving image pixels.
    EditorSelectMove {
        dx: i32,
        dy: i32,
    },
    /// Erase (make transparent) pixels inside the active selection on the active layer.
    EditorSelectionDelete,
    /// Fill the active selection on the active layer with `color` at `opacity` (`0..=1`).
    EditorSelectionFill {
        color: [u8; 3],
        #[serde(default = "default_full_opacity")]
        opacity: f32,
    },
    /// Stroke the boundary of the active selection on the active layer.
    EditorSelectionStroke {
        color: [u8; 3],
        width: u32,
        #[serde(default)]
        position: StrokePosition,
        #[serde(default = "default_full_opacity")]
        opacity: f32,
    },
    /// Liquify / warp pixels along a brush stroke on the active layer.
    EditorLiquifyStroke {
        points: Vec<[f64; 2]>,
        #[serde(default)]
        mode: LiquifyMode,
        radius: f32,
        #[serde(default = "default_liquify_strength")]
        strength: f32,
    },
    /// Begin an interactive live stroke session (Brush/Eraser/Liquify) that
    /// updates the RAM canvas in real time while dragging and commits as one Undo step.
    EditorLiveStrokeBegin {
        #[serde(flatten)]
        stroke: LiveStrokeKind,
        x: f64,
        y: f64,
    },
    /// Append incremental pointer samples to the active live stroke session.
    EditorLiveStrokeStep {
        points: Vec<[f64; 2]>,
    },
    /// Commit (`commit: true`) or cancel (`commit: false`) the active live stroke session.
    EditorLiveStrokeEnd {
        #[serde(default = "default_true")]
        commit: bool,
    },
    /// Duplicate pixels inside the active selection onto a new layer above the active layer (`Ctrl+J`).
    EditorSelectionDuplicateLayer,
    /// Export pixels inside the active selection (or the active layer when no
    /// selection is active) to a temporary PNG for system clipboard copy (`Ctrl+C`).
    /// When `cut` is true (`Ctrl+X`), also erase the selected pixels on the active layer.
    EditorSelectionCopy {
        #[serde(default)]
        cut: bool,
    },
    /// Crop the canvas to the active selection's tight bounding box.
    EditorSelectionCrop,
    /// Restore embedded factory-default configuration (backing up existing
    /// `config.json` to `config.json.bak` first).
    ResetConfig {
        #[serde(default = "default_true")]
        reset_layout: bool,
        #[serde(default = "default_true")]
        reset_settings: bool,
        #[serde(default)]
        reset_favorites: bool,
    },
    CancelOperation,
}

/// One freehand brush stroke in document pixel coordinates for AI inpainting masks.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AiMaskStroke {
    pub radius: f32,
    pub points: Vec<[f32; 2]>,
}

fn default_wm_size() -> String {
    "auto".to_owned()
}
fn default_wm_logo_value() -> f32 {
    255.0
}
fn default_ai_detector() -> String {
    "watermark-yolo26".to_owned()
}
fn default_ai_inpainter() -> String {
    "migan-pipeline-v2".to_owned()
}
fn default_ai_confidence() -> f32 {
    0.35
}
fn default_ai_mask_padding() -> u32 {
    8
}
fn default_refine_softness() -> f32 {
    0.30
}
fn default_inpaint_feather() -> u32 {
    4
}
fn default_caption_model() -> String {
    "wd-vit-tagger-v3".to_owned()
}
fn default_caption_gen_thresh() -> f32 {
    0.35
}
fn default_caption_char_thresh() -> f32 {
    0.85
}

fn default_translate_source() -> String {
    "eng".to_owned()
}

fn default_translate_target() -> String {
    "vi".to_owned()
}

fn default_ai_auto_unload_secs() -> u32 {
    60
}

fn default_rembg_model_id() -> String {
    "rmbg-1.4".to_owned()
}

fn default_wand_tolerance() -> u8 {
    32
}

impl Command {
    /// Stable command name used by the journal and logs.
    pub fn name(&self) -> &'static str {
        match self {
            Self::OpenFile { .. } => "open_file",
            Self::OpenFolder { .. } => "open_folder",
            Self::Navigate { .. } => "navigate",
            Self::Refresh => "refresh",
            Self::Select { .. } => "select",
            Self::SetWorkspace { .. } => "set_workspace",
            Self::SetTheme { .. } => "set_theme",
            Self::SetSettings { .. } => "set_settings",
            Self::ToggleTheme => "toggle_theme",
            Self::SetLanguage { .. } => "set_language",
            Self::ToggleLeftPanel => "toggle_left_panel",
            Self::SetLayout { .. } => "set_layout",
            Self::ToggleRightPanel { .. } => "toggle_right_panel",
            Self::ToggleFilmstrip => "toggle_filmstrip",
            Self::NewFolder { .. } => "new_folder",
            Self::CopyTo { .. } => "copy_to",
            Self::MoveTo { .. } => "move_to",
            Self::Trash { .. } => "trash",
            Self::DeletePermanently { .. } => "delete_permanently",
            Self::AddFavorite { .. } => "add_favorite",
            Self::RemoveFavorite { .. } => "remove_favorite",
            Self::MoveFavorite { .. } => "move_favorite",
            Self::ViewerNext => "viewer_next",
            Self::ViewerPrevious => "viewer_previous",
            Self::ViewerOpen { .. } => "viewer_open",
            Self::CancelOperation => "cancel_operation",
            Self::EditorOpen { .. } => "editor_open",
            Self::EditorSave => "editor_save",
            Self::EditorSaveAs { .. } => "editor_save_as",
            Self::EditorExport { .. } => "editor_export",
            Self::EditorResize { .. } => "editor_resize",
            Self::EditorResizePreview { .. } => "editor_resize_preview",
            Self::EditorCrop { .. } => "editor_crop",
            Self::EditorCropPreview { .. } => "editor_crop_preview",
            Self::EditorTransform { .. } => "editor_transform",
            Self::EditorFreeTransform { .. } => "editor_free_transform",
            Self::EditorTransformPreview { .. } => "editor_transform_preview",
            Self::EditorCanvasSize { .. } => "editor_canvas_size",
            Self::EditorRotateAngle { .. } => "editor_rotate_angle",
            Self::EditorAdjustColor { .. } => "editor_adjust_color",
            Self::EditorAdjustCurves { .. } => "editor_adjust_curves",
            Self::EditorAdjustHsv { .. } => "editor_adjust_hsv",
            Self::EditorColorBalance { .. } => "editor_color_balance",
            Self::EditorPreviewFilter { .. } => "editor_preview_filter",
            Self::EditorRotate { .. } => "editor_rotate",
            Self::EditorFlip { .. } => "editor_flip",
            Self::EditorPaintStroke { .. } => "editor_paint_stroke",
            Self::EditorDrawShape { .. } => "editor_draw_shape",
            Self::EditorFloodFill { .. } => "editor_flood_fill",
            Self::EditorGradient { .. } => "editor_gradient",
            Self::EditorUndo => "editor_undo",
            Self::EditorRedo => "editor_redo",
            Self::EditorReset => "editor_reset",
            Self::EditorClose => "editor_close",
            Self::BatchRun { .. } => "batch_run",
            Self::AiRefreshPlugins => "ai_refresh_plugins",
            Self::AiSetSettings { .. } => "ai_set_settings",
            Self::AiDownloadModel { .. } => "ai_download_model",
            Self::AiDeleteModel { .. } => "ai_delete_model",
            Self::AiSetCustomModel { .. } => "ai_set_custom_model",
            Self::AiCancel => "ai_cancel",
            Self::EditorAiRemoveBackground { .. } => "editor_ai_remove_background",
            Self::QuickActionRun { .. } => "quick_action_run",
            Self::ViewerTranslate { .. } => "viewer_translate",
            Self::ViewerSaveTranslation { .. } => "viewer_save_translation",
            Self::ViewerDeleteTranslation { .. } => "viewer_delete_translation",
            Self::EditorDewatermarkGemini { .. } => "editor_dewatermark_gemini",
            Self::EditorInpaintRegion { .. } => "editor_inpaint_region",
            Self::EditorAiInpaint { .. } => "editor_ai_inpaint",
            Self::EditorRefineAlpha { .. } => "editor_refine_alpha",
            Self::EditorGenerateCaption { .. } => "editor_generate_caption",
            Self::EditorSaveCaption { .. } => "editor_save_caption",
            Self::EditorHistoryJump { .. } => "editor_history_jump",
            Self::EditorLayerAdd { .. } => "editor_layer_add",
            Self::EditorLayerDuplicate { .. } => "editor_layer_duplicate",
            Self::EditorLayerDelete { .. } => "editor_layer_delete",
            Self::EditorLayerSelect { .. } => "editor_layer_select",
            Self::EditorLayerReorder { .. } => "editor_layer_reorder",
            Self::EditorLayerSetProps { .. } => "editor_layer_set_props",
            Self::EditorLayerMergeDown { .. } => "editor_layer_merge_down",
            Self::EditorLayerFlatten => "editor_layer_flatten",
            Self::EditorLayerMaskAdd { .. } => "editor_layer_mask_add",
            Self::EditorLayerMaskDelete { .. } => "editor_layer_mask_delete",
            Self::EditorLayerMaskApply { .. } => "editor_layer_mask_apply",
            Self::EditorLayerMaskInvert { .. } => "editor_layer_mask_invert",
            Self::EditorLayerMaskSetEnabled { .. } => "editor_layer_mask_set_enabled",
            Self::EditorLayerMaskSetEditing { .. } => "editor_layer_mask_set_editing",
            Self::EditorLayerMaskSetLinked { .. } => "editor_layer_mask_set_linked",
            Self::EditorLayerAddAdjustment { .. } => "editor_layer_add_adjustment",
            Self::EditorLayerUpdateAdjustment { .. } => "editor_layer_update_adjustment",
            Self::EditorSetCanvasBackground { .. } => "editor_set_canvas_background",
            Self::EditorNew { .. } => "editor_new",
            Self::EditorPasteImage { .. } => "editor_paste_image",
            Self::EditorSelectRect { .. } => "editor_select_rect",
            Self::EditorSelectEllipse { .. } => "editor_select_ellipse",
            Self::EditorSelectLasso { .. } => "editor_select_lasso",
            Self::EditorSelectMagicWand { .. } => "editor_select_magic_wand",
            Self::EditorSelectAll => "editor_select_all",
            Self::EditorSelectClear => "editor_select_clear",
            Self::EditorSelectInvert => "editor_select_invert",
            Self::EditorSelectModify { .. } => "editor_select_modify",
            Self::EditorSelectMove { .. } => "editor_select_move",
            Self::EditorSelectionDelete => "editor_selection_delete",
            Self::EditorSelectionFill { .. } => "editor_selection_fill",
            Self::EditorSelectionStroke { .. } => "editor_selection_stroke",
            Self::EditorLiquifyStroke { .. } => "editor_liquify_stroke",
            Self::EditorLiveStrokeBegin { .. } => "editor_live_stroke_begin",
            Self::EditorLiveStrokeStep { .. } => "editor_live_stroke_step",
            Self::EditorLiveStrokeEnd { .. } => "editor_live_stroke_end",
            Self::EditorSelectionDuplicateLayer => "editor_selection_duplicate_layer",
            Self::EditorSelectionCopy { .. } => "editor_selection_copy",
            Self::EditorSelectionCrop => "editor_selection_crop",
            Self::ResetConfig { .. } => "reset_config",
        }
    }
}

/// Read-only query surface. Queries never mutate state.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Query {
    ListFolders { path: String },
    State,
}

/// A line meant for the interface, with its wording kept out of Core.
///
/// Core knows *what* happened — a folder loaded, a resize was applied, a
/// destination was rejected — and the interface knows *how to say it* in the
/// current language. Publishing a `code` plus positional `args` instead of a
/// formatted English sentence is what lets the QML translate at the edge, where
/// the active translator lives. The codes are part of the published contract:
/// `crates/desktop/qml/UiLines.qml` is the one place that maps them to
/// sentences, and an unknown code falls back to joining its arguments so a
/// newer Core cannot blank the status bar.
///
/// It lives in the protocol crate rather than Core because a command *result*
/// carries one too — both the success line and the error line travel over the
/// same wire shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiText {
    pub code: String,
    pub args: Vec<String>,
}

impl UiText {
    /// A line with no arguments.
    pub fn new(code: &str) -> Self {
        Self {
            code: code.to_owned(),
            args: Vec::new(),
        }
    }

    /// A line whose sentence is completed by the given positional arguments.
    pub fn with(code: &str, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            code: code.to_owned(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }

    /// The empty line, used to hide the status bar's message.
    pub fn empty() -> Self {
        Self::new("")
    }

    pub fn is_empty(&self) -> bool {
        self.code.is_empty()
    }

    /// The English rendering used by the command journal, the structured log
    /// and any front end that has no translator: the code with its underscores
    /// opened up, followed by the arguments.
    ///
    /// It is deliberately mechanical rather than a second table of sentences:
    /// the interface's wording lives in the QML (one `qsTr` per code), and a
    /// paraphrase here would be a translation nobody maintains. A reader of
    /// `journal/commands.jsonl` has the command name next to it, so
    /// `editor_export` + `exporting pic-export.jpg` reads unambiguously.
    pub fn english(&self) -> String {
        if self.code.is_empty() {
            return String::new();
        }
        let mut text = self.code.replace('_', " ");
        for argument in &self.args {
            text.push(' ');
            text.push_str(argument);
        }
        text
    }
}

/// A rejected command.
///
/// `code` and `message` are contract: the code is the stable machine name a
/// client branches on, the message is the English sentence the journal and the
/// structured log record. `ui` is the same rejection as a translatable line, so
/// the window can say it in its own language instead of printing English in a
/// Vietnamese interface. It is `None` where the detail *is* the platform's text
/// (an OS error, a filesystem path) — there is nothing to translate there, and
/// inventing a sentence would hide the real cause.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ui: Option<UiText>,
}

impl ProtocolError {
    /// A rejection whose detail is not translatable: an OS error, an invalid
    /// envelope, a path the filesystem named.
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            ui: None,
        }
    }

    /// A rejection the interface words itself, with an explicit English
    /// message for the journal (the sentence a reader of the log wants, which
    /// is not always the mechanical rendering of the line).
    pub fn with_line(code: impl Into<String>, message: impl Into<String>, line: UiText) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            ui: Some(line),
        }
    }

    /// A rejection the interface words itself, where those words are also the
    /// journal's: the message is the line's English rendering.
    pub fn line(code: impl Into<String>, line: UiText) -> Self {
        let code = code.into();
        let message = line.english();
        Self {
            code,
            message,
            ui: Some(line),
        }
    }
}

