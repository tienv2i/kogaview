# ADR 0003 — The Editor's working document and history model

- Status: accepted
- Date: 2026-11-16

## Context

The Editor milestone needs a mechanism that feels like a raster editor for
daily use (Krita was the reference during the discussion): apply edits to the
image on screen, undo a step, redo it, and export a result, all without ever
touching the source file. Two candidate models were considered:

- **Source + recipe**: hold the original and a serialized list of operations,
  re-render the whole result whenever anything changes. Correct and tiny, but
  every display refresh pays for a full replay; brush strokes and layers later
  make replay unboundedly expensive, and layer stacks cannot be expressed as a
  flattened recipe.
- **Materialized working document with operation history**: decode once, apply
  edits directly, keep undo/redo as a stack of steps. This is what Krita and
  GIMP do; it matches how people expect "undo" to behave while painting.

The protocol already mandates that every edit be an explicit, serializable
command. The remaining design decisions are where pixels live, how undo keeps
the memory bounded, and how the UI renders a document that Core owns.

## Decision

- Editing starts by **decoding the source once into a working document** that
  lives in Core (`crates/app-core/src/editor.rs`). The source path and bytes are
  never written to.
- A **serializable [`EditOperation`]** is the unit of edit: `Rotate`, `Flip`,
  `Crop`, `Resize` today, more later. Each lands in the command journal as its
  prototyped editor command, so every front end (UI, CLI, IPC, MCP) edits
  through the same gateway and the same history semantics.
- **Undo is a stack of steps.** Losslessly invertible operations (rotate, flip)
  undo by applying their inverse; crop and resize carry a snapshot of the pixels
  they replaced, because those pixels cannot be recreated from parameters. A new
  edit clears the redo branch, like any editor.
- **History is bounded**: at most 12 steps and 160 MiB of snapshot pixels,
  dropping the *oldest* steps first. The newest steps — the ones a user is about
  to undo — are never dropped. This is an explicit limitation of the first
  slice, whose pixels are whole buffers; a tiled or tile-delta model is the
  later, documented upgrade path, not a surprise fix.
- **The original pixels are retained** as an immutable `Arc<RgbaImage>` so
  Reset never needs to re-decode; the working image starts sharing that buffer
  and only diverges after the first edit.
- Worker threads decode and render previews; pixels are passed by `Arc`. Each
  task carries a **generation**, and Core drops any result whose generation is
  stale, so a slow open cannot overwrite a newer document.
- The UI renders a **downscaled preview PNG** (2048 px longest edge) that Core
  writes to `$XDG_CACHE_HOME/kogaview[-dev]/editor/preview-<generation>.png`.
  The working document keeps full resolution; exporting full resolution comes
  with the export milestone.
- The **source file is the single source of truth for Reset**, undo/redo is
  memory-only history for the session, and there is no Editor document format in
  this slice. The `EditOperation` list is already serializable so a session
  format can be built on it later without changing the command protocol.

## Consequences

- A large or slow-to-decode image does not block the UI: decode and preview
  encode run on workers. A debug-build decode of a 1.6 MP JPEG measured ~1 s in
  the dev harness (QML startup dominated the first run); release builds decode
  far faster. Tiled decode and JPEG downscaled decode are future work.
- Undo depth is finite and depends on image size; the UI publishes
  `canUndo`/`canRedo` from the document, so a command the stack cannot answer is
  never enabled.
- `Reset` discards the history, matching "revert to original" rather than a new
  undoable edit.
- The Editor's UI state is a projection (`EditorState` in `state.rs`):
  identity, dimensions, history labels, and the preview path. No front end can
  touch pixels except through the gateway.
- `KOGAVIEW_DEV_COMMANDS_START_MS` was added to the Debug harness so async
  commands (editor open) can be driven for window evidence.