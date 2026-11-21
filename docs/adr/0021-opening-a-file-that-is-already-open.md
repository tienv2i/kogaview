# ADR 0021 — Opening a file that is already open

- Status: accepted
- Date: 2026-11-22
- Related: ADR 0003 (the working document), ADR 0013 (discard resets the
  document), ADR 0020 (the file's identity on disk)

## Context

Two different questions were answered by accident:

1. **The Viewer did not re-read a file it had already shown.** Its `Image`
   source was the path, and a QML `Image` whose source string does not change
   never re-reads the file. Reopening the same picture after another program
   rewrote it kept the old pixels on screen, with the new file sitting on disk.
2. **The Editor tore the document down for the same file.** Every `editor_open`
   deleted the current document and its preview, asked the worker to decode the
   same bytes, and reset the undo history. Asking to see the picture that was
   already on the canvas made it blink and lost every step.

There was also a third, narrower case: a *different* picture requested while the
Editor holds unsaved edits. Core's `link_viewer_into_editor` already refused a
workspace switch in that state, but a direct `editor_open` had no guard.

## Decision

### The Viewer follows the bytes, not the path

`UiState` and `StateMeta` gained `viewer_modified` and `viewer_size`; Core fills
them through one `set_viewer_path` helper at every site that assigns
`viewer_path` (open, next/previous, folder navigation, Home/End). `Viewer.qml`
appends them to the source string:

```qml
source: "file://" + view.currentPath + "?v=" + state.viewerModified + "-" + state.viewerSize
```

Qt strips the query when it reads the file, so the picture is the same path, but
the source string changes exactly when the bytes do. Opening the same unchanged
file again is the same string, so nothing is decoded twice; rewriting it is a new
string, so Qt reads it again.

### The Editor treats "the same file" as the same document

`open_editor` now looks at the document it already has before doing any work:

- **Same path, unsaved edits:** a no-op with the line `editor_already_open`.
  This is the one case where "you have unsaved changes" is not a reason to say
  no: the user asked for the picture already in front of them.
- **Same path, clean, bytes unchanged:** a no-op that keeps the preview and the
  undo history, publishes `editor_already_open`, and makes the Editor the
  workspace.
- **Same path, clean, bytes rewritten under it:** falls through and decodes
  again. The document on screen is stale, and a reload is what the click means.
- **Different path, unsaved edits:** refused with `unsaved_document` (a
  translatable line), not silence. The window never reaches this by itself.
- **Different path, clean:** opens as before.

The shell asks before replacing unsaved work instead of relying on the refusal:
`Main.qml` gained `requestEditorOpen(path, selectFirst)` /
`editorOpenCommands` / `runEditorOpen`, and every entry point goes through it —
the Editor's Open button, the shell menu's "Open in editor…", the fallback
chooser, and the Viewer's own edit action. With unsaved edits it opens the
existing unsaved-changes dialog; Save and Discard then send their own command
followed by the exact open (`pendingLeave.editorOpen`), in one `sendSequence`.

The chooser's "select the file in the Browser first" flag is kept in the same
pending record, so an open that began in the Browser still selects the file
after the dialog is answered.

## Consequences

- A picture that another program rewrites is re-read on the next `open_file`,
  and the Viewer's zoom/fit state is untouched because only the source string
  changes.
- An Editor document survives a second Open of itself: same preview file, same
  history, same unsaved edits. The journal still records the command (`ok:true`)
  and the reply says `editor already open`; the revision moves because the
  command still publishes the state, which is what the journal is for.
- A caller that does not ask first gets `unsaved_document`; the window's guard
  exists so a person is asked rather than refused.
- The reopen path is covered by Core tests
  (`reopening_the_open_document_keeps_its_history`,
  `replacing_a_dirty_document_is_refused`,
  `the_viewer_stamp_follows_the_bytes_on_disk`), a Viewer QML case
  (`theSourceCarriesTheStampSoARewrittenFileIsReadAgain`) and a settings source
  guard for the shell's question. The window runs used a rewritten `photo.png`
  (red 800 × 600 → blue 640 × 480) and a rotate-then-reopen batch; both are
  harness-driven, because this session's compositor delivers no pointer.
