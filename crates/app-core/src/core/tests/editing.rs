//! The Editor: opening, saving, exporting, previews and the source guard.

use super::*;

/// A file the build cannot decode is refused before a worker is started:
/// `ok:true` followed by an asynchronous failure would leave the window with
/// the platform's own English sentence, and it would record an edit that
/// never happened as accepted.
#[test]
fn an_image_without_a_decoder_is_refused_with_a_line() {
    let base = temp_dir();
    let path = base.join("phone.heic");
    std::fs::write(&path, b"this is not a HEIC").unwrap();
    let mut core = Core::for_test(&base.join("runtime"));
    let response = dispatch_json(
        &mut core,
        "open-1",
        &format!(r#"{{"type":"editor_open","path":"{}"}}"#, path.display()),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "no_decoder", "{response}");
    assert_eq!(response["error"]["ui"]["code"], "no_decoder", "{response}");
    assert!(
        core.state.editor.is_none(),
        "a refused open left a document"
    );
}

#[test]
fn export_writes_a_copy_with_the_chosen_quality_and_keeps_the_document() {
    let base = temp_dir();
    let photo = base.join("photo.jpg");
    write_jpeg_with_exif(&photo, 160, 120);
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(r#"{{"type":"editor_open","path":"{}"}}"#, photo.display()),
    );
    assert!(settle_editor(&mut core), "the document never opened");

    // An edit makes `saved` false; an export must not touch that, nor move
    // the save target.
    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );
    let before = core.state.editor.clone().unwrap();
    assert!(!before.saved, "the edit must leave the document unsaved");

    let small = base.join("small.jpg");
    let large = base.join("large.jpg");
    // `plain` differs from `large` in the metadata flag only, so a size
    // comparison between `small` and `plain` measures the quality setting
    // alone — comparing against `large` would measure the APP1 segment it
    // carries as well.
    let plain = base.join("plain.jpg");
    for (path, quality, metadata, id) in [
        (&small, 20, false, "export-1"),
        (&large, 95, true, "export-2"),
        (&plain, 95, false, "export-3"),
    ] {
        let response = dispatch_json(
            &mut core,
            id,
            &format!(
                r#"{{"type":"editor_export","path":"{}","quality":{quality},"metadata":{metadata}}}"#,
                path.display()
            ),
        );
        assert_eq!(response["ok"], true, "{response}");
        assert!(
            settle_export(&mut core, path),
            "no file at {}",
            path.display()
        );
    }

    let after = core.state.editor.as_ref().unwrap();
    assert_eq!(
        after.save_path, before.save_path,
        "export moved the save target"
    );
    assert_eq!(after.saved, before.saved, "export changed the saved flag");
    assert_eq!(after.history, before.history, "export changed the history");
    assert_eq!(core.state.status.code, "exported");
    assert_eq!(core.state.status.args[0], "plain.jpg");

    let small_len = std::fs::metadata(&small).unwrap().len();
    let plain_len = std::fs::metadata(&plain).unwrap().len();
    assert!(
        small_len < plain_len,
        "quality 20 wrote {small_len} bytes, quality 95 wrote {plain_len}"
    );

    // Metadata is the caller's choice, and only JPEG carries it. The fake
    // APP1 the source holds must be in the copy that asked for it.
    let with_meta = std::fs::read(&large).unwrap();
    let without = std::fs::read(&plain).unwrap();
    assert!(
        with_meta.windows(9).any(|window| window == b"KogaViewE"),
        "the export dropped the source metadata"
    );
    assert!(
        !without.windows(9).any(|window| window == b"KogaViewE"),
        "an export that refused metadata copied it anyway"
    );

    // Exporting onto the document's own file is refused: that is Save.
    let refused = dispatch_json(
        &mut core,
        "export-3",
        &format!(r#"{{"type":"editor_export","path":"{}"}}"#, photo.display()),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["code"], "invalid_destination");
    remove_tree(&base);
}

/// A delivery size scales the copy, never the document: the export carries
/// the whole frame at a smaller long edge, the working document keeps its
/// pixels, and a limit larger than the picture is not a licence to upscale.
#[test]
fn export_scales_a_delivery_copy_and_leaves_the_document_alone() {
    let base = temp_dir();
    let photo = base.join("photo.jpg");
    write_jpeg_with_exif(&photo, 160, 120);
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(r#"{{"type":"editor_open","path":"{}"}}"#, photo.display()),
    );
    assert!(settle_editor(&mut core), "the document never opened");
    let before = core.state.editor.clone().unwrap();

    let small = base.join("phone.jpg");
    let response = dispatch_json(
        &mut core,
        "export-1",
        &format!(
            r#"{{"type":"editor_export","path":"{}","quality":90,"metadata":true,"max_edge":64}}"#,
            small.display()
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(
        settle_export(&mut core, &small),
        "no file at {}",
        small.display()
    );

    // 160 × 120 with a 64 px long edge is 64 × 48: the aspect is kept and
    // the picture is not cropped to a square.
    assert_eq!(ops::image_dimensions(&small), Some((64, 48)));
    // The document did not move to the copy's size.
    let after = core.state.editor.as_ref().unwrap();
    assert_eq!((after.width, after.height), (before.width, before.height));
    assert_eq!(after.save_path, before.save_path);
    assert_eq!(after.saved, before.saved);
    assert_eq!(after.history, before.history);

    // A resized copy keeps the ICC profile but not the EXIF that still
    // names the source's pixel dimensions.
    let resized = std::fs::read(&small).unwrap();
    assert!(
        resized.windows(9).any(|window| window == b"KogaViewI"),
        "the resized export dropped the colour profile"
    );
    assert!(
        !resized.windows(9).any(|window| window == b"KogaViewE"),
        "the resized export kept EXIF that describes the old size"
    );

    // A limit above the picture's own long edge writes it unchanged rather
    // than upscaling it.
    let big = base.join("big.jpg");
    let response = dispatch_json(
        &mut core,
        "export-2",
        &format!(
            r#"{{"type":"editor_export","path":"{}","max_edge":4000}}"#,
            big.display()
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(
        settle_export(&mut core, &big),
        "no file at {}",
        big.display()
    );
    assert_eq!(ops::image_dimensions(&big), Some((160, 120)));
    remove_tree(&base);
}

#[test]
fn save_overwrites_the_source_with_the_edit_and_keeps_a_backup() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let before = std::fs::read(&photo).unwrap();
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    );
    assert!(settle_editor(&mut core), "the document never arrived");
    assert!(core.state.editor.as_ref().unwrap().saved);
    assert_eq!(
        core.state.editor.as_ref().unwrap().save_path,
        photo.to_string_lossy()
    );

    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );
    assert!(
        !core.state.editor.as_ref().unwrap().saved,
        "an edit makes the document unsaved"
    );

    let response = dispatch_json(&mut core, "save-1", r#"{"type":"editor_save"}"#);
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_save(&mut core), "the save never finished");
    let editor = core.state.editor.as_ref().unwrap();
    assert!(editor.saved);
    assert_eq!(editor.save_path, photo.to_string_lossy());

    // The source now holds the rotated pixels: 20 × 40, not the original 40 × 20.
    let written = image::open(&photo).unwrap();
    assert_eq!((written.width(), written.height()), (20, 40));
    // The bytes it had before the save are kept beside it.
    let backup = base.join("photo.png.bak");
    assert_eq!(std::fs::read(&backup).unwrap(), before);
    // Journaled like every other command.
    let journal =
        std::fs::read_to_string(base.join("runtime/state/journal/commands.jsonl")).unwrap();
    assert!(journal.contains("\"command\":\"editor_save\""), "{journal}");
    remove_tree(&base);
}

#[test]
fn save_as_moves_the_save_target_and_leaves_the_source_alone() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let before = std::fs::read(&photo).unwrap();
    let destination = base.join("copy.jpeg");
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    );
    assert!(settle_editor(&mut core));
    dispatch_json(
        &mut core,
        "crop-1",
        r#"{"type":"editor_crop","x":0,"y":0,"width":10,"height":5}"#,
    );

    let response = dispatch_json(
        &mut core,
        "save-as-1",
        &format!(
            r#"{{"type":"editor_save_as","path":{}}}"#,
            serde_json::to_string(&destination.to_string_lossy()).unwrap()
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_save(&mut core), "the save never finished");

    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!(editor.save_path, destination.to_string_lossy());
    assert_eq!(editor.format, ".jpg");
    // A save-as never touches the source and keeps no backup of it.
    assert_eq!(std::fs::read(&photo).unwrap(), before);
    assert!(!base.join("photo.png.bak").exists());
    let written = image::open(&destination).unwrap();
    assert_eq!((written.width(), written.height()), (10, 5));
    remove_tree(&base);
}

#[test]
fn a_save_is_refused_when_the_source_changed_under_the_document() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    );
    assert!(settle_editor(&mut core));
    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );

    // Something else rewrites the file while the document is open.
    write_png(&photo, 40, 20);
    let now = std::time::SystemTime::now() + std::time::Duration::from_secs(2);
    std::fs::File::options()
        .write(true)
        .open(&photo)
        .unwrap()
        .set_modified(now)
        .unwrap();

    let response = dispatch_json(&mut core, "save-1", r#"{"type":"editor_save"}"#);
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "source_changed", "{response}");
    assert!(!core.state.editor.as_ref().unwrap().saved);

    // Save As is still allowed, and says nothing about the source.
    let elsewhere = base.join("rescue.png");
    let response = dispatch_json(
        &mut core,
        "save-as-1",
        &format!(
            r#"{{"type":"editor_save_as","path":{}}}"#,
            serde_json::to_string(&elsewhere.to_string_lossy()).unwrap()
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_save(&mut core));
    remove_tree(&base);
}

/// The Editor's Open pointed at the picture it already shows is not a new
/// document. Every `editor_open` used to tear the document down and decode
/// the same bytes again, so the canvas blinked and the undo history was
/// gone — for asking to see what was already on screen. Edits are kept, not
/// refused: the same picture asked for again is the one case where "you
/// have unsaved changes" is not a reason to say no.
#[test]
fn reopening_the_open_document_keeps_its_history() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let mut core = Core::for_test(&base.join("runtime"));
    let open = format!(
        r#"{{"type":"editor_open","path":{}}}"#,
        serde_json::to_string(&photo.to_string_lossy()).unwrap()
    );
    dispatch_json(&mut core, "open-1", &open);
    assert!(settle_editor(&mut core));
    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );
    let before = core.state.editor.clone().unwrap();
    let preview = core.editor_preview_path.clone();

    let again = dispatch_json(&mut core, "open-2", &open);
    assert_eq!(again["ok"], true, "{again}");
    let after = core.state.editor.clone().unwrap();
    // Not one pixel re-decoded, not one history entry dropped.
    assert_eq!(
        after.history, before.history,
        "reopening dropped the history"
    );
    assert_eq!((after.width, after.height), (20, 40));
    assert!(!after.saved, "the unsaved edit was silently kept as saved");
    assert_eq!(
        core.editor_preview_path, preview,
        "reopening threw the open document away"
    );
    assert_eq!(after.preview_revision, before.preview_revision);
    remove_tree(&base);
}

/// A different picture must not replace unsaved work without an answer.
/// The shell asks and sends `editor_reset` first; a caller that does not ask
/// gets this refusal instead of silence.
#[test]
fn replacing_a_dirty_document_is_refused() {
    let base = temp_dir();
    let first = base.join("one.png");
    let second = base.join("two.png");
    write_png(&first, 40, 20);
    write_png(&second, 20, 40);
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&first.to_string_lossy()).unwrap()
        ),
    );
    assert!(settle_editor(&mut core));
    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );

    let response = dispatch_json(
        &mut core,
        "open-2",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&second.to_string_lossy()).unwrap()
        ),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "unsaved_document", "{response}");
    assert_eq!(
        response["error"]["ui"]["code"], "unsaved_document",
        "the refusal must be a line the window can translate: {response}"
    );
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!(editor.save_path, first.to_string_lossy());
    assert_eq!((editor.width, editor.height), (20, 40), "the edit was lost");

    // Once discarded, the same open succeeds.
    dispatch_json(&mut core, "reset-1", r#"{"type":"editor_reset"}"#);
    let response = dispatch_json(
        &mut core,
        "open-3",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&second.to_string_lossy()).unwrap()
        ),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_editor(&mut core));
    assert_eq!(
        core.state.editor.as_ref().unwrap().save_path,
        second.to_string_lossy()
    );
    remove_tree(&base);
}

#[test]
fn saving_an_unsupported_extension_is_rejected_before_any_write() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let mut core = Core::for_test(&base.join("runtime"));
    dispatch_json(
        &mut core,
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    );
    assert!(settle_editor(&mut core));
    let target = base.join("idea.psd");
    let response = dispatch_json(
        &mut core,
        "save-as-1",
        &format!(
            r#"{{"type":"editor_save_as","path":{}}}"#,
            serde_json::to_string(&target.to_string_lossy()).unwrap()
        ),
    );
    assert_eq!(
        response["error"]["code"], "unsupported_format",
        "{response}"
    );
    assert!(!target.exists(), "a rejected save writes nothing");
    remove_tree(&base);
}

#[test]
fn switching_to_the_editor_carries_the_viewer_image() {
    let base = temp_dir();
    write_png(&base.join("one.png"), 10, 10);
    write_png(&base.join("two.png"), 12, 12);
    let mut core = Core::for_test(&base.join("runtime"));
    let folder = base.to_string_lossy().into_owned();
    let one = base.join("one.png").to_string_lossy().into_owned();
    let two = base.join("two.png").to_string_lossy().into_owned();
    dispatch_json(
        &mut core,
        "open-1",
        &format!(r#"{{"type":"open_folder","path":{folder:?}}}"#),
    );
    assert!(settle_scan(&mut core), "the folder never listed");
    dispatch_json(
        &mut core,
        "viewer-1",
        r#"{"type":"set_workspace","workspace":"viewer"}"#,
    );
    assert_eq!(core.state.viewer_path.as_deref(), Some(one.as_str()));

    // The workspace switcher alone: no `editor_open` anywhere in the user's action.
    let response = dispatch_json(
        &mut core,
        "editor-1",
        r#"{"type":"set_workspace","workspace":"editor"}"#,
    );
    assert_eq!(response["ok"], true, "{response}");
    let editor = core
        .state
        .editor
        .as_ref()
        .expect("the editor must open the viewed image");
    assert_eq!(editor.path, one);
    assert!(settle_editor(&mut core));
    assert_eq!(
        core.state.status.code, "editing",
        "the editor must say it is editing: {:?}",
        core.state.status
    );
    assert_eq!(core.state.status.args[0], "one.png");

    // A second switch back keeps the document, and so does a switch that
    // came from the Browser rather than the Viewer.
    let kept = core.state.editor.as_ref().unwrap().path.clone();
    dispatch_json(
        &mut core,
        "browser-1",
        r#"{"type":"set_workspace","workspace":"browser"}"#,
    );
    let status = core.state.status.clone();
    assert!(
        status.is_empty(),
        "the Browser still claimed to be editing: {status:?}"
    );
    dispatch_json(
        &mut core,
        "editor-2",
        r#"{"type":"set_workspace","workspace":"editor"}"#,
    );
    assert_eq!(core.state.editor.as_ref().unwrap().path, kept);

    // Opening another picture in the Viewer and coming back shows that
    // picture, not the document that happened to be open before. This is
    // the reported bug: the Editor kept resurrecting the old image.
    dispatch_json(
        &mut core,
        "viewer-2",
        r#"{"type":"set_workspace","workspace":"viewer"}"#,
    );
    dispatch_json(
        &mut core,
        "viewer-open",
        &format!(r#"{{"type":"viewer_open","path":{two:?}}}"#),
    );
    assert_eq!(core.state.viewer_path.as_deref(), Some(two.as_str()));
    dispatch_json(
        &mut core,
        "editor-3",
        r#"{"type":"set_workspace","workspace":"editor"}"#,
    );
    assert_eq!(
        core.state.editor.as_ref().unwrap().path,
        two,
        "the editor kept the old document instead of the viewed picture"
    );
    assert!(settle_editor(&mut core));
    assert_eq!(core.state.status.args[0], "two.png");

    // Unsaved work is not thrown away by a switch: the window's save /
    // discard question owns that decision.
    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );
    assert!(core.state.editor.as_ref().unwrap().modified);
    dispatch_json(
        &mut core,
        "viewer-3",
        r#"{"type":"set_workspace","workspace":"viewer"}"#,
    );
    dispatch_json(
        &mut core,
        "viewer-open-2",
        &format!(r#"{{"type":"viewer_open","path":{one:?}}}"#),
    );
    dispatch_json(
        &mut core,
        "editor-4",
        r#"{"type":"set_workspace","workspace":"editor"}"#,
    );
    assert_eq!(
        core.state.editor.as_ref().unwrap().path,
        two,
        "a switch replaced a document with unsaved edits"
    );

    // Discard (the window sends `editor_reset` before leaving) makes the
    // document saved again, so the next switch follows the Viewer.
    dispatch_json(&mut core, "reset-1", r#"{"type":"editor_reset"}"#);
    assert!(!core.state.editor.as_ref().unwrap().modified);
    dispatch_json(
        &mut core,
        "viewer-4",
        r#"{"type":"set_workspace","workspace":"viewer"}"#,
    );
    dispatch_json(
        &mut core,
        "editor-5",
        r#"{"type":"set_workspace","workspace":"editor"}"#,
    );
    assert_eq!(core.state.editor.as_ref().unwrap().path, one);
    remove_tree(&base);
}

#[test]
fn an_image_opens_in_the_editor_and_the_source_is_never_written() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let before = std::fs::read(&photo).unwrap();
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);

    let response = core.dispatch(&editor_envelope(
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], true, "{response}");
    assert!(settle_editor(&mut core), "the document never arrived");

    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (40, 20));
    assert_eq!(editor.name, "photo.png");
    assert_eq!(core.state.workspace, Workspace::Editor);
    assert!(editor.preview_path.is_some());
    let preview = PathBuf::from(editor.preview_path.as_ref().unwrap());
    assert!(preview.is_file(), "the preview PNG must exist");

    // A rotate changes the published size, keeps the source untouched, and
    // lands a new preview.
    let response = core.dispatch(&editor_envelope(
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    ));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"],
        true,
        "{response}"
    );
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (20, 40));
    assert_eq!(editor.history, vec![UiText::new("rotate_right")]);
    assert!(editor.can_undo);
    assert!(!editor.can_redo);
    assert!(settle_editor(&mut core), "the preview never landed");
    assert_eq!(std::fs::read(&photo).unwrap(), before);

    // Undo restores the size and offers redo.
    core.dispatch(&editor_envelope("undo-1", r#"{"type":"editor_undo"}"#));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (40, 20));
    assert!(!editor.can_undo);
    assert!(editor.can_redo);
    assert_eq!(editor.history.len(), 0);
    assert!(settle_editor(&mut core));

    core.dispatch(&editor_envelope("redo-1", r#"{"type":"editor_redo"}"#));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (20, 40));
    assert!(settle_editor(&mut core));

    // Close drops the document and its preview, and still leaves the file.
    let current_preview = PathBuf::from(
        core.state
            .editor
            .as_ref()
            .unwrap()
            .preview_path
            .as_ref()
            .unwrap(),
    );
    core.dispatch(&editor_envelope("close-1", r#"{"type":"editor_close"}"#));
    assert!(core.state.editor.is_none());
    assert!(
        !current_preview.is_file(),
        "the preview is removed on close"
    );
    assert_eq!(std::fs::read(&photo).unwrap(), before);

    // The journal recorded each command that reached the gateway.
    let journal = std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
    for name in [
        "editor_open",
        "editor_rotate",
        "editor_undo",
        "editor_redo",
        "editor_close",
    ] {
        assert!(
            journal.contains(&format!("\"command\":\"{name}\"")),
            "{journal}"
        );
    }

    remove_tree(&base);
}

/// The typed stroke reaches the document: the pixels change, the preview
/// hides them behind a redraw, and the whole stroke is one undo step.
#[test]
fn a_paint_stroke_is_one_undo_step_and_publishes_a_new_preview() {
    let base = temp_dir();
    let photo = base.join("paint.png");
    write_png(&photo, 40, 30);
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);
    let open = format!(
        r#"{{"type":"editor_open","path":{}}}"#,
        serde_json::to_string(&photo.to_string_lossy()).unwrap()
    );
    core.dispatch(&editor_envelope("open", &open));
    assert!(settle_editor(&mut core), "the document never arrived");
    let before_pixels = core.editor.as_ref().unwrap().pixels();
    let before_preview_revision = core.state.editor.as_ref().unwrap().preview_revision;
    let before_revision = core.state.revision;

    let response = core.dispatch(&editor_envelope(
        "stroke",
        r#"{"type":"editor_paint_stroke","points":[[10,10],[20,10]],"color":[255,0,0],"radius":3,"opacity":1}"#,
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], true, "{response}");
    assert!(core.state.revision > before_revision, "no revision bumped");

    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!(editor.history, vec![UiText::new("brush_stroke")]);
    assert!(editor.can_undo && !editor.can_redo);
    assert!(editor.modified);
    let after_pixels = core.editor.as_ref().unwrap().pixels();
    assert_ne!(after_pixels.as_raw(), before_pixels.as_raw());
    // The middle of the stroke really carries the brush colour.
    assert_eq!(after_pixels.get_pixel(15, 10).0, [255, 0, 0, 255]);
    // The canvas is handed a fresh preview once the worker lands it.
    assert!(settle_editor(&mut core), "the preview never landed");
    assert!(
        core.state.editor.as_ref().unwrap().preview_revision > before_preview_revision,
        "the canvas must be given a new preview"
    );

    let undo_revision = core.state.editor.as_ref().unwrap().preview_revision;
    core.dispatch(&editor_envelope("undo", r#"{"type":"editor_undo"}"#));
    let editor = core.state.editor.as_ref().unwrap();
    assert!(editor.history.is_empty());
    assert!(editor.can_redo);
    assert_eq!(
        core.editor.as_ref().unwrap().pixels().as_raw(),
        before_pixels.as_raw(),
        "undo must restore the bytes the stroke covered"
    );
    assert!(settle_editor(&mut core));
    assert!(
        core.state.editor.as_ref().unwrap().preview_revision > undo_revision,
        "undo repaints the canvas too"
    );

    let journal = std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
    assert!(journal.contains("\"command\":\"editor_paint_stroke\""));
    remove_tree(&base);
}

#[test]
fn opening_a_missing_or_non_image_file_is_rejected() {
    let base = temp_dir();
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);

    let missing = base.join("missing.png");
    let response = core.dispatch(&editor_envelope(
        "open-missing",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&missing.to_string_lossy()).unwrap()
        ),
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], false);
    assert_eq!(parsed["error"]["code"], "not_found");

    let notes = base.join("notes.txt");
    std::fs::write(&notes, "not an image").unwrap();
    let response = core.dispatch(&editor_envelope(
        "open-text",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&notes.to_string_lossy()).unwrap()
        ),
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], false);
    assert_eq!(parsed["error"]["code"], "not_an_image");

    remove_tree(&base);
}

#[test]
fn editor_resize_crop_and_flip_change_the_published_size() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);
    core.dispatch(&editor_envelope(
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    ));
    assert!(settle_editor(&mut core));

    core.dispatch(&editor_envelope(
        "crop-1",
        r#"{"type":"editor_crop","x":4,"y":2,"width":10,"height":8}"#,
    ));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (10, 8));
    assert_eq!(
        editor.history,
        vec![UiText::with("crop", ["10", "8", "4", "2"])]
    );
    assert_eq!(core.state.status.code, "editing");
    assert_eq!(
        &core.state.status.args[1..],
        ["10", "8"],
        "the status line must follow the document size: {:?}",
        core.state.status
    );

    core.dispatch(&editor_envelope(
        "resize-1",
        r#"{"type":"editor_resize","width":25,"height":25}"#,
    ));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (25, 25));
    // The published preview carries its own identity, not just a name the
    // next run will reuse: this is what keeps a thumbnail cache from
    // answering with an older document's image.
    assert!(editor.preview_modified > 0);
    assert!(editor.preview_size > 0);

    core.dispatch(&editor_envelope(
        "flip-1",
        r#"{"type":"editor_flip","axis":"vertical"}"#,
    ));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (25, 25));
    assert_eq!(editor.history.len(), 3);

    // An out-of-bounds crop is rejected with a message and changes nothing.
    let response = core.dispatch(&editor_envelope(
        "crop-2",
        r#"{"type":"editor_crop","x":20,"y":20,"width":10,"height":10}"#,
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], false);
    assert_eq!(parsed["error"]["code"], "invalid_edit");
    // The rejection says why twice: the line the window translates, and the
    // sentence the journal keeps. The numbers must be in both.
    assert_eq!(parsed["error"]["ui"]["code"], "crop_does_not_fit");
    assert_eq!(
        parsed["error"]["message"],
        "crop 10 × 10 at 20,20 does not fit the 25 × 25 image"
    );
    assert_eq!(core.state.editor.as_ref().unwrap().history.len(), 3);

    // The live preview is a draft: it publishes its own path and target
    // size, and leaves the document, its history and its save target alone.
    let before_history = core.state.editor.as_ref().unwrap().history.clone();
    let response = core.dispatch(&editor_envelope(
        "draft-1",
        r#"{"type":"editor_resize_preview","width":20,"height":20}"#,
    ));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"],
        true,
        "{response}"
    );
    {
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (25, 25));
        assert_eq!(editor.history, before_history);
        assert!(
            editor.preview_draft.is_none(),
            "the draft renders on a worker"
        );
    }
    assert!(settle_draft(&mut core), "the draft preview never landed");
    let draft = core
        .state
        .editor
        .as_ref()
        .unwrap()
        .preview_draft
        .clone()
        .expect("a draft is published");
    assert_eq!((draft.width, draft.height), (20, 20));
    assert_eq!(draft.kind, "resize");
    let draft_path = PathBuf::from(&draft.path);
    assert!(draft_path.is_file());
    let decoded = image::open(&draft_path).unwrap();
    assert_eq!(
        (decoded.width(), decoded.height()),
        (20, 20),
        "the draft is rendered at the target size"
    );

    // Applying the same size records the step and drops the draft file.
    core.dispatch(&editor_envelope(
        "resize-2",
        r#"{"type":"editor_resize","width":20,"height":20}"#,
    ));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (20, 20));
    assert!(editor.preview_draft.is_none());
    assert!(!draft_path.exists(), "the applied draft file is cleaned up");
    assert_eq!(
        editor.history.last(),
        Some(&UiText::with("resize", ["20", "20"]))
    );

    // Reset drops every step, back to the source size.
    core.dispatch(&editor_envelope("reset-1", r#"{"type":"editor_reset"}"#));
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!((editor.width, editor.height), (40, 20));
    assert!(editor.history.is_empty());
    assert!(!editor.can_undo);
    assert!(!editor.modified);

    remove_tree(&base);
}

/// A crop preview is a draft like the resize one: it renders the rectangle
/// Core would cut, publishes it under its own kind, and leaves the
/// document, its history and its preview alone. A no-op rectangle and an
/// out-of-bounds one are answered without rendering anything.
#[test]
fn a_crop_preview_is_a_draft_that_never_cuts() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);
    core.dispatch(&editor_envelope(
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    ));
    assert!(settle_editor(&mut core));
    let document_preview = core.state.editor.as_ref().unwrap().preview_path.clone();

    let response = core.dispatch(&editor_envelope(
        "crop-preview-1",
        r#"{"type":"editor_crop_preview","x":4,"y":2,"width":10,"height":8}"#,
    ));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"],
        true,
        "{response}"
    );
    assert!(settle_draft(&mut core), "the crop draft never landed");
    let draft = core
        .state
        .editor
        .as_ref()
        .unwrap()
        .preview_draft
        .clone()
        .expect("the crop draft is published");
    assert_eq!(draft.kind, "crop");
    assert_eq!((draft.width, draft.height), (10, 8));
    let draft_path = PathBuf::from(&draft.path);
    let decoded = image::open(&draft_path).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (10, 8));
    {
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (40, 20));
        assert!(editor.history.is_empty());
        assert_eq!(editor.preview_path, document_preview);
    }

    // Any other edit drops the draft file and publishes no draft.
    core.dispatch(&editor_envelope(
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    ));
    let editor = core.state.editor.as_ref().unwrap();
    assert!(editor.preview_draft.is_none());
    assert!(!draft_path.exists(), "another edit drops the crop draft");
    assert!(settle_editor(&mut core));

    // The whole image is not a crop: nothing is rendered and the message
    // says why, rather than leaving a stale draft on screen.
    let response = core.dispatch(&editor_envelope(
        "crop-preview-2",
        r#"{"type":"editor_crop_preview","x":0,"y":0,"width":20,"height":40}"#,
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], true, "{response}");
    assert_eq!(parsed["message"], "crop noop");
    assert_eq!(parsed["ui"]["code"], "crop_noop");
    assert!(core.state.editor.as_ref().unwrap().preview_draft.is_none());

    // Out of bounds is rejected at the gateway: no draft, no revision.
    let revision = core.state.revision;
    let response = core.dispatch(&editor_envelope(
        "crop-preview-3",
        r#"{"type":"editor_crop_preview","x":15,"y":0,"width":10,"height":10}"#,
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], false, "{response}");
    assert_eq!(parsed["error"]["code"], "invalid_edit");
    assert_eq!(core.state.revision, revision);
    assert!(core.state.editor.as_ref().unwrap().preview_draft.is_none());

    core.dispatch(&editor_envelope("close-1", r#"{"type":"editor_close"}"#));
    remove_tree(&base);
}

/// A transform preview is the same draft pipeline with a frame-sized result:
/// it renders the straightened picture under its own kind, leaves the
/// document alone until Apply, and answers an identity quad or an outside
/// corner without rendering anything.
#[test]
fn a_transform_preview_straightens_without_applying() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);
    core.dispatch(&editor_envelope(
        "open-1",
        &format!(
            r#"{{"type":"editor_open","path":{}}}"#,
            serde_json::to_string(&photo.to_string_lossy()).unwrap()
        ),
    ));
    assert!(settle_editor(&mut core));
    let document_preview = core.state.editor.as_ref().unwrap().preview_path.clone();

    let keystone = r#"{"type":"editor_transform_preview","corners":[[4,2],[40,0],[40,20],[0,20]]}"#;
    let response = core.dispatch(&editor_envelope("transform-preview-1", keystone));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], true, "{response}");
    assert_eq!(
        parsed["message"], "transform preview 40 20",
        "the line names the frame the draft was rendered at"
    );
    assert_eq!(parsed["ui"]["code"], "transform_preview");
    assert!(settle_draft(&mut core), "the transform draft never landed");
    let draft = core
        .state
        .editor
        .as_ref()
        .unwrap()
        .preview_draft
        .clone()
        .expect("the transform draft is published");
    assert_eq!(draft.kind, "transform");
    assert_eq!((draft.width, draft.height), (40, 20), "the frame is kept");
    let draft_path = PathBuf::from(&draft.path);
    assert!(draft_path.is_file());
    let decoded = image::open(&draft_path).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (40, 20));
    {
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (40, 20));
        assert!(editor.history.is_empty());
        assert_eq!(editor.preview_path, document_preview);
    }

    // Applying records one step and drops the draft file.
    core.dispatch(&editor_envelope(
        "transform-1",
        r#"{"type":"editor_transform","corners":[[4,2],[40,0],[40,20],[0,20]]}"#,
    ));
    {
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!((editor.width, editor.height), (40, 20));
        assert_eq!(editor.history, vec![UiText::new("transform")]);
        assert!(editor.preview_draft.is_none());
        assert!(editor.modified);
    }
    assert!(!draft_path.exists(), "the applied draft file is cleaned up");
    assert!(settle_editor(&mut core));

    // The whole frame is not a transform: no render, and the line says so.
    let response = core.dispatch(&editor_envelope(
        "transform-preview-2",
        r#"{"type":"editor_transform_preview","corners":[[0,0],[40,0],[40,20],[0,20]]}"#,
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], true, "{response}");
    assert_eq!(parsed["ui"]["code"], "transform_noop");
    assert!(core.state.editor.as_ref().unwrap().preview_draft.is_none());

    // A corner outside the picture is rejected at the gateway, with the
    // line the window translates and the revision untouched.
    let revision = core.state.revision;
    let response = core.dispatch(&editor_envelope(
        "transform-preview-3",
        r#"{"type":"editor_transform_preview","corners":[[-1,0],[40,0],[40,20],[0,20]]}"#,
    ));
    let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(parsed["ok"], false, "{response}");
    assert_eq!(parsed["error"]["code"], "invalid_edit");
    assert_eq!(parsed["error"]["ui"]["code"], "transform_outside");
    assert_eq!(core.state.revision, revision);
    assert!(core.state.editor.as_ref().unwrap().preview_draft.is_none());

    core.dispatch(&editor_envelope("close-1", r#"{"type":"editor_close"}"#));
    remove_tree(&base);
}
