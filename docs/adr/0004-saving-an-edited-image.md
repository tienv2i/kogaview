# ADR 0004 — Saving an edited image: overwrite with a backup, or write a copy

- Status: accepted
- Date: 2026-11-16

## Context

ADR 0003 gave the Editor a working document that lives in memory: the source
file is read once and never written. That is the right default for a
non-destructive editor, but a session that cannot produce a file is a viewer
with extra steps, so the document needed a way out. The project rules constrain
the answer:

- "Non-destructive editing; never overwrite source images **by default**."
- "Every edit is an explicit, serializable command" and commands are journaled.
- "Long-running work must be asynchronous, bounded, cancellable and observable."
- Flatpak readiness: no assumption of host-wide write access, no external
  process for something the app can do itself.

There are three plausible exits: overwrite in place, always write a new file
("Save as" only), or both. A fourth question sits behind each of them — what
happens to the file the user opened, and how does the app know the file it is
about to replace is still the one it read?

## Decision

- **Two commands, both serializable and journaled:** `editor_save` writes the
  working pixels to the document's own `save_path`, and
  `editor_save_as {path}` writes them to a new file and *continues editing that
  file*. A `Save as` is therefore a copy-and-continue, not an export.
- **Overwriting keeps one backup.** When the target is the file the document was
  opened from, the previous bytes are renamed to `<name>.<ext>.bak` beside it
  (replacing an older `.bak`) before the new file lands. One step of "undo my
  mistake" is available outside the app; an unbounded version history is not
  this milestone.
- **The write is atomic.** Pixels are encoded to `<name>.<ext>.tmp` in the same
  directory and `rename`d over the target, so a crash or a full disk cannot
  leave a half-written image where the original was.
- **Format follows the extension** (`SaveFormat::{Png, Jpeg, Webp, Tiff, Gif,
  Bmp, Tga, Qoi}`); an unknown extension is refused with a message instead of
  silently writing PNG bytes under a `.foo` name. The save dialog offers exactly
  those filters, from `PlatformHelper::saveNameFilters`.
- **A moved source refuses the overwrite.** The document remembers the
  (size, mtime) stamp of the file it read; if the file changed underneath, the
  command answers `source_changed` and writes nothing rather than clobbering an
  edit made by another program. The user can still `Save as`.
- **Encoding and writing run on a worker thread.** Core publishes
  `EditorState.saving`, and the UI's Save button reads that published flag
  instead of keeping a latch of its own. The command is refused only while the
  initial decode is still running (`width == 0`); a pending *preview* render does
  not block a save, because the preview is presentation and the pixels are not.
- **"Unsaved" is a pixel identity, not a counter.** `EditorDocument` keeps the
  `Arc` it last saved; `saved` is `Arc::ptr_eq(current, saved_pixels)`, so an
  edit that is undone back to the saved pixels is correctly clean again.

## Consequences

- The source file is only ever replaced by an explicit `Save`, and only with a
  `.bak` of what was there. A user who never presses Save leaves every file
  untouched, which is what the rule asks for.
- Two commands, one code path: the encode/write half is shared, and the only
  difference is where the result lands and what `save_path` becomes afterwards.
- The `.bak` policy is deliberately single-generation. A user who wants
  versioned history uses `Save as` or their own tooling.
- A save that overwrites reports `Saved <name>` and a save that writes a copy
  reports the same, because from the user's point of view both produced a file.
- **Not covered here:** export presets, quality settings (JPEG is written with
  the encoder's default), metadata/EXIF preservation, and writing to a path the
  sandbox has not granted. Those are export-milestone decisions.
