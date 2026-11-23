//! The Viewer's stamp and the file identity a save follows.

use super::*;

/// The Viewer's `source` is the path, and a QML `Image` whose source string
/// does not change never re-reads the file. Opening the same picture again
/// after another program rewrote it showed the old pixels; the published
/// mtime and size are what let the window tell the two apart.
#[test]
fn the_viewer_stamp_follows_the_bytes_on_disk() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let mut core = Core::for_test(&base.join("runtime"));
    let open = format!(
        r#"{{"type":"open_file","paths":[{}]}}"#,
        serde_json::to_string(&photo.to_string_lossy()).unwrap()
    );
    dispatch_json(&mut core, "open-1", &open);
    assert!(settle_scan(&mut core));
    let first = (core.state.viewer_modified, core.state.viewer_size);
    assert!(first.0 > 0, "the viewer published no stamp at all");
    assert!(first.1 > 0);

    // Another program writes new bytes, larger than the first, two seconds
    // later: the size alone would already differ, and the mtime that the
    // test then also changes is the half a same-size rewrite relies on.
    write_png(&photo, 40, 21);
    let now = std::time::SystemTime::now() + std::time::Duration::from_secs(2);
    std::fs::File::options()
        .write(true)
        .open(&photo)
        .unwrap()
        .set_modified(now)
        .unwrap();

    dispatch_json(&mut core, "open-2", &open);
    assert!(settle_scan(&mut core));
    let second = (core.state.viewer_modified, core.state.viewer_size);
    assert_ne!(second, first, "the same path kept its old stamp");
    remove_tree(&base);
}

/// The Original tab draws the file on disk, so Core has to publish that
/// file's identity and publish it again after every save: the path may not
/// change and the bytes behind it do.
#[test]
fn the_saved_file_identity_follows_the_file_on_disk() {
    let base = temp_dir();
    let photo = base.join("photo.png");
    write_png(&photo, 40, 20);
    let destination = base.join("delivery.jpeg");
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
    assert_eq!(
        (
            core.state.editor.as_ref().unwrap().file_modified,
            core.state.editor.as_ref().unwrap().file_size,
        ),
        file_identity(&photo),
        "the open documents the source's own identity"
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
    let identity = file_identity(&destination);
    assert_ne!(identity.0, 0, "the destination was never written");
    {
        let editor = core.state.editor.as_ref().unwrap();
        assert_eq!(editor.save_path, destination.to_string_lossy());
        assert_eq!(
            (editor.file_modified, editor.file_size),
            identity,
            "the published identity is not the saved file's"
        );
    }
    assert_ne!(
        identity.1,
        file_identity(&photo).1,
        "the source and the copy are the same size, so this test proves nothing"
    );

    // A second save to the same path re-stats it rather than keeping the
    // pair the open published.
    dispatch_json(
        &mut core,
        "rotate-1",
        r#"{"type":"editor_rotate","degrees":90}"#,
    );
    let response = dispatch_json(&mut core, "save-1", r#"{"type":"editor_save"}"#);
    assert_eq!(response["ok"], true, "{response}");
    assert!(settle_save(&mut core), "the save never finished");
    let editor = core.state.editor.as_ref().unwrap();
    assert_eq!(
        (editor.file_modified, editor.file_size),
        file_identity(&destination)
    );

    remove_tree(&base);
}
