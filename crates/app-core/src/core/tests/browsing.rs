//! Folders, the saved session, the settings and the layout they own.

use super::*;

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
