//! The envelope, a rejection and the journal line it writes.

use super::*;

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
