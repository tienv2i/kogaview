//! The arithmetic an edit is made of: resampling, covering, padding, the
//! perspective warp and one brush stroke. Nothing here knows about a document,
//! a history or a file — it takes a buffer and returns one.

use image::imageops::{self, FilterType};
use image::RgbaImage;
use kogaview_protocol::ResizeFilter;

/// A crop whose canvas grows past the picture: start from the fill colour and
/// copy the part of the picture the rectangle keeps onto it. The rectangle is
/// in the new canvas' coordinates, so a negative origin means the picture
/// starts inside the canvas rather than at its top-left corner.
pub(crate) fn grow_crop(
    image: &RgbaImage,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    fill: [u8; 3],
    fill_alpha: u8,
) -> RgbaImage {
    let mut canvas = RgbaImage::from_pixel(
        width,
        height,
        image::Rgba([fill[0], fill[1], fill[2], fill_alpha]),
    );
    let (doc_w, doc_h) = image.dimensions();
    // The part of the picture the rectangle keeps, in picture coordinates.
    let source_left = x.max(0).min(doc_w as i32);
    let source_top = y.max(0).min(doc_h as i32);
    let source_right = (i64::from(x) + i64::from(width))
        .min(i64::from(doc_w))
        .max(0) as i32;
    let source_bottom = (i64::from(y) + i64::from(height))
        .min(i64::from(doc_h))
        .max(0) as i32;
    if source_right > source_left && source_bottom > source_top {
        let cropped = imageops::crop_imm(
            image,
            source_left as u32,
            source_top as u32,
            (source_right - source_left) as u32,
            (source_bottom - source_top) as u32,
        )
        .to_image();
        imageops::replace(
            &mut canvas,
            &cropped,
            i64::from(source_left - x),
            i64::from(source_top - y),
        );
    }
    canvas
}

/// Paint one stroke as a union of round-capped capsules.
///
/// The coverage of a pixel is the *maximum* over every segment that reaches it,
/// not a sum: a stroke that crosses itself or doubles back would otherwise get
/// darker at the join, which is the classic overlap artefact of painting dabs.
/// Each segment is feathered over one pixel at its edge so a diagonal is not a
/// staircase. A brush blends `color` source-over the pixels; an eraser only
/// lowers their alpha, so it works on a transparent document too.
pub(crate) fn paint_stroke(
    image: &RgbaImage,
    points: &[[f64; 2]],
    color: [u8; 3],
    radius: f64,
    opacity: f64,
    erase: bool,
) -> RgbaImage {
    let (width, height) = image.dimensions();
    let mut result = image.clone();

    // The stroke's bounds plus a pixel of feather, clipped to the frame.
    let feather = radius + 1.0;
    let first = points[0];
    let mut min_x = first[0];
    let mut min_y = first[1];
    let mut max_x = first[0];
    let mut max_y = first[1];
    for [x, y] in points {
        min_x = min_x.min(*x);
        min_y = min_y.min(*y);
        max_x = max_x.max(*x);
        max_y = max_y.max(*y);
    }
    let left = (min_x - feather).floor().max(0.0) as u32;
    let top = (min_y - feather).floor().max(0.0) as u32;
    let right = ((max_x + feather).ceil().max(0.0) as u32).min(width);
    let bottom = ((max_y + feather).ceil().max(0.0) as u32).min(height);
    if left >= right || top >= bottom {
        return result;
    }

    let box_w = (right - left) as usize;
    let box_h = (bottom - top) as usize;
    let mut coverage = vec![0.0f32; box_w * box_h];

    // A single point is a dot: a zero-length segment whose caps make a disk.
    let segments: Vec<([f64; 2], [f64; 2])> = if points.len() == 1 {
        vec![(points[0], points[0])]
    } else {
        points.windows(2).map(|pair| (pair[0], pair[1])).collect()
    };

    for (a, b) in &segments {
        let seg_left = (a[0].min(b[0]) - feather).floor().max(left as f64) as usize;
        let seg_top = (a[1].min(b[1]) - feather).floor().max(top as f64) as usize;
        let seg_right = ((a[0].max(b[0]) + feather).ceil().max(0.0) as usize).min(right as usize);
        let seg_bottom = ((a[1].max(b[1]) + feather).ceil().max(0.0) as usize).min(bottom as usize);
        if seg_left >= seg_right || seg_top >= seg_bottom {
            continue;
        }
        let delta = [b[0] - a[0], b[1] - a[1]];
        let length_squared = delta[0] * delta[0] + delta[1] * delta[1];
        for y in seg_top..seg_bottom {
            let py = y as f64 + 0.5;
            for x in seg_left..seg_right {
                let px = x as f64 + 0.5;
                let t = if length_squared > 0.0 {
                    (((px - a[0]) * delta[0] + (py - a[1]) * delta[1]) / length_squared)
                        .clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let cx = a[0] + delta[0] * t;
                let cy = a[1] + delta[1] * t;
                let distance = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt();
                let value = (radius + 0.5 - distance).clamp(0.0, 1.0) as f32;
                let index = (y - top as usize) * box_w + (x - left as usize);
                if value > coverage[index] {
                    coverage[index] = value;
                }
            }
        }
    }

    let alpha_scale = opacity as f32;
    for y in top..bottom {
        for x in left..right {
            let amount = coverage[((y - top) as usize) * box_w + (x as usize - left as usize)];
            if amount <= 0.0 {
                continue;
            }
            let alpha = (amount * alpha_scale).clamp(0.0, 1.0);
            if alpha <= 0.0 {
                continue;
            }
            let pixel = result.get_pixel_mut(x, y);
            let destination = pixel.0;
            let destination_alpha = f32::from(destination[3]) / 255.0;
            if erase {
                let out_alpha = destination_alpha * (1.0 - alpha);
                pixel.0 = [
                    destination[0],
                    destination[1],
                    destination[2],
                    (out_alpha * 255.0).round().clamp(0.0, 255.0) as u8,
                ];
            } else {
                let out_alpha = alpha + destination_alpha * (1.0 - alpha);
                if out_alpha <= 0.0 {
                    pixel.0 = [0, 0, 0, 0];
                    continue;
                }
                let blend = |source: u8, under: u8| -> u8 {
                    let source = f32::from(source) / 255.0;
                    let under = f32::from(under) / 255.0;
                    (((source * alpha + under * destination_alpha * (1.0 - alpha)) / out_alpha)
                        * 255.0)
                        .round()
                        .clamp(0.0, 255.0) as u8
                };
                pixel.0 = [
                    blend(color[0], destination[0]),
                    blend(color[1], destination[1]),
                    blend(color[2], destination[2]),
                    (out_alpha * 255.0).round().clamp(0.0, 255.0) as u8,
                ];
            }
        }
    }
    result
}

/// The homography that maps the unit square onto `corners`.
///
/// The unit square's (0, 0), (1, 0), (1, 1), (0, 1) land on the quad's TL, TR,
/// BR, BL. The classic square-to-quad decomposition is used rather than an
/// 8 × 8 solve: it is the same answer with the degenerate case (a parallelogram)
/// written out instead of divided by zero.
pub(crate) fn square_to_quad(corners: &[[f64; 2]; 4]) -> [[f64; 3]; 3] {
    let [p0, p1, p2, p3] = *corners;
    let sx = p0[0] - p1[0] + p2[0] - p3[0];
    let sy = p0[1] - p1[1] + p2[1] - p3[1];
    if sx.abs() < 1e-12 && sy.abs() < 1e-12 {
        return [
            [p1[0] - p0[0], p3[0] - p0[0], p0[0]],
            [p1[1] - p0[1], p3[1] - p0[1], p0[1]],
            [0.0, 0.0, 1.0],
        ];
    }
    let dx1 = p1[0] - p2[0];
    let dx2 = p3[0] - p2[0];
    let dy1 = p1[1] - p2[1];
    let dy2 = p3[1] - p2[1];
    let denominator = dx1 * dy2 - dx2 * dy1;
    let g = (sx * dy2 - dx2 * sy) / denominator;
    let h = (dx1 * sy - sx * dy1) / denominator;
    [
        [p1[0] - p0[0] + g * p1[0], p3[0] - p0[0] + h * p3[0], p0[0]],
        [p1[1] - p0[1] + g * p1[1], p3[1] - p0[1] + h * p3[1], p0[1]],
        [g, h, 1.0],
    ]
}

/// Warp `image` so the quad becomes the whole frame, keeping the frame's size.
///
/// Each destination pixel centre is a point in the unit square; the homography
/// takes it to the quad's own point in the source, which is sampled bilinearly.
/// The quad is inside the frame by validation, so every sample lands inside the
/// picture; the clamp is there for float rounding at the very edge, not as a
/// crop.
pub(crate) fn warp_quad(image: &RgbaImage, corners: &[[f64; 2]; 4]) -> RgbaImage {
    let (width, height) = image.dimensions();
    let [[a, b, c], [d, e, f], [g, h, _]] = square_to_quad(corners);
    let mut output = RgbaImage::new(width, height);
    let width_f = f64::from(width);
    let height_f = f64::from(height);
    for y in 0..height {
        // The unit square's v for this row is constant: hoist it out of the
        // inner loop, which is most of the cost on a large document.
        let v = (f64::from(y) + 0.5) / height_f;
        for x in 0..width {
            let u = (f64::from(x) + 0.5) / width_f;
            let w = g * u + h * v + 1.0;
            if w.abs() < 1e-12 {
                continue;
            }
            let source_x = (a * u + b * v + c) / w;
            let source_y = (d * u + e * v + f) / w;
            // The homography answers in *frame* coordinates — where the
            // document's outer edge is 0 and `width`, not the centre of its
            // first pixel. Shift to pixel centres so an identity quad samples
            // pixel (x, y) for destination pixel (x, y) instead of halfway
            // between two.
            output.put_pixel(x, y, sample_bilinear(image, source_x - 0.5, source_y - 0.5));
        }
    }
    output
}

/// Resample `image` to `width × height` and place it at `(x, y)` on a new
/// canvas of `image`'s original dimensions, filling uncovered pixels with
/// `fill` / `fill_alpha`. Pixels placed outside the canvas are clipped.
pub(crate) fn free_transform(
    image: &RgbaImage,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    rotation: f64,
    fill: [u8; 3],
    fill_alpha: u8,
) -> RgbaImage {
    let (doc_w, doc_h) = image.dimensions();
    let background = if fill_alpha == 0 {
        image::Rgba([0, 0, 0, 0])
    } else {
        image::Rgba([fill[0], fill[1], fill[2], fill_alpha])
    };
    let mut output = RgbaImage::from_pixel(doc_w, doc_h, background);
    let scaled = resample(image, width, height, ResizeFilter::Auto);
    let norm = rotation.rem_euclid(360.0);
    if norm < 1e-4 || (360.0 - norm) < 1e-4 {
        let doc_w_i = i64::from(doc_w);
        let doc_h_i = i64::from(doc_h);
        for sy in 0..height {
            let dy = i64::from(y) + i64::from(sy);
            if dy < 0 || dy >= doc_h_i {
                continue;
            }
            for sx in 0..width {
                let dx = i64::from(x) + i64::from(sx);
                if dx < 0 || dx >= doc_w_i {
                    continue;
                }
                let src = *scaled.get_pixel(sx, sy);
                let dst = *output.get_pixel(dx as u32, dy as u32);
                output.put_pixel(dx as u32, dy as u32, blend_over(dst, src));
            }
        }
        return output;
    }

    let rad = rotation.to_radians();
    let cos = rad.cos();
    let sin = rad.sin();
    let wf = f64::from(width);
    let hf = f64::from(height);
    let box_cx = f64::from(x) + wf / 2.0;
    let box_cy = f64::from(y) + hf / 2.0;
    for dy_u in 0..doc_h {
        let dy = (f64::from(dy_u) + 0.5) - box_cy;
        for dx_u in 0..doc_w {
            let dx = (f64::from(dx_u) + 0.5) - box_cx;
            let sx = dx * cos + dy * sin + wf / 2.0;
            let sy = -dx * sin + dy * cos + hf / 2.0;
            if sx >= 0.0 && sx <= wf && sy >= 0.0 && sy <= hf {
                let sampled = sample_bilinear(&scaled, sx - 0.5, sy - 0.5);
                output.put_pixel(dx_u, dy_u, blend_over(background, sampled));
            }
        }
    }
    output
}

/// Resize the canvas without scaling the source pixels.
///
/// The source image is placed at the requested 3×3 anchor inside the new
/// `width × height` frame: growing adds a border filled with `fill` /
/// `fill_alpha`, shrinking crops around the anchor.
pub(crate) fn canvas_size(
    image: &RgbaImage,
    width: u32,
    height: u32,
    anchor: &str,
    fill: [u8; 3],
    fill_alpha: u8,
) -> RgbaImage {
    let (doc_w, doc_h) = image.dimensions();
    let background = if fill_alpha == 0 {
        image::Rgba([0, 0, 0, 0])
    } else {
        image::Rgba([fill[0], fill[1], fill[2], fill_alpha])
    };
    let mut output = RgbaImage::from_pixel(width, height, background);
    let col = match anchor {
        "top_left" | "left" | "bottom_left" => 0,
        "top_right" | "right" | "bottom_right" => 2,
        _ => 1,
    };
    let row = match anchor {
        "top_left" | "top" | "top_right" => 0,
        "bottom_left" | "bottom" | "bottom_right" => 2,
        _ => 1,
    };
    let dx: i64 = match col {
        0 => 0,
        1 => (i64::from(width) - i64::from(doc_w)) / 2,
        _ => i64::from(width) - i64::from(doc_w),
    };
    let dy: i64 = match row {
        0 => 0,
        1 => (i64::from(height) - i64::from(doc_h)) / 2,
        _ => i64::from(height) - i64::from(doc_h),
    };
    let out_w_i = i64::from(width);
    let out_h_i = i64::from(height);
    for sy in 0..doc_h {
        let ty = i64::from(sy) + dy;
        if ty < 0 || ty >= out_h_i {
            continue;
        }
        for sx in 0..doc_w {
            let tx = i64::from(sx) + dx;
            if tx < 0 || tx >= out_w_i {
                continue;
            }
            let src = *image.get_pixel(sx, sy);
            let dst = *output.get_pixel(tx as u32, ty as u32);
            output.put_pixel(tx as u32, ty as u32, blend_over(dst, src));
        }
    }
    output
}

/// Rotate `image` clockwise by an arbitrary angle (in degrees), expanding the
/// canvas to hold the rotated bounding box and filling uncovered corners with
/// `fill` / `fill_alpha`.
pub(crate) fn rotate_angle(
    image: &RgbaImage,
    degrees: f64,
    fill: [u8; 3],
    fill_alpha: u8,
) -> RgbaImage {
    let (w, h) = image.dimensions();
    let wf = f64::from(w);
    let hf = f64::from(h);
    let rad = degrees.to_radians();
    let cos = rad.cos();
    let sin = rad.sin();
    let new_w = ((wf * cos.abs() + hf * sin.abs()).ceil() as u32).clamp(1, 16384);
    let new_h = ((wf * sin.abs() + hf * cos.abs()).ceil() as u32).clamp(1, 16384);
    let background = if fill_alpha == 0 {
        image::Rgba([0, 0, 0, 0])
    } else {
        image::Rgba([fill[0], fill[1], fill[2], fill_alpha])
    };
    let mut output = RgbaImage::from_pixel(new_w, new_h, background);
    let dst_cx = f64::from(new_w) / 2.0;
    let dst_cy = f64::from(new_h) / 2.0;
    let src_cx = wf / 2.0;
    let src_cy = hf / 2.0;

    for y in 0..new_h {
        let dy = (f64::from(y) + 0.5) - dst_cy;
        for x in 0..new_w {
            let dx = (f64::from(x) + 0.5) - dst_cx;
            // Inverse clockwise rotation (-rad) maps destination pixel centre
            // back into source frame coordinates.
            let sx = dx * cos + dy * sin + src_cx;
            let sy = -dx * sin + dy * cos + src_cy;
            if sx >= 0.0 && sx <= wf && sy >= 0.0 && sy <= hf {
                let sampled = sample_bilinear(image, sx - 0.5, sy - 0.5);
                output.put_pixel(x, y, blend_over(background, sampled));
            }
        }
    }
    output
}

fn blend_over(dst: image::Rgba<u8>, src: image::Rgba<u8>) -> image::Rgba<u8> {
    let sa = f32::from(src[3]) / 255.0;
    if sa >= 1.0 {
        return src;
    }
    if sa <= 0.0 {
        return dst;
    }
    let da = f32::from(dst[3]) / 255.0;
    let out_a = sa + da * (1.0 - sa);
    if out_a <= 0.0 {
        return image::Rgba([0, 0, 0, 0]);
    }
    let mix = |s: u8, d: u8| -> u8 {
        let v = (f32::from(s) * sa + f32::from(d) * da * (1.0 - sa)) / out_a;
        v.round().clamp(0.0, 255.0) as u8
    };
    image::Rgba([
        mix(src[0], dst[0]),
        mix(src[1], dst[1]),
        mix(src[2], dst[2]),
        (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
    ])
}

/// Bilinear sample with the sample point clamped to the image's own bounds.
pub(crate) fn sample_bilinear(image: &RgbaImage, x: f64, y: f64) -> image::Rgba<u8> {
    let (width, height) = image.dimensions();
    if width == 0 || height == 0 {
        return image::Rgba([0, 0, 0, 255]);
    }
    let x = x.clamp(0.0, f64::from(width - 1));
    let y = y.clamp(0.0, f64::from(height - 1));
    let x0 = x.floor() as u32;
    let y0 = y.floor() as u32;
    let x1 = (x0 + 1).min(width - 1);
    let y1 = (y0 + 1).min(height - 1);
    let fx = x - f64::from(x0);
    let fy = y - f64::from(y0);
    let top_left = image.get_pixel(x0, y0);
    let top_right = image.get_pixel(x1, y0);
    let bottom_left = image.get_pixel(x0, y1);
    let bottom_right = image.get_pixel(x1, y1);
    let mut out = [0u8; 4];
    for channel in 0..4 {
        let top = f64::from(top_left[channel]) * (1.0 - fx) + f64::from(top_right[channel]) * fx;
        let bottom =
            f64::from(bottom_left[channel]) * (1.0 - fx) + f64::from(bottom_right[channel]) * fx;
        let value = top * (1.0 - fy) + bottom * fy;
        out[channel] = value.round().clamp(0.0, 255.0) as u8;
    }
    image::Rgba(out)
}

/// Resample one image with the filter the form asked for.
///
/// `Auto` is a box average for a downscale — fast and right for shrinking a
/// photo to a delivery size — and Lanczos3 when the target is larger, where a
/// box average would leave a hard-edged enlargement. The named choices map to
/// the `image` crate's kernels: `Bilinear` to its triangle, `Bicubic` to
/// Catmull-Rom, `Bspline` to its Gaussian approximation.
pub(crate) fn resample(
    image: &RgbaImage,
    target_width: u32,
    target_height: u32,
    filter: ResizeFilter,
) -> RgbaImage {
    match filter {
        ResizeFilter::Nearest => {
            imageops::resize(image, target_width, target_height, FilterType::Nearest)
        }
        ResizeFilter::Bilinear => {
            imageops::resize(image, target_width, target_height, FilterType::Triangle)
        }
        ResizeFilter::Bicubic => {
            imageops::resize(image, target_width, target_height, FilterType::CatmullRom)
        }
        ResizeFilter::Bspline => {
            imageops::resize(image, target_width, target_height, FilterType::Gaussian)
        }
        ResizeFilter::Lanczos3 => {
            imageops::resize(image, target_width, target_height, FilterType::Lanczos3)
        }
        ResizeFilter::Auto => {
            let (width, height) = image.dimensions();
            if target_width < width && target_height < height {
                imageops::thumbnail(image, target_width, target_height)
            } else {
                imageops::resize(image, target_width, target_height, FilterType::Lanczos3)
            }
        }
    }
}

/// Scale the whole source down (or up) to the largest box of the source's own
/// shape that fits inside `target_width` × `target_height`, then centre it on a
/// target-sized canvas of `color`. Nothing is stretched and nothing is cut: the
/// target shape is the frame, the source shape is what fills it, and the
/// leftover is the pad. The pad is a letterbox or a pillarbox — only a square
/// when the target itself is square.
pub(crate) fn fit_with_padding(
    image: &RgbaImage,
    target_width: u32,
    target_height: u32,
    color: [u8; 3],
    alpha: u8,
    filter: ResizeFilter,
) -> RgbaImage {
    let (source_width, source_height) = image.dimensions();
    let source_width_64 = u64::from(source_width);
    let source_height_64 = u64::from(source_height);
    let target_width_64 = u64::from(target_width);
    let target_height_64 = u64::from(target_height);

    // The target is the tighter constraint on width when its aspect is narrower
    // than the source's; otherwise height is. Rounded to the nearest pixel and
    // clamped so integer rounding can never spill outside the frame.
    let (content_width, content_height) = if target_width_64 * source_height_64
        <= target_height_64 * source_width_64
    {
        let height = (source_height_64 * target_width_64 + source_width_64 / 2) / source_width_64;
        (target_width, height.clamp(1, target_height_64) as u32)
    } else {
        let width = (source_width_64 * target_height_64 + source_height_64 / 2) / source_height_64;
        (width.clamp(1, target_width_64) as u32, target_height)
    };

    let content = resample(image, content_width, content_height, filter);
    let mut canvas = RgbaImage::from_pixel(
        target_width,
        target_height,
        image::Rgba([color[0], color[1], color[2], alpha]),
    );
    let x = (target_width - content_width) / 2;
    let y = (target_height - content_height) / 2;
    imageops::overlay(&mut canvas, &content, i64::from(x), i64::from(y));
    canvas
}

/// The centred source rectangle that covers the target aspect without
/// stretching. A wider source loses columns, a taller source loses rows; equal
/// aspects keep the whole image.
pub(crate) fn cover_rect(
    source_width: u32,
    source_height: u32,
    target_width: u32,
    target_height: u32,
) -> (u32, u32, u32, u32) {
    let sw = u64::from(source_width);
    let sh = u64::from(source_height);
    let tw = u64::from(target_width);
    let th = u64::from(target_height);
    let (crop_width, crop_height) = if sw * th > tw * sh {
        // Source is wider: keep full height, take a centred width.
        let width = ((sh * tw + th / 2) / th).clamp(1, sw) as u32;
        (width, source_height)
    } else if sw * th < tw * sh {
        // Source is taller: keep full width, take a centred height.
        let height = ((sw * th + tw / 2) / tw).clamp(1, sh) as u32;
        (source_width, height)
    } else {
        (source_width, source_height)
    };
    // A locked ratio produces integer sides that miss the shape by a fraction
    // of a pixel. Cropping a single row or column for that difference is the
    // "resize shaved 1–2 px" defect: when the rectangle would lose at most one
    // pixel on one axis, keep the whole picture and let the resample absorb the
    // rounding instead.
    if source_width.saturating_sub(crop_width) <= 1
        && source_height.saturating_sub(crop_height) <= 1
    {
        return (0, 0, source_width, source_height);
    }
    (
        (source_width - crop_width) / 2,
        (source_height - crop_height) / 2,
        crop_width,
        crop_height,
    )
}

/// Adjust brightness, contrast, and saturation (`-1.0..=1.0`, `0.0` = identity)
/// matching Qt 6 `MultiEffect` order (contrast -> brightness -> saturation) while
/// preserving alpha untouched.
pub(crate) fn adjust_color(
    image: &RgbaImage,
    brightness: f64,
    contrast: f64,
    saturation: f64,
) -> RgbaImage {
    let b = brightness.clamp(-1.0, 1.0);
    let c = contrast.clamp(-1.0, 1.0);
    let s = saturation.clamp(-1.0, 1.0);
    let contrast_factor = if c >= 0.0 {
        1.0 / (1.0 - c * 0.999)
    } else {
        1.0 + c
    };
    let sat_factor = 1.0 + s;

    let mut out = image.clone();
    for px in out.pixels_mut() {
        let mut r = f64::from(px[0]) / 255.0;
        let mut g = f64::from(px[1]) / 255.0;
        let mut bl = f64::from(px[2]) / 255.0;

        // Contrast around mid-grey (0.5)
        r = (r - 0.5) * contrast_factor + 0.5;
        g = (g - 0.5) * contrast_factor + 0.5;
        bl = (bl - 0.5) * contrast_factor + 0.5;

        // Brightness (linear additive, matching Qt Quick MultiEffect)
        r += b;
        g += b;
        bl += b;

        // Saturation around Rec.709 luma
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
        r = luma + (r - luma) * sat_factor;
        g = luma + (g - luma) * sat_factor;
        bl = luma + (bl - luma) * sat_factor;

        px[0] = (r.clamp(0.0, 1.0) * 255.0).round() as u8;
        px[1] = (g.clamp(0.0, 1.0) * 255.0).round() as u8;
        px[2] = (bl.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    out
}
