//! The working document: its pixels, the history of the edits applied to them
//! and the file they came from.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use image::RgbaImage;
use kogaview_protocol::UiText;

use crate::*;

/// Keep the undo stack shallow and the pixel snapshots it holds bounded.
pub(crate) const MAX_HISTORY_STEPS: usize = 12;
pub(crate) const MAX_SNAPSHOT_BYTES: u64 = 160 * 1024 * 1024;

/// How a step is undone. `Invert` re-applies an operation that is its own
/// inverse (flip) or the exact opposite rotation; `Snapshot` restores pixels.
pub(crate) enum Undo {
    Invert(EditOperation),
    Snapshot(Arc<RgbaImage>),
}

pub(crate) struct Step {
    operation: EditOperation,
    undo: Undo,
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
                Ok(*x == 0 && *y == 0 && *w == width && *h == height && rot_zero)
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
            EditOperation::Transform { .. }
            | EditOperation::FreeTransform { .. }
            | EditOperation::CanvasSize { .. }
            | EditOperation::RotateAngle { .. }
            | EditOperation::AdjustColor { .. } => Undo::Snapshot(before),
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
