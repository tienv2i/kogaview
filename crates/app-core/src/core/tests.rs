//! The suites for the gateway: folders, the Viewer, the Editor, the batch
//! worker and the state each command publishes.
//!
//! They share the fixtures at the top (a temp directory, a folder scan, a
//! command helper), which is why they are one file.

use super::*;
use std::sync::atomic::{AtomicU32, Ordering};

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "kogaview-core-test-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Remove a test directory, retrying while a worker still holds a file in it.
///
/// The Editor renders previews into `<base>/cache/editor` on a worker
/// thread, so a `remove_dir_all` can meet a write that lands between its
/// enumeration and its last unlink — the call then answers "Directory not
/// empty" and the test fails on teardown, not on behaviour. Retrying is the
/// honest fix: nothing here asserts on how fast a preview is written.
fn remove_tree(path: &Path) {
    for _ in 0..50 {
        match std::fs::remove_dir_all(path) {
            Ok(()) => return,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(20)),
        }
    }
    let _ = std::fs::remove_dir_all(path);
}

/// Wait for the background folder scan to land, the way the UI's poll timer
/// does. Returns false if it never does.
fn settle_scan(core: &mut Core) -> bool {
    for _ in 0..2000 {
        if core.poll() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

/// Wait for a batch worker to publish its final line.
fn settle_batch(core: &mut Core) -> bool {
    for _ in 0..4000 {
        core.poll();
        if matches!(&core.state.batch, Some(batch) if !batch.running) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

fn select_json(path: &Path) -> String {
    format!(
        r#"{{"id":"select-1","protocol":1,"command":{{"type":"select","paths":["{}"]}}}}"#,
        path.display()
    )
}

/// The point of the split: the only part of the snapshot that grows with the
/// folder — the listing and the filmstrip's image paths — is published under
/// its own epoch, so a select does not pay to re-serialise a thousand
/// entries, and it is still shipped exactly when the listing changes.
#[test]
fn the_folder_listing_travels_apart_from_the_metadata() {
    let base = temp_dir();
    let folder = base.join("Photos");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("one.png"), b"png").unwrap();
    std::fs::write(folder.join("two.png"), b"png").unwrap();
    let runtime = base.join("runtime");

    let mut core = Core::for_test(&runtime);
    // With the scan in flight — even with two images, the worker thread has
    // probably not answered yet — a select must not move the epoch: the
    // window would then re-parse a listing it already has, and would take the
    // empty one if the select came between the clear and the landing.
    core.open_folder(folder.clone(), true).unwrap();
    let while_loading = core.listing_epoch();
    // The open itself cleared the previous listing, which is epoch movement
    // of its own; the select must leave that number alone.
    assert!(while_loading > 0, "the open did not clear the listing");
    core.dispatch(&select_json(&folder.join("one.png")));
    assert_eq!(
        core.listing_epoch(),
        while_loading,
        "a select while the folder was loading re-published the listing"
    );
    assert!(settle_scan(&mut core), "the folder scan never landed");
    // And the landing itself is epoch movement: it is the only signal the
    // window gets that its entries are stale.
    assert!(
        core.listing_epoch() > while_loading,
        "the scan replaced the listing without moving the epoch"
    );
    let last = core.listing_epoch();
    let listing: Value = serde_json::from_str(&core.folder_json()).unwrap();
    assert_eq!(listing["entries"].as_array().unwrap().len(), 2);
    assert_eq!(listing["viewerImages"].as_array().unwrap().len(), 2);
    let meta: Value = serde_json::from_str(&core.meta_json()).unwrap();
    assert_eq!(meta["itemCount"], 2);
    // The metadata alone does not carry the listing at all — not even an
    // empty array, which would still be a field the window had to overwrite.
    assert!(
        meta.get("entries").is_none(),
        "the metadata carried the listing"
    );
    assert!(meta.get("viewerImages").is_none());
    // …so a select, which cannot change the listing, leaves the epoch alone.
    core.dispatch(&select_json(&folder.join("two.png")));
    let after_select: Value = serde_json::from_str(&core.meta_json()).unwrap();
    assert_eq!(
        after_select["selection"].as_array().unwrap(),
        &vec![Value::from(folder.join("two.png").to_string_lossy())]
    );
    assert_eq!(after_select["selectionInfo"]["name"], "two.png");
    assert_eq!(
        core.listing_epoch(),
        last,
        "a select re-published the listing"
    );

    // …while navigating elsewhere does ship the new one.
    let other = base.join("Other");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(other.join("three.png"), b"png").unwrap();
    core.open_folder(other.clone(), false).unwrap();
    assert!(settle_scan(&mut core), "the folder scan never landed");
    assert!(
        core.listing_epoch() > last,
        "navigation did not move the epoch"
    );
    let listing: Value = serde_json::from_str(&core.folder_json()).unwrap();
    assert_eq!(listing["entries"][0]["name"], "three.png");
    assert_eq!(
        listing["viewerImages"][0],
        Value::from(other.join("three.png").to_string_lossy().as_ref())
    );

    // Snapshot and the two halves describe the same state field for field.
    let full: Value = serde_json::from_str(&core.snapshot_json()).unwrap();
    let meta: Value = serde_json::from_str(&core.meta_json()).unwrap();
    let listing: Value = serde_json::from_str(&core.folder_json()).unwrap();
    assert_eq!(full["entries"], listing["entries"]);
    assert_eq!(full["viewerImages"], listing["viewerImages"]);
    let mut merged = meta.as_object().unwrap().clone();
    merged.insert("entries".to_owned(), listing["entries"].clone());
    merged.insert("viewerImages".to_owned(), listing["viewerImages"].clone());
    assert_eq!(
        Value::Object(merged),
        full,
        "the metadata and the listing did not add up to the snapshot"
    );

    remove_tree(&base);
}

#[test]
fn breadcrumbs_include_the_root() {
    let crumbs = breadcrumbs(Path::new("/home/user/Pictures"));
    assert_eq!(crumbs[0].name, "/");
    assert_eq!(crumbs[0].path, "/");
    assert_eq!(crumbs.last().unwrap().name, "Pictures");
    assert_eq!(crumbs.last().unwrap().path, "/home/user/Pictures");
}

#[test]
fn folder_names_are_validated_before_creation() {
    let dir = temp_dir();
    let error = ops::create_folder(&dir, "bad/name").unwrap_err();
    assert!(error.contains("separator"));
    let created = ops::create_folder(&dir, "New folder").unwrap();
    assert!(created.is_dir());
    remove_tree(&dir);
}

// ------------------------------------------------- explorer root vs list

/// The tree keeps its root while the folder stays inside it, so browsing
/// one tree never re-roots it.
#[test]
fn the_root_survives_navigation_inside_the_tree() {
    let root = Path::new("/home/user/Pictures");
    for folder in ["/home/user/Pictures", "/home/user/Pictures/Child"] {
        assert_eq!(
            root_after_navigation(Some(root), Path::new(folder)),
            root,
            "{} re-rooted the tree",
            folder
        );
    }
}

/// A sibling whose name merely starts with the root's name is *outside* it.
#[test]
fn a_sibling_with_a_common_prefix_is_outside_the_tree() {
    assert!(!is_within(
        Path::new("/home/user/Pictures"),
        Path::new("/home/user/Pictures-old")
    ));
    assert_eq!(
        root_after_navigation(
            Some(Path::new("/home/user/Pictures")),
            Path::new("/Pictures-old")
        ),
        PathBuf::from("/Pictures-old")
    );
}

/// Leaving the subtree — breadcrumbs to an ancestor, "up" past the root —
/// moves the tree with the list.
#[test]
fn leaving_the_subtree_moves_the_root() {
    let root = Path::new("/home/user/Pictures");
    for folder in ["/home/user", "/", "/mnt/photos"] {
        assert_eq!(
            root_after_navigation(Some(root), Path::new(folder)),
            PathBuf::from(folder)
        );
    }
    // Nothing open yet: the first folder becomes the root.
    assert_eq!(
        root_after_navigation(None, Path::new("/tmp")),
        PathBuf::from("/tmp")
    );
}

/// The two saved values come back as two values: the sidebar keeps the
/// parent while the list shows the child.
#[test]
fn both_saved_folders_are_restored_separately() {
    let (root, folder) = restored_folders(
        Some("/home/user/Pictures"),
        Some("/home/user/Pictures/Child"),
        |_| true,
    );
    assert_eq!(root.unwrap(), PathBuf::from("/home/user/Pictures"));
    assert_eq!(folder.unwrap(), PathBuf::from("/home/user/Pictures/Child"));
}

/// One missing folder must not cost the other one.
#[test]
fn a_missing_folder_is_derived_from_the_surviving_one() {
    let existing = ["/home/user/Pictures"];

    // Only the tree root survived: the list opens it.
    let (root, folder) = restored_folders(Some("/gone"), Some("/home/user/Pictures"), |path| {
        existing.contains(&path.to_string_lossy().as_ref())
    });
    assert_eq!(root.unwrap(), PathBuf::from("/home/user/Pictures"));
    assert_eq!(folder.unwrap(), PathBuf::from("/home/user/Pictures"));

    // Only the open folder survived: it becomes the root.
    let (root, folder) = restored_folders(Some("/home/user/Pictures"), Some("/gone"), |path| {
        existing.contains(&path.to_string_lossy().as_ref())
    });
    assert_eq!(root.unwrap(), PathBuf::from("/home/user/Pictures"));
    assert_eq!(folder.unwrap(), PathBuf::from("/home/user/Pictures"));
}

/// A config that would restore the list outside the tree is repaired instead
/// of showing an empty tree.
#[test]
fn a_folder_outside_the_saved_root_is_repaired() {
    let (root, folder) = restored_folders(Some("/home/user"), Some("/mnt/photos"), |_| true);
    assert_eq!(root.unwrap(), PathBuf::from("/mnt/photos"));
    assert_eq!(folder.unwrap(), PathBuf::from("/mnt/photos"));
}

/// Drive the real commands: the two values must survive as two values, both
/// in the state the UI renders and in the configuration written to disk.
#[test]
fn the_root_and_the_open_folder_are_saved_apart() {
    let base = temp_dir();
    let root = base.join("Pictures");
    let child = root.join("Child");
    std::fs::create_dir_all(&child).unwrap();
    let runtime = base.join("runtime");

    let grandchild = child.join("Grand");
    std::fs::create_dir_all(&grandchild).unwrap();

    let mut core = Core::for_test(&runtime);
    core.open_folder(root.clone(), true).unwrap();
    // An explicit open of a folder that is already inside the tree — quick
    // access, "Open folder", a launcher argument — keeps the tree root.
    core.open_folder(child.clone(), true).unwrap();
    // A plain navigation (`Navigate`: tree click, grid double-click,
    // breadcrumb) inside the tree changes the list only.
    core.open_folder(grandchild.clone(), false).unwrap();

    let root_label = root.to_string_lossy().into_owned();
    let grandchild_label = grandchild.to_string_lossy().into_owned();
    assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));
    assert_eq!(
        core.state.current_folder.as_deref(),
        Some(grandchild_label.as_str())
    );
    assert_eq!(
        core.saved_folders(),
        (Some(root_label), Some(grandchild_label)),
        "the sidebar root and the open folder were written as one value"
    );

    remove_tree(&base);
}

/// Walking out of the tree ("up" past the root, a breadcrumb to an ancestor)
/// takes the tree with it, and that move is persisted too.
#[test]
fn walking_out_of_the_tree_re_roots_the_saved_value() {
    let base = temp_dir();
    let root = base.join("Pictures");
    let child = root.join("Child");
    std::fs::create_dir_all(&child).unwrap();
    let runtime = base.join("runtime");

    let mut core = Core::for_test(&runtime);
    core.open_folder(child.clone(), true).unwrap();
    assert_eq!(
        core.state.root_folder.as_deref(),
        Some(child.to_string_lossy().as_ref())
    );

    core.open_folder(base.clone(), false).unwrap();
    let base_label = base.to_string_lossy().into_owned();
    assert_eq!(core.state.root_folder.as_deref(), Some(base_label.as_str()));
    assert_eq!(core.saved_folders().0, Some(base_label));

    remove_tree(&base);
}

/// A restored session comes back with the tree above the open folder, not
/// with both collapsed into the deeper folder (the bug this fixes).
#[test]
fn restoring_a_session_keeps_the_tree_above_the_open_folder() {
    let base = temp_dir();
    let root = base.join("Pictures");
    let child = root.join("Child");
    std::fs::create_dir_all(&child).unwrap();
    let runtime = base.join("runtime");

    {
        let mut core = Core::for_test(&runtime);
        core.config.tree_root = Some(root.to_string_lossy().into_owned());
        core.config.last_folder = Some(child.to_string_lossy().into_owned());
        core.save_config();
    }

    let mut core = Core::for_test(&runtime);
    core.restore_last_session();

    let root_label = root.to_string_lossy().into_owned();
    let child_label = child.to_string_lossy().into_owned();
    assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));
    assert_eq!(
        core.state.current_folder.as_deref(),
        Some(child_label.as_str())
    );

    remove_tree(&base);
}

/// Only the open folder was saved (or only the root): the other value is
/// derived instead of leaving the window half empty.
#[test]
fn restoring_derives_the_value_that_is_missing() {
    let base = temp_dir();
    let child = base.join("Pictures/Child");
    std::fs::create_dir_all(&child).unwrap();
    let runtime = base.join("runtime");
    let child_label = child.to_string_lossy().into_owned();

    {
        let mut core = Core::for_test(&runtime);
        core.config.last_folder = Some(child_label.clone());
        core.save_config();
    }
    let mut core = Core::for_test(&runtime);
    core.restore_last_session();
    assert_eq!(
        core.state.root_folder.as_deref(),
        Some(child_label.as_str())
    );
    assert_eq!(
        core.state.current_folder.as_deref(),
        Some(child_label.as_str())
    );

    // Now save a tree root only.
    std::fs::remove_file(runtime.join("config.json")).unwrap();
    {
        let mut core = Core::for_test(&runtime);
        core.config.tree_root = Some(child_label.clone());
        core.save_config();
    }
    let mut core = Core::for_test(&runtime);
    core.restore_last_session();
    assert_eq!(
        core.state.root_folder.as_deref(),
        Some(child_label.as_str())
    );
    assert_eq!(
        core.state.current_folder.as_deref(),
        Some(child_label.as_str())
    );

    remove_tree(&base);
}

/// Folders that no longer exist open nothing, exactly like a first run.
#[test]
fn restoring_deleted_folders_opens_nothing() {
    let base = temp_dir();
    let runtime = base.join("runtime");
    {
        let mut core = Core::for_test(&runtime);
        core.config.tree_root = Some("/definitely/gone".to_owned());
        core.config.last_folder = Some("/also/gone".to_owned());
        core.save_config();
    }
    let mut core = Core::for_test(&runtime);
    core.restore_last_session();
    assert!(core.state.root_folder.is_none());
    assert!(core.state.current_folder.is_none());
    remove_tree(&base);
}

#[test]
fn nothing_opens_when_no_saved_folder_survives() {
    let (root, folder) = restored_folders(Some("/gone"), Some("/gone-too"), |_| false);
    assert!(root.is_none());
    assert!(folder.is_none());
    let (root, folder) = restored_folders(None, None, |_| true);
    assert!(root.is_none() && folder.is_none());
}

/// `set_settings` is what the Settings dialog sends. It has to change what
/// the *next* run restores, not only the file: that is the state delta the
/// user selected the checkbox for.
#[test]
fn settings_decide_whether_the_folders_come_back() {
    let base = temp_dir();
    let root = base.join("Pictures");
    let child = root.join("Child");
    std::fs::create_dir_all(&child).unwrap();
    let runtime = base.join("runtime");
    let root_label = root.to_string_lossy().into_owned();
    let child_label = child.to_string_lossy().into_owned();

    let settings = |remember: bool| {
        format!(
            r#"{{"id":"settings-1","protocol":1,"command":{{"type":"set_settings",
                "theme":"dark","remember_last_folder":{remember},
                "background_thumbnails":true}}}}"#
        )
    };

    {
        let mut core = Core::for_test(&runtime);
        core.open_folder(root.clone(), true).unwrap();
        core.open_folder(child.clone(), true).unwrap();
        assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));
        assert_eq!(
            core.saved_folders(),
            (Some(root_label.clone()), Some(child_label.clone()))
        );
    }

    // Remembered: the folder comes back, as before.
    {
        let mut core = Core::for_test(&runtime);
        core.dispatch(&settings(true));
        assert_eq!(
            core.saved_folders(),
            (Some(root_label.clone()), Some(child_label.clone()))
        );
    }
    let mut core = Core::for_test(&runtime);
    core.restore_last_session();
    assert_eq!(
        core.state.current_folder.as_deref(),
        Some(child_label.as_str())
    );
    assert_eq!(core.state.root_folder.as_deref(), Some(root_label.as_str()));

    // Not remembered: the saved values are dropped, and the next start
    // opens nothing even though this session is showing the folder.
    {
        let mut core = Core::for_test(&runtime);
        core.restore_last_session();
        assert!(core.state.remember_last_folder);
        core.dispatch(&settings(false));
        assert!(
            !core.state.remember_last_folder,
            "the dialog reads this from the snapshot; it still says remembered"
        );
        assert_eq!(
            core.saved_folders(),
            (None, None),
            "turning the option off left the folders in the file"
        );
        // A navigation after that must not put them back.
        core.open_folder(root.clone(), true).unwrap();
        assert_eq!(
            core.saved_folders(),
            (None, None),
            "navigation re-saved the folders"
        );
    }
    let mut core = Core::for_test(&runtime);
    core.restore_last_session();
    assert!(
        core.state.current_folder.is_none(),
        "a session the user asked not to remember came back anyway"
    );

    // And turning it on again remembers what is on screen now, without a
    // navigation in between.
    {
        let mut core = Core::for_test(&runtime);
        core.open_folder(root.clone(), true).unwrap();
        core.open_folder(child.clone(), true).unwrap();
        core.dispatch(&settings(true));
        assert_eq!(core.saved_folders(), (Some(root_label), Some(child_label)));
    }

    remove_tree(&base);
}

/// A config that says "do not remember" is obeyed even when it still holds
/// folders (hand-edited, or written by an older build).
#[test]
fn a_config_that_forgets_opens_nothing() {
    let base = temp_dir();
    let root = base.join("Pictures");
    std::fs::create_dir_all(&root).unwrap();
    let runtime = base.join("runtime");
    {
        let mut core = Core::for_test(&runtime);
        core.open_folder(root, true).unwrap();
        core.config.remember_last_folder = false;
        core.save_config();
    }
    let mut core = Core::for_test(&runtime);
    core.restore_last_session();
    assert!(core.state.root_folder.is_none());
    assert!(core.state.current_folder.is_none());
    remove_tree(&base);
}

/// Poll until the editor has a document and no preview render outstanding.
/// Wait for a save worker to report back, the way the UI's poll timer does.
fn settle_save(core: &mut Core) -> bool {
    for _ in 0..3000 {
        core.poll();
        if !core.editor_saving() {
            return core
                .state
                .editor
                .as_ref()
                .is_some_and(|editor| editor.saved);
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

fn dispatch_json(core: &mut Core, id: &str, command: &str) -> serde_json::Value {
    serde_json::from_str(&core.dispatch(&editor_envelope(id, command))).unwrap()
}

/// Wait for an export worker to finish writing `path`.
fn settle_export(core: &mut Core, path: &Path) -> bool {
    for _ in 0..4000 {
        core.poll();
        if !core.editor_saving() && path.is_file() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

/// A JPEG whose entropy-coded data changes with the quality setting, with
/// an EXIF APP1 segment a reader can look for after an export.
fn write_jpeg_with_exif(path: &Path, width: u32, height: u32) {
    let image = image::RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([
            ((x * 37 + y * 11) % 256) as u8,
            ((x * 13 + y * 29) % 256) as u8,
            ((x * x + y * y) % 256) as u8,
            255,
        ])
    });
    let encoded = editor::encode_with(&image, editor::SaveFormat::Jpeg, Some(95)).unwrap();
    let exif = b"Exif\0\0KogaViewExportTest";
    let icc = b"ICC_PROFILE\0KogaViewIccTest";
    let mut bytes = encoded[..2].to_vec();
    for (marker, payload) in [(0xE1u8, exif.as_slice()), (0xE2, icc.as_slice())] {
        let length = (payload.len() + 2) as u16;
        bytes.extend_from_slice(&[0xFF, marker, (length >> 8) as u8, length as u8]);
        bytes.extend_from_slice(payload);
    }
    bytes.extend_from_slice(&encoded[2..]);
    std::fs::write(path, bytes).unwrap();
}

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

fn settle_editor(core: &mut Core) -> bool {
    for _ in 0..3000 {
        core.poll();
        match &core.state.editor {
            Some(editor) if editor.width > 0 && !editor.rendering => return true,
            _ => {}
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

/// Wait for a live-preview draft to land. `settle_editor` cannot stand in
/// for this: the document is not rendering, so it returns before the draft
/// worker has answered.
fn settle_draft(core: &mut Core) -> bool {
    for _ in 0..3000 {
        core.poll();
        if let Some(editor) = &core.state.editor {
            if editor.preview_draft.is_some() {
                return true;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    false
}

fn write_png(path: &Path, width: u32, height: u32) {
    let image = image::RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([(x % 251) as u8, (y % 251) as u8, 90, 255])
    });
    image::DynamicImage::ImageRgba8(image)
        .save_with_format(path, image::ImageFormat::Png)
        .unwrap();
}

fn editor_envelope(id: &str, command: &str) -> String {
    format!(r#"{{"id":"{id}","protocol":1,"command":{command}}}"#)
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
fn editor_commands_without_a_document_are_rejected_and_journaled() {
    let base = temp_dir();
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);

    for (id, command) in [
        ("undo", r#"{"type":"editor_undo"}"#),
        ("redo", r#"{"type":"editor_redo"}"#),
        (
            "crop",
            r#"{"type":"editor_crop","x":0,"y":0,"width":4,"height":4}"#,
        ),
        ("resize", r#"{"type":"editor_resize","width":4,"height":4}"#),
        ("rotate", r#"{"type":"editor_rotate","degrees":90}"#),
        ("flip", r#"{"type":"editor_flip","axis":"horizontal"}"#),
        ("reset", r#"{"type":"editor_reset"}"#),
    ] {
        let response = core.dispatch(&editor_envelope(id, command));
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["ok"], false, "{command}: {response}");
        assert_eq!(parsed["error"]["code"], "no_document", "{command}");
        assert!(core.state.editor.is_none());
    }

    let journal = std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
    assert!(journal.contains("\"ok\":false"));
    remove_tree(&base);
}

/// A rejection the interface can word itself travels as `{ code, args }`
/// next to the English message: the window says it in its own language, the
/// journal keeps a sentence, and a rejection whose detail is the platform's
/// (an envelope that did not parse) carries no line at all.
#[test]
fn a_rejection_carries_a_line_the_interface_can_translate() {
    let base = temp_dir();
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);

    let reply = dispatch_json(&mut core, "cancel-1", r#"{"type":"cancel_operation"}"#);
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "not_running", "{reply}");
    assert_eq!(
        reply["error"]["ui"]["code"], "cancel_nothing_running",
        "{reply}"
    );
    assert_eq!(reply["error"]["ui"]["args"], json!([]), "{reply}");
    // The journal's sentence is not the line's mechanical rendering.
    assert_eq!(
        reply["error"]["message"], "there is no long-running operation to cancel",
        "{reply}"
    );

    // A rejection that identifies something the filesystem named keeps the
    // path as an argument: the interface owns the sentence, the path is
    // data and must arrive unchanged.
    let missing = base.join("gone.jpg");
    let reply = dispatch_json(
        &mut core,
        "open-1",
        &format!(
            r#"{{"type":"open_file","paths":["{}"]}}"#,
            missing.display()
        ),
    );
    assert_eq!(reply["error"]["ui"]["code"], "path_missing", "{reply}");
    assert_eq!(
        reply["error"]["ui"]["args"][0],
        missing.display().to_string(),
        "{reply}"
    );

    // The journal kept the English sentence, so a reader of the log is not
    // asked to decode a code.
    let journal = std::fs::read_to_string(runtime.join("state/journal/commands.jsonl")).unwrap();
    assert!(journal.contains("no long-running operation"), "{journal}");

    // An envelope that never parsed is answered before the gateway: there
    // is no command to word, so the rejection has no line.
    let reply: serde_json::Value = serde_json::from_str(&core.dispatch("{")).unwrap();
    assert_eq!(reply["error"]["code"], "invalid_envelope", "{reply}");
    assert!(reply["error"].get("ui").is_none(), "{reply}");

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

/// Each workspace keeps its own right-panel preference: hiding the Viewer's
/// information must not shut the Browser's preview, and the choice has to
/// survive a restart because it is written to `config.json`.
#[test]
fn a_right_panel_toggle_belongs_to_its_workspace() {
    let base = temp_dir();
    let runtime = base.join("runtime");

    let mut core = Core::for_test(&runtime);
    assert!(core.state.layout.panel("browser.preview"));
    assert!(core.state.layout.panel("viewer.info"));
    assert!(core.state.layout.panel("editor.info"));

    let response = dispatch_json(
        &mut core,
        "panel-1",
        r#"{"type":"toggle_right_panel","workspace":"viewer"}"#,
    );
    assert_eq!(response["ok"], true, "{response}");
    assert!(!core.state.layout.panel("viewer.info"));
    assert!(
        core.state.layout.panel("browser.preview"),
        "the Browser's panel moved with it"
    );
    assert!(
        core.state.layout.panel("editor.info"),
        "the Editor's panel moved with it"
    );

    // No workspace means the one on screen: the Editor here.
    core.state.workspace = Workspace::Editor;
    let response = dispatch_json(&mut core, "panel-2", r#"{"type":"toggle_right_panel"}"#);
    assert_eq!(response["ok"], true, "{response}");
    assert!(!core.state.layout.panel("editor.info"));
    assert!(!core.state.layout.panel("editor.history"));
    assert!(
        !core.state.layout.panel("viewer.info"),
        "an unrelated toggle came back"
    );

    // A new process reads the same answers back.
    let reloaded = Core::for_test(&runtime);
    assert!(reloaded.config.layout.panel("browser.preview"));
    assert!(!reloaded.config.layout.panel("viewer.info"));
    assert!(!reloaded.config.layout.panel("editor.history"));
    assert!(reloaded.state.layout.panel("browser.preview"));
    assert!(!reloaded.state.layout.panel("viewer.info"));
    assert!(!reloaded.state.layout.panel("editor.options"));

    remove_tree(&base);
}

/// A layout is a preference, so Core writes it, clamps it and publishes it.
#[test]
fn a_saved_layout_is_clamped_written_and_published() {
    let base = temp_dir();
    let runtime = base.join("runtime");
    let mut core = Core::for_test(&runtime);

    let response = dispatch_json(
        &mut core,
        "layout-1",
        r#"{"type":"set_layout","layout":{"leftWidth":9000,"rightWidth":10,
             "editorToolColumns":3,"editorReferenceHeight":9999,
             "editorReferenceTab":"history",
             "panels":{"editor.history":false,"not.a.panel":false}}}"#,
    );
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(core.state.layout.left_width, 560);
    assert_eq!(core.state.layout.right_width, 200);
    assert_eq!(core.state.layout.editor_tool_columns, 2);
    assert_eq!(core.state.layout.editor_reference_height, 900);
    assert_eq!(core.state.layout.editor_reference_tab, "history");
    assert!(!core.state.layout.panel("editor.history"));
    assert!(core.state.layout.panel("editor.info"));

    // The file has it, so the next run opens the same way …
    let reloaded = Core::for_test(&runtime);
    assert_eq!(reloaded.state.layout.left_width, 560);
    assert!(!reloaded.state.layout.panel("editor.history"));
    assert_eq!(reloaded.state.layout.editor_reference_tab, "history");
    // … and the legacy booleans are not the source any more.
    let text = std::fs::read_to_string(runtime.join("config.json")).unwrap();
    assert!(text.contains("\"layout\""), "{text}");
    assert!(!text.contains("left_panel"), "{text}");

    remove_tree(&base);
}

/// A config written before a layout existed still opens with every panel
/// showing, instead of failing to parse or defaulting to hidden — except
/// for a dock the old flags said was closed.
#[test]
fn a_config_from_before_the_layout_loads_with_its_docks_open() {
    let base = temp_dir();
    let runtime = base.join("runtime");
    std::fs::create_dir_all(&runtime).unwrap();
    std::fs::write(
        runtime.join("config.json"),
        r#"{"theme":"light","left_panel":false,"right_panel":false}"#,
    )
    .unwrap();

    let core = Core::for_test(&runtime);
    assert!(!core.state.layout.panel("browser.quickAccess"));
    assert!(!core.state.layout.panel("browser.explorer"));
    assert!(!core.state.layout.panel("browser.preview"));
    assert!(core.state.layout.panel("viewer.info"));
    assert!(core.state.layout.panel("editor.info"));
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
