//! Editor & batch protocol types: brushes, shapes, gradients, adjustments, resize, formats.

use serde::{Deserialize, Serialize};

use crate::opaque_fill_alpha;
use crate::plugins::{default_crop_unit, default_true};

/// The axis a flip mirrors the working image across. Parts of the Editor
/// protocol; kept here so the CLI/IPC/MCP front ends share the one type.
/// Krita-inspired brush tip profile for `EditorPaintStroke`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrushTip {
    #[default]
    Round,
    Flat,
    Chalk,
    Spray,
    Pixel,
}

/// Optional Krita-style brush dynamics attached to a paint stroke.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct BrushSettings {
    #[serde(default)]
    pub tip: BrushTip,
    #[serde(default = "default_brush_hardness")]
    pub hardness: f64,
    #[serde(default = "default_one_f64")]
    pub flow: f64,
    #[serde(default = "default_brush_spacing")]
    pub spacing: f64,
    #[serde(default)]
    pub angle: f64,
    #[serde(default)]
    pub scatter: f64,
}

pub(crate) fn default_brush_hardness() -> f64 {
    0.85
}

pub(crate) fn default_brush_spacing() -> f64 {
    0.15
}

impl Default for BrushSettings {
    fn default() -> Self {
        Self {
            tip: BrushTip::Round,
            hardness: default_brush_hardness(),
            flow: 1.0,
            spacing: default_brush_spacing(),
            angle: 0.0,
            scatter: 0.0,
        }
    }
}

/// Krita-style morphological/edge modifier applied to the active selection mask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiquifyMode {
    Push,
    Bloat,
    Pucker,
    TwirlCw,
    TwirlCcw,
}

impl Default for LiquifyMode {
    fn default() -> Self {
        Self::Push
    }
}

/// Kind of interactive live stroke session (`editor_live_stroke_begin`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LiveStrokeKind {
    Paint {
        color: [u8; 3],
        radius: f64,
        #[serde(default = "default_one_f64")]
        opacity: f64,
        #[serde(default)]
        erase: bool,
        #[serde(flatten, default)]
        brush: BrushSettings,
    },
    Liquify {
        #[serde(default)]
        mode: LiquifyMode,
        radius: f32,
        #[serde(default = "crate::default_liquify_strength")]
        strength: f32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StrokePosition {
    Inside,
    Center,
    Outside,
}

impl Default for StrokePosition {
    fn default() -> Self {
        Self::Center
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionModifyOp {
    Grow,
    Shrink,
    Border,
    Feather,
    Smooth,
}

/// Non-destructive adjustment applied live to all layers underneath an Adjustment Layer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LayerAdjustment {
    BrightnessContrast {
        #[serde(default)]
        brightness: f64,
        #[serde(default)]
        contrast: f64,
        #[serde(default)]
        saturation: f64,
    },
    Hsv {
        #[serde(default)]
        hue: f64,
        #[serde(default)]
        saturation: f64,
        #[serde(default)]
        value: f64,
    },
    ColorBalance {
        #[serde(default)]
        shadows: [f64; 3],
        #[serde(default)]
        midtones: [f64; 3],
        #[serde(default)]
        highlights: [f64; 3],
        #[serde(default = "default_true")]
        preserve_luminosity: bool,
    },
    Invert,
    Desaturate,
}

/// One color/alpha stop along a multi-stop gradient (`pos` in `0.0..=1.0`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct GradientStop {
    pub pos: f64,
    pub color: [u8; 3],
    #[serde(default = "default_one_f64")]
    pub alpha: f64,
}

/// Krita-style gradient geometry shape for `EditorGradient`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GradientShape {
    #[default]
    Linear,
    Bilinear,
    Radial,
    Square,
    Conical,
    Spiral,
}

/// Repeat policy for `EditorGradient` outside `[0, 1]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GradientRepeat {
    #[default]
    None,
    Forwards,
    Alternating,
}

/// Which vector/shape primitive `EditorDrawShape` rasterizes onto the active layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DrawShapeKind {
    Line,
    Rect,
    Ellipse,
    Polygon,
    Polyline,
    Bezier,
}

pub(crate) fn default_one_f64() -> f64 {
    1.0
}

pub(crate) fn default_fill_tolerance() -> u8 {
    24
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FlipAxis {
    /// Mirror left/right (a vertical mirror line).
    Horizontal,
    /// Mirror top/bottom (a horizontal mirror line).
    Vertical,
}

/// How an editing tool or AI plugin targets a layered Editor document.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApplyTarget {
    /// Apply only to the currently selected active layer (other layers untouched).
    ActiveLayer,
    /// Apply to the whole canvas / all layers (default for legacy flat callers).
    #[default]
    WholeImage,
    /// Insert the result as a new layer above the active layer (non-destructive output).
    NewLayer,
}

/// How an oversized pasted image is fitted onto the open Editor canvas.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PasteMode {
    /// Keep original pixels & canvas size (overflow sits outside canvas bounds).
    #[default]
    KeepOriginal,
    /// Scale pasted image down proportionally to fit inside the canvas.
    FitToCanvas,
    /// Expand canvas to at least the pasted image's size, centering existing layers.
    ExpandCanvas,
}

/// How a new selection combines with an existing selection mask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionMode {
    #[default]
    Replace,
    Add,
    Subtract,
    Intersect,
}

/// The resampling filter a resize asks for. `Auto` is the fast box average when
/// the target is smaller and Lanczos3 when it is larger; the named filters are
/// the `image` crate's kernels, so the view's dropdown changes real pixels
/// rather than only its label.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResizeFilter {
    #[default]
    Auto,
    Nearest,
    Bilinear,
    Bicubic,
    Bspline,
    Lanczos3,
}

/// How a resize relates the source's shape to the target's.
///
/// A resize answers "make this W × H", not "decide what the new shape keeps";
/// the second question has three honest answers, so it is asked explicitly
/// instead of being assumed. `Stretch` is the default because it is the only
/// one that discards nothing: every source pixel contributes to the result.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResizeMode {
    /// Scale the whole frame to the target, even when the aspect changes.
    #[default]
    Stretch,
    /// Keep the source's shape and take a centred rectangle of it that covers
    /// the target. Pixels outside that rectangle are discarded.
    Cover,
    /// Scale the whole frame to fit inside the target and fill the leftover
    /// with `fill`. Nothing is stretched and nothing is discarded; the result
    /// is a letterbox or a pillarbox.
    Pad,
}

impl ResizeMode {
    /// The mode a payload means.
    ///
    /// An older payload carries no mode. A `fill` meant "fit and pad", and no
    /// fill meant the centred cover crop — that is the pair the form used to
    /// offer, and a replayed journal must keep its meaning. A *new* payload
    /// always names its mode, so the default for anyone else is `Stretch`:
    /// silently discarding the edges is the bug this enum exists to end.
    pub fn for_payload(mode: Option<Self>, fill: Option<[u8; 3]>) -> Self {
        mode.unwrap_or(if fill.is_some() {
            Self::Pad
        } else {
            Self::Stretch
        })
    }
}

/// A file format a batch convert can write.
///
/// The Editor picks its save format from the destination's extension, but a
/// batch destination is built by Core: the user names a format, Core names the
/// file. The variants are the encoders this build carries, so the dropdown can
/// offer nothing the worker would refuse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageFormat {
    Png,
    Jpeg,
    Webp,
    Tiff,
    Gif,
    Bmp,
    Tga,
    Qoi,
}

impl ImageFormat {
    /// Every format a convert offers, in the order the form lists them.
    pub const ALL: [Self; 8] = [
        Self::Png,
        Self::Jpeg,
        Self::Webp,
        Self::Tiff,
        Self::Gif,
        Self::Bmp,
        Self::Tga,
        Self::Qoi,
    ];

    /// The extension the written file carries, without the dot.
    pub const fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Webp => "webp",
            Self::Tiff => "tiff",
            Self::Gif => "gif",
            Self::Bmp => "bmp",
            Self::Tga => "tga",
            Self::Qoi => "qoi",
        }
    }

    /// The dotted extension the form shows.
    pub const fn label(self) -> &'static str {
        match self {
            Self::Png => ".png",
            Self::Jpeg => ".jpg",
            Self::Webp => ".webp",
            Self::Tiff => ".tiff",
            Self::Gif => ".gif",
            Self::Bmp => ".bmp",
            Self::Tga => ".tga",
            Self::Qoi => ".qoi",
        }
    }
}

/// What one batch job does to every input image.
///
/// A batch is one typed job, not a list of per-file commands: the three
/// operations share the input list, the output policy, the progress counter and
/// the cancellation flag, and a front end that sent a hundred commands could
/// neither cancel them together nor say "12 of 40" honestly.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum BatchOperation {
    /// Scale every image to exactly `width` × `height`.
    ///
    /// The mode and filter mean what they mean in `EditorResize`; `cover` and
    /// `pad` are how one target size fits a folder of mixed shapes.
    Resize {
        width: u32,
        height: u32,
        #[serde(default)]
        mode: ResizeMode,
        #[serde(default)]
        filter: ResizeFilter,
        #[serde(default)]
        fill: Option<[u8; 3]>,
        #[serde(default = "opaque_fill_alpha")]
        fill_alpha: u8,
    },
    /// Cut a proportional rectangle from every image.
    ///
    /// Each value is a percentage (0–100) of that image's own side, so one job
    /// describes the same trim on a folder of mixed sizes: `0,0,100,100` is the
    /// whole picture and `10,10,80,80` trims ten percent from each side.
    Crop {
        #[serde(default)]
        x: f64,
        #[serde(default)]
        y: f64,
        #[serde(default)]
        width: f64,
        #[serde(default)]
        height: f64,
        /// `"percent"` (default, 0–100) or `"pixels"` (absolute pixels).
        #[serde(default = "default_crop_unit")]
        unit: String,
        /// Optional 9-point anchor (`top_left`..`bottom_right`). When set,
        /// placement is computed per image from this anchor instead of `x, y`.
        #[serde(default)]
        anchor: Option<String>,
        /// Optional aspect ratio (`width / height`). When set without explicit
        /// width/height, cuts the largest rectangle of this ratio from each image.
        #[serde(default)]
        ratio: Option<f64>,
    },
    /// Re-encode every image in `format`, with `quality` for the lossy encoder.
    Convert {
        format: ImageFormat,
        #[serde(default)]
        quality: Option<u8>,
    },
}

impl BatchOperation {
    /// Stable name for the journal, the progress label and the logs.
    pub const fn name(&self) -> &'static str {
        match self {
            Self::Resize { .. } => "resize",
            Self::Crop { .. } => "crop",
            Self::Convert { .. } => "convert",
        }
    }
}

/// Where a batch job gets its files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum BatchSource {
    /// The explicit list the interface sends — normally the selection.
    Selection { paths: Vec<String> },
    /// Every image directly inside `path`. Non-recursive: the Browser shows one
    /// folder, and a batch that silently descended would touch files the user
    /// never saw.
    Folder { path: String },
}

/// Where a batch job writes its results.
///
/// The default the interface sends is a suffix beside the source; replacing the
/// originals is a separate, explicit answer because a batch is not a save and
/// the project never overwrites a source by default.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchOutput {
    /// Destination folder; `None` writes beside each source.
    #[serde(default)]
    pub folder: Option<String>,
    /// Text inserted before the extension. Empty keeps the name.
    #[serde(default)]
    pub suffix: String,
    /// Replace the source files in place. Never inferred from an empty suffix:
    /// this flag is the only way a destination may be its own source.
    #[serde(default)]
    pub overwrite: bool,
}
