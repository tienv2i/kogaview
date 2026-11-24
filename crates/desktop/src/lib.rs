//! Qt adapter: exposes a read-only view of Core identity plus a temporary
//! bridge probe used to prove the CXX-Qt property/invokable path in M0.
//!
//! The real state bridge, command submission and event observation arrive in
//! M1. QML must never mutate domain state directly.
//!
//! CXX-Qt generates camelCase `connect_*Changed` helpers for QML properties,
//! so allow that naming convention crate-wide.

#![allow(non_snake_case)]

pub mod bridge;

pub use bridge::*;

/// Extract the preview PNG (`mergedimage.png` / `preview.png`) from a `.ora` or
/// `.kra` archive for Qt's `ThumbnailCache`, `PlatformHelper`, and Viewer
/// `QQuickImageProvider`. Caller frees `out_ptr` with [`kogaview_free_buffer`].
#[no_mangle]
pub unsafe extern "C" fn kogaview_extract_archive_preview(
    path: *const std::ffi::c_char,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> bool {
    if path.is_null() || out_ptr.is_null() || out_len.is_null() {
        return false;
    }
    let Ok(cstr) = std::ffi::CStr::from_ptr(path).to_str() else {
        return false;
    };
    let Ok(bytes) = kogaview_core::editor::extract_archive_preview_png(std::path::Path::new(cstr))
    else {
        return false;
    };
    let mut boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    *out_ptr = ptr;
    *out_len = len;
    true
}

/// Free a buffer previously returned by [`kogaview_extract_archive_preview`] or
/// [`kogaview_copy_editor_frame`].
#[no_mangle]
pub unsafe extern "C" fn kogaview_free_buffer(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    }
}

/// Copy raw RGBA8888 bytes for an in-RAM Editor preview frame
/// (`"canvas"`, `"active"`, `"below"`, `"above"`, `"selection"`).
/// Caller frees `out_ptr` with [`kogaview_free_buffer`] using `(*out_w as usize) * (*out_h as usize) * 4`.
#[no_mangle]
pub unsafe extern "C" fn kogaview_copy_editor_frame(
    kind: *const std::ffi::c_char,
    out_ptr: *mut *mut u8,
    out_w: *mut u32,
    out_h: *mut u32,
) -> bool {
    if kind.is_null() || out_ptr.is_null() || out_w.is_null() || out_h.is_null() {
        return false;
    }
    let Ok(kind_str) = std::ffi::CStr::from_ptr(kind).to_str() else {
        return false;
    };
    let Some((bytes, w, h)) = kogaview_core::ram_preview::copy_frame(kind_str) else {
        return false;
    };
    let mut boxed = bytes.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    *out_ptr = ptr;
    *out_w = w;
    *out_h = h;
    true
}

/// Sample RGB at normalized `(norm_x, norm_y)` directly from the in-RAM Editor canvas.
#[no_mangle]
pub unsafe extern "C" fn kogaview_sample_editor_canvas(
    norm_x: f64,
    norm_y: f64,
    out_r: *mut u8,
    out_g: *mut u8,
    out_b: *mut u8,
) -> bool {
    if out_r.is_null() || out_g.is_null() || out_b.is_null() {
        return false;
    }
    let Some([r, g, b]) = kogaview_core::ram_preview::sample_canvas(norm_x, norm_y) else {
        return false;
    };
    *out_r = r;
    *out_g = g;
    *out_b = b;
    true
}
