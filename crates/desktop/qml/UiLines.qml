import QtQuick

/// The one place a Core line becomes a sentence.
///
/// Core publishes `{ code, args }` (`UiText` in `crates/app-core/src/state.rs`)
/// because it knows *what* happened but not which language the interface is in.
/// Every code Core can send has a `qsTr` below; an unknown code falls back to
/// its arguments, so an older interface meeting a newer Core shows something
/// rather than an empty status bar.
///
/// Add a code here **and** in `i18n/kogaview_vi.ts`; `scripts/check_translations.py`
/// fails a `qsTr` that the catalogue does not hold.
QtObject {
    id: lines

    /// Render one `{ code, args }` line.
    ///
    /// `language` is not read. It is a parameter so a binding that calls this
    /// has a dependency on the interface language: Qt re-evaluates the binding
    /// when the translator changes, and asking `qsTr` again is what makes the
    /// sentence follow the new language instead of keeping the old one.
    function text(line, language) {
        if (!line || line.code === undefined)
            return "";
        var args = line.args || [];
        switch (line.code) {
        // --- shell -------------------------------------------------------
        case "": return "";
        case "ready": return qsTr("Ready");
        case "refreshed": return qsTr("Refreshed");
        case "settings_saved": return qsTr("Settings saved");
        case "language_set": return qsTr("Interface language: %1").arg(args[0]);
        case "quick_access_added": return qsTr("Added %1 to quick access").arg(args[0]);
        case "quick_access_removed": return qsTr("Removed from quick access");
        case "created": return qsTr("Created %1").arg(args[0]);

        // --- browser -----------------------------------------------------
        case "folder_scan_failed": return qsTr("Folder scan failed");
        case "folder_opened": return qsTr("Opened %1").arg(args[0]);
        case "opening_file": return qsTr("Opening %1").arg(args[0]);
        case "file_operation_failed": return qsTr("File operation failed");
        case "restoring_folder": return qsTr("Restoring last folder…");
        case "loading_folder": return qsTr("Loading %1…").arg(args[0]);
        case "folder_contents": return qsTr("%1 items · %2 images").arg(args[0]).arg(args[1]);
        case "folder_error": return qsTr("Cannot read this folder: %1").arg(args[0]);

        // --- copy / move / delete ---------------------------------------
        case "copying": return qsTr("Copying %1 item(s)…").arg(args[0]);
        case "moving": return qsTr("Moving %1 item(s)…").arg(args[0]);
        case "copied_to": return qsTr("Copied %1 item(s) to %2").arg(args[0]).arg(args[1]);
        case "moved_to": return qsTr("Moved %1 item(s) to %2").arg(args[0]).arg(args[1]);
        case "copy_failed":
            return qsTr("Copied %1 item(s); %2 error(s): %3").arg(args[0]).arg(args[1]).arg(args[2]);
        case "move_failed":
            return qsTr("Moved %1 item(s); %2 error(s): %3").arg(args[0]).arg(args[1]).arg(args[2]);
        case "cancelled": return qsTr("Cancelled");
        case "cancelling": return qsTr("Cancelling…");
        case "cancelled_after": return qsTr("Cancelled after %1 item(s)").arg(args[0]);
        case "moving_to_trash": return qsTr("Moving %1 item(s) to trash…").arg(args[0]);
        case "moved_to_trash": return qsTr("Moved %1 item(s) to trash").arg(args[0]);
        case "trash_failed": return qsTr("Move to trash failed: %1").arg(args[0]);
        case "deleting_permanently": return qsTr("Deleting %1 item(s) permanently…").arg(args[0]);
        case "deleted_permanently": return qsTr("Permanently deleted %1 item(s)").arg(args[0]);
        case "delete_failed":
            return qsTr("Deleted %1 item(s); %2 error(s): %3").arg(args[0]).arg(args[1]).arg(args[2]);
        case "cancelled_after_delete":
            return qsTr("Cancelled after deleting %1 item(s)").arg(args[0]);

        // --- editor ------------------------------------------------------
        case "opening_in_editor": return qsTr("Opening %1 in the editor…").arg(args[0]);
        case "editing": return qsTr("Editing %1 · %2 × %3").arg(args[0]).arg(args[1]).arg(args[2]);
        case "edit_noop": return qsTr("That edit would not change the image");
        case "resize_noop": return qsTr("That resize would not change the image");
        case "crop_noop": return qsTr("That crop would not change the image");
        case "resize_preview": return qsTr("Previewing a resize to %1 × %2").arg(args[0]).arg(args[1]);
        case "crop_preview": return qsTr("Previewing a crop to %1 × %2").arg(args[0]).arg(args[1]);
        case "undo": return qsTr("Undo");
        case "redo": return qsTr("Redo");
        case "nothing_to_undo": return qsTr("Nothing to undo");
        case "nothing_to_redo": return qsTr("Nothing to redo");
        case "nothing_to_reset": return qsTr("The image has no edits to reset");
        case "reset_done": return qsTr("Reset to the original image");
        case "edit_error": return qsTr("The edit failed: %1").arg(args[0]);
        case "editor_closed": return qsTr("Editor closed");
        case "preview_folder_failed": return qsTr("Could not create the preview folder");
        case "no_decoder": return qsTr("Cannot open %1: no decoder for this format").arg(args[0]);
        case "saving": return qsTr("Saving %1…").arg(args[0]);
        case "saved": return qsTr("Saved %1").arg(args[0]);
        case "save_error": return qsTr("Save failed: %1").arg(args[0]);
        case "save_incomplete": return qsTr("The save did not finish");
        case "exporting": return qsTr("Exporting %1…").arg(args[0]);
        case "exported": return qsTr("Exported %1").arg(args[0]);
        case "export_error": return qsTr("Export failed: %1").arg(args[0]);
        case "export_incomplete": return qsTr("The export did not finish");
        case "config_save_failed": return qsTr("Cannot save configuration: %1").arg(args[0]);

        // --- editor history (also the text of an applied edit) -----------
        case "rotate_right": return qsTr("Rotate right 90°");
        case "rotate_left": return qsTr("Rotate left 90°");
        case "rotate_half": return qsTr("Rotate 180°");
        case "rotate_degrees": return qsTr("Rotate %1°").arg(args[0]);
        case "flip_horizontal": return qsTr("Flip horizontal");
        case "flip_vertical": return qsTr("Flip vertical");
        case "crop": return qsTr("Crop %1 × %2 at %3,%4").arg(args[0]).arg(args[1]).arg(args[2]).arg(args[3]);
        case "resize": return qsTr("Resize %1 × %2").arg(args[0]).arg(args[1]);
        case "resize_pad": return qsTr("Resize %1 × %2 · pad %3").arg(args[0]).arg(args[1]).arg(args[2]);
        }
        return args.length ? args.join(" ") : line.code;
    }
}
