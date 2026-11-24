//! What one edit is, and the line History shows for it.

use std::sync::Arc;

use image::RgbaImage;
use kogaview_protocol::{
    BrushSettings, DrawShapeKind, FlipAxis, GradientRepeat, GradientShape, GradientStop,
    ResizeFilter, ResizeMode, UiText,
};
use serde::Serialize;

use crate::layer::LayerOperation;

/// One edit, described so it can be serialized into a session file later.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum EditOperation {
    /// Clockwise rotation; negative values rotate counter-clockwise.
    Rotate {
        degrees: i32,
    },
    Flip {
        axis: FlipAxis,
    },
    Crop {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        /// When present the canvas may grow: pixels outside the picture are
        /// painted with this RGB colour at `fill_alpha`. Without it the
        /// rectangle must lie inside the picture.
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
    },
    Resize {
        width: u32,
        height: u32,
        /// When present, scale the whole source to fit inside the target and
        /// fill the leftover with this RGB colour. Only `mode: Pad` reads it.
        fill: Option<[u8; 3]>,
        /// The alpha of that fill: 0 leaves the leftover transparent, 255 is
        /// the opaque pads the form offers.
        fill_alpha: u8,
        /// What happens to the source's shape: stretch it to the target (lose
        /// nothing), cover the target by cropping (lose the edges) or fit it
        /// inside with a pad (lose neither, gain a border).
        mode: ResizeMode,
        filter: ResizeFilter,
    },
    /// A perspective correction: `corners` are the four points of the
    /// quadrilateral, in document pixels and clockwise from the top-left
    /// (TL, TR, BR, BL) that become the whole output frame. The output keeps
    /// the document's width and height, so straightening a keystone keeps the
    /// frame the picture already had and only reshapes what is inside it.
    Transform {
        corners: [[f64; 2]; 4],
    },
    /// Free-transform inside the existing document frame: resample the image to
    /// `width × height`, place it at `(x, y)` (clipping anything outside the
    /// frame), and fill the uncovered canvas with `fill` / `fill_alpha`.
    FreeTransform {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        rotation: f64,
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
    },
    /// Grow or shrink the canvas without scaling the image pixels, anchored at
    /// one of the 9 positions (`top_left`..`bottom_right`), filling uncovered
    /// pixels with `fill` / `fill_alpha`.
    CanvasSize {
        width: u32,
        height: u32,
        anchor: String,
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
    },
    /// Rotate by an arbitrary angle (clockwise, in degrees), expanding the
    /// canvas to fit the rotated bounding box and filling uncovered corners.
    RotateAngle {
        degrees: f64,
        fill: Option<[u8; 3]>,
        fill_alpha: u8,
    },
    /// Adjust light and colour (`brightness`, `contrast`, `saturation` in `-1.0..=1.0`).
    AdjustColor {
        brightness: f64,
        contrast: f64,
        saturation: f64,
    },
    /// Adjust per-channel tonal curves (RGB / R / G / B control points in `0.0..=1.0`).
    AdjustCurves {
        rgb: Vec<[f64; 2]>,
        red: Vec<[f64; 2]>,
        green: Vec<[f64; 2]>,
        blue: Vec<[f64; 2]>,
    },
    /// Krita-style HSV adjustment (`hue` in `-180..=180`, `saturation` & `value` in `-1.0..=1.0`).
    AdjustHsv {
        hue: f64,
        saturation: f64,
        value: f64,
    },
    /// Krita/Photoshop-style Color Balance across Shadows, Midtones, Highlights.
    ColorBalance {
        shadows: [f64; 3],
        midtones: [f64; 3],
        highlights: [f64; 3],
        preserve_luminosity: bool,
    },
    /// One freehand stroke. `points` are in document pixels in drawing order,
    /// `radius` is half the brush width, `opacity` is 0–1 and `erase` lowers
    /// the destination alpha instead of blending `color` over it. The stroke is
    /// painted as one history step, so one undo removes it whole.
    Paint {
        points: Vec<[f64; 2]>,
        color: [u8; 3],
        radius: f64,
        opacity: f64,
        erase: bool,
        #[serde(default)]
        brush: BrushSettings,
    },
    /// Geometric shape or path (line, rectangle, ellipse, polygon, polyline,
    /// or Bezier curve) rasterized onto the active layer as one history step.
    DrawShape {
        kind: DrawShapeKind,
        points: Vec<[f64; 2]>,
        closed: bool,
        stroke_color: Option<[u8; 3]>,
        stroke_width: f64,
        stroke_opacity: f64,
        fill_color: Option<[u8; 3]>,
        fill_opacity: f64,
    },
    /// Krita-style flood fill (Paint Bucket) onto the active layer or its mask.
    FloodFill {
        x: i32,
        y: i32,
        color: [u8; 3],
        opacity: f64,
        tolerance: u8,
        grow: u32,
        contiguous: bool,
        sample_all_layers: bool,
    },
    /// Krita-style gradient fill onto the active layer or its mask.
    Gradient {
        start: [f64; 2],
        end: [f64; 2],
        start_color: [u8; 3],
        start_alpha: f64,
        end_color: [u8; 3],
        end_alpha: f64,
        #[serde(default)]
        stops: Vec<GradientStop>,
        opacity: f64,
        shape: GradientShape,
        repeat: GradientRepeat,
        reverse: bool,
        #[serde(default)]
        dither: bool,
        #[serde(default)]
        blend_mode: String,
    },
    /// Non-destructive pixel output produced by an out-of-process AI plugin
    /// (e.g. Remove Background, Upscale). Stored as an `Arc<RgbaImage>` so
    /// Undo and Redo are instant without re-running model inference.
    AiResult {
        label: UiText,
        #[serde(skip)]
        pixels: Arc<RgbaImage>,
    },
    /// Structural or property change to the document's layer stack.
    Layer(LayerOperation),
}

impl EditOperation {
    /// The label the History panel shows: a stable code plus the numbers the
    /// sentence mentions, never an English string. Kept next to the operation
    /// so a new operation cannot be added without deciding how it is named;
    /// `crates/desktop/qml/UiLines.qml` owns the wording.
    pub fn label(&self) -> UiText {
        match self {
            Self::Rotate { degrees } => match degrees.rem_euclid(360) {
                90 => UiText::new("rotate_right"),
                180 => UiText::new("rotate_half"),
                270 => UiText::new("rotate_left"),
                other => UiText::with("rotate_degrees", [other.to_string()]),
            },
            Self::Flip { axis } => match axis {
                FlipAxis::Horizontal => UiText::new("flip_horizontal"),
                FlipAxis::Vertical => UiText::new("flip_vertical"),
            },
            Self::Crop {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            } => match fill {
                Some([_, _, _]) if *fill_alpha == 0 => {
                    UiText::with("crop_grow_clear", [width.to_string(), height.to_string()])
                }
                Some([r, g, b]) => UiText::with(
                    "crop_grow",
                    [
                        width.to_string(),
                        height.to_string(),
                        format!("#{r:02x}{g:02x}{b:02x}"),
                    ],
                ),
                None => UiText::with(
                    "crop",
                    [
                        width.to_string(),
                        height.to_string(),
                        x.to_string(),
                        y.to_string(),
                    ],
                ),
            },
            Self::Resize {
                width,
                height,
                fill,
                fill_alpha,
                mode,
                ..
            } => match mode {
                // A stretch is the plain scale it says it is; a cover is the
                // one that throws pixels away, and the history says so.
                ResizeMode::Stretch => {
                    UiText::with("resize", [width.to_string(), height.to_string()])
                }
                ResizeMode::Cover => {
                    UiText::with("resize_cover", [width.to_string(), height.to_string()])
                }
                ResizeMode::Pad => match fill {
                    Some([_, _, _]) if *fill_alpha == 0 => {
                        UiText::with("resize_pad_clear", [width.to_string(), height.to_string()])
                    }
                    Some([r, g, b]) => UiText::with(
                        "resize_pad",
                        [
                            width.to_string(),
                            height.to_string(),
                            format!("#{r:02x}{g:02x}{b:02x}"),
                        ],
                    ),
                    // Validation refuses this before it can be labelled, so
                    // the fallback only keeps the sentence shaped like a
                    // resize.
                    None => UiText::with("resize", [width.to_string(), height.to_string()]),
                },
            },
            Self::Transform { .. } | Self::FreeTransform { .. } => UiText::new("transform"),
            Self::CanvasSize { width, height, .. } => {
                UiText::with("canvas_size", [width.to_string(), height.to_string()])
            }
            Self::RotateAngle { degrees, .. } => {
                UiText::with("rotate_angle", [format!("{degrees:.1}")])
            }
            Self::AdjustColor { .. } => UiText::new("adjust_color"),
            Self::AdjustCurves { .. } => UiText::new("adjust_curves"),
            Self::AdjustHsv { .. } => UiText::new("adjust_hsv"),
            Self::ColorBalance { .. } => UiText::new("color_balance"),
            Self::Paint { erase, .. } => {
                if *erase {
                    UiText::new("eraser_stroke")
                } else {
                    UiText::new("brush_stroke")
                }
            }
            Self::DrawShape { kind, .. } => match kind {
                DrawShapeKind::Line => UiText::new("draw_line"),
                DrawShapeKind::Rect => UiText::new("draw_rect"),
                DrawShapeKind::Ellipse => UiText::new("draw_ellipse"),
                DrawShapeKind::Polygon => UiText::new("draw_polygon"),
                DrawShapeKind::Polyline => UiText::new("draw_polyline"),
                DrawShapeKind::Bezier => UiText::new("draw_bezier"),
            },
            Self::FloodFill { .. } => UiText::new("flood_fill"),
            Self::Gradient { .. } => UiText::new("draw_gradient"),
            Self::AiResult { label, .. } => label.clone(),
            Self::Layer(op) => op.label(),
        }
    }
}
