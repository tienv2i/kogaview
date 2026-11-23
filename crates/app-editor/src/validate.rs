//! What Core must refuse before an operation is applied.
//!
//! Every refusal is a [`UiText`] line, so the UI draws a sentence it already
//! has a translation for rather than a developer string.

use kogaview_protocol::{ResizeMode, UiText};

use crate::MAX_DOCUMENT_PIXELS;

pub(crate) fn validate_crop(
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    doc_w: u32,
    doc_h: u32,
) -> Result<(), UiText> {
    if width == 0 || height == 0 {
        return Err(UiText::new("crop_size_empty"));
    }
    if x < 0
        || y < 0
        || (x as i64) >= i64::from(doc_w)
        || (y as i64) >= i64::from(doc_h)
        || (x as i64) + i64::from(width) > i64::from(doc_w)
        || (y as i64) + i64::from(height) > i64::from(doc_h)
    {
        return Err(UiText::with(
            "crop_does_not_fit",
            [
                width.to_string(),
                height.to_string(),
                x.to_string(),
                y.to_string(),
                doc_w.to_string(),
                doc_h.to_string(),
            ],
        ));
    }
    Ok(())
}

/// Validate any crop, inside or growing, and decide which one it is: a crop
/// without a fill must fit the picture, a crop with one may reach outside it.
pub(crate) fn validate_crop_mode(
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    doc_w: u32,
    doc_h: u32,
    fill: Option<[u8; 3]>,
    _fill_alpha: u8,
) -> Result<(), UiText> {
    if fill.is_none() {
        return validate_crop(x, y, width, height, doc_w, doc_h);
    }
    if width == 0 || height == 0 {
        return Err(UiText::new("crop_size_empty"));
    }
    if u64::from(width) * u64::from(height) > MAX_DOCUMENT_PIXELS {
        return Err(UiText::with(
            "crop_too_large",
            [
                width.to_string(),
                height.to_string(),
                MAX_DOCUMENT_PIXELS.to_string(),
            ],
        ));
    }
    // The canvas may grow past the picture, but a rectangle that misses it
    // would only produce a coloured page: the user asked for a border, not for
    // the photo to disappear.
    let right = i64::from(x) + i64::from(width);
    let bottom = i64::from(y) + i64::from(height);
    if right <= 0
        || bottom <= 0
        || i64::from(x) >= i64::from(doc_w)
        || i64::from(y) >= i64::from(doc_h)
    {
        return Err(UiText::with(
            "crop_outside_document",
            [
                width.to_string(),
                height.to_string(),
                x.to_string(),
                y.to_string(),
            ],
        ));
    }
    Ok(())
}

pub fn validate_resize(width: u32, height: u32) -> Result<(), UiText> {
    if width == 0 || height == 0 {
        return Err(UiText::new("resize_size_empty"));
    }
    if u64::from(width) * u64::from(height) > MAX_DOCUMENT_PIXELS {
        return Err(UiText::with(
            "resize_too_large",
            [
                width.to_string(),
                height.to_string(),
                MAX_DOCUMENT_PIXELS.to_string(),
            ],
        ));
    }
    Ok(())
}

/// The mode and the payload must agree: `Pad` is the only mode that paints
/// pixels the source does not have, so it is the only one that needs a colour.
/// A stretch or a cover with a stray `fill` ignores it rather than refusing,
/// because the mode is the answer the caller gave.
pub fn validate_resize_mode(mode: ResizeMode, fill: Option<[u8; 3]>) -> Result<(), UiText> {
    if mode == ResizeMode::Pad && fill.is_none() {
        return Err(UiText::new("resize_pad_needs_colour"));
    }
    Ok(())
}
/// hand on a zoomed-out canvas cannot place a corner closer than a fraction of
/// a pixel, and a warp that moves a corner by less than that is not an edit.
pub(crate) const IDENTITY_EPSILON: f64 = 1e-6;

/// True when the quad is exactly the document's own frame.
pub(crate) fn is_identity_quad(corners: &[[f64; 2]; 4], width: u32, height: u32) -> bool {
    let frame = [
        [0.0, 0.0],
        [f64::from(width), 0.0],
        [f64::from(width), f64::from(height)],
        [0.0, f64::from(height)],
    ];
    corners.iter().zip(frame.iter()).all(|(corner, expected)| {
        (corner[0] - expected[0]).abs() <= IDENTITY_EPSILON
            && (corner[1] - expected[1]).abs() <= IDENTITY_EPSILON
    })
}

/// Reject a quad the warp cannot resolve.
///
/// Three things go wrong on a canvas: a corner is dragged outside the picture
/// (there are no pixels to read there), two corners land on the same point or
/// three become collinear (the homography has no inverse, so one half of the
/// output would read nothing), or a corner is dragged past a neighbour so the
/// quad folds over itself (the projective map would still be a matrix, but the
/// picture inside it is mirrored twice and the user never asked for that).
///
/// Every corner must be inside the frame, every turn must go the same way, and
/// the area must not collapse. Corners are listed clockwise from the top-left
/// by contract, so a negative winding is as wrong as a folded one — it is the
/// same gesture seen from the other side.
pub(crate) fn validate_transform(
    corners: &[[f64; 2]; 4],
    doc_width: u32,
    doc_height: u32,
) -> Result<(), UiText> {
    let max_x = f64::from(doc_width);
    let max_y = f64::from(doc_height);
    if let Some([x, y]) = corners.iter().find(|[x, y]| {
        !x.is_finite() || !y.is_finite() || *x < 0.0 || *y < 0.0 || *x > max_x || *y > max_y
    }) {
        return Err(UiText::with(
            "transform_outside",
            [
                format!("{x:.0}"),
                format!("{y:.0}"),
                doc_width.to_string(),
                doc_height.to_string(),
            ],
        ));
    }

    let mut winding = 0.0f64;
    for index in 0..4 {
        let a = corners[index];
        let b = corners[(index + 1) % 4];
        let c = corners[(index + 2) % 4];
        let cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
        if cross.abs() < 1e-6 {
            return Err(UiText::new("transform_degenerate"));
        }
        if winding == 0.0 {
            winding = cross.signum();
        } else if cross.signum() != winding {
            return Err(UiText::new("transform_degenerate"));
        }
    }
    // Clockwise is the contract, and it is not a preference: the reversed quad
    // maps the frame onto itself mirrored. Turning a picture over is `Flip`'s
    // job, with its own history line, not something a corner drag does by
    // accident.
    if winding < 0.0 {
        return Err(UiText::new("transform_degenerate"));
    }

    if quad_area(corners) < 1.0 {
        return Err(UiText::new("transform_degenerate"));
    }
    Ok(())
}

/// The shoelace area of a quad, in square pixels; always positive.
pub(crate) fn quad_area(corners: &[[f64; 2]; 4]) -> f64 {
    let mut twice = 0.0f64;
    for index in 0..4 {
        let a = corners[index];
        let b = corners[(index + 1) % 4];
        twice += a[0] * b[1] - b[0] * a[1];
    }
    twice.abs() / 2.0
}

/// The largest brush radius accepted, in document pixels. A stroke is a paint
/// operation, not a fill: a radius this big still paints one line, and the cap
/// keeps a bad client from asking for a coverage mask over the whole frame.
pub(crate) const MAX_BRUSH_RADIUS: f64 = 4096.0;

/// A stroke needs at least one finite point, a radius with some width and an
/// opacity above zero. Outside coordinates are not an error: a stroke that
/// starts off the canvas and enters it is clipped, exactly like a real brush
/// held past the paper's edge.
pub(crate) fn validate_paint(points: &[[f64; 2]], radius: f64, opacity: f64) -> Result<(), UiText> {
    if points.is_empty() {
        return Err(UiText::new("paint_empty_stroke"));
    }
    if points.iter().any(|[x, y]| !x.is_finite() || !y.is_finite()) {
        return Err(UiText::new("paint_bad_point"));
    }
    if !radius.is_finite() || !(0.5..=MAX_BRUSH_RADIUS).contains(&radius) {
        return Err(UiText::with(
            "paint_bad_radius",
            [format!("{radius:.1}"), MAX_BRUSH_RADIUS.to_string()],
        ));
    }
    if !opacity.is_finite() || opacity <= 0.0 || opacity > 1.0 {
        return Err(UiText::with(
            "paint_bad_opacity",
            [format!("{:.0}", opacity * 100.0)],
        ));
    }
    Ok(())
}
