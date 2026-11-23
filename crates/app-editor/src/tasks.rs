//! The slow parts, run on a worker thread: decoding a file into a document,
//! rendering a preview, rendering the draft of an uncommitted edit. Each one
//! sends its result down a channel for Core's poll loop to consume.

use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::sync::Arc;

use image::RgbaImage;

use crate::*;

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
