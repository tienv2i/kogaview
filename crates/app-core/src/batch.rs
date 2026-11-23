//! The batch engine: one typed operation over a list of files.
//!
//! A batch is a job, not a stream of per-file commands. The three operations
//! (`resize`, `crop`, `convert`) share the input list, the output policy, the
//! progress counter and the cancellation flag, and the UI needs all four to be
//! one thing: "12 of 40" is only honest when one worker owns the count, and
//! Cancel must stop the *job*, not whichever file happens to be next.
//!
//! The worker is one thread and one image at a time, so memory is bounded by
//! the Editor's own `MAX_DOCUMENT_PIXELS` limit; the job is bounded by
//! [`MAX_BATCH_FILES`]; the cancellation flag is checked between files, so a
//! file that is already being encoded finishes rather than leaving half a
//! picture behind (writes are atomic).
//!
//! This module owns paths and pixels only. The command gateway builds the plan,
//! publishes progress and turns the final line into a `UiText`.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;

use kogaview_protocol::{BatchOperation, BatchOutput, ProtocolError};

use crate::editor::{self, EditOperation, SaveFormat};
use crate::ops;
use crate::state::UiText;

/// Refuse a job with more files than this.
///
/// The bound is about the window, not the disk: progress is one state
/// publication per file, and a selection of ten thousand pictures would spend
/// more time redrawing a count than encoding. A larger job is still possible by
/// running it in parts, and the refusal names the limit.
pub const MAX_BATCH_FILES: usize = 500;

/// One batch, validated and paired with its destinations.
#[derive(Debug)]
pub struct BatchPlan {
    operation: BatchOperation,
    inputs: Vec<PathBuf>,
    outputs: Vec<PathBuf>,
}

/// What the worker has finished so far, sent after each file.
#[derive(Debug, Clone)]
pub struct BatchProgress {
    pub done: usize,
    pub failed: usize,
    /// The file about to be written, for the panel's "now" line.
    pub current: String,
}

/// The end of a job. `message` is the status-bar line, as a code.
#[derive(Debug, Clone)]
pub struct BatchFinished {
    pub done: usize,
    pub failed: usize,
    pub cancelled: bool,
    pub refresh: bool,
    pub message: UiText,
}

/// Everything the worker tells Core.
#[derive(Debug, Clone)]
pub enum BatchEvent {
    Progress(BatchProgress),
    Finished(BatchFinished),
}

impl BatchPlan {
    /// Validate the operation and the output policy, then pair every input with
    /// the file it will write.
    ///
    /// Every refusal here is a whole-job refusal: a bad crop rectangle or a
    /// policy that would overwrite the sources is the same for all inputs, so
    /// failing per file would only hide it N times.
    pub fn build(
        operation: BatchOperation,
        inputs: Vec<PathBuf>,
        output: BatchOutput,
    ) -> Result<Self, ProtocolError> {
        if inputs.is_empty() {
            return Err(ProtocolError::line(
                "no_images",
                UiText::new("batch_no_images"),
            ));
        }
        if inputs.len() > MAX_BATCH_FILES {
            return Err(ProtocolError::line(
                "too_many_files",
                UiText::with("batch_too_many", [MAX_BATCH_FILES.to_string()]),
            ));
        }
        validate_operation(&operation)?;
        validate_policy(&operation, &inputs, &output)?;

        let mut outputs = Vec::with_capacity(inputs.len());
        for source in &inputs {
            outputs.push(destination(source, &operation, &output)?);
        }

        // Two inputs can share a stem (a folder of `a.png` and `a.jpg`), and a
        // suffix-less job would then write one result twice. Refuse rather than
        // let the second file silently replace the first.
        let mut seen = HashSet::new();
        for path in &outputs {
            if !seen.insert(path.clone()) {
                return Err(ProtocolError::line(
                    "duplicate_output",
                    UiText::with("batch_duplicate_output", [path.display().to_string()]),
                ));
            }
        }

        Ok(Self {
            operation,
            inputs,
            outputs,
        })
    }

    pub fn total(&self) -> usize {
        self.inputs.len()
    }

    /// Start the worker. Progress and the final line arrive on `sender`; Core
    /// polls that channel from `poll()`.
    pub fn spawn(self, cancel: Arc<AtomicBool>, sender: Sender<BatchEvent>) {
        std::thread::spawn(move || self.run(&cancel, &sender));
    }

    fn run(self, cancel: &AtomicBool, sender: &Sender<BatchEvent>) {
        let total = self.inputs.len();
        let mut done = 0;
        let mut failed = 0;

        for (source, destination) in self.inputs.iter().zip(&self.outputs) {
            if cancel.load(Ordering::SeqCst) {
                break;
            }
            let current = source
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| source.to_string_lossy().into_owned());
            let _ = sender.send(BatchEvent::Progress(BatchProgress {
                done,
                failed,
                current: current.clone(),
            }));
            match process(source, destination, &self.operation) {
                Ok(()) => {
                    done += 1;
                    tracing::debug!(
                        target: "kogaview::batch",
                        source = %source.display(),
                        destination = %destination.display(),
                        operation = self.operation.name(),
                        "batch file written"
                    );
                }
                Err(error) => {
                    failed += 1;
                    tracing::warn!(
                        target: "kogaview::batch",
                        source = %source.display(),
                        operation = self.operation.name(),
                        %error,
                        "batch file failed"
                    );
                }
            }
        }

        // A cancel that arrived after the last file changed nothing: the job
        // finished, so it is reported as finished rather than as cancelled.
        let cancelled = cancel.load(Ordering::SeqCst) && done + failed < total;
        let message = if cancelled {
            UiText::with("batch_cancelled", [done.to_string(), total.to_string()])
        } else if failed > 0 {
            UiText::with(
                "batch_done_failed",
                [done.to_string(), total.to_string(), failed.to_string()],
            )
        } else {
            UiText::with("batch_done", [done.to_string(), total.to_string()])
        };
        let _ = sender.send(BatchEvent::Finished(BatchFinished {
            done,
            failed,
            cancelled,
            refresh: done > 0,
            message,
        }));
    }
}

/// Apply one operation to one file and write the result.
fn process(source: &Path, destination: &Path, operation: &BatchOperation) -> Result<(), String> {
    let image = editor::decode_rgba(source)?;
    let (pixels, quality) = match operation {
        BatchOperation::Resize {
            width,
            height,
            mode,
            filter,
            fill,
            fill_alpha,
        } => {
            // The Editor's own renderer: a batch resize must not grow a second
            // definition of `cover`/`pad`, or the two surfaces would disagree
            // about what the same words mean.
            let edit = EditOperation::Resize {
                width: *width,
                height: *height,
                fill: *fill,
                fill_alpha: *fill_alpha,
                mode: *mode,
                filter: *filter,
            };
            (
                editor::render_operation(&image, &edit).map_err(|line| line.english())?,
                None,
            )
        }
        BatchOperation::Crop {
            x,
            y,
            width,
            height,
            unit,
            anchor,
            ratio,
        } => {
            let rect = crop_rect_full(
                image.width(),
                image.height(),
                *x,
                *y,
                *width,
                *height,
                unit,
                anchor.as_deref(),
                *ratio,
            );
            let edit = EditOperation::Crop {
                x: rect.0 as i32,
                y: rect.1 as i32,
                width: rect.2,
                height: rect.3,
                fill: None,
                fill_alpha: 255,
            };
            (
                editor::render_operation(&image, &edit).map_err(|line| line.english())?,
                None,
            )
        }
        BatchOperation::Convert { quality, .. } => (image, *quality),
    };
    editor::save_pixels_with(source, &pixels, destination, quality)
}

/// The rectangle a proportional crop describes on one image.
///
/// The percentages are of that image's own sides, which is the whole reason the
/// command carries fractions: one job must trim the same relative area from a
/// 4000 × 3000 photo and a 800 × 800 icon. Rounding can land a pixel outside
/// the frame, so the right and bottom edges are clamped rather than trusted;
/// a zero-sized side can never reach the renderer.
fn anchor_offset(container: u32, size: u32, pos: &str) -> u32 {
    let slack = container.saturating_sub(size);
    match pos {
        "start" => 0,
        "end" => slack,
        _ => slack / 2,
    }
}

fn crop_rect_full(
    image_width: u32,
    image_height: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    unit: &str,
    anchor: Option<&str>,
    ratio: Option<f64>,
) -> (u32, u32, u32, u32) {
    let is_pixels = unit == "pixels";
    let to_px = |value: f64, length: u32| -> u32 {
        if is_pixels {
            value.round().clamp(0.0, f64::from(length)) as u32
        } else {
            (f64::from(length) * value / 100.0)
                .round()
                .clamp(0.0, f64::from(length)) as u32
        }
    };

    let (crop_w, crop_h) = if let Some(aspect) = ratio.filter(|r| r.is_finite() && *r > 0.0) {
        let max_w = if width > 0.0 {
            to_px(width, image_width).max(1).min(image_width)
        } else {
            image_width
        };
        let max_h = if height > 0.0 {
            to_px(height, image_height).max(1).min(image_height)
        } else {
            image_height
        };
        let box_w = f64::from(max_w);
        let box_h = f64::from(max_h);
        if box_w / box_h > aspect {
            let w = (box_h * aspect).round().clamp(1.0, box_w) as u32;
            (w, max_h)
        } else {
            let h = (box_w / aspect).round().clamp(1.0, box_h) as u32;
            (max_w, h)
        }
    } else {
        (
            to_px(width, image_width).max(1).min(image_width),
            to_px(height, image_height).max(1).min(image_height),
        )
    };

    if let Some(a) = anchor {
        let h_pos = match a {
            "top_left" | "left" | "bottom_left" => "start",
            "top_right" | "right" | "bottom_right" => "end",
            _ => "center",
        };
        let v_pos = match a {
            "top_left" | "top" | "top_right" => "start",
            "bottom_left" | "bottom" | "bottom_right" => "end",
            _ => "center",
        };
        let left = anchor_offset(image_width, crop_w, h_pos);
        let top = anchor_offset(image_height, crop_h, v_pos);
        return (left, top, crop_w, crop_h);
    }

    let left = to_px(x, image_width).min(image_width.saturating_sub(1));
    let top = to_px(y, image_height).min(image_height.saturating_sub(1));
    let right = (left + crop_w).min(image_width);
    let bottom = (top + crop_h).min(image_height);
    (left, top, (right - left).max(1), (bottom - top).max(1))
}

#[cfg(test)]
fn crop_rect(
    image_width: u32,
    image_height: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> (u32, u32, u32, u32) {
    crop_rect_full(
        image_width,
        image_height,
        x,
        y,
        width,
        height,
        "percent",
        None,
        None,
    )
}

/// The format a resize or a crop keeps, or the one a convert names.
fn output_format(source: &Path, operation: &BatchOperation) -> Result<String, ProtocolError> {
    match operation {
        BatchOperation::Convert { format, .. } => Ok(format.extension().to_owned()),
        _ => source
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .ok_or_else(|| {
                ProtocolError::line(
                    "missing_extension",
                    UiText::with("batch_bad_name", [source.display().to_string()]),
                )
            }),
    }
}

/// Where one input is written.
fn destination(
    source: &Path,
    operation: &BatchOperation,
    output: &BatchOutput,
) -> Result<PathBuf, ProtocolError> {
    if output.overwrite {
        // The extension cannot change with the bytes: `photo.png` holding JPEG
        // data would be a file that lies about itself, so a convert that
        // replaces the original must already target its format.
        if let BatchOperation::Convert { format, .. } = operation {
            let wanted = SaveFormat::from_image_format(*format);
            if SaveFormat::from_path(source) != Some(wanted) {
                return Err(ProtocolError::line(
                    "convert_overwrite",
                    UiText::with("batch_convert_overwrite", [source.display().to_string()]),
                ));
            }
        }
        return Ok(source.to_path_buf());
    }

    let folder = match &output.folder {
        Some(folder) => ops::normalize_path(Path::new(folder)),
        None => source
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from(".")),
    };
    let stem = source
        .file_stem()
        .and_then(|stem| stem.to_str())
        .ok_or_else(|| {
            ProtocolError::line(
                "missing_name",
                UiText::with("batch_bad_name", [source.display().to_string()]),
            )
        })?;
    let extension = output_format(source, operation)?;
    let name = format!("{stem}{}.{extension}", output.suffix);
    let path = folder.join(name);
    if path == source {
        // The default policy must never become a silent overwrite just because
        // the suffix was left empty and the format did not change.
        return Err(ProtocolError::line(
            "output_is_source",
            UiText::with("batch_output_is_source", [source.display().to_string()]),
        ));
    }
    Ok(path)
}

/// Refuse a job whose operation cannot mean anything, before it touches a file.
fn validate_operation(operation: &BatchOperation) -> Result<(), ProtocolError> {
    match operation {
        BatchOperation::Resize {
            width,
            height,
            mode,
            fill,
            ..
        } => {
            editor::validate_resize(*width, *height)
                .map_err(|line| ProtocolError::line("invalid_resize", line))?;
            editor::validate_resize_mode(*mode, *fill)
                .map_err(|line| ProtocolError::line("invalid_resize", line))?;
            Ok(())
        }
        BatchOperation::Crop {
            x,
            y,
            width,
            height,
            unit,
            anchor,
            ratio,
        } => {
            let (x, y, width, height) = (*x, *y, *width, *height);
            let ratio = *ratio;
            const VALID_ANCHORS: &[&str] = &[
                "top_left",
                "top",
                "top_right",
                "left",
                "center",
                "right",
                "bottom_left",
                "bottom",
                "bottom_right",
            ];
            let valid_unit = unit == "percent" || unit == "pixels";
            let valid_anchor = anchor.as_deref().is_none_or(|a| VALID_ANCHORS.contains(&a));
            let valid_ratio = ratio.is_none_or(|r| r.is_finite() && r > 0.0);
            let finite = [x, y, width, height].iter().all(|value| value.is_finite());
            if !valid_unit || !valid_anchor || !valid_ratio || !finite {
                return Err(ProtocolError::line(
                    "invalid_crop",
                    UiText::new("batch_crop_outside"),
                ));
            }
            let is_pixels = unit == "pixels";
            let has_anchor = anchor.is_some();
            if ratio.is_some() {
                let valid_bounds = if is_pixels {
                    width >= 0.0 && height >= 0.0 && (has_anchor || (x >= 0.0 && y >= 0.0))
                } else {
                    width >= 0.0
                        && height >= 0.0
                        && width <= 100.05
                        && height <= 100.05
                        && (has_anchor || (x >= -0.05 && y >= -0.05 && x < 100.0 && y < 100.0))
                };
                if !valid_bounds {
                    return Err(ProtocolError::line(
                        "invalid_crop",
                        UiText::new("batch_crop_outside"),
                    ));
                }
                return Ok(());
            }
            if is_pixels {
                if width < 1.0 || height < 1.0 || (!has_anchor && (x < 0.0 || y < 0.0)) {
                    return Err(ProtocolError::line(
                        "invalid_crop",
                        UiText::new("batch_crop_outside"),
                    ));
                }
                return Ok(());
            }
            // Percent mode without ratio.
            // A tenth of a percent of slack: the form's fields carry two
            // decimals, and 100.0 must stay reachable after a round trip.
            let inside = if has_anchor {
                width > 0.0 && height > 0.0 && width <= 100.05 && height <= 100.05
            } else {
                x >= -0.05
                    && y >= -0.05
                    && width > 0.0
                    && height > 0.0
                    && x + width <= 100.05
                    && y + height <= 100.05
            };
            if !inside {
                return Err(ProtocolError::line(
                    "invalid_crop",
                    UiText::new("batch_crop_outside"),
                ));
            }
            if (has_anchor || (x.abs() < f64::EPSILON && y.abs() < f64::EPSILON))
                && (width - 100.0).abs() < f64::EPSILON
                && (height - 100.0).abs() < f64::EPSILON
            {
                return Err(ProtocolError::line(
                    "crop_noop",
                    UiText::new("batch_crop_noop"),
                ));
            }
            Ok(())
        }
        BatchOperation::Convert { format, quality } => {
            if quality.is_some_and(|quality| quality == 0 || quality > 100) {
                return Err(ProtocolError::line(
                    "invalid_quality",
                    UiText::with("batch_bad_quality", [format.label()]),
                ));
            }
            Ok(())
        }
    }
}

/// Refuse an output policy that cannot be honoured.
fn validate_policy(
    operation: &BatchOperation,
    inputs: &[PathBuf],
    output: &BatchOutput,
) -> Result<(), ProtocolError> {
    if output.suffix.contains('/') || output.suffix.contains('\\') || output.suffix.contains('\0') {
        return Err(ProtocolError::line(
            "invalid_suffix",
            UiText::new("batch_bad_suffix"),
        ));
    }
    if output.overwrite && output.folder.is_some() {
        return Err(ProtocolError::line(
            "overwrite_with_folder",
            UiText::new("batch_overwrite_with_folder"),
        ));
    }
    if let Some(folder) = &output.folder {
        let folder = ops::normalize_path(Path::new(folder));
        if !folder.is_dir() {
            return Err(ProtocolError::line(
                "missing_folder",
                UiText::with("batch_output_missing", [folder.display().to_string()]),
            ));
        }
    }
    if output.overwrite {
        // `destination` checks this per file too; doing it once here keeps a
        // mixed selection from failing halfway through the batch.
        if let BatchOperation::Convert { format, .. } = operation {
            let wanted = SaveFormat::from_image_format(*format);
            if let Some(source) = inputs
                .iter()
                .find(|source| SaveFormat::from_path(source) != Some(wanted))
            {
                return Err(ProtocolError::line(
                    "convert_overwrite",
                    UiText::with("batch_convert_overwrite", [source.display().to_string()]),
                ));
            }
        }
    }
    Ok(())
}

/// True when `path` is an image this build can decode and the Editor may open.
pub fn is_batchable(path: &Path) -> bool {
    path.is_file() && ops::is_image_path(path) && editor::has_decoder(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_proportional_crop_is_relative_to_each_image() {
        // The same fractions trim the same relative area from different sizes.
        assert_eq!(crop_rect(100, 50, 10.0, 10.0, 80.0, 80.0), (10, 5, 80, 40));
        assert_eq!(
            crop_rect(1000, 800, 10.0, 10.0, 80.0, 80.0),
            (100, 80, 800, 640)
        );
        // The identity keeps everything.
        assert_eq!(crop_rect(64, 32, 0.0, 0.0, 100.0, 100.0), (0, 0, 64, 32));
    }

    #[test]
    fn rounding_can_never_leave_the_frame_or_reach_zero() {
        let (x, y, width, height) = crop_rect(3, 3, 99.9, 99.9, 100.0, 100.0);
        assert!(x < 3 && y < 3, "a crop starts inside the picture");
        assert!(width >= 1 && height >= 1, "a crop keeps at least one pixel");
        assert!(x + width <= 3 && y + height <= 3, "a crop stays inside");
    }

    #[test]
    fn anchor_crop_places_rectangle_at_requested_corner_or_center() {
        assert_eq!(
            crop_rect_full(
                1000,
                800,
                0.0,
                0.0,
                50.0,
                50.0,
                "percent",
                Some("center"),
                None
            ),
            (250, 200, 500, 400)
        );
        assert_eq!(
            crop_rect_full(
                1000,
                800,
                0.0,
                0.0,
                50.0,
                50.0,
                "percent",
                Some("bottom_right"),
                None
            ),
            (500, 400, 500, 400)
        );
        assert_eq!(
            crop_rect_full(
                1000,
                800,
                0.0,
                0.0,
                400.0,
                300.0,
                "pixels",
                Some("top_right"),
                None
            ),
            (600, 0, 400, 300)
        );
        // Oversized pixel crop clamps cleanly to the image.
        assert_eq!(
            crop_rect_full(
                200,
                150,
                0.0,
                0.0,
                400.0,
                300.0,
                "pixels",
                Some("center"),
                None
            ),
            (0, 0, 200, 150)
        );
    }

    #[test]
    fn ratio_crop_fits_largest_aspect_rectangle_inside_bounds() {
        // 1:1 on landscape 1000x600 centered -> 600x600 at (200, 0)
        assert_eq!(
            crop_rect_full(
                1000,
                600,
                0.0,
                0.0,
                100.0,
                100.0,
                "percent",
                Some("center"),
                Some(1.0)
            ),
            (200, 0, 600, 600)
        );
        // 1:1 on portrait 600x1000 anchored top -> 600x600 at (0, 0)
        assert_eq!(
            crop_rect_full(
                600,
                1000,
                0.0,
                0.0,
                0.0,
                0.0,
                "percent",
                Some("top"),
                Some(1.0)
            ),
            (0, 0, 600, 600)
        );
        // 16:9 inside 800px width cap on 1600x1200 -> 800x450 centered
        assert_eq!(
            crop_rect_full(
                1600,
                1200,
                0.0,
                0.0,
                800.0,
                0.0,
                "pixels",
                Some("center"),
                Some(16.0 / 9.0)
            ),
            (400, 375, 800, 450)
        );
    }

    #[test]
    fn validation_accepts_ratio_and_pixel_crops_and_refuses_anchor_noop() {
        assert!(validate_operation(&BatchOperation::Crop {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
            unit: "percent".to_owned(),
            anchor: Some("center".to_owned()),
            ratio: Some(1.0),
        })
        .is_ok());
        assert!(validate_operation(&BatchOperation::Crop {
            x: 0.0,
            y: 0.0,
            width: 500.0,
            height: 500.0,
            unit: "pixels".to_owned(),
            anchor: Some("center".to_owned()),
            ratio: None,
        })
        .is_ok());
        let err = validate_operation(&BatchOperation::Crop {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
            unit: "percent".to_owned(),
            anchor: Some("center".to_owned()),
            ratio: None,
        })
        .unwrap_err();
        assert_eq!(err.code, "crop_noop");
    }

    #[test]
    fn a_suffix_cannot_name_another_folder() {
        let output = BatchOutput {
            folder: None,
            suffix: "/evil".into(),
            overwrite: false,
        };
        let error = BatchPlan::build(
            BatchOperation::Crop {
                x: 0.0,
                y: 0.0,
                width: 50.0,
                height: 50.0,
                unit: "percent".to_owned(),
                anchor: None,
                ratio: None,
            },
            vec![PathBuf::from("/pics/a.png")],
            output,
        )
        .unwrap_err();
        assert_eq!(error.code, "invalid_suffix");
    }

    #[test]
    fn an_empty_suffix_beside_the_source_is_refused_instead_of_overwriting_it() {
        let error = BatchPlan::build(
            BatchOperation::Crop {
                x: 0.0,
                y: 0.0,
                width: 50.0,
                height: 50.0,
                unit: "percent".to_owned(),
                anchor: None,
                ratio: None,
            },
            vec![PathBuf::from("/pics/a.png")],
            BatchOutput::default(),
        )
        .unwrap_err();
        assert_eq!(error.code, "output_is_source");
    }

    #[test]
    fn a_cancelled_job_writes_nothing_and_says_so() {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-batch-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("photo.png");
        image::RgbaImage::from_pixel(16, 8, image::Rgba([20, 40, 60, 255]))
            .save(&source)
            .unwrap();

        let plan = BatchPlan::build(
            BatchOperation::Resize {
                width: 8,
                height: 4,
                mode: kogaview_protocol::ResizeMode::Stretch,
                filter: kogaview_protocol::ResizeFilter::Auto,
                fill: None,
                fill_alpha: 255,
            },
            vec![source.clone()],
            BatchOutput {
                folder: None,
                suffix: "_small".into(),
                overwrite: false,
            },
        )
        .unwrap();
        let cancel = Arc::new(AtomicBool::new(true));
        let (sender, receiver) = std::sync::mpsc::channel();
        plan.spawn(cancel, sender);
        let event = receiver.recv().unwrap();
        match event {
            BatchEvent::Finished(finished) => {
                assert_eq!(finished.done, 0);
                assert!(finished.cancelled);
                assert_eq!(finished.message.code, "batch_cancelled");
                assert!(!finished.refresh, "a cancelled job changed nothing");
            }
            other => panic!("a cancelled job reported {other:?}"),
        }
        assert!(!dir.join("photo_small.png").exists());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
