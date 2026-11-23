//! The Editor: a working document, the operations applied to it and the pixels
//! those operations produce.
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
//! without copying the whole buffer. This crate owns pixels and history only;
//! file paths, the command gateway and UI state stay in Core.
//!
//! It is a crate of its own because the file said so: the Editor's `editor.rs`
//! passed 3,000 lines, and the boundary that had been inside that one module —
//! a document and its history on one side, the pixels an operation renders on
//! the other — is a module boundary here. `kogaview-core` re-exports this crate
//! as `kogaview_core::editor`, so no caller changed. An edit travels through
//! `operation` (what it is), `validate` (why it is refused), `pixels` and
//! `codec` (the arithmetic), `render` (applying it), `document` (recording it)
//! and `tasks` (the parts too slow for the UI thread).

mod codec;
mod document;
mod operation;
mod pixels;
mod render;
mod tasks;
mod validate;

#[cfg(test)]
mod tests;

// The Editor's vocabulary is public: Core validates with the same functions it
// applies with, and the batch worker renders with the same branch a single edit
// does. A narrower API would only make Core re-implement checks. `pixels` is the
// exception — the arithmetic is reached through the modules that use it, and
// nothing outside this crate calls `resample` or `cover_rect` directly.
pub use codec::*;
pub use document::*;
pub use operation::EditOperation;
pub(crate) use pixels::*;
pub use render::*;
pub use tasks::*;
pub use validate::*;

/// Refuse documents larger than this; a full RGBA buffer at 80 MP is already
/// 320 MB and this slice has no tiling, so a bigger image would risk the app
/// instead of editing it. The message says so rather than failing silently.
pub const MAX_DOCUMENT_PIXELS: u64 = 80_000_000;

/// Longest edge of the PNG handed to QML. The document keeps full resolution;
/// the preview exists so each edit renders in a frame, not a second.
pub const PREVIEW_LONG_EDGE: u32 = 2048;
