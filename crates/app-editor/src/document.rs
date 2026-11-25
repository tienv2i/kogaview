//! The working document: its layer stack, composited pixels, edit history and
//! the file it came from.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use image::RgbaImage;
use kogaview_protocol::{FlipAxis, UiText};

use crate::*;

/// Keep the undo stack bounded while preserving enough history for long sessions.
pub(crate) const MAX_HISTORY_STEPS: usize = 30;
pub(crate) const MAX_SNAPSHOT_BYTES: u64 = 256 * 1024 * 1024;

struct LiveStrokeSession {
    before_stack: LayerStack,
    stroke: kogaview_protocol::LiveStrokeKind,
    last_point: [f64; 2],
    editing_mask: bool,
}

/// Decode an image file into a working document. Runs on a worker thread.
pub fn open_document(path: &Path) -> Result<EditorDocument, String> {
    if ora::is_ora_path(path) {
        let stack = ora::read_ora(path)?;
        return Ok(EditorDocument::from_stack(path.to_path_buf(), stack));
    }
    let image = decode_rgba(path)?;
    Ok(EditorDocument::from_image(path.to_path_buf(), image))
}

/// How a step is undone. `Invert` re-applies a losslessly invertible operation
/// on a single-layer document; `Stack` restores the pre-edit [`LayerStack`]
/// (copy-on-write via `Arc<RgbaImage>` so sibling layers cost 0 extra bytes).
pub(crate) enum Undo {
    Invert(EditOperation),
    Stack(LayerStack),
}

pub(crate) struct Step {
    operation: EditOperation,
    target: ApplyTarget,
    undo: Undo,
}

/// A decoded image (single or multi-layer) plus its edit history. The source
/// path is only used for labels and for re-opening; the document never writes
/// to it directly.
pub struct EditorDocument {
    source_path: PathBuf,
    /// Initial layer stack as opened, used by [`reset`](Self::reset).
    original_stack: LayerStack,
    /// The composited pixels as opened. Shared with `working` until the first
    /// edit, so an untouched document holds one buffer, not two.
    original: Arc<RgbaImage>,
    /// Current live layer stack.
    stack: LayerStack,
    /// Cached composited RGBA image matching `stack`.
    working: Arc<RgbaImage>,
    undo: Vec<Step>,
    redo: Vec<(EditOperation, ApplyTarget)>,
    snapshot_bytes: u64,
    /// The composited pixels as they are on disk at [`saved_path`], shared with
    /// `working` while they are identical.
    saved_pixels: Arc<RgbaImage>,
    /// Fingerprint of the source bytes as last seen by the document: at open,
    /// and after a save.
    stamped_source: Option<(u64, Option<std::time::SystemTime>)>,
    /// Where the working pixels are on disk: the source until a save moves it.
    saved_path: PathBuf,
    /// True when `working` is what `saved_path` holds.
    saved: bool,
    /// Optional active raster selection mask (`None` = no selection, 0 bytes).
    selection: Option<SelectionMask>,
    /// True once oldest undo steps have been evicted by `trim_history`.
    history_trimmed: bool,
    /// Active interactive live stroke (Brush/Eraser/Liquify) while mouse is held.
    live_stroke: Option<LiveStrokeSession>,
}

impl EditorDocument {
    /// Build a single-layer document from pixels that were already decoded.
    pub fn from_image(source_path: PathBuf, image: RgbaImage) -> Self {
        let image = Arc::new(image);
        let stack = LayerStack::from_single(Arc::clone(&image));
        Self::from_stack(source_path, stack)
    }

    /// Build a document from an existing [`LayerStack`] (e.g. OpenRaster `.ora`).
    pub fn from_stack(source_path: PathBuf, stack: LayerStack) -> Self {
        let composited = composite_stack(&stack);
        let source_stamp = file_stamp(&source_path);
        Self {
            saved_path: source_path.clone(),
            source_path,
            stamped_source: source_stamp,
            saved_pixels: Arc::clone(&composited),
            original: Arc::clone(&composited),
            original_stack: stack.clone(),
            working: composited,
            stack,
            undo: Vec::new(),
            redo: Vec::new(),
            snapshot_bytes: 0,
            saved: true,
            selection: None,
            history_trimmed: false,
            live_stroke: None,
        }
    }

    pub fn history_trimmed(&self) -> bool {
        self.history_trimmed
    }

    pub fn is_modified_from_original(&self) -> bool {
        self.can_undo() || self.history_trimmed || !Arc::ptr_eq(&self.working, &self.original)
    }

    pub fn selection(&self) -> Option<&SelectionMask> {
        self.selection.as_ref()
    }

    pub fn selection_bounds(&self) -> Option<[u32; 4]> {
        self.selection
            .as_ref()
            .and_then(|s| s.bounds())
            .map(|(x, y, w, h)| [x, y, w, h])
    }

    pub fn apply_selection_mask(
        &mut self,
        mut incoming: SelectionMask,
        mode: kogaview_protocol::SelectionMode,
        feather: u32,
    ) -> bool {
        if feather > 0 {
            incoming.feather(feather);
        }
        match (&mut self.selection, mode) {
            (Some(existing), kogaview_protocol::SelectionMode::Add) => {
                existing.combine(&incoming, kogaview_protocol::SelectionMode::Add);
            }
            (Some(existing), kogaview_protocol::SelectionMode::Subtract) => {
                existing.combine(&incoming, kogaview_protocol::SelectionMode::Subtract);
                if existing.is_empty() {
                    self.selection = None;
                }
            }
            (Some(existing), kogaview_protocol::SelectionMode::Intersect) => {
                existing.combine(&incoming, kogaview_protocol::SelectionMode::Intersect);
                if existing.is_empty() {
                    self.selection = None;
                }
            }
            (
                None,
                kogaview_protocol::SelectionMode::Subtract
                | kogaview_protocol::SelectionMode::Intersect,
            ) => return false,
            _ => {
                if incoming.is_empty() {
                    self.selection = None;
                } else {
                    self.selection = Some(incoming);
                }
            }
        }
        true
    }

    pub fn select_all(&mut self) {
        let (w, h) = self.dimensions();
        self.selection = Some(SelectionMask::all(w, h));
    }

    pub fn clear_selection(&mut self) -> bool {
        self.selection.take().is_some()
    }

    /// Translate the active selection boundary by `(dx, dy)` without moving image pixels.
    pub fn move_selection(&mut self, dx: i32, dy: i32) -> bool {
        let Some(mask) = self.selection.as_mut() else {
            return false;
        };
        if !mask.translate(dx, dy) {
            return false;
        }
        if mask.is_empty() {
            self.selection = None;
        }
        true
    }

    pub fn invert_selection(&mut self) -> bool {
        let (w, h) = self.dimensions();
        match &mut self.selection {
            Some(mask) => {
                mask.invert();
                if mask.is_empty() {
                    self.selection = None;
                }
                true
            }
            None => {
                self.selection = Some(SelectionMask::all(w, h));
                true
            }
        }
    }

    pub fn modify_selection(
        &mut self,
        op: kogaview_protocol::SelectionModifyOp,
        amount: u32,
    ) -> bool {
        let Some(sel) = &mut self.selection else {
            return false;
        };
        let amt = amount.clamp(1, 64);
        match op {
            kogaview_protocol::SelectionModifyOp::Grow => sel.morph(amt, true),
            kogaview_protocol::SelectionModifyOp::Shrink => sel.morph(amt, false),
            kogaview_protocol::SelectionModifyOp::Border => sel.border(amt),
            kogaview_protocol::SelectionModifyOp::Feather => sel.feather(amt),
            kogaview_protocol::SelectionModifyOp::Smooth => sel.smooth(amt),
        }
        if sel.is_empty() {
            self.selection = None;
        }
        true
    }

    /// Clear pixels inside the active selection on the active layer (undoable).
    pub fn selection_delete(&mut self) -> Result<bool, UiText> {
        let Some(sel) = self.selection.clone() else {
            return Ok(false);
        };
        let active = self.stack.active_layer();
        if active.locked {
            return Err(UiText::new("layer_locked"));
        }
        if !active.visible {
            return Err(UiText::new("layer_hidden"));
        }
        let before = self.stack.clone();
        let ox = active.offset_x;
        let oy = active.offset_y;
        let mut next = (*active.pixels).clone();
        let (lw, lh) = next.dimensions();
        let mut touched = false;
        for y in 0..lh {
            for x in 0..lw {
                let m = sel.alpha_at(x as i32 + ox, y as i32 + oy);
                if m == 0 {
                    continue;
                }
                let p = next.get_pixel(x, y).0;
                if p[3] == 0 {
                    continue;
                }
                let keep = 1.0 - (m as f32 / 255.0);
                let new_a = (p[3] as f32 * keep).round().clamp(0.0, 255.0) as u8;
                next.put_pixel(x, y, image::Rgba([p[0], p[1], p[2], new_a]));
                touched = true;
            }
        }
        if !touched {
            return Ok(false);
        }
        let op = EditOperation::AiResult {
            label: UiText::new("selection_delete"),
            pixels: Arc::new(next),
        };
        self.stack.active_layer_mut().pixels = match &op {
            EditOperation::AiResult { pixels, .. } => Arc::clone(pixels),
            _ => unreachable!(),
        };
        self.push(op, ApplyTarget::ActiveLayer, before);
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    /// Clear all pixels on the active layer to transparent (used by Cut when
    /// no selection is active on a single-layer document).
    pub fn clear_active_layer(&mut self) -> Result<bool, UiText> {
        let active = self.stack.active_layer();
        if active.locked {
            return Err(UiText::new("layer_locked"));
        }
        if active.is_empty() {
            return Ok(false);
        }
        let before = self.stack.clone();
        let (lw, lh) = active.dimensions();
        let blank = Arc::new(RgbaImage::from_pixel(lw, lh, image::Rgba([0, 0, 0, 0])));
        let op = EditOperation::AiResult {
            label: UiText::new("selection_delete"),
            pixels: Arc::clone(&blank),
        };
        self.stack.active_layer_mut().pixels = blank;
        self.push(op, ApplyTarget::ActiveLayer, before);
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    /// Fill the active selection on the active layer with `color` at `opacity` (undoable).
    pub fn selection_fill(&mut self, color: [u8; 3], opacity: f32) -> Result<bool, UiText> {
        let Some(sel) = self.selection.clone() else {
            return Ok(false);
        };
        let active = self.stack.active_layer();
        if active.locked {
            return Err(UiText::new("layer_locked"));
        }
        if !active.visible {
            return Err(UiText::new("layer_hidden"));
        }
        let opacity = opacity.clamp(0.01, 1.0);
        let before = self.stack.clone();
        let ox = active.offset_x;
        let oy = active.offset_y;
        let mut next = (*active.pixels).clone();
        let (lw, lh) = next.dimensions();
        let mut touched = false;
        for y in 0..lh {
            for x in 0..lw {
                let m = sel.alpha_at(x as i32 + ox, y as i32 + oy);
                if m == 0 {
                    continue;
                }
                let sa = (m as f32 / 255.0) * opacity;
                let dst = next.get_pixel(x, y).0;
                let da = dst[3] as f32 / 255.0;
                let out_a = sa + da * (1.0 - sa);
                if out_a <= 1e-6 {
                    continue;
                }
                let blend = |sc: u8, dc: u8| -> u8 {
                    let v = (sc as f32 * sa + dc as f32 * da * (1.0 - sa)) / out_a;
                    v.round().clamp(0.0, 255.0) as u8
                };
                next.put_pixel(
                    x,
                    y,
                    image::Rgba([
                        blend(color[0], dst[0]),
                        blend(color[1], dst[1]),
                        blend(color[2], dst[2]),
                        (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
                    ]),
                );
                touched = true;
            }
        }
        if !touched {
            return Ok(false);
        }
        let op = EditOperation::AiResult {
            label: UiText::new("selection_fill"),
            pixels: Arc::new(next),
        };
        self.stack.active_layer_mut().pixels = match &op {
            EditOperation::AiResult { pixels, .. } => Arc::clone(pixels),
            _ => unreachable!(),
        };
        self.push(op, ApplyTarget::ActiveLayer, before);
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    /// Stroke the boundary of the active selection on the active layer (undoable).
    pub fn selection_stroke(
        &mut self,
        color: [u8; 3],
        width: u32,
        position: kogaview_protocol::StrokePosition,
        opacity: f32,
    ) -> Result<bool, UiText> {
        let Some(sel) = self.selection.clone() else {
            return Ok(false);
        };
        let active = self.stack.active_layer();
        if active.locked {
            return Err(UiText::new("layer_locked"));
        }
        if !active.visible {
            return Err(UiText::new("layer_hidden"));
        }
        let width = width.clamp(1, 200);
        let opacity = opacity.clamp(0.01, 1.0);
        let (outer, inner) = match position {
            kogaview_protocol::StrokePosition::Inside => {
                let mut inn = sel.clone();
                inn.morph(width, false);
                (sel.clone(), inn)
            }
            kogaview_protocol::StrokePosition::Outside => {
                let mut out = sel.clone();
                out.morph(width, true);
                (out, sel.clone())
            }
            kogaview_protocol::StrokePosition::Center => {
                let half_out = (width + 1) / 2;
                let half_in = width / 2;
                let mut out = sel.clone();
                if half_out > 0 {
                    out.morph(half_out, true);
                }
                let mut inn = sel.clone();
                if half_in > 0 {
                    inn.morph(half_in, false);
                }
                (out, inn)
            }
        };
        let before = self.stack.clone();
        let ox = active.offset_x;
        let oy = active.offset_y;
        let mut next = (*active.pixels).clone();
        let (lw, lh) = next.dimensions();
        let mut touched = false;
        for y in 0..lh {
            for x in 0..lw {
                let dx = x as i32 + ox;
                let dy = y as i32 + oy;
                let m = outer
                    .alpha_at(dx, dy)
                    .saturating_sub(inner.alpha_at(dx, dy));
                if m == 0 {
                    continue;
                }
                let sa = (m as f32 / 255.0) * opacity;
                let dst = next.get_pixel(x, y).0;
                let da = dst[3] as f32 / 255.0;
                let out_a = sa + da * (1.0 - sa);
                if out_a <= 1e-6 {
                    continue;
                }
                let blend = |sc: u8, dc: u8| -> u8 {
                    let v = (sc as f32 * sa + dc as f32 * da * (1.0 - sa)) / out_a;
                    v.round().clamp(0.0, 255.0) as u8
                };
                next.put_pixel(
                    x,
                    y,
                    image::Rgba([
                        blend(color[0], dst[0]),
                        blend(color[1], dst[1]),
                        blend(color[2], dst[2]),
                        (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
                    ]),
                );
                touched = true;
            }
        }
        if !touched {
            return Ok(false);
        }
        let op = EditOperation::AiResult {
            label: UiText::new("selection_stroke"),
            pixels: Arc::new(next),
        };
        self.stack.active_layer_mut().pixels = match &op {
            EditOperation::AiResult { pixels, .. } => Arc::clone(pixels),
            _ => unreachable!(),
        };
        self.push(op, ApplyTarget::ActiveLayer, before);
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    /// Apply a Liquify warp stroke on the active layer (undoable).
    pub fn liquify_stroke(
        &mut self,
        points: &[[f64; 2]],
        mode: kogaview_protocol::LiquifyMode,
        radius: f32,
        strength: f32,
    ) -> Result<bool, UiText> {
        if points.is_empty() {
            return Ok(false);
        }
        let active = self.stack.active_layer();
        if active.locked {
            return Err(UiText::new("layer_locked"));
        }
        if !active.visible {
            return Err(UiText::new("layer_hidden"));
        }
        let before = self.stack.clone();
        let next = crate::pixels::liquify_stroke(
            &active.pixels,
            points,
            mode,
            radius,
            strength,
            self.selection.as_ref(),
            (active.offset_x, active.offset_y),
        );
        let op = EditOperation::AiResult {
            label: UiText::new("liquify"),
            pixels: Arc::new(next),
        };
        self.stack.active_layer_mut().pixels = match &op {
            EditOperation::AiResult { pixels, .. } => Arc::clone(pixels),
            _ => unreachable!(),
        };
        self.push(op, ApplyTarget::ActiveLayer, before);
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    /// Begin an interactive live stroke session (Brush/Eraser/Liquify).
    pub fn live_stroke_begin(
        &mut self,
        stroke: kogaview_protocol::LiveStrokeKind,
        x: f64,
        y: f64,
    ) -> Result<bool, UiText> {
        if self.live_stroke.is_some() {
            let _ = self.live_stroke_end(true);
        }
        let active = self.stack.active_layer();
        if active.locked {
            return Err(UiText::new("layer_locked"));
        }
        if !active.visible {
            return Err(UiText::new("layer_hidden"));
        }
        let editing_mask = active.editing_mask && active.mask.is_some();
        let before_stack = self.stack.clone();
        self.live_stroke = Some(LiveStrokeSession {
            before_stack,
            stroke,
            last_point: [x, y],
            editing_mask,
        });
        self.apply_live_segment(&[[x, y]]);
        self.working = composite_stack(&self.stack);
        Ok(true)
    }

    /// Apply incremental pointer samples to the active live stroke session.
    pub fn live_stroke_step(&mut self, points: &[[f64; 2]]) -> Result<bool, UiText> {
        if points.is_empty() {
            return Ok(false);
        }
        let Some(last) = self.live_stroke.as_ref().map(|s| s.last_point) else {
            return Ok(false);
        };
        let mut seg = Vec::with_capacity(points.len() + 1);
        seg.push(last);
        seg.extend_from_slice(points);
        if let Some(session) = self.live_stroke.as_mut() {
            if let Some(&tail) = points.last() {
                session.last_point = tail;
            }
        }
        self.apply_live_segment(&seg);
        self.working = composite_stack(&self.stack);
        Ok(true)
    }

    /// Commit (`commit == true`) as one Undo step or cancel (`commit == false`)
    /// the active live stroke session.
    pub fn live_stroke_end(&mut self, commit: bool) -> Result<bool, UiText> {
        let Some(session) = self.live_stroke.take() else {
            return Ok(false);
        };
        if !commit {
            self.stack = session.before_stack;
            self.working = composite_stack(&self.stack);
            return Ok(true);
        }
        let label = match &session.stroke {
            kogaview_protocol::LiveStrokeKind::Paint { erase, .. } => {
                if session.editing_mask {
                    UiText::new("mask_paint")
                } else if *erase {
                    UiText::new("eraser")
                } else {
                    UiText::new("brush")
                }
            }
            kogaview_protocol::LiveStrokeKind::Liquify { .. } => UiText::new("liquify"),
        };
        let op = EditOperation::AiResult {
            label,
            pixels: Arc::clone(&self.stack.active_layer().pixels),
        };
        self.push(op, ApplyTarget::ActiveLayer, session.before_stack);
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    fn apply_live_segment(&mut self, points: &[[f64; 2]]) {
        let Some(session) = self.live_stroke.as_ref() else {
            return;
        };
        let stroke = session.stroke.clone();
        let editing_mask = session.editing_mask;
        let sel = self.selection.clone();
        let active = self.stack.active_layer_mut();
        let ox = active.offset_x;
        let oy = active.offset_y;

        match stroke {
            kogaview_protocol::LiveStrokeKind::Paint {
                color,
                radius,
                opacity,
                erase,
                brush,
            } => {
                let local_pts: Vec<[f64; 2]> = points
                    .iter()
                    .map(|p| [p[0] - ox as f64, p[1] - oy as f64])
                    .collect();
                if editing_mask {
                    if let Some(mask_arc) = active.mask.as_ref() {
                        let (mw, mh) = active.pixels.dimensions();
                        let mut rgba = RgbaImage::new(mw, mh);
                        for y in 0..mh {
                            for x in 0..mw {
                                let idx = (y as usize) * (mw as usize) + (x as usize);
                                let v = mask_arc.get(idx).copied().unwrap_or(255);
                                rgba.put_pixel(x, y, image::Rgba([v, v, v, 255]));
                            }
                        }
                        let mask_color = if erase { [0, 0, 0] } else { color };
                        let painted = crate::pixels::paint_stroke_with_brush(
                            &rgba, &local_pts, mask_color, radius, opacity, false, brush,
                        );
                        let mut next_mask = (**mask_arc).clone();
                        next_mask.resize((mw as usize) * (mh as usize), 255);
                        for y in 0..mh {
                            for x in 0..mw {
                                let sf = match &sel {
                                    Some(s) => {
                                        s.alpha_at(x as i32 + ox, y as i32 + oy) as f32 / 255.0
                                    }
                                    None => 1.0,
                                };
                                if sf <= 1e-4 {
                                    continue;
                                }
                                let idx = (y as usize) * (mw as usize) + (x as usize);
                                let p = painted.get_pixel(x, y).0;
                                let lum = ((0.299 * p[0] as f32
                                    + 0.587 * p[1] as f32
                                    + 0.114 * p[2] as f32)
                                    .round()
                                    .clamp(0.0, 255.0))
                                    as u8;
                                let orig = next_mask[idx];
                                let blended = (orig as f32 * (1.0 - sf) + lum as f32 * sf)
                                    .round()
                                    .clamp(0.0, 255.0)
                                    as u8;
                                next_mask[idx] = blended;
                            }
                        }
                        active.mask = Some(Arc::new(next_mask));
                    }
                } else {
                    let prev = Arc::clone(&active.pixels);
                    let mut painted = crate::pixels::paint_stroke_with_brush(
                        &prev, &local_pts, color, radius, opacity, erase, brush,
                    );
                    if let Some(s) = &sel {
                        let (lw, lh) = painted.dimensions();
                        for y in 0..lh {
                            for x in 0..lw {
                                let m = s.alpha_at(x as i32 + ox, y as i32 + oy);
                                if m == 255 {
                                    continue;
                                }
                                if m == 0 {
                                    painted.put_pixel(x, y, *prev.get_pixel(x, y));
                                } else {
                                    let f = m as f32 / 255.0;
                                    let a = prev.get_pixel(x, y).0;
                                    let b = painted.get_pixel(x, y).0;
                                    painted.put_pixel(
                                        x,
                                        y,
                                        image::Rgba([
                                            (a[0] as f32 * (1.0 - f) + b[0] as f32 * f).round()
                                                as u8,
                                            (a[1] as f32 * (1.0 - f) + b[1] as f32 * f).round()
                                                as u8,
                                            (a[2] as f32 * (1.0 - f) + b[2] as f32 * f).round()
                                                as u8,
                                            (a[3] as f32 * (1.0 - f) + b[3] as f32 * f).round()
                                                as u8,
                                        ]),
                                    );
                                }
                            }
                        }
                    }
                    active.pixels = Arc::new(painted);
                }
            }
            kogaview_protocol::LiveStrokeKind::Liquify {
                mode,
                radius,
                strength,
            } => {
                let warped = crate::pixels::liquify_stroke(
                    &active.pixels,
                    points,
                    mode,
                    radius,
                    strength,
                    sel.as_ref(),
                    (ox, oy),
                );
                active.pixels = Arc::new(warped);
            }
        }
    }

    /// Duplicate pixels inside the active selection from the active layer into a
    /// tightly cropped new layer above it (`Ctrl+J`).
    pub fn selection_duplicate_layer(&mut self) -> Result<bool, UiText> {
        let Some(sel) = self.selection.clone() else {
            return Ok(false);
        };
        let Some((bx, by, bw, bh)) = sel.bounds() else {
            return Ok(false);
        };
        let active = self.stack.active_layer();
        let ox = active.offset_x;
        let oy = active.offset_y;
        let (lw, lh) = active.dimensions();
        let mut extracted = RgbaImage::from_pixel(bw, bh, image::Rgba([0, 0, 0, 0]));
        for dy in 0..bh {
            let cy = by as i32 + dy as i32;
            let ly = cy - oy;
            if ly < 0 || ly >= lh as i32 {
                continue;
            }
            for dx in 0..bw {
                let cx = bx as i32 + dx as i32;
                let lx = cx - ox;
                if lx < 0 || lx >= lw as i32 {
                    continue;
                }
                let m = sel.alpha_at(cx, cy);
                if m == 0 {
                    continue;
                }
                let p = active.pixels.get_pixel(lx as u32, ly as u32).0;
                let new_a = ((u32::from(p[3]) * u32::from(m) + 127) / 255) as u8;
                extracted.put_pixel(dx, dy, image::Rgba([p[0], p[1], p[2], new_a]));
            }
        }
        self.apply_layer_op(LayerOperation::AddImage {
            name: "Selection Copy".to_owned(),
            offset_x: bx as i32,
            offset_y: by as i32,
            pixels: Arc::new(extracted),
        })
    }

    /// Crop the document to the active selection's tight bounding box and clear selection.
    pub fn selection_crop(&mut self) -> Result<bool, UiText> {
        let Some(sel) = self.selection.as_ref() else {
            return Ok(false);
        };
        let Some((bx, by, bw, bh)) = sel.bounds() else {
            return Ok(false);
        };
        let changed = self.apply_with_target(
            EditOperation::Crop {
                x: bx as i32,
                y: by as i32,
                width: bw,
                height: bh,
                fill: None,
                fill_alpha: 255,
            },
            ApplyTarget::WholeImage,
        )?;
        self.selection = None;
        Ok(changed)
    }

    /// Run Magic Wand selection from document pixel `(x, y)`.
    pub fn select_magic_wand(
        &mut self,
        x: i32,
        y: i32,
        tolerance: u8,
        contiguous: bool,
        sample_all_layers: bool,
        mode: kogaview_protocol::SelectionMode,
        feather: u32,
    ) {
        let mask = if sample_all_layers {
            SelectionMask::magic_wand(&self.working, x, y, tolerance, contiguous)
        } else {
            let (cw, ch) = self.dimensions();
            let mut canvas_layer = RgbaImage::from_pixel(cw, ch, image::Rgba([0, 0, 0, 0]));
            let active = self.stack.active_layer();
            let ox = active.offset_x;
            let oy = active.offset_y;
            let (lw, lh) = active.dimensions();
            for ly in 0..lh {
                let cy = oy + ly as i32;
                if cy < 0 || cy >= ch as i32 {
                    continue;
                }
                for lx in 0..lw {
                    let cx = ox + lx as i32;
                    if cx < 0 || cx >= cw as i32 {
                        continue;
                    }
                    canvas_layer.put_pixel(cx as u32, cy as u32, *active.pixels.get_pixel(lx, ly));
                }
            }
            SelectionMask::magic_wand(&canvas_layer, x, y, tolerance, contiguous)
        };
        self.apply_selection_mask(mask, mode, feather);
    }

    /// Extract pixels inside the active selection (masked & tightly cropped) from
    /// the active layer for system clipboard Copy/Cut. When no selection is active,
    /// extracts the active layer's full pixel buffer.
    pub fn extract_selection_image(&self) -> Result<RgbaImage, UiText> {
        let active = self.stack.active_layer();
        let Some(sel) = self.selection.as_ref() else {
            return Ok((*active.pixels).clone());
        };
        let Some((bx, by, bw, bh)) = sel.bounds() else {
            return Ok((*active.pixels).clone());
        };
        let ox = active.offset_x;
        let oy = active.offset_y;
        let (lw, lh) = active.dimensions();
        let mut extracted = RgbaImage::from_pixel(bw, bh, image::Rgba([0, 0, 0, 0]));
        for dy in 0..bh {
            let cy = by as i32 + dy as i32;
            let ly = cy - oy;
            if ly < 0 || ly >= lh as i32 {
                continue;
            }
            for dx in 0..bw {
                let cx = bx as i32 + dx as i32;
                let lx = cx - ox;
                if lx < 0 || lx >= lw as i32 {
                    continue;
                }
                let m = sel.alpha_at(cx, cy);
                if m == 0 {
                    continue;
                }
                let p = active.pixels.get_pixel(lx as u32, ly as u32).0;
                let new_a = ((u32::from(p[3]) * u32::from(m) + 127) / 255) as u8;
                extracted.put_pixel(dx, dy, image::Rgba([p[0], p[1], p[2], new_a]));
            }
        }
        Ok(extracted)
    }

    pub fn source_path(&self) -> &Path {
        &self.source_path
    }

    /// Original composited pixels as opened (immutable baseline for Reset / Restore brush).
    pub fn original_pixels(&self) -> Arc<RgbaImage> {
        Arc::clone(&self.original)
    }

    /// Layer-local baseline pixels for the active layer (falling back to document original).
    pub fn active_layer_original_pixels(&self) -> Arc<RgbaImage> {
        self.stack
            .active_layer()
            .original
            .as_ref()
            .map(Arc::clone)
            .unwrap_or_else(|| Arc::clone(&self.original))
    }

    pub fn stack(&self) -> &LayerStack {
        &self.stack
    }

    pub fn layers(&self) -> &[Layer] {
        &self.stack.layers
    }

    pub fn active_layer(&self) -> &Layer {
        self.stack.active_layer()
    }

    pub fn active_layer_id(&self) -> u64 {
        self.stack.active_layer_id
    }

    /// Document-wide solid canvas background underneath all layers (`None` = transparent).
    pub fn canvas_background(&self) -> Option<[u8; 3]> {
        self.stack.background
    }

    /// Return `(below_active, active_pixels, above_active)` for WYSIWYG
    /// per-layer live Transform previews on both single-layer and multi-layer documents.
    pub fn active_layer_split_previews(&self) -> (RgbaImage, Arc<RgbaImage>, RgbaImage) {
        let idx = self.stack.active_index();
        let below = crate::layer::composite_range(&self.stack, 0..idx);
        let active = Arc::clone(&self.stack.layers[idx].pixels);
        let above = crate::layer::composite_range(&self.stack, (idx + 1)..self.stack.layers.len());
        (below, active, above)
    }

    /// Return `(base_without_selection, floating_selection_patch)` directly at
    /// preview resolution (`<= 1400 px`) for instant 60 fps Transform previews
    /// even on 24–50 MP images, without cloning or compositing full-res buffers.
    pub fn selection_split_previews(&self) -> Option<(RgbaImage, RgbaImage)> {
        const MAX_PREVIEW_EDGE: u32 = 1400;
        let sel = self.selection.as_ref()?;
        let (bx, by, bw, bh) = sel.bounds()?;
        let (cw, ch) = self.dimensions();
        if cw == 0 || ch == 0 || bw == 0 || bh == 0 {
            return None;
        }
        let scale = if cw.max(ch) > MAX_PREVIEW_EDGE {
            MAX_PREVIEW_EDGE as f64 / cw.max(ch) as f64
        } else {
            1.0
        };
        let pw = ((cw as f64 * scale).round() as u32).max(1);
        let ph = ((ch as f64 * scale).round() as u32).max(1);
        let inv_x = cw as f64 / pw as f64;
        let inv_y = ch as f64 / ph as f64;

        let active_idx = self.stack.active_index();
        let active = &self.stack.layers[active_idx];
        let ox = active.offset_x;
        let oy = active.offset_y;
        let (lw, lh) = active.dimensions();

        // 1. Floating patch sampled directly at preview scale inside selection bounds.
        let fw = ((bw as f64 * scale).round() as u32).max(1);
        let fh = ((bh as f64 * scale).round() as u32).max(1);
        let f_inv_x = bw as f64 / fw as f64;
        let f_inv_y = bh as f64 / fh as f64;
        let mut floating = RgbaImage::from_pixel(fw, fh, image::Rgba([0, 0, 0, 0]));
        for py in 0..fh {
            let cy = by as i32 + ((py as f64 + 0.5) * f_inv_y).floor() as i32;
            let ly = cy - oy;
            if ly < 0 || ly >= lh as i32 {
                continue;
            }
            for px in 0..fw {
                let cx = bx as i32 + ((px as f64 + 0.5) * f_inv_x).floor() as i32;
                let lx = cx - ox;
                if lx < 0 || lx >= lw as i32 {
                    continue;
                }
                let m = sel.alpha_at(cx, cy);
                if m == 0 {
                    continue;
                }
                let src = active.pixels.get_pixel(lx as u32, ly as u32).0;
                if src[3] == 0 {
                    continue;
                }
                let a = ((u32::from(src[3]) * u32::from(m) + 127) / 255) as u8;
                floating.put_pixel(px, py, image::Rgba([src[0], src[1], src[2], a]));
            }
        }

        // 2. Preview-resolution base canvas: fast-sample `self.working` outside
        //    the selection bounds, and only recomposite punched-out pixels inside
        //    the projected selection rectangle!
        let mut base = RgbaImage::new(pw, ph);
        let working = self.working.as_ref();
        let (ww, wh) = working.dimensions();
        for py in 0..ph {
            let cy = (((py as f64 + 0.5) * inv_y).floor() as u32).min(wh.saturating_sub(1));
            for px in 0..pw {
                let cx = (((px as f64 + 0.5) * inv_x).floor() as u32).min(ww.saturating_sub(1));
                base.put_pixel(px, py, *working.get_pixel(cx, cy));
            }
        }

        let pbx0 = ((bx as f64 * scale).floor() as u32).min(pw);
        let pby0 = ((by as f64 * scale).floor() as u32).min(ph);
        let pbx1 = (((bx + bw) as f64 * scale).ceil() as u32).min(pw);
        let pby1 = (((by + bh) as f64 * scale).ceil() as u32).min(ph);
        let bg_px = match self.stack.background {
            Some([r, g, b]) => [r, g, b, 255u8],
            None => [0u8, 0, 0, 0],
        };
        let single_layer = self.stack.layers.len() == 1;

        for py in pby0..pby1 {
            let cy = ((py as f64 + 0.5) * inv_y).floor() as i32;
            for px in pbx0..pbx1 {
                let cx = ((px as f64 + 0.5) * inv_x).floor() as i32;
                let m = sel.alpha_at(cx, cy);
                if m == 0 {
                    continue;
                }
                if single_layer {
                    let lx = cx - ox;
                    let ly = cy - oy;
                    let rem = if active.visible
                        && active.opacity > 1e-4
                        && lx >= 0
                        && ly >= 0
                        && lx < lw as i32
                        && ly < lh as i32
                    {
                        let p = active.pixels.get_pixel(lx as u32, ly as u32).0;
                        let keep = 1.0 - (m as f32 / 255.0);
                        let a = (p[3] as f32 * keep * active.opacity)
                            .round()
                            .clamp(0.0, 255.0) as u8;
                        [p[0], p[1], p[2], a]
                    } else {
                        [0, 0, 0, 0]
                    };
                    if bg_px[3] == 0 {
                        base.put_pixel(px, py, image::Rgba(rem));
                    } else if rem[3] == 0 {
                        base.put_pixel(px, py, image::Rgba(bg_px));
                    } else {
                        let sa = rem[3] as f32 / 255.0;
                        let inv = 1.0 - sa;
                        let mix = |s: u8, d: u8| -> u8 {
                            (s as f32 * sa + d as f32 * inv).round().clamp(0.0, 255.0) as u8
                        };
                        base.put_pixel(
                            px,
                            py,
                            image::Rgba([
                                mix(rem[0], bg_px[0]),
                                mix(rem[1], bg_px[1]),
                                mix(rem[2], bg_px[2]),
                                255,
                            ]),
                        );
                    }
                } else {
                    // Multi-layer: recomposite only this single pixel across stack.
                    let mut out = bg_px;
                    for (idx, layer) in self.stack.layers.iter().enumerate() {
                        if !layer.visible || layer.opacity <= 1e-4 {
                            continue;
                        }
                        let lx = cx - layer.offset_x;
                        let ly = cy - layer.offset_y;
                        let (w, h) = layer.dimensions();
                        if lx < 0 || ly < 0 || lx >= w as i32 || ly >= h as i32 {
                            continue;
                        }
                        let mut p = layer.pixels.get_pixel(lx as u32, ly as u32).0;
                        if idx == active_idx {
                            let keep = 1.0 - (m as f32 / 255.0);
                            p[3] = (p[3] as f32 * keep).round().clamp(0.0, 255.0) as u8;
                        }
                        let sa = (p[3] as f32 / 255.0) * layer.opacity;
                        if sa <= 1e-5 {
                            continue;
                        }
                        let da = out[3] as f32 / 255.0;
                        let out_a = sa + da * (1.0 - sa);
                        if out_a <= 1e-5 {
                            continue;
                        }
                        let blend = |sc: u8, dc: u8| -> u8 {
                            ((sc as f32 * sa + dc as f32 * da * (1.0 - sa)) / out_a)
                                .round()
                                .clamp(0.0, 255.0) as u8
                        };
                        out = [
                            blend(p[0], out[0]),
                            blend(p[1], out[1]),
                            blend(p[2], out[2]),
                            (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
                        ];
                    }
                    base.put_pixel(px, py, image::Rgba(out));
                }
            }
        }
        Some((base, floating))
    }

    /// Fast WYSIWYG live preview for color filters (`AdjustColor` / `AdjustCurves`
    /// / `AdjustHsv` / `ColorBalance`) at `<= 960 px`, respecting `ActiveLayer` vs
    /// `WholeImage`, `canvas_background`, and any active `SelectionMask` in ~1–3 ms.
    pub fn preview_color_filter(
        &self,
        operation: &EditOperation,
        target: ApplyTarget,
    ) -> RgbaImage {
        const MAX_PREVIEW_EDGE: u32 = 960;
        let (cw, ch) = self.dimensions();
        if cw == 0 || ch == 0 {
            return RgbaImage::new(1, 1);
        }
        let scale = if cw.max(ch) > MAX_PREVIEW_EDGE {
            MAX_PREVIEW_EDGE as f64 / cw.max(ch) as f64
        } else {
            1.0
        };
        let pw = ((cw as f64 * scale).round() as u32).max(1);
        let ph = ((ch as f64 * scale).round() as u32).max(1);
        let step_x = ((cw as u64) << 16) / (pw as u64);
        let step_y = ((ch as u64) << 16) / (ph as u64);

        // Fast-path: single-layer document with zero offset and full canvas size.
        if self.is_simple_single_layer() {
            let src = self.stack.layers[0].pixels.as_ref();
            let raw = src.as_raw();
            let sw = cw as usize;
            let pwu = pw as usize;
            let mut small_raw = vec![0u8; pwu * (ph as usize) * 4];
            for py in 0..(ph as usize) {
                let sy =
                    ((((py as u64) * step_y + (step_y >> 1)) >> 16) as usize).min(ch as usize - 1);
                let srow = sy * sw;
                let drow = py * pwu * 4;
                for px in 0..pwu {
                    let sx = ((((px as u64) * step_x + (step_x >> 1)) >> 16) as usize).min(sw - 1);
                    let si = (srow + sx) * 4;
                    let di = drow + px * 4;
                    small_raw[di..di + 4].copy_from_slice(&raw[si..si + 4]);
                }
            }
            let small = RgbaImage::from_raw(pw, ph, small_raw).expect("preview buffer");
            let Ok(mut filtered) = render_operation(&small, operation) else {
                return small;
            };
            if let Some(sel) = &self.selection {
                let sraw = small.as_raw();
                let fraw = filtered.as_mut();
                for py in 0..(ph as usize) {
                    let cy =
                        ((((py as u64) * step_y + (step_y >> 1)) >> 16) as i32).min(ch as i32 - 1);
                    let drow = py * pwu * 4;
                    for px in 0..pwu {
                        let cx = ((((px as u64) * step_x + (step_x >> 1)) >> 16) as i32)
                            .min(cw as i32 - 1);
                        let m = sel.alpha_at(cx, cy);
                        if m == 255 {
                            continue;
                        }
                        let di = drow + px * 4;
                        if m == 0 {
                            fraw[di..di + 4].copy_from_slice(&sraw[di..di + 4]);
                        } else {
                            let mi = u32::from(m);
                            let inv = 255 - mi;
                            for c in 0..4 {
                                fraw[di + c] = ((u32::from(sraw[di + c]) * inv
                                    + u32::from(fraw[di + c]) * mi
                                    + 127)
                                    / 255) as u8;
                            }
                        }
                    }
                }
            }
            return filtered;
        }

        let inv_x = cw as f64 / pw as f64;
        let inv_y = ch as f64 / ph as f64;

        // Build a lightweight preview-resolution stack (only layers are downscaled).
        let active_idx = self.stack.active_index();
        let mut preview_layers = Vec::with_capacity(self.stack.layers.len());
        for (idx, layer) in self.stack.layers.iter().enumerate() {
            if !layer.visible || layer.opacity <= 1e-4 {
                continue;
            }
            let (lw, lh) = layer.dimensions();
            let plw = ((lw as f64 * scale).round() as u32).max(1);
            let plh = ((lh as f64 * scale).round() as u32).max(1);
            let l_inv_x = lw as f64 / plw as f64;
            let l_inv_y = lh as f64 / plh as f64;
            let mut small = RgbaImage::new(plw, plh);
            for py in 0..plh {
                let sy = (((py as f64 + 0.5) * l_inv_y).floor() as u32).min(lh.saturating_sub(1));
                for px in 0..plw {
                    let sx =
                        (((px as f64 + 0.5) * l_inv_x).floor() as u32).min(lw.saturating_sub(1));
                    small.put_pixel(px, py, *layer.pixels.get_pixel(sx, sy));
                }
            }
            let pox = (layer.offset_x as f64 * scale).round() as i32;
            let poy = (layer.offset_y as f64 * scale).round() as i32;
            let should_filter = target == ApplyTarget::WholeImage || idx == active_idx;
            if should_filter {
                if let Ok(mut filtered) = render_operation(&small, operation) {
                    if let Some(sel) = &self.selection {
                        for py in 0..plh {
                            let cy = (((py as i32 + poy) as f64 + 0.5) * inv_y).floor() as i32;
                            for px in 0..plw {
                                let cx = (((px as i32 + pox) as f64 + 0.5) * inv_x).floor() as i32;
                                let m = sel.alpha_at(cx, cy);
                                if m == 255 {
                                    continue;
                                }
                                let orig = small.get_pixel(px, py).0;
                                if m == 0 {
                                    filtered.put_pixel(px, py, image::Rgba(orig));
                                } else {
                                    let cur = filtered.get_pixel(px, py).0;
                                    let t = m as f32 / 255.0;
                                    let inv = 1.0 - t;
                                    let mix = |a: u8, b: u8| -> u8 {
                                        (a as f32 * inv + b as f32 * t).round().clamp(0.0, 255.0)
                                            as u8
                                    };
                                    filtered.put_pixel(
                                        px,
                                        py,
                                        image::Rgba([
                                            mix(orig[0], cur[0]),
                                            mix(orig[1], cur[1]),
                                            mix(orig[2], cur[2]),
                                            mix(orig[3], cur[3]),
                                        ]),
                                    );
                                }
                            }
                        }
                    }
                    small = filtered;
                }
            }
            let mut pl = Layer::new(layer.id, layer.name.clone(), Arc::new(small));
            pl.opacity = layer.opacity;
            pl.blend_mode = layer.blend_mode;
            pl.offset_x = pox;
            pl.offset_y = poy;
            preview_layers.push(pl);
        }

        let preview_stack = LayerStack {
            canvas_width: pw,
            canvas_height: ph,
            layers: preview_layers,
            active_layer_id: self.stack.active_layer_id,
            next_id: self.stack.next_id,
            background: self.stack.background,
        };
        (*crate::layer::composite_stack(&preview_stack)).clone()
    }

    /// Change the active layer without recording an undo step.
    pub fn select_layer(&mut self, id: u64) -> Result<bool, UiText> {
        self.stack.select(id)
    }

    /// Apply a structural or property [`LayerOperation`] (recorded in Undo/Redo).
    pub fn apply_layer_op(&mut self, op: LayerOperation) -> Result<bool, UiText> {
        self.apply_with_target(EditOperation::Layer(op), ApplyTarget::WholeImage)
    }

    /// Where a save would write, and whether the pixels are already there.
    pub fn save_target(&self) -> (&Path, bool) {
        (&self.saved_path, self.saved)
    }

    /// Record that the working pixels were written to `path`.
    pub fn mark_saved(&mut self, path: PathBuf) -> Result<(), String> {
        let format = SaveFormat::from_path(&path).ok_or_else(|| {
            format!(
                "cannot save as {}; use one of {}",
                path.display(),
                SaveFormat::CHOICES
            )
        })?;
        tracing::debug!(
            target: "kogaview::editor",
            path = %path.display(),
            format = format.label(),
            "editor document saved"
        );
        self.saved_path = path;
        self.saved_pixels = Arc::clone(&self.working);
        self.saved = true;
        Ok(())
    }

    /// True when an edit has not been written yet.
    pub fn has_unsaved_changes(&self) -> bool {
        !self.saved
    }

    /// Mark a newly created in-memory document as unsaved so Save is enabled
    /// immediately and leaving the Editor prompts to save.
    pub fn mark_unsaved(&mut self) {
        self.saved = false;
    }

    /// True when the source file no longer looks like it did when opened.
    pub fn source_changed(&self) -> bool {
        file_stamp(&self.source_path) != self.stamped_source
    }

    /// Record what the source looks like now, after Core wrote it itself.
    pub fn remember_source(&mut self) {
        self.stamped_source = file_stamp(&self.source_path);
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.stack.canvas_width, self.stack.canvas_height)
    }

    /// The current composited pixels, cheap to hand to a render thread.
    pub fn pixels(&self) -> Arc<RgbaImage> {
        Arc::clone(&self.working)
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn redo_count(&self) -> usize {
        self.redo.len()
    }

    /// Labels of the applied operations, oldest first.
    pub fn history(&self) -> Vec<UiText> {
        self.undo
            .iter()
            .map(|step| step.operation.label())
            .collect()
    }

    /// Labels of the redoable operations, next-to-redo first.
    pub fn redo_history(&self) -> Vec<UiText> {
        self.redo.iter().rev().map(|(op, _)| op.label()).collect()
    }

    /// Jump directly to `target_len` applied steps (`0` = original before all
    /// undo steps, `undo.len()` = current, `> undo.len()` = redo forward).
    pub fn jump_history(&mut self, target_len: usize) -> bool {
        let mut changed = false;
        while self.undo.len() > target_len {
            if !self.undo() {
                break;
            }
            changed = true;
        }
        while self.undo.len() < target_len && !self.redo.is_empty() {
            if !self.redo() {
                break;
            }
            changed = true;
        }
        changed
    }

    /// Apply an operation using the legacy default target (`ApplyTarget::WholeImage`).
    pub fn apply(&mut self, operation: EditOperation) -> Result<bool, UiText> {
        self.apply_with_target(operation, ApplyTarget::WholeImage)
    }

    /// Apply an operation targeting either the active layer, the whole image, or
    /// a new layer above the active layer.
    pub fn apply_with_target(
        &mut self,
        operation: EditOperation,
        target: ApplyTarget,
    ) -> Result<bool, UiText> {
        if let EditOperation::Layer(ref layer_op) = operation {
            let before = self.stack.clone();
            let changed = self.stack.apply_op(layer_op)?;
            if !changed {
                return Ok(false);
            }
            self.push(operation, target, before);
            self.working = composite_stack(&self.stack);
            self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels) && self.undo.is_empty();
            return Ok(true);
        }

        if self.is_noop(&operation, target)? {
            return Ok(false);
        }

        let before = self.stack.clone();
        self.execute_operation(&operation, target)?;
        self.push(operation, target, before);
        self.working = composite_stack(&self.stack);
        self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels);
        Ok(true)
    }

    /// Paste `image` as a new centered layer, handling oversized images per `mode`
    /// (`KeepOriginal`, `FitToCanvas`, or `ExpandCanvas`) in one atomic Undo step.
    pub fn paste_image_with_mode(
        &mut self,
        name: String,
        image: RgbaImage,
        mode: kogaview_protocol::PasteMode,
    ) -> Result<bool, UiText> {
        let before = self.stack.clone();
        let (cw, ch) = self.dimensions();
        let (iw, ih) = image.dimensions();

        let final_image = match mode {
            kogaview_protocol::PasteMode::FitToCanvas if iw > cw || ih > ch => {
                let scale = (cw as f64 / iw.max(1) as f64).min(ch as f64 / ih.max(1) as f64);
                let nw = ((iw as f64 * scale).round() as u32).max(1);
                let nh = ((ih as f64 * scale).round() as u32).max(1);
                image::imageops::resize(&image, nw, nh, image::imageops::FilterType::Lanczos3)
            }
            kogaview_protocol::PasteMode::ExpandCanvas if iw > cw || ih > ch => {
                let new_w = cw.max(iw);
                let new_h = ch.max(ih);
                let dx = (new_w as i32 - cw as i32) / 2;
                let dy = (new_h as i32 - ch as i32) / 2;
                for layer in &mut self.stack.layers {
                    layer.offset_x += dx;
                    layer.offset_y += dy;
                }
                self.stack.canvas_width = new_w;
                self.stack.canvas_height = new_h;
                image
            }
            _ => image,
        };

        let (ncw, nch) = self.dimensions();
        let (fw, fh) = final_image.dimensions();
        let offset_x = (ncw as i32 - fw as i32) / 2;
        let offset_y = (nch as i32 - fh as i32) / 2;
        if ncw != cw || nch != ch {
            self.selection = None;
        }

        // If the user explicitly added an empty layer and immediately pasted
        // into it, fill that empty layer directly instead of spawning a stray
        // extra layer on top of an empty one.
        let reuse_empty_active = self.stack.layers.len() > 1
            && !self.stack.active_layer().locked
            && self.stack.active_layer().is_empty();
        let layer_op = LayerOperation::AddImage {
            name: name.clone(),
            offset_x,
            offset_y,
            pixels: Arc::new(final_image),
        };
        if reuse_empty_active {
            let active = self.stack.active_layer_mut();
            let pixels = match &layer_op {
                LayerOperation::AddImage { pixels, .. } => Arc::clone(pixels),
                _ => unreachable!(),
            };
            active.pixels = Arc::clone(&pixels);
            active.original = Some(pixels);
            active.offset_x = offset_x;
            active.offset_y = offset_y;
            if active.name.starts_with("Layer ") && !name.trim().is_empty() {
                active.name = name.trim().to_owned();
            }
        } else {
            let changed = self.stack.apply_op(&layer_op)?;
            if !changed {
                return Ok(false);
            }
        }
        self.push(
            EditOperation::Layer(layer_op),
            ApplyTarget::WholeImage,
            before,
        );
        self.working = composite_stack(&self.stack);
        self.saved = false;
        Ok(true)
    }

    /// Would `operation` change anything?
    pub fn would_change(&self, operation: &EditOperation) -> Result<bool, UiText> {
        self.is_noop(operation, ApplyTarget::WholeImage)
            .map(|noop| !noop)
    }

    pub fn undo(&mut self) -> bool {
        let Some(step) = self.undo.pop() else {
            return false;
        };
        match &step.undo {
            Undo::Invert(inv_op) => {
                if self
                    .execute_operation(inv_op, ApplyTarget::WholeImage)
                    .is_err()
                {
                    self.undo.push(step);
                    return false;
                }
            }
            Undo::Stack(prev_stack) => {
                self.stack = prev_stack.clone();
            }
        }
        self.working = composite_stack(&self.stack);
        self.redo.push((step.operation, step.target));
        self.saved = false;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some((operation, target)) = self.redo.pop() else {
            return false;
        };
        let before = self.stack.clone();
        let res = match &operation {
            EditOperation::Layer(layer_op) => self.stack.apply_op(layer_op).map(|_| ()),
            _ => self.execute_operation(&operation, target),
        };
        if res.is_err() {
            self.redo.push((operation, target));
            return false;
        }
        self.push_preserving_redo(operation, target, before);
        self.working = composite_stack(&self.stack);
        self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels);
        true
    }

    /// Discard every edit and restore the initial layer stack.
    pub fn reset(&mut self) -> bool {
        if self.undo.is_empty()
            && self.redo.is_empty()
            && Arc::ptr_eq(&self.working, &self.original)
        {
            return false;
        }
        self.stack = self.original_stack.clone();
        self.working = Arc::clone(&self.original);
        self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels);
        self.undo.clear();
        self.redo.clear();
        self.snapshot_bytes = 0;
        self.history_trimmed = false;
        self.live_stroke = None;
        self.selection = None;
        true
    }

    fn execute_operation(
        &mut self,
        operation: &EditOperation,
        target: ApplyTarget,
    ) -> Result<(), UiText> {
        // 1. NewLayer target: render against current composited image and insert above active layer.
        if target == ApplyTarget::NewLayer {
            let source_before = Arc::clone(&self.working);
            let next = render_operation(&self.working, operation)?;
            let (name, preserve_original) = match operation {
                EditOperation::AiResult { label, .. } => match label.code.as_str() {
                    "remove_background" => ("Cutout".to_owned(), true),
                    "remove_watermark" => ("Watermark removed".to_owned(), false),
                    "refine_alpha_mask" => ("Refined".to_owned(), false),
                    _ => ("AI Layer".to_owned(), false),
                },
                _ => ("Layer".to_owned(), false),
            };
            self.stack.apply_op(&LayerOperation::AddImage {
                name,
                offset_x: 0,
                offset_y: 0,
                pixels: Arc::new(next),
            })?;
            if preserve_original {
                self.stack.active_layer_mut().original = Some(source_before);
            }
            return Ok(());
        }

        // 2. Canvas-wide geometry operations always apply to the whole stack.
        match operation {
            EditOperation::Crop {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            } => {
                if self.is_simple_single_layer() {
                    let next = render_operation(&self.stack.layers[0].pixels, operation)?;
                    self.stack.canvas_width = next.width();
                    self.stack.canvas_height = next.height();
                    self.stack.layers[0].pixels = Arc::new(next);
                } else {
                    let old_w = self.stack.canvas_width;
                    let old_h = self.stack.canvas_height;
                    self.stack.canvas_width = *width;
                    self.stack.canvas_height = *height;
                    for layer in &mut self.stack.layers {
                        layer.offset_x -= *x;
                        layer.offset_y -= *y;
                    }
                    if *x < 0
                        || *y < 0
                        || (*x as i64 + *width as i64) > old_w as i64
                        || (*y as i64 + *height as i64) > old_h as i64
                    {
                        fill_expanded_bottom_layer(&mut self.stack, *fill, *fill_alpha);
                    }
                }
                self.selection = None;
                return Ok(());
            }
            EditOperation::Resize { width, height, .. } => {
                if self.is_simple_single_layer() {
                    let next = render_operation(&self.stack.layers[0].pixels, operation)?;
                    self.stack.canvas_width = next.width();
                    self.stack.canvas_height = next.height();
                    self.stack.layers[0].pixels = Arc::new(next);
                } else {
                    let old_w = self.stack.canvas_width.max(1) as f64;
                    let old_h = self.stack.canvas_height.max(1) as f64;
                    let sx = *width as f64 / old_w;
                    let sy = *height as f64 / old_h;
                    for layer in &mut self.stack.layers {
                        let (lw, lh) = layer.dimensions();
                        let new_lw = ((lw as f64 * sx).round() as u32).max(1);
                        let new_lh = ((lh as f64 * sy).round() as u32).max(1);
                        let scaled = image::imageops::resize(
                            layer.pixels.as_ref(),
                            new_lw,
                            new_lh,
                            image::imageops::FilterType::CatmullRom,
                        );
                        layer.pixels = Arc::new(scaled);
                        layer.offset_x = (layer.offset_x as f64 * sx).round() as i32;
                        layer.offset_y = (layer.offset_y as f64 * sy).round() as i32;
                    }
                    self.stack.canvas_width = *width;
                    self.stack.canvas_height = *height;
                }
                self.selection = None;
                return Ok(());
            }
            EditOperation::CanvasSize {
                width,
                height,
                anchor,
                fill,
                fill_alpha,
            } => {
                if self.is_simple_single_layer() {
                    let next = render_operation(&self.stack.layers[0].pixels, operation)?;
                    self.stack.canvas_width = next.width();
                    self.stack.canvas_height = next.height();
                    self.stack.layers[0].pixels = Arc::new(next);
                } else {
                    let old_w = self.stack.canvas_width;
                    let old_h = self.stack.canvas_height;
                    let (dx, dy) = anchor_offset(old_w, old_h, *width, *height, anchor);
                    for layer in &mut self.stack.layers {
                        layer.offset_x += dx;
                        layer.offset_y += dy;
                    }
                    self.stack.canvas_width = *width;
                    self.stack.canvas_height = *height;
                    if *width > old_w || *height > old_h {
                        fill_expanded_bottom_layer(&mut self.stack, *fill, *fill_alpha);
                    }
                }
                self.selection = None;
                return Ok(());
            }
            _ => {}
        }

        // 3. Paint always targets the active layer (or its transparency mask when
        // `editing_mask` is active), checking lock/visibility, translating offset,
        // and clipping to any active selection mask.
        if let EditOperation::Paint {
            points,
            color,
            radius,
            opacity,
            erase,
            brush,
        } = operation
        {
            let active = self.stack.active_layer();
            if active.locked {
                return Err(UiText::new("layer_locked"));
            }
            if !active.visible {
                return Err(UiText::new("layer_hidden"));
            }
            let ox = active.offset_x as f64;
            let oy = active.offset_y as f64;
            let local_pts: Vec<[f64; 2]> = points.iter().map(|[x, y]| [x - ox, y - oy]).collect();

            if active.editing_mask {
                if let Some(existing_mask) = &active.mask {
                    let (lw, lh) = active.dimensions();
                    let mut mask_img = RgbaImage::new(lw, lh);
                    for y in 0..lh {
                        let row = (y as usize) * (lw as usize);
                        for x in 0..lw {
                            let v = existing_mask.get(row + x as usize).copied().unwrap_or(255);
                            mask_img.put_pixel(x, y, image::Rgba([v, v, v, 255]));
                        }
                    }
                    let gray = if *erase {
                        0u8
                    } else {
                        (0.299 * f64::from(color[0])
                            + 0.587 * f64::from(color[1])
                            + 0.114 * f64::from(color[2]))
                        .round()
                        .clamp(0.0, 255.0) as u8
                    };
                    let mask_op = EditOperation::Paint {
                        points: local_pts,
                        color: [gray, gray, gray],
                        radius: *radius,
                        opacity: *opacity,
                        erase: false,
                        brush: *brush,
                    };
                    let mut next = render_operation(&mask_img, &mask_op)?;
                    if let Some(sel) = &self.selection {
                        blend_with_selection(
                            &mask_img,
                            &mut next,
                            sel,
                            active.offset_x,
                            active.offset_y,
                        );
                    }
                    let mut out_mask = vec![0u8; (lw as usize) * (lh as usize)];
                    for y in 0..lh {
                        let row = (y as usize) * (lw as usize);
                        for x in 0..lw {
                            out_mask[row + x as usize] = next.get_pixel(x, y).0[0];
                        }
                    }
                    self.stack.active_layer_mut().mask = Some(Arc::new(out_mask));
                    return Ok(());
                }
            }

            let local_op = EditOperation::Paint {
                points: local_pts,
                color: *color,
                radius: *radius,
                opacity: *opacity,
                erase: *erase,
                brush: *brush,
            };
            let mut next = render_operation(&active.pixels, &local_op)?;
            // If a selection mask is active, constrain the paint/erase stroke to it!
            if let Some(sel) = &self.selection {
                blend_with_selection(
                    &active.pixels,
                    &mut next,
                    sel,
                    active.offset_x,
                    active.offset_y,
                );
            }
            self.stack.active_layer_mut().pixels = Arc::new(next);
            return Ok(());
        }

        // 3a. DrawShape targets the active layer (or its transparency mask when
        // `editing_mask` is active), translating coordinates by the layer's offset,
        // and clipping to the active selection mask.
        if let EditOperation::DrawShape {
            kind,
            points,
            closed,
            stroke_color,
            stroke_width,
            stroke_opacity,
            fill_color,
            fill_opacity,
        } = operation
        {
            let active = self.stack.active_layer();
            if active.locked {
                return Err(UiText::new("layer_locked"));
            }
            if !active.visible {
                return Err(UiText::new("layer_hidden"));
            }
            let ox = active.offset_x as f64;
            let oy = active.offset_y as f64;
            let local_pts: Vec<[f64; 2]> = points.iter().map(|[x, y]| [x - ox, y - oy]).collect();

            if active.editing_mask {
                if let Some(existing_mask) = &active.mask {
                    let (lw, lh) = active.dimensions();
                    let mut mask_img = RgbaImage::new(lw, lh);
                    for y in 0..lh {
                        let row = (y as usize) * (lw as usize);
                        for x in 0..lw {
                            let v = existing_mask.get(row + x as usize).copied().unwrap_or(255);
                            mask_img.put_pixel(x, y, image::Rgba([v, v, v, 255]));
                        }
                    }
                    let to_gray = |c: [u8; 3]| -> [u8; 3] {
                        let g = (0.299 * f64::from(c[0])
                            + 0.587 * f64::from(c[1])
                            + 0.114 * f64::from(c[2]))
                        .round()
                        .clamp(0.0, 255.0) as u8;
                        [g, g, g]
                    };
                    let mask_op = EditOperation::DrawShape {
                        kind: *kind,
                        points: local_pts,
                        closed: *closed,
                        stroke_color: stroke_color.map(to_gray),
                        stroke_width: *stroke_width,
                        stroke_opacity: *stroke_opacity,
                        fill_color: fill_color.map(to_gray),
                        fill_opacity: *fill_opacity,
                    };
                    let mut next = render_operation(&mask_img, &mask_op)?;
                    if let Some(sel) = &self.selection {
                        blend_with_selection(
                            &mask_img,
                            &mut next,
                            sel,
                            active.offset_x,
                            active.offset_y,
                        );
                    }
                    let mut out_mask = vec![0u8; (lw as usize) * (lh as usize)];
                    for y in 0..lh {
                        let row = (y as usize) * (lw as usize);
                        for x in 0..lw {
                            out_mask[row + x as usize] = next.get_pixel(x, y).0[0];
                        }
                    }
                    self.stack.active_layer_mut().mask = Some(Arc::new(out_mask));
                    return Ok(());
                }
            }

            let local_op = EditOperation::DrawShape {
                kind: *kind,
                points: local_pts,
                closed: *closed,
                stroke_color: *stroke_color,
                stroke_width: *stroke_width,
                stroke_opacity: *stroke_opacity,
                fill_color: *fill_color,
                fill_opacity: *fill_opacity,
            };
            let mut next = render_operation(&active.pixels, &local_op)?;
            if let Some(sel) = &self.selection {
                blend_with_selection(
                    &active.pixels,
                    &mut next,
                    sel,
                    active.offset_x,
                    active.offset_y,
                );
            }
            self.stack.active_layer_mut().pixels = Arc::new(next);
            return Ok(());
        }

        // 3b-fill. FloodFill targets the active layer (or its transparency mask),
        // optionally sampling the composited stack for lineart coloring, and
        // clips strictly to any active selection mask.
        if let EditOperation::FloodFill {
            x,
            y,
            color,
            opacity,
            tolerance,
            grow,
            contiguous,
            sample_all_layers,
        } = operation
        {
            let active = self.stack.active_layer();
            if active.locked {
                return Err(UiText::new("layer_locked"));
            }
            if !active.visible {
                return Err(UiText::new("layer_hidden"));
            }
            let (lw, lh) = active.dimensions();
            let ox = active.offset_x;
            let oy = active.offset_y;
            let composite_ref = if *sample_all_layers {
                Some(composite_stack(&self.stack))
            } else {
                None
            };
            let (ref_img, ref_ox, ref_oy, seed_x, seed_y) = match &composite_ref {
                Some(comp) => (comp.as_ref(), ox, oy, *x, *y),
                None => (active.pixels.as_ref(), 0, 0, *x - ox, *y - oy),
            };
            if active.editing_mask {
                if let Some(existing_mask) = &active.mask {
                    let mut mask_img = RgbaImage::new(lw, lh);
                    for py in 0..lh {
                        let row = (py as usize) * (lw as usize);
                        for px in 0..lw {
                            let v = existing_mask.get(row + px as usize).copied().unwrap_or(255);
                            mask_img.put_pixel(px, py, image::Rgba([v, v, v, 255]));
                        }
                    }
                    let g = (0.299 * f64::from(color[0])
                        + 0.587 * f64::from(color[1])
                        + 0.114 * f64::from(color[2]))
                    .round()
                    .clamp(0.0, 255.0) as u8;
                    let mut next = crate::pixels::flood_fill(
                        &mask_img,
                        &mask_img,
                        0,
                        0,
                        *x - ox,
                        *y - oy,
                        [g, g, g],
                        *opacity,
                        *tolerance,
                        *grow,
                        *contiguous,
                    );
                    if let Some(sel) = &self.selection {
                        blend_with_selection(&mask_img, &mut next, sel, ox, oy);
                    }
                    let mut out_mask = vec![0u8; (lw as usize) * (lh as usize)];
                    for py in 0..lh {
                        let row = (py as usize) * (lw as usize);
                        for px in 0..lw {
                            out_mask[row + px as usize] = next.get_pixel(px, py).0[0];
                        }
                    }
                    self.stack.active_layer_mut().mask = Some(Arc::new(out_mask));
                    return Ok(());
                }
            }
            let mut next = crate::pixels::flood_fill(
                &active.pixels,
                ref_img,
                ref_ox,
                ref_oy,
                seed_x,
                seed_y,
                *color,
                *opacity,
                *tolerance,
                *grow,
                *contiguous,
            );
            if let Some(sel) = &self.selection {
                blend_with_selection(&active.pixels, &mut next, sel, ox, oy);
            }
            self.stack.active_layer_mut().pixels = Arc::new(next);
            return Ok(());
        }

        // 3b-grad. Gradient targets the active layer (or its transparency mask)
        // and clips strictly to any active selection mask.
        if let EditOperation::Gradient {
            start,
            end,
            start_color,
            start_alpha,
            end_color,
            end_alpha,
            stops,
            opacity,
            shape,
            repeat,
            reverse,
            dither,
            blend_mode,
        } = operation
        {
            let active = self.stack.active_layer();
            if active.locked {
                return Err(UiText::new("layer_locked"));
            }
            if !active.visible {
                return Err(UiText::new("layer_hidden"));
            }
            let ox = active.offset_x;
            let oy = active.offset_y;
            let local_start = [start[0] - ox as f64, start[1] - oy as f64];
            let local_end = [end[0] - ox as f64, end[1] - oy as f64];
            if active.editing_mask {
                if let Some(existing_mask) = &active.mask {
                    let (lw, lh) = active.dimensions();
                    let mut mask_img = RgbaImage::new(lw, lh);
                    for py in 0..lh {
                        let row = (py as usize) * (lw as usize);
                        for px in 0..lw {
                            let v = existing_mask.get(row + px as usize).copied().unwrap_or(255);
                            mask_img.put_pixel(px, py, image::Rgba([v, v, v, 255]));
                        }
                    }
                    let to_gray = |c: [u8; 3]| -> [u8; 3] {
                        let g = (0.299 * f64::from(c[0])
                            + 0.587 * f64::from(c[1])
                            + 0.114 * f64::from(c[2]))
                        .round()
                        .clamp(0.0, 255.0) as u8;
                        [g, g, g]
                    };
                    let gray_stops: Vec<kogaview_protocol::GradientStop> = stops
                        .iter()
                        .map(|s| kogaview_protocol::GradientStop {
                            pos: s.pos,
                            color: to_gray(s.color),
                            alpha: s.alpha,
                        })
                        .collect();
                    let mut next = crate::pixels::render_gradient(
                        &mask_img,
                        local_start,
                        local_end,
                        to_gray(*start_color),
                        *start_alpha,
                        to_gray(*end_color),
                        *end_alpha,
                        &gray_stops,
                        *opacity,
                        *shape,
                        *repeat,
                        *reverse,
                        *dither,
                        "normal",
                    );
                    if let Some(sel) = &self.selection {
                        blend_with_selection(&mask_img, &mut next, sel, ox, oy);
                    }
                    let mut out_mask = vec![0u8; (lw as usize) * (lh as usize)];
                    for py in 0..lh {
                        let row = (py as usize) * (lw as usize);
                        for px in 0..lw {
                            out_mask[row + px as usize] = next.get_pixel(px, py).0[0];
                        }
                    }
                    self.stack.active_layer_mut().mask = Some(Arc::new(out_mask));
                    return Ok(());
                }
            }
            let mut next = crate::pixels::render_gradient(
                &active.pixels,
                local_start,
                local_end,
                *start_color,
                *start_alpha,
                *end_color,
                *end_alpha,
                stops,
                *opacity,
                *shape,
                *repeat,
                *reverse,
                *dither,
                blend_mode,
            );
            if let Some(sel) = &self.selection {
                blend_with_selection(&active.pixels, &mut next, sel, ox, oy);
            }
            self.stack.active_layer_mut().pixels = Arc::new(next);
            return Ok(());
        }

        // 3b. FreeTransform with an active selection floats, transforms (scale +
        // rotate + move), and composites ONLY the selected pixels on the active
        // layer in one atomic undoable step, updating the selection mask to match.
        if let EditOperation::FreeTransform {
            x,
            y,
            width,
            height,
            rotation,
            ..
        } = operation
        {
            if let Some(sel) = self.selection.clone() {
                if let Some((bx, by, bw, bh)) = sel.bounds() {
                    let active = self.stack.active_layer();
                    if active.locked {
                        return Err(UiText::new("layer_locked"));
                    }
                    if !active.visible {
                        return Err(UiText::new("layer_hidden"));
                    }
                    validate_resize(*width, *height)?;
                    if !rotation.is_finite() {
                        return Err(UiText::with("invalid_rotation", [rotation.to_string()]));
                    }

                    let ox = active.offset_x;
                    let oy = active.offset_y;
                    let (lw, lh) = active.dimensions();
                    let mut cleared = (*active.pixels).clone();
                    let mut patch = RgbaImage::from_pixel(bw, bh, image::Rgba([0, 0, 0, 0]));
                    let mut mask_img = RgbaImage::from_pixel(bw, bh, image::Rgba([0, 0, 0, 0]));

                    for dy in 0..bh {
                        let cy = by as i32 + dy as i32;
                        let ly = cy - oy;
                        for dx in 0..bw {
                            let cx = bx as i32 + dx as i32;
                            let m = sel.alpha_at(cx, cy);
                            if m == 0 {
                                continue;
                            }
                            mask_img.put_pixel(dx, dy, image::Rgba([255, 255, 255, m]));
                            let lx = cx - ox;
                            if lx < 0 || ly < 0 || lx >= lw as i32 || ly >= lh as i32 {
                                continue;
                            }
                            let p = active.pixels.get_pixel(lx as u32, ly as u32).0;
                            let cut_a = ((u32::from(p[3]) * u32::from(m) + 127) / 255) as u8;
                            patch.put_pixel(dx, dy, image::Rgba([p[0], p[1], p[2], cut_a]));
                            let rem_a = ((u32::from(p[3]) * u32::from(255 - m) + 127) / 255) as u8;
                            cleared.put_pixel(
                                lx as u32,
                                ly as u32,
                                image::Rgba([p[0], p[1], p[2], rem_a]),
                            );
                        }
                    }

                    let mut next_patch = if *width == bw && *height == bh {
                        patch
                    } else {
                        resample(
                            &patch,
                            *width,
                            *height,
                            kogaview_protocol::ResizeFilter::Bicubic,
                        )
                    };
                    let mut next_mask_img = if *width == bw && *height == bh {
                        mask_img
                    } else {
                        resample(
                            &mask_img,
                            *width,
                            *height,
                            kogaview_protocol::ResizeFilter::Bilinear,
                        )
                    };
                    let norm = rotation.rem_euclid(360.0);
                    let (mut new_x, mut new_y) = (*x, *y);
                    if norm > 1e-4 && (360.0 - norm) > 1e-4 {
                        let (bw_s, bh_s) = next_patch.dimensions();
                        let rot_op = EditOperation::RotateAngle {
                            degrees: *rotation,
                            fill: None,
                            fill_alpha: 0,
                        };
                        next_patch = render_operation(&next_patch, &rot_op)?;
                        next_mask_img = render_operation(&next_mask_img, &rot_op)?;
                        let (rw, rh) = next_patch.dimensions();
                        new_x += (bw_s as i32 - rw as i32) / 2;
                        new_y += (bh_s as i32 - rh as i32) / 2;
                    }

                    let (pw, ph) = next_patch.dimensions();
                    for py in 0..ph {
                        let cy = new_y + py as i32;
                        let ly = cy - oy;
                        if ly < 0 || ly >= lh as i32 {
                            continue;
                        }
                        for px in 0..pw {
                            let cx = new_x + px as i32;
                            let lx = cx - ox;
                            if lx < 0 || lx >= lw as i32 {
                                continue;
                            }
                            let src = next_patch.get_pixel(px, py).0;
                            if src[3] == 0 {
                                continue;
                            }
                            let dst = cleared.get_pixel(lx as u32, ly as u32).0;
                            let sa = src[3] as f32 / 255.0;
                            let da = dst[3] as f32 / 255.0;
                            let out_a = sa + da * (1.0 - sa);
                            if out_a <= 0.0 {
                                continue;
                            }
                            let blend = |sc: u8, dc: u8| -> u8 {
                                ((sc as f32 * sa + dc as f32 * da * (1.0 - sa)) / out_a)
                                    .round()
                                    .clamp(0.0, 255.0) as u8
                            };
                            cleared.put_pixel(
                                lx as u32,
                                ly as u32,
                                image::Rgba([
                                    blend(src[0], dst[0]),
                                    blend(src[1], dst[1]),
                                    blend(src[2], dst[2]),
                                    (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
                                ]),
                            );
                        }
                    }

                    self.stack.active_layer_mut().pixels = Arc::new(cleared);

                    // Update selection mask to follow the transformed bounds.
                    let (cw, ch) = self.dimensions();
                    let mut new_sel = SelectionMask::empty(cw, ch);
                    let (mw, mh) = next_mask_img.dimensions();
                    for py in 0..mh {
                        let cy = new_y + py as i32;
                        if cy < 0 || cy >= ch as i32 {
                            continue;
                        }
                        let row = (cy as usize) * (cw as usize);
                        for px in 0..mw {
                            let cx = new_x + px as i32;
                            if cx < 0 || cx >= cw as i32 {
                                continue;
                            }
                            new_sel.alpha[row + cx as usize] = next_mask_img.get_pixel(px, py).0[3];
                        }
                    }
                    self.selection = if new_sel.is_empty() {
                        None
                    } else {
                        Some(new_sel)
                    };
                    return Ok(());
                }
            }
        }

        // 3c. Rotate (90°/-90°/180°) and Flip (H/V) with an active selection:
        // float ONLY the selected pixels on the active layer, rotate/flip both
        // the patch and the selection mask around the selection center, and
        // composite back in one atomic undoable step.
        if matches!(
            operation,
            EditOperation::Rotate { .. } | EditOperation::Flip { .. }
        ) {
            if let Some(sel) = self.selection.clone() {
                if let Some((bx, by, bw, bh)) = sel.bounds() {
                    let active = self.stack.active_layer();
                    if active.locked {
                        return Err(UiText::new("layer_locked"));
                    }
                    if !active.visible {
                        return Err(UiText::new("layer_hidden"));
                    }
                    let ox = active.offset_x;
                    let oy = active.offset_y;
                    let (lw, lh) = active.dimensions();
                    let mut cleared = (*active.pixels).clone();
                    let mut patch = RgbaImage::from_pixel(bw, bh, image::Rgba([0, 0, 0, 0]));
                    let mut mask_img = RgbaImage::from_pixel(bw, bh, image::Rgba([0, 0, 0, 0]));

                    for dy in 0..bh {
                        let cy = by as i32 + dy as i32;
                        let ly = cy - oy;
                        for dx in 0..bw {
                            let cx = bx as i32 + dx as i32;
                            let m = sel.alpha_at(cx, cy);
                            if m == 0 {
                                continue;
                            }
                            mask_img.put_pixel(dx, dy, image::Rgba([255, 255, 255, m]));
                            let lx = cx - ox;
                            if lx < 0 || ly < 0 || lx >= lw as i32 || ly >= lh as i32 {
                                continue;
                            }
                            let p = active.pixels.get_pixel(lx as u32, ly as u32).0;
                            let cut_a = ((u32::from(p[3]) * u32::from(m) + 127) / 255) as u8;
                            patch.put_pixel(dx, dy, image::Rgba([p[0], p[1], p[2], cut_a]));
                            let rem_a = ((u32::from(p[3]) * u32::from(255 - m) + 127) / 255) as u8;
                            cleared.put_pixel(
                                lx as u32,
                                ly as u32,
                                image::Rgba([p[0], p[1], p[2], rem_a]),
                            );
                        }
                    }

                    let next_patch = render_operation(&patch, operation)?;
                    let next_mask_img = render_operation(&mask_img, operation)?;
                    let (rw, rh) = next_patch.dimensions();
                    let new_x = bx as i32 + (bw as i32 - rw as i32) / 2;
                    let new_y = by as i32 + (bh as i32 - rh as i32) / 2;

                    for py in 0..rh {
                        let cy = new_y + py as i32;
                        let ly = cy - oy;
                        if ly < 0 || ly >= lh as i32 {
                            continue;
                        }
                        for px in 0..rw {
                            let cx = new_x + px as i32;
                            let lx = cx - ox;
                            if lx < 0 || lx >= lw as i32 {
                                continue;
                            }
                            let src = next_patch.get_pixel(px, py).0;
                            if src[3] == 0 {
                                continue;
                            }
                            let dst = cleared.get_pixel(lx as u32, ly as u32).0;
                            let sa = src[3] as f32 / 255.0;
                            let da = dst[3] as f32 / 255.0;
                            let out_a = sa + da * (1.0 - sa);
                            if out_a <= 0.0 {
                                continue;
                            }
                            let blend = |sc: u8, dc: u8| -> u8 {
                                ((sc as f32 * sa + dc as f32 * da * (1.0 - sa)) / out_a)
                                    .round()
                                    .clamp(0.0, 255.0) as u8
                            };
                            cleared.put_pixel(
                                lx as u32,
                                ly as u32,
                                image::Rgba([
                                    blend(src[0], dst[0]),
                                    blend(src[1], dst[1]),
                                    blend(src[2], dst[2]),
                                    (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
                                ]),
                            );
                        }
                    }
                    self.stack.active_layer_mut().pixels = Arc::new(cleared);

                    let (cw, ch) = self.dimensions();
                    let mut new_sel = SelectionMask::empty(cw, ch);
                    for py in 0..rh {
                        let cy = new_y + py as i32;
                        if cy < 0 || cy >= ch as i32 {
                            continue;
                        }
                        let row = (cy as usize) * (cw as usize);
                        for px in 0..rw {
                            let cx = new_x + px as i32;
                            if cx < 0 || cx >= cw as i32 {
                                continue;
                            }
                            new_sel.alpha[row + cx as usize] = next_mask_img.get_pixel(px, py).0[3];
                        }
                    }
                    self.selection = if new_sel.is_empty() {
                        None
                    } else {
                        Some(new_sel)
                    };
                    return Ok(());
                }
            }
        }

        // 4. ActiveLayer target: mutate ONLY the active layer.
        if target == ApplyTarget::ActiveLayer {
            let active = self.stack.active_layer();
            if active.locked {
                return Err(UiText::new("layer_locked"));
            }
            if !active.visible {
                return Err(UiText::new("layer_hidden"));
            }
            // FreeTransform on ActiveLayer resizes and repositions the layer's
            // own pixel buffer directly without clipping off-canvas overflow.
            if let EditOperation::FreeTransform {
                x,
                y,
                width,
                height,
                rotation,
                ..
            } = operation
            {
                validate_resize(*width, *height)?;
                if !rotation.is_finite() {
                    return Err(UiText::with("invalid_rotation", [rotation.to_string()]));
                }
                let mut next = resample(
                    &active.pixels,
                    *width,
                    *height,
                    kogaview_protocol::ResizeFilter::Auto,
                );
                let norm = rotation.rem_euclid(360.0);
                let (mut new_x, mut new_y) = (*x, *y);
                if norm > 1e-4 && (360.0 - norm) > 1e-4 {
                    let (bw, bh) = next.dimensions();
                    next = render_operation(
                        &next,
                        &EditOperation::RotateAngle {
                            degrees: *rotation,
                            fill: None,
                            fill_alpha: 0,
                        },
                    )?;
                    let (rw, rh) = next.dimensions();
                    new_x += (bw as i32 - rw as i32) / 2;
                    new_y += (bh as i32 - rh as i32) / 2;
                }
                let active_mut = self.stack.active_layer_mut();
                active_mut.pixels = Arc::new(next);
                active_mut.offset_x = new_x;
                active_mut.offset_y = new_y;
                return Ok(());
            }

            let (old_w, old_h) = active.dimensions();
            let mut next = render_operation(&active.pixels, operation)?;
            if matches!(
                operation,
                EditOperation::AdjustColor { .. }
                    | EditOperation::AdjustCurves { .. }
                    | EditOperation::AdjustHsv { .. }
                    | EditOperation::ColorBalance { .. }
            ) {
                if let Some(sel) = &self.selection {
                    blend_with_selection(
                        &active.pixels,
                        &mut next,
                        sel,
                        active.offset_x,
                        active.offset_y,
                    );
                }
            }
            let (new_w, new_h) = next.dimensions();
            let active_mut = self.stack.active_layer_mut();
            if matches!(operation, EditOperation::AiResult { label, .. } if label.code == "remove_background")
                && active_mut.original.is_none()
            {
                active_mut.original = Some(Arc::clone(&active_mut.pixels));
            }
            if new_w != old_w || new_h != old_h {
                active_mut.offset_x += (old_w as i32 - new_w as i32) / 2;
                active_mut.offset_y += (old_h as i32 - new_h as i32) / 2;
            }
            active_mut.pixels = Arc::new(next);
            return Ok(());
        }

        // 5. WholeImage target:
        if self.is_simple_single_layer() {
            let mut next = render_operation(&self.stack.layers[0].pixels, operation)?;
            if matches!(
                operation,
                EditOperation::AdjustColor { .. }
                    | EditOperation::AdjustCurves { .. }
                    | EditOperation::AdjustHsv { .. }
                    | EditOperation::ColorBalance { .. }
            ) {
                if let Some(sel) = &self.selection {
                    blend_with_selection(&self.stack.layers[0].pixels, &mut next, sel, 0, 0);
                }
            }
            self.stack.canvas_width = next.width();
            self.stack.canvas_height = next.height();
            if matches!(operation, EditOperation::AiResult { label, .. } if label.code == "remove_background")
                && self.stack.layers[0].original.is_none()
            {
                self.stack.layers[0].original = Some(Arc::clone(&self.stack.layers[0].pixels));
            }
            self.stack.layers[0].pixels = Arc::new(next);
            return Ok(());
        }

        // Multi-layer WholeImage operations:
        match operation {
            EditOperation::Rotate { degrees } => {
                let cw = self.stack.canvas_width;
                let ch = self.stack.canvas_height;
                let norm = degrees.rem_euclid(360);
                for layer in &mut self.stack.layers {
                    let (lw, lh) = layer.dimensions();
                    let next = render_operation(&layer.pixels, operation)?;
                    let (ox, oy) = (layer.offset_x, layer.offset_y);
                    let (new_ox, new_oy) = match norm {
                        90 => (ch as i32 - oy - lh as i32, ox),
                        180 => (cw as i32 - ox - lw as i32, ch as i32 - oy - lh as i32),
                        270 => (oy, cw as i32 - ox - lw as i32),
                        _ => (ox, oy),
                    };
                    layer.pixels = Arc::new(next);
                    layer.offset_x = new_ox;
                    layer.offset_y = new_oy;
                }
                if norm == 90 || norm == 270 {
                    self.stack.canvas_width = ch;
                    self.stack.canvas_height = cw;
                }
            }
            EditOperation::Flip { axis } => {
                let cw = self.stack.canvas_width;
                let ch = self.stack.canvas_height;
                for layer in &mut self.stack.layers {
                    let (lw, lh) = layer.dimensions();
                    let next = render_operation(&layer.pixels, operation)?;
                    match axis {
                        FlipAxis::Horizontal => {
                            layer.offset_x = cw as i32 - layer.offset_x - lw as i32;
                        }
                        FlipAxis::Vertical => {
                            layer.offset_y = ch as i32 - layer.offset_y - lh as i32;
                        }
                    }
                    layer.pixels = Arc::new(next);
                }
            }
            EditOperation::AdjustColor { .. }
            | EditOperation::AdjustCurves { .. }
            | EditOperation::AdjustHsv { .. }
            | EditOperation::ColorBalance { .. } => {
                for layer in &mut self.stack.layers {
                    let mut next = render_operation(&layer.pixels, operation)?;
                    if let Some(sel) = &self.selection {
                        blend_with_selection(
                            &layer.pixels,
                            &mut next,
                            sel,
                            layer.offset_x,
                            layer.offset_y,
                        );
                    }
                    layer.pixels = Arc::new(next);
                }
            }
            _ => {
                // Transform / FreeTransform / RotateAngle / AiResult on WholeImage
                // operates on the composited image and replaces the stack with the result.
                let next = render_operation(&self.working, operation)?;
                let (nw, nh) = next.dimensions();
                let id = self.stack.next_id;
                self.stack.next_id += 1;
                self.stack.canvas_width = nw;
                self.stack.canvas_height = nh;
                self.stack.layers = vec![Layer::new(id, "Background", Arc::new(next))];
                self.stack.active_layer_id = id;
            }
        }
        Ok(())
    }

    fn is_simple_single_layer(&self) -> bool {
        self.stack.layers.len() == 1
            && self.stack.background.is_none()
            && self.stack.layers[0].offset_x == 0
            && self.stack.layers[0].offset_y == 0
            && self.stack.layers[0].dimensions()
                == (self.stack.canvas_width, self.stack.canvas_height)
    }

    fn is_noop(&self, operation: &EditOperation, target: ApplyTarget) -> Result<bool, UiText> {
        let (width, height) = self.dimensions();
        match operation {
            EditOperation::Rotate { degrees } => {
                if degrees.rem_euclid(360) % 90 == 0 && degrees.rem_euclid(360) != 0 {
                    Ok(false)
                } else {
                    Err(UiText::with("invalid_rotation", [degrees.to_string()]))
                }
            }
            EditOperation::Flip { .. } => Ok(false),
            EditOperation::Crop {
                x,
                y,
                width: w,
                height: h,
                fill,
                fill_alpha,
            } => {
                validate_crop_mode(*x, *y, *w, *h, width, height, *fill, *fill_alpha)?;
                Ok(*x == 0 && *y == 0 && *w == width && *h == height)
            }
            EditOperation::Resize {
                width: w,
                height: h,
                fill,
                mode,
                ..
            } => {
                validate_resize(*w, *h)?;
                validate_resize_mode(*mode, *fill)?;
                Ok(*w == width && *h == height)
            }
            EditOperation::Transform { corners } => {
                validate_transform(corners, width, height)?;
                Ok(is_identity_quad(corners, width, height))
            }
            EditOperation::FreeTransform {
                x,
                y,
                width: w,
                height: h,
                rotation,
                ..
            } => {
                validate_resize(*w, *h)?;
                if !rotation.is_finite() {
                    return Err(UiText::with("invalid_rotation", [rotation.to_string()]));
                }
                let norm = rotation.rem_euclid(360.0);
                let rot_zero = norm < 1e-4 || (360.0 - norm) < 1e-4;
                if let Some(sel) = &self.selection {
                    if let Some((bx, by, bw, bh)) = sel.bounds() {
                        return Ok(*x == bx as i32
                            && *y == by as i32
                            && *w == bw
                            && *h == bh
                            && rot_zero);
                    }
                }
                if target == ApplyTarget::ActiveLayer {
                    let active = self.stack.active_layer();
                    let (lw, lh) = active.dimensions();
                    Ok(*x == active.offset_x
                        && *y == active.offset_y
                        && *w == lw
                        && *h == lh
                        && rot_zero)
                } else {
                    Ok(*x == 0 && *y == 0 && *w == width && *h == height && rot_zero)
                }
            }
            EditOperation::CanvasSize {
                width: w,
                height: h,
                ..
            } => {
                validate_resize(*w, *h)?;
                Ok(*w == width && *h == height)
            }
            EditOperation::RotateAngle { degrees, .. } => {
                if !degrees.is_finite() {
                    return Err(UiText::with("invalid_rotation", [degrees.to_string()]));
                }
                let norm = degrees.rem_euclid(360.0);
                Ok(norm < 1e-4 || (360.0 - norm) < 1e-4)
            }
            EditOperation::AdjustColor {
                brightness,
                contrast,
                saturation,
            } => {
                if !brightness.is_finite() || !contrast.is_finite() || !saturation.is_finite() {
                    return Err(UiText::new("invalid_color_adjustment"));
                }
                Ok(brightness.abs() < 1e-4 && contrast.abs() < 1e-4 && saturation.abs() < 1e-4)
            }
            EditOperation::AdjustCurves {
                rgb,
                red,
                green,
                blue,
            } => {
                let id_rgb = pixels::is_identity_lut(&pixels::build_curve_lut(rgb));
                let id_r = pixels::is_identity_lut(&pixels::build_curve_lut(red));
                let id_g = pixels::is_identity_lut(&pixels::build_curve_lut(green));
                let id_b = pixels::is_identity_lut(&pixels::build_curve_lut(blue));
                Ok(id_rgb && id_r && id_g && id_b)
            }
            EditOperation::AdjustHsv {
                hue,
                saturation,
                value,
            } => {
                if !hue.is_finite() || !saturation.is_finite() || !value.is_finite() {
                    return Err(UiText::new("invalid_color_adjustment"));
                }
                Ok(hue.abs() < 1e-4 && saturation.abs() < 1e-4 && value.abs() < 1e-4)
            }
            EditOperation::ColorBalance {
                shadows,
                midtones,
                highlights,
                ..
            } => {
                let all = shadows
                    .iter()
                    .chain(midtones.iter())
                    .chain(highlights.iter());
                for &v in all.clone() {
                    if !v.is_finite() {
                        return Err(UiText::new("invalid_color_adjustment"));
                    }
                }
                Ok(all.copied().all(|v| v.abs() < 1e-4))
            }
            EditOperation::Paint {
                points,
                radius,
                opacity,
                ..
            } => {
                validate_paint(points, *radius, *opacity)?;
                Ok(false)
            }
            EditOperation::DrawShape {
                points,
                stroke_color,
                stroke_width,
                stroke_opacity,
                fill_color,
                fill_opacity,
                ..
            } => {
                if points.is_empty() || points.iter().any(|[x, y]| !x.is_finite() || !y.is_finite())
                {
                    return Ok(true);
                }
                let has_stroke = stroke_color.is_some()
                    && stroke_width.is_finite()
                    && *stroke_width > 0.0
                    && stroke_opacity.is_finite()
                    && *stroke_opacity > 0.0;
                let has_fill =
                    fill_color.is_some() && fill_opacity.is_finite() && *fill_opacity > 0.0;
                Ok(!has_stroke && !has_fill)
            }
            EditOperation::FloodFill { opacity, .. } => Ok(!opacity.is_finite() || *opacity <= 0.0),
            EditOperation::Gradient {
                start,
                end,
                opacity,
                ..
            } => {
                let valid = start[0].is_finite()
                    && start[1].is_finite()
                    && end[0].is_finite()
                    && end[1].is_finite()
                    && opacity.is_finite()
                    && *opacity > 0.0
                    && (end[0] - start[0]).hypot(end[1] - start[1]) >= 0.5;
                Ok(!valid)
            }
            EditOperation::AiResult { .. } | EditOperation::Layer(_) => Ok(false),
        }
    }

    fn push(&mut self, operation: EditOperation, target: ApplyTarget, before: LayerStack) {
        self.redo.clear();
        self.push_preserving_redo(operation, target, before);
    }

    fn push_preserving_redo(
        &mut self,
        operation: EditOperation,
        target: ApplyTarget,
        before: LayerStack,
    ) {
        let undo = if target == ApplyTarget::WholeImage && before.layers.len() == 1 {
            match &operation {
                EditOperation::Rotate { degrees } => Undo::Invert(EditOperation::Rotate {
                    degrees: 360 - degrees.rem_euclid(360),
                }),
                EditOperation::Flip { axis } => Undo::Invert(EditOperation::Flip { axis: *axis }),
                _ => Undo::Stack(before),
            }
        } else {
            Undo::Stack(before)
        };
        self.undo.push(Step {
            operation,
            target,
            undo,
        });
        self.trim_history();
    }

    fn trim_history(&mut self) {
        while self.undo.len() > MAX_HISTORY_STEPS {
            self.undo.remove(0);
            self.history_trimmed = true;
        }
        self.snapshot_bytes = self.compute_snapshot_bytes();
        while self.snapshot_bytes > MAX_SNAPSHOT_BYTES && self.undo.len() > 1 {
            self.undo.remove(0);
            self.history_trimmed = true;
            self.snapshot_bytes = self.compute_snapshot_bytes();
        }
    }

    /// Count unique pixel buffers held in Undo snapshots (deduplicating `Arc`-shared layers).
    fn compute_snapshot_bytes(&self) -> u64 {
        let mut seen: HashSet<*const RgbaImage> = HashSet::new();
        let mut total = 0u64;
        for step in &self.undo {
            if let Undo::Stack(stack) = &step.undo {
                for layer in &stack.layers {
                    let ptr = Arc::as_ptr(&layer.pixels);
                    if seen.insert(ptr) {
                        total += layer.pixels.as_raw().len() as u64;
                    }
                }
            }
        }
        total
    }
}

/// Blend `adjusted` back onto `orig` through the canvas-space selection mask `sel`.
fn blend_with_selection(
    orig: &RgbaImage,
    adjusted: &mut RgbaImage,
    sel: &SelectionMask,
    offset_x: i32,
    offset_y: i32,
) {
    let (lw, lh) = adjusted.dimensions();
    if orig.dimensions() != (lw, lh) {
        return;
    }
    for y in 0..lh {
        for x in 0..lw {
            let m = sel.alpha_at(x as i32 + offset_x, y as i32 + offset_y);
            if m == 255 {
                continue;
            }
            let prev = orig.get_pixel(x, y).0;
            if m == 0 {
                adjusted.put_pixel(x, y, image::Rgba(prev));
            } else {
                let cur = adjusted.get_pixel(x, y).0;
                let t = m as f32 / 255.0;
                let inv = 1.0 - t;
                let mix = |a: u8, b: u8| -> u8 {
                    (a as f32 * inv + b as f32 * t).round().clamp(0.0, 255.0) as u8
                };
                adjusted.put_pixel(
                    x,
                    y,
                    image::Rgba([
                        mix(prev[0], cur[0]),
                        mix(prev[1], cur[1]),
                        mix(prev[2], cur[2]),
                        mix(prev[3], cur[3]),
                    ]),
                );
            }
        }
    }
}

/// When a multi-layer canvas grows with an opaque background fill, paint the
/// uncovered area onto the bottom-most layer so it matches single-layer growth
/// and the live canvas preview.
fn fill_expanded_bottom_layer(stack: &mut LayerStack, fill: Option<[u8; 3]>, fill_alpha: u8) {
    if fill_alpha == 0 {
        return;
    }
    let Some(rgb) = fill else {
        return;
    };
    if stack.layers.is_empty() {
        return;
    }
    let mut bg = RgbaImage::from_pixel(
        stack.canvas_width.max(1),
        stack.canvas_height.max(1),
        image::Rgba([rgb[0], rgb[1], rgb[2], fill_alpha]),
    );
    crate::layer::blend_layer_onto(&mut bg, &stack.layers[0]);
    stack.layers[0].pixels = Arc::new(bg);
    stack.layers[0].offset_x = 0;
    stack.layers[0].offset_y = 0;
}

/// Compute `(dx, dy)` pixel shift for a canvas resize with the given 9-point anchor.
fn anchor_offset(old_w: u32, old_h: u32, new_w: u32, new_h: u32, anchor: &str) -> (i32, i32) {
    let dw = new_w as i32 - old_w as i32;
    let dh = new_h as i32 - old_h as i32;
    let dx = match anchor {
        "top_left" | "left" | "bottom_left" => 0,
        "top_right" | "right" | "bottom_right" => dw,
        _ => dw / 2,
    };
    let dy = match anchor {
        "top_left" | "top" | "top_right" => 0,
        "bottom_left" | "bottom" | "bottom_right" => dh,
        _ => dh / 2,
    };
    (dx, dy)
}
