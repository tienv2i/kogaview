//! What one edit is, and the line History shows for it.

use kogaview_protocol::{FlipAxis, ResizeFilter, ResizeMode, UiText};
use serde::Serialize;

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
    },
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
            Self::Transform { .. } => UiText::new("transform"),
            Self::Paint { erase, .. } => {
                if *erase {
                    UiText::new("eraser_stroke")
                } else {
                    UiText::new("brush_stroke")
                }
            }
        }
    }
}
