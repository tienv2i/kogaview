//! The batch worker and the input set it runs over.

use super::*;

/// A batch is one typed job: the counts it publishes, the files it writes
/// and the source it must not touch are all one assertion each.
#[test]
fn a_batch_resize_writes_beside_the_source_and_keeps_it() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let mut core = Core::for_test(&base.join("runtime"));
    let source = serde_json::to_string(&photo.to_string_lossy()).unwrap();

    let response = dispatch_json(
        &mut core,
        "batch-1",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"resize","width":20,"height":10}},
                "source":{{"source":"selection","paths":[{source}]}},
                "output":{{"suffix":"_small"}}}}"#
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_batch(&mut core), "the batch never finished");

    let output = base.join("photo_small.png");
    assert!(output.is_file(), "the batch wrote no copy");
    assert_eq!(
        image::image_dimensions(&output).unwrap(),
        (20, 10),
        "the copy is not the target size"
    );
    assert_eq!(
        image::image_dimensions(&photo).unwrap(),
        (40, 20),
        "the source must not be resized"
    );
    let batch = core.state.batch.as_ref().expect("no batch state");
    assert_eq!((batch.done, batch.failed, batch.total), (1, 0, 1));
    assert!(!batch.running);
    assert_eq!(core.state.status.code, "batch_done");

    remove_tree(&base);
}

#[test]
fn a_batch_crop_is_proportional_to_each_image() {
    let base = temp_dir();
    write_png(&base.join("wide.png"), 40, 20);
    write_png(&base.join("square.png"), 20, 20);
    write_png(&base.join("small.png"), 8, 8);
    let mut core = Core::for_test(&base.join("runtime"));
    let folder = serde_json::to_string(&base.to_string_lossy()).unwrap();

    let response = dispatch_json(
        &mut core,
        "batch-1",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"crop","x":0,"y":0,"width":50,"height":50}},
                "source":{{"source":"folder","path":{folder}}},
                "output":{{"suffix":"_half"}}}}"#
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_batch(&mut core), "the batch never finished");

    // Half of each image's own sides: 20 × 10 from the wide one, 10 × 10
    // from the square one. A percentage crop is the only shape that can do
    // both in one job.
    assert_eq!(
        image::image_dimensions(&base.join("wide_half.png")).unwrap(),
        (20, 10)
    );
    assert_eq!(
        image::image_dimensions(&base.join("square_half.png")).unwrap(),
        (10, 10)
    );
    assert_eq!(
        image::image_dimensions(&base.join("small_half.png")).unwrap(),
        (4, 4),
        "the folder source processes every image it lists"
    );
    let batch = core.state.batch.as_ref().unwrap();
    assert_eq!((batch.done, batch.failed, batch.total), (3, 0, 3));

    remove_tree(&base);
}

#[test]
fn a_batch_convert_writes_the_new_format_and_keeps_the_original() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 12, 8);
    let mut core = Core::for_test(&base.join("runtime"));
    let source = serde_json::to_string(&photo.to_string_lossy()).unwrap();

    let response = dispatch_json(
        &mut core,
        "batch-1",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"convert","format":"jpeg","quality":80}},
                "source":{{"source":"selection","paths":[{source}]}},
                "output":{{}}}}"#
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_batch(&mut core), "the batch never finished");

    let converted = base.join("photo.jpg");
    assert!(converted.is_file(), "the conversion wrote no JPEG");
    assert!(photo.is_file(), "the PNG source must stay");
    assert_eq!(image::image_dimensions(&converted).unwrap(), (12, 8));
    // The bytes really are JPEG, not a PNG under another name.
    assert_eq!(
        image::ImageReader::open(&converted)
            .unwrap()
            .with_guessed_format()
            .unwrap()
            .format(),
        Some(image::ImageFormat::Jpeg)
    );

    remove_tree(&base);
}

#[test]
fn a_batch_refuses_to_overwrite_a_source_unless_asked() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 12, 8);
    let before = std::fs::read(&photo).unwrap();
    let mut core = Core::for_test(&base.join("runtime"));
    let source = serde_json::to_string(&photo.to_string_lossy()).unwrap();

    // An empty suffix beside the source is the one policy that would be a
    // silent overwrite, so it is refused before any worker exists.
    let response = dispatch_json(
        &mut core,
        "batch-1",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"crop","x":0,"y":0,"width":50,"height":50}},
                "source":{{"source":"selection","paths":[{source}]}},
                "output":{{}}}}"#
        ),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "output_is_source", "{response}");
    assert!(core.state.batch.is_none(), "a refused job must not publish");

    // The explicit flag is the only way to replace the original.
    let response = dispatch_json(
        &mut core,
        "batch-2",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"crop","x":0,"y":0,"width":50,"height":50}},
                "source":{{"source":"selection","paths":[{source}]}},
                "output":{{"overwrite":true}}}}"#
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_batch(&mut core), "the batch never finished");
    assert_ne!(
        std::fs::read(&photo).unwrap(),
        before,
        "the overwrite did not change the source"
    );
    assert_eq!(
        image::image_dimensions(&photo).unwrap(),
        (6, 4),
        "the overwrite is the crop, in place"
    );
    assert!(
        base.join("photo.png.bak").is_file(),
        "an overwrite keeps the previous bytes, like a save does"
    );

    remove_tree(&base);
}

/// The third destination: a folder of its own. The sources stay where they
/// are, the copies keep their names, and a folder that is not there is
/// refused before a worker starts rather than failing per file.
#[test]
fn a_batch_writes_into_another_folder() {
    let base = temp_dir();
    let wide = base.join("wide.png");
    let tall = base.join("tall.png");
    write_png(&wide, 40, 20);
    write_png(&tall, 20, 40);
    let out = base.join("out");
    std::fs::create_dir_all(&out).unwrap();
    let mut core = Core::for_test(&base.join("runtime"));
    let wide_source = serde_json::to_string(&wide.to_string_lossy()).unwrap();
    let tall_source = serde_json::to_string(&tall.to_string_lossy()).unwrap();
    let out_folder = serde_json::to_string(&out.to_string_lossy()).unwrap();

    let response = dispatch_json(
        &mut core,
        "batch-1",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"resize","width":10,"height":10}},
                "source":{{"source":"selection","paths":[{wide_source},{tall_source}]}},
                "output":{{"folder":{out_folder},"suffix":"_small"}}}}"#
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_batch(&mut core), "the batch never finished");

    for name in ["wide_small.png", "tall_small.png"] {
        let copy = out.join(name);
        assert!(copy.is_file(), "{name} was not written into the folder");
        assert_eq!(
            image::image_dimensions(&copy).unwrap(),
            (10, 10),
            "{name} is not the target size"
        );
    }
    // The copies live in the folder, not beside the sources.
    assert!(!base.join("wide_small.png").exists());
    assert_eq!(image::image_dimensions(&wide).unwrap(), (40, 20));
    assert_eq!(image::image_dimensions(&tall).unwrap(), (20, 40));

    // A folder that does not exist is a refusal with a line, not a run that
    // fails once per image.
    let missing = serde_json::to_string(&base.join("nope").to_string_lossy()).unwrap();
    let response = dispatch_json(
        &mut core,
        "batch-2",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"resize","width":10,"height":10}},
                "source":{{"source":"selection","paths":[{wide_source}]}},
                "output":{{"folder":{missing},"suffix":"_small"}}}}"#
        ),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "missing_folder", "{response}");
    assert_eq!(
        response["error"]["ui"]["code"], "batch_output_missing",
        "a rejection the interface can word"
    );

    remove_tree(&base);
}

#[test]
fn a_batch_with_nothing_to_do_is_refused_with_a_line() {
    let base = temp_dir();
    let text = base.join("notes.txt");
    std::fs::write(&text, b"not a picture").unwrap();
    let mut core = Core::for_test(&base.join("runtime"));
    let source = serde_json::to_string(&text.to_string_lossy()).unwrap();

    let response = dispatch_json(
        &mut core,
        "batch-1",
        &format!(
            r#"{{"type":"batch_run",
                "operation":{{"operation":"resize","width":10,"height":10}},
                "source":{{"source":"selection","paths":[{source}]}},
                "output":{{"suffix":"_small"}}}}"#
        ),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "no_images", "{response}");
    assert_eq!(
        response["error"]["ui"]["code"], "batch_no_images",
        "a rejection the interface can word"
    );

    remove_tree(&base);
}
