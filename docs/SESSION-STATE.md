# Session handoff — state at 2026-11-21

Four sessions' worth of work on the same day: the launch surface speaks
Vietnamese and the dock icon draws, the mouse wheel moves at the rate the device
reports, fit is a mode that survives a window resize while Settings previews
live and saves on Apply/OK, the toolbar drops its labels instead of being
squashed while a shell-opened window is sized to the picture, the label threshold
now follows the interface language instead of measuring English, the Browser
and Viewer are operable from the keyboard, their tooltips name the keys, the
burger menu opens a file, a folder or the Editor, a modal dialog owns the
pointer so the Settings header drags in the Viewer instead of panning the
picture behind it, the Editor is a tool palette with a pointer inspector
rather than a second toolbar, its Resize tool links Width and Height through
a ratio, offers many 64-divisible sizes and can render the result live before
Apply — with the pointer thumbnail now keyed on the preview file's own identity
instead of a name that repeats every run — and its Crop tool has the same linked
sides and presets, a 3 × 3 anchor that places the rectangle and its own live
preview. The two size tools now also carry +/- steppers on Width and Height, a
`Keep current ratio` lock for a custom pair, and a shorter list of ratios and
samples; this follow-up makes the steppers auto-repeat and starts them from the
document size, fixes the Crop preset list that filled the fields on open, and
turns the old square pad into `Pad to fit` — the whole picture fits the target
and only the leftover is filled, square or not. The next session did the three
things the handoff had listed as the natural next steps: Core's status and
history text became `{ code, args }` lines the window translates (row 77), the
Editor gained a real Export with a JPEG quality and metadata (row 78), and a
large JPEG's first preview is now decoded at a reduced DCT scale so the picture
appears while the full frame is still decoding (row 79). The session after that
made the last English sentences in a Vietnamese window — the toast for a
*rejected* command — translatable too (row 80), and while doing it found that
`UiLines.qml` was not named in the `lupdate` project, so the next `lupdate`
would have marked its thirty sentences `vanished` and `lrelease` would have
dropped them silently. A fifth change (row 81) lets Export write a delivery copy
at a chosen long edge — `Original size`, 3840, 2560, 1920, 1280 or 800 px —
scaling the whole frame and never enlarging it, and keeps the ICC profile but
not the EXIF of a resized copy. The latest session made the canvas itself an
editing surface (row 82): Crop's rectangle is now a frame you drag out on the
picture, move from the inside and resize from eight handles, and a fourth tool,
Transform, carries four source corners plus four edge handles so a keystoned
photo can be straightened; both tools keep their typed fields as the same
rectangle or quad and share the existing preview/Apply path in Core. The latest
session (row 83) turned Resize into a dialog of its own — the Settings pattern,
with the form's live draft inside it — and made Discard reset the document before
the workspace changes; without that reset Core still saw unsaved edits and the
Editor reopened the old image after the user had already discarded them. A
follow-up (row 84) took the framed preview out of that dialog: its asynchronous
picture read as the form loading before it settled, and the size is typed, so
the form is fields and buttons only. The latest session (row 85) gave the canvas
a brush and an eraser with Krita's default keys: a stroke is one typed command
sent on release, Core paints the pixels and the canvas only shows the stroke in
flight; `B`/`E` pick the tools, `[`/`]` size them, `X`/`D` swap and reset the
colours, Space pans, `Tab` hides the panels, and `Ctrl+Z`/`Ctrl+Shift+Z` undo and
redo the document. A last fix (row 86) moves both modal forms' centring and
opening values from `onOpened` to `onAboutToShow`: Breeze's enter fade was
running while the form sat at the window's left edge, then `opened` moved it to
the centre when the fade finished. This session added the copy keys (row 87):
`Ctrl+Shift+C` puts the one picture's pixels on the clipboard and `Ctrl+Alt+C`
its path, both declared once in `Main.qml`, and the right-click menus now draw
their keys in a measured right-hand column because a `MenuItem` has no shortcut
column of its own. The same session gave the header a third state (row 88):
below the icon-only width each workspace keeps a few buttons and folds the rest
into one `⋮` menu, which lowered the window floor from ~798 px to a measured
580 px. A follow-up (row 89) moved the fold and label points from the widest
workspace to the workspace on screen: the three switcher buttons now decide
which row the window must fit, so the Browser no longer folds at the Editor's
width and shows its labels about 350 px sooner.

Nothing here is a plan; it is what was measured, what was not, and why.

## Tree

- Branch `main`. The previous session's three changes (rows 77, 78, 79) are one
  commit, `ca9a6d6 feat(editor): typed lines, export and a fast first preview`,
  on top of the build fix `1b4e940` and the pad/stepper follow-up `9d4dab4`.
  This session adds two commits: `feat(core): word a rejected command in the
  interface language` for row 80 (the `ProtocolError.ui` shape, the QML that
  draws it, the new QML/Core tests, the `.pro` fix and its translation-gate
  check, and the 32 Vietnamese sentences), then `feat(editor): export at a
  chosen long edge` for row 81 (`max_edge` on `editor_export`, the long-edge
  rule and the APP1 rule in Core, the dialog's `Output size` row, two Core
  tests and one QML case, ADR 0004). The canvas-drag session (row 82) is one
  commit on top: the Transform tool in protocol/Core/QML, the crop frame and
  its handles, the four new QML cases, the new `editor-transform` harness
  request and the four screenshots. ADR 0011 records why the transform is a
  quad, why the output keeps the document's size and why it undoes by snapshot.
  The resize-dialog session (row 83) is one commit on top: the new
  `ResizeDialog.qml`, the Core/`Main.qml` half of the Discard fix, the crop
  field renames, the tests, the `_ARG5=apply` hook and the three screenshots.
  ADR 0012 records why a size is a dialog and ADR 0013 why Discard sends a reset
  first. The preview-removal follow-up (row 84) is one commit on top: the
  `ResizeDialog.qml` slimming, the `EditorView.qml`/`cpp/main.cpp` wiring it
  drops, `theResizeDialogHasNoPreviewSurfaces`, the Vietnamese catalogue cleanup
  and the new first-frame screenshot; ADR 0012 gained a revision note.
  The paint session (row 85) is one commit on top: the `editor_paint_stroke`
  protocol command, Core's mask renderer and its four tests, the palette/inspector
  and canvas overlay in `EditorView.qml`, Krita's keys, the five QML cases, the
  `editor-paint` harness request, the Vietnamese sentences and the two
  screenshots; ADR 0014 records why a stroke is one command, why QML only
  previews it and where the keymap lives. It also fixes the editor suite's
  cross-case flake (a fading modal took the next case's click). The dialog-open
  fix (row 86) is one commit on top: `ResizeDialog.qml`/`SettingsDialog.qml`
  move their opening work to `onAboutToShow`, `tst_editor`/`tst_settings` gain a
  slow-enter case each, and the two first-frame screenshots are new. No ADR:
  this corrects a lifecycle hook, not a decision.
  This session (rows 87 and 88) is one commit on top, `ecb1129 feat(shell):
  copy keys in the menus and a mini toolbar`: the two window `Shortcut`s and
  their copy helpers in `Main.qml`, the new `MenuShortcut.qml` and the measured
  key column in `Theme.qml`, the hints in `Viewer.qml`/`BrowserView.qml`, the three-tier
  rows in `ToolbarMetrics.qml` and the three views' overflow menus and folded
  visibility, `theCopyEntriesNameTheirKeys` in the two view suites,
  `theShellBindsTheCopyKeysItsMenusName` in `tst_settings`, the mini counts and
  `theFloorIsTheMiniToolbar` in `tst_toolbar`, the 12 Vietnamese sentences,
  ADR 0015 and ADR 0016 plus a revision note in ADR 0010, and the eight
  screenshots. It is one commit rather than two because `Main.qml`, `Theme.qml`
  and the `.ts` carry both rows; the tree at each row was not separately run.
  The follow-up (row 89) is one commit on top, `fix(shell): measure the toolbar
  tier for the open workspace`: `ToolbarMetrics.qml`'s per-workspace rows and
  `modeFor`, `Main.qml`'s single `toolbarMode` binding, the two fixtures, six
  row measurements and `theTierFollowsTheOpenWorkspace`, ADR 0017, a revision
  note in ADR 0015, and three screenshots. No `.ts` change: no new words.
  Nothing is pushed (see below).
  Earlier commits in `git log`: the keyboard map, the tooltip hints, the
  burger-menu fix, the modal-pointer fix, the Editor layout and its pointer
  follow-up, and the two size tools.
- `cpp/main.cpp` gained a third permanent editor request in row 78,
  `KOGAVIEW_DEV_UI_REQUEST=editor-export` (`_ARG` = destination, `_ARG2` =
  quality 10–100, `_ARG3` = `confirm`): it `click()`s the real toolbar Export
  button, writes the dialog's own properties, logs the popped-up state and
  presses the dialog's Export. It is documented in the harness reference like
  the two below. Row 81 gave it `_ARG4` (a long-edge preset) and a log line that
  names the tool before and after the confirm click, which is how a one-off grab
  showing the Resize panel was reduced to "did not reproduce" rather than left
  as a mystery.
- `cpp/main.cpp` gained one permanent debug hook per size tool:
  `KOGAVIEW_DEV_UI_REQUEST=editor-resize` (`_ARG` = `WIDTHxHEIGHT` of a preset,
  or a custom pair; `_ARG2` = an optional ratio key such as `current`; `_ARG3` =
  a fill colour that arms `Pad to fit`; `_ARG4` = stepper taps such as
  `w+3,h-2`; `_ARG5=apply` presses the dialog's Apply) clicks the palette's
  Resize button, which since row 83 opens the Resize **dialog**, waits for it
  to open, fills it through the dialog's own helpers (or writes the two fields
  for a custom pair), arms the pad, clicks the dialog's stepper buttons and
  optionally presses Apply; row 84 removed the Live preview click, because the
  form no longer has a preview; `editor-crop` (`_ARG` =
  `WIDTHxHEIGHT`, `_ARG2` = an anchor key, default `center`) does the same for
  Crop including an anchor button — found by walking the item tree, because a
  `Repeater` delegate is not a QObject child. Both exist so the panel can be
  photographed on a session where XTEST pointer warps do not move the pointer.
  Row 80 also fixed a harness bug found while checking a second run: both size
  requests clicked the tool button unconditionally, and selecting a tool is a
  toggle, so a second `editor-resize` while Resize was already selected put the
  tool down and the request then wrote its fields into a Pointer panel. They now
  click only while `highlighted` is false — row 83 keeps that for Crop, and
  Resize needs no guard at all because its button opens a dialog instead of
  toggling a mode. The language
  follow-up changes exactly one thing in it — `KOGAVIEW_DEV_SCREENSHOT` now
  treats `isExposed()` as a hint (a covered window on this session reports
  itself unexposed while `grabWindow()` still renders), waiting up to 8 s and
  then grabbing anyway. Temporary hooks used on the real window and removed
  again:
  `KOGAVIEW_DEV_WHEEL_LOG`, `KOGAVIEW_DEV_GRID_SCROLL` (wheel session),
  `KOGAVIEW_DEV_RESIZE` and `KOGAVIEW_DEV_SETTINGS_STEPS` (fit/settings session),
  `KOGAVIEW_DEV_RESIZE` with `KOGAVIEW_DEV_RESIZE_SHOT` twice (toolbar, and
  the Vietnamese threshold), `KOGAVIEW_DEV_KEYS` (keyboard session; QTest
  key events through the real window's focus item),
  `KOGAVIEW_DEV_GRAB_POPUPS` (tooltip session; grabbed the window with a
  tooltip forced open), `KOGAVIEW_DEV_MAIN_MENU`/`KOGAVIEW_DEV_EDITOR_PICK`
  (menu session; opened the shell menu and replayed the chooser's answer), and
  `KOGAVIEW_DEV_UI_REQUEST=settings-drag` (modal-pointer session; dragged the
  real Settings header with `QTest` and logged the dialog and Viewer offsets).
  Every temporary hook is gone again; the only surviving debug additions are the
  permanent `editor-resize`, `editor-crop` and `editor-transform` requests
  above, plus row 87's `KOGAVIEW_DEV_KEY`. `editor-transform` (row 82) clicks the
  Transform tool, moves one corner
  (`_ARG` = `X,Y` in document pixels, `_ARG2` = `0`–`3` or `e0`–`e3`) through the
  same helpers the handles call, and takes `_ARG3=live` and `_ARG4=apply`; it
  found nothing broken, but it is the only way a quad reached the real window
  this session. `KOGAVIEW_DEV_KEY` (`;`-separated sequences) finds the
  `Shortcut` that declares each one, sends it the `QShortcutEvent` its handler
  consumes and logs `declared`/`allowed`, the toast and both clipboards; it
  exists because no physical key reaches this window. Row 87 also gave
  `KOGAVIEW_DEV_UI_REQUEST=context-menu` an `_ARG2` naming a menu object, which
  is how the three overflow menus were photographed, and used a temporary
  `KOGAVIEW_DEV_RESIZE=WIDTHxHEIGHT` for the mini shots — removed again, and
  `strings build/dev/bin/kogaview | grep -c KOGAVIEW_DEV_RESIZE` answers `0` on
  the committed build.
- **Not pushed:** `origin` has no branches; `git push` answers `remote: No
  anonymous write access`.
- Installed state: `/usr/local/bin/kogaview` (currently the **`dev-prod`**
  build: RelWithDebInfo + dev hooks, production identity) plus entry, SVG, seven
  PNG rasters, merged `index.theme` and metainfo; `xdg-mime query default
  image/jpeg` is `io.github.tienv2i.KogaView.desktop` **because the owner set it
  that way** — the install itself never calls `xdg-mime default`.
- The prefix binary is a development install on purpose (the owner asked for
  that, not a separate release). `just install` replaces it with a Release build;
  `just install-dev` puts the hook-carrying one back. **Never symlink
  `build/dev/bin/kogaview` into the prefix**: it is `.Dev` with `kogaview-dev`
  directories, so the launcher would not match it and it would read none of the
  saved configuration.

## Environment the evidence was produced on

Arch Linux, GNOME on Wayland (`wayland-0`), Qt 6.12.0, rustc 1.99.1, icon theme
`Papirus-Dark`, system PySide6 in `/usr/lib/python3.14/site-packages`.

- Build needs `PATH=/usr/lib/qt6/bin:$PATH` (`lrelease` is the system Qt 6 one
  now; the `/tmp/opencode/lrel` copy is gone).
- `KOGAVIEW_DEV_SCREENSHOT` works on the real Wayland window (a window grab needs
  no compositor permission); `QT_QPA_PLATFORM=offscreen` loads no icon theme.
- **`qInfo`/`qWarning` from the harness are silent when stderr is a file.** Qt 6
  sends its default message output wherever it thinks a console is, so a
  `timeout … build/dev/bin/kogaview > run.log 2>&1` run prints only the Rust
  tracing lines and every `KogaView dev …` line disappears — which reads exactly
  like a hook that never fired. `QT_ASSUME_STDERR_HAS_CONSOLE=1` on the command
  restores them (row 82 lost a run to this before noticing).
- `org.gnome.Shell` `Eval` answers `ok False`: the app grid cannot be read or
  photographed from here.
- **No `wmctrl`, and XTEST input does not reach the app window.** A window
  cannot be resized, clicked or typed into from a script on this session;
  real-window checks drove the app through temporary debug hooks —
  `QQuickWindow::resize`, a button's `click()`, or `QTest::keyClick` through the
  real focus item (`KOGAVIEW_DEV_KEYS`) — not through a hand. Mouse and key
  events sent with `xdotool` were silently ignored by the Wayland/XWayland
  window.
- **`xdotool` exists but only works on a window the run itself created under
  `QT_QPA_PLATFORM=xcb`**, and only while that launch keeps focus; a warm-up
  click on the "Editor" tab was what let a later click reach a field. That is
  how the Resize panel was typed into (row 72); it is still not a human hand, and
  it does not touch the compositor's own windows. On the row 73 runs the same
  trick did not reproduce: `xdotool mousemove` reported success but
  `getmouselocation` never changed, so the panel was driven by the
  `editor-resize` request instead (synthetic state, real QML handlers); the row
  74 crop panel used `editor-crop` for the same reason, including a real click
  on the anchor button found through the item tree.

## What changed

| Row (`docs/M1-REPORT.md`) | Change | Verified how |
|---|---|---|
| 62 | Dock/app-grid icon was blank while Open With drew it; launch surface had no Vietnamese | prefix `icon-theme.cache` contains the app id; `Gtk.IconTheme.lookup_icon` answers PNG 16–256 and SVG at 96/512; `GioUnix.DesktopAppInfo` returns `Trình xem ảnh` under `vi_VN`; `just doctor` reports `7/7 raster sizes + SVG` |
| 63 | The mouse wheel scrolled ~29× too slowly in the grid and filmstrip | a notch is `angleDelta ±120` *plus* `pixelDelta ±10`; after the fix one notch = 645 px = 3 × 215 px, every settled offset a multiple of 645 |
| 64 | Fit did not survive a resize (Viewer `fit()` cleared its own flag; neither view refitted on a window resize); Settings applied nothing until Save | real window: 1920×935 fit `1.52717` → 760×520 fit `0.539` → 1100×700 fit `0.833`, screenshot whole; settings preview `dark → light` with `config.json` untouched, Cancel restored, Apply wrote `set_settings` rev 2 and stayed open |
| 65 | Toolbar squashed below its floor; shell-opened windows ignored the picture's shape; the Vietnamese threshold was computed from English labels and the small-image hint had no translation | real window with a temporary resize hook: row 683 px compact / 921 px labelled (English Viewer), 1039 (English Editor), 1015 / 1133 (Vietnamese), floor **870** re-applied after requests for 200–869, labels on at exactly **1131** and off at 1130 in English, on at exactly **1225** and off at 1224 in Vietnamese (Editor); 2400×1600 → 1339×1086, 300×200 → 878×420 at 100 % with the hint, 9000×600 → 1731×420 at 19 %, 700×700 → 878×904; screenshots in `docs/evidence/M1-toolbar-*.png` and `M1-window-*.png` (Vietnamese ones suffixed `-vi`) |
| 66 | The Browser and Viewer were mouse-only; no key walked the grid, stepped/zoomed/rotated the picture, trashed a file or switched workspace | QML suites: `viewer` 35 and `browser` 42 cases; real debug binary with a temporary `KOGAVIEW_DEV_KEYS` hook (QTest key events through the real focus path) + `KOGAVIEW_DEV_GEOM`/`KOGAVIEW_DEV_SCREENSHOT`; journals under `/tmp/opencode/kb/s*/kogaview-dev/journal/commands.jsonl`; pictures `docs/evidence/M1-keyboard-browser.png`, `docs/evidence/M1-keyboard-viewer.png` |
| 67 | Tooltips described the controls but not the keys that reach them | three new QML cases reading each button's attached `ToolTip.text` (`viewer` 36, `browser` 44, `editor` 19 cases); `just test translations` (142 strings, 112 compiled into C++); real binary with a temporary `KOGAVIEW_DEV_GRAB_POPUPS` hook and a forced `ToolTip.visible` → `docs/evidence/M1-tooltip-shortcuts.png` (`Rotate left (Shift+R)`); dropping a key from a tooltip fails its suite, dropping it from the catalogue fails the translation gate |
| 68 | The burger menu showed `Move down`/`Open file…` in its first two slots and had no explicit Editor entry | `tst_browser.cpp::shellMenuStartsWithTheOpenEntries` resolving `Theme.menuEntries[n]` to labels from `Main.qml` (browser now 45 cases); `just test translations` (143 strings); real binary with temporary `KOGAVIEW_DEV_MAIN_MENU`/`KOGAVIEW_DEV_EDITOR_PICK` hooks → `docs/evidence/M1-main-menu.png`, `docs/evidence/M1-open-in-editor.png`; journal `set_workspace` rev 3 then `editor_open` rev 4, Editor status `Editing M1-viewer.png` |
| 70–71 | The Editor's sidebars duplicated the toolbar, then kept Undo/Redo/Reset in the palette with no home for the document itself | palette Pointer/Resize/Crop with per-tool inspector, header Undo/Redo/Reset (12 buttons, 5 separators), Pointer default showing details, cached thumbnail and history; `editor` 22 cases at that point (`docs/evidence/M1-editor-tools.png`, `M1-editor-pointer.png`) |
| 69 | The Settings dialog could not be dragged by its header in the Viewer (the pan handler took the drag); it worked in the Editor | `tst_viewer.cpp::aModalDialogOwnsThePointer` (real Viewer + real Settings dialog, header drag moves the dialog and leaves the offsets at 0, then Escape/R prove focus returns), `tst_settings.cpp::theShellSuspendsTheWorkspaceWhileAModalDialogIsOpen` (source guard on `Main.qml`); real binary with a temporary `KOGAVIEW_DEV_UI_REQUEST=settings-drag` hook: header drag `(330,108) → (250,148)` moved the dialog, offsets stayed `0,0` (before the fix the dialog stayed put and the offsets went `-80,40`) |
| 72 | Resize could only type two numbers: no anchor, no common sizes, no squaring | anchor pad + 64-divisible presets + pad-to-square colour, in Core (`pad_to_square`, `anchored_cover_rect`) and QML; `cargo` 63, `editor` 24, `translations` 161 strings; real window `docs/evidence/M1-editor-resize.png`, `M1-editor-resize-square.png`; mutations: pad ignoring the anchor, Resize not padding, preset auto-selected |
| 73 | Resize's anchor belonged to Crop, Width/Height were not linked, the preset list was one size per ratio, there was no live preview, and the pointer thumbnail could show the previous run's picture | anchor removed from protocol/Core/QML and the pad centred; ratio-linked fields, 47 sizes and a live-preview Core draft (`editor_resize_preview`); thumbnail cache keyed on the published preview mtime/size. `cargo` 63 + 4, `editor` 27, `translations` 155 strings; real window `docs/evidence/M1-editor-resize-live.png`, `M1-editor-thumbnail-second-run.png`; mutations: thumbnail identity zeroed, `free` ratio left linked, pad not centred, preview stamp zeroed |
| 74 | Crop still typed four numbers by hand: no linked sides, no presets, nowhere to say where inside the document the rectangle belongs, and no way to see the cut before applying it | shared `sizeRatios`/`sizePresets`, a fitting `cropPresets` list, a 3 × 3 `cropAnchors` pad that places X/Y, and `editor_crop_preview` reusing the draft with `kind: "crop"`. `cargo` 64 + 4, `editor` 31, `translations` 166 strings; real window `docs/evidence/M1-editor-crop-live.png` (512 × 384 at `bottom_right`, draft on canvas, status still 1254 × 1254); mutations: preset filter removed, draft kind ignored, anchor column fixed, Core kind swapped |
| 75 | Width/Height were type-only, a custom W:H pair could not be locked, and 12 ratios / 47 samples made the panel longer than it was useful | `stepField` plus four arrow buttons, a per-tool `Keep current ratio` snapshot, six common ratios (21:9, 5:4, 16:10, 2:3 removed) and 18 presets (three per ratio); `editor-resize` also takes a custom pair and an `_ARG2` ratio key. `cargo` 64 + 4, `editor` 33, `translations` 171 strings; real window `docs/evidence/M1-editor-resize-current-ratio.png` (1000 × 700 with `Keep current ratio`, draft on canvas, status still 1254 × 1254); mutations: snapshot call removed (`captured.width` 0), stepper link removed, 21:9 restored |
| 76 | The steppers felt stuck or bounded, the shared Width/Height fields showed 2048 × 2048 on a fresh Resize panel, and `Pad to square` forced a square frame instead of the requested fit-inside-and-fill | `stepField` starts from an empty/invalid field's placeholder and clamps both sides to 1–20000, the four arrow buttons auto-repeat and are 24 × 16, both preset dropdowns apply only from `onActivated` (Crop's document-filtered model was re-applying its first row when a document arrived), and `pad_to_square` became `fit_with_padding` in Core: scale the whole source into the target and fill the leftover, letterbox or pillarbox. `cargo` 65 + 4, `editor` 34, `translations` 172 strings; real window `docs/evidence/M1-editor-resize-pad-fit.png` (1003 × 698 target from a 1595 × 2048 portrait, red bars, `Pad to fit`, status still 1595 × 2048); mutations: ratio link removed from `stepField`, the Crop dropdown reverted to `onCurrentIndexChanged`, `fit_with_padding` stretched to the target |
| 77 | The last English sentences in a Vietnamese window came from Core: `Ready`, `Editing pic.jpg`, `Resize 512 × 512 · square #ff0000` | `UiText { code, args }` in `state.rs` with `UiState.status` and `EditorState.history` as lines, every Core handler returning `Result<Option<UiText>, _>`, the new `crates/desktop/qml/UiLines.qml` as the only code→`qsTr` table, the journal and the reply's `message` keeping the English rendering while the reply also carries `"ui": {code, args}`, `scripts/check_translations.py` now failing a Core code with no `case` and a `case` no Core publishes. `cargo` 66 + 4, `editor` 34, `translations` 244; mutations: a deleted `case "ready"` fails the gate, `UiLines.text()` returning the code fails `thePointerShowsTheDocumentAndHistory` |
| 78 | Export did not exist and ADR 0004 had deferred its options | `Command::EditorExport { path, quality, metadata }`, Core `editor_export`/`apply_export_result`/`export_pixels` with the JPEG metadata splice and `invalid_destination` for the document's own path, a 13th toolbar button with the `exportDialog` (path, quality, metadata, saying which format honours which), `Main.qml` fallback chooser, `ToolbarMetrics.editorButtons: 13`. `cargo` 66 + 4 (the export test now compares sizes between two identical-metadata exports, so the metadata flag cannot mask a broken quality setting), `editor` 35, `translations` 244; real window `docs/evidence/M1-editor-export-dialog.png`, `editor_export ok:true rev 9`, 245 252 B copy at quality 60 vs a 639 157 B source; mutations: quality ignored → size test fails, metadata splice dropped → metadata test fails |
| 79 | Opening a 27 MP JPEG in the Editor took 11 s of empty canvas: Core decoded the full frame, then resized it for the preview, before anything could be drawn | `crates/app-core/Cargo.toml` (`jpeg-decoder`, no default features, pure Rust), `crates/app-core/src/editor.rs` (`scaled_jpeg_preview` reads 1/8, 1/4 or 1/2 of a JPEG through the DCT and answers the header size; `preview_dimensions`; `render_preview` now box-samples via `preview_pixels`/`imageops::thumbnail`; `spawn_open` publishes `EditorTask::FirstPreview` before decoding the document), `crates/app-core/src/state.rs` (`EditorState.opening`), `crates/app-core/src/core.rs` (`publish_opening_preview`, the `FirstPreview` arm, a failed open now drops the fast preview it had shown), `crates/desktop/qml/EditorView.qml` (`opening`/`documentReady`: the canvas and the footer draw the provisional state, the tools stay disabled), `tests/qml/tst_editor.cpp` (`theCanvasPaintsTheOpeningPreviewWhileTheDocumentDecodes`), Core tests (`the_scaled_jpeg_preview_matches_the_full_decode`, `a_small_jpeg_is_not_decoded_twice`, `opening_a_large_jpeg_publishes_the_preview_before_the_document`), `cargo test`, `just test` | **Measured** on a 4500 × 6000 JPEG (1.4 MB, `ffmpeg -q:v 3`): before, one decode of 11 063 ms and then a preview render of 6 264 ms; after, the reduced decode plus its PNG lands at 3 034 ms (the picture is on screen from 3.1 s) and the full document installs at 7 863 ms instead of 11 063 ms. The 2× on the document half is `imageops::thumbnail` replacing `imageops::resize(…, Triangle)`: on a 27 MP frame the general resampler was the second-largest cost after the decode. **Real window** (Vietnamese, isolated `XDG_*`): the grab at 8 s shows the picture, `4500 × 6000`, the soft decode on the canvas, `Đang mở big.jpg…` in the status bar and Resize/Crop/Rotate greyed; the grab after the document landed shows `Đang chỉnh sửa big.jpg · 4500 × 6000` with every tool live and a `editor_resize_preview` draft on the canvas (journal rev 5). **Mutations** (each restored, then re-run): `scaled_jpeg_preview` returning `None` always → `opening_a_large_jpeg_publishes_the_preview_before_the_document` fails on the first message; `documentReady` no longer subtracting `opening` → the QML test fails `!m_editor->property("documentReady")`. **Not verified:** no hand opened a file; the run was driven by dev commands. A CMYK JPEG and a progressive JPEG take the fallback path, which is exercised only by `a_small_jpeg_is_not_decoded_twice` (a plain JPEG), not by a CMYK sample. `jpeg-decoder`'s `scale()` picks the smallest power of two that still covers the request, so on a frame just above 4096 px the reduced decode is 1/2 and the saving is smaller than these numbers; that case was not timed. |
| 80 | A rejected command was still English in a Vietnamese window: `Main.qml` drew `result.error.message`, a sentence Core had built | `crates/app-protocol/src/lib.rs` (`UiText` beside `ProtocolError`, which gained `ui: Option<UiText>` and `line`/`with_line`; `None` where the detail is the platform's), `crates/app-core/src/state.rs` (re-export), `core.rs` (every refusal Core words itself publishes a line; `invalid_edit` keeps a journal sentence for crop/resize), `editor.rs` (validators and `apply`/`would_change` answer `UiText`), `ops.rs` (`safe_for_deletion`), `Main.qml` (toast draws `error.ui` first), `UiLines.qml` (32 cases), `i18n/kogaview_ts.pro` (`UiLines.qml`/`ToolbarMetrics.qml` were missing — the next `lupdate` would have marked their strings `vanished`), `scripts/check_translations.py` (a QML file that draws a string must be in the `.pro`), `i18n/kogaview_vi.ts` (32 strings), `tests/qml/tst_language.cpp` (2 cases), Core tests | `just test` 276 strings / 110 C++ / 272 drawn; cargo 70 + 4; language 7; real window: Vietnamese toast `Xuất đè lên tài liệu đang mở sẽ thay thế nó; hãy dùng Lưu` after the export dialog was pointed at the document itself (`docs/evidence/M1-rejection-vi.png`), journal `ok:false` `invalid_destination` + `ui.code export_onto_document`; 5 mutations, each caught |
| 81 | Export always wrote the document at its own size: delivering a 27 MP picture at a web or phone size meant editing the document first, which is destructive and easy to forget | `crates/app-protocol/src/lib.rs` (`EditorExport.max_edge`), `crates/app-core/src/editor.rs` (`export_dimensions`, the long-edge rule; `export_pixels` takes the limit; `jpeg_metadata_segments` keeps each marker so a resized copy drops APP1 but keeps APP2/APP13), `core.rs` (`editor_export` passes it, `0`/absent = the document's size), `EditorView.qml` (`exportLongEdge`, `exportEdges`, `chooseExportSize`, an `Output size` row, an EXIF note), `cpp/main.cpp` (`_ARG4` + tool logging), `tests/qml/tst_editor.cpp`, Core tests, ADR 0004 | `just test` 280 strings / 110 C++ / 276 drawn; cargo 72 + 4; editor 37; real window: the Vietnamese `Kích thước xuất` combo reading `800 px cạnh dài`, and `phone.jpg` written at 600 × 800 from a 1200 × 1600 document that stayed 1200 × 1600 (`docs/evidence/M1-export-size-vi.png`, `-written.png`), journal rev 5, tool still `pointer`; 4 mutations, each caught |
| 82 | Crop had no frame on the canvas to place its rectangle, and a photo shot at an angle could not be straightened at all | `crates/app-protocol/src/lib.rs` (`EditorTransform`/`EditorTransformPreview`), `crates/app-core/src/editor.rs` (the `Transform` operation, `validate_transform`, `square_to_quad`/`invert3`/`warp_quad`, snapshot undo), `core.rs` (`PreviewKind::Transform`, `editor_transform_preview`), `crates/desktop/qml/EditorView.qml` (a fourth tool, the crop frame with eight handles, the transform quad with four corners plus four edge handles, the pan dropping the left button while either is armed, `cropFrameShown`/`transformFrameShown`), `UiLines.qml` + `kogaview_vi.ts` (four lines and the history sentence), `cpp/main.cpp` (`editor-transform`), `tests/qml/tst_editor.cpp` (4 cases + the pan assertions), 6 Core tests | `just test` 293 strings / 110 C++ / 289 drawn; cargo 78 + 4; editor 41; real window: quad grabbed (`docs/evidence/M1-editor-transform-quad-vi.png`), live draft + the `Tắt Xem trước trực tiếp…` hint (`-live-vi.png`, journal `editor_transform_preview` rev 4), applied at `1200 × 1600` with Apply disabled again (`-applied-vi.png`, `editor_transform` rev 4), crop frame 512 × 384 at `bottom_right` (`M1-editor-crop-frame-vi.png`); 8 mutations, each caught |
| 83 | Discard did not discard: after an unsaved edit, a Discard answer and another picture in the Viewer, the Editor reopened the old image. Resize was also an Inspector column even though a size is a question, not a mode | `crates/app-core/src/core.rs` (`SetWorkspace` keeps `previous` and passes `previous == Workspace::Viewer` to `link_viewer_into_editor`, which follows the Viewer's picture from the Viewer, keeps an open document from elsewhere and refuses an unsaved one; the test walks discard → viewer open → editor), `crates/desktop/qml/Main.qml` (`leaveAfterDiscard` sends `editor_reset` + the leave through `sendSequence`; quit exempt), `crates/desktop/qml/ResizeDialog.qml` (new modal form: its own fields/ratio/presets/pad/live preview, a draft preview inside the form with the stale-draft guard, theme-coloured switch labels), `crates/desktop/qml/EditorView.qml` (palette `Resize…` opens the dialog and keeps `tool` on `pointer`, the canvas no longer draws a resize draft, the crop fields renamed `cropWidth`/`cropHeight`), `crates/app-core/src/editor.rs` (`invert3` removed), `crates/desktop/build.rs`, `i18n/kogaview_ts.pro`, `i18n/kogaview_vi.ts` (25 new strings), `tests/qml/tst_editor.cpp`, `tests/qml/tst_settings.cpp` (the discard source guard), `cpp/main.cpp` (`_ARG5=apply`), ADR 0012, ADR 0013 | `just test` 299 strings / 110 C++ / 295 drawn; cargo 78 + 4; settings 15, editor 41; real window: the dialog with a live 1024 × 1024 draft and legible switches (`docs/evidence/M1-editor-resize-dialog-vi.png`), applied (journal `editor_resize` rev 7, `M1-editor-resize-applied-vi.png`), and the Discard sequence ending on `two.png` (`M1-discard-follows-viewer-vi.png`, journal `editor_reset` rev 9 → `set_workspace` rev 10 → `viewer_open` rev 12 → `set_workspace` rev 13); 5 mutations, each caught |
| 84 | The Resize dialog carried a framed preview of its result; its asynchronous picture inside the modal read as the form loading, then "bursting out" on first open | `crates/desktop/qml/ResizeDialog.qml` (preview frame, caption, `Live preview` switch and its state, `documentPreview`/`draft`/`ignoredDraft`/`shownDraft`/`previewSource`/`previewCaption`, `requestDraft`, `draftRequested` and the debounce timer removed; the column is measured at `dialog.width - 40` so the first layout does not use the popup's pre-open width), `crates/desktop/qml/EditorView.qml` (`resizeDraft`/`previewSource` and the draft wiring removed), `tests/qml/tst_editor.cpp` (`theResizeDialogHasNoPreviewSurfaces`; the live-preview case removed; crop no longer drives the resize form), `cpp/main.cpp` (`editor-resize` no longer clicks a live toggle), the harness reference, `i18n/kogaview_vi.ts` (6 vanished preview strings removed), ADR 0012 (revision) | `just test` 294 strings / 110 C++ / 290 drawn; cargo 78 + 4; editor 41; real window: the form at 1472 × 943 with no preview, pad armed (`docs/evidence/M1-editor-resize-dialog-no-preview-vi.png`) and a grab 150 ms after the open request already at its final size; 1 mutation, caught |
| 85 | The Editor had no brush and no eraser: every edit was chosen with numbers, and no pixel could be placed by hand. A stroke is also continuous in time, unlike a rotate or a crop | `crates/app-protocol/src/lib.rs` (`EditorPaintStroke { points, color, radius, opacity, erase }`, `name()`, a round-trip case, and `#[serde(default)]` on `erase` so an older payload is a brush), `crates/app-core/src/editor.rs` (`EditOperation::Paint`, `MAX_BRUSH_RADIUS`, the `brush_stroke`/`eraser_stroke` labels, snapshot undo, `validate_paint` with four codes, `paint_stroke`: a bbox coverage mask of round-capped capsules, **maximum** coverage so a crossing stroke does not darken, one-pixel feather, source-over for the brush and alpha-only for the eraser), `core.rs` (dispatch + preview test), `crates/desktop/qml/EditorView.qml` (Brush/Eraser palette buttons as one `paint` tool, the paint inspector with swatch/hex/swap/eight colours/size/opacity, the in-flight `Canvas` overlay, the pan yielding the left button except while Space is held, and the Krita keys `B E [ ] X D Space + - Tab` plus `Ctrl+Z`/`Ctrl+Shift+Z`/`Ctrl+Y`), `UiLines.qml` + `kogaview_vi.ts` (17 strings), `cpp/main.cpp` (`editor-paint`), `tests/qml/tst_editor.cpp` (5 cases + the matte press; `init()`/`openResizeDialog()` now wait for a closing modal to be invisible), ADR 0014 | `just test` 311 strings / 110 C++ / 307 drawn; cargo 82 + 4; editor 46; real window: a blue 40 px stroke on the exact line (`docs/evidence/M1-editor-paint-vi.png`), a brush then an eraser at rev 5 → 7 with alpha 0 under the eraser in `preview-3.png` and History `1. Brush stroke` / `2. Eraser stroke` (`M1-editor-paint-history.png`; the Vietnamese eraser grab is `M1-editor-eraser-vi.png`), an undo that restored the picture; 8 mutations, each caught after one test was strengthened |
| 87 | The copy entries were menu-only and no entry said which key reached them; `Ctrl+C` was not available (a focused Editor field owns it) and a `MenuItem` draws no shortcut column | two `Shortcut`s in `Main.qml` (`Ctrl+Shift+C` → `copyImageContent`, `Ctrl+Alt+C` → `copySelectedPaths`, both gated on `modalDialogOpen`), `MenuShortcut.qml` (right-aligned label, `objectName: "shortcutHint"`, colour from the entry's content item), `Theme.qml`'s `menuShortcutLabels`/`menuWidth(widths, shortcutWidths)`, hints in `Viewer.qml`/`BrowserView.qml`, `tst_viewer`/`tst_browser::theCopyEntriesNameTheirKeys`, `tst_settings::theShellBindsTheCopyKeysItsMenusName`, `KOGAVIEW_DEV_KEY`, ADR 0016 | `just test` 316 strings / 313 drawn; viewer 40, browser 48, settings 17; **real window**: clipboard image `1200x800` and the toast, then clipboard text = the path; a Browser selection of `two.png` gave `640x480`, an empty selection toasted `Select one image to copy its content.` while the path key copied the folder; two menus photographed after a colour fix (white-on-light first); 3 mutations, each caught |
| 88 | The header had only two states and its floor *was* the icon-only row (~798 px), so a window could not be narrower than the widest workspace toolbar | `ToolbarMetrics.qml` (`*MiniButtons`, `miniToolbarWidth`, `minimumWindowWidth = max(miniToolbarWidth, 260 + 320)`), `Main.qml` (`toolbarMini`), the three views (`visible: !view.miniToolbar` plus one `⋮` overflow menu each, Editor zoom hidden), `Theme.menuEntries` 31–38 appended, the mini fixture and `theFloorIsTheMiniToolbar`, three view cases, ADR 0015 and a revision note in ADR 0010 | toolbar 12, viewer 40, browser 48, editor 49; **real window** at 700 × 620 and at the 580 px floor: Browser 4 buttons, Viewer 5 + counter, Editor 7 with no zoom, each ending in `⋮`; overflow menus open with their folded actions; 2 mutations, each caught |
| 89 | The three tiers were chosen from the widest workspace, so the Browser folded at ~782 px although it needs 438 and showed labels only at the Editor's ~1000 px; the switcher's three buttons were counted only in that global maximum | per-workspace `*CompactRowWidth`/`*MiniRowWidth`/`*LabelledRowWidth` and `modeFor(workspace,width)` in `ToolbarMetrics.qml`, `Main.qml`'s single `toolbarMode` binding, the per-workspace fixture and six row measurements, `theTierFollowsTheOpenWorkspace`, ADR 0017 + ADR 0015 revision | toolbar 17; real window at 600/700 px: Browser all six icons / labels while Viewer and Editor fold (`M1-toolbar-tier-*.png`); 3 mutations, each caught |

## Test gate

`PATH=/usr/lib/qt6/bin:$PATH just test` — exit 0 (`lrelease` is the system Qt 6
one now; `/tmp/opencode/lrel` no longer exists):

```
translations: 316 strings in kogaview_vi.ts, 110 of them compiled into C++, 313 drawn by the QML, 4 looked up by context
packaging: 19 MIME types, 3 categories, icon and metainfo named io.github.tienv2i.KogaView
cargo: 82 passed (kogaview-core) + 4 passed (kogaview-protocol)
viewer 40 · browser 48 · cache 15 · state 7 · settings 17 · editor 49 · language 7 · toolbar 17
```

`cargo fmt --check` clean. `cargo clippy -p kogaview-protocol -p kogaview-core --all-targets`
still reports the two pre-existing `derivable_impls` warnings in
`crates/app-protocol/src/lib.rs` (`impl Default for Workspace`/`Theme`, lines 53 and 135) and
the pre-existing core warnings (`too_many_arguments`, `while_let_loop`, `sort_by_key`,
`field_reassign_with_default`, `needless_return`); rows 80, 81, 83, 84, 85, 86, 87, 88 and 89
add no new warning (the protocol's `Anchor` and the anchored Core helpers are still gone).

## Design decisions, keyboard session

- **Ownership**: plain keys live in `Keys.onPressed` on the view that shows the
  content (`BrowserView.qml`, `Viewer.qml`). A window-wide `Shortcut` with a bare
  key would also fire while a text field, menu or dialog has focus, so only the
  Ctrl/Alt combinations stay in `Main.qml`; the views return early on
  Ctrl/Alt except for the Browser's Ctrl+A.
- **Focus**: both view roots are `focus: true` and call `forceActiveFocus()` on
  completion. Buttons that can hold the keyboard
  elsewhere — the breadcrumb ellipsis, the tree chevron and the footer Cancel —
  are `focusPolicy: Qt.NoFocus`, so the arrows move the grid/picture instead of
  being eaten by a control.
- **Same commands as the pointer**: selection, opening, folder navigation,
  trashing, filmstrip and workspace switching emit `select`, `open_file`,
  `navigate`, `trash`, `toggle_filmstrip`, `set_workspace` and the
  `viewer_*` commands. Zoom, pan, rotate and flip are Qt presentation only, like
  their toolbar buttons.
- **The Browser cursor is presentation-only**: Core owns `selection`;
  `keyboardCursor` only remembers the cell the next arrow starts from when the
  selection is empty or left the folder. The first arrow out of an empty
  selection lands on the first cell rather than skipping it.
- **Delete is one command per press**: a key event with `isAutoRepeat` set is
  ignored, so holding the key cannot empty the folder.
- **Home/End in the Viewer** use `viewer_open` on the folder's ends instead of
  stepping through every image; previous/next stay Core's `viewer_next`/
  `viewer_previous`, including their wrap-around.
- **Tooltips name only real keys**: the hint is appended to the sentence the
  control already had (`Rotate left (Shift+R)`, `Go to parent folder
  (Backspace)`, `Browser workspace: … (Ctrl+1)`). A button whose action has no
  shortcut keeps plain text; the Editor test pins `Undo` to `Undo` so a tooltip
  cannot claim a key that does nothing. The strings live in the QML layer that
  owns the key, and every one is in the `.ts` and the C++ table.

## Design decisions, shell-menu session

- **Indices are pinned by a test.** The Browser, Viewer and Editor menus already
  address `Theme.menuEntries[n]` by number. The new `Open in editor…` label is
  appended at slot 30 rather than inserted, so none of those numbers move; a new
  `shellMenuStartsWithTheOpenEntries` case resolves the shell menu's first three
  slots back to labels, which is what the old membership-only check missed.
- **One chooser, two destinations.** `chooseEditorImage()` serves both the
  Editor's toolbar button and the shell menu. `handleOpenedPaths` switches to the
  Editor before `editor_open` only when the menu is used from another workspace;
  from inside the Editor it sends the open command alone. The command pair goes
  through `sendSequence`, the same ordering fix the Browser's Edit entry uses.

## Design decisions, modal-pointer session

- **Pointer handlers are not occluded by a popup.** Qt's modal overlay blocks
  *item* events, but pointer-handler delivery still reaches handlers attached to
  items under the overlay, and two `DragHandler`s cannot take over from one
  another by default. That is why the Viewer's pan handler won the Settings
  header drag in the Viewer only: the pointer was inside the viewport rectangle,
  and that handler is always armed (the Editor arms its pan only while the
  pointer is over its canvas, which the header is not).
- **The shell owns the gate.** `Main.qml` exposes `readonly property bool
  modalDialogOpen` over Settings, the unsaved-changes dialog, the delete
  confirmation and the three fallback choosers, and the workspace `Loader` is
  `enabled: !root.modalDialogOpen`. One gate covers drags, the wheel, taps and
  clicks instead of a per-handler flag. Menus are modeless and stay out.
- **Focus returns.** Disabling the loader does not cost the workspace its
  keyboard: after Escape the active focus is the Viewer again and `R` still
  rotates (`aModalDialogOwnsThePointer` asserts both).
- **The shell half is a source guard.** `Main.qml` needs the real
  `KogaViewBridge`, so `tst_settings` checks that the loader is gated and that
  every modal dialog feeds the property — the same substitute used for the
  shell-menu labels (row 50).

## Design decisions, editor-layout session

- **The toolbar is global, the palette is local.** Open, zoom, Save / Save as…,
  Undo, Redo, Reset, back and close stay in the header; the header's duplicate
  rotate/flip icons were removed. `ToolbarMetrics` counts 12 buttons and 5
  separators, and `tst_toolbar` counts the real source, so a new header button
  cannot outgrow the window floor.
- **The left column holds tools, the right their options.** Pointer, Resize and
  Crop are selectors, not commands: they set `view.tool`, which swaps the
  inspector's column. Apply sends the same typed `editor_resize` /
  `editor_crop`; Reset only clears the fields. Save is not in the inspector.
- **Pointer is the no-op default.** The Editor opens on Pointer; its column
  shows the document title, size, save target, the browser's cached thumbnail
  and the session history. Clicking the selected Resize/Crop returns to
  Pointer, so a tool can always be put down. Selecting a tool sends no command.
- **The history list is back, under the pointer.** Core publishes `history` and
  owns undo/redo; the view draws it only where a tool is not armed, so the
  tool column stays about the tool.
- **The thumbnail is a cached decode of the current preview.** The first
  version decoded `editor.previewPath` directly; under software rendering it
  stayed black past five seconds. `CachedThumbnail` + `ThumbnailBook` (the
  grid's own cache, passed from `Main`) draws it promptly, and each edit writes
  a new preview path so the thumbnail follows the edit.
- **Labels, not a 2 × 2 grid.** At 220 px "Flip horizontal" was elided to
  "Flip horizo…", so the four rotate/flip actions are one full-width column.
  The Vietnamese labels are shorter, but the same column keeps both languages
  whole.
- **The layout is source-and-item tested.** `tst_editor` loads the real QML, so
  the palette/inspector geometry, the pointer default, the tool toggle, the
  hidden fields and Reset are asserted through the real items; `tst_toolbar`
  still guards the counts.

## Design decisions, resize rework session

- **Resize has no anchor; Crop keeps its rectangle.** The `Anchor` enum is gone
  from protocol, Core and QML, and `editor_resize` is `{width, height, fill}`.
  The older payload's `anchor` field is ignored (the round-trip test asserts
  that), so a stale client cannot move the crop. Core always takes the centred
  cover rectangle, and the square pad adds its fill evenly on the two short
  sides — where the result sits is a Crop decision, not a Resize one.
- **Width and Height are one shape.** A ratio combo (`Free`, `Original` plus
  nine common ratios) decides what typing one side does to the other; `free` is
  the only unlinked choice and `original` follows the document. Programmatic
  writes (a preset, Reset) do not come through `textEdited`, so the link cannot
  feed back on itself. A preset also selects its ratio, so the two controls
  never describe different shapes.
- **The presets are concrete sizes, not ratios.** 47 entries, every side a
  multiple of 64, grouped by ratio in one flat list labelled `1:1 · 1024 × 1024`
  style — including 1024/768/512 squares for 1:1. `Custom` is the initial
  state (`currentIndex: -1`): nothing is armed until the user acts.
- **Live preview is a Core draft, not an edit.** `editor_resize_preview` renders
  the operation on a worker to `draft-{generation}.png` and publishes
  `editor.previewDraft {path,width,height}`; the document, its history and its
  save target do not move (the status bar still reads the old size and the
  journal line says `Previewing a resize to …`). The canvas draws the draft only
  while Resize is selected *and* the toggle is on, so leaving the tool hides it
  without another command. Applying the real `editor_resize`, any other edit,
  undo/redo/reset, a new open and close all drop the draft file.
- **The preview thumbnail is keyed on the file, not its name.** Preview files
  are named `preview-{generation}.png` and the generation restarts at 1 each
  process, so the persistent `ThumbnailCache` answered a fresh preview with the
  previous run's thumbnail when it was handed `(path, edge, 0, 0)`. Core now
  publishes the preview file's real mtime and size (`previewModified`,
  `previewSize`) and the pointer's `CachedThumbnail` passes them, which is what
  the cache actually keys on.

## Design decisions, crop session

- **The anchor is Crop's, and it places rather than locks.** Nine document
  points (four corners, four edges, centre) decide where a rectangle of the
  current Width/Height sits; the pad's glyph points at the kept corner or edge
  and its `column`/`row` are the same numbers `applyCropAnchor` uses, so an
  arrow cannot say one thing while the rectangle does another. Typing X/Y is
  the user's own placement and is never overwritten; changing a size through
  the ratio link, a preset or Reset re-places the rectangle. This is the idea
  row 73 took out of Resize and returned to Crop.
- **The two tools share one ratio table, not one choice.** `sizeRatios` and
  `sizePresets` are read-only data both tools use; `resizeRatio` and
  `cropRatio` are separate properties, so a 1:1 crop does not turn the next
  resize into a square. Picking a ratio re-links the fields immediately
  (`relinkFields`), so a 16:9 label with a 1024 × 1024 pair typed earlier is
  corrected at the moment the ratio changes.
- **Crop presets are filtered, Resize presets are not.** A crop preset the
  document cannot hold would arm Apply with a rectangle Core rejects, so
  `cropPresets` offers only sizes whose both sides fit the document; a small
  picture simply has a shorter list and keeps the fields. The shared list stays
  one flat, 64-divisible set, so a preset is still a concrete size in pixels.
- **A ratio can come from the fields themselves.** `Keep current ratio` is a
  third source next to `Original` and the fixed shapes: picking it snapshots the
  Width/Height pair on screen (or the document's aspect when the fields are
  empty) into `resizeCurrentRatio`/`cropCurrentRatio`, and later edits keep that
  shape. The snapshots are per tool, so locking a 3:2 crop does not change the
  next resize. It is the "keep what I typed" lock, without a second control:
  the Ratio combo already is the lock.
- **Steppers are the same edit path as typing.** The +/- pair beside Width and
  Height sets the text and calls `linkHeightFromWidth`/`linkWidthFromHeight`,
  then the same 200 ms draft debounce. An empty or invalid field starts from the
  document size its placeholder shows, not from 1, the linked side is clamped to
  the fields' 1–20000 range, and `Free` leaves the other side alone. Each button
  auto-repeats while held, so a long nudge does not need hundreds of clicks.
  Nothing is sent to Core until Apply or Live preview asks.
- **Pad to fit is not pad to square.** The old checkbox squared the canvas before
  covering it, so a 1003 × 698 target became a 2048-square first. `fit_with_padding`
  instead computes the largest box of the *source's* shape that fits inside the
  target, resizes the source once into it, and centres it on a target-sized fill
  canvas. The leftover is a letterbox, a pillarbox, or nothing — only the target
  being square makes the frame square. Without the checkbox, Resize keeps the
  existing centred cover-and-crop so nothing is ever stretched.
- **A preset is applied on activation, never on an index change.** Both Size
  dropdowns use `onActivated`, and the concrete size + ratio work lives in
  `chooseResizePreset`/`chooseCropPreset`. Crop's list is filtered by the
  document, so it is rebuilt when a document arrives; with
  `onCurrentIndexChanged` its first fitting row (1:1 · 2048 × 2048) applied
  itself then and wrote the shared Width/Height fields, which is why a fresh
  Resize panel showed 2048 × 2048 while the Size control still read `Custom`.
  Writing `currentIndex` from `matchingPreset()` now only mirrors a typed pair
  in the dropdown and cannot re-apply it.
- **The lists are short on purpose.** Twelve ratios and 47 samples buried
  `Custom` and the useful targets. Six common ratios and three sizes each (18
  entries) keep the dropdown scannable; the rare shapes (21:9, 5:4, 16:10, 2:3)
  are still reachable by typing the numbers and choosing `Free`. Every preset
  side stays a multiple of 64.
- **Validity is the rectangle, not just two numbers.** `cropFieldsValid()`
  answers the same question Core will ask (`x + width ≤ document width`,
  `y + height ≤ document height`); Apply and the draft both use it, so a legal
  rectangle is visible in both places and an illegal one reaches neither.
- **Live crop is the Resize draft with a kind.** `editor_crop_preview` goes
  through the same `editor_preview` path as `editor_resize_preview`: it
  validates with `would_change`, renders on a worker to `draft-{generation}.png`
  and publishes `editor.previewDraft {kind, path, width, height}` without
  touching the document, its history or its save target. The canvas draws a
  draft only when the selected tool and the draft's `kind` agree and that
  tool's toggle is on, so switching Resize ↔ Crop cannot paint the other
  tool's result for a frame, and leaving to Pointer hides it with no command.
  Every applied edit, undo/redo/reset, a new open and close still drop the
  draft file.

## Design decisions, canvas-drag session (row 82, ADR 0011)

- **The canvas is a second input, not a second source of truth.** A crop drag
  writes `cropX`/`cropY`/`widthField`/`heightField` — the same four fields the
  inspector owns — through `setCropRect`, so there is exactly one rectangle and
  Apply, the preset dropdowns and the draft all read it. A transform drag writes
  `transformCorners`, which is exactly what the protocol carries.
- **A handle owns two sides and pins the opposite ones.** `dragCropHandle(column,
  row, hostX, hostY)` moves only the left/right and top/bottom sides the handle
  is on, clamps them to the document and keeps at least one pixel, so a rectangle
  cannot invert. A press inside the frame moves it and keeps its size; a drag on
  the empty canvas seeds a new one. The frame is declared after the create area,
  so the frame wins a press that starts on it.
- **The four edges are an affordance over four corners.** `moveTransformEdge`
  computes the pointer's delta from the edge's midpoint and applies it to both of
  its corners — clamped so neither leaves the frame — then publishes the same
  four-point array. The wire format, the validator and the draft never learn
  about edges.
- **Clockwise, one winding, and not a mirror.** `validate_transform` refuses a
  reversed quad as `transform_degenerate` because it is a mirror of the frame and
  Flip owns mirroring, with its own history line. Outside corners answer
  `transform_outside` with the corner and the frame in the line. The QML repeats
  those two guards only so a quad Core would refuse is never drawn or armed.
- **The homography goes from the destination square to the source quad.**
  `square_to_quad` is the forward map (its inverse was the first bug: the result
  came out pinched). `warp_quad` walks the document, finds the source point of
  each pixel's unit-square coordinate, shifts by half a pixel to pixel centres and
  samples bilinearly with the edges clamped, which is what lets
  `the_identity_quad_reproduces_every_pixel` demand the original bytes back.
- **A warp is undone by a snapshot.** The pixels outside the quad are not in the
  result, so it cannot be inverted the way a rotate or a flip can; `trim_history`
  already budgets snapshots.
- **The overlay hides while its own draft is on the canvas.** Both `cropFrameShown`
  and `transformFrameShown` require `previewDraft === null`, and `previewDraft`
  already filters by tool and by the draft's `kind`. A draft is the result; a
  frame drawn over it would describe source pixels that are no longer there, and
  dragging it would write the result's coordinates into the source's fields. The
  crop create area and overlay are disabled with the frame, and the inspector
  says `Tắt Xem trước trực tiếp…` / `Turn Live preview off…` so the way back is
  on screen.
- **The left button belongs to the armed overlay.** With Crop or Transform
  selected, `editorPan` accepts only `MiddleButton`. Pointer handlers are
  offered the sequence even when the overlay's `MouseArea` takes the item event,
  so without this a corner drag also panned the picture — the QML suite fails
  three cases, including "the corner did not follow the pointer", which is the
  defect itself.
- **Transform keeps the document's size.** The quad is remapped onto the frame,
  never cropped to the quad's aspect: the inspector says so, and Resize/Export
  remain the ways to choose another size. Outside the quad the sampler clamps to
  the border pixel, so the leftover smears rather than turning transparent.

## Design decisions, resize-dialog session (rows 83, ADR 0012 and 0013)

- **A size is a question, not a mode.** `ResizeDialog.qml` owns the form, its
  fields, its ratio and preset lists, its pad and its Live preview toggle, and
  resets them from the document every time it opens. The palette's `Resize…`
  opens it and keeps `view.tool` on `pointer`; the button stays highlighted
  while the dialog is up, so the palette still says where the question came
  from. Crop and Transform stay inspector tools because their answers are drawn
  on the picture.
- **The dialog shows the draft; the canvas does not.** A resize draft is painted
  inside the form's own preview and only while its toggle is on; the canvas never
  draws one, so closing or cancelling needs no repaint. `ignoredDraft` keeps a
  draft published before this visit from appearing as this visit's answer, and
  the `kind` check keeps a stray crop draft out.
- **One document, two tool columns.** Removing Resize from the Inspector meant
  the shared Width/Height fields had no second user, so they and the steppers
  became `cropWidthField`/`cropHeightField` and `stepCropField` with
  `cropWidthStepUp`-style names. The dialog has its own pair; nothing is shared
  between a closed form and an armed tool.
- **The dialog sizes itself.** `height` is the header (52) plus the footer (60)
  plus the content column plus its 40 px margins, capped at the window; a fixed
  height left a blank page under the footer in English and clipped a wrapped
  Vietnamese sentence. `ScrollBar.AsNeeded` is how a short window says the form
  continues below.
- **The switches are drawn in the theme's colour.** A Popup created inside the
  workspace Loader resolves the platform's light palette, and this Qt build
  ignores a QML `palette` write on a `CheckBox`, so both labels were
  dark-on-dark. They now use a `Text` content item with `theme.text` (and
  `textMuted` when disabled) and keep the style's indicator. The form's fields
  and buttons still use the platform's own light boxes, as they did before.
- **Discard is two commands in order.** The shell sends `editor_reset` and then
  the leave through `sendSequence`; Core refuses to replace an unsaved document,
  so a reset that arrived later would be too late for the workspace switch it
  belongs to. Quit skips the reset. A switch *from the Viewer* follows the
  Viewer even when a saved document is open; a switch from anywhere else keeps
  the open document, which is ADR 0013's whole rule.
- **The size form has no picture (row 84).** The framed preview and its
  `Live preview` switch were removed: the asynchronous image made the dialog
  read as loading before it settled, and the picture behind the modal already
  shows the document. The form is fields, ratio, preset, pad and footer; the
  content column takes its width from `dialog.width - 40` so the first layout
  does not use the popup's pre-open width, and a QML case asserts the height
  does not move after the first layout. `editor_resize_preview` still exists in
  protocol/Core; no front end emits it now.

## Design decisions, paint session (row 85, ADR 0014)

- **A stroke is one command, sent on release.** `editor_paint_stroke` carries
  document-space points, an RGB colour, a radius, an opacity and `erase`.
  Points are collected while the button is down and nothing reaches Core until
  it comes up, so an abandoned stroke (Escape, focus loss, Space for pan)
  changes no pixels. A press with no drag is one point and still paints a dot.
- **QML previews, Core paints.** `paintStroke` plus a `Canvas` overlay is the
  in-flight mark; it is presentation state like zoom, and the pixels that
  persist are Core's new preview. The overlay is cleared on release, so for the
  moment the worker renders, the canvas shows the previous frame — the
  alternative (holding the overlay until `previewRevision` advances) was not
  built.
- **The mask takes the maximum, not a sum.** Each segment is a round-capped
  capsule with a one-pixel feather; overlapping segments contribute their
  largest coverage to a pixel. Summing would darken a semi-transparent stroke at
  every join and at every self-crossing, the classic dab artefact. The eraser
  uses the same mask and only lowers destination alpha; it never repaints a
  colour.
- **The brush and the eraser are one tool with two modes.** `tool === "paint"`
  and `paintMode` is `brush` or `eraser`, the way Krita's freehand brush and
  eraser share one engine. The palette shows both as separate buttons; the
  inspector column owns colour, size and opacity for whichever is armed.
- **Krita's keys live on the Editor view.** Plain keys (`B`, `E`, `[`, `]`,
  `X`, `D`, `Space`, `+`, `-`, `Tab`) are handled by `Keys` on the view root, so
  a focused text field consumes them first: typing `b` in the colour field must
  not arm the brush. `Ctrl+Z`/`Ctrl+Shift+Z`/`Ctrl+Y` are handled there too, so
  they undo the document rather than a field. Palette buttons are
  `focusPolicy: Qt.NoFocus`; the colour field hands focus back on
  `onEditingFinished`, and a focus loss cancels a half stroke and releases a
  held Space.
- **Space is temporary pan and yields the left button back.** While Space is
  held, the paint overlay is disabled and the pan handler accepts the left
  button again. The pan already accepted only the middle button under Crop and
  Transform; Paint joins that rule, so a brush drag is never stolen by the pan.
- **Tab hides the Editor's panels, not the shell.** The two side panels and
  their splitters go and the picture gets their width; the header toolbar
  belongs to the window, not to the Editor, so it stays.
- **A press on the matte is not a dab.** The canvas host extends beyond the
  picture; a press outside the document is ignored, because it would send a
  stroke Core clips away and still cost an undo step and a preview render.

## Design decisions, dialog-open fix (row 86)

- **`opened` is "finished opening", not "visible".** Qt Quick Controls emits
  `opened` after the style's enter transition. Breeze fades opacity from 0 to 1
  for roughly 300 ms, and the popup is already visible at the positioner's
  default `(18, 0)` for that whole time. Centring in `onOpened` therefore made
  the form fade in at the left and jump to the middle when the fade ended.
- **`onAboutToShow` is the hook with a parent and a size.** Qt sets `visible`,
  reparents the popup item and emits `aboutToShow`; only then does it give the
  positioner its parent item and emit `visibleChanged`. The dialog's width and
  height bindings already resolve there, so `centerInParent()` writes the
  position for the first rendered frame. The opening values (`fillFromDocument`,
  the language list and the seen snapshot) move there too, so a second visit
  does not show the previous visit's fields while fading in.
- **The user's 300 ms of fade are kept.** The fix does not disable Breeze's
  enter transition; a fade at the correct position is just an opening, not a
  jump. `moved` still guards a hand-placed dialog from being recentred by a
  later width/height change.
- **The regression test installs the transition it needs.** The QML suites run
  under the Basic style, where opening can finish in the same event loop, so
  `theResizeDialogIsCentredWhileItOpens` and `theDialogIsCentredWhileItOpens`
  assign a 600 ms opacity `enter` transition through the dialog's own property
  and force a corner start. They then assert the first visible frame is already
  centred while `opened` is still false; reverting either handler to `onOpened`
  fails its case.

## Design decisions, copy-key session (row 87, ADR 0016)

- **`Ctrl+C` stays the field's.** The Editor has a hex colour field, size
  fields, an export path and a folder name; a window-level `Ctrl+C` would eat
  every one. The two copy actions therefore take `Ctrl+Shift+C` (pixels) and
  `Ctrl+Alt+C` (the path), declared once in `Main.qml` and gated on
  `modalDialogOpen` like every other shell shortcut.
- **The key hint is a widget, not text.** `MenuItem` has an `Action.shortcut`
  that Qt Quick Controls never draws, and `\t` appended to `text` renders as
  nothing. `MenuShortcut.qml` is a right-aligned `Label`
  (`objectName: "shortcutHint"`, `z: 2`) laid over the entry's content item;
  the view suites find it by that object name, so a menu that stops naming its
  key fails a test.
- **The menu reserves the key column in its width.** `Theme.menuShortcutLabels`
  lists the keys a menu can draw, `Main.qml` measures them with
  `Platform.textWidths`, and `menuWidth(widths, shortcutWidths)` adds the widest
  key plus a 24 px gap. Without that the widest row (`Ctrl+Shift+C`) would be
  clipped, and the menu's width would jump between right clicks.
- **The hint colour comes from the entry, not the palette.** A `Menu` popup is
  painted by the platform style (light, black text) while `palette.*` inside it
  resolves this app's forced-dark window palette; `palette.windowText` painted
  `#fcfcfc` hints on `#efefef` (the first grab). The label reads
  `parent.contentItem.color` and dims it to 70 %, so it follows either theme
  instead of hard-coding a grey.
- **"Copy to…" has no key.** It opens a destination chooser, so a key would have
  to open a dialog rather than do the thing the entry says.
- **Both halves are pinned separately.** The view suites check the text drawn in
  the menu; `Main.qml` needs the bridge, so `tst_settings` reads its source and
  asserts the two sequences, their handlers and the modal gate. Renaming a key
  in either half alone fails one of them.

## Design decisions, mini-toolbar session (row 88, ADR 0015)

- **The floor was the icon row; now it is the folded row plus a picture.**
  `compactToolbarWidth` (~782 px) is the point where each workspace folds, not
  the minimum window width. `minimumWindowWidth` is
  `max(miniToolbarWidth, sidePanelWidth + pictureWidth)`, measured at 580 px,
  which is what the compositor is given as `minimumWidth` and what the
  `onWidthChanged` guard re-applies on this Wayland session.
- **Each view folds by itself.** `Main.qml` publishes `toolbarMini` and the
  views put `visible: !view.miniToolbar` on the buttons that fold, plus one
  overflow button (`⋮`) whose `Menu` carries the same actions.
  No separate toolbar component and no second command path: a folded entry
  sends exactly the command its button did and reads its words from
  `Theme.menuEntries`.
- **The overflow button is not budgeted twice.** `browserButtons`/`viewerButtons`/
  `editorButtons` remain the compact rows and exclude it;
  `browserMiniButtons`/`viewerMiniButtons`/`editorMiniButtons` include it.
  `tst_toolbar` subtracts it by object name from the live source, so a count
  that drifts fails the suite instead of narrowing the window by one square.
- **What stays visible is the frequent action, not the dangerous one.**
  Browser keeps up/refresh/open-folder; Viewer keeps back/prev/next/fit and its
  `n / m` counter; Editor keeps open/save/undo/redo/back/close and loses the
  zoom readout (its buttons are in the menu). Trash, rotate, flip, export,
  panels and settings fold.
- **The floor's trade is recorded, not hidden.** At 580 px with both Browser
  panels open the grid is ~55 px wide and the Editor canvas ~100 px
  (`M1-toolbar-mini-floor.png`). The panels are draggable, Tab hides the
  Editor's, and their toggles are in the overflow menu; a floor of
  `260 + 260 + 320` would have been wider than the row this change replaced.

## Design decisions, per-workspace toolbar tier (row 89, ADR 0017)

- **The row that is drawn is the row that is measured.** `ToolbarMetrics` now
  has `*CompactRowWidth`, `*MiniRowWidth` and `*LabelledRowWidth` for each
  workspace, all through one `rowWidth(switcher, toolbar)` that includes the
  switcher's three buttons. The widest aggregates (`compactToolbarWidth`,
  `miniToolbarWidth`, `labelledToolbarWidth`) are maxima of those rows, so the
  580 px floor and the tests keep one arithmetic.
- **One function decides, one binding publishes.** `modeFor(workspace, width)`
  returns `"full"`, `"compact"` or `"mini"`; `Main.qml` binds `toolbarMode` to
  it with `root.state.workspace` and `root.width`, and `toolbarLabels` /
  `toolbarMini` are comparisons against that string. There is no
  `toolbarCompactThreshold` left to fall out of step, and switching workspace
  re-evaluates the binding because the workspace is an input to it.
- **The Browser never folds at a legal size.** Its icon row is 438 px and the
  floor is 580 px (two panels' worth of width), so a 580 px Browser shows every
  button; the overflow menu is still there as the rule's consequence. The
  Viewer (771) and the Editor (782) do fold between the floor and their rows.
- **Each workspace earns labels on its own row.** At the test font the label
  points are 653 / 986 / 997 px, so a 700 px window has Browser labels and
  Editor icons; the real window font measures 665 / 1011 and the screenshots at
  600 and 700 are what locate the boundary there. Switching to a heavier
  workspace can drop the labels at a fixed width — the row must still fit.
- **The fixture is measured per workspace.** `tst_ToolbarRow.qml` takes a
  `workspace` and a `mini` flag, and `theWidthsMatchTheRealHeaderRow` runs six
  rows against the real layout; `theTierFollowsTheOpenWorkspace` checks every
  boundary and the same-width/different-workspace case that was the defect.

## Design decisions, fit/settings session (ADR 0009)

- **Fit is a mode.** `fit()` sets `autoFit = true`; `setZoom` clears it. Both
  views go through `refitOrClamp()`: fitted views refit on a viewport resize, a
  window resize, a rotation and an image load; a hand-chosen zoom only re-clamps.
- **Settings buttons**: `Defaults` (left, apart) · `Cancel · Apply · OK`, OK
  highlighted. Defaults restores values without saving; Cancel reverts the
  preview and closes; Apply saves and stays; OK saves and closes.
- **One QML-owned state**: `Main.qml` `previewTheme`. It exists because a preview
  that had to be persisted first is not a preview. Cleared on every save and on
  Cancel; the stored value only ever comes from `set_settings`.
- **Why not `DialogButtonBox`**: it sorts buttons by role. Measured — with the
  four declared in the intended order, OK landed leftmost at `x=446`. The footer
  is a `RowLayout`, and a test asserts left-to-right order from real positions.

## Mutations run (each re-run, then restored)

Toolbar/window: removing `Math.min(1, …)` from `fittedZoom()` → 
`aSmallPictureFitsAtOneHundredPercent` fails (4.018, expected 1.0); `filmstripShown` back to
`!!view.filmstrip` → `aSingleImageFolderHasNoFilmstrip` fails; `rowGaps` counting one gap per
trailing child → `theCompactWidthMatchesTheRealHeaderRow` fails (865 vs 857 — it now reads the
gaps from the layout, not from the property under test); side margins dropped → the same test
fails (849 vs 857); the Viewer counter or the Editor zoom dropped from the toolbar width →
`theCountedButtonsMatchTheRealToolbars` fails ("budgets nothing for it"); `widestToolbarWidth`
reduced to the Browser → `theFloorIsTheWidestWorkspace` fails. The `onWidthChanged` floor guard
has no suite test (`Main.qml` needs the bridge), so it was mutated on the real window: with it
gone, requests for 200 and 600 stayed at 200 and 600.

Language: the four `qsTranslate` calls replaced by the English literals (the bug that was
fixed) → `theLabelThresholdFollowsTheInterfaceLanguage` fails ("the Vietnamese labels measured
no wider (260.031 vs 260.031): the metrics are still using the English literals"). The
translation gate, mutated separately and each reported by name: a wrong context
(`WorkspaceSwitcherr`) → "the .ts has no context 'WorkspaceSwitcherr'"; a wrong source
(`Main`/`Menuu`) → "context 'Main' has no source 'Menuu'"; a `qsTr` missing from the `.ts` and a
deleted hint entry → both reported as missing from `kogaview_vi.ts`.

Fit: removing both Viewer resize handlers → `aFittedImageFollowsTheWindowResize`
fails ("the picture fills 0.620667 of the smaller viewport"); removing only the
viewport handlers → `showingTheFilmstripRefitsThePicture` fails; removing the
rotation refit → `aFittedImageRefitsAfterAQuarterTurn` fails; removing the Editor
host handlers → `aFittedDocumentFollowsTheWindowResize` fails.

Settings: removing the `onClosed` revert → `escapeRevertsThePreview` and
`cancelUndoesThePreview` fail; removing the per-control previews →
`everyChangePreviewsImmediately` and `cancelUndoesThePreview` fail; making Apply
close → `applySavesAndLeavesTheDialogOpen` fails with "Apply closed the dialog".

Modal pointer: dropping `enabled: !root.modalDialogOpen` from the workspace
loader → `theShellSuspendsTheWorkspaceWhileAModalDialogIsOpen` fails ("the
workspace loader is not gated"); dropping `settingsDialog.visible` from
`modalDialogOpen` → the same test names `settingsDialog`; removing the
loader-disable from the pairing test (the control run) → `aModalDialogOwnsThePointer`
fails with the dialog still at `330`, which is the reported bug.

Resize rework: the pointer thumbnail binding dropping `modified`/`fileSize`
(→ 0,0) → `thePointerThumbnailCarriesThePreviewIdentity` fails
(`call.modified` 0, expected `1700000000123`), which is the exact cross-run key
that showed the wrong picture; `ratioFactor()` no longer returning `null` for
`free` → `typingOneSideKeepsTheChosenRatio` fails on `NaN` in Height;
`pad_to_square` placing the source at `0,0` → `square_pad_is_centred_and_uses_the_colour`
fails (`left: Rgba([10, 20, 30, 255])`, the source pixel where the fill was
expected); `install_editor_preview` publishing `Some((0,0))` as the stamp →
`editor_resize_crop_and_flip_change_the_published_size` fails
(`editor.preview_modified > 0`). Each restored, then `just test` green.

Crop: `cropPresets` keeping a size the document cannot hold → 
`theCropPresetsFitInsideTheDocument` fails on `9:16 · 1728 × 3072`; the canvas
dropping the draft's `kind` check → `theLiveCropShowsOnlyItsOwnDraft` fails
(a resize draft painted under Crop); `applyCropAnchor` using a fixed centre
column → `theCropAnchorPlacesTheRectangle` fails (`cropX` 1600, expected 0 for
`top_left`); Core's `spawn_draft` labelling a crop `"resize"` →
`a_crop_preview_is_a_draft_that_never_cuts` fails `left: "resize"`,
`right: "crop"`. Each restored, then `just test` green.

Steppers and the current-ratio lock: deleting the
`captureCurrentRatio()` call from `setRatio` → `theCurrentRatioLocksTheTypedPair`
fails (`captured.width` 0, expected 1000); removing the ratio link from
`stepField` → `theSizeSteppersNudgeBothSides` fails on the first linked height;
putting `21:9` back in `sizeRatios` → `theResizePresetsAreMultiplesOf64` fails
on `!ratioKeys.contains("21:9")`. Each restored, then the suite green.

Pad to fit and the startup race: making `fit_with_padding` stretch to the target
(use the target size as the content box) → `fit_padding_keeps_a_non_square_target`
and `resize_can_fit_the_whole_image_with_the_chosen_colour` fail; reverting the
Size dropdown to `onCurrentIndexChanged` → nothing (its model is constant);
reverting the Crop dropdown to `onCurrentIndexChanged` →
`theFreshResizeFieldsStayEmpty` fails with `2048` in Width and Height, because
its document-filtered model rebuilds when the state arrives; removing the link
calls from `stepField` → `theSizeSteppersNudgeBothSides` fails on the first
linked height. Each restored, then the suite green.

Rejection lines: the cancel refusal put back to `ProtocolError::new` (no `ui`) →
`a_rejection_carries_a_line_the_interface_can_translate` fails with
`left: Null, right: "cancel_nothing_running"`; `Main.qml` drawing
`result.error.message` again → `theToastDrawsTheLineCoreSent` fails ("the
rejection is not drawn from Core's line"); `invalid_edit` always using
`line.english()` instead of the hand-worded sentences → the crop case fails with
`crop does not fit 10 10 20 20 25 25`; `UiLines.qml` dropped from the `.pro` →
the translation gate names it; the `not_a_folder` case deleted from
`UiLines.qml` → the gate fails ("Core publishes the line … which UiLines.qml
does not draw") **and** `aRejectedCommandIsDrawnInTheInterfaceLanguage` fails;
the Vietnamese `%1 không phải là thư mục` reverted to English in the `.ts`,
rebuilt → the same QML case fails on the actual text, which is what proves the
suite reads the compiled catalogue, not the source.

Export size: dropping the never-upscale guard from `export_dimensions` → the
export test fails on the 4000 px limit (a 160 × 120 copy would be enlarged);
passing `true` for `keep_exif` → "the resized export kept EXIF that describes the
old size"; removing `max_edge` from the QML command → `exportOffersADeliverySize`
fails (`0` vs `1280`); not moving the combo box with the property →
`chosenIndex` 0 vs 4, the bug the first window grab showed. Each restored, then
the suite green.

Crop frame and transform quad: dropping the half-pixel shift from `warp_quad`'s
sampler → `the_identity_quad_reproduces_every_pixel` fails on the first row
instead of returning the original bytes; the reversed winding accepted (guard
moved to `< -1.0`) → `a_folded_or_outside_quad_is_rejected_with_a_line` fails on
the mirrored quad; the lower bounds check loosened to `-2.0` → the same test
fails on `transform_outside`; `dragCropHandle`'s right side no longer writing a
width → `theCropFrameIsDrawnAndDragged` fails (`80` where `60` was expected);
`transformChanged()` answering `true` unconditionally → `theTransformToolDragsCornersAndEdges`
fails because Apply is armed at the identity; `moveTransformEdge` leaving its
second corner alone → the same case fails ("the edge did not move its first
corner"); `editor_transform_preview` asking for `PreviewKind::Resize` → the Core
case fails with `resize preview 40 20` where `transform preview 40 20` was
expected; `editorPan` accepting the left button again under Crop/Transform →
`theCropFrameIsDrawnAndDragged`, `theTransformToolDragsCornersAndEdges` and
`theLiveTransformShowsOnlyItsOwnDraft` all fail, the corner case with "the corner
did not follow the pointer", because the pan takes the drag. Each restored, then
the suite green.

Keyboard: Left/PageUp stepping `+1` instead of `−1` → `navigationKeysAskCoreForTheNeighbour`
fails at index 3; Shift+Space made a plain "next" → the same test fails at index 5;
the Ctrl+A guard changed to `Key_B` → `ctrlASelectsEveryEntry` fails; `gridColumns()`
hard-coded to 1 → `downMovesByOneGridRow` fails (it compared the cell to the right
with the cell below); dropping `!event.isAutoRepeat` from the Delete branch →
that view's Delete test fails on the synthetic repeat event (viewer and browser
re-run separately). All restored, then `just test` green.

Resize dialog and Discard: passing `false` for `from_viewer` →
`switching_to_the_editor_carries_the_viewer_image` fails with
`left: …/one.png, right: …/two.png`, which is the reported bug; dropping
`editor_reset` from `leaveAfterDiscard` →
`theDiscardAnswerResetsTheDocumentBeforeLeaving` fails with "Discard leaves the
document modified"; making `openResizeDialog` also set `tool = "resize"` → 13
editor cases fail (the dialog's fields are only visible with the form, and a
resize tool would draw its own panel); removing the `livePreview` gate from
`shownDraft` → `theLivePreviewShowsTheDraftWithoutApplyingIt` fails with the
preview's `source` not ending in `preview-1.png` (a draft drawn while the toggle
is off); pinning one switch label to the light-theme literal `#1c1f24` →
`theResizeDialogStartsFromTheDocumentSize` fails on the colour comparison. Each
restored, then the suite green.

Preview removal: putting a 150 px `Rectangle { objectName: "resizePreview" }`
back into the form's column → `theResizeDialogHasNoPreviewSurfaces` fails with
"the resize form still has a preview frame". Restored, then the suite green.

Paint: summing the segment coverage instead of taking the maximum → the eraser
case first **passed**, because its one sampled pixel sat inside full coverage
where max and sum agree; the case was strengthened to compare a whole stroke
drawn out and back against the same line drawn once, after which the mutation
fails ("the return leg summed its dabs instead of covering them once"). The
eraser branch replaced by the brush's blend → the eraser case fails
(`left: 255, right: 128`, the alpha was not lowered). `erase` hardcoded `false`
in the QML command → `theEraserStrokeCarriesItsModeAndBrush` fails. The pan
accepting the left button under Paint again → `spacePansInsteadOfPainting`
fails ("the armed brush still gave the left button to the pan"). `]` stepping
the size down → `theKritaKeysPickTheToolsAndAdjustTheBrush` fails. `paintStroke`
not cleared on release → `thePaintToolSendsOneStrokeOnRelease` fails. `radius`
pinned to `8` instead of `paintSize / 2` → the same case fails. The matte guard
removed → the same case fails on the press outside the picture. Each restored,
then the suite green three runs in a row.

Copy keys and mini toolbar: deleting the `MenuShortcut` from the Viewer's
`Copy image content` entry → `theCopyEntriesNameTheirKeys` fails with "the
copy-image entry draws no key"; changing the Browser's `Ctrl+Alt+C` hint to
`Ctrl+C` → the same case fails `Actual "Ctrl+C" / Expected "Ctrl+Alt+C"`. On the
shell half, renaming `Ctrl+Shift+C` to `Ctrl+Alt+Shift+C` in `Main.qml` →
`theShellBindsTheCopyKeysItsMenusName` fails with "no Shortcut is bound to
Ctrl+Shift+C". For the mini row, dropping `visible: !view.miniToolbar` from the
Viewer's zoom-in button → `theMiniToolbarFoldsTheSecondaryActions` fails
(`buttons 6`, expected 5); pointing `minimumWindowWidth` back at
`compactToolbarWidth` → `theFloorIsTheMiniToolbar` fails with "the floor 782 is
not below the compact row 782, so the overflow menu would never be used". Each
restored, then the suite green.

## Design decisions, export-size session (ADR 0004)

- **A delivery size is one number: the long edge.** `max_edge` scales the whole
  frame and never crops or pads, so an export cannot quietly lose content the
  way Resize's cover-crop can — and Resize already owns exact `W × H` with its
  own fill. The dialog offers six presets (`Original size`, 3840, 2560, 1920,
  1280, 800) and starts on the document's own size every time, because a copy
  that shrank because the last export asked for a small one would be a surprise.
- **Core decides the size; the view only picks a preset.** `export_dimensions`
  is the rule (aspect kept, longer side = the limit, never upscaled, never a
  zero side) and lives in `editor.rs`; the QML labels the rows and holds one
  integer. The view therefore never predicts the other side and cannot disagree
  with what is written.
- **The combo box and the property are one choice.** `chooseExportSize` sets
  both, and `onActivated` goes through it, so a preset applied from a test or
  the dev harness moves the visible row too. The first window grab of this
  feature showed the combo still reading `Original size` while Core was told
  800 px — the function now owns both halves.
- **A resized copy keeps ICC, drops EXIF.** EXIF still names the source's pixel
  dimensions and may embed its thumbnail, so it is a lie in a smaller file; APP2
  (ICC) and APP13 (IPTC) are copied because colour must not change with the
  size and the credit is still true. A copy that is not resized carries all
  three, as before.
- **`0`/absent means "the document's size".** An older client that knows only
  `path` still exports unchanged; `editor_export` filters `Some(0)` to `None`
  before the worker sees it, so a request for "no limit" cannot be a request for
  a zero-pixel copy.

## Design decisions, toolbar/labelling session (ADR 0010)

- **Labels are earned.** `ToolbarMetrics.qml` measures every piece of the header
  row (icon square, label addition, separator, gaps, margins, busy indicator,
  menu, plus the Viewer's counter and the Editor's zoom as `TextMetrics`) and
  derives both the floor (`compactToolbarWidth`) and the label threshold. A
  button is either an icon square or icon + label, never a clipped half-label.
- **The threshold is per language.** The label measurements are
  `qsTranslate("WorkspaceSwitcher"|"Main", …)`, the contexts that actually draw
  those words, not `qsTr()` (which would look them up in `ToolbarMetrics`'
  own context and silently measure English). Measured: 1131 px English, 1225 px
  Vietnamese, +94 px = the label growth, same 210 px headroom.
- **The floor is enforced twice.** `minimumWidth` for the compositor, and
  `onWidthChanged → Qt.callLater(enforceMinimumWidth)` because this GNOME/Wayland
  session accepts a programmatic `resize` below a window's minimum.
- **Only the launch path resizes the window**, from the header-read image size,
  capped at 92 % of the screen minus the chrome, clamped to the floor, never
  upscaling. Opening a folder inside the app never moves the window.
- **`fittedZoom()` caps at 1.0**; the wheel and buttons still go past 100 %.
- **A one-image folder hides the filmstrip** (`filmstripShown`); the stored
  preference is untouched.
- Fixtures (`tst_ToolbarFixture.qml`, `tst_ToolbarRow.qml`) live beside the views
  because Qt resolves local types as siblings, and are deliberately absent from
  `crates/desktop/build.rs` so they never ship.

## Known gaps, in the words they were last measured with

- **No physical key reaches the copy bindings either.** Row 87's
  `KOGAVIEW_DEV_KEY` hands each `Shortcut` the `QShortcutEvent` its handler
  consumes and logs both clipboards and the toast afterwards; that proves the
  binding, the `enabled` gate and the handler, not the compositor delivering
  `Ctrl+Shift+C` to the window. That `Ctrl+C` in a focused field stays the
  field's is a consequence of choosing two other combos, not a measured
  collision: no text field was focused while a copy key fired.
- **The mini floor is a trade, not a win everywhere.** At exactly 580 px with
  both Browser panels open the grid is ~55 px wide and the Editor's canvas
  ~100 px (`M1-toolbar-mini-floor.png` is that window). The panels can be dragged
  or toggled from the overflow menu; the floor counts one sidebar plus a
  picture, not two sidebars.
- **The overflow menus were opened with `popup()`, not by clicking `⋮`.** Their
  rows, check marks and keys are real; their placement is the positioner's
  default (the Browser's opened at the bottom-left of the window), which a click
  would not produce.
- **No hand resized the window.** A temporary `QWindow::resize` hook produced the
  mini-toolbar shots, and on one early run this session's compositor rearranged
  the window mid-run (a 1296 px window shrank in steps while keys were being
  delivered); four later runs of the same request held at 700 × 620, and the
  evidence comes from those. It is recorded as unexplained, not as a product
  bug; a compositor-clamped drag remains unproven.
- **A `Menu` popup is still the platform's light theme on a dark window.** The
  key hint takes the entry's own text colour now, so it is legible on either
  theme; the popup background, separators and hover colour remain the style's,
  exactly as before this change.
- **No key was pressed by a hand.** `xdotool`/XTEST input does not reach the
  Wayland/XWayland window here, so the real-window keys were `QTest`-synthesised
  through the app's real focus path (temporary `KOGAVIEW_DEV_KEYS` hook, removed
  before commit). The QML suites send the same `QTest` key events into the real
  `.qml` sources. A compositor delivering physical key repeat to the window was
  not exercised; the Delete guard is asserted with a synthetic `QKeyEvent` that
  sets `autorep`, not by holding a key.
- **Ctrl+1/2/3 have no suite test.** They live in `Main.qml`, which needs the
  bridge; their evidence is the real-window journal (three `set_workspace`
  entries with focus following browser → viewer → editor → browser).
- **The Resize panel grab used a temporary build.** `M1-editor-resize.png` came
  from a run whose defaults were `tool: "resize"`, padding on and a red fill, so
  the panel shows every resize control at once; those three defaults were put
  back (Pointer, padding off, white) and the tree committed is the shipped one.
  The square result (`M1-editor-resize-square.png`) is the shipped binary.
- **The anchored cover loses pixels on purpose.** A non-square source scaled to
  a different aspect is cropped, not letterboxed; only `fill` pads. Whether the
  user wants "cover" or "fit with transparency" as a second mode is unasked.
- **A resize is applied on Apply, but it no longer previews blind.** The live
  draft (`editor_resize_preview`, rows 73 and 76) draws the new size on the
  canvas before it is committed; the document, its history and its save target
  do not move until Apply.
- The dock and app grid were never photographed. Proven at the icon-theme and
  desktop-entry layer. If a launcher already cached the miss, the empty square
  can persist until the session restarts.
- **No resize was performed by a hand.** A temporary hook called
  `QQuickWindow::resize`; the geometry and zoom it produced are real, the gesture
  was not. Fullscreen/maximise was not exercised.
- **The system wheel scroll rate was not measured.** A pixel-only device gets the
  named `notchPixels: 20`.
- **Row 80's window showed one rejection, not all of them.** The 32 new
  Vietnamese sentences were reviewed in the catalogue, but only the export-onto-
  the-document toast was drawn on a real window (`M1-rejection-vi.png`); the
  cancellation, delete and invalid-edit sentences are covered by the QML case and
  the translation gate, not by a photograph. A rejection whose `ui` is absent
  (an OS `io_error`, an `invalid_path`) was exercised only as
  `invalid_envelope` in a unit test; the window never printed one. `cargo
  clippy -D warnings` still fails on the two pre-existing `derivable_impls`.
- **The resized-export checks used a synthetic profile.** The "ICC is kept"
  assertion rests on an APP2 segment written by the test helper, not on a real
  camera profile, and no CMYK/progressive JPEG was exported. One early grab
  showed the Resize panel after an export; four later runs of the same request
  did not, and the harness now logs `tool` as `pointer` on both sides of the
  confirm click. It is recorded as unexplained rather than fixed.
- `scripts/check_translations.py` now scans the QML for `qsTr()` **and**
  `qsTranslate("Ctx", "src")` after stripping comments, so a new untranslated
  string fails the gate — the small-image hint got through before this, and the
  English-measured threshold got through with every check green.
- **A grab needs an exposed window.** `KOGAVIEW_DEV_SCREENSHOT` now raises and
  activates the window, waits up to 20 s for exposure and fails if it never
  comes. Grabbing an unexposed window is no longer accepted: it returned the
  last committed frame — the pre-fit picture at the wrong zoom with no hint —
  while the window's own geometry log said `zoom 1`, canvas `300×200` at
  `289,15`. With raise+activate the same run grabbed the correct frame. Every
  screenshot is a window grab of an exposed window; nothing was photographed on
  the physical screen.
- **First paint was not photographed frame by frame.** The screenshots show the
  settled window; "fitted from the first frame" rests on the launch path setting
  the size and the fit before the picture decodes, not on a capture.
- **No window was ever resized by a hand.** The floor and the label threshold
  were driven by a temporary hook calling `QQuickWindow::resize`; the numbers
  are real, the gesture was not. A compositor-clamped drag is still unproven.
- The floor guard in `Main.qml` has no QML test: `Main.qml` needs the bridge, so
  its mutation was checked on the real window only.
- At the floor the compact toolbar has visible slack (857 px budget for a
  842 px row) because the floor also includes the side panels and the widest
  workspace's readouts.
- `cargo clippy -D warnings` fails on two pre-existing `derivable_impls` in
  `crates/app-protocol/src/lib.rs`.
- **No hand dragged a crop frame or a quad.** The real-window runs moved one
  corner through `setTransformCorner`/`moveTransformEdge` — the functions the
  handles call — and the drags themselves are `QTest` pointer sequences inside
  the QML suite. A pointer sequence on this compositor was not delivered to the
  window (see above), so a hand's frame-by-frame drag is still unexercised.
- **The transform is one projective quad onto the document's own frame.** It
  keeps the document size, never crops to the quad's aspect, has no rotation of
  the quad, no lens/barrel model and no "keep transparency outside the quad"
  mode; outside the quad the sampler clamps to the border pixel, so the leftover
  smears. That is a decision, not a measured user preference.
- **The warp's cost on a large document was not timed.** The 1 200 × 1 600 draft
  had landed before the 18 s grab; nothing finer was measured, and a 27 MP warp
  may be slow enough to want tiling (the same gap row 79's tiled-decode item
  names).
- **The crop frame's on-screen numbers are geometric, not pixel-perfect.** On
  the grab the frame's two horizontal borders are 195 px apart and it is 261 px
  wide at 0.51 zoom (= 384 and 512 document pixels); the accent-colour bounding
  box also picks up the eight handles, so the box itself measures 269 × 203.
- **No hand pressed Discard or the dialog's buttons.** The real-window run
  answered the guard through `KOGAVIEW_DEV_UI_REQUEST=leave-guard`/`_ARG2=discard`
  and pressed Apply through `_ARG5=apply`; both call the same QML handlers and
  both commands reached the journal, but no pointer was on the window. The
  discard sequence itself is proven by the journal order, and by Core's test
  walking the same commands.
- **The short-window scroll bar was not photographed.** The dialog was captured
  at 1472 × 943, where its natural height fits; the `ScrollBar.AsNeeded` case
  (a window shorter than the form with `Pad to fit` armed) rests on the QML
  fit assertion in `tst_editor` at the 1100 × 700 test host, not on a grab.
- **The palette fix is two switches, not a sweep.** A Popup built inside the
  workspace `Loader` resolves the platform palette, and this Qt build ignores a
  QML `palette` write on a `CheckBox`; only `ResizeDialog`'s two labels were
  changed to a `Text` content item with the theme colour. The Editor's export
  dialog and any other popup keep whatever the style gives them.
- **The Resize form has no live preview anywhere now.** `editor_resize_preview`
  remains a protocol/Core command with its own tests, but no QML emits it; a
  resize draft in `editor.previewDraft` is drawn by nothing. Whether the command
  should be deleted is a protocol decision, not part of the UI change.
- **The first frame was checked by delay, not by frame capture.** The 150 ms
  grab shows the form already at its final size, and the QML case asserts the
  height does not change after the first layout; a capture of the compositor's
  very first painted frame is still not available here.
- **Row 86's first-frame claim is a log, not a frame capture.** On the real
  window the trace after the opening click read `visible true, opened false` at
  the centred `x/y`, and the 100 ms sample had not moved; the two screenshots
  are window grabs taken after their own raise/exposure wait, so they show the
  settled form. Breeze's enter transition is not deterministic on every launch
  (one run finished it before the hook could sample), which is why that run used
  `QT_QUICK_CONTROLS_STYLE=org.kde.breeze`; no hand opened the form, and only
  this GNOME Wayland session was measured.
- Flatpak, Windows, the portal Save-As chooser and the Editor's adjustment
  operations remain unverified as recorded in earlier rows.
- **No hand drew a stroke.** The real-window runs drove `beginPaintStroke`/
  `extendPaintStroke`/`finishPaintStroke` through the `editor-paint` hook, which
  is the same path the canvas `MouseArea` calls; the drag paths themselves are
  `QTest` pointer sequences in `tst_editor`, and this compositor does not
  deliver synthetic pointer moves to the window. No pen, pressure, tilt or
  stylus eraser was exercised.
- **The brush is one hard-edged round tip.** There is no spacing, softness,
  blending mode, colour picker or eyedropper; the eight swatches and the
  `#rrggbb` field are the whole palette question. Krita's `[`/`]` step the size
  by 1 px (10 with Shift) between 1 and 400 display px, while Core accepts a
  radius up to 4096 — the view's range is narrower than the protocol's.
- **The in-flight stroke is not held until the preview lands.** The overlay is
  cleared on release, so the canvas shows the previous frame for the moment the
  worker renders; the alternative was not built, and no frame-by-frame capture
  proves how long that gap looks. The eraser's in-flight mark is a solid line in
  the theme's thumb colour rather than a checkerboard or a live cut, so it says
  "erasing" more than it shows the result.
- **`Tab` hides only the Editor's panels.** The shell's toolbar stays, because
  it is the window's, not the Editor's; Krita's canvas-only mode would hide
  more. Space-pan and Tab were asserted with `QTest` keys, not a keyboard.
- **The paint tests found a suite flake, not a product bug.** Seven resize and
  palette cases failed after the paint cases were added; the cause was a Resize
  form answered by the previous case still fading out while its modal overlay
  took the next case's click. `init()` and `openResizeDialog()` now wait for
  `visible` to go false and close both modal forms. It passed 46/46 on three
  consecutive runs after the fix; the underlying fade timing on a slower
  machine was not measured.

## Installed binary (this session, after `fad0fb1`)

`just install-dev` → `dev-prod` preset. Measured on `/usr/local/bin/kogaview`:
33 MB (Release 28 MB, Debug 220 MB); `--version` prints
`io.github.tienv2i.KogaView`; startup log `profile="prod"`,
`state_dir=…/kogaview`; `KOGAVIEW_DEV_COMMANDS`, `KOGAVIEW_DEV_GEOM` and
`KOGAVIEW_DEV_SCREENSHOT` all worked on it (journal ids `dev-1`, `dev-2`,
`ok:true`; a 1280×820 window grab showing the Viewer with no "(Dev)" suffix).
A launcher-started instance was also seen running from that path.

Reinstalled after the language follow-up and smoke-tested on that binary with an
isolated `XDG_CONFIG_HOME` (`language: "vi"`, a 300×200 picture): it opened at
878×420, the icon-only toolbar, the hint `Ảnh nhỏ đang hiển thị ở 100 % …`, and
the instance reported `profile="prod"`. The owner's own configuration and the
`image/jpeg` default handler were not touched.

The prefix binary was **not** reinstalled for the keyboard commit or any
follow-up since; it predates rows 66 and 77–88 until the next `just install-dev`
(or `just install`). The keyboard, tooltip, menu, export, canvas and row 87–88
evidence all comes from `build/dev/bin/kogaview`.

## Next natural step

1. **Tiled decode for the Editor document** (row 60's second half). The first
   preview now arrives about 2× sooner on a 27 MP JPEG (row 79), but the full
   frame still decodes in one piece before any edit is possible; region-of-
   interest decoding would let a crop read only the pixels it keeps.
2. **Colour-profile handling on export.** Row 81 passes the source's ICC
   segment through unchanged and drops a resized copy's EXIF; converting to
   sRGB (or embedding a target profile) is a decision that needs a colour
   library and a Flatpak dependency review, and "pass through" is the honest
   default until then.
3. **The platform's own text is still the platform's.** Row 80 made every
   rejection Core *words itself* a line; an `io_error` or an `invalid_path`
   still carries the OS/library sentence (`ProtocolError::new`, no `ui`), and
   `spawn_draft`'s render failure keeps its message. Translating that means
   classifying the errno rather than passing `io::Error`'s string through —
   a decision about what the user should be told, not a mechanical sweep.
4. **The canvas now edits, so decide what "outside the quad" should look like.**
   Row 82's warp clamps to the border pixel; transparent or a fill colour would
   be a different result, and neither was asked for. Related: the crop frame
   accepts a rectangle anywhere on the document but never offers to keep its
   ratio while dragging (the ratio lock still only links the typed fields).
5. **The warp is one pass over every pixel on a worker thread.** `spawn_draft`
   already renders drafts on a `std::thread::spawn`, but a corner drag on a 27 MP
   document with Live preview on re-renders the whole frame per settle. Profiling
   it before adding tiling (item 1) is the cheaper move.
6. **Decide whether `editor_resize_preview` still has a front end.** Row 84
   removed the only QML that asked for a resize draft. The command is tested in
   protocol/Core, but no window emits it; keeping it for a future CLI is a
   contract decision, and deleting it would remove a payload shape that row 73's
   preview work introduced.
7. **Painting is one hard tip and one pass per stroke.** Softness, spacing,
   pressure and a colour eyedropper are the natural next questions, and a long
   stroke on a 27 MP document re-renders the whole bounding box on a worker —
   tiling it belongs with the same profile that item 5 asks for. Keeping the
   in-flight overlay until `previewRevision` advances would remove the
   one-frame gap where the old preview shows.
8. **The copy keys need a real keyboard, and a decision about the Editor.**
   `Ctrl+Shift+C`/`Ctrl+Alt+C` were driven by `QShortcutEvent` injection, so a
   desktop that already owns either combo (an IME, a clipboard manager, a
   terminal) has not been ruled out. The Editor has no copy entry at all: whether
   its document should reach the clipboard before Save/Export is a contract
   question, not a menu row.
9. **The mini row has no room for two sidebars.** The floor counts one sidebar
   plus a picture, so at 580 px a user who wants both panels shrinks the content
   to a strip. Auto-hiding the panels below a width, or letting each panel fold
   on its own, would be the next question — the current answer is the overflow
   menu's two toggles, which is honest but manual.
