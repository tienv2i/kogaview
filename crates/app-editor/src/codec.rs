//! Reading a picture into pixels and writing pixels back out: the decoders,
//! the encoders, the atomic save, the export copy and the JPEG metadata the
//! original carried.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::*;
use image::imageops::{self, FilterType};
use image::{DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, ImageReader, RgbaImage};

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
    Ora,
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
            "ora" => Self::Ora,
            _ => return None,
        })
    }

    /// The format a batch convert named explicitly. The destination extension
    /// is then built by Core, so it cannot be inferred from a path.
    pub fn from_image_format(format: kogaview_protocol::ImageFormat) -> Self {
        use kogaview_protocol::ImageFormat;
        match format {
            ImageFormat::Png => Self::Png,
            ImageFormat::Jpeg => Self::Jpeg,
            ImageFormat::Webp => Self::Webp,
            ImageFormat::Tiff => Self::Tiff,
            ImageFormat::Gif => Self::Gif,
            ImageFormat::Bmp => Self::Bmp,
            ImageFormat::Tga => Self::Tga,
            ImageFormat::Qoi => Self::Qoi,
        }
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
            Self::Ora => ".ora",
        }
    }

    /// The list every surface shows for "what can I save to".
    pub const CHOICES: &'static str = ".png .jpg .webp .tiff .gif .bmp .tga .qoi .ora";
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
        SaveFormat::Ora => {
            let stack = LayerStack::from_single(std::sync::Arc::new(image.clone()));
            return ora::write_ora(&stack);
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
                SaveFormat::Jpeg | SaveFormat::Gif | SaveFormat::Webp | SaveFormat::Ora => {
                    unreachable!()
                }
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
pub(crate) fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
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

/// Save a layered [`LayerStack`] to `path`.
///
/// When `path` has a `.ora` extension, writes a lossless OpenRaster archive
/// preserving every layer, blend mode, opacity, visibility, and offset. For all
/// flat formats, composites the stack and delegates to [`save_pixels`].
pub fn save_stack(source: &Path, stack: &LayerStack, path: &Path) -> Result<(), String> {
    if SaveFormat::from_path(path) == Some(SaveFormat::Ora) {
        let bytes = ora::write_ora(stack)?;
        if path == source && path.is_file() {
            let backup = backup_path(path);
            std::fs::copy(path, &backup).map_err(|error| {
                format!(
                    "could not keep a backup of {} at {}: {error}",
                    path.display(),
                    backup.display()
                )
            })?;
        }
        return write_atomically(path, &bytes);
    }
    let pixels = composite_stack(stack);
    save_pixels(source, &pixels, path)
}

/// Encode `pixels` and write them to `path`.
///
/// When `path` is `source`, the previous bytes are first copied to
/// `<name>.bak` *next to the file*, so a save over the original can still be
/// walked back. A save-as writes only the new file. Takes the source path
/// rather than the document so it can run on a worker: the document is not
/// `Send`-shared and the pixels come as an `Arc`.
pub fn save_pixels(source: &Path, pixels: &RgbaImage, path: &Path) -> Result<(), String> {
    save_pixels_with(source, pixels, path, None)
}

/// [`save_pixels`] with the lossy encoder's quality made explicit.
///
/// A batch convert lets the user choose the JPEG quality, so it cannot go
/// through the fixed default; the backup and atomic-write rules are the same
/// because a batch that replaces an original is still a save over it.
pub fn save_pixels_with(
    source: &Path,
    pixels: &RgbaImage,
    path: &Path,
    quality: Option<u8>,
) -> Result<(), String> {
    let format = SaveFormat::from_path(path).ok_or_else(|| {
        format!(
            "cannot save as {}; use one of {}",
            path.display(),
            SaveFormat::CHOICES
        )
    })?;
    let bytes = encode_with(pixels, format, quality)?;
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
pub(crate) fn export_dimensions(
    source_width: u32,
    source_height: u32,
    max_edge: u32,
) -> Option<(u32, u32)> {
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
pub(crate) fn jpeg_metadata_segments(bytes: &[u8]) -> Vec<(u8, &[u8])> {
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
pub(crate) fn splice_jpeg_metadata_segments(
    original: &[u8],
    encoded: Vec<u8>,
    keep_exif: bool,
) -> Vec<u8> {
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
pub(crate) fn file_stamp(path: &Path) -> Option<(u64, Option<std::time::SystemTime>)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.len(), metadata.modified().ok()))
}

/// `<name>.<ext>.bak` beside `path`, so `photo.jpg` becomes
/// `photo.jpg.bak` and is never mistaken for an image the app lists.
pub(crate) fn backup_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".to_owned());
    name.push_str(".bak");
    path.with_file_name(name)
}

/// True when the file's bytes are encoded in a format `image` has a decoder
/// for in this build. The extension decides what the browser lists; the bytes
/// decide whether it can be decoded, so a mislabelled file says so plainly.
pub fn has_decoder(path: &Path) -> bool {
    if ora::has_archive_decoder(path) {
        return true;
    }
    match ImageReader::open(path).and_then(|reader| reader.with_guessed_format()) {
        // `format()` only says the bytes *look* like a known format. Building the
        // decoder is what proves this build carries one: `image`'s `avif`
        // feature is an encoder, and a file can be sniffed as AVIF while
        // `into_decoder` still answers "not supported".
        Ok(reader) => reader.into_decoder().is_ok(),
        Err(_) => false,
    }
}

/// Decode an image file into 8-bit RGBA.
///
/// One implementation for the Editor's document and a batch worker: both must
/// refuse the same oversized pictures and both need the same alpha handling, or
/// a batch would edit a file the Editor calls too large.
pub fn decode_rgba(path: &Path) -> Result<RgbaImage, String> {
    if ora::is_archive_image_path(path) {
        return ora::read_zip_merged_image(path);
    }
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
    Ok(ImageReader::open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?
        .with_guessed_format()
        .map_err(|error| format!("could not read {}: {error}", path.display()))?
        .decode()
        .map_err(|error| format!("could not decode {}: {error}", path.display()))?
        .to_rgba8())
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
pub(crate) fn preview_pixels(image: &RgbaImage) -> RgbaImage {
    let (width, height) = image.dimensions();
    if width.max(height) > PREVIEW_LONG_EDGE {
        let (target_w, target_h) = preview_dimensions(width, height);
        imageops::thumbnail(image, target_w, target_h)
    } else {
        image.clone()
    }
}

/// A preview-sized decode of a large JPEG, or `None` when this is not the case.
///
/// A JPEG's DCT lets a decoder produce 1/2, 1/4 or 1/8 of the frame without
/// decoding the pixels it would throw away, and `image` does not expose that.
/// The result is only ever used for the *first* preview: the document still
/// decodes at full resolution, and every later preview is rendered from those
/// pixels. A file that fails here is simply decoded the ordinary way.
pub(crate) fn scaled_jpeg_preview(path: &Path) -> Result<Option<(RgbaImage, u32, u32)>, String> {
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

pub(crate) fn rgb_to_rgba(pixels: &[u8]) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(pixels.len() / 3 * 4);
    for chunk in pixels.chunks_exact(3) {
        rgba.extend_from_slice(&[chunk[0], chunk[1], chunk[2], 255]);
    }
    rgba
}
