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

mod document;
mod operation;
mod render;
mod tasks;
mod validate;

#[cfg(test)]
mod tests;

pub use kogaview_image::codec::*;
pub use kogaview_image::layer::*;
pub use kogaview_image::ora::{
    extract_archive_preview_png, has_archive_decoder, is_archive_image_path, is_kra_path,
    is_ora_path, read_ora, read_zip_dimensions, read_zip_merged_image, write_ora,
};
pub(crate) use kogaview_image::pixels::*;
pub use kogaview_image::selection::SelectionMask;
pub use kogaview_image::{
    codec, layer, ora, pixels, selection, MAX_DOCUMENT_PIXELS, PREVIEW_LONG_EDGE,
};

pub use document::*;
pub use operation::EditOperation;
pub use render::*;
pub use tasks::*;
pub use validate::*;
