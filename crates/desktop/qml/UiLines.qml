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
        case "layout_saved": return qsTr("Layout saved");
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

        // --- batch -------------------------------------------------------
        case "batch_started": return qsTr("Starting a batch of %1 image(s)…").arg(args[0]);
        case "batch_done": return qsTr("Batch finished: %1 of %2 image(s)").arg(args[0]).arg(args[1]);
        case "batch_done_failed":
            return qsTr("Batch finished: %1 of %2 image(s), %3 failed").arg(args[0]).arg(args[1]).arg(args[2]);
        case "batch_cancelled":
            return qsTr("Batch cancelled after %1 of %2 image(s)").arg(args[0]).arg(args[1]);
        case "batch_incomplete": return qsTr("The batch stopped before it finished");
        case "batch_already_running": return qsTr("A batch is already running");
        case "batch_no_images": return qsTr("There is no image to process");
        case "batch_too_many": return qsTr("A batch can process at most %1 images at once").arg(args[0]);
        case "batch_duplicate_output":
            return qsTr("Two files would be written to %1; add a suffix or choose another folder").arg(args[0]);
        case "batch_bad_name": return qsTr("Cannot name an output file for %1").arg(args[0]);
        case "batch_output_is_source":
            return qsTr("That would write over %1; add a suffix or choose another folder").arg(args[0]);
        case "batch_convert_overwrite":
            return qsTr("Replacing %1 in place would keep its old format; choose a suffix or another folder").arg(args[0]);
        case "batch_crop_outside":
            return qsTr("A crop must stay inside the image: X and Y at least 0, width and height above 0, and each side ending at 100 %");
        case "batch_crop_noop": return qsTr("That crop covers the whole image; set a width or height below 100 %");
        case "batch_bad_quality": return qsTr("The JPEG quality must be between 1 and 100");
        case "batch_bad_suffix": return qsTr("A suffix cannot contain a path separator");
        case "batch_overwrite_with_folder": return qsTr("Replacing the originals cannot also choose an output folder");
        case "batch_output_missing": return qsTr("The output folder does not exist: %1").arg(args[0]);

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
        case "editor_already_open": return qsTr("The editor is already showing this image");
        case "unsaved_document":
            return qsTr("Save or discard the current edits before opening %1").arg(args[0]);
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

        // --- rejected commands -------------------------------------------
        // A rejection is a line too: the cause is Core's, so the sentence is
        // the interface's. `message` stays as the English fallback for a
        // rejection whose detail is the platform's own (an OS error, an
        // envelope that did not parse).
        case "cancel_nothing_running": return qsTr("There is nothing running to cancel");
        case "open_needs_a_path": return qsTr("Choose a file or a folder to open first");
        case "path_missing": return qsTr("%1 does not exist").arg(args[0]);
        case "path_has_no_folder": return qsTr("That path has no parent folder");
        case "not_a_folder": return qsTr("%1 is not a folder").arg(args[0]);
        case "not_a_file": return qsTr("%1 is not a file").arg(args[0]);
        case "not_an_image": return qsTr("%1 is not an image").arg(args[0]);
        case "not_in_this_folder": return qsTr("That image is not part of the current folder");
        case "no_images_here": return qsTr("There are no images in the current folder");
        case "no_source_files": return qsTr("There are no files to copy or move");
        case "no_existing_paths": return qsTr("None of those paths exist any more");
        case "operation_in_progress": return qsTr("Another operation is still running");
        case "write_in_flight": return qsTr("A write is already in progress");
        case "destination_is_a_folder": return qsTr("%1 is a folder, not a file").arg(args[0]);
        case "copy_into_itself": return qsTr("Cannot copy or move %1 into itself").arg(args[0]);
        case "unsupported_save_format": return qsTr("Cannot save as %1; use one of %2").arg(args[0]).arg(args[1]);
        case "unsupported_export_format": return qsTr("Cannot export as %1; use one of %2").arg(args[0]).arg(args[1]);
        case "source_changed_on_disk":
            return qsTr("%1 changed on disk since it was opened; use Save As instead").arg(args[0]);
        case "export_onto_document": return qsTr("Exporting onto the open document would replace it; use Save");
        case "quick_access_needs_a_folder": return qsTr("Only folders can be added to quick access");
        case "relative_path_cannot_be_deleted": return qsTr("A relative path cannot be deleted");
        case "filesystem_root_cannot_be_deleted": return qsTr("The filesystem root cannot be deleted");
        case "home_folder_cannot_be_deleted": return qsTr("The home folder cannot be deleted");
        case "not_in_quick_access": return qsTr("That folder is not in quick access");
        case "needs_a_document": return qsTr("Open an image in the editor before editing it");
        case "editor_still_opening": return qsTr("The editor is still opening the image; save once it is shown");
        case "document_still_decoding": return qsTr("The document is still being decoded");

        // --- rejected edits ----------------------------------------------
        case "invalid_rotation": return qsTr("Cannot rotate by %1°; use a quarter, half or three-quarter turn").arg(args[0]);
        case "crop_size_empty": return qsTr("A crop needs a width and a height");
        case "crop_does_not_fit":
            return qsTr("A %1 × %2 crop at %3,%4 does not fit the %5 × %6 image")
                .arg(args[0]).arg(args[1]).arg(args[2]).arg(args[3]).arg(args[4]).arg(args[5]);
        case "crop_outside_document":
            return qsTr("A %1 × %2 crop at %3,%4 would not include the image; grow it over the picture")
                .arg(args[0]).arg(args[1]).arg(args[2]).arg(args[3]);
        case "crop_too_large": return qsTr("Growing to %1 × %2 is larger than the %3 pixel limit").arg(args[0]).arg(args[1]).arg(args[2]);
        case "resize_size_empty": return qsTr("A resize needs a width and a height");
        case "resize_too_large": return qsTr("Resizing to %1 × %2 is larger than the %3 pixel limit").arg(args[0]).arg(args[1]).arg(args[2]);
        case "resize_pad_needs_colour": return qsTr("Fit with background needs a background colour");
        case "transform_outside":
            return qsTr("The corner at %1,%2 is outside the %3 × %4 image")
                .arg(args[0]).arg(args[1]).arg(args[2]).arg(args[3]);
        case "transform_degenerate":
            return qsTr("Those four corners do not make a usable shape; keep them in order and apart");
        case "transform_noop": return qsTr("That transform would not change the image");
        case "transform_preview": return qsTr("Previewing a transform at %1 × %2").arg(args[0]).arg(args[1]);
        case "paint_empty_stroke": return qsTr("A stroke needs at least one point");
        case "paint_bad_point": return qsTr("A stroke point is not a number");
        case "paint_bad_radius":
            return qsTr("A brush from 0.5 to %1 px wide is needed, not %2")
                .arg(args[1]).arg(args[0]);
        case "paint_bad_opacity": return qsTr("A brush opacity must be above 0 and at most 100 %, not %1 %").arg(args[0]);

        // --- editor history (also the text of an applied edit) -----------
        case "rotate_right": return qsTr("Rotate right 90°");
        case "rotate_left": return qsTr("Rotate left 90°");
        case "rotate_half": return qsTr("Rotate 180°");
        case "rotate_degrees": return qsTr("Rotate %1°").arg(args[0]);
        case "flip_horizontal": return qsTr("Flip horizontal");
        case "flip_vertical": return qsTr("Flip vertical");
        case "crop": return qsTr("Crop %1 × %2 at %3,%4").arg(args[0]).arg(args[1]).arg(args[2]).arg(args[3]);
        case "crop_grow": return qsTr("Grow to %1 × %2 · %3 border").arg(args[0]).arg(args[1]).arg(args[2]);
        case "crop_grow_clear": return qsTr("Grow to %1 × %2 · transparent border").arg(args[0]).arg(args[1]);
        case "resize": return qsTr("Resize %1 × %2").arg(args[0]).arg(args[1]);
        case "resize_cover": return qsTr("Crop to fill %1 × %2").arg(args[0]).arg(args[1]);
        case "resize_pad": return qsTr("Resize %1 × %2 · pad %3").arg(args[0]).arg(args[1]).arg(args[2]);
        case "resize_pad_clear": return qsTr("Resize %1 × %2 · transparent background").arg(args[0]).arg(args[1]);
        case "transform": return qsTr("Straighten the frame");
        case "canvas_size": return qsTr("Canvas size %1 × %2").arg(args[0]).arg(args[1]);
        case "rotate_angle": return qsTr("Rotate %1°").arg(args[0]);
        case "adjust_color": return qsTr("Adjust color & light");
        case "invalid_color_adjustment": return qsTr("Invalid color adjustment values");
        case "brush_stroke": return qsTr("Brush stroke");
        case "eraser_stroke": return qsTr("Eraser stroke");
        }
        return args.length ? args.join(" ") : line.code;
    }
}
