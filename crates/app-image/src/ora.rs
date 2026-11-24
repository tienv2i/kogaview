//! OpenRaster (`.ora`) lossless multi-layer reader/writer and Krita (`.kra`)
//! preview extractor.
//!
//! Implements the OpenRaster 0.0.5 specification (interoperable with Krita and
//! GIMP):
//! - `mimetype` stored uncompressed as the first ZIP entry (`image/openraster`)
//! - `stack.xml` describing canvas size and layers top-to-bottom
//! - `data/layer{i}.png` per raster layer
//! - `mergedimage.png` full-resolution composite
//! - `Thumbnails/thumbnail.png` 256 px preview thumbnail

use std::io::{Cursor, Read, Write};
use std::path::Path;
use std::sync::Arc;

use image::imageops::FilterType;
use image::{ExtendedColorType, ImageEncoder, ImageReader, RgbaImage};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::layer::{composite_stack, BlendMode, Layer, LayerStack};
use crate::MAX_DOCUMENT_PIXELS;

const ORA_MIMETYPE: &[u8] = b"image/openraster";

pub fn is_ora_path(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("ora"))
}

pub fn is_kra_path(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("kra"))
}

pub fn is_archive_image_path(path: &Path) -> bool {
    is_ora_path(path) || is_kra_path(path)
}

/// Quick check that `path` is a `.ora` or `.kra` file starting with ZIP magic bytes.
pub fn has_archive_decoder(path: &Path) -> bool {
    if !is_archive_image_path(path) {
        return false;
    }
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).is_ok() && magic == [0x50, 0x4B, 0x03, 0x04]
}

/// Encode a [`LayerStack`] as an OpenRaster 0.0.5 (`.ora`) ZIP archive.
pub fn write_ora(stack: &LayerStack) -> Result<Vec<u8>, String> {
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut cursor);

        // 1. Mandatory uncompressed `mimetype` as the very first entry.
        let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        let deflated = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);

        zip.start_file("mimetype", stored)
            .map_err(|e| format!("ora: cannot write mimetype: {e}"))?;
        zip.write_all(ORA_MIMETYPE)
            .map_err(|e| format!("ora: cannot write mimetype bytes: {e}"))?;

        // 2. Build `stack.xml` (OpenRaster lists layers top-to-bottom).
        let mut xml = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <image version=\"0.0.5\" w=\"{}\" h=\"{}\">\n\
             \x20 <stack>\n",
            stack.canvas_width, stack.canvas_height
        );

        let mut layer_entries: Vec<(String, Vec<u8>)> = Vec::with_capacity(stack.layers.len());
        for (rev_idx, layer) in stack.layers.iter().rev().enumerate() {
            let src = format!("data/layer{rev_idx}.png");
            let visibility = if layer.visible { "visible" } else { "hidden" };
            let opacity = layer.opacity.clamp(0.0, 1.0);
            let comp_op = layer.blend_mode.ora_name();
            let escaped_name = xml_escape(&layer.name);
            xml.push_str(&format!(
                "    <layer name=\"{escaped_name}\" src=\"{src}\" x=\"{}\" y=\"{}\" opacity=\"{opacity:.4}\" visibility=\"{visibility}\" composite-op=\"{comp_op}\" />\n",
                layer.offset_x, layer.offset_y
            ));
            layer_entries.push((src, encode_png(&layer.pixels)?));
        }
        xml.push_str("  </stack>\n</image>\n");

        zip.start_file("stack.xml", deflated)
            .map_err(|e| format!("ora: cannot write stack.xml: {e}"))?;
        zip.write_all(xml.as_bytes())
            .map_err(|e| format!("ora: cannot write stack.xml bytes: {e}"))?;

        // 3. Per-layer PNG payloads (Stored: PNG is already compressed).
        for (src, png_bytes) in layer_entries {
            zip.start_file(&src, stored)
                .map_err(|e| format!("ora: cannot write {src}: {e}"))?;
            zip.write_all(&png_bytes)
                .map_err(|e| format!("ora: cannot write {src} bytes: {e}"))?;
        }

        // 4. Mandatory `mergedimage.png` full-resolution composite.
        let merged = composite_stack(stack);
        let merged_png = encode_png(&merged)?;
        zip.start_file("mergedimage.png", stored)
            .map_err(|e| format!("ora: cannot write mergedimage.png: {e}"))?;
        zip.write_all(&merged_png)
            .map_err(|e| format!("ora: cannot write mergedimage.png bytes: {e}"))?;

        // 5. Mandatory `Thumbnails/thumbnail.png` (max 256×256).
        let thumb = make_thumbnail(&merged, 256);
        let thumb_png = encode_png(&thumb)?;
        zip.start_file("Thumbnails/thumbnail.png", stored)
            .map_err(|e| format!("ora: cannot write Thumbnails/thumbnail.png: {e}"))?;
        zip.write_all(&thumb_png)
            .map_err(|e| format!("ora: cannot write Thumbnails/thumbnail.png bytes: {e}"))?;

        zip.finish()
            .map_err(|e| format!("ora: cannot finalize archive: {e}"))?;
    }
    Ok(cursor.into_inner())
}

/// Decode an OpenRaster (`.ora`) file into a full multi-layer [`LayerStack`].
pub fn read_ora(path: &Path) -> Result<LayerStack, String> {
    let file =
        std::fs::File::open(path).map_err(|e| format!("could not open {}: {e}", path.display()))?;
    let mut archive = ZipArchive::new(file)
        .map_err(|e| format!("{} is not a valid OpenRaster archive: {e}", path.display()))?;

    let xml = read_zip_string(&mut archive, "stack.xml")
        .map_err(|e| format!("{} is missing stack.xml: {e}", path.display()))?;

    let (canvas_w, canvas_h) = parse_image_dimensions(&xml).ok_or_else(|| {
        format!(
            "{} has invalid <image> dimensions in stack.xml",
            path.display()
        )
    })?;
    if canvas_w == 0 || canvas_h == 0 {
        return Err(format!("{} has zero canvas dimensions", path.display()));
    }
    if u64::from(canvas_w) * u64::from(canvas_h) > MAX_DOCUMENT_PIXELS {
        return Err(format!(
            "{canvas_w} × {canvas_h} is larger than the {MAX_DOCUMENT_PIXELS} pixel editor limit"
        ));
    }

    let parsed_layers = parse_layer_elements(&xml);
    if parsed_layers.is_empty() {
        // Fallback to mergedimage.png if stack.xml contains no <layer> nodes.
        let merged = read_zip_merged_image(path)?;
        return Ok(LayerStack::from_single(Arc::new(merged)));
    }

    // OpenRaster lists top-to-bottom; LayerStack stores bottom-to-top.
    let mut layers = Vec::with_capacity(parsed_layers.len());
    let mut next_id = 1u64;
    for spec in parsed_layers.into_iter().rev() {
        let png_bytes = read_zip_bytes(&mut archive, &spec.src)
            .map_err(|e| format!("ora: missing layer '{}': {e}", spec.src))?;
        let img = image::load_from_memory(&png_bytes)
            .map_err(|e| format!("ora: cannot decode layer '{}': {e}", spec.src))?
            .to_rgba8();
        let id = next_id;
        next_id += 1;
        let name = if spec.name.is_empty() {
            format!("Layer {id}")
        } else {
            spec.name
        };
        let mut layer = Layer::new(id, name, Arc::new(img));
        layer.offset_x = spec.x;
        layer.offset_y = spec.y;
        layer.opacity = spec.opacity.clamp(0.0, 1.0);
        layer.visible = spec.visible;
        layer.blend_mode = spec.blend_mode;
        layers.push(layer);
    }

    let active_layer_id = layers.last().map(|l| l.id).unwrap_or(1);
    Ok(LayerStack {
        canvas_width: canvas_w,
        canvas_height: canvas_h,
        layers,
        active_layer_id,
        next_id,
        background: None,
    })
}

/// Extract raw PNG bytes of the preview image (`mergedimage.png`, falling back
/// to `preview.png`) from a `.ora` or `.kra` archive.
pub fn extract_archive_preview_png(path: &Path) -> Result<Vec<u8>, String> {
    let file =
        std::fs::File::open(path).map_err(|e| format!("could not open {}: {e}", path.display()))?;
    let mut archive = ZipArchive::new(file)
        .map_err(|e| format!("{} is not a valid archive: {e}", path.display()))?;
    if let Ok(bytes) = read_zip_bytes(&mut archive, "mergedimage.png") {
        return Ok(bytes);
    }
    if let Ok(bytes) = read_zip_bytes(&mut archive, "preview.png") {
        return Ok(bytes);
    }
    if let Ok(bytes) = read_zip_bytes(&mut archive, "Thumbnails/thumbnail.png") {
        return Ok(bytes);
    }
    Err(format!(
        "{} does not contain a mergedimage.png or preview.png",
        path.display()
    ))
}

/// Decode `mergedimage.png` (or `preview.png`) from a `.ora` or `.kra` file into RGBA.
pub fn read_zip_merged_image(path: &Path) -> Result<RgbaImage, String> {
    let bytes = extract_archive_preview_png(path)?;
    let reader = ImageReader::new(Cursor::new(&bytes))
        .with_guessed_format()
        .map_err(|e| format!("cannot sniff archive preview {}: {e}", path.display()))?;
    let (w, h) = reader
        .into_dimensions()
        .map_err(|e| format!("cannot read archive preview size {}: {e}", path.display()))?;
    if u64::from(w) * u64::from(h) > MAX_DOCUMENT_PIXELS {
        return Err(format!(
            "{w} × {h} is larger than the {MAX_DOCUMENT_PIXELS} pixel editor limit"
        ));
    }
    image::load_from_memory(&bytes)
        .map_err(|e| format!("cannot decode archive preview {}: {e}", path.display()))
        .map(|img| img.to_rgba8())
}

/// Fast header-only dimensions for `.ora` or `.kra` files.
pub fn read_zip_dimensions(path: &Path) -> Option<(u32, u32)> {
    let file = std::fs::File::open(path).ok()?;
    let mut archive = ZipArchive::new(file).ok()?;
    if is_ora_path(path) {
        if let Ok(xml) = read_zip_string(&mut archive, "stack.xml") {
            if let Some(dims) = parse_image_dimensions(&xml) {
                return Some(dims);
            }
        }
    }
    let bytes = read_zip_bytes(&mut archive, "mergedimage.png")
        .or_else(|_| read_zip_bytes(&mut archive, "preview.png"))
        .ok()?;
    ImageReader::new(Cursor::new(&bytes))
        .with_guessed_format()
        .ok()?
        .into_dimensions()
        .ok()
}

fn encode_png(image: &RgbaImage) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new(&mut buf);
    encoder
        .write_image(
            image.as_raw(),
            image.width(),
            image.height(),
            ExtendedColorType::Rgba8,
        )
        .map_err(|e| format!("cannot encode PNG: {e}"))?;
    Ok(buf)
}

fn make_thumbnail(image: &RgbaImage, max_edge: u32) -> RgbaImage {
    let (w, h) = image.dimensions();
    let longest = w.max(h);
    if longest <= max_edge {
        return image.clone();
    }
    let scale = f64::from(max_edge) / f64::from(longest);
    let tw = ((f64::from(w) * scale).round() as u32).max(1);
    let th = ((f64::from(h) * scale).round() as u32).max(1);
    image::imageops::resize(image, tw, th, FilterType::Triangle)
}

fn read_zip_bytes(archive: &mut ZipArchive<std::fs::File>, name: &str) -> Result<Vec<u8>, String> {
    let mut entry = archive.by_name(name).map_err(|e| e.to_string())?;
    let mut buf = Vec::with_capacity(entry.size().min(64 * 1024 * 1024) as usize);
    entry.read_to_end(&mut buf).map_err(|e| e.to_string())?;
    Ok(buf)
}

fn read_zip_string(archive: &mut ZipArchive<std::fs::File>, name: &str) -> Result<String, String> {
    let bytes = read_zip_bytes(archive, name)?;
    String::from_utf8(bytes).map_err(|e| e.to_string())
}

fn xml_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(ch),
        }
    }
    out
}

fn xml_unescape(input: &str) -> String {
    input
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

struct ParsedLayer {
    name: String,
    src: String,
    x: i32,
    y: i32,
    opacity: f32,
    visible: bool,
    blend_mode: BlendMode,
}

fn parse_xml_attr(tag: &str, attr: &str) -> Option<String> {
    let needle_dq = format!("{attr}=\"");
    if let Some(start) = tag.find(&needle_dq) {
        let rest = &tag[start + needle_dq.len()..];
        if let Some(end) = rest.find('"') {
            return Some(xml_unescape(&rest[..end]));
        }
    }
    let needle_sq = format!("{attr}='");
    if let Some(start) = tag.find(&needle_sq) {
        let rest = &tag[start + needle_sq.len()..];
        if let Some(end) = rest.find('\'') {
            return Some(xml_unescape(&rest[..end]));
        }
    }
    None
}

fn parse_image_dimensions(xml: &str) -> Option<(u32, u32)> {
    let start = xml.find("<image")?;
    let rest = &xml[start..];
    let end = rest.find('>')?;
    let tag = &rest[..end];
    let w = parse_xml_attr(tag, "w")?.parse::<u32>().ok()?;
    let h = parse_xml_attr(tag, "h")?.parse::<u32>().ok()?;
    Some((w, h))
}

fn parse_layer_elements(xml: &str) -> Vec<ParsedLayer> {
    let mut out = Vec::new();
    let mut cursor = xml;
    while let Some(pos) = cursor.find("<layer") {
        let after = &cursor[pos..];
        let Some(end) = after.find('>') else {
            break;
        };
        let tag = &after[..end];
        if let Some(src) = parse_xml_attr(tag, "src") {
            let name = parse_xml_attr(tag, "name").unwrap_or_default();
            let x = parse_xml_attr(tag, "x")
                .and_then(|v| v.parse::<i32>().ok())
                .unwrap_or(0);
            let y = parse_xml_attr(tag, "y")
                .and_then(|v| v.parse::<i32>().ok())
                .unwrap_or(0);
            let opacity = parse_xml_attr(tag, "opacity")
                .and_then(|v| v.parse::<f32>().ok())
                .unwrap_or(1.0);
            let visible = parse_xml_attr(tag, "visibility")
                .map(|v| !v.eq_ignore_ascii_case("hidden"))
                .unwrap_or(true);
            let blend_mode = parse_xml_attr(tag, "composite-op")
                .map(|v| BlendMode::from_ora_name(&v))
                .unwrap_or(BlendMode::Normal);
            out.push(ParsedLayer {
                name,
                src,
                x,
                y,
                opacity,
                visible,
                blend_mode,
            });
        }
        cursor = &after[end + 1..];
    }
    out
}
