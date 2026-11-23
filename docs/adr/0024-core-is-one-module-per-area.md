# ADR 0024 — Core is one module per area, not one file

- Status: accepted
- Date: 2026-11-23
- Related: ADR 0023 (the Editor is a crate), ADR 0022 (a layout owned by Core),
  ADR 0002 (the configuration file)

## Context

ADR 0023 moved the Editor out, which left `crates/app-core/src/core.rs` as the
last 5,217-line file in the tree: one `impl Core` of 2,534 lines, a 2,380-line
suite and ~100 lines of free helpers. Three problems came with that:

1. **Every command area shared one file.** A Viewer command recompiled the file
   that holds the batch worker; a reader could not tell from the file which
   methods belonged to the Browser, the Viewer, the Editor or the shell's own
   settings.
2. **The gateway is a design constraint, not an accident.** `AGENTS.md` says the
   Command Bus is the nervous system — one ordered entry point, one state owner.
   So `Core` cannot be split into cooperating crates the way the Editor could:
   the ordering *is* the feature, and the desktop bridge
   (`crates/desktop/src/bridge.rs`) names `kogaview_core::Core` directly.
3. **The file had two natural axes already.** The `impl` blocks fall into
   command areas (`dispatch`, `execute`'s match, and the handlers each arm
   calls), and the state either outlives the command (config, layout, the saved
   folders) or answers a worker (scans, editor tasks, batch events).

## Decision

- **`src/core.rs` becomes `src/core/`**, one module per area:

  | Module | What it owns |
  |---|---|
  | `mod.rs` | `Core` and its fields, the constructor and session restore, the snapshots it publishes, the value types a worker sends back, the free helpers (`is_within`, `breadcrumbs`, `restored_folders`, …) and the module declarations |
  | `gateway.rs` | `dispatch` (the envelope, the revision check, the journal), `query_json`, `execute` with its command match, `poll` and `start_operation` |
  | `browsing.rs` | `open_file`/`open_folder`/`navigate`, the scan lifecycle, selection and its Info, new folder, transfer, trash/delete, favourites, `set_theme`, panels and `save_config` |
  | `viewing.rs` | the Viewer's path, its selection, its step and the Info page |
  | `editing.rs` | the Editor's open/close, apply/preview, undo/redo/reset, save, export, the preview cache and every editor worker message |
  | `jobs.rs` | `batch_run` and the input set it resolves |
  | `tests.rs` | the whole suite, because its fixtures are shared (the same choice `crates/app-editor/src/tests.rs` makes) |

- **The fields stay private to `core/mod.rs`.** A module is a child of `core`,
  so it can read the fields the same way the original `impl` could; nothing
  outside `core` gained access, and the struct's layout did not move.
- **A method a sibling calls is `pub(super)`.** `gateway::execute` calls a
  handler in `browsing`, `editing` or `jobs`; `poll` calls back into the same
  areas. `pub(super)` is the smallest visibility that crosses that line, and it
  does not widen `Core`'s public API — the bridge and the tests see exactly what
  they saw before.
- **No command, payload, journal line or state field changed.** This is a move,
  not a redesign: `Core::dispatch`, `query_json`, `poll`, `snapshot_json`,
  `meta_json`, `folder_json`, `busy`, `revision`, `status`, `language`,
  `editor_saving`, `paths` and `state_value` are the same functions with the
  same bodies.
- **The translation gate scans recursively.** `scripts/check_translations.py`
  read `*.rs` from each source directory, so a module directory would have
  removed the moved `UiText` codes from the scan without failing: the gate is
  now recursive, and it distinguishes an inline `#[cfg(test)] mod tests {`
  (which it still truncates) from `#[cfg(test)] mod tests;` (a file it must
  keep reading). Both were measured — see the report row.

## Consequences

- A command area is now a file of 108–968 lines, and adding a command means
  choosing the area it belongs to instead of appending to one 2,534-line block.
- The gateway and its polling stay in one file on purpose: `poll` is where the
  three worker kinds meet the state they publish into, and splitting it would
  spread one ordering rule across three modules.
- `Core` is still one struct in one crate. The next boundary beyond this — if
  `editing` keeps growing — cannot be a crate unless the desktop bridge and the
  ordering rule move with it, which ADR 0023 already names as the larger,
  unproven move.
- The suite is one file. It is 2,379 lines, and it is the next candidate for a
  split by area, but only if the fixture helpers can move to a shared module
  without turning every case into an import list.

## Revision — the suite followed the modules (2026-11-23)

The consequence above called the suite the next candidate, and it became one:
`core/tests.rs` (2,379 lines) is now `core/tests/`, one file per area. The
fixtures did move to a shared module first, which was the condition:

- `tests/mod.rs` holds the fixtures — `temp_dir`, `remove_tree`, `settle_scan`,
  `settle_batch`, `settle_save`, `settle_export`, `settle_editor`,
  `settle_draft`, `select_json`, `dispatch_json`, `write_png`,
  `write_jpeg_with_exif`, `editor_envelope` — and declares five child modules.
- `tests/browsing.rs` (20 cases), `tests/viewing.rs` (2), `tests/editing.rs`
  (16), `tests/gateway.rs` (2) and `tests/jobs.rs` (6) each start with
  `use super::*;`, so a fixture is one copy and a case sits with the module it
  drives.

No test was rewritten, renamed or dropped: the same 75 core cases pass, now
under `core::tests::<area>::…`. The translation gate reads the new files (it
skips a file named `tests.rs`, which this is not) and still prints 438 strings,
which was already measured to be the same result with or without that skip.
