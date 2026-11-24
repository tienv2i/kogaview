//! Raster selection mask (`0..=255` alpha per canvas pixel) for `kogaview-editor`.
//!
//! Supports rectangle, anti-aliased ellipse, freehand lasso polygon, combine
//! modes (`Replace` / `Add` / `Subtract`), inversion, fast separable feathering,
//! tight bounding-box computation, and crisp marching-ants contour rendering.

use std::collections::VecDeque;
use std::path::Path;

use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use kogaview_protocol::SelectionMode;

use crate::codec::preview_dimensions;
use crate::PREVIEW_LONG_EDGE;

/// Canvas-sized selection mask (`0` = unselected, `255` = fully selected).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectionMask {
    pub width: u32,
    pub height: u32,
    pub alpha: Vec<u8>,
}

impl SelectionMask {
    pub fn empty(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            alpha: vec![0; (width as usize) * (height as usize)],
        }
    }

    pub fn all(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            alpha: vec![255; (width as usize) * (height as usize)],
        }
    }

    pub fn rect(canvas_w: u32, canvas_h: u32, x: i32, y: i32, w: u32, h: u32) -> Self {
        let mut mask = Self::empty(canvas_w, canvas_h);
        if w == 0 || h == 0 || canvas_w == 0 || canvas_h == 0 {
            return mask;
        }
        let x0 = x.max(0) as u32;
        let y0 = y.max(0) as u32;
        let x1 = (x as i64 + w as i64).clamp(0, canvas_w as i64) as u32;
        let y1 = (y as i64 + h as i64).clamp(0, canvas_h as i64) as u32;
        for py in y0..y1 {
            let row = (py as usize) * (canvas_w as usize);
            for px in x0..x1 {
                mask.alpha[row + px as usize] = 255;
            }
        }
        mask
    }

    pub fn ellipse(canvas_w: u32, canvas_h: u32, x: i32, y: i32, w: u32, h: u32) -> Self {
        let mut mask = Self::empty(canvas_w, canvas_h);
        if w == 0 || h == 0 || canvas_w == 0 || canvas_h == 0 {
            return mask;
        }
        let rx = w as f64 / 2.0;
        let ry = h as f64 / 2.0;
        let cx = x as f64 + rx;
        let cy = y as f64 + ry;
        let x0 = (x - 1).max(0) as u32;
        let y0 = (y - 1).max(0) as u32;
        let x1 = (x as i64 + w as i64 + 1).clamp(0, canvas_w as i64) as u32;
        let y1 = (y as i64 + h as i64 + 1).clamp(0, canvas_h as i64) as u32;
        // Anti-aliased edge band width in normalized radius units.
        let aa = 1.0 / rx.min(ry).max(1.0);
        for py in y0..y1 {
            let dy = (py as f64 + 0.5 - cy) / ry;
            let row = (py as usize) * (canvas_w as usize);
            for px in x0..x1 {
                let dx = (px as f64 + 0.5 - cx) / rx;
                let dist = (dx * dx + dy * dy).sqrt();
                if dist <= 1.0 - aa * 0.5 {
                    mask.alpha[row + px as usize] = 255;
                } else if dist < 1.0 + aa * 0.5 {
                    let t = ((1.0 + aa * 0.5 - dist) / aa).clamp(0.0, 1.0);
                    mask.alpha[row + px as usize] = (t * 255.0).round() as u8;
                }
            }
        }
        mask
    }

    /// Rasterize a closed polygon (even-odd scanline fill) for freehand Lasso.
    pub fn polygon(canvas_w: u32, canvas_h: u32, points: &[[f64; 2]]) -> Self {
        let mut mask = Self::empty(canvas_w, canvas_h);
        if points.len() < 3 || canvas_w == 0 || canvas_h == 0 {
            return mask;
        }
        let mut min_y = f64::INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for p in points {
            min_y = min_y.min(p[1]);
            max_y = max_y.max(p[1]);
        }
        let y0 = (min_y.floor() as i32).clamp(0, canvas_h as i32) as u32;
        let y1 = (max_y.ceil() as i32).clamp(0, canvas_h as i32) as u32;
        let mut intersections: Vec<f64> = Vec::with_capacity(32);
        let n = points.len();
        for py in y0..y1 {
            let scan_y = py as f64 + 0.5;
            intersections.clear();
            for i in 0..n {
                let a = points[i];
                let b = points[(i + 1) % n];
                if (a[1] <= scan_y && b[1] > scan_y) || (b[1] <= scan_y && a[1] > scan_y) {
                    let t = (scan_y - a[1]) / (b[1] - a[1]);
                    intersections.push(a[0] + t * (b[0] - a[0]));
                }
            }
            if intersections.len() < 2 {
                continue;
            }
            intersections.sort_by(|u, v| u.total_cmp(v));
            let row = (py as usize) * (canvas_w as usize);
            for pair in intersections.chunks_exact(2) {
                let x_start = (pair[0].floor() as i32).clamp(0, canvas_w as i32) as u32;
                let x_end = (pair[1].ceil() as i32).clamp(0, canvas_w as i32) as u32;
                for px in x_start..x_end {
                    mask.alpha[row + px as usize] = 255;
                }
            }
        }
        mask
    }

    /// Magic Wand selection starting from `(x, y)` on `image`.
    ///
    /// Matches pixels whose per-channel absolute difference from the seed pixel
    /// is within `tolerance` (`0..=255`). Fully transparent pixels (`alpha == 0`)
    /// match each other regardless of RGB values. When `contiguous` is true,
    /// performs a 4-connected BFS flood fill; otherwise matches globally.
    pub fn magic_wand(image: &RgbaImage, x: i32, y: i32, tolerance: u8, contiguous: bool) -> Self {
        let (w, h) = image.dimensions();
        let mut mask = Self::empty(w, h);
        if w == 0 || h == 0 || x < 0 || y < 0 || x >= w as i32 || y >= h as i32 {
            return mask;
        }
        let sx = x as u32;
        let sy = y as u32;
        let seed = image.get_pixel(sx, sy).0;
        let matches = |px: [u8; 4]| -> bool {
            if seed[3] == 0 && px[3] == 0 {
                return true;
            }
            seed[0].abs_diff(px[0]) <= tolerance
                && seed[1].abs_diff(px[1]) <= tolerance
                && seed[2].abs_diff(px[2]) <= tolerance
                && seed[3].abs_diff(px[3]) <= tolerance
        };

        let w_usize = w as usize;
        if !contiguous {
            for py in 0..h {
                let row = (py as usize) * w_usize;
                for px in 0..w {
                    if matches(image.get_pixel(px, py).0) {
                        mask.alpha[row + px as usize] = 255;
                    }
                }
            }
            return mask;
        }

        let mut visited = vec![false; w_usize * (h as usize)];
        let mut queue = VecDeque::with_capacity(1024);
        let start_idx = (sy as usize) * w_usize + (sx as usize);
        visited[start_idx] = true;
        mask.alpha[start_idx] = 255;
        queue.push_back((sx, sy));

        while let Some((cx, cy)) = queue.pop_front() {
            let neighbors = [
                (cx.wrapping_sub(1), cy, cx > 0),
                (cx + 1, cy, cx + 1 < w),
                (cx, cy.wrapping_sub(1), cy > 0),
                (cx, cy + 1, cy + 1 < h),
            ];
            for (nx, ny, ok) in neighbors {
                if !ok {
                    continue;
                }
                let idx = (ny as usize) * w_usize + (nx as usize);
                if visited[idx] {
                    continue;
                }
                visited[idx] = true;
                if matches(image.get_pixel(nx, ny).0) {
                    mask.alpha[idx] = 255;
                    queue.push_back((nx, ny));
                }
            }
        }
        mask
    }

    pub fn combine(&mut self, other: &SelectionMask, mode: SelectionMode) {
        if self.width != other.width || self.height != other.height {
            *self = other.clone();
            return;
        }
        match mode {
            SelectionMode::Replace => {
                self.alpha.copy_from_slice(&other.alpha);
            }
            SelectionMode::Add => {
                for (dst, &src) in self.alpha.iter_mut().zip(other.alpha.iter()) {
                    *dst = (*dst).max(src);
                }
            }
            SelectionMode::Subtract => {
                for (dst, &src) in self.alpha.iter_mut().zip(other.alpha.iter()) {
                    *dst = dst.saturating_sub(src);
                }
            }
            SelectionMode::Intersect => {
                for (dst, &src) in self.alpha.iter_mut().zip(other.alpha.iter()) {
                    *dst = (*dst).min(src);
                }
            }
        }
    }

    /// Translate the selection mask by `(dx, dy)` document pixels, clipping
    /// pixels shifted outside the canvas bounds. Returns `true` if moved.
    pub fn translate(&mut self, dx: i32, dy: i32) -> bool {
        if dx == 0 && dy == 0 {
            return false;
        }
        let w = self.width as i32;
        let h = self.height as i32;
        if w <= 0 || h <= 0 {
            return false;
        }
        let mut next = vec![0u8; self.alpha.len()];
        let dst_y_start = dy.max(0).min(h);
        let dst_y_end = (h + dy).max(0).min(h);
        let dst_x_start = dx.max(0).min(w);
        let dst_x_end = (w + dx).max(0).min(w);
        if dst_x_start < dst_x_end && dst_y_start < dst_y_end {
            let wu = self.width as usize;
            let count = (dst_x_end - dst_x_start) as usize;
            for ny in dst_y_start..dst_y_end {
                let sy = (ny - dy) as usize;
                let sx = (dst_x_start - dx) as usize;
                let dst_off = (ny as usize) * wu + (dst_x_start as usize);
                let src_off = sy * wu + sx;
                next[dst_off..dst_off + count]
                    .copy_from_slice(&self.alpha[src_off..src_off + count]);
            }
        }
        self.alpha = next;
        true
    }

    pub fn invert(&mut self) {
        for a in &mut self.alpha {
            *a = 255 - *a;
        }
    }

    /// Fast 2-pass separable box blur approximating a Gaussian feather.
    pub fn feather(&mut self, radius: u32) {
        let r = radius.min(64) as i32;
        if r <= 0 || self.width == 0 || self.height == 0 {
            return;
        }
        let w = self.width as usize;
        let h = self.height as usize;
        let mut tmp = vec![0u8; w * h];
        for _ in 0..2 {
            // Horizontal pass
            for y in 0..h {
                let row = y * w;
                let mut acc: u32 = 0;
                let mut count: u32 = 0;
                for x in 0..=(r as usize).min(w - 1) {
                    acc += u32::from(self.alpha[row + x]);
                    count += 1;
                }
                for x in 0..w {
                    tmp[row + x] = (acc / count.max(1)) as u8;
                    let add_x = x as i32 + r + 1;
                    if (add_x as usize) < w {
                        acc += u32::from(self.alpha[row + add_x as usize]);
                        count += 1;
                    }
                    let rem_x = x as i32 - r;
                    if rem_x >= 0 {
                        acc -= u32::from(self.alpha[row + rem_x as usize]);
                        count -= 1;
                    }
                }
            }
            // Vertical pass
            for x in 0..w {
                let mut acc: u32 = 0;
                let mut count: u32 = 0;
                for y in 0..=(r as usize).min(h - 1) {
                    acc += u32::from(tmp[y * w + x]);
                    count += 1;
                }
                for y in 0..h {
                    self.alpha[y * w + x] = (acc / count.max(1)) as u8;
                    let add_y = y as i32 + r + 1;
                    if (add_y as usize) < h {
                        acc += u32::from(tmp[add_y as usize * w + x]);
                        count += 1;
                    }
                    let rem_y = y as i32 - r;
                    if rem_y >= 0 {
                        acc -= u32::from(tmp[rem_y as usize * w + x]);
                        count -= 1;
                    }
                }
            }
        }
    }

    #[inline]
    pub fn alpha_at(&self, x: i32, y: i32) -> u8 {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            return 0;
        }
        self.alpha[(y as usize) * (self.width as usize) + (x as usize)]
    }

    pub fn bounds(&self) -> Option<(u32, u32, u32, u32)> {
        let w = self.width as usize;
        let h = self.height as usize;
        let mut min_x = w;
        let mut min_y = h;
        let mut max_x = 0usize;
        let mut max_y = 0usize;
        let mut found = false;
        for y in 0..h {
            let row = y * w;
            for x in 0..w {
                if self.alpha[row + x] > 0 {
                    found = true;
                    if x < min_x {
                        min_x = x;
                    }
                    if x > max_x {
                        max_x = x;
                    }
                    if y < min_y {
                        min_y = y;
                    }
                    if y > max_y {
                        max_y = y;
                    }
                }
            }
        }
        if !found {
            return None;
        }
        Some((
            min_x as u32,
            min_y as u32,
            (max_x - min_x + 1) as u32,
            (max_y - min_y + 1) as u32,
        ))
    }

    pub fn is_empty(&self) -> bool {
        !self.alpha.iter().any(|&a| a > 0)
    }

    /// Render a preview-resolution RGBA alpha mask (`[255, 255, 255, alpha]`)
    /// so QML GPU effects can clip live Brush/Eraser stroke previews to the exact
    /// selection shape (including feathering) at 60 fps.
    pub fn render_mask_image(&self) -> RgbaImage {
        const MAX_MASK_EDGE: u32 = 1400;
        let (pw, ph) = if self.width.max(self.height) > MAX_MASK_EDGE {
            let scale = MAX_MASK_EDGE as f64 / self.width.max(self.height) as f64;
            (
                ((self.width as f64 * scale).round() as u32).max(1),
                ((self.height as f64 * scale).round() as u32).max(1),
            )
        } else {
            (self.width.max(1), self.height.max(1))
        };
        let sx = self.width as f64 / pw as f64;
        let sy = self.height as f64 / ph as f64;
        let mut raw = vec![0u8; (pw as usize) * (ph as usize) * 4];
        let pwu = pw as usize;
        for y in 0..ph {
            let oy = (((y as f64 + 0.5) * sy).floor() as usize).min(self.height as usize - 1);
            let src_row = oy * (self.width as usize);
            let dst_row = (y as usize) * pwu * 4;
            for x in 0..pw {
                let ox = (((x as f64 + 0.5) * sx).floor() as usize).min(self.width as usize - 1);
                let a = self.alpha[src_row + ox];
                if a > 0 {
                    let di = dst_row + (x as usize) * 4;
                    raw[di] = 255;
                    raw[di + 1] = 255;
                    raw[di + 2] = 255;
                    raw[di + 3] = a;
                }
            }
        }
        RgbaImage::from_raw(pw, ph, raw).expect("render_mask_image buffer size")
    }

    /// Render a crisp Krita-style marching-ants dashed black/white contour
    /// `RgbaImage` matching the preview scale (`PREVIEW_LONG_EDGE`).
    pub fn render_overlay_image(&self) -> RgbaImage {
        self.render_overlay_image_phase(false)
    }

    /// Render marching-ants contour with alternating `phase` (`false`/`true`)
    /// so QML can animate crisp Krita marching ants at zero CPU cost.
    pub fn render_overlay_image_phase(&self, phase: bool) -> RgbaImage {
        let (pw, ph) = if self.width.max(self.height) > PREVIEW_LONG_EDGE {
            preview_dimensions(self.width, self.height)
        } else {
            (self.width.max(1), self.height.max(1))
        };
        let mut out = RgbaImage::from_pixel(pw, ph, Rgba([0, 0, 0, 0]));
        let sx = self.width as f64 / pw as f64;
        let sy = self.height as f64 / ph as f64;

        let sampled = |x: i32, y: i32| -> bool {
            if x < 0 || y < 0 || x >= pw as i32 || y >= ph as i32 {
                return false;
            }
            let ox = ((x as f64 + 0.5) * sx).floor() as i32;
            let oy = ((y as f64 + 0.5) * sy).floor() as i32;
            self.alpha_at(ox, oy) >= 128
        };

        // Crisp Krita-style fine contour (1–2 px, never overly chunky) with 6–10 px dashes.
        let stroke = if pw.max(ph) >= 1100 { 2 } else { 1 };
        let dash = (stroke * 5).max(6);
        let phase_bit: i32 = if phase { 1 } else { 0 };

        let mut edges: Vec<(i32, i32)> = Vec::new();
        for y in 0..ph as i32 {
            for x in 0..pw as i32 {
                if !sampled(x, y) {
                    continue;
                }
                let is_edge = !sampled(x - 1, y)
                    || !sampled(x + 1, y)
                    || !sampled(x, y - 1)
                    || !sampled(x, y + 1);
                if is_edge {
                    edges.push((x, y));
                }
            }
        }
        let pw_i = pw as i32;
        let ph_i = ph as i32;
        for (ex, ey) in edges {
            for dy in 0..stroke {
                let ny = ey + dy;
                if ny < 0 || ny >= ph_i {
                    continue;
                }
                for dx in 0..stroke {
                    let nx = ex + dx;
                    if nx < 0 || nx >= pw_i {
                        continue;
                    }
                    let stripe = (((nx + ny) / dash) & 1) == phase_bit;
                    let px = if stripe {
                        Rgba([255, 255, 255, 255])
                    } else {
                        Rgba([20, 20, 20, 255])
                    };
                    out.put_pixel(nx as u32, ny as u32, px);
                }
            }
        }
        out
    }

    /// Render Krita-style translucent red mask overlay covering unselected pixels
    /// (accurately visualizing feathered edges and complex shapes).
    pub fn render_red_overlay_image(&self) -> RgbaImage {
        const MAX_EDGE: u32 = 1400;
        let (pw, ph) = if self.width.max(self.height) > MAX_EDGE {
            let scale = MAX_EDGE as f64 / self.width.max(self.height) as f64;
            (
                ((self.width as f64 * scale).round() as u32).max(1),
                ((self.height as f64 * scale).round() as u32).max(1),
            )
        } else {
            (self.width.max(1), self.height.max(1))
        };
        let sx = self.width as f64 / pw as f64;
        let sy = self.height as f64 / ph as f64;
        let mut raw = vec![0u8; (pw as usize) * (ph as usize) * 4];
        let pwu = pw as usize;
        for y in 0..ph {
            let oy = (((y as f64 + 0.5) * sy).floor() as usize).min(self.height as usize - 1);
            let src_row = oy * (self.width as usize);
            let dst_row = (y as usize) * pwu * 4;
            for x in 0..pw {
                let ox = (((x as f64 + 0.5) * sx).floor() as usize).min(self.width as usize - 1);
                let inv = 255u32 - u32::from(self.alpha[src_row + ox]);
                if inv > 0 {
                    let di = dst_row + (x as usize) * 4;
                    raw[di] = 220;
                    raw[di + 1] = 38;
                    raw[di + 2] = 56;
                    raw[di + 3] = ((inv * 96 + 127) / 255) as u8;
                }
            }
        }
        RgbaImage::from_raw(pw, ph, raw).expect("render_red_overlay_image buffer size")
    }

    /// Render the marching-ants contour PNG to `path`.
    pub fn render_overlay_png(&self, path: &Path) -> Result<(), String> {
        let out = self.render_overlay_image();
        DynamicImage::ImageRgba8(out)
            .save_with_format(path, ImageFormat::Png)
            .map_err(|e| format!("could not write selection overlay {}: {e}", path.display()))
    }
}
