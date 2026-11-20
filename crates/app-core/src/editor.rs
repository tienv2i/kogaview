//! The Editor working document.
//!
//! Editing follows the model a raster editor uses: opening an image decodes it
//! once into a *working document* that edits are applied to directly, while the
//! source file stays untouched. Undo/redo walk a stack of applied operations.
//!
//! Every operation is described by a serializable [`EditOperation`], so the
//! history the user sees is a typed list rather than pixels. Operations that are
//! losslessly invertible (rotate, flip) undo by applying their inverse; crop and
//! resize keep the previous pixels in the step, because the discarded pixels
//! cannot be recreated from parameters alone. Snapshots are bounded so a long
//! session cannot grow without limit.
//!
//! Pixels live behind `Arc`, so a preview render can run on a worker thread
//! without copying the whole buffer. This module owns pixels and history only;
//! file paths, the command gateway and UI state stay in Core.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::Arc;

use image::imageops::{self, FilterType};
use image::{DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, ImageReader, RgbaImage};
use kogaview_protocol::FlipAxis;
use serde::Serialize;

use crate::state::UiText;

/// Refuse documents larger than this; a full RGBA buffer at 80 MP is already
/// 320 MB and this slice has no tiling, so a bigger image would risk the app
/// instead of editing it. The message says so rather than failing silently.
pub const MAX_DOCUMENT_PIXELS: u64 = 80_000_000;

/// Longest edge of the PNG handed to QML. The document keeps full resolution;
/// the preview exists so each edit renders in a frame, not a second.
pub const PREVIEW_LONG_EDGE: u32 = 2048;

/// Keep the undo stack shallow and the pixel snapshots it holds bounded.
const MAX_HISTORY_STEPS: usize = 12;
const MAX_SNAPSHOT_BYTES: u64 = 160 * 1024 * 1024;

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
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    },
    Resize {
        width: u32,
        height: u32,
        /// When present, scale the whole source to fit inside the target and
        /// fill the leftover with this RGB colour. Without it the target aspect
        /// is filled by a centred crop instead.
        fill: Option<[u8; 3]>,
    },
    /// A perspective correction: `corners` are the four points of the
    /// quadrilateral, in document pixels and clockwise from the top-left
    /// (TL, TR, BR, BL) that become the whole output frame. The output keeps
    /// the document's width and height, so straightening a keystone keeps the
    /// frame the picture already had and only reshapes what is inside it.
    Transform {
        corners: [[f64; 2]; 4],
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
            } => UiText::with(
                "crop",
                [
                    width.to_string(),
                    height.to_string(),
                    x.to_string(),
                    y.to_string(),
                ],
            ),
            Self::Resize {
                width,
                height,
                fill,
            } => match fill {
                Some([r, g, b]) => UiText::with(
                    "resize_pad",
                    [
                        width.to_string(),
                        height.to_string(),
                        format!("#{r:02x}{g:02x}{b:02x}"),
                    ],
                ),
                None => UiText::with("resize", [width.to_string(), height.to_string()]),
            },
            Self::Transform { .. } => UiText::new("transform"),
        }
    }
}

/// How a step is undone. `Invert` re-applies an operation that is its own
/// inverse (flip) or the exact opposite rotation; `Snapshot` restores pixels.
enum Undo {
    Invert(EditOperation),
    Snapshot(Arc<RgbaImage>),
}

struct Step {
    operation: EditOperation,
    undo: Undo,
}

/// File format a save writes. Decided by the destination's extension, so what
/// the user names the file is what they get.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveFormat {
    Png,
    Jpeg,
    Webp,
    Tiff,
    Gif,
    Bmp,
    Tga,
    Qoi,
}

impl SaveFormat {
    /// `None` for an extension this slice cannot encode; the caller turns that
    /// into a user-facing error naming the formats that work.
    pub fn from_path(path: &Path) -> Option<Self> {
        let extension = path.extension()?.to_str()?.to_ascii_lowercase();
        Some(match extension.as_str() {
            "png" => Self::Png,
            "jpg" | "jpeg" | "jpe" | "jfif" => Self::Jpeg,
            "webp" => Self::Webp,
            "tif" | "tiff" => Self::Tiff,
            "gif" => Self::Gif,
            "bmp" => Self::Bmp,
            "tga" => Self::Tga,
            "qoi" => Self::Qoi,
            _ => return None,
        })
    }

    /// The dotted extension the file list shows for this style.
    pub fn label(self) -> &'static str {
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

    /// The list every surface shows for "what can I save to".
    pub const CHOICES: &'static str = ".png .jpg .webp .tiff .gif .bmp .tga .qoi";
}

/// Encoded bytes for `image` in `format`. JPEG has no alpha, so it is
/// composited over white instead of silently turning transparency black.
pub fn encode(image: &RgbaImage, format: SaveFormat) -> Result<Vec<u8>, String> {
    encode_with(image, format, None)
}

/// The quality a save uses when the caller does not pick one. Export lets the
/// user choose; Save stays predictable.
pub const DEFAULT_JPEG_QUALITY: u8 = 92;

/// Encode `image`, with `quality` (1–100) applied to the lossy encoders. Only
/// JPEG is lossy in this build; the WebP encoder is lossless, so a quality
/// value is ignored there rather than silently degrading a lossless file.
pub fn encode_with(
    image: &RgbaImage,
    format: SaveFormat,
    quality: Option<u8>,
) -> Result<Vec<u8>, String> {
    let quality = quality
        .map(|value| value.clamp(1, 100))
        .unwrap_or(DEFAULT_JPEG_QUALITY);
    let mut bytes = Vec::new();
    match format {
        SaveFormat::Jpeg => {
            let rgb = image::RgbImage::from_fn(image.width(), image.height(), |x, y| {
                let pixel = image.get_pixel(x, y).0;
                let alpha = u32::from(pixel[3]);
                let over = |channel: u8| -> u8 {
                    ((u32::from(channel) * alpha + 255 * (255 - alpha)) / 255) as u8
                };
                image::Rgb([over(pixel[0]), over(pixel[1]), over(pixel[2])])
            });
            let mut encoder =
                image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, quality);
            encoder
                .encode_image(&rgb)
                .map_err(|error| format!("could not encode JPEG: {error}"))?;
        }
        SaveFormat::Gif => {
            // GIF carries at most 256 colours; `save_with_format` quantises.
            let mut cursor = std::io::Cursor::new(bytes);
            DynamicImage::ImageRgba8(image.clone())
                .write_to(&mut cursor, ImageFormat::Gif)
                .map_err(|error| format!("could not encode GIF: {error}"))?;
            bytes = cursor.into_inner();
        }
        other => {
            // `image` has no lossless WebP encoder, so that one is the
            // dedicated lossless encoder; the rest encode RGB(A) pixels
            // directly.
            if other == SaveFormat::Webp {
                let mut cursor = std::io::Cursor::new(bytes);
                let encoder = image::codecs::webp::WebPEncoder::new_lossless(&mut cursor);
                encoder
                    .write_image(
                        image.as_raw(),
                        image.width(),
                        image.height(),
                        ExtendedColorType::Rgba8,
                    )
                    .map_err(|error| format!("could not encode WebP: {error}"))?;
                return Ok(cursor.into_inner());
            }
            let target = match other {
                SaveFormat::Png => ImageFormat::Png,
                SaveFormat::Tiff => ImageFormat::Tiff,
                SaveFormat::Bmp => ImageFormat::Bmp,
                SaveFormat::Tga => ImageFormat::Tga,
                SaveFormat::Qoi => ImageFormat::Qoi,
                SaveFormat::Jpeg | SaveFormat::Gif | SaveFormat::Webp => unreachable!(),
            };
            let mut cursor = std::io::Cursor::new(bytes);
            let encoded = match target {
                ImageFormat::Png => image::codecs::png::PngEncoder::new(&mut cursor).write_image(
                    image.as_raw(),
                    image.width(),
                    image.height(),
                    ExtendedColorType::Rgba8,
                ),
                ImageFormat::Tiff => image::codecs::tiff::TiffEncoder::new(&mut cursor)
                    .write_image(
                        image.as_raw(),
                        image.width(),
                        image.height(),
                        ExtendedColorType::Rgba8,
                    ),
                ImageFormat::Bmp => image::codecs::bmp::BmpEncoder::new(&mut cursor).write_image(
                    image.as_raw(),
                    image.width(),
                    image.height(),
                    ExtendedColorType::Rgba8,
                ),
                ImageFormat::Tga => image::codecs::tga::TgaEncoder::new(&mut cursor).write_image(
                    image.as_raw(),
                    image.width(),
                    image.height(),
                    ExtendedColorType::Rgba8,
                ),
                ImageFormat::Qoi => image::codecs::qoi::QoiEncoder::new(&mut cursor).write_image(
                    image.as_raw(),
                    image.width(),
                    image.height(),
                    ExtendedColorType::Rgba8,
                ),
                _ => unreachable!("only the formats above are reachable here"),
            };
            encoded.map_err(|error| format!("could not encode the image: {error}"))?;
            bytes = cursor.into_inner();
        }
    }
    Ok(bytes)
}

/// Write `bytes` to `path` through a temporary file in the same directory and
/// an atomic rename, so a failed save never leaves a half-written image where
/// the user's photo was.
fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".to_owned());
    let temporary = parent.join(format!(".{name}.kogaview-{}.tmp", std::process::id()));
    let write = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, path)
    })();
    if let Err(error) = write {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("could not write {}: {error}", path.display()));
    }
    Ok(())
}

/// Encode `pixels` and write them to `path`.
///
/// When `path` is `source`, the previous bytes are first copied to
/// `<name>.bak` *next to the file*, so a save over the original can still be
/// walked back. A save-as writes only the new file. Takes the source path
/// rather than the document so it can run on a worker: the document is not
/// `Send`-shared and the pixels come as an `Arc`.
pub fn save_pixels(source: &Path, pixels: &RgbaImage, path: &Path) -> Result<(), String> {
    let format = SaveFormat::from_path(path).ok_or_else(|| {
        format!(
            "cannot save as {}; use one of {}",
            path.display(),
            SaveFormat::CHOICES
        )
    })?;
    let bytes = encode(pixels, format)?;
    if path == source && path.is_file() {
        let backup = backup_path(path);
        std::fs::copy(path, &backup).map_err(|error| {
            format!(
                "could not keep a backup of {} at {}: {error}",
                path.display(),
                backup.display()
            )
        })?;
        tracing::debug!(
            target: "kogaview::editor",
            backup = %backup.display(),
            "kept the previous file before overwriting it"
        );
    }
    write_atomically(path, &bytes)
}

/// Write a delivery copy of `pixels`, leaving the document untouched.
///
/// This is `Save as` with the export decisions ADR 0004 deferred: the JPEG
/// quality is the user's, and the source's metadata segments can travel with
/// the picture. Only JPEG→JPEG metadata is transplanted: EXIF, XMP, ICC and
/// IPTC live in APP segments there, while PNG/TIFF metadata would need a
/// different (chunk/IFD) rewrite this slice does not own. The write is atomic
/// like a save, and no `.bak` is made because the target is not the source.
/// The copy's size under a long-edge limit: the aspect is kept, the longer side
/// becomes `max_edge`, and a picture already that small is left alone (an export
/// never upscales). `None` means "encode the pixels as they are"; rounding can
/// never put a side at zero, and the other side is always `<= max_edge` because
/// the longer side maps exactly onto the limit.
fn export_dimensions(source_width: u32, source_height: u32, max_edge: u32) -> Option<(u32, u32)> {
    let longer = source_width.max(source_height);
    if max_edge == 0 || max_edge >= longer {
        return None;
    }
    let scale = |side: u32| {
        let scaled =
            (u64::from(side) * u64::from(max_edge) + u64::from(longer) / 2) / u64::from(longer);
        scaled.clamp(1, u64::from(u32::MAX)) as u32
    };
    Some((scale(source_width), scale(source_height)))
}

pub fn export_pixels(
    source: &Path,
    pixels: &RgbaImage,
    path: &Path,
    quality: Option<u8>,
    metadata: bool,
    max_edge: Option<u32>,
) -> Result<(), String> {
    let format = SaveFormat::from_path(path).ok_or_else(|| {
        format!(
            "cannot export as {}; use one of {}",
            path.display(),
            SaveFormat::CHOICES
        )
    })?;
    // A delivery size is a scale of the whole frame, never a crop: the export
    // keeps everything the document holds. `export_dimensions` answers `None`
    // when the limit would not shrink anything, so the pixels are encoded as
    // they are rather than copied into a same-sized buffer.
    let target = max_edge.and_then(|edge| export_dimensions(pixels.width(), pixels.height(), edge));
    let scaled;
    let (pixels, resized) = match target {
        Some((width, height)) => {
            scaled = imageops::resize(pixels, width, height, FilterType::Triangle);
            (&scaled, true)
        }
        None => (pixels, false),
    };
    let mut bytes = encode_with(pixels, format, quality)?;
    if metadata
        && format == SaveFormat::Jpeg
        && SaveFormat::from_path(source) == Some(SaveFormat::Jpeg)
    {
        match std::fs::read(source) {
            // A resized copy's EXIF still says the source's pixel dimensions and
            // carries the source's thumbnail, so APP1 is dropped; the ICC
            // profile (APP2) and IPTC (APP13) are kept, because colour must not
            // change with the size.
            Ok(original) => bytes = splice_jpeg_metadata_segments(&original, bytes, !resized),
            Err(error) => tracing::warn!(
                target: "kogaview::editor",
                path = %source.display(),
                %error,
                "export without metadata: the source could not be read"
            ),
        }
    }
    write_atomically(path, &bytes)
}

/// The APP segments of a JPEG that carry metadata rather than pixels.
///
/// APP1 holds EXIF and XMP, APP2 the ICC profile, APP13 IPTC/Photoshop data;
/// APP0 is skipped because it describes the JFIF encoding the new file already
/// has. Anything unparsable ends the scan instead of being copied.
fn jpeg_metadata_segments(bytes: &[u8]) -> Vec<(u8, &[u8])> {
    if bytes.len() < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 {
        return Vec::new();
    }
    let mut segments = Vec::new();
    let mut position = 2;
    while position + 4 <= bytes.len() {
        if bytes[position] != 0xFF {
            break;
        }
        let mut marker_at = position;
        while marker_at + 1 < bytes.len() && bytes[marker_at + 1] == 0xFF {
            marker_at += 1;
        }
        let marker = bytes[marker_at + 1];
        let length_at = marker_at + 2;
        // Standalone markers (RSTn, TEM) have no length field.
        if (0xD0..=0xD9).contains(&marker) || marker == 0x01 {
            position = length_at;
            continue;
        }
        // Start of scan: everything after it is entropy-coded pixels.
        if marker == 0xDA || length_at + 2 > bytes.len() {
            break;
        }
        let length = usize::from(u16::from_be_bytes([bytes[length_at], bytes[length_at + 1]]));
        let segment_end = length_at + length;
        if length < 2 || segment_end > bytes.len() {
            break;
        }
        if matches!(marker, 0xE1 | 0xE2 | 0xED) {
            segments.push((marker, &bytes[position..segment_end]));
        }
        position = segment_end;
    }
    segments
}

/// Copy `original`'s metadata segments into `encoded`, right after its SOI.
///
/// The bytes are carried verbatim so an ICC profile or an orientation tag keeps
/// its exact encoding. A file that is not a JPEG, or an encode that is not one,
/// is returned unchanged: a broken export is worse than one without metadata.
pub fn splice_jpeg_metadata(original: &[u8], encoded: Vec<u8>) -> Vec<u8> {
    splice_jpeg_metadata_segments(original, encoded, true)
}

/// Like [`splice_jpeg_metadata`], but a resized copy can drop APP1.
///
/// EXIF and XMP name the source's pixel dimensions and may embed the source's
/// thumbnail, so carrying them onto a smaller export states a size the file no
/// longer has. The ICC profile (APP2) and IPTC data (APP13) are still copied,
/// because dropping them would change the colours and the credit.
fn splice_jpeg_metadata_segments(original: &[u8], encoded: Vec<u8>, keep_exif: bool) -> Vec<u8> {
    let segments: Vec<(u8, &[u8])> = jpeg_metadata_segments(original)
        .into_iter()
        .filter(|(marker, _)| keep_exif || *marker != 0xE1)
        .collect();
    if segments.is_empty() || encoded.len() < 2 || encoded[0] != 0xFF || encoded[1] != 0xD8 {
        return encoded;
    }
    let extra: usize = segments.iter().map(|(_, segment)| segment.len()).sum();
    let mut out = Vec::with_capacity(encoded.len() + extra);
    out.extend_from_slice(&encoded[..2]);
    for (_, segment) in segments {
        out.extend_from_slice(segment);
    }
    out.extend_from_slice(&encoded[2..]);
    out
}

/// Size and modification time of a file, or `None` when it cannot be read.
fn file_stamp(path: &Path) -> Option<(u64, Option<std::time::SystemTime>)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.len(), metadata.modified().ok()))
}

/// `<name>.<ext>.bak` beside `path`, so `photo.jpg` becomes
/// `photo.jpg.bak` and is never mistaken for an image the app lists.
fn backup_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".to_owned());
    name.push_str(".bak");
    path.with_file_name(name)
}

/// A decoded image plus its edit history. The source path is only used for
/// labels and for re-opening; the document never writes to it.
pub struct EditorDocument {
    source_path: PathBuf,
    /// The pixels as opened. Shared with `working` until the first edit, so an
    /// untouched document holds one buffer, not two.
    original: Arc<RgbaImage>,
    working: Arc<RgbaImage>,
    undo: Vec<Step>,
    redo: Vec<EditOperation>,
    snapshot_bytes: u64,
    /// The pixels as they are on disk at [`saved_path`], shared with `working`
    /// while they are identical. Undo/redo compare against it, so returning to
    /// what was written does not leave the document looking unsaved.
    saved_pixels: Arc<RgbaImage>,
    /// Fingerprint of the source bytes as last seen by the document: at open,
    /// and after a save. Size and modification time are cheap enough to check
    /// and precise enough to catch another program rewriting the file.
    stamped_source: Option<(u64, Option<std::time::SystemTime>)>,
    /// Where the working pixels are on disk: the source until a save moves it.
    saved_path: PathBuf,
    /// True when `working` is what `saved_path` holds.
    saved: bool,
}

impl EditorDocument {
    /// Build a document from pixels that were already decoded and checked.
    pub fn from_image(source_path: PathBuf, image: RgbaImage) -> Self {
        let image = Arc::new(image);
        let source_stamp = file_stamp(&source_path);
        Self {
            saved_path: source_path.clone(),
            source_path,
            stamped_source: source_stamp,
            saved_pixels: Arc::clone(&image),
            original: Arc::clone(&image),
            working: image,
            undo: Vec::new(),
            redo: Vec::new(),
            snapshot_bytes: 0,
            saved: true,
        }
    }

    pub fn source_path(&self) -> &Path {
        &self.source_path
    }

    /// Where a save would write, and whether the pixels are already there.
    pub fn save_target(&self) -> (&Path, bool) {
        (&self.saved_path, self.saved)
    }

    /// Record that the working pixels were written to `path`. Returns `Err`
    /// when the destination is not the format of the source, because the
    /// change of style also moves what the file list shows.
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

    /// True when the source file no longer looks like it did when opened.
    /// Re-evaluated, not cached: a missed check would overwrite the change.
    pub fn source_changed(&self) -> bool {
        file_stamp(&self.source_path) != self.stamped_source
    }

    /// Record what the source looks like now, after Core wrote it itself.
    pub fn remember_source(&mut self) {
        self.stamped_source = file_stamp(&self.source_path);
    }

    pub fn dimensions(&self) -> (u32, u32) {
        self.working.dimensions()
    }

    /// The current pixels, cheap to hand to a render thread.
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

    /// Apply an operation to the working pixels.
    ///
    /// Returns `Ok(true)` when pixels changed, `Ok(false)` for a request that
    /// would change nothing (crop to the full frame, resize to the same size),
    /// and `Err` with an interface line when the request is invalid. A changed
    /// document clears the redo branch, as in any editor.
    pub fn apply(&mut self, operation: EditOperation) -> Result<bool, UiText> {
        if self.is_noop(&operation)? {
            return Ok(false);
        }
        let before = Arc::clone(&self.working);
        let next = render_operation(&before, &operation)?;
        self.push(operation, before);
        self.working = Arc::new(next);
        self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels);
        Ok(true)
    }

    /// Would `operation` change anything? Validates the request the same way
    /// `apply` does, without touching the pixels: the live resize preview asks
    /// before it spends a worker render.
    pub fn would_change(&self, operation: &EditOperation) -> Result<bool, UiText> {
        self.is_noop(operation).map(|noop| !noop)
    }

    /// The working pixels, for a worker that renders a preview or a draft.
    pub fn undo(&mut self) -> bool {
        let Some(step) = self.undo.pop() else {
            return false;
        };
        let previous = match &step.undo {
            Undo::Invert(operation) => match render_operation(&self.working, operation) {
                Ok(image) => Arc::new(image),
                Err(_) => {
                    // The inverse of a reversible operation cannot fail; if it
                    // ever does, leave the history exactly as it was.
                    self.undo.push(step);
                    return false;
                }
            },
            Undo::Snapshot(image) => Arc::clone(image),
        };
        self.working = previous;
        self.redo.push(step.operation);
        self.saved = false;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(operation) = self.redo.pop() else {
            return false;
        };
        let before = Arc::clone(&self.working);
        let Ok(next) = render_operation(&before, &operation) else {
            self.redo.push(operation);
            return false;
        };
        self.push(operation, before);
        self.working = Arc::new(next);
        self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels);
        true
    }

    /// Discard every edit. Returns false when the document was already
    /// untouched, so the caller can skip a state revision.
    pub fn reset(&mut self) -> bool {
        if self.undo.is_empty()
            && self.redo.is_empty()
            && Arc::ptr_eq(&self.working, &self.original)
        {
            return false;
        }
        self.working = Arc::clone(&self.original);
        self.saved = Arc::ptr_eq(&self.working, &self.saved_pixels);
        self.undo.clear();
        self.redo.clear();
        self.snapshot_bytes = 0;
        true
    }

    fn is_noop(&self, operation: &EditOperation) -> Result<bool, UiText> {
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
            } => {
                validate_crop(*x, *y, *w, *h, width, height)?;
                Ok(*x == 0 && *y == 0 && *w == width && *h == height)
            }
            EditOperation::Resize {
                width: w,
                height: h,
                ..
            } => {
                validate_resize(*w, *h)?;
                // Same dimensions are the only no-op: a pad colour on the same
                // target would fit the whole source exactly, so nothing is
                // added.
                Ok(*w == width && *h == height)
            }
            EditOperation::Transform { corners } => {
                validate_transform(corners, width, height)?;
                Ok(is_identity_quad(corners, width, height))
            }
        }
    }

    fn push(&mut self, operation: EditOperation, before: Arc<RgbaImage>) {
        let undo = match &operation {
            EditOperation::Rotate { degrees } => Undo::Invert(EditOperation::Rotate {
                degrees: 360 - degrees.rem_euclid(360),
            }),
            EditOperation::Flip { axis } => Undo::Invert(EditOperation::Flip { axis: *axis }),
            EditOperation::Crop { .. } | EditOperation::Resize { .. } => Undo::Snapshot(before),
            // A warp cannot be recreated from its parameters: the pixels that
            // left the quad are not in the result. Snapshot, like crop.
            EditOperation::Transform { .. } => Undo::Snapshot(before),
        };
        self.undo.push(Step { operation, undo });
        self.redo.clear();
        self.trim_history();
    }

    /// Drop the oldest steps once the stack is too deep or holds too many
    /// pixels. Undo then stops at the oldest step still kept; the newest steps
    /// (the ones a user is about to undo) are never dropped.
    fn trim_history(&mut self) {
        while self.undo.len() > MAX_HISTORY_STEPS {
            self.undo.remove(0);
        }
        self.snapshot_bytes = self
            .undo
            .iter()
            .map(|step| match &step.undo {
                Undo::Snapshot(image) => image.as_raw().len() as u64,
                Undo::Invert(_) => 0,
            })
            .sum();
        while self.snapshot_bytes > MAX_SNAPSHOT_BYTES && self.undo.len() > 1 {
            let dropped = self.undo.remove(0);
            if let Undo::Snapshot(image) = dropped.undo {
                self.snapshot_bytes -= image.as_raw().len() as u64;
            }
        }
    }
}

fn validate_crop(
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    doc_w: u32,
    doc_h: u32,
) -> Result<(), UiText> {
    if width == 0 || height == 0 {
        return Err(UiText::new("crop_size_empty"));
    }
    if x >= doc_w
        || y >= doc_h
        || x.saturating_add(width) > doc_w
        || y.saturating_add(height) > doc_h
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

fn validate_resize(width: u32, height: u32) -> Result<(), UiText> {
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

/// The tolerance an identity quad is recognised with, in document pixels. A
/// hand on a zoomed-out canvas cannot place a corner closer than a fraction of
/// a pixel, and a warp that moves a corner by less than that is not an edit.
const IDENTITY_EPSILON: f64 = 1e-6;

/// True when the quad is exactly the document's own frame.
fn is_identity_quad(corners: &[[f64; 2]; 4], width: u32, height: u32) -> bool {
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
fn validate_transform(
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
fn quad_area(corners: &[[f64; 2]; 4]) -> f64 {
    let mut twice = 0.0f64;
    for index in 0..4 {
        let a = corners[index];
        let b = corners[(index + 1) % 4];
        twice += a[0] * b[1] - b[0] * a[1];
    }
    twice.abs() / 2.0
}

/// The homography that maps the unit square onto `corners`.
///
/// The unit square's (0, 0), (1, 0), (1, 1), (0, 1) land on the quad's TL, TR,
/// BR, BL. The classic square-to-quad decomposition is used rather than an
/// 8 × 8 solve: it is the same answer with the degenerate case (a parallelogram)
/// written out instead of divided by zero.
fn square_to_quad(corners: &[[f64; 2]; 4]) -> [[f64; 3]; 3] {
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

/// The inverse of a 3 × 3 matrix, or `None` when it has none.
fn invert3(matrix: [[f64; 3]; 3]) -> Option<[[f64; 3]; 3]> {
    let [[a, b, c], [d, e, f], [g, h, i]] = matrix;
    let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if determinant.abs() < 1e-12 {
        return None;
    }
    let scale = 1.0 / determinant;
    Some([
        [
            (e * i - f * h) * scale,
            (c * h - b * i) * scale,
            (b * f - c * e) * scale,
        ],
        [
            (f * g - d * i) * scale,
            (a * i - c * g) * scale,
            (c * d - a * f) * scale,
        ],
        [
            (d * h - e * g) * scale,
            (b * g - a * h) * scale,
            (a * e - b * d) * scale,
        ],
    ])
}
/// Warp `image` so the quad becomes the whole frame, keeping the frame's size.
///
/// Each destination pixel centre is a point in the unit square; the homography
/// takes it to the quad's own point in the source, which is sampled bilinearly.
/// The quad is inside the frame by validation, so every sample lands inside the
/// picture; the clamp is there for float rounding at the very edge, not as a
/// crop.
fn warp_quad(image: &RgbaImage, corners: &[[f64; 2]; 4]) -> RgbaImage {
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

/// Bilinear sample with the sample point clamped to the image's own bounds.
fn sample_bilinear(image: &RgbaImage, x: f64, y: f64) -> image::Rgba<u8> {
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

/// Scale the whole source down (or up) to the largest box of the source's own
/// shape that fits inside `target_width` × `target_height`, then centre it on a
/// target-sized canvas of `color`. Nothing is stretched and nothing is cut: the
/// target shape is the frame, the source shape is what fills it, and the
/// leftover is the pad. The pad is a letterbox or a pillarbox — only a square
/// when the target itself is square.
fn fit_with_padding(
    image: &RgbaImage,
    target_width: u32,
    target_height: u32,
    color: [u8; 3],
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

    let content = imageops::resize(image, content_width, content_height, FilterType::Lanczos3);
    let mut canvas = RgbaImage::from_pixel(
        target_width,
        target_height,
        image::Rgba([color[0], color[1], color[2], 255]),
    );
    let x = (target_width - content_width) / 2;
    let y = (target_height - content_height) / 2;
    imageops::overlay(&mut canvas, &content, i64::from(x), i64::from(y));
    canvas
}

/// The centred source rectangle that covers the target aspect without
/// stretching. A wider source loses columns, a taller source loses rows; equal
/// aspects keep the whole image.
fn cover_rect(
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
    (
        (source_width - crop_width) / 2,
        (source_height - crop_height) / 2,
        crop_width,
        crop_height,
    )
}

/// Render one operation into a new buffer, leaving `image` untouched.
fn render_operation(image: &RgbaImage, operation: &EditOperation) -> Result<RgbaImage, UiText> {
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
        } => {
            validate_crop(*x, *y, *w, *h, width, height)?;
            Ok(imageops::crop_imm(image, *x, *y, *w, *h).to_image())
        }
        EditOperation::Resize {
            width: w,
            height: h,
            fill,
        } => {
            validate_resize(*w, *h)?;
            // With a fill, fit the whole source inside the target and pad the
            // leftover: no pixels are stretched or thrown away. Without one,
            // cover the target by cropping around the centre and scale.
            if let Some([r, g, b]) = fill {
                return Ok(fit_with_padding(image, *w, *h, [*r, *g, *b]));
            }
            let rect = cover_rect(width, height, *w, *h);
            let cropped = imageops::crop_imm(image, rect.0, rect.1, rect.2, rect.3).to_image();
            Ok(imageops::resize(&cropped, *w, *h, FilterType::Lanczos3))
        }
        EditOperation::Transform { corners } => {
            validate_transform(corners, width, height)?;
            Ok(warp_quad(image, corners))
        }
    }
}

/// True when the file's bytes are encoded in a format `image` has a decoder
/// for in this build. The extension decides what the browser lists; the bytes
/// decide whether it can be decoded, so a mislabelled file says so plainly.
pub fn has_decoder(path: &Path) -> bool {
    match ImageReader::open(path).and_then(|reader| reader.with_guessed_format()) {
        Ok(reader) => reader.format().is_some(),
        Err(_) => false,
    }
}

/// Decode an image file into a working document. Runs on a worker thread.
pub fn open_document(path: &Path) -> Result<EditorDocument, String> {
    let reader = ImageReader::open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?
        .with_guessed_format()
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    let (width, height) = reader
        .into_dimensions()
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    if u64::from(width) * u64::from(height) > MAX_DOCUMENT_PIXELS {
        return Err(format!(
            "{width} × {height} is larger than the {MAX_DOCUMENT_PIXELS} pixel editor limit"
        ));
    }
    let image = ImageReader::open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?
        .with_guessed_format()
        .map_err(|error| format!("could not read {}: {error}", path.display()))?
        .decode()
        .map_err(|error| format!("could not decode {}: {error}", path.display()))?
        .to_rgba8();
    Ok(EditorDocument::from_image(path.to_path_buf(), image))
}

/// The size a preview of `width` × `height` is rendered at.
pub fn preview_dimensions(width: u32, height: u32) -> (u32, u32) {
    let longest = width.max(height);
    if longest <= PREVIEW_LONG_EDGE {
        return (width.max(1), height.max(1));
    }
    let scale = f64::from(PREVIEW_LONG_EDGE) / f64::from(longest);
    (
        ((f64::from(width) * scale).round() as u32).max(1),
        ((f64::from(height) * scale).round() as u32).max(1),
    )
}

/// Write the QML preview: PNG, downscaled to [`PREVIEW_LONG_EDGE`] on the long
/// edge. Runs on a worker thread; the document keeps full resolution.
pub fn render_preview(image: &RgbaImage, path: &Path) -> Result<(), String> {
    DynamicImage::ImageRgba8(preview_pixels(image))
        .save_with_format(path, ImageFormat::Png)
        .map_err(|error| format!("could not write the preview {}: {error}", path.display()))
}

/// The pixels a preview of `image` is drawn from.
///
/// Box sampling, not a general resampler: a preview is looked at, never
/// measured, and `imageops::resize` spends seconds on a 27 MP frame deciding
/// where a Lanczos lobe should fall. `imageops::thumbnail` averages the source
/// block behind each target pixel — the right filter for a downscale this
/// large, and the cheap one.
fn preview_pixels(image: &RgbaImage) -> RgbaImage {
    let (width, height) = image.dimensions();
    if width.max(height) > PREVIEW_LONG_EDGE {
        let (target_w, target_h) = preview_dimensions(width, height);
        imageops::thumbnail(image, target_w, target_h)
    } else {
        image.clone()
    }
}

/// A result produced on a worker thread and consumed by Core's poll loop.
pub enum EditorTask {
    /// The preview is ready but the document is not: the canvas can paint it
    /// while the full frame decodes. `source` and the two dimensions are the
    /// document's own, read from the file's header before decoding, so the
    /// window can name the picture and its size at reduced detail instead of
    /// showing an empty canvas.
    FirstPreview {
        generation: u64,
        source: PathBuf,
        preview: PathBuf,
        width: u32,
        height: u32,
    },
    Opened {
        generation: u64,
        document: EditorDocument,
        preview: PathBuf,
    },
    Preview {
        generation: u64,
        preview: PathBuf,
    },
    /// A preview of an edit that has not been applied, rendered at the target
    /// size rather than the document's. It never touches the document. `kind`
    /// names the tool that asked for it (`resize` or `crop`), so the view can
    /// refuse to draw the other tool's draft after a switch.
    Draft {
        generation: u64,
        kind: String,
        preview: PathBuf,
        width: u32,
        height: u32,
    },
    DraftFailed {
        generation: u64,
        message: String,
    },
    Failed {
        generation: u64,
        message: String,
    },
}

/// Decode `source` and render its first preview, then report to Core.
pub fn spawn_open(source: PathBuf, generation: u64, preview: PathBuf, sender: Sender<EditorTask>) {
    std::thread::spawn(move || {
        let started = std::time::Instant::now();
        // First stage: a JPEG preview decoded at a reduced DCT scale. It is
        // published on its own so the canvas paints something as soon as the
        // file's header allowed it, while the full frame is still decoding.
        // Everything else — and any failure here — falls through to the
        // one-stage path below, which is the behaviour every format had.
        let mut preview_written = false;
        if let Ok(Some((image, width, height))) = scaled_jpeg_preview(&source) {
            if render_preview(&image, &preview).is_ok() {
                preview_written = true;
                let _ = sender.send(EditorTask::FirstPreview {
                    generation,
                    source: source.clone(),
                    preview: preview.clone(),
                    width,
                    height,
                });
                tracing::debug!(
                    target: "kogaview::editor",
                    generation,
                    elapsed_ms = started.elapsed().as_millis() as u64,
                    "editor first preview written"
                );
            }
        }

        let task = match open_document(&source) {
            Ok(document) => {
                if !preview_written {
                    if let Err(message) = render_preview(&document.pixels(), &preview) {
                        let _ = sender.send(EditorTask::Failed {
                            generation,
                            message,
                        });
                        return;
                    }
                }
                tracing::debug!(
                    target: "kogaview::editor",
                    generation,
                    elapsed_ms = started.elapsed().as_millis() as u64,
                    "editor document decoded and preview written"
                );
                EditorTask::Opened {
                    generation,
                    document,
                    preview,
                }
            }
            Err(message) => EditorTask::Failed {
                generation,
                message,
            },
        };
        let _ = sender.send(task);
    });
}

/// A preview-sized decode of a large JPEG, or `None` when this is not the case.
///
/// A JPEG's DCT lets a decoder produce 1/2, 1/4 or 1/8 of the frame without
/// decoding the pixels it would throw away, and `image` does not expose that.
/// The result is only ever used for the *first* preview: the document still
/// decodes at full resolution, and every later preview is rendered from those
/// pixels. A file that fails here is simply decoded the ordinary way.
fn scaled_jpeg_preview(path: &Path) -> Result<Option<(RgbaImage, u32, u32)>, String> {
    let reader = ImageReader::open(path)
        .map_err(|error| error.to_string())?
        .with_guessed_format()
        .map_err(|error| error.to_string())?;
    if reader.format() != Some(ImageFormat::Jpeg) {
        return Ok(None);
    }
    let (width, height) = reader
        .into_dimensions()
        .map_err(|error| error.to_string())?;
    if width.max(height) <= PREVIEW_LONG_EDGE {
        // Already preview-sized: a scaled decode would only lose quality, and
        // the ordinary path cheaply produces the same file.
        return Ok(None);
    }
    let (target_w, target_h) = preview_dimensions(width, height);
    let file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let mut decoder = jpeg_decoder::Decoder::new(std::io::BufReader::new(file));
    // `scale` answers with the size it will really produce: the smallest of
    // 1/8, 1/4 and 1/2 that still covers the request, so the preview is never
    // an upscale of a too-small decode.
    let (decoded_w, decoded_h) = decoder
        .scale(target_w as u16, target_h as u16)
        .map_err(|error| error.to_string())?;
    let pixels = decoder.decode().map_err(|error| error.to_string())?;
    let info = decoder.info().ok_or("the JPEG has no frame information")?;
    let image = match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => {
            RgbaImage::from_raw(decoded_w.into(), decoded_h.into(), rgb_to_rgba(&pixels))
                .ok_or("the JPEG decoder returned the wrong number of pixels")?
        }
        jpeg_decoder::PixelFormat::L8 => {
            let mut rgba = Vec::with_capacity(pixels.len() * 4);
            for value in pixels {
                rgba.extend_from_slice(&[value, value, value, 255]);
            }
            RgbaImage::from_raw(decoded_w.into(), decoded_h.into(), rgba)
                .ok_or("the JPEG decoder returned the wrong number of pixels")?
        }
        // CMYK JPEGs are rare and the colour conversion is not this path's job:
        // fall back to the ordinary decode rather than guessing at it.
        _ => return Ok(None),
    };
    Ok(Some((image, width, height)))
}

fn rgb_to_rgba(pixels: &[u8]) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(pixels.len() / 3 * 4);
    for chunk in pixels.chunks_exact(3) {
        rgba.extend_from_slice(&[chunk[0], chunk[1], chunk[2], 255]);
    }
    rgba
}

/// Render a preview of the pixels Core just produced.
pub fn spawn_preview(
    pixels: Arc<RgbaImage>,
    generation: u64,
    preview: PathBuf,
    sender: Sender<EditorTask>,
) {
    std::thread::spawn(move || {
        let task = match render_preview(&pixels, &preview) {
            Ok(()) => EditorTask::Preview {
                generation,
                preview,
            },
            Err(message) => EditorTask::Failed {
                generation,
                message,
            },
        };
        let _ = sender.send(task);
    });
}

/// Render an operation that is only being previewed: the pixels are the
/// current document, and the result is written at the target size so the canvas
/// can show what Apply would produce. The document, its history and its save
/// target are untouched — Core still owns the decision to apply.
pub fn spawn_draft(
    pixels: Arc<RgbaImage>,
    operation: EditOperation,
    generation: u64,
    preview: PathBuf,
    sender: Sender<EditorTask>,
) {
    let (kind, width, height) = match &operation {
        EditOperation::Resize { width, height, .. } => ("resize", *width, *height),
        EditOperation::Crop { width, height, .. } => ("crop", *width, *height),
        // A transform keeps the frame it started with, so the draft is the
        // document's own size — read from the pixels the worker was handed.
        EditOperation::Transform { .. } => {
            let (width, height) = pixels.dimensions();
            ("transform", width, height)
        }
        _ => ("", 0, 0),
    };
    std::thread::spawn(move || {
        // A rejected render is a log line, not a sentence on screen: Core
        // validated the request with `would_change` before spawning this, so a
        // failure here is the renderer disagreeing with its own validator.
        let task = match render_operation(&pixels, &operation) {
            Ok(result) => match render_preview(&result, &preview) {
                Ok(()) => EditorTask::Draft {
                    generation,
                    kind: kind.to_owned(),
                    preview,
                    width,
                    height,
                },
                Err(message) => EditorTask::DraftFailed {
                    generation,
                    message,
                },
            },
            Err(line) => EditorTask::DraftFailed {
                generation,
                message: line.english(),
            },
        };
        let _ = sender.send(task);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-editor-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A deterministic pattern: pixel (x, y) is (x*8, y*8, x+y, 255).
    fn pattern(width: u32, height: u32) -> RgbaImage {
        RgbaImage::from_fn(width, height, |x, y| {
            image::Rgba([
                (x * 8 % 256) as u8,
                (y * 8 % 256) as u8,
                ((x + y) % 256) as u8,
                255,
            ])
        })
    }

    fn source_file(dir: &Path, name: &str, width: u32, height: u32) -> PathBuf {
        let path = dir.join(name);
        DynamicImage::ImageRgba8(pattern(width, height))
            .save_with_format(&path, ImageFormat::Png)
            .unwrap();
        path
    }

    /// A JPEG larger than one DCT halving of the preview edge, so the scaled
    /// decode has a scale to choose (1/2 must still cover 2048 px).
    fn wide_jpeg(dir: &Path, name: &str, width: u32, height: u32) -> PathBuf {
        let path = dir.join(name);
        let image = pattern(width, height);
        let bytes = encode_with(&image, SaveFormat::Jpeg, Some(92)).unwrap();
        std::fs::write(&path, bytes).unwrap();
        path
    }

    fn mean_absolute_difference(left: &RgbaImage, right: &RgbaImage) -> f64 {
        assert_eq!(left.dimensions(), right.dimensions());
        let mut total: u64 = 0;
        for (a, b) in left.pixels().zip(right.pixels()) {
            for channel in 0..3 {
                total += u64::from(a.0[channel].abs_diff(b.0[channel]));
            }
        }
        total as f64 / (left.pixels().len() * 3) as f64
    }

    /// A photograph-like frame: smooth gradients plus a low-frequency
    /// undulation. `pattern` above is deliberately high frequency, which is the
    /// worst case for a decoder that keeps only the low DCT bands; a preview's
    /// job is to look like the picture, so it is judged on this one.
    fn smooth_pattern(width: u32, height: u32) -> RgbaImage {
        RgbaImage::from_fn(width, height, |x, y| {
            let fx = x as f64 / f64::from(width);
            let fy = y as f64 / f64::from(height);
            let wave = (fx * 6.0 * std::f64::consts::PI).sin() * 24.0;
            image::Rgba([
                (fx * 255.0).clamp(0.0, 255.0) as u8,
                ((fy * 180.0 + 40.0 + wave).clamp(0.0, 255.0)) as u8,
                (((fx + fy) * 110.0).clamp(0.0, 255.0)) as u8,
                255,
            ])
        })
    }

    fn wide_smooth_jpeg(dir: &Path, name: &str, width: u32, height: u32) -> PathBuf {
        let path = dir.join(name);
        let bytes =
            encode_with(&smooth_pattern(width, height), SaveFormat::Jpeg, Some(92)).unwrap();
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn the_scaled_jpeg_preview_matches_the_full_decode() {
        let dir = temp_dir();
        let path = wide_smooth_jpeg(&dir, "wide.jpg", 4200, 600);

        let (scaled, full_w, full_h) = scaled_jpeg_preview(&path)
            .unwrap()
            .expect("a 4200 px JPEG has a halved decode");
        assert_eq!(
            (full_w, full_h),
            (4200, 600),
            "the header size is the document's"
        );
        assert!(
            scaled.width() < 4200,
            "the preview decode was not scaled down: {} px",
            scaled.width()
        );

        let full = open_document(&path).unwrap();
        let (width, height) = full.dimensions();
        let (target_w, target_h) = preview_dimensions(width, height);
        let fast = imageops::thumbnail(&scaled, target_w, target_h);
        let accurate = preview_pixels(&full.pixels());
        let difference = mean_absolute_difference(&fast, &accurate);
        assert!(
            difference < 4.0,
            "the halved decode differs from the full one by {difference:.2} levels"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_small_jpeg_is_not_decoded_twice() {
        let dir = temp_dir();
        // 1200 px is already preview-sized: the ordinary path is used, so no
        // quality is lost and no second decode is paid for.
        let path = wide_jpeg(&dir, "small.jpg", 1200, 800);
        assert!(scaled_jpeg_preview(&path).unwrap().is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn opening_a_large_jpeg_publishes_the_preview_before_the_document() {
        let dir = temp_dir();
        let source = wide_jpeg(&dir, "wide.jpg", 4200, 600);
        let preview = dir.join("preview.png");
        let (sender, receiver) = std::sync::mpsc::channel();
        spawn_open(source.clone(), 7, preview.clone(), sender);

        let first = receiver
            .recv_timeout(std::time::Duration::from_secs(30))
            .expect("the worker must report something");
        match first {
            EditorTask::FirstPreview {
                generation,
                source: from,
                preview: fast,
                width,
                height,
            } => {
                assert_eq!(generation, 7);
                assert_eq!(from, source);
                // The published size is the document's, not the reduced
                // decode's: the footer must not show 2048 px and then jump.
                assert_eq!((width, height), (4200, 600));
                assert!(fast.is_file(), "the first preview was not written");
            }
            other => panic!(
                "the first message must be the preview, not {:?}",
                std::mem::discriminant(&other)
            ),
        }

        let second = receiver
            .recv_timeout(std::time::Duration::from_secs(30))
            .expect("the document must follow the preview");
        match second {
            EditorTask::Opened {
                generation,
                document,
                preview: written,
            } => {
                assert_eq!(generation, 7);
                assert_eq!(document.dimensions(), (4200, 600));
                assert_eq!(written, preview);
                assert!(written.is_file(), "the document had no preview");
            }
            _ => panic!("the second message must be the decoded document"),
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn open(dir: &Path) -> EditorDocument {
        let path = source_file(dir, "source.png", 64, 32);
        open_document(&path).unwrap()
    }

    #[test]
    fn opening_decodes_the_file_and_keeps_the_source() {
        let dir = temp_dir();
        let path = source_file(&dir, "photo.png", 20, 10);
        let before = std::fs::read(&path).unwrap();
        let mut document = open_document(&path).unwrap();
        assert_eq!(document.dimensions(), (20, 10));
        assert!(!document.can_undo());
        assert!(document
            .apply(EditOperation::Rotate { degrees: 90 })
            .unwrap());
        assert_eq!(document.dimensions(), (10, 20));
        // The source bytes are untouched by an edit.
        assert_eq!(std::fs::read(&path).unwrap(), before);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rotate_and_flip_change_pixels_and_undo_exactly() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let original = document.pixels();
        assert!(document
            .apply(EditOperation::Rotate { degrees: 90 })
            .unwrap());
        assert_eq!(document.dimensions(), (32, 64));
        assert!(document
            .apply(EditOperation::Flip {
                axis: FlipAxis::Vertical
            })
            .unwrap());
        assert_eq!(document.dimensions(), (32, 64));
        assert_eq!(
            document.history(),
            vec![UiText::new("rotate_right"), UiText::new("flip_vertical")]
        );
        assert!(document.undo());
        assert!(document.undo());
        assert_eq!(document.dimensions(), (64, 32));
        assert_eq!(document.pixels().as_raw(), original.as_raw());
        assert!(!document.can_undo());
        assert_eq!(document.redo_count(), 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn crop_and_resize_are_exact_and_reject_bad_rectangles() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let original = document.pixels();
        assert!(document
            .apply(EditOperation::Crop {
                x: 8,
                y: 4,
                width: 16,
                height: 12,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (16, 12));
        assert_eq!(
            document.pixels().get_pixel(0, 0),
            original.get_pixel(8, 4),
            "the crop must start at the requested pixel"
        );
        assert!(document
            .apply(EditOperation::Resize {
                width: 8,
                height: 6,
                fill: None,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (8, 6));

        assert!(document.undo());
        assert_eq!(document.dimensions(), (16, 12));
        assert!(document.undo());
        assert_eq!(document.dimensions(), (64, 32));
        assert_eq!(document.pixels().as_raw(), original.as_raw());

        let error = document
            .apply(EditOperation::Crop {
                x: 60,
                y: 0,
                width: 10,
                height: 10,
            })
            .unwrap_err();
        // The rejected request is a line, not a sentence: the code names the
        // cause and the arguments carry the rectangle and the document.
        assert_eq!(error.code, "crop_does_not_fit");
        assert_eq!(error.args, ["10", "10", "60", "0", "64", "32"]);
        assert!(!document.can_undo(), "a rejected crop must not be recorded");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_noop_crop_or_resize_is_not_recorded() {
        let dir = temp_dir();
        let mut document = open(&dir);
        assert!(!document
            .apply(EditOperation::Crop {
                x: 0,
                y: 0,
                width: 64,
                height: 32,
            })
            .unwrap());
        assert!(!document
            .apply(EditOperation::Resize {
                width: 64,
                height: 32,
                fill: None,
            })
            .unwrap());
        assert!(!document.can_undo());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_zero_rotation_is_rejected() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let error = document
            .apply(EditOperation::Rotate { degrees: 360 })
            .unwrap_err();
        assert_eq!(error.code, "invalid_rotation");
        assert_eq!(error.args, ["360"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_identity_quad_is_never_recorded() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let (width, height) = document.dimensions();
        let identity = EditOperation::Transform {
            corners: [
                [0.0, 0.0],
                [f64::from(width), 0.0],
                [f64::from(width), f64::from(height)],
                [0.0, f64::from(height)],
            ],
        };
        assert!(!document.apply(identity.clone()).unwrap());
        assert!(!document.would_change(&identity).unwrap());
        assert!(!document.can_undo());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_identity_quad_reproduces_every_pixel() {
        let dir = temp_dir();
        let document = open(&dir);
        let image = document.pixels();
        let (width, height) = image.dimensions();
        let warped = warp_quad(
            &image,
            &[
                [0.0, 0.0],
                [f64::from(width), 0.0],
                [f64::from(width), f64::from(height)],
                [0.0, f64::from(height)],
            ],
        );
        assert_eq!(
            warped.as_raw(),
            image.as_raw(),
            "an identity quad is a copy, not a half-pixel shift"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_keystone_maps_the_quad_onto_the_frame() {
        // R encodes the column and G the row, so a sample can be read back as
        // the source point it came from: the warp is judged on coordinates, not
        // on whether it "looks straightened".
        let image = RgbaImage::from_fn(64, 64, |x, y| {
            image::Rgba([x as u8 * 4, y as u8 * 4, 0, 255])
        });
        // The inner rectangle (16, 16) – (48, 48) becomes the whole frame.
        let warped = warp_quad(
            &image,
            &[[16.0, 16.0], [48.0, 16.0], [48.0, 48.0], [16.0, 48.0]],
        );
        assert_eq!(warped.dimensions(), image.dimensions(), "the frame is kept");
        let left = warped.get_pixel(0, 32);
        let right = warped.get_pixel(63, 32);
        let top = warped.get_pixel(32, 0);
        let bottom = warped.get_pixel(32, 63);
        // A linear ramp survives bilinear sampling exactly, so these are the
        // quad's own edges: x 16 → R 64, x 47.5 → R ~190; likewise for y.
        assert!(
            (left[0] as i32 - 64).abs() <= 4,
            "the left edge sampled x≈{}",
            left[0] / 4
        );
        assert!(
            (right[0] as i32 - 190).abs() <= 4,
            "the right edge sampled x≈{}",
            right[0] / 4
        );
        assert!(
            (top[1] as i32 - 64).abs() <= 4,
            "the top edge sampled y≈{}",
            top[1] / 4
        );
        assert!(
            (bottom[1] as i32 - 190).abs() <= 4,
            "the bottom edge sampled y≈{}",
            bottom[1] / 4
        );
    }

    #[test]
    fn a_transform_of_one_corner_keeps_the_far_side_and_undoes_by_snapshot() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let original = document.pixels();
        // Pull the top-left corner inwards: the bottom-right of the output must
        // still be the bottom-right of the picture, which is what makes this a
        // corner pin rather than a resize.
        assert!(document
            .apply(EditOperation::Transform {
                corners: [[12.0, 6.0], [64.0, 0.0], [64.0, 32.0], [0.0, 32.0],],
            })
            .unwrap());
        assert_eq!(document.dimensions(), (64, 32));
        let warped = document.pixels();
        assert_ne!(warped.as_raw(), original.as_raw());
        assert_eq!(
            document.history(),
            vec![UiText::new("transform")],
            "the history names the operation, the sentence lives in UiLines"
        );
        // The bottom-right destination pixel comes from the quad's own
        // bottom-right, which did not move.
        let corner = warped.get_pixel(63, 31);
        let expected = original.get_pixel(63, 31);
        for channel in 0..3 {
            assert!(
                (corner[channel] as i32 - expected[channel] as i32).abs() <= 6,
                "the untouched corner changed: {corner:?} vs {expected:?}"
            );
        }
        assert!(document.undo());
        assert_eq!(document.pixels().as_raw(), original.as_raw());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_folded_or_outside_quad_is_rejected_with_a_line() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let outside = document
            .apply(EditOperation::Transform {
                corners: [[-1.0, 0.0], [64.0, 0.0], [64.0, 32.0], [0.0, 32.0]],
            })
            .unwrap_err();
        assert_eq!(outside.code, "transform_outside");
        assert_eq!(outside.args, ["-1", "0", "64", "32"]);

        // TR and BL swapped: the edges cross, so there is no picture inside the
        // quad to keep.
        let folded = document
            .apply(EditOperation::Transform {
                corners: [[0.0, 0.0], [64.0, 0.0], [0.0, 32.0], [64.0, 32.0]],
            })
            .unwrap_err();
        assert_eq!(folded.code, "transform_degenerate");

        // The same quad wound the other way is a mirror of the frame. Turning a
        // picture over is Flip's job, so Transform refuses it rather than
        // applying an edit the user cannot name.
        let reversed = document
            .apply(EditOperation::Transform {
                corners: [[0.0, 0.0], [0.0, 32.0], [64.0, 32.0], [64.0, 0.0]],
            })
            .unwrap_err();
        assert_eq!(reversed.code, "transform_degenerate");

        // Two corners on the same point.
        let pinched = document
            .apply(EditOperation::Transform {
                corners: [[8.0, 8.0], [8.0, 8.0], [64.0, 32.0], [0.0, 32.0]],
            })
            .unwrap_err();
        assert_eq!(pinched.code, "transform_degenerate");
        assert!(!document.can_undo(), "a rejected warp must not be recorded");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_new_edit_discards_the_redo_branch() {
        let dir = temp_dir();
        let mut document = open(&dir);
        assert!(document
            .apply(EditOperation::Rotate { degrees: 90 })
            .unwrap());
        assert!(document.undo());
        assert!(document.can_redo());
        assert!(document
            .apply(EditOperation::Resize {
                width: 32,
                height: 16,
                fill: None,
            })
            .unwrap());
        assert!(!document.can_redo());
        assert_eq!(
            document.history(),
            vec![UiText::with("resize", ["32", "16"])]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A long-edge limit scales the whole frame, keeps its shape and never
    /// enlarges a picture that is already small enough. Rounding can make the
    /// short side one pixel but never zero.
    #[test]
    fn export_dimensions_keep_the_aspect_and_never_upscale() {
        assert_eq!(export_dimensions(160, 120, 64), Some((64, 48)));
        assert_eq!(export_dimensions(120, 160, 64), Some((48, 64)));
        // The same limit on a square keeps it square.
        assert_eq!(export_dimensions(100, 100, 50), Some((50, 50)));
        // A limit at or above the longer side is not a request to upscale.
        assert_eq!(export_dimensions(160, 120, 160), None);
        assert_eq!(export_dimensions(160, 120, 1000), None);
        assert_eq!(export_dimensions(160, 120, 0), None);
        // A very thin picture keeps at least one row.
        assert_eq!(export_dimensions(4000, 3, 8), Some((8, 1)));
    }

    #[test]
    fn cover_rect_keeps_the_centre() {
        // A 2:1 source resized to 1:1 keeps the full height and takes a square
        // width from the middle: Resize has no anchor, so nothing else can
        // move the crop off centre.
        assert_eq!(cover_rect(64, 32, 16, 16), (16, 0, 32, 32));
        // A taller source loses rows instead.
        assert_eq!(cover_rect(32, 64, 16, 16), (0, 16, 32, 32));
        // The same aspect keeps the whole image.
        assert_eq!(cover_rect(64, 32, 32, 16), (0, 0, 64, 32));
        // A 3:2 target on a 2:1 source keeps full height and trims the width
        // to the nearest pixel, centred.
        assert_eq!(cover_rect(64, 32, 15, 10), (8, 0, 48, 32));
        assert_eq!(cover_rect(64, 32, 10, 15), (21, 0, 21, 32));
    }

    #[test]
    fn fit_padding_centres_the_source_in_a_square_target() {
        let image = RgbaImage::from_pixel(4, 2, image::Rgba([10, 20, 30, 255]));
        let fitted = fit_with_padding(&image, 4, 4, [1, 2, 3]);
        assert_eq!(fitted.dimensions(), (4, 4));
        // One row of fill above and below the centred source, never all on one
        // side.
        assert_eq!(fitted.get_pixel(0, 0), &image::Rgba([1, 2, 3, 255]));
        assert_eq!(fitted.get_pixel(0, 1), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(fitted.get_pixel(3, 2), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(fitted.get_pixel(3, 3), &image::Rgba([1, 2, 3, 255]));
        // A tall source is padded left and right instead.
        let tall = RgbaImage::from_pixel(2, 4, image::Rgba([10, 20, 30, 255]));
        let fitted = fit_with_padding(&tall, 4, 4, [9, 8, 7]);
        assert_eq!(fitted.get_pixel(0, 0), &image::Rgba([9, 8, 7, 255]));
        assert_eq!(fitted.get_pixel(1, 0), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(fitted.get_pixel(2, 3), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(fitted.get_pixel(3, 3), &image::Rgba([9, 8, 7, 255]));
    }

    #[test]
    fn fit_padding_keeps_a_non_square_target() {
        let image = RgbaImage::from_pixel(4, 2, image::Rgba([10, 20, 30, 255]));
        // An 8 × 4 target has the source's 2:1 shape: the whole frame is the
        // image and the colour is never used.
        let exact = fit_with_padding(&image, 8, 4, [1, 2, 3]);
        assert_eq!(exact.dimensions(), (8, 4));
        assert_eq!(exact.get_pixel(0, 0), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(exact.get_pixel(7, 3), &image::Rgba([10, 20, 30, 255]));
        // An 8 × 6 target is taller than the source: a 1 px band on top and
        // bottom, not a square.
        let wide = fit_with_padding(&image, 8, 6, [1, 2, 3]);
        assert_eq!(wide.dimensions(), (8, 6));
        assert_eq!(wide.get_pixel(0, 0), &image::Rgba([1, 2, 3, 255]));
        assert_eq!(wide.get_pixel(0, 1), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(wide.get_pixel(7, 4), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(wide.get_pixel(7, 5), &image::Rgba([1, 2, 3, 255]));
        // A portrait source in an 8 × 4 frame is pillarboxed, not squared.
        let tall = RgbaImage::from_pixel(2, 4, image::Rgba([10, 20, 30, 255]));
        let pillarboxed = fit_with_padding(&tall, 8, 4, [4, 5, 6]);
        assert_eq!(pillarboxed.dimensions(), (8, 4));
        assert_eq!(pillarboxed.get_pixel(0, 0), &image::Rgba([4, 5, 6, 255]));
        assert_eq!(pillarboxed.get_pixel(3, 0), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(pillarboxed.get_pixel(4, 3), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(pillarboxed.get_pixel(7, 0), &image::Rgba([4, 5, 6, 255]));
    }

    #[test]
    fn resize_can_fit_the_whole_image_with_the_chosen_colour() {
        let dir = temp_dir();
        let path = source_file(&dir, "photo.png", 8, 4);
        let mut document = open_document(&path).unwrap();
        let source_pixel = *document.pixels().get_pixel(0, 2);
        assert!(document
            .apply(EditOperation::Resize {
                width: 8,
                height: 8,
                fill: Some([255, 0, 0]),
            })
            .unwrap());
        assert_eq!(document.dimensions(), (8, 8));
        assert_eq!(
            document.pixels().get_pixel(0, 7),
            &image::Rgba([255, 0, 0, 255]),
            "the leftover band is the chosen colour"
        );
        assert_eq!(
            document.pixels().get_pixel(0, 4),
            &source_pixel,
            "the source was not stretched to the square"
        );
        assert_eq!(
            document.history(),
            vec![UiText::with("resize_pad", ["8", "8", "#ff0000"])]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn reset_returns_to_the_original_pixels_and_clears_history() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let original = document.pixels();
        assert!(document
            .apply(EditOperation::Crop {
                x: 1,
                y: 2,
                width: 10,
                height: 10,
            })
            .unwrap());
        assert!(document.reset());
        assert_eq!(document.dimensions(), (64, 32));
        assert_eq!(document.pixels().as_raw(), original.as_raw());
        assert!(!document.can_undo());
        assert!(
            !document.reset(),
            "an untouched document has nothing to reset"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn history_is_bounded() {
        let dir = temp_dir();
        let mut document = open(&dir);
        for _ in 0..(MAX_HISTORY_STEPS + 5) {
            assert!(document
                .apply(EditOperation::Rotate { degrees: 90 })
                .unwrap());
        }
        assert_eq!(document.history().len(), MAX_HISTORY_STEPS);
        // Undo still walks back through every step that was kept.
        for _ in 0..MAX_HISTORY_STEPS {
            assert!(document.undo());
        }
        assert!(!document.undo());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn preview_is_written_downscaled_and_is_a_png() {
        let dir = temp_dir();
        let document = open_document(&source_file(&dir, "big.png", 400, 200)).unwrap();
        let preview = dir.join("preview.png");
        render_preview(&document.pixels(), &preview).unwrap();
        let decoded = image::open(&preview).unwrap();
        assert_eq!(
            (decoded.width(), decoded.height()),
            (400, 200),
            "small images are not upscaled"
        );

        let wide = RgbaImage::from_fn(PREVIEW_LONG_EDGE * 2, PREVIEW_LONG_EDGE, |x, y| {
            image::Rgba([(x % 256) as u8, (y % 256) as u8, 0, 255])
        });
        render_preview(&wide, &preview).unwrap();
        let decoded = image::open(&preview).unwrap();
        assert_eq!(decoded.width(), PREVIEW_LONG_EDGE);
        assert_eq!(decoded.height(), PREVIEW_LONG_EDGE / 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn every_save_format_round_trips_the_working_pixels() {
        let dir = temp_dir();
        let source = source_file(&dir, "source.png", 16, 8);
        let document = open_document(&source).unwrap();
        let pixels = document.pixels();
        for (extension, tolerance) in [
            ("png", 0u8),
            ("jpg", 4),
            ("webp", 0),
            ("tiff", 0),
            ("gif", 0),
            ("bmp", 0),
            ("tga", 0),
            ("qoi", 0),
        ] {
            let target = dir.join(format!("out.{extension}"));
            save_pixels(&source, &pixels, &target).unwrap();
            let written = image::open(&target)
                .unwrap_or_else(|error| panic!("{extension} did not decode: {error}"))
                .to_rgba8();
            assert_eq!(written.dimensions(), pixels.dimensions(), "{extension}");
            for (index, (before, after)) in
                pixels.pixels().zip(written.pixels()).enumerate().step_by(7)
            {
                for channel in 0..3 {
                    let delta = before.0[channel].abs_diff(after.0[channel]);
                    assert!(
                        delta <= tolerance,
                        "{extension} pixel {index} channel {channel}: {before:?} vs {after:?}"
                    );
                }
            }
        }
        // An extension with no encoder is refused, and writes nothing.
        let refused = dir.join("out.psd");
        assert!(save_pixels(&source, &pixels, &refused).is_err());
        assert!(!refused.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_document_tracks_whether_its_pixels_are_on_disk() {
        let dir = temp_dir();
        let source = source_file(&dir, "photo.png", 20, 10);
        let mut document = open_document(&source).unwrap();
        assert!(!document.has_unsaved_changes());

        assert!(document
            .apply(EditOperation::Rotate { degrees: 90 })
            .unwrap());
        assert!(document.has_unsaved_changes());

        let target = dir.join("copy.png");
        save_pixels(&source, &document.pixels(), &target).unwrap();
        document.mark_saved(target.clone()).unwrap();
        assert!(!document.has_unsaved_changes());
        assert_eq!(document.save_target().0, target);

        // Undo goes back to the pixels as opened, which is not what the save
        // wrote, so the document is unsaved again; the file on disk is the
        // rotated one.
        assert!(document.undo());
        assert!(
            document.has_unsaved_changes(),
            "the save wrote the rotated pixels"
        );
        assert!(document
            .apply(EditOperation::Flip {
                axis: FlipAxis::Vertical
            })
            .unwrap());
        assert!(document.has_unsaved_changes());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn overwriting_the_source_keeps_the_previous_file_as_a_backup() {
        let dir = temp_dir();
        let source = source_file(&dir, "photo.png", 20, 10);
        let before = std::fs::read(&source).unwrap();
        let mut document = open_document(&source).unwrap();
        assert!(document
            .apply(EditOperation::Resize {
                width: 10,
                height: 5,
                fill: None,
            })
            .unwrap());
        save_pixels(&source, &document.pixels(), &source).unwrap();
        assert!(
            document.source_changed(),
            "a write from outside the document is detected"
        );
        document.remember_source();
        assert!(!document.source_changed(), "the document's own save is not");
        let decoded = image::open(&source).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (10, 5));
        let backup = dir.join("photo.png.bak");
        assert_eq!(std::fs::read(&backup).unwrap(), before);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn operation_labels_are_codes_not_sentences() {
        // The wording lives in `UiLines.qml`; Core only names the operation and
        // the numbers. A translated history line in Core would be English in a
        // Vietnamese window, which is the bug this shape exists to prevent.
        assert_eq!(
            EditOperation::Rotate { degrees: 90 }.label(),
            UiText::new("rotate_right")
        );
        assert_eq!(
            EditOperation::Rotate { degrees: -90 }.label(),
            UiText::new("rotate_left")
        );
        assert_eq!(
            EditOperation::Flip {
                axis: FlipAxis::Horizontal
            }
            .label(),
            UiText::new("flip_horizontal")
        );
        assert_eq!(
            EditOperation::Crop {
                x: 1,
                y: 2,
                width: 3,
                height: 4
            }
            .label(),
            UiText::with("crop", ["3", "4", "1", "2"])
        );
        assert_eq!(
            EditOperation::Resize {
                width: 512,
                height: 512,
                fill: None
            }
            .label(),
            UiText::with("resize", ["512", "512"])
        );
        // The label must name the colour it padded with, not only the size.
        assert_eq!(
            EditOperation::Resize {
                width: 512,
                height: 512,
                fill: Some([255, 0, 0])
            }
            .label(),
            UiText::with("resize_pad", ["512", "512", "#ff0000"])
        );
        // No code ever arrives with a formatted sentence in it.
        for operation in [
            EditOperation::Rotate { degrees: 45 },
            EditOperation::Resize {
                width: 3,
                height: 4,
                fill: Some([1, 2, 3]),
            },
        ] {
            let label = operation.label();
            assert!(
                !label.code.contains(' ') && !label.code.contains('×'),
                "the code must be a stable key, not a sentence: {label:?}"
            );
        }
    }
}
