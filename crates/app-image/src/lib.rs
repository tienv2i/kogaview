//! Pure raster image engine: codecs, multi-layer compositing, OpenRaster/Krita
//! archives, selection masks, and pixel-level filters/brush/gradient/liquify.
//!
//! Nothing in this crate knows about documents, undo history, or UI state.

pub mod codec;
pub mod layer;
pub mod ora;
pub mod pixels;
pub mod selection;

pub use codec::*;
pub use layer::*;
pub use ora::{
    extract_archive_preview_png, has_archive_decoder, is_archive_image_path, is_kra_path,
    is_ora_path, read_ora, read_zip_dimensions, read_zip_merged_image, write_ora,
};
pub use pixels::*;
pub use selection::SelectionMask;

/// Refuse documents larger than this; a full RGBA buffer at 80 MP is already
/// 320 MB and this slice has no tiling, so a bigger image would risk the app
/// instead of editing it. The message says so rather than failing silently.
pub const MAX_DOCUMENT_PIXELS: u64 = 80_000_000;

/// Longest edge of the PNG handed to QML. The document keeps full resolution;
/// the preview exists so each edit renders in a frame, not a second.
pub const PREVIEW_LONG_EDGE: u32 = 2048;
