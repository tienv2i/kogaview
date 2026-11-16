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
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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
    },
}

impl EditOperation {
    /// The label the History panel shows. Kept next to the operation so a new
    /// operation cannot be added without deciding how it is named.
    pub fn label(&self) -> String {
        match self {
            Self::Rotate { degrees } => match degrees.rem_euclid(360) {
                90 => "Rotate right 90°".to_owned(),
                180 => "Rotate 180°".to_owned(),
                270 => "Rotate left 90°".to_owned(),
                other => format!("Rotate {other}°"),
            },
            Self::Flip { axis } => match axis {
                FlipAxis::Horizontal => "Flip horizontal".to_owned(),
                FlipAxis::Vertical => "Flip vertical".to_owned(),
            },
            Self::Crop {
                x,
                y,
                width,
                height,
            } => format!("Crop {width} × {height} at {x},{y}"),
            Self::Resize { width, height } => format!("Resize {width} × {height}"),
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
            let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 92);
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
    pub fn history(&self) -> Vec<String> {
        self.undo
            .iter()
            .map(|step| step.operation.label())
            .collect()
    }

    /// Apply an operation to the working pixels.
    ///
    /// Returns `Ok(true)` when pixels changed, `Ok(false)` for a request that
    /// would change nothing (crop to the full frame, resize to the same size),
    /// and `Err` with a user-facing message when the request is invalid. A
    /// changed document clears the redo branch, as in any editor.
    pub fn apply(&mut self, operation: EditOperation) -> Result<bool, String> {
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

    fn is_noop(&self, operation: &EditOperation) -> Result<bool, String> {
        let (width, height) = self.dimensions();
        match operation {
            EditOperation::Rotate { degrees } => {
                if degrees.rem_euclid(360) == 0 {
                    Err("rotation must be 90, 180 or 270 degrees".to_owned())
                } else {
                    Ok(false)
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
            } => {
                validate_resize(*w, *h)?;
                Ok(*w == width && *h == height)
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
) -> Result<(), String> {
    if width == 0 || height == 0 {
        return Err("crop width and height must be greater than zero".to_owned());
    }
    if x >= doc_w
        || y >= doc_h
        || x.saturating_add(width) > doc_w
        || y.saturating_add(height) > doc_h
    {
        return Err(format!(
            "crop {width} × {height} at {x},{y} does not fit the {doc_w} × {doc_h} image"
        ));
    }
    Ok(())
}

fn validate_resize(width: u32, height: u32) -> Result<(), String> {
    if width == 0 || height == 0 {
        return Err("resize width and height must be greater than zero".to_owned());
    }
    if u64::from(width) * u64::from(height) > MAX_DOCUMENT_PIXELS {
        return Err(format!(
            "resize to {width} × {height} is larger than the {MAX_DOCUMENT_PIXELS} pixel limit"
        ));
    }
    Ok(())
}

/// Render one operation into a new buffer, leaving `image` untouched.
fn render_operation(image: &RgbaImage, operation: &EditOperation) -> Result<RgbaImage, String> {
    let (width, height) = image.dimensions();
    match operation {
        EditOperation::Rotate { degrees } => match degrees.rem_euclid(360) {
            90 => Ok(imageops::rotate90(image)),
            180 => Ok(imageops::rotate180(image)),
            270 => Ok(imageops::rotate270(image)),
            other => Err(format!(
                "rotation must be 90, 180 or 270 degrees, got {other}"
            )),
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
        } => {
            validate_resize(*w, *h)?;
            Ok(imageops::resize(image, *w, *h, FilterType::Lanczos3))
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

/// Write the QML preview: PNG, downscaled to [`PREVIEW_LONG_EDGE`] on the long
/// edge. Runs on a worker thread; the document keeps full resolution.
pub fn render_preview(image: &RgbaImage, path: &Path) -> Result<(), String> {
    let (width, height) = image.dimensions();
    let longest = width.max(height);
    let preview = if longest > PREVIEW_LONG_EDGE {
        let scale = PREVIEW_LONG_EDGE as f64 / f64::from(longest);
        let target_w = ((f64::from(width) * scale).round() as u32).max(1);
        let target_h = ((f64::from(height) * scale).round() as u32).max(1);
        imageops::resize(image, target_w, target_h, FilterType::Triangle)
    } else {
        image.clone()
    };
    DynamicImage::ImageRgba8(preview)
        .save_with_format(path, ImageFormat::Png)
        .map_err(|error| format!("could not write the preview {}: {error}", path.display()))
}

/// A result produced on a worker thread and consumed by Core's poll loop.
pub enum EditorTask {
    Opened {
        generation: u64,
        document: EditorDocument,
        preview: PathBuf,
    },
    Preview {
        generation: u64,
        preview: PathBuf,
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
        let task = match open_document(&source)
            .and_then(|document| render_preview(&document.pixels(), &preview).map(|()| document))
        {
            Ok(document) => {
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
            vec!["Rotate right 90°", "Flip vertical"]
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
        assert!(error.contains("does not fit"), "{error}");
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
        assert!(error.contains("90, 180 or 270"), "{error}");
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
            })
            .unwrap());
        assert!(!document.can_redo());
        assert_eq!(document.history(), vec!["Resize 32 × 16"]);
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
    fn operation_labels_are_stable() {
        assert_eq!(
            EditOperation::Rotate { degrees: 90 }.label(),
            "Rotate right 90°"
        );
        assert_eq!(
            EditOperation::Rotate { degrees: -90 }.label(),
            "Rotate left 90°"
        );
        assert_eq!(
            EditOperation::Flip {
                axis: FlipAxis::Horizontal
            }
            .label(),
            "Flip horizontal"
        );
        assert_eq!(
            EditOperation::Crop {
                x: 1,
                y: 2,
                width: 3,
                height: 4
            }
            .label(),
            "Crop 3 × 4 at 1,2"
        );
    }
}
