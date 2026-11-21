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
use kogaview_protocol::{FlipAxis, ResizeFilter, ResizeMode};
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
                // Same dimensions are the only no-op: a pad colour on the same
                // target would fit the whole source exactly, so nothing is
                // added, and a stretch of the same size is the identity.
                Ok(*w == width && *h == height)
            }
            EditOperation::Transform { corners } => {
                validate_transform(corners, width, height)?;
                Ok(is_identity_quad(corners, width, height))
            }
            EditOperation::Paint {
                points,
                radius,
                opacity,
                ..
            } => {
                validate_paint(points, *radius, *opacity)?;
                // A valid stroke always leaves a mark: the validation rejects
                // an empty point list and a zero radius or opacity, so there is
                // no "nothing to do" case to report.
                Ok(false)
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
            // A stroke blends over the pixels underneath it, so inverting it
            // would need the original alpha at every touched pixel. Snapshot.
            EditOperation::Paint { .. } => Undo::Snapshot(before),
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
fn validate_crop_mode(
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

/// A crop whose canvas grows past the picture: start from the fill colour and
/// copy the part of the picture the rectangle keeps onto it. The rectangle is
/// in the new canvas' coordinates, so a negative origin means the picture
/// starts inside the canvas rather than at its top-left corner.
fn grow_crop(
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

/// The mode and the payload must agree: `Pad` is the only mode that paints
/// pixels the source does not have, so it is the only one that needs a colour.
/// A stretch or a cover with a stray `fill` ignores it rather than refusing,
/// because the mode is the answer the caller gave.
fn validate_resize_mode(mode: ResizeMode, fill: Option<[u8; 3]>) -> Result<(), UiText> {
    if mode == ResizeMode::Pad && fill.is_none() {
        return Err(UiText::new("resize_pad_needs_colour"));
    }
    Ok(())
}
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

/// The largest brush radius accepted, in document pixels. A stroke is a paint
/// operation, not a fill: a radius this big still paints one line, and the cap
/// keeps a bad client from asking for a coverage mask over the whole frame.
const MAX_BRUSH_RADIUS: f64 = 4096.0;

/// A stroke needs at least one finite point, a radius with some width and an
/// opacity above zero. Outside coordinates are not an error: a stroke that
/// starts off the canvas and enters it is clipped, exactly like a real brush
/// held past the paper's edge.
fn validate_paint(points: &[[f64; 2]], radius: f64, opacity: f64) -> Result<(), UiText> {
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

/// Paint one stroke as a union of round-capped capsules.
///
/// The coverage of a pixel is the *maximum* over every segment that reaches it,
/// not a sum: a stroke that crosses itself or doubles back would otherwise get
/// darker at the join, which is the classic overlap artefact of painting dabs.
/// Each segment is feathered over one pixel at its edge so a diagonal is not a
/// staircase. A brush blends `color` source-over the pixels; an eraser only
/// lowers their alpha, so it works on a transparent document too.
fn paint_stroke(
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

/// Resample one image with the filter the form asked for.
///
/// `Auto` is a box average for a downscale — fast and right for shrinking a
/// photo to a delivery size — and Lanczos3 when the target is larger, where a
/// box average would leave a hard-edged enlargement. The named choices map to
/// the `image` crate's kernels: `Bilinear` to its triangle, `Bicubic` to
/// Catmull-Rom, `Bspline` to its Gaussian approximation.
fn resample(
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
fn fit_with_padding(
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

/// True when the file's bytes are encoded in a format `image` has a decoder
/// for in this build. The extension decides what the browser lists; the bytes
/// decide whether it can be decoded, so a mislabelled file says so plainly.
pub fn has_decoder(path: &Path) -> bool {
    match ImageReader::open(path).and_then(|reader| reader.with_guessed_format()) {
        // `format()` only says the bytes *look* like a known format. Building the
        // decoder is what proves this build carries one: `image`'s `avif`
        // feature is an encoder, and a file can be sniffed as AVIF while
        // `into_decoder` still answers "not supported".
        Ok(reader) => reader.into_decoder().is_ok(),
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

    /// The browser advertises `.avif`, the Viewer draws it through Qt, and this
    /// build once answered "The image format Avif is not supported" from the
    /// Editor because `image`'s `avif` feature is an encoder. The decoder is
    /// `avif-native` (ADR 0005 revision); this test encodes a real AVIF and
    /// opens it back, so the advertised format is proven decodable rather than
    /// only named.
    #[test]
    fn an_advertised_avif_is_really_decoded() {
        let dir = temp_dir();
        let path = dir.join("sample.avif");
        let pixels = pattern(16, 12);
        let mut bytes = Vec::new();
        image::codecs::avif::AvifEncoder::new_with_speed_quality(&mut bytes, 10, 60)
            .write_image(
                pixels.as_raw(),
                pixels.width(),
                pixels.height(),
                ExtendedColorType::Rgba8,
            )
            .expect("the encoder must produce an AVIF");
        std::fs::write(&path, &bytes).unwrap();

        assert!(
            has_decoder(&path),
            "the browser lists .avif but the build has no decoder for it"
        );
        let document = open_document(&path).expect("the advertised AVIF must open");
        assert_eq!(document.dimensions(), (16, 12));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// An extension is not a decoder. Before `has_decoder` built the decoder it
    /// answered true for any name `image` could map, which is how a HEIC or this
    /// build's AVIF reached the worker and failed in English instead of being
    /// refused with a translatable line.
    #[test]
    fn a_file_with_no_decoder_is_reported_as_such() {
        let dir = temp_dir();
        let broken = dir.join("broken.jpg");
        std::fs::write(&broken, b"this is not a JPEG").unwrap();
        assert!(!has_decoder(&broken), "a .jpg name is not a JPEG decoder");

        let unlisted = dir.join("phone.heic");
        std::fs::write(&unlisted, b"this is not a HEIC either").unwrap();
        assert!(!has_decoder(&unlisted), "HEIC has no decoder in this build");
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
                fill: None,
                fill_alpha: 255,
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
                fill_alpha: 255,
                mode: ResizeMode::Stretch,
                filter: ResizeFilter::Auto,
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
                fill: None,
                fill_alpha: 255,
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
    fn a_crop_with_a_fill_can_grow_the_canvas_past_the_picture() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let original = document.pixels();
        // Four pixels of border on the left and top, eight on the right and
        // six below: the rectangle reaches outside the picture on every side.
        assert!(document
            .apply(EditOperation::Crop {
                x: -4,
                y: -3,
                width: 76,
                height: 41,
                fill: Some([10, 20, 30]),
                fill_alpha: 255,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (76, 41));
        // The grown border carries the chosen colour…
        assert_eq!(
            document.pixels().get_pixel(0, 0),
            &image::Rgba([10, 20, 30, 255])
        );
        assert_eq!(
            document.pixels().get_pixel(75, 40),
            &image::Rgba([10, 20, 30, 255])
        );
        // …and the picture sits inside it at the rectangle's origin.
        assert_eq!(
            document.pixels().get_pixel(4, 3),
            original.get_pixel(0, 0),
            "the picture did not move to the grown canvas' origin"
        );
        assert_eq!(
            document.pixels().get_pixel(67, 34),
            original.get_pixel(63, 31),
            "the picture's last pixel must land at its rectangle offset"
        );
        assert_eq!(
            document.history(),
            vec![UiText::with("crop_grow", ["76", "41", "#0a141e"])]
        );

        // A transparent grow keeps the picture and leaves the border clear.
        assert!(document
            .apply(EditOperation::Crop {
                x: -2,
                y: -2,
                width: 80,
                height: 45,
                fill: Some([0, 0, 0]),
                fill_alpha: 0,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (80, 45));
        assert_eq!(
            document.pixels().get_pixel(0, 0),
            &image::Rgba([0, 0, 0, 0])
        );
        assert_eq!(
            document.pixels().get_pixel(2, 2),
            &image::Rgba([10, 20, 30, 255])
        );

        // A "grow" that misses the picture is only a coloured page, so it is
        // refused rather than silently replacing the photo with a swatch.
        let error = document
            .apply(EditOperation::Crop {
                x: 200,
                y: 0,
                width: 20,
                height: 20,
                fill: Some([255, 255, 255]),
                fill_alpha: 255,
            })
            .unwrap_err();
        assert_eq!(error.code, "crop_outside_document");
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
                fill: None,
                fill_alpha: 255,
            })
            .unwrap());
        assert!(!document
            .apply(EditOperation::Resize {
                width: 64,
                height: 32,
                fill: None,
                fill_alpha: 255,
                mode: ResizeMode::Stretch,
                filter: ResizeFilter::Auto,
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
                fill_alpha: 255,
                mode: ResizeMode::Stretch,
                filter: ResizeFilter::Auto,
            })
            .unwrap());
        assert!(!document.can_redo());
        assert_eq!(
            document.history(),
            vec![UiText::with("resize", ["32", "16"])]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A stroke is one history step: it paints its colour at full opacity,
    /// leaves pixels outside it alone, and undo restores the exact bytes.
    #[test]
    fn a_brush_stroke_paints_its_colour_and_undoes_in_one_step() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let before = document.pixels();
        assert!(document
            .apply(EditOperation::Paint {
                points: vec![[16.3, 16.0]],
                color: [255, 0, 0],
                radius: 4.0,
                opacity: 1.0,
                erase: false,
            })
            .unwrap());

        assert_eq!(document.history(), vec![UiText::new("brush_stroke")]);
        assert!(document.can_undo());
        let painted = document.pixels();
        // The centre of the dot is exactly the brush colour.
        assert_eq!(painted.get_pixel(16, 16).0, [255, 0, 0, 255]);
        // A pixel outside the stroke keeps its source value.
        assert_eq!(painted.get_pixel(50, 2).0, before.get_pixel(50, 2).0);
        // The edge is feathered: partly the brush, partly the source, never a
        // hard step.
        let edge = painted.get_pixel(20, 16).0;
        assert_ne!(edge, [255, 0, 0, 255]);
        assert_ne!(edge, before.get_pixel(20, 16).0);

        assert!(document.undo());
        assert_eq!(document.pixels().as_raw(), before.as_raw());
        assert!(document.history().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// An eraser lowers alpha and keeps the colour it uncovered, and a stroke
    /// that doubles back does not erase twice at the join: coverage is the
    /// maximum over the segments, not their sum.
    #[test]
    fn an_eraser_lowers_alpha_without_building_up_at_a_join() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let before = document.pixels();
        assert!(document
            .apply(EditOperation::Paint {
                points: vec![[10.0, 10.0], [30.0, 10.0], [10.0, 10.0]],
                color: [0, 0, 0],
                radius: 3.0,
                opacity: 0.5,
                erase: true,
            })
            .unwrap());

        assert_eq!(
            document.history(),
            vec![UiText::new("eraser_stroke")],
            "the history names the eraser, not the brush"
        );
        // 255 × (1 − 0.5) = 127.5 → 128 at full coverage. A sum over the
        // outbound and return segments would erase this pixel twice.
        let pixel = document.pixels().get_pixel(20, 10).0;
        assert_eq!(pixel[3], 128, "the overlap erased twice: {pixel:?}");
        // The eraser does not repaint the colour.
        assert_eq!(&pixel[..3], &before.get_pixel(20, 10).0[..3]);
        // The outbound and return legs cover the same line, so the result must
        // be the same as one leg on its own — including on the anti-aliased
        // edge, where a sum would darken the ring. Comparing the whole frame
        // rather than one hand-picked pixel keeps the check honest about the
        // geometry.
        let doubled = document.pixels();
        assert!(document.undo());
        assert!(document
            .apply(EditOperation::Paint {
                points: vec![[10.0, 10.0], [30.0, 10.0]],
                color: [0, 0, 0],
                radius: 3.0,
                opacity: 0.5,
                erase: true,
            })
            .unwrap());
        assert_eq!(
            doubled.as_raw(),
            document.pixels().as_raw(),
            "the return leg summed its dabs instead of covering them once"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A request a brush cannot honour is refused with a line, not painted as
    /// far as it can go.
    #[test]
    fn a_malformed_stroke_is_rejected_with_a_line() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let mut paint = |points: Vec<[f64; 2]>, radius: f64, opacity: f64| {
            document.apply(EditOperation::Paint {
                points,
                color: [1, 2, 3],
                radius,
                opacity,
                erase: false,
            })
        };

        assert_eq!(
            paint(Vec::new(), 4.0, 1.0).unwrap_err().code,
            "paint_empty_stroke"
        );
        assert_eq!(
            paint(vec![[f64::NAN, 0.0]], 4.0, 1.0).unwrap_err().code,
            "paint_bad_point"
        );
        assert_eq!(
            paint(vec![[1.0, 1.0]], 0.0, 1.0).unwrap_err().code,
            "paint_bad_radius"
        );
        assert_eq!(
            paint(vec![[1.0, 1.0]], 4.0, 0.0).unwrap_err().code,
            "paint_bad_opacity"
        );
        assert!(!document.can_undo(), "a refused stroke records no step");
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
    fn the_resize_filter_changes_the_pixels() {
        // A step of two values, enlarged. Nearest may only copy the two source
        // values; a smooth kernel has to interpolate the step it crosses, so the
        // dropdown is a real control rather than a second label.
        let mut image = RgbaImage::new(4, 1);
        for x in 0..4u32 {
            let value = if x < 2 { 0 } else { 255 };
            image.put_pixel(x, 0, image::Rgba([value, value, value, 255]));
        }
        let nearest = resample(&image, 18, 5, ResizeFilter::Nearest);
        let bilinear = resample(&image, 18, 5, ResizeFilter::Bilinear);
        let lanczos = resample(&image, 18, 5, ResizeFilter::Lanczos3);
        assert_eq!(nearest.dimensions(), (18, 5));
        assert!(nearest
            .pixels()
            .all(|pixel| pixel[0] == 0 || pixel[0] == 255));
        assert!(bilinear
            .pixels()
            .any(|pixel| pixel[0] > 0 && pixel[0] < 255));
        assert!(lanczos.pixels().any(|pixel| pixel[0] > 0 && pixel[0] < 255));
        assert_ne!(nearest.as_raw(), bilinear.as_raw());
        assert_ne!(bilinear.as_raw(), lanczos.as_raw());
        // `Auto` enlarges with Lanczos3, so it cannot equal Nearest here.
        let automatic = resample(&image, 18, 5, ResizeFilter::Auto);
        assert_ne!(automatic.as_raw(), nearest.as_raw());
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
        let fitted = fit_with_padding(&image, 4, 4, [1, 2, 3], 255, ResizeFilter::Auto);
        assert_eq!(fitted.dimensions(), (4, 4));
        // One row of fill above and below the centred source, never all on one
        // side.
        assert_eq!(fitted.get_pixel(0, 0), &image::Rgba([1, 2, 3, 255]));
        assert_eq!(fitted.get_pixel(0, 1), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(fitted.get_pixel(3, 2), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(fitted.get_pixel(3, 3), &image::Rgba([1, 2, 3, 255]));
        // A tall source is padded left and right instead.
        let tall = RgbaImage::from_pixel(2, 4, image::Rgba([10, 20, 30, 255]));
        let fitted = fit_with_padding(&tall, 4, 4, [9, 8, 7], 255, ResizeFilter::Auto);
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
        let exact = fit_with_padding(&image, 8, 4, [1, 2, 3], 255, ResizeFilter::Auto);
        assert_eq!(exact.dimensions(), (8, 4));
        assert_eq!(exact.get_pixel(0, 0), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(exact.get_pixel(7, 3), &image::Rgba([10, 20, 30, 255]));
        // An 8 × 6 target is taller than the source: a 1 px band on top and
        // bottom, not a square.
        let wide = fit_with_padding(&image, 8, 6, [1, 2, 3], 255, ResizeFilter::Auto);
        assert_eq!(wide.dimensions(), (8, 6));
        assert_eq!(wide.get_pixel(0, 0), &image::Rgba([1, 2, 3, 255]));
        assert_eq!(wide.get_pixel(0, 1), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(wide.get_pixel(7, 4), &image::Rgba([10, 20, 30, 255]));
        assert_eq!(wide.get_pixel(7, 5), &image::Rgba([1, 2, 3, 255]));
        // A portrait source in an 8 × 4 frame is pillarboxed, not squared.
        let tall = RgbaImage::from_pixel(2, 4, image::Rgba([10, 20, 30, 255]));
        let pillarboxed = fit_with_padding(&tall, 8, 4, [4, 5, 6], 255, ResizeFilter::Auto);
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
                fill_alpha: 255,
                mode: ResizeMode::Pad,
                filter: ResizeFilter::Auto,
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
    fn resize_can_leave_the_leftover_transparent() {
        let dir = temp_dir();
        let path = source_file(&dir, "photo.png", 8, 4);
        let mut document = open_document(&path).unwrap();
        assert!(document
            .apply(EditOperation::Resize {
                width: 8,
                height: 8,
                fill: Some([255, 0, 0]),
                fill_alpha: 0,
                mode: ResizeMode::Pad,
                filter: ResizeFilter::Auto,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (8, 8));
        assert_eq!(
            document.pixels().get_pixel(0, 7),
            &image::Rgba([255, 0, 0, 0]),
            "the leftover band kept the chosen colour but not an opaque alpha"
        );
        assert_eq!(
            document.history(),
            vec![UiText::with("resize_pad_clear", ["8", "8"])]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A resize answers "make it this big". Changing the shape must not
    /// silently throw the edges away, which is what the old cover-by-default
    /// path did: a 64 × 32 picture resized to a square lost a quarter of its
    /// width with nothing on screen saying so.
    #[test]
    fn a_stretch_resize_keeps_every_column() {
        let dir = temp_dir();
        let mut document = open(&dir); // 64 × 32 pattern
        assert!(document
            .apply(EditOperation::Resize {
                width: 32,
                height: 32,
                fill: None,
                fill_alpha: 255,
                mode: ResizeMode::Stretch,
                filter: ResizeFilter::Nearest,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (32, 32));
        // The pattern's red channel is x * 8, so a 64-wide source starts at 0
        // and ends at 63 * 8 mod 256 = 248. `Nearest` samples half a pixel in,
        // which is why the first column is 8 rather than 0; the point is that
        // both *ends* of the source are present, where the old cover crop
        // would have handed back 128 and 120.
        let first = document.pixels().get_pixel(0, 0)[0];
        let last = document.pixels().get_pixel(31, 0)[0];
        assert!(
            first < 40,
            "the stretch started at {first}, not near the source's left edge"
        );
        assert!(
            last > 200,
            "the stretch ended at {last}, not near the source's right edge"
        );
        assert_eq!(
            document.history(),
            vec![UiText::with("resize", ["32", "32"])],
            "a stretch is a resize, not a crop"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// `Cover` is the old behaviour, now a choice: the centred rectangle that
    /// matches the target's shape, then a scale.
    #[test]
    fn a_cover_resize_crops_the_centre_and_says_so() {
        let dir = temp_dir();
        let mut document = open(&dir); // 64 × 32, red = x * 8
        assert!(document
            .apply(EditOperation::Resize {
                width: 32,
                height: 32,
                fill: None,
                fill_alpha: 255,
                mode: ResizeMode::Cover,
                filter: ResizeFilter::Nearest,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (32, 32));
        // The cover rectangle starts at x = 16, so the first column is 128.
        assert_eq!(document.pixels().get_pixel(0, 0)[0], 128);
        assert_eq!(document.pixels().get_pixel(31, 0)[0], 120);
        assert_eq!(
            document.history(),
            vec![UiText::with("resize_cover", ["32", "32"])],
            "the history must say which resize discarded the edges"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A locked ratio produces integer sides that miss the shape by a fraction
    /// of a pixel. Covering must not lose the row that difference is worth.
    #[test]
    fn a_rounded_ratio_does_not_shave_a_pixel() {
        let dir = temp_dir();
        let mut image = pattern(200, 134);
        for x in 0..200 {
            image.put_pixel(x, 133, image::Rgba([1, 2, 3, 255]));
        }
        let mut document = EditorDocument::from_image(dir.join("photo.png"), image);
        // 200 × 134 → 200 × 133 is the rounding a 200 × 133.0 target produces.
        // Cover would crop one row; the snap keeps the whole frame instead.
        assert!(document
            .apply(EditOperation::Resize {
                width: 200,
                height: 133,
                fill: None,
                fill_alpha: 255,
                mode: ResizeMode::Cover,
                filter: ResizeFilter::Nearest,
            })
            .unwrap());
        assert_eq!(document.dimensions(), (200, 133));
        assert_eq!(
            document.pixels().get_pixel(0, 132),
            &image::Rgba([1, 2, 3, 255]),
            "the last row was shaved by the rounding"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// `Pad` is the only mode that paints pixels the source does not have, so
    /// it is the only one that needs a colour; asking for it without one is a
    /// refusal, not a silent black border.
    #[test]
    fn a_pad_without_a_colour_is_refused() {
        let dir = temp_dir();
        let mut document = open(&dir);
        let error = document
            .apply(EditOperation::Resize {
                width: 32,
                height: 32,
                fill: None,
                fill_alpha: 255,
                mode: ResizeMode::Pad,
                filter: ResizeFilter::Auto,
            })
            .unwrap_err();
        assert_eq!(error.code, "resize_pad_needs_colour");
        assert_eq!(document.dimensions(), (64, 32));
        assert!(!document.can_undo(), "a refused resize is not recorded");
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
                fill: None,
                fill_alpha: 255,
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
                fill_alpha: 255,
                mode: ResizeMode::Stretch,
                filter: ResizeFilter::Auto,
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
                height: 4,
                fill: None,
                fill_alpha: 255
            }
            .label(),
            UiText::with("crop", ["3", "4", "1", "2"])
        );
        assert_eq!(
            EditOperation::Resize {
                width: 512,
                height: 512,
                fill: None,
                fill_alpha: 255,
                mode: ResizeMode::Stretch,
                filter: ResizeFilter::Auto
            }
            .label(),
            UiText::with("resize", ["512", "512"])
        );
        // The label must name the colour it padded with, not only the size.
        assert_eq!(
            EditOperation::Resize {
                width: 512,
                height: 512,
                fill: Some([255, 0, 0]),
                fill_alpha: 255,
                mode: ResizeMode::Pad,
                filter: ResizeFilter::Auto
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
                fill_alpha: 255,
                mode: ResizeMode::Pad,
                filter: ResizeFilter::Auto,
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
