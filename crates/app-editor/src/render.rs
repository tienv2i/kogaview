//! Applying one operation: validate it against the document, then hand the
//! pixels to the arithmetic in `pixels` and the format work in `codec`.

use image::imageops;
use image::RgbaImage;
use kogaview_protocol::{FlipAxis, ResizeMode, UiText};

use crate::*;

/// Render one operation into a new buffer, leaving `image` untouched.
pub fn render_operation(image: &RgbaImage, operation: &EditOperation) -> Result<RgbaImage, UiText> {
    let (width, height) = image.dimensions();
    match operation {
        EditOperation::Rotate { degrees } => match degrees.rem_euclid(360) {
            90 => Ok(imageops::rotate90(image)),
            180 => Ok(imageops::rotate180(image)),
            270 => Ok(imageops::rotate270(image)),
            other => Err(UiText::with("invalid_rotation", [other.to_string()])),
        },
        EditOperation::Flip { axis } => Ok(match axis {
            FlipAxis::Horizontal => imageops::flip_horizontal(image),
            FlipAxis::Vertical => imageops::flip_vertical(image),
        }),
        EditOperation::Crop {
            x,
            y,
            width: w,
            height: h,
            fill,
            fill_alpha,
        } => {
            validate_crop_mode(*x, *y, *w, *h, width, height, *fill, *fill_alpha)?;
            match fill {
                Some([r, g, b]) => Ok(grow_crop(image, *x, *y, *w, *h, [*r, *g, *b], *fill_alpha)),
                None => Ok(imageops::crop_imm(image, *x as u32, *y as u32, *w, *h).to_image()),
            }
        }
        EditOperation::Resize {
            width: w,
            height: h,
            fill,
            fill_alpha,
            mode,
            filter,
        } => {
            validate_resize(*w, *h)?;
            validate_resize_mode(*mode, *fill)?;
            match mode {
                // The whole frame, scaled to the target: the only mode that
                // keeps every pixel, and the default because the user asked
                // for a size, not for a decision about what to lose.
                ResizeMode::Stretch => Ok(resample(image, *w, *h, *filter)),
                // Keep the source's shape and take the centred rectangle that
                // covers the target. `cover_rect` snaps a rounding difference
                // of a pixel, so a locked ratio cannot shave an edge.
                ResizeMode::Cover => {
                    let rect = cover_rect(width, height, *w, *h);
                    let cropped =
                        imageops::crop_imm(image, rect.0, rect.1, rect.2, rect.3).to_image();
                    Ok(resample(&cropped, *w, *h, *filter))
                }
                // Fit inside and pad the leftover: no stretch, no crop.
                ResizeMode::Pad => {
                    let [r, g, b] = fill.unwrap_or([0, 0, 0]);
                    Ok(fit_with_padding(
                        image,
                        *w,
                        *h,
                        [r, g, b],
                        *fill_alpha,
                        *filter,
                    ))
                }
            }
        }
        EditOperation::Transform { corners } => {
            validate_transform(corners, width, height)?;
            Ok(warp_quad(image, corners))
        }
        EditOperation::FreeTransform {
            x,
            y,
            width: w,
            height: h,
            rotation,
            fill,
            fill_alpha,
        } => {
            validate_resize(*w, *h)?;
            if !rotation.is_finite() {
                return Err(UiText::with("invalid_rotation", [rotation.to_string()]));
            }
            let rgb = fill.unwrap_or([0, 0, 0]);
            Ok(free_transform(
                image,
                *x,
                *y,
                *w,
                *h,
                *rotation,
                rgb,
                *fill_alpha,
            ))
        }
        EditOperation::CanvasSize {
            width: w,
            height: h,
            anchor,
            fill,
            fill_alpha,
        } => {
            validate_resize(*w, *h)?;
            let rgb = fill.unwrap_or([0, 0, 0]);
            Ok(canvas_size(image, *w, *h, anchor, rgb, *fill_alpha))
        }
        EditOperation::RotateAngle {
            degrees,
            fill,
            fill_alpha,
        } => {
            if !degrees.is_finite() {
                return Err(UiText::with("invalid_rotation", [degrees.to_string()]));
            }
            let rgb = fill.unwrap_or([0, 0, 0]);
            Ok(rotate_angle(image, *degrees, rgb, *fill_alpha))
        }
        EditOperation::AdjustColor {
            brightness,
            contrast,
            saturation,
        } => {
            if !brightness.is_finite() || !contrast.is_finite() || !saturation.is_finite() {
                return Err(UiText::new("invalid_color_adjustment"));
            }
            Ok(pixels::adjust_color(
                image,
                *brightness,
                *contrast,
                *saturation,
            ))
        }
        EditOperation::Paint {
            points,
            color,
            radius,
            opacity,
            erase,
        } => {
            validate_paint(points, *radius, *opacity)?;
            Ok(paint_stroke(
                image, points, *color, *radius, *opacity, *erase,
            ))
        }
    }
}
