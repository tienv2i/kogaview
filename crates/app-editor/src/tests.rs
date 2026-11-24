//! The suites for this crate. They are one file because they share the fixture
//! helpers at the top: a temp directory, a deterministic pixel pattern and the
//! two JPEG writers the preview tests need a real encoder for.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use image::imageops;
use image::{DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, RgbaImage};
use kogaview_protocol::{FlipAxis, ResizeFilter, ResizeMode, UiText};

use crate::*;
use std::sync::atomic::{AtomicU32, Ordering};

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "kogaview-editor-test-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A deterministic pattern: pixel (x, y) is (x*8, y*8, x+y, 255).
fn pattern(width: u32, height: u32) -> RgbaImage {
    RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([
            (x * 8 % 256) as u8,
            (y * 8 % 256) as u8,
            ((x + y) % 256) as u8,
            255,
        ])
    })
}

fn source_file(dir: &Path, name: &str, width: u32, height: u32) -> PathBuf {
    let path = dir.join(name);
    DynamicImage::ImageRgba8(pattern(width, height))
        .save_with_format(&path, ImageFormat::Png)
        .unwrap();
    path
}

/// A JPEG larger than one DCT halving of the preview edge, so the scaled
/// decode has a scale to choose (1/2 must still cover 2048 px).
fn wide_jpeg(dir: &Path, name: &str, width: u32, height: u32) -> PathBuf {
    let path = dir.join(name);
    let image = pattern(width, height);
    let bytes = encode_with(&image, SaveFormat::Jpeg, Some(92)).unwrap();
    std::fs::write(&path, bytes).unwrap();
    path
}

fn mean_absolute_difference(left: &RgbaImage, right: &RgbaImage) -> f64 {
    assert_eq!(left.dimensions(), right.dimensions());
    let mut total: u64 = 0;
    for (a, b) in left.pixels().zip(right.pixels()) {
        for channel in 0..3 {
            total += u64::from(a.0[channel].abs_diff(b.0[channel]));
        }
    }
    total as f64 / (left.pixels().len() * 3) as f64
}

/// A photograph-like frame: smooth gradients plus a low-frequency
/// undulation. `pattern` above is deliberately high frequency, which is the
/// worst case for a decoder that keeps only the low DCT bands; a preview's
/// job is to look like the picture, so it is judged on this one.
fn smooth_pattern(width: u32, height: u32) -> RgbaImage {
    RgbaImage::from_fn(width, height, |x, y| {
        let fx = x as f64 / f64::from(width);
        let fy = y as f64 / f64::from(height);
        let wave = (fx * 6.0 * std::f64::consts::PI).sin() * 24.0;
        image::Rgba([
            (fx * 255.0).clamp(0.0, 255.0) as u8,
            ((fy * 180.0 + 40.0 + wave).clamp(0.0, 255.0)) as u8,
            (((fx + fy) * 110.0).clamp(0.0, 255.0)) as u8,
            255,
        ])
    })
}

fn wide_smooth_jpeg(dir: &Path, name: &str, width: u32, height: u32) -> PathBuf {
    let path = dir.join(name);
    let bytes = encode_with(&smooth_pattern(width, height), SaveFormat::Jpeg, Some(92)).unwrap();
    std::fs::write(&path, bytes).unwrap();
    path
}

#[test]
fn the_scaled_jpeg_preview_matches_the_full_decode() {
    let dir = temp_dir();
    let path = wide_smooth_jpeg(&dir, "wide.jpg", 4200, 600);

    let (scaled, full_w, full_h) = scaled_jpeg_preview(&path)
        .unwrap()
        .expect("a 4200 px JPEG has a halved decode");
    assert_eq!(
        (full_w, full_h),
        (4200, 600),
        "the header size is the document's"
    );
    assert!(
        scaled.width() < 4200,
        "the preview decode was not scaled down: {} px",
        scaled.width()
    );

    let full = open_document(&path).unwrap();
    let (width, height) = full.dimensions();
    let (target_w, target_h) = preview_dimensions(width, height);
    let fast = imageops::thumbnail(&scaled, target_w, target_h);
    let accurate = preview_pixels(&full.pixels());
    let difference = mean_absolute_difference(&fast, &accurate);
    assert!(
        difference < 4.0,
        "the halved decode differs from the full one by {difference:.2} levels"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_small_jpeg_is_not_decoded_twice() {
    let dir = temp_dir();
    // 1200 px is already preview-sized: the ordinary path is used, so no
    // quality is lost and no second decode is paid for.
    let path = wide_jpeg(&dir, "small.jpg", 1200, 800);
    assert!(scaled_jpeg_preview(&path).unwrap().is_none());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// The browser advertises `.avif`, the Viewer draws it through Qt, and this
/// build once answered "The image format Avif is not supported" from the
/// Editor because `image`'s `avif` feature is an encoder. The decoder is
/// `avif-native` (ADR 0005 revision); this test encodes a real AVIF and
/// opens it back, so the advertised format is proven decodable rather than
/// only named.
#[test]
fn an_advertised_avif_is_really_decoded() {
    let dir = temp_dir();
    let path = dir.join("sample.avif");
    let pixels = pattern(16, 12);
    let mut bytes = Vec::new();
    image::codecs::avif::AvifEncoder::new_with_speed_quality(&mut bytes, 10, 60)
        .write_image(
            pixels.as_raw(),
            pixels.width(),
            pixels.height(),
            ExtendedColorType::Rgba8,
        )
        .expect("the encoder must produce an AVIF");
    std::fs::write(&path, &bytes).unwrap();

    assert!(
        has_decoder(&path),
        "the browser lists .avif but the build has no decoder for it"
    );
    let document = open_document(&path).expect("the advertised AVIF must open");
    assert_eq!(document.dimensions(), (16, 12));
    std::fs::remove_dir_all(&dir).unwrap();
}

/// An extension is not a decoder. Before `has_decoder` built the decoder it
/// answered true for any name `image` could map, which is how a HEIC or this
/// build's AVIF reached the worker and failed in English instead of being
/// refused with a translatable line.
#[test]
fn a_file_with_no_decoder_is_reported_as_such() {
    let dir = temp_dir();
    let broken = dir.join("broken.jpg");
    std::fs::write(&broken, b"this is not a JPEG").unwrap();
    assert!(!has_decoder(&broken), "a .jpg name is not a JPEG decoder");

    let unlisted = dir.join("phone.heic");
    std::fs::write(&unlisted, b"this is not a HEIC either").unwrap();
    assert!(!has_decoder(&unlisted), "HEIC has no decoder in this build");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn opening_a_large_jpeg_publishes_the_preview_before_the_document() {
    let dir = temp_dir();
    let source = wide_jpeg(&dir, "wide.jpg", 4200, 600);
    let preview = dir.join("preview.png");
    let (sender, receiver) = std::sync::mpsc::channel();
    spawn_open(source.clone(), 7, preview.clone(), sender);

    let first = receiver
        .recv_timeout(std::time::Duration::from_secs(30))
        .expect("the worker must report something");
    match first {
        EditorTask::FirstPreview {
            generation,
            source: from,
            preview: fast,
            width,
            height,
        } => {
            assert_eq!(generation, 7);
            assert_eq!(from, source);
            // The published size is the document's, not the reduced
            // decode's: the footer must not show 2048 px and then jump.
            assert_eq!((width, height), (4200, 600));
            assert!(fast.is_file(), "the first preview was not written");
        }
        other => panic!(
            "the first message must be the preview, not {:?}",
            std::mem::discriminant(&other)
        ),
    }

    let second = receiver
        .recv_timeout(std::time::Duration::from_secs(30))
        .expect("the document must follow the preview");
    match second {
        EditorTask::Opened {
            generation,
            document,
            preview: written,
        } => {
            assert_eq!(generation, 7);
            assert_eq!(document.dimensions(), (4200, 600));
            assert_eq!(written, preview);
            assert!(written.is_file(), "the document had no preview");
        }
        _ => panic!("the second message must be the decoded document"),
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

fn open(dir: &Path) -> EditorDocument {
    let path = source_file(dir, "source.png", 64, 32);
    open_document(&path).unwrap()
}

#[test]
fn opening_decodes_the_file_and_keeps_the_source() {
    let dir = temp_dir();
    let path = source_file(&dir, "photo.png", 20, 10);
    let before = std::fs::read(&path).unwrap();
    let mut document = open_document(&path).unwrap();
    assert_eq!(document.dimensions(), (20, 10));
    assert!(!document.can_undo());
    assert!(document
        .apply(EditOperation::Rotate { degrees: 90 })
        .unwrap());
    assert_eq!(document.dimensions(), (10, 20));
    // The source bytes are untouched by an edit.
    assert_eq!(std::fs::read(&path).unwrap(), before);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn rotate_and_flip_change_pixels_and_undo_exactly() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let original = document.pixels();
    assert!(document
        .apply(EditOperation::Rotate { degrees: 90 })
        .unwrap());
    assert_eq!(document.dimensions(), (32, 64));
    assert!(document
        .apply(EditOperation::Flip {
            axis: FlipAxis::Vertical
        })
        .unwrap());
    assert_eq!(document.dimensions(), (32, 64));
    assert_eq!(
        document.history(),
        vec![UiText::new("rotate_right"), UiText::new("flip_vertical")]
    );
    assert!(document.undo());
    assert!(document.undo());
    assert_eq!(document.dimensions(), (64, 32));
    assert_eq!(document.pixels().as_raw(), original.as_raw());
    assert!(!document.can_undo());
    assert_eq!(document.redo_count(), 2);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn crop_and_resize_are_exact_and_reject_bad_rectangles() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let original = document.pixels();
    assert!(document
        .apply(EditOperation::Crop {
            x: 8,
            y: 4,
            width: 16,
            height: 12,
            fill: None,
            fill_alpha: 255,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (16, 12));
    assert_eq!(
        document.pixels().get_pixel(0, 0),
        original.get_pixel(8, 4),
        "the crop must start at the requested pixel"
    );
    assert!(document
        .apply(EditOperation::Resize {
            width: 8,
            height: 6,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Stretch,
            filter: ResizeFilter::Auto,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (8, 6));

    assert!(document.undo());
    assert_eq!(document.dimensions(), (16, 12));
    assert!(document.undo());
    assert_eq!(document.dimensions(), (64, 32));
    assert_eq!(document.pixels().as_raw(), original.as_raw());

    let error = document
        .apply(EditOperation::Crop {
            x: 60,
            y: 0,
            width: 10,
            height: 10,
            fill: None,
            fill_alpha: 255,
        })
        .unwrap_err();
    // The rejected request is a line, not a sentence: the code names the
    // cause and the arguments carry the rectangle and the document.
    assert_eq!(error.code, "crop_does_not_fit");
    assert_eq!(error.args, ["10", "10", "60", "0", "64", "32"]);
    assert!(!document.can_undo(), "a rejected crop must not be recorded");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_crop_with_a_fill_can_grow_the_canvas_past_the_picture() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let original = document.pixels();
    // Four pixels of border on the left and top, eight on the right and
    // six below: the rectangle reaches outside the picture on every side.
    assert!(document
        .apply(EditOperation::Crop {
            x: -4,
            y: -3,
            width: 76,
            height: 41,
            fill: Some([10, 20, 30]),
            fill_alpha: 255,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (76, 41));
    // The grown border carries the chosen colour…
    assert_eq!(
        document.pixels().get_pixel(0, 0),
        &image::Rgba([10, 20, 30, 255])
    );
    assert_eq!(
        document.pixels().get_pixel(75, 40),
        &image::Rgba([10, 20, 30, 255])
    );
    // …and the picture sits inside it at the rectangle's origin.
    assert_eq!(
        document.pixels().get_pixel(4, 3),
        original.get_pixel(0, 0),
        "the picture did not move to the grown canvas' origin"
    );
    assert_eq!(
        document.pixels().get_pixel(67, 34),
        original.get_pixel(63, 31),
        "the picture's last pixel must land at its rectangle offset"
    );
    assert_eq!(
        document.history(),
        vec![UiText::with("crop_grow", ["76", "41", "#0a141e"])]
    );

    // A transparent grow keeps the picture and leaves the border clear.
    assert!(document
        .apply(EditOperation::Crop {
            x: -2,
            y: -2,
            width: 80,
            height: 45,
            fill: Some([0, 0, 0]),
            fill_alpha: 0,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (80, 45));
    assert_eq!(
        document.pixels().get_pixel(0, 0),
        &image::Rgba([0, 0, 0, 0])
    );
    assert_eq!(
        document.pixels().get_pixel(2, 2),
        &image::Rgba([10, 20, 30, 255])
    );

    // A "grow" that misses the picture is only a coloured page, so it is
    // refused rather than silently replacing the photo with a swatch.
    let error = document
        .apply(EditOperation::Crop {
            x: 200,
            y: 0,
            width: 20,
            height: 20,
            fill: Some([255, 255, 255]),
            fill_alpha: 255,
        })
        .unwrap_err();
    assert_eq!(error.code, "crop_outside_document");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_noop_crop_or_resize_is_not_recorded() {
    let dir = temp_dir();
    let mut document = open(&dir);
    assert!(!document
        .apply(EditOperation::Crop {
            x: 0,
            y: 0,
            width: 64,
            height: 32,
            fill: None,
            fill_alpha: 255,
        })
        .unwrap());
    assert!(!document
        .apply(EditOperation::Resize {
            width: 64,
            height: 32,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Stretch,
            filter: ResizeFilter::Auto,
        })
        .unwrap());
    assert!(!document.can_undo());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_zero_rotation_is_rejected() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let error = document
        .apply(EditOperation::Rotate { degrees: 360 })
        .unwrap_err();
    assert_eq!(error.code, "invalid_rotation");
    assert_eq!(error.args, ["360"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_identity_quad_is_never_recorded() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let (width, height) = document.dimensions();
    let identity = EditOperation::Transform {
        corners: [
            [0.0, 0.0],
            [f64::from(width), 0.0],
            [f64::from(width), f64::from(height)],
            [0.0, f64::from(height)],
        ],
    };
    assert!(!document.apply(identity.clone()).unwrap());
    assert!(!document.would_change(&identity).unwrap());
    assert!(!document.can_undo());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_identity_quad_reproduces_every_pixel() {
    let dir = temp_dir();
    let document = open(&dir);
    let image = document.pixels();
    let (width, height) = image.dimensions();
    let warped = warp_quad(
        &image,
        &[
            [0.0, 0.0],
            [f64::from(width), 0.0],
            [f64::from(width), f64::from(height)],
            [0.0, f64::from(height)],
        ],
    );
    assert_eq!(
        warped.as_raw(),
        image.as_raw(),
        "an identity quad is a copy, not a half-pixel shift"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_keystone_maps_the_quad_onto_the_frame() {
    // R encodes the column and G the row, so a sample can be read back as
    // the source point it came from: the warp is judged on coordinates, not
    // on whether it "looks straightened".
    let image = RgbaImage::from_fn(64, 64, |x, y| {
        image::Rgba([x as u8 * 4, y as u8 * 4, 0, 255])
    });
    // The inner rectangle (16, 16) – (48, 48) becomes the whole frame.
    let warped = warp_quad(
        &image,
        &[[16.0, 16.0], [48.0, 16.0], [48.0, 48.0], [16.0, 48.0]],
    );
    assert_eq!(warped.dimensions(), image.dimensions(), "the frame is kept");
    let left = warped.get_pixel(0, 32);
    let right = warped.get_pixel(63, 32);
    let top = warped.get_pixel(32, 0);
    let bottom = warped.get_pixel(32, 63);
    // A linear ramp survives bilinear sampling exactly, so these are the
    // quad's own edges: x 16 → R 64, x 47.5 → R ~190; likewise for y.
    assert!(
        (left[0] as i32 - 64).abs() <= 4,
        "the left edge sampled x≈{}",
        left[0] / 4
    );
    assert!(
        (right[0] as i32 - 190).abs() <= 4,
        "the right edge sampled x≈{}",
        right[0] / 4
    );
    assert!(
        (top[1] as i32 - 64).abs() <= 4,
        "the top edge sampled y≈{}",
        top[1] / 4
    );
    assert!(
        (bottom[1] as i32 - 190).abs() <= 4,
        "the bottom edge sampled y≈{}",
        bottom[1] / 4
    );
}

#[test]
fn a_transform_of_one_corner_keeps_the_far_side_and_undoes_by_snapshot() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let original = document.pixels();
    // Pull the top-left corner inwards: the bottom-right of the output must
    // still be the bottom-right of the picture, which is what makes this a
    // corner pin rather than a resize.
    assert!(document
        .apply(EditOperation::Transform {
            corners: [[12.0, 6.0], [64.0, 0.0], [64.0, 32.0], [0.0, 32.0],],
        })
        .unwrap());
    assert_eq!(document.dimensions(), (64, 32));
    let warped = document.pixels();
    assert_ne!(warped.as_raw(), original.as_raw());
    assert_eq!(
        document.history(),
        vec![UiText::new("transform")],
        "the history names the operation, the sentence lives in UiLines"
    );
    // The bottom-right destination pixel comes from the quad's own
    // bottom-right, which did not move.
    let corner = warped.get_pixel(63, 31);
    let expected = original.get_pixel(63, 31);
    for channel in 0..3 {
        assert!(
            (corner[channel] as i32 - expected[channel] as i32).abs() <= 6,
            "the untouched corner changed: {corner:?} vs {expected:?}"
        );
    }
    assert!(document.undo());
    assert_eq!(document.pixels().as_raw(), original.as_raw());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn free_transform_scales_inside_frame_fills_background_and_undoes() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let original = document.pixels();
    // Identity rect is a no-op.
    assert!(!document
        .apply(EditOperation::FreeTransform {
            x: 0,
            y: 0,
            width: 64,
            height: 32,
            rotation: 0.0,
            fill: Some([10, 20, 30]),
            fill_alpha: 255,
        })
        .unwrap());
    // Place scaled 32x16 image at (16, 8) with opaque background fill.
    assert!(document
        .apply(EditOperation::FreeTransform {
            x: 16,
            y: 8,
            width: 32,
            height: 16,
            rotation: 0.0,
            fill: Some([10, 20, 30]),
            fill_alpha: 255,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (64, 32));
    let transformed = document.pixels();
    // Uncovered corner gets the background fill.
    assert_eq!(*transformed.get_pixel(0, 0), image::Rgba([10, 20, 30, 255]));
    // Interior pixel inside the placed rect is not the background fill.
    assert_ne!(
        *transformed.get_pixel(32, 16),
        image::Rgba([10, 20, 30, 255])
    );
    // Transparent background leaves uncovered pixels at alpha 0 and clips off-canvas cleanly.
    assert!(document
        .apply(EditOperation::FreeTransform {
            x: -8,
            y: -4,
            width: 40,
            height: 20,
            rotation: 30.0,
            fill: None,
            fill_alpha: 0,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (64, 32));
    assert_eq!(document.pixels().get_pixel(63, 31)[3], 0);
    // Two undos restore the original image bit-for-bit.
    assert!(document.undo());
    assert!(document.undo());
    assert_eq!(document.pixels().as_raw(), original.as_raw());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_folded_or_outside_quad_is_rejected_with_a_line() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let outside = document
        .apply(EditOperation::Transform {
            corners: [[-1.0, 0.0], [64.0, 0.0], [64.0, 32.0], [0.0, 32.0]],
        })
        .unwrap_err();
    assert_eq!(outside.code, "transform_outside");
    assert_eq!(outside.args, ["-1", "0", "64", "32"]);

    // TR and BL swapped: the edges cross, so there is no picture inside the
    // quad to keep.
    let folded = document
        .apply(EditOperation::Transform {
            corners: [[0.0, 0.0], [64.0, 0.0], [0.0, 32.0], [64.0, 32.0]],
        })
        .unwrap_err();
    assert_eq!(folded.code, "transform_degenerate");

    // The same quad wound the other way is a mirror of the frame. Turning a
    // picture over is Flip's job, so Transform refuses it rather than
    // applying an edit the user cannot name.
    let reversed = document
        .apply(EditOperation::Transform {
            corners: [[0.0, 0.0], [0.0, 32.0], [64.0, 32.0], [64.0, 0.0]],
        })
        .unwrap_err();
    assert_eq!(reversed.code, "transform_degenerate");

    // Two corners on the same point.
    let pinched = document
        .apply(EditOperation::Transform {
            corners: [[8.0, 8.0], [8.0, 8.0], [64.0, 32.0], [0.0, 32.0]],
        })
        .unwrap_err();
    assert_eq!(pinched.code, "transform_degenerate");
    assert!(!document.can_undo(), "a rejected warp must not be recorded");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_new_edit_discards_the_redo_branch() {
    let dir = temp_dir();
    let mut document = open(&dir);
    assert!(document
        .apply(EditOperation::Rotate { degrees: 90 })
        .unwrap());
    assert!(document.undo());
    assert!(document.can_redo());
    assert!(document
        .apply(EditOperation::Resize {
            width: 32,
            height: 16,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Stretch,
            filter: ResizeFilter::Auto,
        })
        .unwrap());
    assert!(!document.can_redo());
    assert_eq!(
        document.history(),
        vec![UiText::with("resize", ["32", "16"])]
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A stroke is one history step: it paints its colour at full opacity,
/// leaves pixels outside it alone, and undo restores the exact bytes.
#[test]
fn a_brush_stroke_paints_its_colour_and_undoes_in_one_step() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let before = document.pixels();
    assert!(document
        .apply(EditOperation::Paint {
            points: vec![[16.3, 16.0]],
            color: [255, 0, 0],
            radius: 4.0,
            opacity: 1.0,
            erase: false,
        })
        .unwrap());

    assert_eq!(document.history(), vec![UiText::new("brush_stroke")]);
    assert!(document.can_undo());
    let painted = document.pixels();
    // The centre of the dot is exactly the brush colour.
    assert_eq!(painted.get_pixel(16, 16).0, [255, 0, 0, 255]);
    // A pixel outside the stroke keeps its source value.
    assert_eq!(painted.get_pixel(50, 2).0, before.get_pixel(50, 2).0);
    // The edge is feathered: partly the brush, partly the source, never a
    // hard step.
    let edge = painted.get_pixel(20, 16).0;
    assert_ne!(edge, [255, 0, 0, 255]);
    assert_ne!(edge, before.get_pixel(20, 16).0);

    assert!(document.undo());
    assert_eq!(document.pixels().as_raw(), before.as_raw());
    assert!(document.history().is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// An eraser lowers alpha and keeps the colour it uncovered, and a stroke
/// that doubles back does not erase twice at the join: coverage is the
/// maximum over the segments, not their sum.
#[test]
fn an_eraser_lowers_alpha_without_building_up_at_a_join() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let before = document.pixels();
    assert!(document
        .apply(EditOperation::Paint {
            points: vec![[10.0, 10.0], [30.0, 10.0], [10.0, 10.0]],
            color: [0, 0, 0],
            radius: 3.0,
            opacity: 0.5,
            erase: true,
        })
        .unwrap());

    assert_eq!(
        document.history(),
        vec![UiText::new("eraser_stroke")],
        "the history names the eraser, not the brush"
    );
    // 255 × (1 − 0.5) = 127.5 → 128 at full coverage. A sum over the
    // outbound and return segments would erase this pixel twice.
    let pixel = document.pixels().get_pixel(20, 10).0;
    assert_eq!(pixel[3], 128, "the overlap erased twice: {pixel:?}");
    // The eraser does not repaint the colour.
    assert_eq!(&pixel[..3], &before.get_pixel(20, 10).0[..3]);
    // The outbound and return legs cover the same line, so the result must
    // be the same as one leg on its own — including on the anti-aliased
    // edge, where a sum would darken the ring. Comparing the whole frame
    // rather than one hand-picked pixel keeps the check honest about the
    // geometry.
    let doubled = document.pixels();
    assert!(document.undo());
    assert!(document
        .apply(EditOperation::Paint {
            points: vec![[10.0, 10.0], [30.0, 10.0]],
            color: [0, 0, 0],
            radius: 3.0,
            opacity: 0.5,
            erase: true,
        })
        .unwrap());
    assert_eq!(
        doubled.as_raw(),
        document.pixels().as_raw(),
        "the return leg summed its dabs instead of covering them once"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A request a brush cannot honour is refused with a line, not painted as
/// far as it can go.
#[test]
fn a_malformed_stroke_is_rejected_with_a_line() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let mut paint = |points: Vec<[f64; 2]>, radius: f64, opacity: f64| {
        document.apply(EditOperation::Paint {
            points,
            color: [1, 2, 3],
            radius,
            opacity,
            erase: false,
        })
    };

    assert_eq!(
        paint(Vec::new(), 4.0, 1.0).unwrap_err().code,
        "paint_empty_stroke"
    );
    assert_eq!(
        paint(vec![[f64::NAN, 0.0]], 4.0, 1.0).unwrap_err().code,
        "paint_bad_point"
    );
    assert_eq!(
        paint(vec![[1.0, 1.0]], 0.0, 1.0).unwrap_err().code,
        "paint_bad_radius"
    );
    assert_eq!(
        paint(vec![[1.0, 1.0]], 4.0, 0.0).unwrap_err().code,
        "paint_bad_opacity"
    );
    assert!(!document.can_undo(), "a refused stroke records no step");
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A long-edge limit scales the whole frame, keeps its shape and never
/// enlarges a picture that is already small enough. Rounding can make the
/// short side one pixel but never zero.
#[test]
fn export_dimensions_keep_the_aspect_and_never_upscale() {
    assert_eq!(export_dimensions(160, 120, 64), Some((64, 48)));
    assert_eq!(export_dimensions(120, 160, 64), Some((48, 64)));
    // The same limit on a square keeps it square.
    assert_eq!(export_dimensions(100, 100, 50), Some((50, 50)));
    // A limit at or above the longer side is not a request to upscale.
    assert_eq!(export_dimensions(160, 120, 160), None);
    assert_eq!(export_dimensions(160, 120, 1000), None);
    assert_eq!(export_dimensions(160, 120, 0), None);
    // A very thin picture keeps at least one row.
    assert_eq!(export_dimensions(4000, 3, 8), Some((8, 1)));
}

#[test]
fn the_resize_filter_changes_the_pixels() {
    // A step of two values, enlarged. Nearest may only copy the two source
    // values; a smooth kernel has to interpolate the step it crosses, so the
    // dropdown is a real control rather than a second label.
    let mut image = RgbaImage::new(4, 1);
    for x in 0..4u32 {
        let value = if x < 2 { 0 } else { 255 };
        image.put_pixel(x, 0, image::Rgba([value, value, value, 255]));
    }
    let nearest = resample(&image, 18, 5, ResizeFilter::Nearest);
    let bilinear = resample(&image, 18, 5, ResizeFilter::Bilinear);
    let lanczos = resample(&image, 18, 5, ResizeFilter::Lanczos3);
    assert_eq!(nearest.dimensions(), (18, 5));
    assert!(nearest
        .pixels()
        .all(|pixel| pixel[0] == 0 || pixel[0] == 255));
    assert!(bilinear
        .pixels()
        .any(|pixel| pixel[0] > 0 && pixel[0] < 255));
    assert!(lanczos.pixels().any(|pixel| pixel[0] > 0 && pixel[0] < 255));
    assert_ne!(nearest.as_raw(), bilinear.as_raw());
    assert_ne!(bilinear.as_raw(), lanczos.as_raw());
    // `Auto` enlarges with Lanczos3, so it cannot equal Nearest here.
    let automatic = resample(&image, 18, 5, ResizeFilter::Auto);
    assert_ne!(automatic.as_raw(), nearest.as_raw());
}

#[test]
fn cover_rect_keeps_the_centre() {
    // A 2:1 source resized to 1:1 keeps the full height and takes a square
    // width from the middle: Resize has no anchor, so nothing else can
    // move the crop off centre.
    assert_eq!(cover_rect(64, 32, 16, 16), (16, 0, 32, 32));
    // A taller source loses rows instead.
    assert_eq!(cover_rect(32, 64, 16, 16), (0, 16, 32, 32));
    // The same aspect keeps the whole image.
    assert_eq!(cover_rect(64, 32, 32, 16), (0, 0, 64, 32));
    // A 3:2 target on a 2:1 source keeps full height and trims the width
    // to the nearest pixel, centred.
    assert_eq!(cover_rect(64, 32, 15, 10), (8, 0, 48, 32));
    assert_eq!(cover_rect(64, 32, 10, 15), (21, 0, 21, 32));
}

#[test]
fn fit_padding_centres_the_source_in_a_square_target() {
    let image = RgbaImage::from_pixel(4, 2, image::Rgba([10, 20, 30, 255]));
    let fitted = fit_with_padding(&image, 4, 4, [1, 2, 3], 255, ResizeFilter::Auto);
    assert_eq!(fitted.dimensions(), (4, 4));
    // One row of fill above and below the centred source, never all on one
    // side.
    assert_eq!(fitted.get_pixel(0, 0), &image::Rgba([1, 2, 3, 255]));
    assert_eq!(fitted.get_pixel(0, 1), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(fitted.get_pixel(3, 2), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(fitted.get_pixel(3, 3), &image::Rgba([1, 2, 3, 255]));
    // A tall source is padded left and right instead.
    let tall = RgbaImage::from_pixel(2, 4, image::Rgba([10, 20, 30, 255]));
    let fitted = fit_with_padding(&tall, 4, 4, [9, 8, 7], 255, ResizeFilter::Auto);
    assert_eq!(fitted.get_pixel(0, 0), &image::Rgba([9, 8, 7, 255]));
    assert_eq!(fitted.get_pixel(1, 0), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(fitted.get_pixel(2, 3), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(fitted.get_pixel(3, 3), &image::Rgba([9, 8, 7, 255]));
}

#[test]
fn fit_padding_keeps_a_non_square_target() {
    let image = RgbaImage::from_pixel(4, 2, image::Rgba([10, 20, 30, 255]));
    // An 8 × 4 target has the source's 2:1 shape: the whole frame is the
    // image and the colour is never used.
    let exact = fit_with_padding(&image, 8, 4, [1, 2, 3], 255, ResizeFilter::Auto);
    assert_eq!(exact.dimensions(), (8, 4));
    assert_eq!(exact.get_pixel(0, 0), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(exact.get_pixel(7, 3), &image::Rgba([10, 20, 30, 255]));
    // An 8 × 6 target is taller than the source: a 1 px band on top and
    // bottom, not a square.
    let wide = fit_with_padding(&image, 8, 6, [1, 2, 3], 255, ResizeFilter::Auto);
    assert_eq!(wide.dimensions(), (8, 6));
    assert_eq!(wide.get_pixel(0, 0), &image::Rgba([1, 2, 3, 255]));
    assert_eq!(wide.get_pixel(0, 1), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(wide.get_pixel(7, 4), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(wide.get_pixel(7, 5), &image::Rgba([1, 2, 3, 255]));
    // A portrait source in an 8 × 4 frame is pillarboxed, not squared.
    let tall = RgbaImage::from_pixel(2, 4, image::Rgba([10, 20, 30, 255]));
    let pillarboxed = fit_with_padding(&tall, 8, 4, [4, 5, 6], 255, ResizeFilter::Auto);
    assert_eq!(pillarboxed.dimensions(), (8, 4));
    assert_eq!(pillarboxed.get_pixel(0, 0), &image::Rgba([4, 5, 6, 255]));
    assert_eq!(pillarboxed.get_pixel(3, 0), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(pillarboxed.get_pixel(4, 3), &image::Rgba([10, 20, 30, 255]));
    assert_eq!(pillarboxed.get_pixel(7, 0), &image::Rgba([4, 5, 6, 255]));
}

#[test]
fn resize_can_fit_the_whole_image_with_the_chosen_colour() {
    let dir = temp_dir();
    let path = source_file(&dir, "photo.png", 8, 4);
    let mut document = open_document(&path).unwrap();
    let source_pixel = *document.pixels().get_pixel(0, 2);
    assert!(document
        .apply(EditOperation::Resize {
            width: 8,
            height: 8,
            fill: Some([255, 0, 0]),
            fill_alpha: 255,
            mode: ResizeMode::Pad,
            filter: ResizeFilter::Auto,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (8, 8));
    assert_eq!(
        document.pixels().get_pixel(0, 7),
        &image::Rgba([255, 0, 0, 255]),
        "the leftover band is the chosen colour"
    );
    assert_eq!(
        document.pixels().get_pixel(0, 4),
        &source_pixel,
        "the source was not stretched to the square"
    );
    assert_eq!(
        document.history(),
        vec![UiText::with("resize_pad", ["8", "8", "#ff0000"])]
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn resize_can_leave_the_leftover_transparent() {
    let dir = temp_dir();
    let path = source_file(&dir, "photo.png", 8, 4);
    let mut document = open_document(&path).unwrap();
    assert!(document
        .apply(EditOperation::Resize {
            width: 8,
            height: 8,
            fill: Some([255, 0, 0]),
            fill_alpha: 0,
            mode: ResizeMode::Pad,
            filter: ResizeFilter::Auto,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (8, 8));
    assert_eq!(
        document.pixels().get_pixel(0, 7),
        &image::Rgba([255, 0, 0, 0]),
        "the leftover band kept the chosen colour but not an opaque alpha"
    );
    assert_eq!(
        document.history(),
        vec![UiText::with("resize_pad_clear", ["8", "8"])]
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A resize answers "make it this big". Changing the shape must not
/// silently throw the edges away, which is what the old cover-by-default
/// path did: a 64 × 32 picture resized to a square lost a quarter of its
/// width with nothing on screen saying so.
#[test]
fn a_stretch_resize_keeps_every_column() {
    let dir = temp_dir();
    let mut document = open(&dir); // 64 × 32 pattern
    assert!(document
        .apply(EditOperation::Resize {
            width: 32,
            height: 32,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Stretch,
            filter: ResizeFilter::Nearest,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (32, 32));
    // The pattern's red channel is x * 8, so a 64-wide source starts at 0
    // and ends at 63 * 8 mod 256 = 248. `Nearest` samples half a pixel in,
    // which is why the first column is 8 rather than 0; the point is that
    // both *ends* of the source are present, where the old cover crop
    // would have handed back 128 and 120.
    let first = document.pixels().get_pixel(0, 0)[0];
    let last = document.pixels().get_pixel(31, 0)[0];
    assert!(
        first < 40,
        "the stretch started at {first}, not near the source's left edge"
    );
    assert!(
        last > 200,
        "the stretch ended at {last}, not near the source's right edge"
    );
    assert_eq!(
        document.history(),
        vec![UiText::with("resize", ["32", "32"])],
        "a stretch is a resize, not a crop"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// `Cover` is the old behaviour, now a choice: the centred rectangle that
/// matches the target's shape, then a scale.
#[test]
fn a_cover_resize_crops_the_centre_and_says_so() {
    let dir = temp_dir();
    let mut document = open(&dir); // 64 × 32, red = x * 8
    assert!(document
        .apply(EditOperation::Resize {
            width: 32,
            height: 32,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Cover,
            filter: ResizeFilter::Nearest,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (32, 32));
    // The cover rectangle starts at x = 16, so the first column is 128.
    assert_eq!(document.pixels().get_pixel(0, 0)[0], 128);
    assert_eq!(document.pixels().get_pixel(31, 0)[0], 120);
    assert_eq!(
        document.history(),
        vec![UiText::with("resize_cover", ["32", "32"])],
        "the history must say which resize discarded the edges"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A locked ratio produces integer sides that miss the shape by a fraction
/// of a pixel. Covering must not lose the row that difference is worth.
#[test]
fn a_rounded_ratio_does_not_shave_a_pixel() {
    let dir = temp_dir();
    let mut image = pattern(200, 134);
    for x in 0..200 {
        image.put_pixel(x, 133, image::Rgba([1, 2, 3, 255]));
    }
    let mut document = EditorDocument::from_image(dir.join("photo.png"), image);
    // 200 × 134 → 200 × 133 is the rounding a 200 × 133.0 target produces.
    // Cover would crop one row; the snap keeps the whole frame instead.
    assert!(document
        .apply(EditOperation::Resize {
            width: 200,
            height: 133,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Cover,
            filter: ResizeFilter::Nearest,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (200, 133));
    assert_eq!(
        document.pixels().get_pixel(0, 132),
        &image::Rgba([1, 2, 3, 255]),
        "the last row was shaved by the rounding"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// `Pad` is the only mode that paints pixels the source does not have, so
/// it is the only one that needs a colour; asking for it without one is a
/// refusal, not a silent black border.
#[test]
fn a_pad_without_a_colour_is_refused() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let error = document
        .apply(EditOperation::Resize {
            width: 32,
            height: 32,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Pad,
            filter: ResizeFilter::Auto,
        })
        .unwrap_err();
    assert_eq!(error.code, "resize_pad_needs_colour");
    assert_eq!(document.dimensions(), (64, 32));
    assert!(!document.can_undo(), "a refused resize is not recorded");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn reset_returns_to_the_original_pixels_and_clears_history() {
    let dir = temp_dir();
    let mut document = open(&dir);
    let original = document.pixels();
    assert!(document
        .apply(EditOperation::Crop {
            x: 1,
            y: 2,
            width: 10,
            height: 10,
            fill: None,
            fill_alpha: 255,
        })
        .unwrap());
    assert!(document.reset());
    assert_eq!(document.dimensions(), (64, 32));
    assert_eq!(document.pixels().as_raw(), original.as_raw());
    assert!(!document.can_undo());
    assert!(
        !document.reset(),
        "an untouched document has nothing to reset"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn history_is_bounded() {
    let dir = temp_dir();
    let mut document = open(&dir);
    for _ in 0..(MAX_HISTORY_STEPS + 5) {
        assert!(document
            .apply(EditOperation::Rotate { degrees: 90 })
            .unwrap());
    }
    assert_eq!(document.history().len(), MAX_HISTORY_STEPS);
    // Undo still walks back through every step that was kept.
    for _ in 0..MAX_HISTORY_STEPS {
        assert!(document.undo());
    }
    assert!(!document.undo());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn preview_is_written_downscaled_and_is_a_png() {
    let dir = temp_dir();
    let document = open_document(&source_file(&dir, "big.png", 400, 200)).unwrap();
    let preview = dir.join("preview.png");
    render_preview(&document.pixels(), &preview).unwrap();
    let decoded = image::open(&preview).unwrap();
    assert_eq!(
        (decoded.width(), decoded.height()),
        (400, 200),
        "small images are not upscaled"
    );

    let wide = RgbaImage::from_fn(PREVIEW_LONG_EDGE * 2, PREVIEW_LONG_EDGE, |x, y| {
        image::Rgba([(x % 256) as u8, (y % 256) as u8, 0, 255])
    });
    render_preview(&wide, &preview).unwrap();
    let decoded = image::open(&preview).unwrap();
    assert_eq!(decoded.width(), PREVIEW_LONG_EDGE);
    assert_eq!(decoded.height(), PREVIEW_LONG_EDGE / 2);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn every_save_format_round_trips_the_working_pixels() {
    let dir = temp_dir();
    let source = source_file(&dir, "source.png", 16, 8);
    let document = open_document(&source).unwrap();
    let pixels = document.pixels();
    for (extension, tolerance) in [
        ("png", 0u8),
        ("jpg", 4),
        ("webp", 0),
        ("tiff", 0),
        ("gif", 0),
        ("bmp", 0),
        ("tga", 0),
        ("qoi", 0),
    ] {
        let target = dir.join(format!("out.{extension}"));
        save_pixels(&source, &pixels, &target).unwrap();
        let written = image::open(&target)
            .unwrap_or_else(|error| panic!("{extension} did not decode: {error}"))
            .to_rgba8();
        assert_eq!(written.dimensions(), pixels.dimensions(), "{extension}");
        for (index, (before, after)) in pixels.pixels().zip(written.pixels()).enumerate().step_by(7)
        {
            for channel in 0..3 {
                let delta = before.0[channel].abs_diff(after.0[channel]);
                assert!(
                    delta <= tolerance,
                    "{extension} pixel {index} channel {channel}: {before:?} vs {after:?}"
                );
            }
        }
    }
    // An extension with no encoder is refused, and writes nothing.
    let refused = dir.join("out.psd");
    assert!(save_pixels(&source, &pixels, &refused).is_err());
    assert!(!refused.exists());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_document_tracks_whether_its_pixels_are_on_disk() {
    let dir = temp_dir();
    let source = source_file(&dir, "photo.png", 20, 10);
    let mut document = open_document(&source).unwrap();
    assert!(!document.has_unsaved_changes());

    assert!(document
        .apply(EditOperation::Rotate { degrees: 90 })
        .unwrap());
    assert!(document.has_unsaved_changes());

    let target = dir.join("copy.png");
    save_pixels(&source, &document.pixels(), &target).unwrap();
    document.mark_saved(target.clone()).unwrap();
    assert!(!document.has_unsaved_changes());
    assert_eq!(document.save_target().0, target);

    // Undo goes back to the pixels as opened, which is not what the save
    // wrote, so the document is unsaved again; the file on disk is the
    // rotated one.
    assert!(document.undo());
    assert!(
        document.has_unsaved_changes(),
        "the save wrote the rotated pixels"
    );
    assert!(document
        .apply(EditOperation::Flip {
            axis: FlipAxis::Vertical
        })
        .unwrap());
    assert!(document.has_unsaved_changes());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn overwriting_the_source_keeps_the_previous_file_as_a_backup() {
    let dir = temp_dir();
    let source = source_file(&dir, "photo.png", 20, 10);
    let before = std::fs::read(&source).unwrap();
    let mut document = open_document(&source).unwrap();
    assert!(document
        .apply(EditOperation::Resize {
            width: 10,
            height: 5,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Stretch,
            filter: ResizeFilter::Auto,
        })
        .unwrap());
    save_pixels(&source, &document.pixels(), &source).unwrap();
    assert!(
        document.source_changed(),
        "a write from outside the document is detected"
    );
    document.remember_source();
    assert!(!document.source_changed(), "the document's own save is not");
    let decoded = image::open(&source).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (10, 5));
    let backup = dir.join("photo.png.bak");
    assert_eq!(std::fs::read(&backup).unwrap(), before);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn operation_labels_are_codes_not_sentences() {
    // The wording lives in `UiLines.qml`; Core only names the operation and
    // the numbers. A translated history line in Core would be English in a
    // Vietnamese window, which is the bug this shape exists to prevent.
    assert_eq!(
        EditOperation::Rotate { degrees: 90 }.label(),
        UiText::new("rotate_right")
    );
    assert_eq!(
        EditOperation::Rotate { degrees: -90 }.label(),
        UiText::new("rotate_left")
    );
    assert_eq!(
        EditOperation::Flip {
            axis: FlipAxis::Horizontal
        }
        .label(),
        UiText::new("flip_horizontal")
    );
    assert_eq!(
        EditOperation::Crop {
            x: 1,
            y: 2,
            width: 3,
            height: 4,
            fill: None,
            fill_alpha: 255
        }
        .label(),
        UiText::with("crop", ["3", "4", "1", "2"])
    );
    assert_eq!(
        EditOperation::Resize {
            width: 512,
            height: 512,
            fill: None,
            fill_alpha: 255,
            mode: ResizeMode::Stretch,
            filter: ResizeFilter::Auto
        }
        .label(),
        UiText::with("resize", ["512", "512"])
    );
    // The label must name the colour it padded with, not only the size.
    assert_eq!(
        EditOperation::Resize {
            width: 512,
            height: 512,
            fill: Some([255, 0, 0]),
            fill_alpha: 255,
            mode: ResizeMode::Pad,
            filter: ResizeFilter::Auto
        }
        .label(),
        UiText::with("resize_pad", ["512", "512", "#ff0000"])
    );
    // No code ever arrives with a formatted sentence in it.
    for operation in [
        EditOperation::Rotate { degrees: 45 },
        EditOperation::Resize {
            width: 3,
            height: 4,
            fill: Some([1, 2, 3]),
            fill_alpha: 255,
            mode: ResizeMode::Pad,
            filter: ResizeFilter::Auto,
        },
    ] {
        let label = operation.label();
        assert!(
            !label.code.contains(' ') && !label.code.contains('×'),
            "the code must be a stable key, not a sentence: {label:?}"
        );
    }
}

#[test]
fn canvas_size_grows_and_shrinks_without_scaling_and_respects_anchor() {
    let dir = temp_dir();
    let path = source_file(&dir, "photo.png", 4, 4);
    let mut document = open_document(&path).unwrap();
    let origin_pixel = *document.pixels().get_pixel(0, 0);

    // Grow to 8x6 anchored at top_left: source stays at (0..4, 0..4), new area gets fill.
    assert!(document
        .apply(EditOperation::CanvasSize {
            width: 8,
            height: 6,
            anchor: "top_left".to_owned(),
            fill: Some([10, 20, 30]),
            fill_alpha: 255,
        })
        .unwrap());
    assert_eq!(document.dimensions(), (8, 6));
    assert_eq!(document.pixels().get_pixel(0, 0), &origin_pixel);
    assert_eq!(
        document.pixels().get_pixel(7, 5),
        &image::Rgba([10, 20, 30, 255])
    );

    // Undo restores the original 4x4 document.
    assert!(document.undo());
    assert_eq!(document.dimensions(), (4, 4));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn rotate_angle_expands_canvas_and_fills_corners() {
    let dir = temp_dir();
    let path = source_file(&dir, "photo.png", 20, 10);
    let mut document = open_document(&path).unwrap();

    // 45° rotation expands bounding box beyond 20x10 and fills corners with background.
    assert!(document
        .apply(EditOperation::RotateAngle {
            degrees: 45.0,
            fill: Some([40, 50, 60]),
            fill_alpha: 255,
        })
        .unwrap());
    let (w, h) = document.dimensions();
    assert!(w > 20 && h > 10, "expected expanded bounds, got {w}x{h}");
    assert_eq!(
        document.pixels().get_pixel(0, 0),
        &image::Rgba([40, 50, 60, 255])
    );
    assert!(document.undo());
    assert_eq!(document.dimensions(), (20, 10));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn adjust_color_modifies_pixels_and_undoes() {
    let dir = temp_dir();
    let path = source_file(&dir, "photo.png", 8, 8);
    let mut document = open_document(&path).unwrap();
    let before = *document.pixels().get_pixel(4, 4);

    // Zero adjustment is a no-op.
    assert!(!document
        .apply(EditOperation::AdjustColor {
            brightness: 0.0,
            contrast: 0.0,
            saturation: 0.0,
        })
        .unwrap());

    // Brightening increases RGB channels while preserving alpha.
    assert!(document
        .apply(EditOperation::AdjustColor {
            brightness: 0.25,
            contrast: 0.1,
            saturation: 0.0,
        })
        .unwrap());
    let after = *document.pixels().get_pixel(4, 4);
    assert_ne!(after, before);
    assert_eq!(after[3], before[3]);

    assert!(document.undo());
    assert_eq!(*document.pixels().get_pixel(4, 4), before);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn single_layer_compositor_is_zero_copy_fast_path() {
    let img = Arc::new(RgbaImage::from_pixel(
        16,
        16,
        image::Rgba([40, 80, 120, 255]),
    ));
    let stack = LayerStack::from_single(Arc::clone(&img));
    let out = composite_stack(&stack);
    assert!(
        Arc::ptr_eq(&img, &out),
        "single-layer composite must be O(1) zero-copy"
    );
}

#[test]
fn multilayer_compositor_applies_offset_opacity_visibility_and_blend_modes() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(20, 20, image::Rgba([200, 100, 50, 255]));
    let mut doc = EditorDocument::from_image(dir.join("base.png"), bg);

    // Add a 6x6 red square at offset (4, 5)
    let top_px = Arc::new(RgbaImage::from_pixel(
        6,
        6,
        image::Rgba([100, 200, 100, 255]),
    ));
    assert!(doc
        .apply_layer_op(LayerOperation::AddImage {
            name: "Top".to_owned(),
            offset_x: 4,
            offset_y: 5,
            pixels: top_px,
        })
        .unwrap());
    let top_id = doc.active_layer_id();

    // Normal blend at 100% replaces inside (4..10, 5..11) and keeps background outside
    assert_eq!(
        *doc.pixels().get_pixel(0, 0),
        image::Rgba([200, 100, 50, 255])
    );
    assert_eq!(
        *doc.pixels().get_pixel(5, 6),
        image::Rgba([100, 200, 100, 255])
    );

    // Multiply blend: (200/255 * 100/255 * 255) ≈ 78, (100*200/255) ≈ 78, (50*100/255) ≈ 20
    assert!(doc
        .apply_layer_op(LayerOperation::SetProps {
            id: top_id,
            name: None,
            visible: None,
            locked: None,
            opacity: None,
            blend_mode: Some(BlendMode::Multiply),
            offset_x: None,
            offset_y: None,
        })
        .unwrap());
    let mul = *doc.pixels().get_pixel(5, 6);
    assert!((mul[0] as i32 - 78).abs() <= 1 && (mul[1] as i32 - 78).abs() <= 1);

    // Half opacity with Normal blend: 0.5 * 100 + 0.5 * 200 = 150
    assert!(doc
        .apply_layer_op(LayerOperation::SetProps {
            id: top_id,
            name: None,
            visible: None,
            locked: None,
            opacity: Some(0.5),
            blend_mode: Some(BlendMode::Normal),
            offset_x: None,
            offset_y: None,
        })
        .unwrap());
    let half = *doc.pixels().get_pixel(5, 6);
    assert!((half[0] as i32 - 150).abs() <= 1 && (half[1] as i32 - 150).abs() <= 1);

    // Hiding the top layer restores exact background pixel
    assert!(doc
        .apply_layer_op(LayerOperation::SetProps {
            id: top_id,
            name: None,
            visible: Some(false),
            locked: None,
            opacity: None,
            blend_mode: None,
            offset_x: None,
            offset_y: None,
        })
        .unwrap());
    assert_eq!(
        *doc.pixels().get_pixel(5, 6),
        image::Rgba([200, 100, 50, 255])
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn active_layer_target_respects_lock_visibility_and_offset_without_touching_siblings() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(32, 32, image::Rgba([20, 40, 60, 255]));
    let mut doc = EditorDocument::from_image(dir.join("bg.png"), bg);
    let bg_ptr = Arc::as_ptr(&doc.layers()[0].pixels);

    // Add an offset layer at (10, 10) of size 12x12
    let patch = Arc::new(RgbaImage::from_pixel(
        12,
        12,
        image::Rgba([100, 100, 100, 255]),
    ));
    assert!(doc
        .apply_layer_op(LayerOperation::AddImage {
            name: "Sticker".to_owned(),
            offset_x: 10,
            offset_y: 10,
            pixels: patch,
        })
        .unwrap());
    let sticker_id = doc.active_layer_id();

    // Paint in document coordinates (15, 15) -> local (5, 5) on Sticker
    assert!(doc
        .apply_with_target(
            EditOperation::Paint {
                points: vec![[15.0, 15.0]],
                color: [255, 0, 0],
                radius: 2.0,
                opacity: 1.0,
                erase: false,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    assert_eq!(doc.pixels().get_pixel(15, 15)[0], 255);
    // Background layer buffer was NEVER copied or mutated!
    assert_eq!(Arc::as_ptr(&doc.layers()[0].pixels), bg_ptr);

    // AdjustColor with ActiveLayer modifies only Sticker, not Background
    assert!(doc
        .apply_with_target(
            EditOperation::AdjustColor {
                brightness: 0.3,
                contrast: 0.0,
                saturation: 0.0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    assert_eq!(Arc::as_ptr(&doc.layers()[0].pixels), bg_ptr);
    assert_eq!(
        *doc.pixels().get_pixel(2, 2),
        image::Rgba([20, 40, 60, 255])
    );

    // Locking Sticker refuses further edits & deletion
    assert!(doc
        .apply_layer_op(LayerOperation::SetProps {
            id: sticker_id,
            name: None,
            visible: None,
            locked: Some(true),
            opacity: None,
            blend_mode: None,
            offset_x: None,
            offset_y: None,
        })
        .unwrap());
    let err = doc
        .apply_with_target(
            EditOperation::AdjustColor {
                brightness: 0.1,
                contrast: 0.0,
                saturation: 0.0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap_err();
    assert_eq!(err.code, "layer_locked");
    let del_err = doc
        .apply_layer_op(LayerOperation::Delete { id: sticker_id })
        .unwrap_err();
    assert_eq!(del_err.code, "layer_locked");

    // Unlock and hide -> ActiveLayer edit refuses hidden layer
    assert!(doc
        .apply_layer_op(LayerOperation::SetProps {
            id: sticker_id,
            name: None,
            visible: Some(false),
            locked: Some(false),
            opacity: None,
            blend_mode: None,
            offset_x: None,
            offset_y: None,
        })
        .unwrap());
    let hid_err = doc
        .apply_with_target(
            EditOperation::AdjustColor {
                brightness: 0.1,
                contrast: 0.0,
                saturation: 0.0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap_err();
    assert_eq!(hid_err.code, "layer_hidden");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn whole_image_geometry_transforms_keep_multilayer_alignment_exact() {
    let dir = temp_dir();
    // 20x10 dark canvas with a 4x4 bright green block at top-left (0, 0)
    let bg = RgbaImage::from_pixel(20, 10, image::Rgba([10, 10, 10, 255]));
    let mut doc = EditorDocument::from_image(dir.join("geom.png"), bg);
    let block = Arc::new(RgbaImage::from_pixel(4, 4, image::Rgba([0, 255, 0, 255])));
    assert!(doc
        .apply_layer_op(LayerOperation::AddImage {
            name: "Corner".to_owned(),
            offset_x: 0,
            offset_y: 0,
            pixels: block,
        })
        .unwrap());

    // Rotate 90° CW: 20x10 -> 10x20, top-left (0,0) block moves to top-right (6..10, 0..4)
    assert!(doc
        .apply_with_target(
            EditOperation::Rotate { degrees: 90 },
            ApplyTarget::WholeImage
        )
        .unwrap());
    assert_eq!(doc.dimensions(), (10, 20));
    assert_eq!(*doc.pixels().get_pixel(8, 2), image::Rgba([0, 255, 0, 255]));
    assert_eq!(
        *doc.pixels().get_pixel(2, 2),
        image::Rgba([10, 10, 10, 255])
    );

    // Flip horizontal: top-right (6..10, 0..4) moves back to top-left (0..4, 0..4)
    assert!(doc
        .apply_with_target(
            EditOperation::Flip {
                axis: FlipAxis::Horizontal,
            },
            ApplyTarget::WholeImage,
        )
        .unwrap());
    assert_eq!(*doc.pixels().get_pixel(2, 2), image::Rgba([0, 255, 0, 255]));
    assert_eq!(
        *doc.pixels().get_pixel(8, 2),
        image::Rgba([10, 10, 10, 255])
    );

    // Undo both restores exact 20x10 alignment
    assert!(doc.undo());
    assert!(doc.undo());
    assert_eq!(doc.dimensions(), (20, 10));
    assert_eq!(*doc.pixels().get_pixel(2, 2), image::Rgba([0, 255, 0, 255]));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn new_layer_target_and_stack_ops_undo_redo_and_reset_cleanly() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(16, 16, image::Rgba([30, 30, 30, 255]));
    let mut doc = EditorDocument::from_image(dir.join("stack.png"), bg);

    // Cannot delete last remaining layer
    let last_id = doc.active_layer_id();
    assert_eq!(
        doc.apply_layer_op(LayerOperation::Delete { id: last_id })
            .unwrap_err()
            .code,
        "cannot_delete_last_layer"
    );

    // Apply AI result as NewLayer (non-destructive)
    let ai_px = Arc::new(RgbaImage::from_pixel(
        16,
        16,
        image::Rgba([255, 200, 0, 255]),
    ));
    assert!(doc
        .apply_with_target(
            EditOperation::AiResult {
                label: UiText::new("remove_watermark"),
                pixels: ai_px,
            },
            ApplyTarget::NewLayer,
        )
        .unwrap());
    assert_eq!(doc.layers().len(), 2);
    assert_eq!(
        *doc.pixels().get_pixel(0, 0),
        image::Rgba([255, 200, 0, 255])
    );

    // Duplicate -> 3 layers, MergeDown -> 2 layers, Flatten -> 1 layer
    let top_id = doc.active_layer_id();
    assert!(doc
        .apply_layer_op(LayerOperation::Duplicate { id: top_id })
        .unwrap());
    assert_eq!(doc.layers().len(), 3);
    let dup_id = doc.active_layer_id();
    assert!(doc
        .apply_layer_op(LayerOperation::MergeDown { id: dup_id })
        .unwrap());
    assert_eq!(doc.layers().len(), 2);
    assert!(doc.apply_layer_op(LayerOperation::Flatten).unwrap());
    assert_eq!(doc.layers().len(), 1);

    // Undo Flatten -> 2 layers, Redo Flatten -> 1 layer
    assert!(doc.undo());
    assert_eq!(doc.layers().len(), 2);
    assert!(doc.redo());
    assert_eq!(doc.layers().len(), 1);

    // Reset restores initial 1-layer original pixels
    assert!(doc.reset());
    assert_eq!(doc.layers().len(), 1);
    assert_eq!(
        *doc.pixels().get_pixel(0, 0),
        image::Rgba([30, 30, 30, 255])
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn apply_target_active_layer_whole_image_and_new_layer_semantics() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(16, 16, image::Rgba([40, 40, 40, 255]));
    let path = dir.join("targets.png");
    bg.save(&path).unwrap();
    let mut doc = EditorDocument::from_image(path, bg);

    // Add a second layer with a bright red patch on the left half, transparent on the right.
    let mut top_px = RgbaImage::from_pixel(16, 16, image::Rgba([0, 0, 0, 0]));
    for y in 0..16 {
        for x in 0..8 {
            top_px.put_pixel(x, y, image::Rgba([200, 20, 20, 255]));
        }
    }
    doc.apply_layer_op(LayerOperation::AddImage {
        name: "RedLeft".into(),
        offset_x: 0,
        offset_y: 0,
        pixels: Arc::new(top_px),
    })
    .unwrap();
    let top_id = doc.active_layer_id();

    // 1. Flip Horizontal with ApplyTarget::ActiveLayer moves RedLeft to the right half
    //    without touching Background (still [40, 40, 40, 255] on left).
    assert!(doc
        .apply_with_target(
            EditOperation::Flip {
                axis: FlipAxis::Horizontal,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    assert_eq!(
        *doc.pixels().get_pixel(12, 8),
        image::Rgba([200, 20, 20, 255])
    );
    assert_eq!(
        *doc.pixels().get_pixel(2, 8),
        image::Rgba([40, 40, 40, 255])
    );

    // 2. AdjustColor with ApplyTarget::ActiveLayer brightens RedLeft only; Background stays 40.
    assert!(doc
        .apply_with_target(
            EditOperation::AdjustColor {
                brightness: 0.4,
                contrast: 0.0,
                saturation: 0.0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    assert_eq!(doc.layers()[0].pixels.get_pixel(2, 8).0[0], 40);
    assert!(doc.active_layer().pixels.get_pixel(12, 8).0[0] > 200);

    // 3. AdjustColor with ApplyTarget::WholeImage brightens BOTH layers.
    assert!(doc
        .apply_with_target(
            EditOperation::AdjustColor {
                brightness: 0.25,
                contrast: 0.0,
                saturation: 0.0,
            },
            ApplyTarget::WholeImage,
        )
        .unwrap());
    assert!(doc.layers()[0].pixels.get_pixel(2, 8).0[0] > 40);

    // 4. Locked active layer refuses ActiveLayer edit; hidden layer refuses ActiveLayer edit.
    doc.apply_layer_op(LayerOperation::SetProps {
        id: top_id,
        name: None,
        visible: None,
        locked: Some(true),
        opacity: None,
        blend_mode: None,
        offset_x: None,
        offset_y: None,
    })
    .unwrap();
    assert_eq!(
        doc.apply_with_target(
            EditOperation::Flip {
                axis: FlipAxis::Vertical,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap_err()
        .code,
        "layer_locked"
    );
    doc.apply_layer_op(LayerOperation::SetProps {
        id: top_id,
        name: None,
        visible: Some(false),
        locked: Some(false),
        opacity: None,
        blend_mode: None,
        offset_x: None,
        offset_y: None,
    })
    .unwrap();
    assert_eq!(
        doc.apply_with_target(
            EditOperation::Flip {
                axis: FlipAxis::Vertical,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap_err()
        .code,
        "layer_hidden"
    );

    // 5. Remove Background with ApplyTarget::NewLayer creates a "Cutout" layer
    //    and preserves the pre-cutout composited image as `layer.original`.
    let before_cutout = doc.pixels();
    let cutout = Arc::new(RgbaImage::from_pixel(16, 16, image::Rgba([0, 255, 0, 128])));
    assert!(doc
        .apply_with_target(
            EditOperation::AiResult {
                label: UiText::with("remove_background", ["u2net".to_owned()]),
                pixels: cutout,
            },
            ApplyTarget::NewLayer,
        )
        .unwrap());
    assert_eq!(doc.layers().len(), 3);
    assert_eq!(doc.active_layer().name, "Cutout");
    assert_eq!(
        doc.active_layer_original_pixels().as_raw(),
        before_cutout.as_raw()
    );

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn ora_round_trips_multilayer_stack_and_kra_preview_decodes() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(24, 16, image::Rgba([20, 40, 80, 255]));
    let src_png = dir.join("base.png");
    bg.save(&src_png).unwrap();

    let mut doc = EditorDocument::from_image(src_png.clone(), bg);
    let overlay_px = RgbaImage::from_pixel(10, 8, image::Rgba([200, 100, 50, 180]));
    doc.apply_layer_op(LayerOperation::AddImage {
        name: "Layer & \"Top\"".into(),
        offset_x: 5,
        offset_y: 3,
        pixels: Arc::new(overlay_px),
    })
    .unwrap();
    let top_id = doc.active_layer_id();
    doc.apply_layer_op(LayerOperation::SetProps {
        id: top_id,
        name: None,
        visible: Some(true),
        locked: None,
        opacity: Some(0.75),
        blend_mode: Some(BlendMode::Multiply),
        offset_x: None,
        offset_y: None,
    })
    .unwrap();

    // Save as OpenRaster (.ora)
    let ora_path = dir.join("layered.ora");
    save_stack(&src_png, doc.stack(), &ora_path).unwrap();
    assert!(has_decoder(&ora_path));
    assert_eq!(read_zip_dimensions(&ora_path), Some((24, 16)));

    // Verify OpenRaster mimetype entry is first and stored uncompressed
    let raw_file = std::fs::File::open(&ora_path).unwrap();
    let mut zip = zip::ZipArchive::new(raw_file).unwrap();
    {
        let first = zip.by_index(0).unwrap();
        assert_eq!(first.name(), "mimetype");
        assert_eq!(first.compression(), zip::CompressionMethod::Stored);
    }
    assert!(zip.by_name("mergedimage.png").is_ok());
    assert!(zip.by_name("Thumbnails/thumbnail.png").is_ok());
    drop(zip);

    // Re-open via open_document -> restores full 2-layer stack losslessly
    let reopened = open_document(&ora_path).unwrap();
    assert_eq!(reopened.dimensions(), (24, 16));
    assert_eq!(reopened.layers().len(), 2);
    assert_eq!(reopened.layers()[0].name, "Background");
    assert_eq!(reopened.layers()[1].name, "Layer & \"Top\"");
    assert_eq!(reopened.layers()[1].offset_x, 5);
    assert_eq!(reopened.layers()[1].offset_y, 3);
    assert!((reopened.layers()[1].opacity - 0.75).abs() < 0.01);
    assert_eq!(reopened.layers()[1].blend_mode, BlendMode::Multiply);
    assert_eq!(reopened.pixels().as_raw(), doc.pixels().as_raw());

    // Copy .ora bytes to a .kra path (same ZIP + mergedimage.png structure) and
    // verify Browser/Viewer preview decode works cleanly.
    let kra_path = dir.join("artwork.kra");
    std::fs::copy(&ora_path, &kra_path).unwrap();
    assert!(has_decoder(&kra_path));
    assert_eq!(read_zip_dimensions(&kra_path), Some((24, 16)));
    let kra_img = decode_rgba(&kra_path).unwrap();
    assert_eq!(kra_img.dimensions(), (24, 16));
    assert_eq!(kra_img.as_raw(), doc.pixels().as_raw());

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn paste_modes_and_active_layer_free_transform_resize_and_undo_cleanly() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(100, 80, image::Rgba([20, 20, 20, 255]));
    let src_png = dir.join("canvas.png");
    bg.save(&src_png).unwrap();

    // Oversized pasted image (400 × 200 -> 2:1 aspect)
    let big = RgbaImage::from_pixel(400, 200, image::Rgba([255, 0, 0, 255]));

    // 1. FitToCanvas scales 400×200 down to 100×50 centered at (0, 15)
    let mut doc_fit = EditorDocument::from_image(src_png.clone(), bg.clone());
    assert!(doc_fit
        .paste_image_with_mode(
            "Fitted".into(),
            big.clone(),
            kogaview_protocol::PasteMode::FitToCanvas,
        )
        .unwrap());
    assert_eq!(doc_fit.dimensions(), (100, 80));
    assert_eq!(doc_fit.active_layer().dimensions(), (100, 50));
    assert_eq!(doc_fit.active_layer().offset_x, 0);
    assert_eq!(doc_fit.active_layer().offset_y, 15);

    // 2. ExpandCanvas expands canvas to 400×200, centers old Background at (150, 60),
    //    and 1 Undo restores both canvas size (100×80) and layer count (1)!
    let mut doc_exp = EditorDocument::from_image(src_png.clone(), bg.clone());
    assert!(doc_exp
        .paste_image_with_mode(
            "Expanded".into(),
            big.clone(),
            kogaview_protocol::PasteMode::ExpandCanvas,
        )
        .unwrap());
    assert_eq!(doc_exp.dimensions(), (400, 200));
    assert_eq!(doc_exp.layers()[0].offset_x, 150);
    assert_eq!(doc_exp.layers()[0].offset_y, 60);
    assert_eq!(doc_exp.active_layer().dimensions(), (400, 200));
    assert!(doc_exp.undo());
    assert_eq!(doc_exp.dimensions(), (100, 80));
    assert_eq!(doc_exp.layers().len(), 1);
    assert_eq!(doc_exp.layers()[0].offset_x, 0);
    assert_eq!(doc_exp.layers()[0].offset_y, 0);

    // 3. KeepOriginal keeps 400×200 at (-150, -60), and FreeTransform on ActiveLayer
    //    shrinks it cleanly to 80×40 at (10, 20) without clipping overflow!
    let mut doc_keep = EditorDocument::from_image(src_png, bg);
    assert!(doc_keep
        .paste_image_with_mode(
            "Kept".into(),
            big,
            kogaview_protocol::PasteMode::KeepOriginal,
        )
        .unwrap());
    assert_eq!(doc_keep.dimensions(), (100, 80));
    assert_eq!(doc_keep.active_layer().dimensions(), (400, 200));
    assert_eq!(doc_keep.active_layer().offset_x, -150);
    assert_eq!(doc_keep.active_layer().offset_y, -60);

    assert!(doc_keep
        .apply_with_target(
            EditOperation::FreeTransform {
                x: 10,
                y: 20,
                width: 80,
                height: 40,
                rotation: 0.0,
                fill: None,
                fill_alpha: 0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    assert_eq!(doc_keep.active_layer().dimensions(), (80, 40));
    assert_eq!(doc_keep.active_layer().offset_x, 10);
    assert_eq!(doc_keep.active_layer().offset_y, 20);
    // Pixel inside transformed layer is red; pixel outside (0,0) shows Background.
    assert_eq!(
        *doc_keep.pixels().get_pixel(50, 40),
        image::Rgba([255, 0, 0, 255])
    );
    assert_eq!(
        *doc_keep.pixels().get_pixel(0, 0),
        image::Rgba([20, 20, 20, 255])
    );

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn selection_mask_shapes_combine_paint_masking_and_actions() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(32, 32, image::Rgba([30, 40, 50, 255]));
    let src = dir.join("sel.png");
    bg.save(&src).unwrap();
    let mut doc = EditorDocument::from_image(src, bg);

    // 1. Rect selection [4..20, 4..20] -> Brush stroke across entire row y=10
    //    must paint ONLY inside x in [4..20), leaving x=1 and x=28 untouched!
    let rect = SelectionMask::rect(32, 32, 4, 4, 16, 16);
    doc.apply_selection_mask(rect, kogaview_protocol::SelectionMode::Replace, 0);
    assert_eq!(doc.selection_bounds(), Some([4, 4, 16, 16]));

    doc.apply(EditOperation::Paint {
        points: vec![[1.0, 10.0], [28.0, 10.0]],
        color: [255, 0, 0],
        radius: 3.0,
        opacity: 1.0,
        erase: false,
    })
    .unwrap();
    assert_eq!(
        *doc.pixels().get_pixel(10, 10),
        image::Rgba([255, 0, 0, 255])
    );
    assert_eq!(
        *doc.pixels().get_pixel(1, 10),
        image::Rgba([30, 40, 50, 255])
    );
    assert_eq!(
        *doc.pixels().get_pixel(28, 10),
        image::Rgba([30, 40, 50, 255])
    );

    // 2. Duplicate selection to new layer (Ctrl+J) creates 16×16 layer at (4, 4)
    assert!(doc.selection_duplicate_layer().unwrap());
    assert_eq!(doc.layers().len(), 2);
    assert_eq!(doc.active_layer().name, "Selection Copy");
    assert_eq!(doc.active_layer().dimensions(), (16, 16));
    assert_eq!(doc.active_layer().offset_x, 4);
    assert_eq!(doc.active_layer().offset_y, 4);

    // 3. Selection Fill paints blue inside selection on active layer
    assert!(doc.selection_fill([0, 0, 255], 1.0).unwrap());
    assert_eq!(
        *doc.pixels().get_pixel(10, 10),
        image::Rgba([0, 0, 255, 255])
    );

    // 4. Selection Delete clears alpha inside selection on active layer
    assert!(doc.selection_delete().unwrap());
    assert_eq!(doc.active_layer().pixels.get_pixel(6, 6).0[3], 0);

    // 5. Lasso polygon + Feather + Overlay PNG
    let tri = SelectionMask::polygon(32, 32, &[[2.0, 2.0], [30.0, 2.0], [16.0, 30.0]]);
    doc.apply_selection_mask(tri, kogaview_protocol::SelectionMode::Replace, 2);
    assert!(doc.selection().is_some());
    let overlay_path = dir.join("sel-overlay.png");
    doc.selection()
        .unwrap()
        .render_overlay_png(&overlay_path)
        .unwrap();
    assert!(overlay_path.is_file());

    // 6. Crop to selection shrinks canvas and clears selection
    let rect2 = SelectionMask::rect(32, 32, 8, 8, 12, 10);
    doc.apply_selection_mask(rect2, kogaview_protocol::SelectionMode::Replace, 0);
    assert!(doc.selection_crop().unwrap());
    assert_eq!(doc.dimensions(), (12, 10));
    assert!(doc.selection().is_none());

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn magic_wand_selection_copy_and_adjust_color_masking() {
    let dir = temp_dir();
    // 20×10 image: left block [0..8) red, middle barrier [8..12) blue, right block [12..20) red.
    let mut img = RgbaImage::from_pixel(20, 10, image::Rgba([200, 40, 40, 255]));
    for y in 0..10 {
        for x in 8..12 {
            img.put_pixel(x, y, image::Rgba([30, 60, 220, 255]));
        }
    }
    let src = dir.join("wand.png");
    img.save(&src).unwrap();
    let mut doc = EditorDocument::from_image(src, img);

    // 1. Contiguous Magic Wand at (2, 5) selects ONLY left red block [0..8, 0..10]
    doc.select_magic_wand(
        2,
        5,
        10,
        true,
        true,
        kogaview_protocol::SelectionMode::Replace,
        0,
    );
    assert_eq!(doc.selection_bounds(), Some([0, 0, 8, 10]));

    // 2. Non-contiguous Magic Wand at (2, 5) selects BOTH left & right red blocks [0..20, 0..10]
    //    while skipping the blue barrier at x=10.
    doc.select_magic_wand(
        2,
        5,
        10,
        false,
        true,
        kogaview_protocol::SelectionMode::Replace,
        0,
    );
    assert_eq!(doc.selection_bounds(), Some([0, 0, 20, 10]));
    assert_eq!(doc.selection().unwrap().alpha_at(10, 5), 0);
    assert_eq!(doc.selection().unwrap().alpha_at(15, 5), 255);

    // 3. Extract selection image for clipboard copy masks out the unselected blue barrier
    let extracted = doc.extract_selection_image().unwrap();
    assert_eq!(extracted.dimensions(), (20, 10));
    assert_eq!(extracted.get_pixel(2, 5).0[3], 255);
    assert_eq!(extracted.get_pixel(10, 5).0[3], 0);
    assert_eq!(extracted.get_pixel(15, 5).0[3], 255);

    // 4. AdjustColor respects active selection: brightens red blocks, leaves blue barrier untouched!
    doc.apply(EditOperation::AdjustColor {
        brightness: 0.4,
        contrast: 0.0,
        saturation: 0.0,
    })
    .unwrap();
    assert!(
        doc.pixels().get_pixel(2, 5).0[0] > 200,
        "selected pixel should brighten"
    );
    assert_eq!(
        *doc.pixels().get_pixel(10, 5),
        image::Rgba([30, 60, 220, 255]),
        "unselected pixel must remain untouched by AdjustColor"
    );

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn free_transform_with_selection_floats_rotates_composites_and_undoes() {
    let dir = temp_dir();
    let mut img = RgbaImage::from_pixel(32, 32, image::Rgba([40, 40, 40, 255]));
    for y in 4..12 {
        for x in 4..12 {
            img.put_pixel(x, y, image::Rgba([255, 0, 0, 255]));
        }
    }
    let src = dir.join("sel-transform.png");
    img.save(&src).unwrap();
    let mut doc = EditorDocument::from_image(src, img);

    let sel = SelectionMask::rect(32, 32, 4, 4, 8, 8);
    doc.apply_selection_mask(sel, kogaview_protocol::SelectionMode::Replace, 0);

    // Move + scale + rotate the selected red square to (16, 12, 10x10, 90 deg)
    assert!(doc
        .apply_with_target(
            EditOperation::FreeTransform {
                x: 16,
                y: 12,
                width: 10,
                height: 10,
                rotation: 90.0,
                fill: None,
                fill_alpha: 0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());

    // Original spot was cut (transparent)
    assert_eq!(doc.pixels().get_pixel(8, 8).0[3], 0);
    // Destination spot received the red patch
    assert_eq!(
        *doc.pixels().get_pixel(20, 16),
        image::Rgba([255, 0, 0, 255])
    );
    // Unselected background pixel is completely untouched
    assert_eq!(
        *doc.pixels().get_pixel(1, 1),
        image::Rgba([40, 40, 40, 255])
    );
    // Selection mask moved to the new region
    assert_eq!(doc.selection_bounds(), Some([16, 12, 10, 10]));

    // 1 Undo restores the original red square at (8, 8)
    assert!(doc.undo());
    assert_eq!(*doc.pixels().get_pixel(8, 8), image::Rgba([255, 0, 0, 255]));
    assert_eq!(
        *doc.pixels().get_pixel(20, 16),
        image::Rgba([40, 40, 40, 255])
    );

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn paste_into_empty_layer_reuses_it_and_split_previews_isolate_active_layer() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(20, 20, image::Rgba([10, 20, 30, 255]));
    let src = dir.join("split.png");
    bg.save(&src).unwrap();
    let mut doc = EditorDocument::from_image(src, bg);

    // Add an empty layer (Layer 2) then paste a 10x10 red image: should reuse Layer 2
    assert!(doc
        .apply_layer_op(LayerOperation::AddEmpty {
            name: String::new(),
        })
        .unwrap());
    assert_eq!(doc.layers().len(), 2);
    let red = RgbaImage::from_pixel(10, 10, image::Rgba([220, 40, 40, 255]));
    assert!(doc
        .paste_image_with_mode(
            "Pasted Red".to_owned(),
            red,
            kogaview_protocol::PasteMode::KeepOriginal
        )
        .unwrap());
    assert_eq!(
        doc.layers().len(),
        2,
        "pasting onto an empty layer should fill it instead of spawning a stray layer"
    );
    assert_eq!(doc.active_layer().name, "Pasted Red");

    // Add a third green layer on top so we have 3 layers: Background, Pasted Red (active), Green
    let green = RgbaImage::from_pixel(6, 6, image::Rgba([40, 220, 40, 255]));
    assert!(doc
        .paste_image_with_mode(
            "Pasted Green".to_owned(),
            green,
            kogaview_protocol::PasteMode::KeepOriginal
        )
        .unwrap());
    assert_eq!(doc.layers().len(), 3);
    let mid_id = doc.layers()[1].id;
    doc.select_layer(mid_id).unwrap();

    // Split previews for middle layer must isolate below (bg), active (red), above (green)
    let (below, active, above) = doc.active_layer_split_previews();
    assert_eq!(*below.get_pixel(0, 0), image::Rgba([10, 20, 30, 255]));
    assert_eq!(active.dimensions(), (10, 10));
    assert_eq!(*active.get_pixel(0, 0), image::Rgba([220, 40, 40, 255]));
    assert_eq!(above.get_pixel(0, 0).0[3], 0);
    assert_eq!(*above.get_pixel(10, 10), image::Rgba([40, 220, 40, 255]));

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn multilayer_canvas_size_fills_bottom_layer_when_opaque_and_keeps_transparent_when_alpha_zero() {
    let dir = temp_dir();
    let bg = RgbaImage::from_pixel(10, 10, image::Rgba([20, 30, 40, 255]));
    let src = dir.join("bg-expand.png");
    bg.save(&src).unwrap();
    let mut doc = EditorDocument::from_image(src, bg);

    // Add a second layer on top
    let top = RgbaImage::from_pixel(4, 4, image::Rgba([200, 50, 50, 255]));
    doc.paste_image_with_mode(
        "Top".to_owned(),
        top,
        kogaview_protocol::PasteMode::KeepOriginal,
    )
    .unwrap();
    assert_eq!(doc.layers().len(), 2);

    // 1. Expand canvas to 20x20 with opaque white fill -> corner (0, 0) becomes white, 2 layers preserved
    doc.apply(EditOperation::CanvasSize {
        width: 20,
        height: 20,
        anchor: "center".to_owned(),
        fill: Some([255, 255, 255]),
        fill_alpha: 255,
    })
    .unwrap();
    assert_eq!(doc.layers().len(), 2);
    assert_eq!(
        *doc.pixels().get_pixel(0, 0),
        image::Rgba([255, 255, 255, 255])
    );
    assert_eq!(
        *doc.pixels().get_pixel(10, 10),
        image::Rgba([200, 50, 50, 255])
    );

    // 2. Undo and expand with transparent fill_alpha=0 -> corner (0, 0) stays transparent
    assert!(doc.undo());
    doc.apply(EditOperation::CanvasSize {
        width: 20,
        height: 20,
        anchor: "center".to_owned(),
        fill: None,
        fill_alpha: 0,
    })
    .unwrap();
    assert_eq!(doc.pixels().get_pixel(0, 0).0[3], 0);

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn canvas_background_toggles_between_transparent_and_solid_with_undo_and_split_previews() {
    let dir = temp_dir();
    let path = dir.join("sprite.png");
    let mut img = image::RgbaImage::from_pixel(16, 16, image::Rgba([0, 0, 0, 0]));
    for y in 4..12 {
        for x in 4..12 {
            img.put_pixel(x, y, image::Rgba([220, 40, 40, 255]));
        }
    }
    img.save(&path).unwrap();

    let mut doc = EditorDocument::from_image(path, img);
    assert_eq!(doc.canvas_background(), None);
    assert_eq!(doc.pixels().get_pixel(0, 0).0, [0, 0, 0, 0]);
    assert_eq!(doc.pixels().get_pixel(8, 8).0, [220, 40, 40, 255]);

    // Enable solid white canvas background underneath the single layer.
    assert!(doc
        .apply_layer_op(LayerOperation::SetCanvasBackground {
            color: Some([255, 255, 255]),
        })
        .unwrap());
    assert_eq!(doc.canvas_background(), Some([255, 255, 255]));
    assert_eq!(doc.pixels().get_pixel(0, 0).0, [255, 255, 255, 255]);
    assert_eq!(doc.pixels().get_pixel(8, 8).0, [220, 40, 40, 255]);

    // Split previews on a single-layer doc expose the solid background in `below`
    // and the layer's own transparent pixels in `active`.
    let (below, active, above) = doc.active_layer_split_previews();
    assert_eq!(below.get_pixel(0, 0).0, [255, 255, 255, 255]);
    assert_eq!(active.get_pixel(0, 0).0, [0, 0, 0, 0]);
    assert_eq!(active.get_pixel(8, 8).0, [220, 40, 40, 255]);
    assert_eq!(above.get_pixel(0, 0).0[3], 0);

    // Undo restores transparent canvas background.
    assert!(doc.undo());
    assert_eq!(doc.canvas_background(), None);
    assert_eq!(doc.pixels().get_pixel(0, 0).0[3], 0);

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn selection_split_previews_separate_base_and_floating_patch() {
    let dir = temp_dir();
    let path = dir.join("solid.png");
    let img = image::RgbaImage::from_pixel(20, 20, image::Rgba([30, 120, 210, 255]));
    img.save(&path).unwrap();

    let mut doc = EditorDocument::from_image(path, img);
    let mask = SelectionMask::rect(20, 20, 5, 6, 8, 7);
    doc.apply_selection_mask(mask, kogaview_protocol::SelectionMode::Replace, 0);

    let (base, floating) = doc.selection_split_previews().expect("selection split");
    assert_eq!(floating.dimensions(), (8, 7));
    assert_eq!(floating.get_pixel(0, 0).0, [30, 120, 210, 255]);
    // Selected hole in base is punched out (transparent), outside remains opaque.
    assert_eq!(base.get_pixel(6, 7).0[3], 0);
    assert_eq!(base.get_pixel(0, 0).0, [30, 120, 210, 255]);

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn rotate_and_flip_with_selection_transform_only_selected_region_and_mask() {
    let dir = temp_dir();
    let path = dir.join("sel-rot.png");
    let mut img = image::RgbaImage::from_pixel(30, 20, image::Rgba([20, 20, 20, 255]));
    // Paint a non-square 8x4 red bar at (10..18, 8..12) with bright green left half.
    for y in 8..12 {
        for x in 10..18 {
            let px = if x < 14 {
                image::Rgba([0, 255, 0, 255])
            } else {
                image::Rgba([255, 0, 0, 255])
            };
            img.put_pixel(x, y, px);
        }
    }
    img.save(&path).unwrap();

    let mut doc = EditorDocument::from_image(path, img);
    doc.apply_selection_mask(
        SelectionMask::rect(30, 20, 10, 8, 8, 4),
        kogaview_protocol::SelectionMode::Replace,
        0,
    );

    // 1. Flip horizontally: green (left) and red (right) swap inside (10..18, 8..12), canvas stays 30x20!
    doc.apply_with_target(
        EditOperation::Flip {
            axis: FlipAxis::Horizontal,
        },
        ApplyTarget::WholeImage,
    )
    .unwrap();
    assert_eq!(doc.dimensions(), (30, 20));
    assert_eq!(doc.selection_bounds(), Some([10, 8, 8, 4]));
    assert_eq!(doc.pixels().get_pixel(11, 9).0, [255, 0, 0, 255]);
    assert_eq!(doc.pixels().get_pixel(16, 9).0, [0, 255, 0, 255]);

    // 2. Rotate 90° CW: 8x4 selection becomes 4x8 centered at (12, 6), canvas still 30x20!
    doc.apply_with_target(
        EditOperation::Rotate { degrees: 90 },
        ApplyTarget::WholeImage,
    )
    .unwrap();
    assert_eq!(doc.dimensions(), (30, 20));
    assert_eq!(doc.selection_bounds(), Some([12, 6, 4, 8]));
    // Original left/right overhanging ends of 8x4 were punched out to transparent.
    assert_eq!(doc.pixels().get_pixel(10, 9).0[3], 0);
    // Top half of rotated 4x8 bar is now red (was left half before 90° CW).
    assert_eq!(doc.pixels().get_pixel(13, 7).0, [255, 0, 0, 255]);

    // 3. Clear selection and rotate 90° CW on WholeImage -> whole canvas swaps 30x20 -> 20x30!
    doc.clear_selection();
    doc.apply_with_target(
        EditOperation::Rotate { degrees: 90 },
        ApplyTarget::WholeImage,
    )
    .unwrap();
    assert_eq!(doc.dimensions(), (20, 30));

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn adjust_curves_respects_channels_active_layer_selection_and_preview() {
    let dir = temp_dir();
    let path = dir.join("curves.png");
    let bg = image::RgbaImage::from_pixel(16, 16, image::Rgba([100, 100, 100, 255]));
    bg.save(&path).unwrap();

    let mut doc = EditorDocument::from_image(path, bg);
    let top = image::RgbaImage::from_pixel(16, 16, image::Rgba([128, 128, 128, 255]));
    doc.paste_image_with_mode(
        "Top".to_owned(),
        top,
        kogaview_protocol::PasteMode::KeepOriginal,
    )
    .unwrap();
    // Select left half (0..8, 0..16)
    doc.apply_selection_mask(
        SelectionMask::rect(16, 16, 0, 0, 8, 16),
        kogaview_protocol::SelectionMode::Replace,
        0,
    );

    // Boost red channel at midpoint (0.5 -> 0.85), leave green/blue linear.
    let op = EditOperation::AdjustCurves {
        rgb: vec![[0.0, 0.0], [1.0, 1.0]],
        red: vec![[0.0, 0.0], [0.5, 0.85], [1.0, 1.0]],
        green: vec![[0.0, 0.0], [1.0, 1.0]],
        blue: vec![[0.0, 0.0], [1.0, 1.0]],
    };

    // 1. Live preview reflects boosted red ONLY inside selection without mutating doc
    let prev = doc.preview_color_filter(&op, ApplyTarget::ActiveLayer);
    assert!(prev.get_pixel(2, 2).0[0] > 200);
    assert_eq!(prev.get_pixel(12, 2).0[0], 128);
    assert_eq!(doc.pixels().get_pixel(2, 2).0[0], 128);

    // 2. Apply on ActiveLayer modifies Top inside selection, leaves Background & outside untouched
    assert!(doc.apply_with_target(op, ApplyTarget::ActiveLayer).unwrap());
    assert!(doc.pixels().get_pixel(2, 2).0[0] > 200);
    assert_eq!(doc.pixels().get_pixel(2, 2).0[1], 128);
    assert_eq!(doc.pixels().get_pixel(12, 2).0[0], 128);
    assert_eq!(doc.layers()[0].pixels.get_pixel(2, 2).0[0], 100);

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn selection_move_and_intersect_work_without_mutating_pixels() {
    let dir = temp_dir();
    let path = dir.join("sel-move.png");
    let img = image::RgbaImage::from_pixel(30, 30, image::Rgba([50, 100, 150, 255]));
    img.save(&path).unwrap();

    let mut doc = EditorDocument::from_image(path, img);
    doc.apply_selection_mask(
        SelectionMask::rect(30, 30, 4, 4, 10, 10),
        kogaview_protocol::SelectionMode::Replace,
        0,
    );
    assert_eq!(doc.selection_bounds(), Some([4, 4, 10, 10]));

    // Move selection frame by (+6, +3) -> bounds shift to (10, 7, 10, 10), pixels untouched
    assert!(doc.move_selection(6, 3));
    assert_eq!(doc.selection_bounds(), Some([10, 7, 10, 10]));
    assert!(!doc.can_undo());

    // Intersect with (15, 10, 10, 10) -> overlap is (15..20, 10..17) => [15, 10, 5, 7]
    doc.apply_selection_mask(
        SelectionMask::rect(30, 30, 15, 10, 10, 10),
        kogaview_protocol::SelectionMode::Intersect,
        0,
    );
    assert_eq!(doc.selection_bounds(), Some([15, 10, 5, 7]));

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn adjust_hsv_and_color_balance_respect_selection_and_layers() {
    let dir = temp_dir();
    let path = dir.join("hsv-cb.png");
    let img = image::RgbaImage::from_pixel(16, 16, image::Rgba([200, 50, 50, 255]));
    img.save(&path).unwrap();

    let mut doc = EditorDocument::from_image(path, img);
    doc.apply_selection_mask(
        SelectionMask::rect(16, 16, 0, 0, 8, 16),
        kogaview_protocol::SelectionMode::Replace,
        0,
    );

    // 1. HSV hue shift +120° turns red (200, 50, 50) into green inside selection only
    assert!(doc
        .apply_with_target(
            EditOperation::AdjustHsv {
                hue: 120.0,
                saturation: 0.0,
                value: 0.0,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    let inside = doc.pixels().get_pixel(2, 2).0;
    let outside = doc.pixels().get_pixel(12, 2).0;
    assert!(inside[1] > inside[0] && inside[1] > 180);
    assert_eq!(outside, [200, 50, 50, 255]);

    // 2. Color balance boosts blue in midtones inside selection only
    assert!(doc
        .apply_with_target(
            EditOperation::ColorBalance {
                shadows: [0.0, 0.0, 0.0],
                midtones: [0.0, 0.0, 0.8],
                highlights: [0.0, 0.0, 0.0],
                preserve_luminosity: false,
            },
            ApplyTarget::ActiveLayer,
        )
        .unwrap());
    assert!(doc.pixels().get_pixel(2, 2).0[2] > inside[2]);
    assert_eq!(doc.pixels().get_pixel(12, 2).0, [200, 50, 50, 255]);

    std::fs::remove_dir_all(&dir).unwrap();
}
