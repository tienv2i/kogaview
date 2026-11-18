# Session handoff — state at 2026-11-18

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
and only the leftover is filled, square or not.

Nothing here is a plan; it is what was measured, what was not, and why.

## Tree

- Branch `main`. The pad/stepper follow-up (row 76) is the newest commit on top
  of `bc9cd54` (the size steppers and current-ratio lock); the tree is clean
  after it. This session's earlier commits are on top of `d149152` and are
  listed in `git log`; the newest are the keyboard map, the tooltip hints, the
  burger-menu fix, the modal-pointer fix, the Editor layout and its pointer
  follow-up, and the two size tools.
- `cpp/main.cpp` gained one permanent debug hook per size tool:
  `KOGAVIEW_DEV_UI_REQUEST=editor-resize` (`_ARG` = `WIDTHxHEIGHT` of a preset,
  or a custom pair; `_ARG2` = an optional ratio key such as `current`; `_ARG3` =
  a fill colour that arms `Pad to fit`; `_ARG4` = stepper taps such as
  `w+3,h-2`) clicks the real Resize tool button, applies the size through the
  same helper the dropdown's selection calls (or writes the two fields for a
  custom pair), arms the pad, clicks the stepper buttons and Live preview, and
  `editor-crop` (`_ARG` =
  `WIDTHxHEIGHT`, `_ARG2` = an anchor key, default `center`) does the same for
  Crop including an anchor button — found by walking the item tree, because a
  `Repeater` delegate is not a QObject child. Both exist so the panel can be
  photographed on a session where XTEST pointer warps do not move the pointer.
  The language
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
  permanent `editor-resize` and `editor-crop` requests above.
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

- Build needs `PATH=/tmp/opencode/lrel/bin:$PATH` (`lrelease` from a PySide6
  copy found by `scripts/find_lrelease.py`).
- `KOGAVIEW_DEV_SCREENSHOT` works on the real Wayland window (a window grab needs
  no compositor permission); `QT_QPA_PLATFORM=offscreen` loads no icon theme.
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

## Test gate

`PATH=/tmp/opencode/lrel/bin:$PATH just test` — exit 0:

```
translations: 172 strings in kogaview_vi.ts, 110 of them compiled into C++, 168 drawn by the QML, 4 looked up by context
packaging: 19 MIME types, 3 categories, icon and metainfo named …
cargo: 65 passed (kogaview-core) + 4 passed (kogaview-protocol)
viewer 37 · browser 45 · cache 15 · state 7 · settings 14 · editor 34 · language 5 · toolbar 11
```

`cargo fmt --check` clean. `cargo clippy -p kogaview-protocol -p kogaview-core --all-targets`
still reports the two pre-existing `derivable_impls` warnings in
`crates/app-protocol/src/lib.rs` (`impl Default for Workspace`/`Theme`, lines 53 and 135) and
the pre-existing core warnings (`too_many_arguments`, `while_let_loop`, `sort_by_key`,
`field_reassign_with_default`, `needless_return`); the Resize rework adds no new warning
(the protocol's `Anchor` and the anchored Core helpers are gone).

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

Keyboard: Left/PageUp stepping `+1` instead of `−1` → `navigationKeysAskCoreForTheNeighbour`
fails at index 3; Shift+Space made a plain "next" → the same test fails at index 5;
the Ctrl+A guard changed to `Key_B` → `ctrlASelectsEveryEntry` fails; `gridColumns()`
hard-coded to 1 → `downMovesByOneGridRow` fails (it compared the cell to the right
with the cell below); dropping `!event.isAutoRepeat` from the Delete branch →
that view's Delete test fails on the synthetic repeat event (viewer and browser
re-run separately). All restored, then `just test` green.

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
- **Resize has no live preview on the canvas.** The size is applied on Apply, as
  before; the panel and the post-edit preview are the only feedback.
- The dock and app grid were never photographed. Proven at the icon-theme and
  desktop-entry layer. If a launcher already cached the miss, the empty square
  can persist until the session restarts.
- **No resize was performed by a hand.** A temporary hook called
  `QQuickWindow::resize`; the geometry and zoom it produced are real, the gesture
  was not. Fullscreen/maximise was not exercised.
- **The system wheel scroll rate was not measured.** A pixel-only device gets the
  named `notchPixels: 20`.
- **Core's status text is still English** (`Ready`, `Editing photo-1.jpg`) — the
  last English strings in a Vietnamese window (ADR 0006).
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
- Flatpak, Windows, the portal Save-As chooser and the Editor's adjustment
  operations remain unverified as recorded in earlier rows.

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

The prefix binary was **not** reinstalled for the keyboard commit or the two
follow-ups; it predates them until the next `just install-dev` (or `just
install`). The keyboard, tooltip and menu evidence comes from
`build/dev/bin/kogaview`.

## Next natural step

1. **Editor history labels and status text as data** — Core builds
   `Resize 512 × 512 · square #ff0000` and `Ready` with `format!`; publishing
   `{ code, args }` and translating at the presentation edge removes the last
   English strings in a Vietnamese window (which now includes the Resize
   history line and its anchor names).
2. **Export** the working document with real options (JPEG quality, metadata) —
   ADR 0004 left them out.
3. **Editor open speed** (row 60): downscaled JPEG decode for the preview, tiled
   decode for the document.
