//! The suites for the gateway, one file per area.
//!
//! They share the fixtures below — a temp directory, a folder scan, a save
//! settle, a command helper and the JPEG writer — so those live here and each
//! area module starts with `use super::*;`. The cases themselves sit with the
//! module they drive: `browsing`, `viewing`, `editing`, `gateway` and `jobs`.

use super::*;
use std::sync::atomic::{AtomicU32, Ordering};

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "kogaview-core-test-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Remove a test directory, retrying while a worker still holds a file in it.
///
/// The Editor renders previews into `<base>/cache/editor` on a worker
/// thread, so a `remove_dir_all` can meet a write that lands between its
/// enumeration and its last unlink — the call then answers "Directory not
/// empty" and the test fails on teardown, not on behaviour. Retrying is the
/// honest fix: nothing here asserts on how fast a preview is written.
fn remove_tree(path: &Path) {
    for _ in 0..50 {
        match std::fs::remove_dir_all(path) {
            Ok(()) => return,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(20)),
        }
    }
    let _ = std::fs::remove_dir_all(path);
}

/// Wait for the background folder scan to land, the way the UI's poll timer
/// does. Returns false if it never does.
fn settle_scan(core: &mut Core) -> bool {
    for _ in 0..2000 {
        if core.poll() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

/// Wait for a batch worker to publish its final line.
fn settle_batch(core: &mut Core) -> bool {
    for _ in 0..4000 {
        core.poll();
        if matches!(&core.state.batch, Some(batch) if !batch.running) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

fn select_json(path: &Path) -> String {
    format!(
        r#"{{"id":"select-1","protocol":1,"command":{{"type":"select","paths":["{}"]}}}}"#,
        path.display()
    )
}

/// Wait for a save worker to report back, the way the UI's poll timer does.
fn settle_save(core: &mut Core) -> bool {
    for _ in 0..3000 {
        core.poll();
        if !core.editor_saving() {
            return core
                .state
                .editor
                .as_ref()
                .is_some_and(|editor| editor.saved);
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

fn dispatch_json(core: &mut Core, id: &str, command: &str) -> serde_json::Value {
    serde_json::from_str(&core.dispatch(&editor_envelope(id, command))).unwrap()
}

/// Wait for an export worker to finish writing `path`.
fn settle_export(core: &mut Core, path: &Path) -> bool {
    for _ in 0..4000 {
        core.poll();
        if !core.editor_saving() && path.is_file() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

/// A JPEG whose entropy-coded data changes with the quality setting, with
/// an EXIF APP1 segment a reader can look for after an export.
fn write_jpeg_with_exif(path: &Path, width: u32, height: u32) {
    let image = image::RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([
            ((x * 37 + y * 11) % 256) as u8,
            ((x * 13 + y * 29) % 256) as u8,
            ((x * x + y * y) % 256) as u8,
            255,
        ])
    });
    let encoded = editor::encode_with(&image, editor::SaveFormat::Jpeg, Some(95)).unwrap();
    let exif = b"Exif\0\0KogaViewExportTest";
    let icc = b"ICC_PROFILE\0KogaViewIccTest";
    let mut bytes = encoded[..2].to_vec();
    for (marker, payload) in [(0xE1u8, exif.as_slice()), (0xE2, icc.as_slice())] {
        let length = (payload.len() + 2) as u16;
        bytes.extend_from_slice(&[0xFF, marker, (length >> 8) as u8, length as u8]);
        bytes.extend_from_slice(payload);
    }
    bytes.extend_from_slice(&encoded[2..]);
    std::fs::write(path, bytes).unwrap();
}

fn settle_editor(core: &mut Core) -> bool {
    for _ in 0..3000 {
        core.poll();
        match &core.state.editor {
            Some(editor) if editor.width > 0 && !editor.rendering => return true,
            _ => {}
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

/// Wait for a live-preview draft to land. `settle_editor` cannot stand in
/// for this: the document is not rendering, so it returns before the draft
/// worker has answered.
fn settle_draft(core: &mut Core) -> bool {
    for _ in 0..3000 {
        core.poll();
        if let Some(editor) = &core.state.editor {
            if editor.preview_draft.is_some() {
                return true;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

fn write_png(path: &Path, width: u32, height: u32) {
    let image = image::RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([(x % 251) as u8, (y % 251) as u8, 90, 255])
    });
    image::DynamicImage::ImageRgba8(image)
        .save_with_format(path, image::ImageFormat::Png)
        .unwrap();
}

fn editor_envelope(id: &str, command: &str) -> String {
    format!(r#"{{"id":"{id}","protocol":1,"command":{command}}}"#)
}

mod browsing;
mod editing;
mod gateway;
mod jobs;
mod viewing;
