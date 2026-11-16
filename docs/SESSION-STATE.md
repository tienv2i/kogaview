# Session handoff — state at 2026-11-16 (evening)

This handoff was written after the Editor grew Save/Save As and an unsaved-changes
guard, the Editor/Browser/Viewer edit hand-off was repaired, the Editor's columns
were split, the interface gained a live Vietnamese translation, and the decoder
list was widened. That work is committed; this file is the handoff that follows it.

Nothing here is a plan; it is what was measured, what was not, and why.

## Tree

- Branch `main`, HEAD `82c982a`, 24 commits. The session's work is **committed**
  in `82c982a` (`feat(editor): …`) and described in "What changed in this
  session" below; the tree is clean apart from this handoff.
- New files that commit added: `crates/app-core/src/editor.rs` (row 53 work,
  extended with save), `docs/adr/0003-editor-working-document.md`,
  `docs/adr/0004-saving-an-edited-image.md`,
  `docs/adr/0005-image-formats-compiled-in.md`, `docs/adr/0006-interface-language.md`,
  `i18n/kogaview_vi.ts`, `i18n/kogaview_ts.pro`, `cpp/language.h`, `cpp/language.cpp`,
  `cpp/translations.h`, `cpp/translations.cpp`, `scripts/check_translations.py`,
  `scripts/find_lrelease.py`, `crates/desktop/qml/SettingsDialog.qml`,
  `tests/qml/tst_editor.cpp`, `tests/qml/tst_language.cpp`,
  `tests/qml/tst_settings.cpp`, `opencode.json`, `.opencode/`, and four
  `docs/evidence/M1-*-vi.png` frames.
- The commit had no configured git identity on this machine; it was made with
  `-c user.name="HuynhAT" -c user.email="tienv2i@gmail.com"`, the identity every
  earlier commit in the repository uses. Nothing was written to `.git/config`.
- **Not pushed:** `origin` (`https://github.com/tienv2i/kogaview.git`) has no
  branches; `git push` answers `remote: No anonymous write access`. Credentials
  are needed before any of this leaves the machine.
- Debug binary `build/dev/bin/kogaview`, built from that commit's tree.

## Environment the evidence below was produced on

Arch Linux, GNOME on Wayland (`wayland-0`), Qt 6.12.0, rustc 1.99.1, cmake 4.5.0.

- **`KOGAVIEW_DEV_SCREENSHOT` needs `QT_QPA_PLATFORM=xcb` on this session.** A
  plain Wayland run answers `window is not exposed`; the same binary under XWayland
  grabs a real 1467×940 frame *with* the themed icons drawn. Offscreen works too
  but loads no icon theme (`QIcon::themeName()` empty, every themed icon blank), so
  judge layout there and icons only on the XWayland run.
- **`qtbase_vi.qm` does not exist here** (`/usr/share/qt6/translations` has 33
  `qtbase_*` files, no `vi`). Anything the app draws with `standardButtons` would
  therefore stay English inside a Vietnamese window; the app's own dialogs now use
  explicit `qsTr` buttons for that reason.
- `xdg-desktop-portal-gnome` still does not implement
  `org.freedesktop.impl.portal.OpenURI`: a returned request handle is not a drawn
  chooser. No screen capture is available (`grim`: "compositor doesn't support the
  screen capture protocol").
- Build needs `PATH=/tmp/opencode/lrel/bin:$PATH` (or `KOGAVIEW_LRELEASE`) because
  `lrelease`/`lupdate` come from a PySide6 copy, found by
  `scripts/find_lrelease.py`.

## What changed in this session

| Row (`docs/M1-REPORT.md`) | Change | Verified how |
|---|---|---|
| 55 | Browser/Viewer "Edit" now really opens the image in the Editor, and a Viewer→Editor switch carries the open image | QML suites assert the new `editInEditor(path)` signal; Core test `switching_to_the_editor_carries_the_viewer_image`; real window (`/tmp/opencode/kvW/linked.png`) |
| 56 | `editor_save` (overwrite + `.bak`) and `editor_save_as`, atomic temp+rename, `source_changed` refusal, unsaved-changes prompt | Core save tests; real window: `photo-1.jpg` rotated and overwritten with a `.bak`, Discard/Cancel/Save exercised through `KOGAVIEW_DEV_UI_REQUEST=leave-guard` |
| 57 | Editor columns split: edits left, commands right; `panMargin: 64` and touchpad/middle-click panning | `tst_editor` (three cases); real window `offsetX/offsetY 0 → 64` |
| 58 | i18n: `Language {system,en,vi}`, 132-string Vietnamese catalogue compiled into a `.rcc`, live switch, `tst_language`, `scripts/check_translations.py` | `just test language`, `just test translations`, four real-window screenshots in `docs/evidence/M1-*-vi.png` |
| 59 | Formats: 15 decoders compiled in, no runtime download, `avif-native` rejected, `heic`/`heif` listed but undecodable | `every_advertised_extension_has_a_decoder`; `KOGAVIEW_DEV_FORMATS=1` output |
| 60 | **Diagnosis only** — why the Editor takes seconds to open a photo | cause recorded, fix postponed at the owner's request |

## Test gate

`PATH=/tmp/opencode/lrel/bin:$PATH just test` runs the translation check, the
Cargo workspace and seven Qt suites:

```
translations: 132 strings in kogaview_vi.ts, 104 of them compiled into C++
cargo: 60 passed + 4 passed
viewer 22 · browser 33 · cache 15 · state 7 · settings 7 · editor 16 · language 5
```

`cargo fmt --check` is clean. `just test translations`, `just test language` and
`just test <suite>` exist because the full gate is ~20 s warm.

## Known gaps, in the words they were last measured with

- **Core's status text is still English.** `Ready`, `Editing photo-1.jpg · 2400 ×
  1600`, `7 items · 6 images`, `Saving …` are built in Core with `format!`; Core is
  Qt-free and cannot translate. The fix is a status *code plus arguments*
  translated at the presentation edge — a protocol change, not a catalogue entry
  (ADR 0006 records it).
- **Save As through the portal chooser is unverified**, because the chooser has
  never been seen drawn on this session (row 49). Only the fallback dialog path was
  exercised.
- **No physical input.** Pan, wheel zoom, menu opening and the unsaved dialog are
  driven by `QTest` and by `KOGAVIEW_DEV_*` hooks on the real window; no hand was on
  the mouse.
- **No Wayland (non-XWayland) frame this session.** Every picture is XWayland.
- **`KOGAVIEW_DEV_UI_REQUEST=context-menu-trigger` matches menu entries by their
  English `text`.** With the interface in Vietnamese the lookup finds nothing; pass
  the translated label (e.g. `_ARG2="Chỉnh sửa"`) or run in English.
- **The Editor decodes at full resolution** before downscaling (row 60). A debug
  build needs `KOGAVIEW_DEV_COMMANDS_STAGGER_MS` ≥ 3000–4000 for a batch that edits
  the document, and `KOGAVIEW_DEV_UI_REQUEST_DELAY_MS` ≥ 18000 in a clean root.
- **`avif-native` must stay out of `crates/app-core/Cargo.toml`** — it links the
  system `libdav1d` and the build fails with undefined `dav1d_*` symbols.
- **Stray instances.** A leftover `kogaview` process holds the dev app id and makes
  the next window report "not exposed": `pkill -x kogaview` (not `pkill -f`, which
  also matches the shell running it).

## How to reproduce the verification loop

```sh
just doctor && git status --short
PATH=/tmp/opencode/lrel/bin:$PATH just build
PATH=/tmp/opencode/lrel/bin:$PATH just test

# real window (icons drawn): XWayland on this session
pkill -x kogaview
XDG_STATE_HOME=/tmp/opencode/kvS XDG_CONFIG_HOME=/tmp/opencode/kvC \
XDG_CACHE_HOME=/tmp/opencode/kvK QT_QPA_PLATFORM=xcb \
QT_ASSUME_STDERR_HAS_CONSOLE=1 \
KOGAVIEW_DEV_COMMANDS='{"type":"set_settings","theme":"dark","remember_last_folder":true,"background_thumbnails":true,"language":"vi"}' \
KOGAVIEW_DEV_COMMANDS_START_MS=2000 \
KOGAVIEW_DEV_SCREENSHOT=/tmp/opencode/shot.png KOGAVIEW_DEV_SCREENSHOT_DELAY_MS=6000 \
KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT=1 ./build/dev/bin/kogaview
```

Dev hooks (Debug builds only, inert unless set; full list in the "Dev harness"
section of `docs/M1-REPORT.md` and in
`.opencode/skills/real-window-verification/references/dev-harness.md`):
`KOGAVIEW_DEV_COMMANDS`, `_START_MS`, `_STAGGER_MS`, `KOGAVIEW_DEV_STATE`,
`KOGAVIEW_DEV_SCREENSHOT[_DELAY_MS]`, `KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT`,
`KOGAVIEW_DEV_EXIT_AFTER_MS`, `KOGAVIEW_DEV_GEOM`, `KOGAVIEW_DEV_WHEEL`,
`KOGAVIEW_DEV_FILMSTRIP_WHEEL`, `KOGAVIEW_DEV_VIEWER_MENU`,
`KOGAVIEW_DEV_COPY_IMAGE`, `KOGAVIEW_DEV_EDITOR_WHEEL` (+ `_DELAY_MS`),
`KOGAVIEW_DEV_FORMATS`, `KOGAVIEW_DEV_UI_REQUEST` + `_ARG`/`_ARG2`/`_DELAY_MS`/
`_REPEAT_MS` (`open-folder`, `open-external`, `open-with`, `context-menu`,
`context-menu-trigger`, `settings`, `editor-fit`, `editor-zoom`, `editor-pan`,
`editor-pan-as`, `leave-guard`), `KOGAVIEW_DEV_PORTAL_DISMISS_MS`,
`KOGAVIEW_UI_LANG` (harness language override, wins over the stored setting).

## Fixtures

`/tmp/opencode` is the scratch root; per-run XDG roots live under `kv*`
(`kvW/pics` holds `photo-1..6.jpg` at 2400×1600, `photo-1.jpg` is now rotated with
a `.bak` beside it). Nothing in `/tmp` is kept between sessions and nothing there
is an artefact: the Qt suites build their own trees in `QTemporaryDir` or use fake
`/root/...` paths, so `just test` never touches the disk.

## Next natural step

1. **Status text as data.** Publish `status { code, args }` from Core and translate
   it in QML/bridge, so the last English strings in a Vietnamese window go away.
2. **Export** the working document with real options (JPEG quality, metadata) —
   ADR 0004 deliberately left those out.
3. **Editor open speed** (row 60): downscaled JPEG decode for the preview, tiled
   decode for the document.
4. The adjustment operations (brightness/contrast/saturation) are still disabled in
   the Editor's tool column.
