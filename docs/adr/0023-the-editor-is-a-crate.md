# ADR 0023 — The Editor is a crate of its own

- Status: accepted
- Date: 2026-11-22
- Related: ADR 0003 (the Editor's working document), ADR 0005 (the format
  features), ADR 0011 (the quad), ADR 0012 (sizing is a dialog), ADR 0014
  (painting is one typed stroke)

## Context

Every Editor feature since row 61 has landed in one file,
`crates/app-core/src/editor.rs`: 3,280 lines of code and another 1,300 lines of
suite, in a crate whose other half, `core.rs`, is 5,217 lines. Three things made
that the wrong shape:

1. **The file had already declared the boundary.** Its module documentation says
   "This module owns pixels and history only; file paths, the command gateway
   and UI state stay in Core." That is a crate-shaped sentence about a module.
   The Editor does not know `Core`, `Envelope`, a journal, a workspace or a
   `QString`; it knows a document, the operations applied to it and the pixels
   they produce.
2. **The dependency set had drifted.** `image`, `jpeg-decoder`, `rayon`-free
   decoding and the DCT-scaled preview reader live only for the Editor, yet a
   reader of `app-core/src` had to open `editor.rs` to discover them, and the
   format feature list (ADR 0005) was named in `app-core/Cargo.toml`.
3. **`docs/IMPLEMENTATION_PLAN.md` had already promised this split** — "Split
   later only when a boundary is proven" — and a review of the repository said
   the line count had passed the threshold rather than approaching it. Waiting
   for a larger number would have made the move harder, not easier.

## Decision

- **A new workspace member, `crates/app-editor` (`kogaview-editor`).** It is the
  former `editor.rs` split along the seams the file already had:

  | Module | What it owns |
  |---|---|
  | `operation` | `EditOperation` and the history line each variant produces |
  | `document` | `EditorDocument`: its pixels, its undo stack, its snapshot budget, its save target |
  | `validate` | every refusal, as a `UiText` code the window can translate |
  | `pixels` | the arithmetic: resample, cover, pad, grow, the perspective warp, one brush stroke |
  | `codec` | decode, encode, the atomic save, the export copy, the JPEG metadata an original carried |
  | `render` | applying one operation: validate, hand the pixels to `pixels`, record the step |
  | `tasks` | the worker half: open, preview, draft — each answering down a channel |

- **`kogaview-core` re-exports it under the name every caller already uses:**

  ```rust
  pub use kogaview_editor as editor;
  ```

  `crate::editor::spawn_open`, `editor::SaveFormat`, `editor::render_operation`
  and `editor::validate_resize` are unchanged at every call site — Core's
  handlers and the batch worker (`crates/app-core/src/batch.rs`) were not
  touched. The re-export is not a shim to be removed later: it is how Core says
  "the Editor is a dependency of mine, not a part of me".

- **The vocabulary stays wide.** `codec`, `render`, `validate`, `tasks` and
  `document` are re-exported wholesale. Core validates a pending edit with the
  same functions it applies it with, and the batch worker renders with the same
  branch a single edit does; a narrower API would only make Core re-implement
  those checks. Only `pixels` is `pub(crate)` inside the new crate — its
  functions are reachable through the modules that use them and by nothing
  outside, which is the one boundary that turned out to be private.

- **The dependencies move with the code.** The `image` feature list, the
  `jpeg-decoder` reader for the 1/2, 1/4 and 1/8 DCT decode, and `tracing` (a
  failed preview write is logged where it happens) are `app-editor`'s now;
  `app-core` names `kogaview-editor` instead. `avif-native` still links the
  system `libdav1d`, so `CMakeLists.txt` is unchanged (ADR 0005 revision).

- **The translation gate reads both crates.** `scripts/check_translations.py`
  scans a list of source directories, not one, and skips `app-editor/src/tests.rs`
  for the same reason it skips a `#[cfg(test)]` module: the suite's fixtures
  build `UiText` lines of their own, and they are not something a window can show.
  The gate caught the move by itself — left pointing at `app-core/src` alone it
  stopped `just test` with `translations: 30 problem(s)`, beginning
  `UiLines.qml draws the line "brush_stroke", which no Core UiText publishes` —
  which is the check working: a code that leaves the scanned tree is noticed
  rather than believed. The `tests.rs` skip, by contrast, is belt-and-braces:
  dropping it changes nothing (the suite builds only codes Core already
  publishes), and that was measured rather than assumed.

## Consequences

- A change to the Editor recompiles one crate instead of invalidating the
  whole of `app-core`; a change to Core's gateway no longer recompiles the
  pixel arithmetic.
- The boundary is now enforced by the compiler rather than by a paragraph: the
  Editor cannot read a path it was not handed, call `Core`, or name a Qt type.
- `editor.rs` is gone from `app-core`; a stale `use crate::editor::…` path or a
  `crates/app-core/src/editor.rs` reference in a document is a defect, not a
  variant spelling.
- The next honest split is `core.rs` itself (5,217 lines: gateway, handlers,
  scan, tasks, journal and state publishing), and it is a larger change than
  this one because the desktop bridge names `Core` directly. It was not done
  here.
