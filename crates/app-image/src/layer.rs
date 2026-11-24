//! Multi-layer raster stack, blend modes, and CPU compositor for `kogaview-editor`.
//!
//! Design invariants:
//! - Every `Layer.pixels` lives behind `Arc<RgbaImage>` (Copy-on-Write).
//!   Editing one layer never copies sibling layers' pixel buffers.
//! - Single-layer documents (normal PNG/JPEG/WebP files) hit an O(1) zero-copy
//!   fast path in [`composite_stack`], adding zero overhead to flat editing.
//! - Blend modes match W3C Compositing & Blending Level 1 and OpenRaster
//!   (`svg:*` composite-op names) for lossless `.ora` interchange with Krita/GIMP.

use std::sync::Arc;

use image::{Rgba, RgbaImage};
pub use kogaview_protocol::ApplyTarget;
use kogaview_protocol::{LayerAdjustment, UiText};
use serde::{Deserialize, Serialize};

/// Layer blending modes (1:1 with OpenRaster `composite-op` values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlendMode {
    #[default]
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    Difference,
}

impl BlendMode {
    /// OpenRaster `composite-op` attribute string.
    pub fn ora_name(self) -> &'static str {
        match self {
            Self::Normal => "svg:src-over",
            Self::Multiply => "svg:multiply",
            Self::Screen => "svg:screen",
            Self::Overlay => "svg:overlay",
            Self::Darken => "svg:darken",
            Self::Lighten => "svg:lighten",
            Self::Difference => "svg:difference",
        }
    }

    /// Parse an OpenRaster `composite-op` attribute string (unknown falls back to `Normal`).
    pub fn from_ora_name(name: &str) -> Self {
        match name {
            "svg:multiply" => Self::Multiply,
            "svg:screen" => Self::Screen,
            "svg:overlay" => Self::Overlay,
            "svg:darken" => Self::Darken,
            "svg:lighten" => Self::Lighten,
            "svg:difference" => Self::Difference,
            _ => Self::Normal,
        }
    }

    /// Parse a wire/UI key string.
    pub fn from_key(key: &str) -> Self {
        match key {
            "multiply" => Self::Multiply,
            "screen" => Self::Screen,
            "overlay" => Self::Overlay,
            "darken" => Self::Darken,
            "lighten" => Self::Lighten,
            "difference" => Self::Difference,
            _ => Self::Normal,
        }
    }

    pub fn as_key(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Multiply => "multiply",
            Self::Screen => "screen",
            Self::Overlay => "overlay",
            Self::Darken => "darken",
            Self::Lighten => "lighten",
            Self::Difference => "difference",
        }
    }
}

/// One raster layer in a document stack.
#[derive(Debug, Clone)]
pub struct Layer {
    pub id: u64,
    pub name: String,
    pub visible: bool,
    pub locked: bool,
    pub opacity: f32,
    pub blend_mode: BlendMode,
    pub offset_x: i32,
    pub offset_y: i32,
    pub pixels: Arc<RgbaImage>,
    /// Optional layer-local baseline pixels captured before destructive alpha
    /// edits (e.g. Remove Background) so Refine Alpha Restore recovers this layer.
    pub original: Option<Arc<RgbaImage>>,
    /// Optional non-destructive 8-bit grayscale transparency mask matching
    /// `pixels.dimensions()` (`255` = revealed, `0` = hidden).
    pub mask: Option<Arc<Vec<u8>>>,
    /// Whether `mask` is currently applied during compositing.
    pub mask_enabled: bool,
    /// Whether paint/shape/fill operations target `mask` instead of `pixels`.
    pub editing_mask: bool,
    /// When `true`, moving the layer moves its mask together; when `false`,
    /// layer pixels and mask move independently via `mask_offset_x/y`.
    pub mask_linked: bool,
    pub mask_offset_x: i32,
    pub mask_offset_y: i32,
    /// When `Some`, this is a non-destructive Adjustment Layer applied live to
    /// the composited canvas underneath it (respecting `opacity`, `blend_mode`, and `mask`).
    pub adjustment: Option<LayerAdjustment>,
}

impl Layer {
    pub fn new(id: u64, name: impl Into<String>, pixels: Arc<RgbaImage>) -> Self {
        Self {
            id,
            name: name.into(),
            visible: true,
            locked: false,
            opacity: 1.0,
            blend_mode: BlendMode::Normal,
            offset_x: 0,
            offset_y: 0,
            original: Some(Arc::clone(&pixels)),
            pixels,
            mask: None,
            mask_enabled: true,
            editing_mask: false,
            mask_linked: true,
            mask_offset_x: 0,
            mask_offset_y: 0,
            adjustment: None,
        }
    }

    pub fn dimensions(&self) -> (u32, u32) {
        self.pixels.dimensions()
    }

    /// True when every pixel in this layer is completely transparent (`alpha == 0`).
    pub fn is_empty(&self) -> bool {
        !self.pixels.pixels().any(|p| p.0[3] > 0)
    }
}

/// Ordered stack of raster layers sharing a document canvas.
#[derive(Debug, Clone)]
pub struct LayerStack {
    pub canvas_width: u32,
    pub canvas_height: u32,
    /// Bottom-to-top order (`layers[0]` is background, `layers.last()` is topmost).
    pub layers: Vec<Layer>,
    pub active_layer_id: u64,
    pub next_id: u64,
    /// Optional solid RGB backdrop composited underneath all layers
    /// (`None` = transparent canvas, `Some([r, g, b])` = opaque canvas background).
    pub background: Option<[u8; 3]>,
}

/// Serializable layer mutation recorded in History and Undo/Redo.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "layer_op", rename_all = "snake_case")]
pub enum LayerOperation {
    AddEmpty {
        name: String,
    },
    AddImage {
        name: String,
        offset_x: i32,
        offset_y: i32,
        #[serde(skip)]
        pixels: Arc<RgbaImage>,
    },
    Duplicate {
        id: u64,
    },
    Delete {
        id: u64,
    },
    Reorder {
        id: u64,
        new_index: usize,
    },
    SetProps {
        id: u64,
        name: Option<String>,
        visible: Option<bool>,
        locked: Option<bool>,
        opacity: Option<f32>,
        blend_mode: Option<BlendMode>,
        offset_x: Option<i32>,
        offset_y: Option<i32>,
    },
    MergeDown {
        id: u64,
    },
    Flatten,
    SetCanvasBackground {
        color: Option<[u8; 3]>,
    },
    /// Attach a non-destructive transparency mask to `id`.
    AddMask {
        id: u64,
        reveal_all: bool,
        #[serde(skip)]
        initial: Option<Arc<Vec<u8>>>,
    },
    /// Remove the transparency mask from `id` without altering its RGB pixels.
    DeleteMask {
        id: u64,
    },
    /// Bake the transparency mask permanently into `id`'s alpha channel.
    ApplyMask {
        id: u64,
    },
    /// Invert every value (`v -> 255 - v`) of `id`'s transparency mask.
    InvertMask {
        id: u64,
    },
    /// Enable or temporarily bypass `id`'s transparency mask.
    SetMaskEnabled {
        id: u64,
        enabled: bool,
    },
    /// Switch whether brush/shape/fill edits target `id`'s mask or its pixels.
    SetEditingMask {
        id: u64,
        editing: bool,
    },
    /// Link or unlink layer `id`'s pixels and transparency mask during moves.
    SetMaskLinked {
        id: u64,
        linked: bool,
    },
    /// Add a non-destructive Adjustment Layer above the active layer.
    AddAdjustment {
        name: String,
        adjustment: LayerAdjustment,
    },
    /// Update live parameters of an existing Adjustment Layer.
    UpdateAdjustment {
        id: u64,
        adjustment: LayerAdjustment,
    },
}

impl LayerOperation {
    pub fn label(&self) -> UiText {
        match self {
            Self::AddEmpty { name } | Self::AddImage { name, .. } => {
                UiText::with("layer_add", [name.clone()])
            }
            Self::Duplicate { .. } => UiText::new("layer_duplicate"),
            Self::Delete { .. } => UiText::new("layer_delete"),
            Self::Reorder { .. } => UiText::new("layer_reorder"),
            Self::SetProps { .. } => UiText::new("layer_props"),
            Self::MergeDown { .. } => UiText::new("layer_merge_down"),
            Self::Flatten => UiText::new("layer_flatten"),
            Self::SetCanvasBackground { .. } => UiText::new("canvas_background"),
            Self::AddMask { .. } => UiText::new("layer_mask_add"),
            Self::DeleteMask { .. } => UiText::new("layer_mask_delete"),
            Self::ApplyMask { .. } => UiText::new("layer_mask_apply"),
            Self::InvertMask { .. } => UiText::new("layer_mask_invert"),
            Self::SetMaskEnabled { .. } => UiText::new("layer_mask_toggle"),
            Self::SetEditingMask { .. } => UiText::new("layer_mask_edit"),
            Self::SetMaskLinked { .. } => UiText::new("layer_mask_link"),
            Self::AddAdjustment { .. } => UiText::new("layer_adjustment_add"),
            Self::UpdateAdjustment { .. } => UiText::new("layer_adjustment_update"),
        }
    }
}

impl LayerStack {
    /// Build a single-layer stack from a flat image (the default when opening PNG/JPG/WebP).
    pub fn from_single(image: Arc<RgbaImage>) -> Self {
        let (canvas_width, canvas_height) = image.dimensions();
        let bg = Layer::new(1, "Background", image);
        Self {
            canvas_width,
            canvas_height,
            layers: vec![bg],
            active_layer_id: 1,
            next_id: 2,
            background: None,
        }
    }

    pub fn index_of(&self, id: u64) -> Option<usize> {
        self.layers.iter().position(|l| l.id == id)
    }

    pub fn active_index(&self) -> usize {
        self.index_of(self.active_layer_id).unwrap_or(0)
    }

    pub fn active_layer(&self) -> &Layer {
        &self.layers[self.active_index()]
    }

    pub fn active_layer_mut(&mut self) -> &mut Layer {
        let idx = self.active_index();
        &mut self.layers[idx]
    }

    pub fn select(&mut self, id: u64) -> Result<bool, UiText> {
        if self.index_of(id).is_none() {
            return Err(UiText::new("layer_not_found"));
        }
        if self.active_layer_id == id {
            return Ok(false);
        }
        self.active_layer_id = id;
        Ok(true)
    }

    /// Apply a structural or property [`LayerOperation`] directly to the stack.
    /// Returns `Ok(true)` if the stack changed, `Ok(false)` if no-op.
    pub fn apply_op(&mut self, op: &LayerOperation) -> Result<bool, UiText> {
        match op {
            LayerOperation::AddEmpty { name } => {
                let id = self.next_id;
                self.next_id += 1;
                let blank = Arc::new(RgbaImage::from_pixel(
                    self.canvas_width,
                    self.canvas_height,
                    Rgba([0, 0, 0, 0]),
                ));
                let label = if name.trim().is_empty() {
                    format!("Layer {id}")
                } else {
                    name.trim().to_owned()
                };
                let insert_at = (self.active_index() + 1).min(self.layers.len());
                self.layers.insert(insert_at, Layer::new(id, label, blank));
                self.active_layer_id = id;
                Ok(true)
            }
            LayerOperation::AddImage {
                name,
                offset_x,
                offset_y,
                pixels,
            } => {
                let id = self.next_id;
                self.next_id += 1;
                let label = if name.trim().is_empty() {
                    format!("Layer {id}")
                } else {
                    name.trim().to_owned()
                };
                let mut layer = Layer::new(id, label, Arc::clone(pixels));
                layer.offset_x = *offset_x;
                layer.offset_y = *offset_y;
                let insert_at = (self.active_index() + 1).min(self.layers.len());
                self.layers.insert(insert_at, layer);
                self.active_layer_id = id;
                Ok(true)
            }
            LayerOperation::Duplicate { id } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                let new_id = self.next_id;
                self.next_id += 1;
                let mut copy = self.layers[idx].clone();
                copy.id = new_id;
                copy.name = format!("{} copy", copy.name);
                copy.locked = false;
                self.layers.insert(idx + 1, copy);
                self.active_layer_id = new_id;
                Ok(true)
            }
            LayerOperation::Delete { id } => {
                if self.layers.len() <= 1 {
                    return Err(UiText::new("cannot_delete_last_layer"));
                }
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].locked {
                    return Err(UiText::new("layer_locked"));
                }
                self.layers.remove(idx);
                if self.active_layer_id == *id {
                    let next_idx = idx.saturating_sub(1).min(self.layers.len() - 1);
                    self.active_layer_id = self.layers[next_idx].id;
                }
                Ok(true)
            }
            LayerOperation::Reorder { id, new_index } => {
                let Some(old_idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                let clamped = (*new_index).min(self.layers.len() - 1);
                if old_idx == clamped {
                    return Ok(false);
                }
                let layer = self.layers.remove(old_idx);
                self.layers.insert(clamped, layer);
                Ok(true)
            }
            LayerOperation::SetProps {
                id,
                name,
                visible,
                locked,
                opacity,
                blend_mode,
                offset_x,
                offset_y,
            } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                let layer = &mut self.layers[idx];
                let mut changed = false;
                if let Some(n) = name {
                    let trimmed = n.trim();
                    if !trimmed.is_empty() && layer.name != trimmed {
                        layer.name = trimmed.to_owned();
                        changed = true;
                    }
                }
                if let Some(v) = *visible {
                    if layer.visible != v {
                        layer.visible = v;
                        changed = true;
                    }
                }
                if let Some(l) = *locked {
                    if layer.locked != l {
                        layer.locked = l;
                        changed = true;
                    }
                }
                if let Some(op) = *opacity {
                    let c = op.clamp(0.0, 1.0);
                    if (layer.opacity - c).abs() > 1e-4 {
                        layer.opacity = c;
                        changed = true;
                    }
                }
                if let Some(bm) = *blend_mode {
                    if layer.blend_mode != bm {
                        layer.blend_mode = bm;
                        changed = true;
                    }
                }
                if let Some(ox) = *offset_x {
                    if layer.locked {
                        return Err(UiText::new("layer_locked"));
                    }
                    let dx = ox - layer.offset_x;
                    if dx != 0 {
                        if layer.mask.is_some() && !layer.mask_linked && layer.editing_mask {
                            layer.mask_offset_x += dx;
                        } else {
                            layer.offset_x = ox;
                            if layer.mask.is_some() && !layer.mask_linked {
                                layer.mask_offset_x -= dx;
                            }
                        }
                        changed = true;
                    }
                }
                if let Some(oy) = *offset_y {
                    if layer.locked {
                        return Err(UiText::new("layer_locked"));
                    }
                    let dy = oy - layer.offset_y;
                    if dy != 0 {
                        if layer.mask.is_some() && !layer.mask_linked && layer.editing_mask {
                            layer.mask_offset_y += dy;
                        } else {
                            layer.offset_y = oy;
                            if layer.mask.is_some() && !layer.mask_linked {
                                layer.mask_offset_y -= dy;
                            }
                        }
                        changed = true;
                    }
                }
                Ok(changed)
            }
            LayerOperation::MergeDown { id } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if idx == 0 {
                    return Err(UiText::new("cannot_merge_bottom_layer"));
                }
                if self.layers[idx].locked || self.layers[idx - 1].locked {
                    return Err(UiText::new("layer_locked"));
                }
                let merged = composite_pair(
                    self.canvas_width,
                    self.canvas_height,
                    &self.layers[idx - 1],
                    &self.layers[idx],
                );
                let target = &mut self.layers[idx - 1];
                target.pixels = Arc::new(merged);
                target.original = Some(Arc::clone(&target.pixels));
                target.offset_x = 0;
                target.offset_y = 0;
                target.opacity = 1.0;
                target.blend_mode = BlendMode::Normal;
                target.visible = true;
                let kept_id = target.id;
                self.layers.remove(idx);
                self.active_layer_id = kept_id;
                Ok(true)
            }
            LayerOperation::Flatten => {
                if self.layers.len() == 1
                    && self.background.is_none()
                    && self.layers[0].visible
                    && (self.layers[0].opacity - 1.0).abs() < 1e-4
                    && self.layers[0].blend_mode == BlendMode::Normal
                    && self.layers[0].offset_x == 0
                    && self.layers[0].offset_y == 0
                    && self.layers[0].dimensions() == (self.canvas_width, self.canvas_height)
                {
                    return Ok(false);
                }
                let flat = composite_stack(self);
                let id = self.next_id;
                self.next_id += 1;
                self.layers = vec![Layer::new(id, "Background", flat)];
                self.active_layer_id = id;
                self.background = None;
                Ok(true)
            }
            LayerOperation::SetCanvasBackground { color } => {
                if self.background == *color {
                    return Ok(false);
                }
                self.background = *color;
                Ok(true)
            }
            LayerOperation::AddMask {
                id,
                reveal_all,
                initial,
            } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].locked {
                    return Err(UiText::new("layer_locked"));
                }
                let (lw, lh) = self.layers[idx].dimensions();
                let expected = (lw as usize) * (lh as usize);
                let data = match initial {
                    Some(buf) if buf.len() == expected => Arc::clone(buf),
                    _ => Arc::new(vec![if *reveal_all { 255u8 } else { 0u8 }; expected]),
                };
                self.layers[idx].mask = Some(data);
                self.layers[idx].mask_enabled = true;
                self.layers[idx].editing_mask = true;
                self.layers[idx].mask_linked = true;
                self.layers[idx].mask_offset_x = 0;
                self.layers[idx].mask_offset_y = 0;
                self.active_layer_id = *id;
                Ok(true)
            }
            LayerOperation::DeleteMask { id } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].locked {
                    return Err(UiText::new("layer_locked"));
                }
                if self.layers[idx].mask.is_none() {
                    return Ok(false);
                }
                self.layers[idx].mask = None;
                self.layers[idx].mask_enabled = true;
                self.layers[idx].editing_mask = false;
                Ok(true)
            }
            LayerOperation::ApplyMask { id } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].locked {
                    return Err(UiText::new("layer_locked"));
                }
                let Some(mask) = self.layers[idx].mask.take() else {
                    return Ok(false);
                };
                let (lw, lh) = self.layers[idx].dimensions();
                if mask.len() == (lw as usize) * (lh as usize) {
                    let mut next = (*self.layers[idx].pixels).clone();
                    for y in 0..lh {
                        let row = (y as usize) * (lw as usize);
                        for x in 0..lw {
                            let m = mask[row + x as usize] as u16;
                            let px = next.get_pixel_mut(x, y);
                            px.0[3] = ((px.0[3] as u16 * m + 127) / 255) as u8;
                        }
                    }
                    self.layers[idx].pixels = Arc::new(next);
                }
                self.layers[idx].mask_enabled = true;
                self.layers[idx].editing_mask = false;
                Ok(true)
            }
            LayerOperation::InvertMask { id } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].locked {
                    return Err(UiText::new("layer_locked"));
                }
                let Some(mask) = &self.layers[idx].mask else {
                    return Ok(false);
                };
                let inverted: Vec<u8> = mask.iter().map(|&v| 255 - v).collect();
                self.layers[idx].mask = Some(Arc::new(inverted));
                Ok(true)
            }
            LayerOperation::SetMaskEnabled { id, enabled } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].mask.is_none() || self.layers[idx].mask_enabled == *enabled {
                    return Ok(false);
                }
                self.layers[idx].mask_enabled = *enabled;
                Ok(true)
            }
            LayerOperation::SetEditingMask { id, editing } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                let want = *editing && self.layers[idx].mask.is_some();
                if self.layers[idx].editing_mask == want && self.active_layer_id == *id {
                    return Ok(false);
                }
                self.layers[idx].editing_mask = want;
                self.active_layer_id = *id;
                Ok(true)
            }
            LayerOperation::SetMaskLinked { id, linked } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].mask.is_none() || self.layers[idx].mask_linked == *linked {
                    return Ok(false);
                }
                self.layers[idx].mask_linked = *linked;
                Ok(true)
            }
            LayerOperation::AddAdjustment { name, adjustment } => {
                let id = self.next_id;
                self.next_id += 1;
                let default_name = match adjustment {
                    LayerAdjustment::BrightnessContrast { .. } => "Brightness / Contrast",
                    LayerAdjustment::Hsv { .. } => "HSV Adjustment",
                    LayerAdjustment::ColorBalance { .. } => "Color Balance",
                    LayerAdjustment::Invert => "Invert",
                    LayerAdjustment::Desaturate => "Black & White",
                };
                let label = if name.trim().is_empty() {
                    default_name.to_owned()
                } else {
                    name.trim().to_owned()
                };
                // Canvas-sized 1x1 dummy pixel buffer isn't used for RGB, but keep canvas
                // dimensions so attaching a transparency mask to an Adjustment Layer works cleanly!
                let blank = Arc::new(RgbaImage::from_pixel(
                    self.canvas_width.max(1),
                    self.canvas_height.max(1),
                    Rgba([0, 0, 0, 0]),
                ));
                let mut layer = Layer::new(id, label, blank);
                layer.adjustment = Some(adjustment.clone());
                let insert_at = (self.active_index() + 1).min(self.layers.len());
                self.layers.insert(insert_at, layer);
                self.active_layer_id = id;
                Ok(true)
            }
            LayerOperation::UpdateAdjustment { id, adjustment } => {
                let Some(idx) = self.index_of(*id) else {
                    return Err(UiText::new("layer_not_found"));
                };
                if self.layers[idx].locked {
                    return Err(UiText::new("layer_locked"));
                }
                if self.layers[idx].adjustment.as_ref() == Some(adjustment) {
                    return Ok(false);
                }
                self.layers[idx].adjustment = Some(adjustment.clone());
                Ok(true)
            }
        }
    }
}

/// Composite all visible layers in `stack` onto a `canvas_width × canvas_height` RGBA buffer.
///
/// Zero-copy O(1) fast path for unmodified single-layer images with transparent canvas background.
pub fn composite_stack(stack: &LayerStack) -> Arc<RgbaImage> {
    if stack.layers.len() == 1 && stack.background.is_none() {
        let l = &stack.layers[0];
        if l.visible
            && (l.opacity - 1.0).abs() < 1e-4
            && l.blend_mode == BlendMode::Normal
            && l.offset_x == 0
            && l.offset_y == 0
            && l.adjustment.is_none()
            && (l.mask.is_none() || !l.mask_enabled)
            && l.dimensions() == (stack.canvas_width, stack.canvas_height)
        {
            return Arc::clone(&l.pixels);
        }
    }
    let base_px = match stack.background {
        Some([r, g, b]) => Rgba([r, g, b, 255]),
        None => Rgba([0, 0, 0, 0]),
    };
    let mut canvas = RgbaImage::from_pixel(
        stack.canvas_width.max(1),
        stack.canvas_height.max(1),
        base_px,
    );
    for layer in &stack.layers {
        if !layer.visible || layer.opacity <= 1e-4 {
            continue;
        }
        blend_layer_onto(&mut canvas, layer);
    }
    Arc::new(canvas)
}

/// Composite only the visible layers within `range` onto a canvas-sized buffer
/// (used to build below-active and above-active Transform live previews).
/// When `range.start == 0`, includes the document's solid `canvas_background` if set.
/// Fast-path: when no visible layers fall in `range`, returns a 1×1 pixel buffer
/// (4 bytes instead of tens of MB) that Qt stretches at zero GPU cost.
pub fn composite_range(stack: &LayerStack, range: std::ops::Range<usize>) -> RgbaImage {
    let base_px = if range.start == 0 {
        match stack.background {
            Some([r, g, b]) => Rgba([r, g, b, 255]),
            None => Rgba([0, 0, 0, 0]),
        }
    } else {
        Rgba([0, 0, 0, 0])
    };
    let end = range.end.min(stack.layers.len());
    let has_visible =
        (range.start..end).any(|idx| stack.layers[idx].visible && stack.layers[idx].opacity > 1e-4);
    if !has_visible {
        return RgbaImage::from_pixel(1, 1, base_px);
    }
    let mut canvas = RgbaImage::from_pixel(
        stack.canvas_width.max(1),
        stack.canvas_height.max(1),
        base_px,
    );
    for idx in range.start..end {
        let layer = &stack.layers[idx];
        if !layer.visible || layer.opacity <= 1e-4 {
            continue;
        }
        blend_layer_onto(&mut canvas, layer);
    }
    canvas
}

/// Composite two layers (`bottom`, then `top`) onto a full canvas-sized image (used by `MergeDown`).
fn composite_pair(canvas_w: u32, canvas_h: u32, bottom: &Layer, top: &Layer) -> RgbaImage {
    let mut canvas = RgbaImage::from_pixel(canvas_w.max(1), canvas_h.max(1), Rgba([0, 0, 0, 0]));
    if bottom.visible && bottom.opacity > 1e-4 {
        blend_layer_onto(&mut canvas, bottom);
    }
    if top.visible && top.opacity > 1e-4 {
        blend_layer_onto(&mut canvas, top);
    }
    canvas
}

#[inline]
fn blend_channel(mode: BlendMode, dst: f32, src: f32) -> f32 {
    match mode {
        BlendMode::Normal => src,
        BlendMode::Multiply => dst * src,
        BlendMode::Screen => 1.0 - (1.0 - dst) * (1.0 - src),
        BlendMode::Overlay => {
            if dst < 0.5 {
                2.0 * dst * src
            } else {
                1.0 - 2.0 * (1.0 - dst) * (1.0 - src)
            }
        }
        BlendMode::Darken => dst.min(src),
        BlendMode::Lighten => dst.max(src),
        BlendMode::Difference => (dst - src).abs(),
    }
}

/// Blend `layer` onto `canvas` using exact W3C Compositing & Blending Level 1 math.
/// When `layer.adjustment` is `Some`, applies the non-destructive adjustment live to
/// `canvas` respecting `layer.opacity`, `layer.blend_mode`, and `layer.mask`.
pub fn blend_layer_onto(canvas: &mut RgbaImage, layer: &Layer) {
    let (cw, ch) = canvas.dimensions();
    if let Some(adj) = &layer.adjustment {
        let adjusted = match adj {
            LayerAdjustment::BrightnessContrast {
                brightness,
                contrast,
                saturation,
            } => crate::pixels::adjust_color(canvas, *brightness, *contrast, *saturation),
            LayerAdjustment::Hsv {
                hue,
                saturation,
                value,
            } => crate::pixels::adjust_hsv(canvas, *hue, *saturation, *value),
            LayerAdjustment::ColorBalance {
                shadows,
                midtones,
                highlights,
                preserve_luminosity,
            } => crate::pixels::color_balance(
                canvas,
                *shadows,
                *midtones,
                *highlights,
                *preserve_luminosity,
            ),
            LayerAdjustment::Invert => {
                let mut out = canvas.clone();
                for px in out.pixels_mut() {
                    px.0[0] = 255 - px.0[0];
                    px.0[1] = 255 - px.0[1];
                    px.0[2] = 255 - px.0[2];
                }
                out
            }
            LayerAdjustment::Desaturate => {
                let mut out = canvas.clone();
                for px in out.pixels_mut() {
                    let g = (0.2126 * f32::from(px.0[0])
                        + 0.7152 * f32::from(px.0[1])
                        + 0.0722 * f32::from(px.0[2]))
                    .round()
                    .clamp(0.0, 255.0) as u8;
                    px.0[0] = g;
                    px.0[1] = g;
                    px.0[2] = g;
                }
                out
            }
        };
        let opacity = layer.opacity.clamp(0.0, 1.0);
        let (lw, lh) = layer.dimensions();
        let active_mask = if layer.mask_enabled {
            layer.mask.as_deref().filter(|m| m.len() == (lw as usize) * (lh as usize))
        } else {
            None
        };
        let mode = layer.blend_mode;
        for y in 0..ch {
            for x in 0..cw {
                let m = match active_mask {
                    Some(mask) if x < lw && y < lh => {
                        mask[(y as usize) * (lw as usize) + (x as usize)] as f32 / 255.0
                    }
                    Some(_) => 0.0,
                    None => 1.0,
                };
                let t = (opacity * m).clamp(0.0, 1.0);
                if t <= 1e-5 {
                    continue;
                }
                let dp = canvas.get_pixel(x, y).0;
                let sp = adjusted.get_pixel(x, y).0;
                let mix = |d: u8, s: u8| -> u8 {
                    let df = f32::from(d) / 255.0;
                    let sf = f32::from(s) / 255.0;
                    let b = blend_channel(mode, df, sf);
                    ((df * (1.0 - t) + b * t) * 255.0)
                        .round()
                        .clamp(0.0, 255.0) as u8
                };
                canvas.put_pixel(
                    x,
                    y,
                    Rgba([mix(dp[0], sp[0]), mix(dp[1], sp[1]), mix(dp[2], sp[2]), dp[3]]),
                );
            }
        }
        return;
    }

    let (lw, lh) = layer.pixels.dimensions();
    let ox = layer.offset_x;
    let oy = layer.offset_y;

    let x_start = ox.max(0);
    let y_start = oy.max(0);
    let x_end = (ox + lw as i32).min(cw as i32);
    let y_end = (oy + lh as i32).min(ch as i32);
    if x_start >= x_end || y_start >= y_end {
        return;
    }

    let opacity = layer.opacity.clamp(0.0, 1.0);
    let mode = layer.blend_mode;
    let active_mask = if layer.mask_enabled {
        layer.mask.as_deref().filter(|m| m.len() == (lw as usize) * (lh as usize))
    } else {
        None
    };

    let mox = layer.mask_offset_x;
    let moy = layer.mask_offset_y;

    for cy in y_start..y_end {
        let ly = (cy - oy) as u32;
        let my = ly as i32 - moy;
        for cx in x_start..x_end {
            let lx = (cx - ox) as u32;
            let sp = layer.pixels.get_pixel(lx, ly);
            let mask_factor = match active_mask {
                Some(m) => {
                    let mx = lx as i32 - mox;
                    if mx >= 0 && my >= 0 && (mx as u32) < lw && (my as u32) < lh {
                        m[(my as usize) * (lw as usize) + (mx as usize)] as f32 / 255.0
                    } else {
                        0.0
                    }
                }
                None => 1.0,
            };
            let sa = (sp[3] as f32 / 255.0) * opacity * mask_factor;
            if sa <= 1e-5 {
                continue;
            }
            let dp = canvas.get_pixel(cx as u32, cy as u32);
            let da = dp[3] as f32 / 255.0;

            if da <= 1e-5 && mode == BlendMode::Normal {
                let out_a = (sa * 255.0).round().clamp(0.0, 255.0) as u8;
                canvas.put_pixel(cx as u32, cy as u32, Rgba([sp[0], sp[1], sp[2], out_a]));
                continue;
            }

            let sr = sp[0] as f32 / 255.0;
            let sg = sp[1] as f32 / 255.0;
            let sb = sp[2] as f32 / 255.0;
            let dr = dp[0] as f32 / 255.0;
            let dg = dp[1] as f32 / 255.0;
            let db = dp[2] as f32 / 255.0;

            let br = blend_channel(mode, dr, sr);
            let bg = blend_channel(mode, dg, sg);
            let bb = blend_channel(mode, db, sb);

            // W3C Porter-Duff src-over with separable blend function B(Cb, Cs):
            // Cs_eff = (1 - da) * Cs + da * B(Cb, Cs)
            // Co * ao = sa * Cs_eff + (1 - sa) * da * Cb
            let out_a = sa + da * (1.0 - sa);
            if out_a <= 1e-5 {
                canvas.put_pixel(cx as u32, cy as u32, Rgba([0, 0, 0, 0]));
                continue;
            }
            let r_eff = (1.0 - da) * sr + da * br;
            let g_eff = (1.0 - da) * sg + da * bg;
            let b_eff = (1.0 - da) * sb + da * bb;

            let out_r = ((sa * r_eff + (1.0 - sa) * da * dr) / out_a * 255.0)
                .round()
                .clamp(0.0, 255.0) as u8;
            let out_g = ((sa * g_eff + (1.0 - sa) * da * dg) / out_a * 255.0)
                .round()
                .clamp(0.0, 255.0) as u8;
            let out_b = ((sa * b_eff + (1.0 - sa) * da * db) / out_a * 255.0)
                .round()
                .clamp(0.0, 255.0) as u8;
            let out_au = (out_a * 255.0).round().clamp(0.0, 255.0) as u8;

            canvas.put_pixel(cx as u32, cy as u32, Rgba([out_r, out_g, out_b, out_au]));
        }
    }
}
