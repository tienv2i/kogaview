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
width and shows its labels about 350 px sooner. The latest session (row 90)
finished the Crop tool: it has a frame the moment it is armed, a chosen ratio
survives handle and create-drags, the discarded picture is dimmed outside the
frame and split by rule-of-thirds guides, the rectangle turns through 90° with
one button, arrows/Shift/Alt nudge and resize it, Enter applies and Escape puts
the tool down, Apply refuses the whole document, and an applied crop leaves a
fresh frame on the cropped result. The current pass (row 91) turns Resize into a
scale form: two numbers with one drawn chain, a concrete size preset, an
always-visible background and a real resampling filter, opened with
`Ctrl+Alt+I` with Width selected; Crop gains a Center/Grow choice, where Grow
lets the rectangle leave the picture and paint the new border in a chosen
colour. This pass (row 92) gives Crop back to the user: it opens with no frame,
a drag, a click, a typed side, a preset or an anchor builds one, Width/Height/
Ratio each carry a lock so only two of them can be inputs, the ratio is a text
field (`3:2`, blank for free), Reset restores the panel while Clear puts the
frame down, and an applied cut leaves a frame over the whole result. A follow-up
(row 93) makes the format list true: AVIF now decodes in the Editor (the `avif`
feature was an encoder; `avif-native` and a libdav1d link line supply the
decoder), an undecodable file is refused with a translatable line instead of an
English library error, and `.jpe` is listed as the JPEG it is. This pass
(row 94) turns the Editor's left column into the drawing-first rail the user
asked for: twelve of the repository's own SVGs in a two-column grid of 34 px
squares, a bottom control that folds it to one column, a tooltip and an
accessible name on every button, and the 220 px text sidebar and its splitter
gone; the Crop and Resize number fields gained a `px`/`%` selector that
re-spells the same pixel quantity (percent of the document's width for Width, of
its height for Height) without ever reaching the protocol. A same-day follow-up
on that row moves the selector out of the field to sit beside it, leaves X and Y
without one (a place is a pixel coordinate, not a fraction), dims the whole
picture while Crop is armed and no frame exists, shortens the crop button to
`Apply`, pins the rail drawing at its own 20 px so the first click cannot resize
it, and moves the Editor's Back-to-browser button into the Viewer's first slot.
The pass after that (row 95) splits the Editor's right column in two — the armed
tool's options above a draggable divider, and Info / History / Preview as tabs
below — so a crop no longer hides the document's history and thumbnail and the
pointer column has room to be reference only. The tab strip is drawn in the
app's colours (`PanelTabs.qml`), labels fold to drawings under 240 px, arming a
tool opens the zone, and the pinned Apply/Reset/Clear row is a grid whose column
count follows the measured width of the three translated labels — three 80 px
buttons do not fit the default 236 px row, so Apply takes a line of its own and
`Bỏ khung` stays whole instead of eliding. The latest session (rows 96–98)
takes the three separate right-hand columns apart and builds one shared dock:
the Browser shows its preview over the file's details, the Viewer gets the
details it never had, and the Editor keeps the tool options on top and `Info`,
`History` and `Original` below — where `Original` is now the file on disk rather
than Core's working render, keyed on its mtime and size so a save over the same
path is a new picture. A one-page dock draws no tab strip. Each workspace's
panel visibility is its own flag in `config.json` and in `UiState`, while the
dock's width is one session value shared by the three views. The Editor's tool
zone no longer has a divider or a fixed 440 px height: it is as tall as its
options, its action row sits directly under them, and only a window that cannot
keep 180 px of reference below it makes the options scroll — `PanelDivider.qml`
is deleted. The pointer's heading always reads `Pointer options` and its body
`This tool has no options.`, and Resize leaves the pointer armed behind its
modal. Finally the Browser's file, folder and quick menus and the Viewer's
canvas menu gained `Show in folder`, which asks `org.freedesktop.FileManager1`
to select the path, falls back to the portal's containing folder and then to the
default handler. On the real window the Original tab first drew black, because
it handed the thumbnail cache where a `ThumbnailBook` was expected and the
`TypeError` left `edge` at 0; the binding and its test were fixed.

This session (rows 99–103) was a correctness pass on five things the user
named. Resize no longer changes a picture's shape by silently throwing the ends
away: `Stretch to size` is the default and the whole frame is scaled, `Cover` is
the old centred crop under its own name, `Pad` keeps fit-and-fill and is the
only mode with a colour, and a locked ratio that rounds by a pixel no longer
shaves a strip off two sides (row 99). The Editor's dock can now put its three
reference pages away — only the 34 px tab strip stays at the bottom and the
options take the height — and a vertical divider between options and reference
is back, because a fold and a split answer different questions (row 100). "Show
in folder" no longer asks whether a file manager is *running*: the call goes out
and the bus activates one, which on a nested session started Dolphin with
`--select` on the file (row 101). Reopening a file is now defined: the Viewer's
source carries the file's mtime and size, so a picture another program rewrote
is re-read, while the Editor treats the same path as the same document — no
re-decode, no lost history — and a *different* picture asked for over unsaved
edits is refused in Core and questioned by the shell (row 102). The duplicate
"Explore here" menu entry is gone (row 103).

Nothing here is a plan; it is what was measured, what was not, and why.

## Tree

- Branch `main`. Rows 99–103 are one commit on top of `346d65c`,
  `feat: an honest resize, a foldable dock and a defined reopen` (its hash is
  the one `git log -1` prints; this file is inside that commit, so it cannot
  name itself without going stale): the protocol's `ResizeMode`/`for_payload`, Core's three render
  branches, `validate_resize_mode` and the `cover_rect` snap, the Resize form's
  `Fit` row, the dock's fold (`PanelTabs`/`RightDock`) and vertical
  `PanelSplitter`, `EditorView`'s `referenceFolded`/`toolZoneHeight`,
  `PlatformHelper::revealInFolder`, `viewer_modified`/`viewer_size` with the
  Viewer's `?v=` source, `open_editor`'s reopen guard, `Main.qml`'s
  `requestEditorOpen`, the "Explore here" removal, the harness's `_ARG6`
  (`editor-resize`) and `_ARG5`/`_ARG6` (`editor-dock`), the tests, ADR 0012 and
  0020 revisions, the new ADR 0021, the report rows and the nine screenshots.
  Not pushed: `origin` refuses (`No anonymous write access`).
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
  The crop-completion session (row 90) is one commit on top, `11fd126
  feat(editor): finish the crop tool`: `EditorView.qml`'s seeded frame, ratio
  lock in drags, shade and thirds, swap, keyboard, no-op guard and
  document-change refit; six new `tst_editor` cases plus two rewritten ones;
  `editor-crop`'s `seed`/`swap`/`apply` arguments and its ratio/document log;
  the reworded hint, Apply label and swap tooltip in the `.ts`; the stale
  `Apply crop` C++ row removed; ADR 0011's revision; four screenshots.
  Commit `af3fbfc just play` landed the scale-form/crop-grow work of row 91 and
  a first cut of row 92's Crop rework (the unframed start, the three locks, the
  ratio text field, the reordered panel, `ensureCropFrame`, `clearCropFrame`,
  `resetCropOptions` and `settleAppliedCrop`) without a report row of its own.
  The crop-rework follow-up is **uncommitted**: `EditorView.qml` (the
  `cropHeightAuto`/`cropWidthAuto` keystroke follow, the white-on-accent
  padlock glyph, the lock buttons resyncing after a refused third lock, and the
  removed `swapCropOrientation`), `cpp/main.cpp` (the `editor-crop`
  `unframed`/`full`/`clear` and lock/reset arguments, the `_ARG9` preset a
  `clear` run builds first), `tests/qml/tst_editor.cpp`
  (the five new crop cases, nine updated bodies and the removed swap/preview
  cases), `i18n/kogaview_vi.ts` + `cpp/translations.cpp` (4 new sentences and
  15 vanished entries), ADR 0011's second revision, `docs/M1-REPORT.md` and this
  file, and six screenshots under `docs/evidence/`. Row 93 is **also
  uncommitted** on top: `crates/app-core/Cargo.toml` (`avif-native`),
  `CMakeLists.txt` (`PkgConfig::DAV1D` on the executable), `editor.rs`
  (`has_decoder` builds the decoder, plus the AVIF and no-decoder tests),
  `core.rs` (the `open_editor` guard and its test), `app-protocol`'s `jpe`,
  `ops.rs`, `scripts/dev.py` (doctor's libdav1d line), `docs/BUILD.md`,
  ADR 0005's revision, `docs/M1-REPORT.md`, this file and four screenshots.
  Row 94 is **also uncommitted** on top: `crates/desktop/qml/icons/` (twelve
  SVGs), the new `crates/desktop/icons.qrc` and its `.qrc` line in
  `crates/desktop/build.rs`, the new `ToolRailButton.qml` and `UnitField.qml`
  (both added to the QML list, `UnitField.qml` also to `i18n/kogaview_ts.pro`),
  `EditorView.qml` (the rail, `toolColumns`/`toolRailWidth`, the four crop
  `UnitField`s with X/Y pixel-only, whole-pixel canvas position, the
  `cropShadeEmpty` whole-picture dim, the `Apply` label and the Back button moved
  to the first toolbar slot), `ResizeDialog.qml` (two `UnitField`s, `px` on
  every open, focus/Tab through `inputField`), the follow-up's `UnitField.qml`
  as a `RowLayout` around the `TextField` and its selector, `ToolRailButton.qml`'s
  wrapper `contentItem` (`iconDrawing`), `tests/qml/tst_editor.cpp` (three new
  cases, the `chooseUnit` helper, `textInput()` for a row-shaped field, the
  no-frame shade assertions, an `init()` that resets the fold and the units and
  fits the view), `tests/qml/tst_toolbar.cpp`
  (`theBackButtonLeadsEveryWorkspaceToolbar`), three Vietnamese sentences in
  `kogaview_vi.ts` plus the compiled table (`Apply crop (Enter)` retired), ADR
  0018 and its follow-up notes, ADR 0011's no-frame note, `docs/M1-REPORT.md`,
  this file and three screenshots.
  Row 95 is **also uncommitted** on top: the new `PanelTabs.qml` and
  `PanelDivider.qml` (both in `crates/desktop/build.rs`), four SVGs
  (`info`, `history`, `preview`, `chevron`) in the new `icons.qrc`,
  `EditorView.qml`'s two-zone inspector (`rightToolZoneHeight`,
  `toolZoneFolded`, `rightTab`/`rightTabEntries`/`rightTabIndex`, the heading
  and its `toolZoneToggle`, `toolOptionsScroll`, the `GridLayout` action row and
  the view's `cropActionsStack` measurement,
  the divider, the tabs and the Info/History/Preview `StackLayout` pages),
  `cpp/main.cpp`'s `editor-dock` request and its comment, `tests/qml/tst_editor.cpp`
  (`theInspectorSplitsToolsFromThreeReferenceTabs`, `selectRightTab`,
  `scrollOptionsIntoView`, four rewritten cases, `init()`'s new resets), four
  Vietnamese sentences in `kogaview_vi.ts`, ADR 0019, `docs/M1-REPORT.md`, this
  file and six screenshots.
  Rows 92–98 are committed on top in three commits, not the four originally
  planned: `6b6ef19 feat(core): panel flags per workspace, saved-file identity
  and AVIF` (rows 93 and 96's Rust, the format/build plumbing), `f97ec04
  feat(shell): one right dock, a content-sized tool zone and file reveal`
  (rows 96–98 plus the QML/C++/tests of rows 92, 94 and 95, which sit on the
  same files), and the docs commit itself (the report rows, ADRs 0018–0020, the
  revisions, the contract and the twenty-five grabs). Splitting by row would
  have been a fiction: `EditorView.qml` carries rows 90–98, the `.ts` carries
  every string and
  `docs/M1-REPORT.md` every row, so the split is by layer and the shell commit
  names the earlier rows it carries. The tree at each row was not separately
  run; the full gate was run once on the whole tree.
  `git status` is the authority for exactly what is still open.
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
  permanent `editor-resize`, `editor-crop`, `editor-transform`, `editor-paint`,
  `editor-export` and `editor-dock` requests above, plus row 87's
  `KOGAVIEW_DEV_KEY`. `editor-dock` (row 95) is the dock without a pointer:
  `_ARG` names the reference tab, `_ARG2=fold` presses the chevron,
  `_ARG3` writes the dock's width and `_ARG4` clicks a rail tool button only
  while it is not selected; it logs the tab, its index, the fold, the width and
  the armed tool, and sends no command — which is the point, because a tab
  click leaves the journal untouched. It is what produced rows 95–97's six
  dock grabs (the divider it used to mention is gone; the fold and the tab
  remain), and the `Editor` run for `M1-editor-original-vi.png` is where the
  black Original frame was seen: the page had handed the `ThumbnailCache` where
  its `ThumbnailBook` was expected, `edgeFor` raised `TypeError`, `edge` stayed
  0 and no picture was requested. The log's last label read `tabs` while
  printing `rightTabIndex`; it now says `index`.
  `editor-transform` (row 82) clicks the Transform tool, moves one corner
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
| 90 | Crop still asked to be typed into: no frame on a fresh document, a chosen ratio broken by every drag, nothing dimmed outside the frame and no thirds, no one-button turn, no keyboard, Reset emptied the form, Apply accepted the whole document (`edit_noop`), and an applied crop left the tool with no frame | `EditorView.qml` (`cropRatio: "free"`, `seedCropFrame`, `cropSeedDebounce` + `refitCropAfterDocumentChange`, ratio-aware `dragCropHandle`/`dragCropCreate`, `cropShade` + four thirds lines, `swapCropOrientation`, arrow/Shift/Alt/Enter/Escape, `cropCanApply`, `applyCrop` order), `cpp/main.cpp` (`editor-crop` `seed`/`swap`/`apply` + ratio/document log), `tst_editor` (six new cases, `resetRestoresTheStartingCropFrame`, free-default assertion), `.ts` (hint, “Apply crop (Enter)”, swap tooltip), ADR 0011 revision | editor 55; real window (Vietnamese, isolated `XDG_*`): seeded 1003 × 1003 frame with shade/thirds (`M1-crop-seed-vi.png`), 4:3 → 3:4 swap to 384 × 512 at (435,371) (`M1-crop-swap-vi.png`, `M1-crop-ratio-locked-en.png`), apply `512 384 742 870` then a fresh 410 × 307 frame on the 512 × 384 document (`M1-crop-applied-vi.png`); 11 mutations caught, one equivalent reordering recorded |
| 91 | Resize asked for its shape through a ratio table and a `Pad to fit` checkbox, so the form had a stepper, a hidden fill row and no way to say how the pixels are resampled; the lock's icon had also gone blank. Crop could only cut inside the picture, so a photo could never gain a border | `crates/desktop/qml/ResizeDialog.qml` (the +/- steppers and the Ratio combo removed; `constraint` + `lockedRatio` as the only aspect lock, captured when switched on; `Size preset` kept; an always-visible `Background` dropdown — `None` cover-crops, a colour fits and pads, `Transparent` pads at alpha 0 — with its swatch; a `Filter` dropdown; the chain drawn by a `Canvas` because an emoji glyph was blank and a themed icon would depend on the desktop; Width focused and selected on open, `Tab` to Height, `Enter` applies), `crates/desktop/qml/Main.qml` (`Ctrl+Alt+I` opens the form in the Editor), `crates/desktop/qml/EditorView.qml` (the resize command carries `fill_alpha`/`filter`; Crop gains `cropMode` (`center`/`grow`), `cropFill`/`cropFillColor`, signed X/Y, a grow border drawn on the canvas, `revealCropGrowth` zooming out when the fitted view leaves no room, the `cropFillForCommand` rule that an inside Grow rectangle travels as an ordinary crop), `crates/app-protocol/src/lib.rs` (`ResizeFilter` with `auto`/`nearest`/`bilinear`/`bicubic`/`bspline`/`lanczos3`; `fill_alpha` on resize and crop; `EditorCrop`/`EditorCropPreview` take signed `x`/`y` and an optional fill), `crates/app-core/src/editor.rs` (`resample` per kernel, `fit_with_padding` with alpha, `validate_crop_mode`, `grow_crop`, the grow history lines), `core.rs` (dispatch and draft signatures), `UiLines.qml` + `i18n/kogaview_vi.ts` (grow and refusal sentences; 28 new sources, 4 retired with the steppers and the pad), `cpp/main.cpp` (`editor-resize` background/filter/chain arguments; `editor-crop` `_ARG6`/`_ARG7`), `tests/qml/tst_editor.cpp` (the scale-form cases and `aGrowingCropReachesOutsideThePicture`), ADR 0012 and ADR 0011 revisions | `just test` translations 341/109 C++/338 drawn, cargo 85+4, viewer 40 · browser 48 · cache 15 · state 7 · settings 17 · editor 57 · language 7 · toolbar 17; `just build` and `cargo fmt --check` clean, `qmllint` only the pre-existing unqualified-access warnings; **real window** (window grabs, isolated `XDG_*`, Vietnamese): the scale form with the chain drawn in the accent colour at the checked state, `Nền` reading `Đen` and `Bộ lọc` `Bicubic` (`M1-resize-scale-form-vi.png`); `Ctrl+Alt+I` logged `declared 1 allowed 1` and opened the form with `1200` selected in Width (`M1-resize-shortcut-vi.png`); Crop in `Mở rộng` with X `-336`, Y `-224`, 1536 × 1024 and the black border drawn around the 1200 × 800 picture (`M1-crop-grow-border-vi.png`), then Apply sent `editor_crop` (`crop grow 1536 1024 #000000`, `ok:true` rev 4), the document became 1536 × 1024 with its border and a fresh frame was seeded on it (`M1-crop-grow-applied-vi.png`). No hand touched the form: the fields/buttons were driven by the harness and `QShortcutEvent` injection; the filter's visible effect, a real `Ctrl+Alt+I` press and a hand-dragged grow frame are not verified |
| 92 | Crop still placed a frame for the user the moment it opened, the ratio was a dropdown, the panel carried hints, a Live preview row and a swap button, and there was no way to say which of Width/Height/Ratio the user is pinning; Reset emptied the form and Clear did not exist | `crates/desktop/qml/EditorView.qml` (`enterCropTool` clears the fields, releases the locks and seeds nothing; `createFullCropFrame` for a click with no travel; `clearCropFrame` vs `resetCropOptions`; `ensureCropFrame` builds from a typed side, a preset or an anchor; `cropLockWidth`/`cropLockHeight`/`cropLockRatio` + `CropLockButton` padlocks painted on a `Canvas`; `cropWidthEditable`/`cropHeightEditable`/`cropRatioEditable`/`cropResizable`; ratio as text with `cropRatioPair`/`parseRatio`/`gcd`/`reducedRatio`/`applyCropRatio`/`setCropRatio`; `cropHeightAuto`/`cropWidthAuto` so a typed side does not leave `8 × 6` behind; `pendingCropResult` + `settleAppliedCrop` for a frame over the applied result; the sidebar reordered to X/Y/W/H/Ratio · mode/fill · preset/anchor · Apply/Reset/Clear; the crop hints, the crop Live preview row and `swapCropOrientation` removed), `cpp/main.cpp` (`editor-crop` takes `unframed`/`full`/`clear` — the old `seed` spelling still works — `_ARG3` lock names, `_ARG4=reset`, `_ARG8` a ratio typed after the preset, `_ARG9` the preset a `clear` run builds and then clears, and logs the three locks), `tests/qml/tst_editor.cpp` (5 new crop cases — `cropStartsWithNoFrameAndClickBuildsOne`, `theCropFieldsCreateTheFrame`, `theCropLocksChooseWhichFieldIsAnInput`, `resetRestoresTheCropOptionsAndKeepsTheFrame`, `aLockedSidePinsTheFrameDrag` — nine existing crop bodies updated, and the swap/Live-preview cases removed; `init()` resets the locks, the auto flags and the pending result), `i18n/kogaview_vi.ts` + `cpp/translations.cpp` (4 new sentences, 15 vanished entries removed), the harness reference, ADR 0011 revision | `just test` translations 332 strings / 106 C++ / 332 drawn / 4 by context, cargo 85 + 4, editor 58 (viewer 40 · browser 48 · cache 15 · state 7 · settings 17 · language 7 · toolbar 17); `just build` and `cargo fmt --check` clean; **real window** (window grabs, isolated `XDG_*`, Vietnamese): Crop open with no frame and empty fields (`M1-crop-unframed-vi.png`), a click creating the whole-picture frame with Apply disabled as `edit_noop` (`M1-crop-click-full-vi.png`), Width+Ratio locked with Height disabled and the frame at `bottom_right` 512 × 384 (`M1-crop-locks-vi.png`), Clear pressed on a framed, ratio-locked 512 × 341 rectangle (harness log `before clear` `frame true rect 344 230 512 341`) returning to the unframed state with X/Y `0`, the Width/Height fields empty (their placeholders show `1200`/`800`), the locks off and the ratio `3:2` kept (`M1-crop-clear-vi.png`), Reset keeping the frame exactly where it was (688,416) while ratio/anchor/mode/preset read their defaults (`M1-crop-reset-vi.png`), and Apply sending `editor_crop 512 384 688 416` (`ok:true` rev 4) with the document at 512 × 384 and a 0,0,512,384 frame on it (`M1-crop-applied-frame-vi.png`, footer rev 5). Mutations, each restored: seeding a frame on open, removing the auto-height follow, Clear keeping its fields, Reset clearing them, a lock surviving the settle, a locked Height being overwritten, `cropWidthEditable` ignoring a ratio lock, the locked-side drag branch removed, `cropResizable` losing its ratio clause, the third-lock rule removed from both its guards, Bilinear resampling swapped to Nearest, and the pad fill's alpha forced to 255 — all caught. Three equivalent/unreached mutations are recorded below. No hand touched the panel: every run drove the helpers and buttons the harness calls |
| 93 | The advertised formats and Core's decoders disagreed: `.avif` was listed everywhere but the Editor failed with `The image format Avif is not supported` (the `avif` feature is an encoder), `has_decoder` answered `true` from a guessed name, and `.jpe` was invisible in the Browser and, separately, in the fallback chooser | `crates/app-core/Cargo.toml` (`avif-native` beside `avif`), `CMakeLists.txt` (`PkgConfig::DAV1D`; the staticlib alone leaves `dav1d_*` undefined), `editor.rs` (`has_decoder` builds the decoder; `an_advertised_avif_is_really_decoded`, `a_file_with_no_decoder_is_reported_as_such`), `core.rs` (`editor_open` refuses before a worker with the translatable `no_decoder` line), `app-protocol`'s `jpe`, `ops.rs`, `cpp/platform.cpp` (the chooser's second list gains `.jpe`), `scripts/check_packaging.py` (compares the two spellings), `scripts/dev.py` (doctor's libdav1d line), `docs/BUILD.md`, ADR 0005 revision | `just test`: translations 332 / 106 C++ / 332 drawn, packaging 19 MIME, cargo **88 + 4**, all eight QML suites; `cargo fmt --check` clean; **real window** (this session's Wayland, isolated `XDG_*`, Vietnamese): AVIF opens in the Editor at 64 × 48 with the tools live (`M1-editor-avif-fixed.png`), the chooser filter logs `*.jpe` where it stopped at `*.jpeg`, `b.jpe` is listed with a thumbnail (`M1-browser-jpe.png`) and opens at 64 × 48 (`M1-editor-jpe-vi.png`), the folder reads 17 items · **16 images**, and a HEIC is refused with `ok:false` `no_decoder` and an unchanged revision in the journal, the toast reading `Không mở được …/a.heic: không có bộ giải mã cho định dạng này` (`M1-heic-rejected-vi.png`); 6 mutations caught, and the C++ link failure recorded before the CMake line was added |
| 94 | The Editor's left column was a 220 px text sidebar repeating the toolbar, and no size field could be read as a fraction of the picture | twelve SVGs in `crates/desktop/qml/icons/` registered by the new `crates/desktop/icons.qrc`; `ToolRailButton.qml` (34 px, icon-only, tooltip + accessible name) with its own `IconImage` content item because Breeze replaces a file icon with a generic document glyph, now wrapped so the 20 × 20 drawing (`iconDrawing`) keeps its own size instead of being stretched to the square; `UnitField.qml` (`px`/`%` beside the field in a `RowLayout`, `pixels()`/`setPixels`, `unitReference`, `inputField`/`nextField`/`previousField`, a forwarded `accepted`, `unitsVisible`, two decimals in the `C` locale); `EditorView.qml`'s rail (`toolColumns`, `toolRailWidth`, `editorToolGrid`, `editorEditGrid`, `toolRailColumns`, heading hidden at one column, left splitter removed), Crop's Width/Height with a selector and X/Y as pixel-only fields, the whole-picture 45 % dim with no frame (`cropShadeEmpty`), the button reading `Apply`, the Back button moved to the first toolbar slot, and a whole-pixel canvas position; `ResizeDialog.qml`'s two `UnitField`s with keyboard focus and Tab through `inputField`; `tst_editor`'s three cases plus `tst_toolbar`'s back-button order case; ADR 0018 (two revisions) and ADR 0011's no-frame note | `just test editor` 61 passed and `just test toolbar` 18; translations 334 strings / 106 C++ / 334 drawn / 4 by context after retiring `Apply crop (Enter)`; `just build` and `cargo fmt --check` clean; **real window** (Wayland, isolated `XDG_*`, dev commands, no hand): the 88 px two-column rail with all twelve drawings and, while Crop is armed frameless, the whole picture dimmed, X/Y bare, `px` beside Width/Height and the button reading `Apply` (`M1-editor-crop-unframed.png`), the same panel with a 512 × 384 frame kept bright (`M1-editor-tool-rail.png`), the Resize form's `px` pair beside its fields with the chain on (`M1-editor-resize-units.png`); two runs measured the same muted drawings (resize 14 × 16, transform 15 × 18, brush 19 × 18, eraser 15 × 16) before and after a tool click. The first grab was a column of identical document glyphs — that is how the Breeze behaviour was found; the first grab of the follow-up clipped `px` to one letter in a 42 px selector, which is why it is 56 px wide |
| 95 | The Editor's right column was one thing at a time: with the pointer it showed the document's identity, history and thumbnail, and arming Crop, Transform or Brush replaced all of that with the tool's fields — the reference disappeared exactly when a crop needed it, and the pointer column had no room for tool options | `PanelTabs.qml` (self-drawn strip, one button per tab, `editorTab_<key>`/`editorTabIcon_<key>`/`editorTabLabel_<key>`, labels folded under 240 px), `PanelDivider.qml` (scene-coordinate drag, clamped, double-click restores 440), four new SVGs, `EditorView.qml`'s two-zone inspector (`rightToolZoneHeight` 440 clamped to `header+40 … height-180`, `toolZoneFolded`, `rightTab`/`rightTabIndex`, `toolOptionsScroll`, a `GridLayout` action row whose `cropActionsStack` measures the three labels, the divider, the tabs, a `StackLayout` keeping `imageName`/`historyList`/`pointerThumbnail`), `onToolChanged` unfolding, `cpp/main.cpp`'s `editor-dock`, `tst_editor`'s `theInspectorSplitsToolsFromThreeReferenceTabs` plus `selectRightTab` and `scrollOptionsIntoView`, four Vietnamese sentences, ADR 0019 | `just test` 337 strings / 106 C++ / 337 drawn / 4 by context, cargo 88 + 4, editor **62** (viewer 40 · browser 48 · cache 15 · state 7 · settings 17 · language 7 · toolbar 18); `cargo fmt --check` clean; **real window** (Wayland, isolated `XDG_*`, `editor-dock`, no hand): Info with no tool zone (`M1-editor-dock-info.png`), Crop over History (`M1-editor-dock-history-crop.png`), Brush over Preview (`M1-editor-dock-preview.png`), the folded zone (`M1-editor-dock-folded.png`), the 260 px Vietnamese dock with `Bỏ khung` whole (`M1-editor-dock-vi-260.png`), and the 220 px dock with icon tabs and Apply on its own line (`M1-editor-dock-compact.png`) — the old three-column row squeezed the three 80 px buttons to 74.6 px at the default 236 px row, so the column count is measured; 9 mutations, each caught |
| 96 | The three workspaces had three different right-hand columns, the Viewer had none, and the Editor's `Preview` tab drew the working render rather than the file on disk | one `RightDock.qml` with an optional `PanelTabs` strip (`stripShown: tabs.length > 1`), the shared `InfoPanel`/`PreviewPanel`/`HistoryPanel` pages, a per-workspace `right_panel*` flag in `Config`/`UiState`/`toggle_right_panel`, one session `rightPanelWidth` in `Main.qml`, and `Original` drawing `editor.save_path` with `file_identity` (mtime, size) | `just test` green; real window: the six dock grabs of rows 95–97, the `Original` tab over `saved-one.png`, and the black frame it first drew when handed the cache instead of the `ThumbnailBook` (the binding and its test were fixed) |
| 97 | The Editor's tool zone was a fixed 440 px split with a divider, so Brush's 300 px of options left a hole and a long Crop column needed a scroll | the divider and `rightToolZoneHeight` removed, `toolOptionsScroll` inside `toolOptionsHost` (a `Layout.maximumHeight` on a `ScrollView` is ignored), `optionsCap = height - 180 - headerHeight - actionRowHeight - 10`, and the pinned action row measured by `cropActionsStack` | `just test` green; real window: `docs/evidence/M1-editor-crop-hug-vi.png` (fields at their own height, verbs directly under them); the 700 px short-window case is QML-only |
| 98 | No menu could show a picture's folder in the desktop's file manager | `PlatformHelper::revealInFolder`, `Main.qml`'s `revealPath`, the Browser's three menus and the Viewer's canvas menu, `Theme.menuEntryLabels[39]` | `just test` green; real window: the Vietnamese entry (`docs/evidence/M1-file-menu-reveal-vi.png`); no file manager was running then, so nothing was selected — row 101 later ran it against a real Dolphin |
| 99 | Resize silently cropped on an aspect change, a rounded ratio shaved a pixel, and `Pad` without a colour meant black | `ResizeMode { Stretch, Cover, Pad }` and `for_payload` in the protocol, `validate_resize_mode`, three render branches and the ≤ 1 px `cover_rect` snap in Core, the form's `Fit` row (background only for `pad`), the pad refusal line | `just test` green (cargo 98 + 5, editor 69); real window: `Fit: Stretch to size` with no background row, and 600 × 800 stretches all six stripes (`resize 600 800`, rev 4) while `Cover` cuts the ends (`resize cover 600 800`), `docs/evidence/M1-resize-fit-stretch.png`, `-stretch-applied.png`, `-cover-applied.png`; 2 mutations caught |
| 100 | The reference pages could not be folded away and the tool options could not be given more room | `PanelSplitter.orientation`, `PanelTabs`'s chevron (`folded`/`foldRequested`), `RightDock`'s `folded`/`stripHeight`, `EditorView`'s `referenceFolded`/`toolZoneHeight` and its vertical divider | real window: the fold leaves only the strip with the options filling the dock (`docs/evidence/M1-dock-folded.png`), a 320 px divider measured at scene y 370 with the strip at 385 (`-dock-divider-320.png`); 3 mutations caught |
| 101 | `Show in folder` was gated on the file manager already running, which a D-Bus-activated desktop never satisfies before the first click | `revealInFolder` sends the call with a 5 s timeout and lets the bus activate the service; a missing path is answered with a line; sandbox skip kept; each branch logs | in a fresh `dbus-run-session` the call activated `/usr/bin/dolphin --new-window --select /tmp/opencode/ws5/pics/wide.png` (pid 185577); on this session Dolphin already owned the name, so the old gate happened to be true here — which is why the bug was invisible |
| 102 | The Viewer never re-read a file it had already shown, and the Editor tore its document down when asked for the same path | `viewer_modified`/`viewer_size` + `set_viewer_path`, the Viewer's `?v=` source, `open_editor`'s four-way guard (`editor_already_open`, reload-on-rewrite, `unsaved_document`), `Main.qml`'s `requestEditorOpen` queue | real window: a red 800 × 600 file rewritten to blue 640 × 480 was redrawn at 640 × 480 after a second `open_file` (`M1-viewer-before-rewrite.png` / `-rewritten.png`), and a rotated document kept its `Rotate right 90°` history across a second `editor_open` (`M1-editor-reopen-same.png`, `-history.png`, rev 6); 4 mutations caught |
| 103 | "Explore here" duplicated Open folder and Show in folder without doing either reliably | the label dropped from `Theme.menuEntryLabels` and every menu entry at index ≥ 10 renumbered; the vanished string removed | `tst_browser::theFolderMenusDoNotRepeatTheOpenAction`; `just test` green |

## Test gate

`PATH=/usr/lib/qt6/bin:$PATH just test` — exit 0 (`lrelease` is the system Qt 6
one now; `/tmp/opencode/lrel` no longer exists):

```
translations: 353 strings in kogaview_vi.ts, 105 of them compiled into C++, 353 drawn by the QML, 4 looked up by context
packaging: 19 MIME types, 3 categories, icon and metainfo named io.github.tienv2i.KogaView
cargo: 98 passed (kogaview-core) + 5 passed (kogaview-protocol)
viewer 43 · browser 51 · cache 15 · state 7 · settings 19 · editor 69 · language 7 · toolbar 18
```

`cargo fmt --check` clean. `cargo clippy -p kogaview-protocol -p kogaview-core --all-targets`
still reports the two pre-existing `derivable_impls` warnings in
`crates/app-protocol/src/lib.rs` (`impl Default for Workspace`/`Theme`, lines 53 and 135) and
the pre-existing core warnings (`too_many_arguments`, `while_let_loop`, `sort_by_key`,
`field_reassign_with_default`, `needless_return`); rows 91 and 92 add no new warning (the
protocol's `Anchor` and the anchored Core helpers are still gone).

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

## Design decisions, crop completion (row 90, ADR 0011 revision)

- **Crop starts free.** A crop tool with no constraint should keep the shape the
  user draws; picking a ratio is the lock. Resize's dialog keeps `original`,
  because a scale usually keeps the shape. The default is asserted in
  `initTestCase` before `init()` writes any per-case state, so the QML
  declaration itself is the thing under test.
- **The frame exists when the tool does.** `seedCropFrame` fits the chosen ratio
  at 80 % of the picture and writes the same four fields the command is built
  from. It never overwrites a typed rectangle unless Reset forces it. Reset is
  the starting frame, not an empty form.
- **A size change waits one turn and then refits.** A state publish changes width
  and height in one write but QML emits one signal at a time; seeding from the
  width change fitted the frame to the previous height. `cropSeedDebounce` (0 ms)
  runs `refitCropAfterDocumentChange()` after both bindings settle. It re-seeds
  an empty or no-longer-fitting rectangle and leaves a fitting one alone; the QML
  case measures both directions on a rectangle whose partial seed *would* have
  fitted, so it can tell the difference.
- **A ratio is a lock on the canvas too.** A corner drag pins the opposite
  corner and fits the pointer box to the ratio; a side drag pins the opposite
  side and grows the other axis around the rectangle's centre. A create-drag is
  fitted before clamping, so a square drag draws a square. The `free` path is
  row 82's code unchanged.
- **The frame is also the composition aid.** Four shade rectangles dim the
  picture outside the frame, computed from the same document rectangle the frame
  and the command read, and four thirds lines sit inside it. Both vanish with
  the frame while a live draft is on the canvas, because a draft is the result.
- **Swap is a turn, not a retype.** `swapCropOrientation` rotates through 90°
  around the rectangle's centre, keeps it inside the document, maps a named
  ratio to its counterpart (4:3 ↔ 3:4, 16:9 ↔ 9:16, 1:1 → 1:1) and turns any
  other shape into `current`. It sends nothing until Apply.
- **The keyboard belongs to the armed tool, not the window.** Arrows nudge,
  Shift steps 10 px, Alt resizes around the centre and derives the linked side,
  Enter applies, Escape returns to Pointer. The handler is on the view, so a
  focused field still consumes the keys first; palette buttons stay
  `NoFocus`.
- **Apply refuses Core's no-op.** A rectangle equal to the document is
  `edit_noop`, so `cropCanApply()` requires a valid *and* changed rectangle.
  `applyCrop()` puts the form down before the command; the debounce then seeds
  the cropped result's fresh frame.
- **No new protocol or Core code at the time.** A crop was still
  `{x, y, width, height}`; the ratio, guides, shade, swap and keyboard all wrote
  those four numbers. Row 91's Grow mode later signed the same command's `x`/`y`
  and gave it an optional fill, so this describes row 90, not the tree today.

## Design decisions, scale form and a growing crop (row 91, ADR 0012 and ADR 0011 revisions)

- **The chain replaces the ratio table.** Resize has one lock, like a scale
  dialog: switching it on captures the pair currently in the fields (or the
  document when a field is empty), switching it off leaves the two sides
  independent, and a preset becomes the locked shape. The Ratio combo and the
  +/- steppers are gone; `Size preset` stays because a concrete size is a
  faster answer than two numbers.
- **Background is a description, not an option to reveal.** `None` is the
  existing centred cover crop, any colour scales the whole picture to fit and
  pads the leftover with it, and `Transparent` is that same pad at alpha 0.
  Because it is always on screen, the old `Pad to fit` checkbox and its hidden
  colour row have no job; `fill_alpha` on the command is what lets
  `Transparent` be a colour with alpha 0 rather than a special mode.
- **The filter is real pixels.** `ResizeFilter` travels in `editor_resize` and
  becomes an `image` kernel in Core. `Auto` keeps the fast `thumbnail` path on a
  downscale and Lanczos3 when enlarging, so the default does not regress the
  large-JPEG path row 79 measured. A filter that changed only its label would
  have been a menu, not a control.
- **The chain is drawn on a Canvas.** An emoji link glyph was blank in this
  session's font and a themed `Icon` would depend on the desktop's icon set, so
  two capsule outlines on a diagonal are painted in the theme's colours; the
  accent is the "locked" state. This is also why the first version of the
  control looked empty.
- **Keyboard: the form is reachable without a pointer.** `Ctrl+Alt+I` opens it
  from the Editor (gated by the shell's modal state), Width receives focus with
  its number selected, `Tab` moves to Height, and Enter in either field applies.
  `focusPending` keeps retrying until the field really owns the keyboard,
  because `forceActiveFocus` before the popup is visible does nothing.
- **Crop's fill is its mode.** `center` keeps the row-90 inside-only rule;
  `grow` allows a negative origin and a rectangle past the right/bottom edges,
  and the command carries `fill` + `fill_alpha`. A present fill means Core may
  create the larger canvas; an absent one keeps the ordinary cut, which is why
  a Grow rectangle that still lies inside the picture travels as a normal crop.
  Core still refuses a rectangle that misses the picture entirely
  (`crop_outside_document`) and a growth past `MAX_DOCUMENT_PIXELS`
  (`crop_too_large`), so Grow is a border, never a blank coloured page.
- **Grow has to be visible before Apply.** The canvas paints the part of the
  frame outside the picture in the chosen fill, so the border is a preview, not
  a surprise. Choosing Grow also steps the fitted view back once
  (`revealCropGrowth`) when the fit leaves less than 12 % margin, because the
  canvas host clips at its edge and there would be nowhere to drag the frame
  outward; a view with enough room is left alone.
- **The four fields stay the one rectangle.** Grow relaxes the same typed
  fields, the same eight handles and the same drag code; typing `-336`/`-224`
  and dragging a handle write the same numbers. Switching back to Center pulls
  the rectangle into the picture again, so Apply is never armed for a rectangle
  Core would reject.
- **Core's grow is a copy, then a fill.** `grow_crop` allocates the requested
  canvas, paints it with the fill at the requested alpha, and copies the
  intersection of the picture and the rectangle into its place. That is why a
  grow is a snapshot for undo, and why its history line says
  `Grow to W × H · #rrggbb border` (or `transparent border`).

## Design decisions, crop rework (row 92, ADR 0011 revision)

- **The frame is the user's answer, so Crop opens without one.** The old tool
  seeded a rectangle the moment it was armed, which meant the first thing the
  user saw was a guess and Apply could be one click from cutting a picture they
  had not framed. `enterCropTool()` now clears the four fields, releases the
  locks and does nothing else; a drag, a click (the whole picture), a typed
  side, a preset or an anchor is what builds a rectangle. Keeping an existing
  frame across a tool switch would also be wrong: the options survive, the
  answer does not.
- **Width, Height and Ratio are three inputs with locks, and one is derived.**
  The locks replaced a ratio dropdown plus a `Keep current ratio` item because
  the question the panel is really asking is "which two numbers do I choose, and
  what follows?". Width+Height fixes the shape (the ratio text is disabled and
  follows the pair); Width+Ratio derives Height; Height+Ratio derives Width. A
  third lock is refused, and the button snaps back, because a state with three
  inputs would have nothing to derive.
- **The padlocks are drawn, not icon-font glyphs.** The first version used the
  style's indicator and the second an emoji, which was blank in this session's
  font; a themed icon would make the control depend on the desktop's icon set.
  `CropLockButton` paints a two-part padlock in a `Canvas`, white on the accent
  when checked and grey when not, so the checked state is legible on the dark
  window without a theme lookup. The first grab showed an accent lock on an
  accent chip — a blue square — which is why the checked glyph is white.
- **Ratio is text because a ratio is a pair, not a menu.** `3:2`, `3/2`, `3x2`
  and a bare `2` parse, the display reduces by its gcd (a 1024 × 768 preset shows
  `4:3`), and an empty field is `Free`. A ratio typed into an empty panel does
  not invent a frame; the next typed side uses it.
- **The auto-follow flags exist because typing is incremental.** Without them,
  typing `800` into an empty Width set Height on the first keystroke (`8 × 6`)
  and then refused to move it, because `6` was now "a height the user typed".
  `cropHeightAuto`/`cropWidthAuto` say "this side has only ever followed", so
  the rest of the number keeps deriving it; typing that side ends the follow.
  A drag, a click, a preset, a ratio and Clear reset both flags.
- **A locked side is a lock on the canvas.** The drag code already had a branch
  that pinned a locked axis; the panel's locks are now the only source of that
  rule, and `cropResizable` is false once two values are pinned, so the handles
  do nothing while the inside of the frame still moves it. The pointer must not
  be able to change a value the panel says cannot change.
- **Reset is about the panel; Clear is about the frame.** Reset restores every
  option to its default (unlocked, free, Center, transparent, Custom, Center)
  and leaves the rectangle exactly where it is. Clear empties the fields,
  releases the locks and puts the frame down, but keeps the chosen mode, colour,
  ratio and anchor — the two verbs a user expects from "Reset" and "Clear".
- **Apply frames the result.** The document Core publishes after a cut has the
  rectangle's own size; `pendingCropResult` compares that against the published
  size and `settleAppliedCrop` releases the locks and writes a 0,0,W,H frame
  over the whole result. A document change that is not the pending cut keeps the
  existing clamp/refit rule instead of pretending the user made a new crop.
- **The crop live draft is gone from the window.** `editor_crop_preview` remains
  a protocol/Core command with its tests, but no QML emits it and the row, the
  toggle, the hint labels and `swapCropOrientation` are removed; Transform keeps
  its own draft and its own hint, which is the only place a live preview still
  answers a question the typed fields cannot.

## Design decisions, resize-dialog session (rows 83, ADR 0012 and 0013)

- **A size is a question, not a mode.** `ResizeDialog.qml` owns the form, its
  fields, its preset list and — since row 91 — its chain, background and filter,
  and resets them from the document every time it opens. The palette's `Resize…`
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
  shows the document. The concept the row-83 form had (draft inside the form)
  is gone entirely; row 91 then removed the ratio list and the pad too. The
  form is two numbers, a chain, a preset, a background and a filter; the
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

Crop completion (row 90): dropping the ratio from `dragCropHandle`'s aspect path
→ `theCropRatioLocksTheFrameDrag` fails (`cropHeight` 200, expected 260 after the
side drag); giving `cropShadeTop` a zero height → `theCropFrameDrawsItsGuidesAndShade`
fails (0, expected 30); reversing the Left arrow's nudge → `theCropKeysNudgeResizeAndApply`
fails (`width` 201, expected 199); making `swapCropOrientation` keep W and H →
`theCropOrientationSwapsTheRectangle` fails (`cropWidth` 200, expected 100);
removing the seed from `onToolChanged` → `theCropFrameIsDrawnAndDragged` fails
with "frame->isVisible() returned FALSE"; inverting the Enter guard → the key
case fails with 0 commands instead of 1. Reverting the declared default to
`"original"` → `initTestCase` fails (`cropRatio` "original", expected "free").
Replacing the zero-turn `cropSeedDebounce` with a direct
`refitCropAfterDocumentChange()` in both size handlers → `theAppliedCropLeavesAFreshFrame`
fails (`cropHeight` 512, expected 480: the width change had fitted the frame to
the previous height and the partial 640 × 512 still fitted the new 800 × 600,
so the second change did not correct it). Dropping `cropChanged()` from
`cropCanApply()` → the same case fails because Apply is armed for the whole
document. Forcing the refit to re-seed a rectangle that still fits →
`theCropFrameRefitsAfterADocumentChange` fails (`cropWidth` 640 after a grow,
expected 160); refusing the refit entirely → the same case fails with 300 (the
shrink left the old rectangle). Each restored, then the suite green. One
reordering is recorded as **equivalent**: moving `clearCropFields()` back after
`view.command()` in `applyCrop()` leaves the suite green, because the zero-turn
seed sees the cleared fields either way; the order before the command is kept
for clarity, and is not claimed to fix anything.

Crop rework (row 92): seeding a frame in `enterCropTool()` →
`cropStartsWithNoFrameAndClickBuildsOne` fails (`800 × 600` where an empty field
was expected); removing the `cropHeightAuto` follow from `linkHeightFromWidth` →
`theCropFieldsCreateTheFrame` fails with Height `6` instead of `600`; Clear
keeping its fields → the same case fails with Width `800` where the field should
be empty; Reset clearing them → `resetRestoresTheCropOptionsAndKeepsTheFrame`
fails on the frame it was supposed to keep; a lock surviving the settle →
`theAppliedCropLeavesAFreshFrame` fails with "a lock survived the rectangle it
described"; a locked Height overwritten by a typed Width → the lock case fails
with Height `188` instead of `300`; `cropWidthEditable` ignoring the ratio lock
→ the same case fails because Width is still an input; the locked-side branch
removed from `dragCropHandle` → `aLockedSidePinsTheFrameDrag` fails with Height
`190`; `cropResizable` losing its ratio clause → the lock case fails with
"Width+Ratio still let a handle reshape the frame". Each restored, then the
suite green. Three are recorded as **equivalent or unreached**, not as passes:
`settleAppliedCrop`'s `setCropRect` can be removed because the document-change
refit already pulls an offset rectangle into the result (the result is exactly
the rectangle's size, so the old x/y can never fit); the per-branch third-lock
guard and the W+H "ratio becomes a consequence" line each enforce the same rule,
so removing either alone changes nothing — removing both fails the lock case; and
the `applyCropRatio` locked-side branch is not reached by that case at all.
Resize filters, which row 91 added without mutation checks, were run here:
Bilinear resampling swapped to Nearest → `the_resize_filter_changes_the_pixels`
fails on the interpolated sample; `fit_with_padding`'s fill alpha forced to 255 →
`resize_can_leave_the_leftover_transparent` fails (`Rgba([255,0,0,255])` where
alpha 0 was written). Both restored.

Rail and units (row 94): deleting `ToolRailButton`'s `contentItem: IconImage`
→ `theToolRailIsAnIconColumn` fails with `contentItem.source` `""` against
`icons/pointer.svg`, which is the state in which the style puts its own generic
glyph in every square; making `setPixels` write whole-number percentages
(`* 100` instead of `* 10000 / 100`) → `theUnitsAreAnotherSpellingOfTheSamePixels`
fails with `0` where `0.03` was expected — that px → % → px step **was added
after the mutation first escaped**, so the two-decimal rule is now guarded
rather than assumed; making `onUnitChanged` write `String(lastPixels)` instead of
`setPixels(lastPixels)` → `theResizeFormTakesPercentagesToo` fails with `4000`
where `100` was expected. Each restored, then the suite green. Note for the next
session: a **QML-only** edit needs no rebuild (`tests/qml` loads the sources from
disk) but a **test-source** edit does, and the first two runs of these mutations
used a binary that still had the old assertions — a stale test binary passes.

Rail and units follow-up (row 94, same day): removing `unitsVisible: false` from
Crop's X → `theUnitsAreAnotherSpellingOfTheSamePixels` fails with "`!expectItem
("cropXUnit")->isVisible()` returned FALSE"; making the no-frame dim
`visible: false` → `theCropFrameDrawsItsGuidesAndShade` fails on
`cropShadeEmpty`; setting `ToolRailButton.iconSize` to 30 → the rail case fails
with `iconDrawing.width` 30 against 20, which is the property the wrapper was
introduced for; putting `Apply crop (Enter)` back as the button's text →
`just test translations` names the QML string that is no longer in
`kogaview_vi.ts`; moving the Editor's Back button after Open (source only, no
rebuild) → `theBackButtonLeadsEveryWorkspaceToolbar` fails with "EditorView.qml's
first toolbar button is not the back button". Each restored, then `just test
editor` 61, `just test toolbar` 18 and the translations gate green.

Split dock (row 95), every one run against
`kogaview_editor_tests theInspectorSplitsToolsFromThreeReferenceTabs` and then
restored: dropping `&& !view.toolZoneFolded` from the pinned action row's
`visible` → the case fails at `zone->height() <= 40` while folded (the row kept
69 px under the heading); hardcoding `currentIndex: 0` in the pages'
`StackLayout` → `historyPanel` is not visible after its tab is chosen; making
the divider's `onMoved` a no-op → "the divider did not move the split: 440 ->
440"; passing `compact: false` to `PanelTabs` → the history label is still
drawn at 220 px; removing the `toolZoneFolded = false` from `onToolChanged` →
arming Brush while folded leaves `toolOptionsScroll` invisible; letting the
pointer have options (`toolOptionsShown` without the `tool !== "pointer"` term)
→ the opening assertion that the pointer has no options zone fails; and the
action row back to three cells at 220 px (`columns: 3`, `columnSpan: 1`) →
"applyCrop is 61 px wide but needs 80", which is the measured sliver this grid
replaced; with the measured rule in place, `cropActionsStack: false` → the same
"applyCrop is 61 px wide but needs 80" message, and `tabsCompact: width < 120` →
the history label is still visible at 220 px. After each restore the case
passed again, and the whole suite was run green afterwards.

One right dock (rows 96–98), each re-run against its own case and then restored:
`stripShown: tabs.length > 0` in place of `> 1` → `theSidebarIsOneInformationPage`
(viewer) and `theSidebarIsOnePreviewPage` (browser) fail, because the one-page
dock grows a strip that switches to itself; removing `toolOptionsHost` and
leaving the `ScrollView` to answer the layout → `theReferenceZoneKeepsRoomWhenTheWindowIsShort`
fails with the tabs pushed under the short window's fold; pointing the Original
page at `editor.previewPath` instead of `editor.savePath` → `theOriginalTabShowsTheSavedFile`
fails on the preview file's name; binding one view's splitter to a local width
instead of `root.rightPanelWidth` → the settings guard fails with "the shared
width reaches 2 views, expected 3"; calling `Platform.openExternal` where the
menus should reveal → `theShellSharesOneDockWidthAndRevealsThroughThePlatform`
fails on the reveal call; stubbing `file_identity` to `(0, 0)` → the Core
identity test fails because a save over the same path does not change the
number; making `toggle_right_panel` ignore the explicit `workspace` →
`a_right_panel_toggle_belongs_to_its_workspace` fails with the other two flags
written. The black-frame bug was mutated last: `book: thumbs` back to `book:
view.thumbnails` fails `theOriginalTabShowsTheSavedFile` with `edge 0`, which is
the defect exactly. Each restored, then `just test` green.

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

## Design decisions, tool-rail session (row 94, ADR 0018)

- **The rail is a view, not a setting.** `toolColumns` is a QML property; folding
  to one column sends no command and writes no configuration, so a rail width
  cannot drift between the core, the settings file and the window. The price is
  that the fold is forgotten on the next launch, which is stated rather than
  hidden.
- **The left splitter is gone, not merely unused.** The rail's own control is
  its width; keeping a drag handle would recreate the column this change
  removed. The right inspector keeps its splitter and `rightPanelWidth`.
- **Twelve drawings, one tint.** The SVGs are single-colour so
  `AbstractButton.icon.color`'s four states (muted, hover, accent, 40 % for
  disabled) are a colour write rather than four files each. They live next to
  the QML and are registered by `icons.qrc` at the module's own resource prefix,
  because that is the one path both the built module and the QML suites resolve.
- **The button draws its icon because the style will not.** Measured on this
  desktop: Basic draws a `icon.source` file, Breeze shows a generic document
  glyph for it. `ToolRailButton` therefore sets a `contentItem` holding an
  `IconImage` (the styles' own renderer, which keeps the SVG alpha and takes
  `color`), and the drawing keeps its own 20 × 20 size inside that wrapper:
  `AbstractButton` sizes the content item to the control, so an `IconImage`
  declared *as* the content item was re-laid at run time — icons looked one size
  when the Editor opened and another after the first click. `icon.source` stays
  set, because that is the intent the suites read; the suite compares
  `iconDrawing.width`, not the content item's own width.
- **The unit selector is beside the field, not inside it.** A child cannot be
  drawn outside a `TextField`, so the old inline `ComboBox` ate into the number's
  width, had no room for its own height, and at 42 px elided `px` to one clipped
  letter. `UnitField` is a `RowLayout` now: the `TextField` fills, the selector
  is a 56 px control 4 px to its right and as tall as it, with a tooltip and an
  accessible name. `inputField` names the text control, because a layout cannot
  take the keyboard; the Resize dialog focuses it, Tab walks `nextField`/
  `previousField` to it, and `accepted` is re-emitted so Enter still applies.
- **A place has no unit.** X and Y keep the component but hide the selector:
  a fraction of the picture is a size, not a position, and the protocol never
  carried a unit for a coordinate.
- **A unit is a spelling.** `pixels()` is the authority and `%` is
  `value / 100 · unitReference`; the field keeps `lastPixels` so px → % → px
  returns the number the user had instead of a rounded one. Nothing new crosses
  the protocol, and Apply still sends integers.
- **Nothing chosen dims the whole picture.** With no crop rectangle the old
  overlay drew nothing, so an armed Crop looked like a bright picture and the
  only cue was an empty form. One full-picture 45 % rectangle now covers it while
  `cropFrameShown` is false, and the four edge strips take over as soon as a
  rectangle exists, so "nothing selected" and "this part is kept" are different
  pictures.
- **The crop button says what it does.** `Apply crop (Enter)` was a sentence in
  a row of one-word verbs; it is `Apply` now, the same word the Resize and
  Settings forms use. Enter still applies the frame — the Crop tool's key
  handler owns `Qt.Key_Return`/`Qt.Key_Enter` — but the label no longer doubles
  as its key hint.
- **Back leads every picture workspace.** The Editor's Back button sat after a
  document-dependent number of buttons; it now occupies the Viewer's first slot,
  before the separator that starts the workspace's own actions, so the one
  control both workspaces share does not move. `tst_toolbar` reads the real
  toolbar sources and asserts that first block is the `go-previous-symbolic`
  button that sends `set_workspace`.
- **A unit change must not look like typing.** `onUnitChanged` writes `text`
  directly, which does not emit `textEdited`; the ratio link, the auto-follow
  flags and the presets only listen to typing, so re-spelling a rectangle cannot
  arm Apply or lock a side. The two new cases assert both the text and the
  command.
- **`pixels()` is a function because `textEdited` leads `text`.** A property
  bound to `text` is one keystroke behind inside the handler that reacts to the
  keypress, which is why the pre-existing code read `parseInt(text)` inline.
- **The canvas sits on whole pixels.** `canvas.x`/`y` are rounded after the
  centring arithmetic: at 100 % a document coordinate must map to the pixel under
  the pointer. A centred picture at an odd host width sat at `.5`, and a crop
  dragged from document pixel 10 started at 11 — the rail's width change flipped
  the parity and surfaced it.

## Design decisions, split dock (row 95, ADR 0019)

- **The options belong to the tool; the reference belongs to the document.** One
  column, two zones: `editorToolZone` above `editorRightDivider` above the tab
  strip and its `StackLayout`. The pointer has no options, so its zone is the
  34 px heading alone and the tabs take the dock; arming a tool opens its
  options and leaves the chosen tab open underneath.
- **The split is view state, clamped so the tabs cannot disappear.**
  `rightToolZoneHeight` (default 440) is bounded by `header + 40` and
  `height - 180`; the divider writes it through `moved`, and a double-click
  restores 440. Nothing about it reaches Core — a drag leaves no journal line,
  which is the expected evidence, not a missing command.
- **The zone is fixed, so a short tool leaves space.** Brush's options stop
  around 300 px and the rest of a 440 px zone is empty. A split that shrank to
  each tool's content would move the tabs under the pointer on every tool
  switch; the divider is how a user says "less options, more history".
- **Folding hides the verbs too.** The pinned Apply/Reset/Clear row is part of
  the tool zone, so a fold leaves the heading alone. Folding is a deliberate
  request for the tabs' room and the chevron is the way back; a 69 px row under
  a 34 px heading would have been a fold that saves nothing.
- **Arming a tool unfolds.** `onToolChanged` clears `toolZoneFolded` for a
  non-pointer tool: the fold is about the visit, not a setting that would hide
  the next tool's fields. The heading, the options and the divider come back in
  one turn (`theInspectorSplitsToolsFromThreeReferenceTabs` arms Brush while
  folded).
- **The tab strip is self-drawn.** `PanelTabs.qml` exists because the platform
  `TabBar` paints its own light strip inside this forced-dark window and because
  each tab needs a stable `objectName` for the suite; the labels and icons come
  from `rightTabEntries`, so the component owns no translated string. Under
  240 px the labels give way to the drawing, its tooltip and its
  `Accessible.name`.
- **The action row measures the words it has.** The style gives a `Button` an
  80 px minimum, so three verbs plus two 6 px gaps need 252 px and do not fit
  the default 260 px dock (236 px of row) in either language; the row that
  pretended otherwise squeezed them to 74.6 px at the default row (61 px at
  220 px), which is why the labels elided: `Bỏ khu…` at 260 px in Vietnamese.
  `cropActionsStack` on the view compares the row's width with the sum of the
  three `implicitWidth`s, so Apply spans both columns and Reset/Clear take the
  next line exactly when the translated words need it; Transform has two verbs
  and stays two-up. The rule lives on the *view* because a `Layout.columnSpan`
  binding on a child cannot see a property declared on its parent `GridLayout`:
  the first version declared `stacks` on the grid, and while `columns` read 2
  the span stayed 1 and Apply shared a row with Reset. The case asserts each
  button's width against its own `implicitWidth`, that Apply is on a different
  line at 220 and the same line at 340, and the two anchor cases scroll the
  options column to reach the pad at the 700 px test host, where the wrapped
  row puts it under the fold.
- **Existing names stayed put.** `imageName`, `imageSize`, `saveTarget`,
  `historyList`, `pointerThumbnail` and `previewCaption` keep their object names
  inside the tabs, so the harness, the thumbnail identity plumbing and the
  pointer cases moved rather than being rewritten. The cases that asserted
  "a tool hides the document" were rewritten, because hiding it is the defect.

## Design decisions, one right dock (rows 96–98, ADR 0020)

- **A dock is a surface, not a workspace.** `RightDock.qml` owns the panel
  background, an optional `PanelTabs` strip and a `StackLayout`; the pages are
  passed as its default property (`default property alias pages: stack.data`),
  so a view lists them in order and the component draws no sentence of its own.
  The pages themselves are shared: `InfoPanel`, `PreviewPanel` and
  `HistoryPanel` are the same QML in every workspace that shows them, which is
  why their translations moved to their own contexts and `lupdate` had to be
  re-run before the window could speak Vietnamese in them.
- **A strip is drawn only for two or more panels.** `stripShown` is
  `tabs.length > 1`. An invisible strip in a `ColumnLayout` takes no height, so
  the Browser's and the Viewer's one-page docks start at their first page
  instead of leaving an empty 34 px band. The alternative — always drawing the
  strip so the dock looks the same everywhere — would have made a one-item tab
  row that switches to itself.
- **The Browser's one page is two panels.** Its preview and its metadata answer
  different questions but are read together, so they are stacked inside the
  single page rather than being two tabs. The Viewer's page is `InfoPanel`
  alone; the Editor's reference pages are `Info`, `History` and `Original`.
- **Visibility is per workspace and lives in Core.** `toggle_right_panel` takes
  an optional `workspace`; absent means the one on screen, which is what an
  older payload means and what the toolbar toggle sends. The three flags are
  separate because a narrow Viewer may want its details while the Browser's
  preview stays shut, and the Editor's dock is the tool options. `Config` keeps
  the historical `right_panel` for the Browser and adds `right_panel_viewer` /
  `right_panel_editor` (both default `true`); `UiState` mirrors all three, so a
  config written before this change opens with both new panels visible.
- **The width is one session value, clamped by each view.** `Main.qml` owns
  `rightPanelWidth` (seeded from `appTheme.previewWidth`), every view binds to
  it, and a splitter drag emits `panelWidthRequested` back to the shell. Each
  view draws its own `dockWidth` clamp, so the Browser's 200–640 range cannot
  be violated by a width the Editor set. Nothing about a drag reaches Core or
  `config.json`, because a splitter is presentation state — the opposite of
  visibility, which is a domain answer.
- **`Original` is the file, not the render.** The Editor's third tab used to
  draw `editor.previewPath` (Core's working preview) under the name `Preview`.
  It now draws `editor.savePath` — the source until the first Save/Save As — so
  "what is on disk?" has an answer. `file_identity(path)` returns
  `(mtime ms, byte size)` and Core publishes it as `fileModified` /
  `fileSize` on open, on every state publish and after every save; the shared
  `ThumbnailBook` keys its requests on exactly those values, so saving over the
  same path with new bytes is a new picture, not a cached old one.
- **The page needs a `ThumbnailBook`, not the cache.** The first working
  version passed `view.thumbnails` (the `ThumbnailCache`) into the page's
  `book`, so `book.edgeFor` was undefined, the `TypeError` left `edge` at 0,
  the cache was never asked and the frame drew black. The page now takes
  `thumbs` (the `ThumbnailBook`, as the Browser's preview does) and the suite
  asserts the request's `edge >= 160` as well as its path, so a black frame
  with a correct caption cannot pass again.
- **The tool zone hugs its options.** The divider and `rightToolZoneHeight`
  are gone; `toolOptionsScroll` sits in a plain `Item` (`toolOptionsHost`) whose
  `Layout.preferredHeight` is `min(content implicitHeight + 10, optionsCap)`.
  The wrapper exists because a `Layout.maximumHeight` on a `ScrollView` is
  ignored — it answers the layout with its content height, which is how a 430 px
  window drew a 362 px scroll view and pushed the tabs out. `optionsCap` is
  `max(40, height - 180 - headerHeight - actionRowHeight - 10)`, so only a window
  that cannot keep 180 px of reference makes the options scroll.
- **The heading always says whose options they are.** `%1 options` with the tool
  name, including `Pointer options`; the pointer shows one muted sentence,
  `This tool has no options.`, and no action row. Brush and Eraser have options
  and no verbs; Crop has Apply/Reset/Clear and Transform Apply/Reset, directly
  under the fields with no pinned gap between them.
- **Resize is a dialog and leaves the pointer armed.** `openResizeDialog()`
  writes `tool = "pointer"` before `open()`. The form is modal and owns its
  fields; leaving Crop armed behind it made the tool zone contradict the dialog
  and could leave Apply armed on a rectangle nobody framed. The window grab for
  row 96 is that state: form up, Resize button lit, `tool` logged as `pointer`.
- **"Show in folder" is a platform request, not a command.** The two view menus
  emit `revealPath(path)`; `Main.qml` calls
  `PlatformHelper::revealInFolder`. The order is measured by the helper, not by
  QML: outside a sandbox with `org.freedesktop.FileManager1` on the bus it calls
  `ShowItems` (file) or `ShowFolders` (folder), which selects the path in the
  file manager the user already has; otherwise the portal's `OpenURI` on the
  containing folder; otherwise `QDesktopServices::openUrl`; a refusal reaches
  the existing `dialogError`. Inside a Flatpak (`/.flatpak-info` present) the
  direct bus call is skipped, because the host service is not reachable from the
  sandbox. Nothing about it changes domain state, so there is no journal line to
  look for — the menu is the evidence.
- **The three labels are appended, not inserted.** `Theme.menuEntryLabels` is
  addressed by number from the three views; `Show in folder` is 39,
  `Toggle information panel` 40 and `Toggle tool and reference panel` 41, so no
  existing index moved. The new toggles are `visible: !miniToolbar` and are
  mirrored in each overflow menu, which keeps the 580 px floor and the mini
  counts unchanged (Viewer 13, Editor 14).

## Design decisions, resize modes, a foldable dock and reopening (rows 99–103)

- **A resize mode is named, not inferred, unless the payload is old.** `Stretch`,
  `Cover` and `Pad` travel as `editor_resize`'s `mode`. `ResizeMode::for_payload`
  keeps a replayable meaning for a payload that has none — a `fill` was `Pad`,
  no fill was `Cover` — so an old journal still crops what it cropped. A payload
  from this build always names its mode, and the enum's own default is `Stretch`:
  losing edges must be asked for, not inherited.
- **Stretch is the default because the old default threw pixels away.** With the
  chain locked, a 1200 × 800 picture asked for 600 × 800 used to lose its left and
  right quarters without a word. The three answers now sit in one `Fit` row above
  the filter, and `Background` is drawn only for `Pad`, because a colour is only
  meaningful when something is left to fill.
- **The one-pixel snap is about rounding, not about content.** `cover_rect` is the
  centred cover rectangle; when it would lose no more than one pixel on each axis
  it returns the whole frame instead, because a 3:2 lock whose target rounded by
  a pixel used to shave a strip off two sides for nothing.
- **`Pad` without a colour is refused.** `resize_pad_needs_colour` is a line the
  window can draw; painting black by default was the alternative and it looked
  like a result.
- **The fold and the split are two objects because they answer two questions.**
  `PanelTabs`'s chevron puts the pages away and leaves the 34 px strip at the
  bottom (the three tabs stay visible and switchable); `PanelSplitter` with
  `orientation: Qt.Vertical` divides options from reference while both are open.
  Neither sends a command: a drag or a fold is presentation state, and the
  journal stays silent, which is the expected evidence.
- **The fold gives its height to the options.** `referenceFolded` is a layout
  input, not a cosmetic hide: the options host takes the height the pages gave
  up, so folding is a way to see more of a long form, not a way to leave a hole.
  The QML case fails if the host is left to the layout's own preference.
- **The test asserts the drawn height, not the property.** `toolZoneHeight` is
  what the divider writes, but the zone had to prove it is drawn there: the case
  writes 300 and compares `zone->height()`. The window run measured the same
  thing in scene coordinates (zone top 50, height 320, divider 370, strip 385),
  which is what corrected an earlier reading of the grab as a ~390 px zone.
- **A reveal must let the bus activate the service.** `isServiceRegistered` asks
  "is it running now", which is exactly the wrong question for a D-Bus-activated
  file manager: the answer was false until the first click that would have
  started it. The helper sends `ShowItems`/`ShowFolders` with a 5 s timeout and
  lets activation happen; on a desktop with no `FileManager1` the call fails and
  the portal, then the default handler, still answer.
- **The Viewer's identity lives in the source string.** A QML `Image` whose
  `source` does not change never reloads, so `?v=<mtime>-<size>` is appended. Qt
  strips the query when it reads the file, so the path is untouched and the
  string changes exactly when the bytes do.
- **The Editor's reopen is a four-way answer.** Same path + unsaved edits → no-op
  with `editor_already_open` (asking for the picture in front of you is not a
  reason to be refused); same path + clean + unchanged → no-op that keeps the
  preview and the history; same path + clean + rewritten → decode again, because
  the document on screen is stale; different path + unsaved edits → refused with
  `unsaved_document`.
- **The shell asks; Core refuses.** `requestEditorOpen` runs the unsaved-changes
  dialog before any entry point opens a picture, and Save/Discard then send their
  command followed by the exact open in one `sendSequence`. The refusal is what
  protects a CLI or IPC caller; the question is what a person gets.

## Known gaps, in the words they were last measured with

- **Rows 99–103's window runs are driven, not clicked.** No hand typed a size,
  picked a fit, pressed the dock chevron, dragged the divider, answered the
  unsaved-changes question or reopened a file; `KOGAVIEW_DEV_COMMANDS` and the
  `editor-resize`/`editor-dock` requests call the same helpers and buttons the
  controls call, and every grab is a window grab of that state. The Viewer's
  before/after pair is two separate launches, because the rewrite has to happen
  between them. The divider was first read off the picture as a ~390 px zone; the
  harness now maps the zone, divider and strip to the scene, and 370 − 50 = 320
  is the measured answer — the earlier reading was wrong, not the layout.
- **"Show in folder" reached a real file manager, but no window was
  photographed.** In a fresh `dbus-run-session` the click activated
  `/usr/bin/dolphin --new-window --select /tmp/opencode/ws5/pics/wide.png`
  (`ps` at 02:48:49, pid 185577, and a second from the 02:49:44 run), which is
  the call arriving at a file manager that was not registered beforehand. The
  file being *selected* in an already-open window was not seen: this compositor
  supports no screen capture, and a window grab only reaches KogaView. On the
  real session bus Dolphin already owned `org.freedesktop.FileManager1`, so the
  old gate was true here — the bug is real for a desktop that has not started
  its file manager, and this session could only reproduce it inside a nested
  bus. Two stray Dolphin windows were left behind by those nested runs.
- **The Editor's reload-on-rewrite branch has no window run.** `open_editor`
  falls through to a decode when the same path's bytes changed, and Core covers
  both sides of the comparison, but the window evidence is the *unchanged* file
  (history kept, rev 6) and the Viewer's rewrite, not an Editor document whose
  file was rewritten under it.
- **The unsaved-changes question was not answered by a hand.** `Main.qml` needs
  the bridge, so `theShellAsksBeforeReplacingAnUnsavedDocument` reads its source
  and Core's tests walk the command order; no window run pressed Save or Discard
  from that dialog for an Editor open.

- **Rows 96–98's window runs are synthetic too.** No hand selected a tab,
  dragged a dock splitter or opened a menu; `KOGAVIEW_DEV_UI_REQUEST=editor-dock`
  writes `rightTab`/`rightPanelWidth` and clicks a rail button, and
  `context-menu` calls `popup()`. The six grabs are window grabs of those states.
- **The shared width is a source guard and a QML assertion, not a drag.** The
  suite counts three `rightPanelWidth: root.rightPanelWidth` bindings and the
  three `onPanelWidthRequested` handlers in `Main.qml`; no window run dragged
  the Browser's splitter and then opened the Viewer to measure the same width,
  so "a width chosen once is the width the other two open with" is proven at the
  binding, not with a pointer.
- **The per-workspace panel flags were never toggled on a window.** Core's
  `a_right_panel_toggle_belongs_to_its_workspace` and the config/state mirrors
  are the evidence; no grab shows the Viewer's panel hidden while the Browser's
  is open, and no journal line from a real menu click was collected.
- **`Original` was photographed after one save only.** The tab shows the written
  `saved-one.png` and its 20 KB size; the pre-save state (the source file) is the
  QML case's `/pics/photo.png`, and the save-over-the-same-path identity change
  is Core's `file_identity` test. No window run saved twice over one path and
  watched the thumbnail refresh. That run is also where the black frame was
  found — a `ThumbnailCache` passed where a `ThumbnailBook` was expected, which
  raised `TypeError` in `edgeFor` and left `edge` 0 — and the fix is the one
  mutation above that reproduces it.
- **"Show in folder" was not seen doing anything.** No file manager is running
  on this session, `org.freedesktop.portal.OpenURI` is not implemented by this
  desktop, and the portal therefore sends no response; the screenshot shows the
  Vietnamese menu entry, not a selected file. The `FileManager1` branch, the
  portal branch and the `QDesktopServices` fallback are code order, not measured
  outcomes. Inside a Flatpak the direct call is skipped by design and no
  sandboxed run exists.
- **The tool zone's height was photographed for Crop at 1472 × 943 only.** The
  180 px reference rule, the short window's scroll and the Brush/Eraser (no
  action row) states are `theReferenceZoneKeepsRoomWhenTheWindowIsShort` and the
  dock cases at the 700 px QML host; no short-window or Brush grab was taken.
- **The dock's translations were partly English for one build.** The shared
  panels are new translation contexts (`InfoPanel`, `PreviewPanel`,
  `HistoryPanel`), and the `.ts` had their strings under the old `BrowserView`/
  `EditorView` contexts until `lupdate` was re-run; the first Vietnamese grab of
  the Original tab read English for the moved labels. The re-run moved them, the
  gate reads 344 strings / 344 drawn, and `cpp/translations.cpp` stays the
  C++-only subset (the QML uses the compiled `kogaview_vi.qm`), so a QML string
  does not belong in that table. One residue is the `.ts` line numbers for the
  moved entries: they are lupdate's, not hand-written references.

- **Row 95's window runs are synthetic, and a short window needs a scroll.** No
  hand clicked a tab, dragged the divider or pressed the chevron; the six grabs
  came from `editor-dock` on the real Wayland window, which calls the same tab
  handler, divider and rail buttons. At the 943 px default window the Crop
  panel and the tabs both fit; at a 700 px window the zone is clamped to
  `height - 180` and the two-row action row leaves the anchor pad 34 px under
  the fold in the QML host, where the suite now scrolls the options column into
  view — a user scrolls the same column. No short window was photographed, and
  the tab, the split and the fold are still forgotten on the next launch.
- **Row 94's one-column rail was not photographed.** The QML case presses the
  real toggle and asserts two columns at 88 px → one at 50 px → back, the
  heading hidden and all twelve buttons still visible; the three window grabs
  show only the two-column state. No hand pressed the toggle, a tool button, a
  `px` selector, a table row or a single field: the runs were
  `KOGAVIEW_DEV_COMMANDS` + `editor-crop` / `editor-resize` on the real Wayland
  window, and the three pictures are `M1-editor-crop-unframed.png`,
  `M1-editor-tool-rail.png` and `M1-editor-resize-units.png`.
- **The icon-size fix is measured from two grabs, not from a watched click.**
  Two runs at the same window size gave the same muted-drawing bounding boxes
  (resize 14 × 16, transform 15 × 18, brush 19 × 18, eraser 15 × 16) whether the
  Editor had just opened or a tool had been clicked, which is what "does not
  grow on the first click" means here. A real click's frame-by-frame layout was
  not captured, and no 1.5×/2× display was available to check the scale.
- **The no-frame dim was not compared with another tool's.** 45 % black is the
  same value the outside strips already used, chosen for consistency; whether a
  user wants a lighter "armed but unselected" state was not asked, and no hand
  dragged a frame out of that state on a real window.
- **The Back button's new position is photographed in the Editor only.** The
  grab shows it as the first control after the workspace switcher and
  `tst_toolbar` reads both toolbar sources, but no screenshot puts the Viewer and
  the Editor side by side, because the window run opened the Editor.
- **Only `px` was photographed.** The `%` spelling (20 % of an 800 px side, a
  typed 25 % reaching the command as 1000 px, `0.03 %` round-tripping to one
  pixel, the Resize form's 50 % → 2000 × 1500) is asserted by
  `theUnitsAreAnotherSpellingOfTheSamePixels` and
  `theResizeFormTakesPercentagesToo`. No harness argument chooses a unit, so no
  grab shows `%` selected, and the selector is pointer-only (`focusPolicy:
  Qt.NoFocus`), so no key reaches it either.
- **The icons are the rail's, not the app's.** Twelve SVGs cover the Editor's
  tool and quick-edit buttons; the header, the menus, the Browser and the Viewer
  still draw the desktop's themed icons. Making the whole app
  icon-theme-independent is a later pass, not this one.
- **The fold is not remembered and HiDPI was not measured.** `toolColumns`
  resets to two every launch (it is view state, not `config.json`), and the
  icons ask for a 2× source size drawn at 20 logical px without a 1.5×/2×
  display to check that against.
- **Row 93's AVIF sample is a synthetic 64 × 48 frame.** `an_advertised_avif_is_really_decoded`
  encodes it with `image`'s own encoder and opens it back; the window run opened
  the ffmpeg `libaom-av1` sample of the same size. No camera or phone AVIF, no
  10-bit/HDR AVIF, no AVIF with an alpha plane and no animation was tried.
  HEIC/HEIF stay listed and refused: Qt draws them, Core does not, and adding a
  HEIC decoder is a separate library decision.
- **`has_decoder` costs a file open per Editor open, and proves the decoder can
  be constructed, not that this particular file decodes.** A truncated JPEG with
  a valid header still passes the check and fails later on the worker; only a
  format with no decoder is caught up front. The refusal reply is `no_decoder`;
  no new code was added for "file is damaged".
- **libdav1d is now a build dependency that Flatpak and Windows have to carry.**
  `just doctor` reports the pkg-config version and CMake links
  `PkgConfig::DAV1D`, but no sandboxed or Windows build was run; the Flatpak
  manifest does not exist yet. A machine without `libdav1d` fails the C++ link
  at `dav1d_*` symbols, which is exactly how the first attempt failed.
- **The Viewer and the Browser's thumbnails are still Qt, not Core.** They draw
  AVIF/HEIC/JXL only where the Qt image plugins are installed; a Qt build
  without the AVIF plugin would list the file (Core's `IMAGE_EXTENSIONS`) and
  show no thumbnail. That mismatch was not reproduced — this machine has the
  plugins.
- **`.pam` still decodes but is not listed.** `image`'s PNM decoder reads it and
  shared-mime-info has no MIME type for it, so the Browser's filter leaves it
  out; `.jpe` was added because shared-mime-info does map it to `image/jpeg`.
  The split is recorded, not resolved.
- **Row 92's window runs were synthetic, like every editor run here.** The
  `editor-crop` request clicked the real Crop button, the real lock buttons, the
  real Reset/Clear/Apply buttons and typed through the same helpers a hand uses,
  but no pointer was on the window and no key reached a field. The six grabs show
  the resulting states, not a hand's sequence: a real click on the picture, a
  typed `800`, a pressed padlock and a dragged handle are `QTest` sequences in
  `tst_editor`, not compositor events.
- **The post-Apply settle recognises a cut by size.** `pendingCropResult` matches
  the published document's width and height; only `editor_crop` can produce that
  size today, but a future command that published the same dimensions would be
  read as this cut. A document change whose size differs is left to the existing
  clamp/refit, which is what keeps an unrelated edit from framing the result.
- **Clear keeps the ratio.** Clear is about the frame, so the ratio text, the mode,
  the fill and the anchor survive it. The screenshot of a cleared panel can
  therefore still read `3:2`; that is the chosen split between Reset and Clear,
  not a measurement of what a user expects, and the ratio field is editable in
  that state.
- **The ratio field is validated on commit, not per keystroke.** `3`, `3:` and
  `3:2` are accepted in turn only when they parse; an unreadable entry snaps back
  to the previous ratio on `editingFinished`. No grab shows that snap-back, and
  the placeholder `Free` is the only empty-state cue.
- **Two locks make the handles refuse, but the inside still moves the frame.**
  That is a decision (moving is not reshaping) rather than a measured preference;
  the lock-drag case asserts both halves. The padlocks are 26 px buttons with
  tooltips, not a keyboard-reachable control: they are `NoFocus`, so Tab skips
  them and there is no key that toggles a lock.
- **The reordered panel was photographed at 1472 × 943 only.** It fits there with
  room to spare; a shorter window with Grow armed (the fill row visible) was not
  grabbed, and the panel is a scrolling column rather than a folding one.
- **The crop Live preview command is now UI-less.** `editor_crop_preview` keeps
  its protocol/Core tests but no QML emits it; whether to delete the command or
  keep it for a future CLI is an open contract question (item 6 below). The
  crop hint labels and `swapCropOrientation` are gone with no replacement key.

- **No hand pressed the chain, the dropdowns, or `Ctrl+Alt+I`.** Row 91's window
  runs filled the form through `KOGAVIEW_DEV_UI_REQUEST=editor-resize` (which now
  calls the background chooser and writes the filter through the same
  properties a pick does) and pressed Apply from the hook; the shortcut case
  used `KOGAVIEW_DEV_KEY`, which hands the `Shortcut` the `QShortcutEvent` its
  handler consumes. The screenshot shows the chain in its checked accent and
  `1200` selected in Width, but no compositor delivered a physical key, and no
  click landed on the swatch, the filter row or the chain.
- **The filter is proven different, not proven better.** Core's
  `the_resize_filter_changes_the_pixels` asserts Nearest keeps only source
  values while Bilinear, Lanczos3 and `Auto` interpolate and differ from it.
  The visual quality of each kernel was not compared on a photograph, and the
  `Auto` path's timing on a 27 MP JPEG was not re-measured after the change;
  `Auto` still uses `imageops::thumbnail` for a downscale, which is row 79's
  path unchanged.
- **The grow border was photographed opaque, not transparent.** The window runs
  grew a 1200 × 800 picture to 1536 × 1024 with a black border
  (`M1-crop-grow-border-vi.png`, `M1-crop-grow-applied-vi.png`) and the journal
  recorded `crop grow 1536 1024 #000000`; `fill_alpha = 0` is covered by Core's
  test and the QML command case only. Choosing Grow zoomed the view from 63 % to
  45 %, which is `revealCropGrowth` doing its one step, but the 12 % margin rule
  was not measured at its boundary, and no hand dragged a frame past the
  picture.
- **A Grow rectangle that stays inside the picture is sent as an ordinary
  crop** (`cropFillForCommand`), so its history line says Crop rather than Grow.
  That rule follows from "a fill means the canvas may grow"; the QML case now
  asserts the inside-Grow command carries no fill, but no user asked for the
  behaviour and no window run exercised it.
- **The Resize form still draws the platform's light fields** inside a dark
  window, exactly as the row-83 form did. `Background`'s swatch follows the
  theme, but the combo boxes and text fields are the style's own boxes; that
  contrast was not changed in this pass.

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
  window (see above), so a hand's frame-by-frame drag is still unexercised. Row
  90's real-window evidence is the same kind: `editor-crop` (`seed`, a
  preset + anchor, `_ARG4=swap`, `_ARG5=apply`) called the helpers and the
  buttons' own `click()`, while the nudges, Enter/Escape and the ratio-locked
  drags are `QTest` sequences. No hand pressed the swap button, typed X/Y or
  dragged a handle.
- **Row 90's side-drag rule is a choice, not a measurement.** A ratio-locked side
  handle pins its opposite side and grows the other axis around the rectangle's
  centre; corner handles pin the opposite corner. Photoshop's and Krita's exact
  behaviour was not compared, and no user asked for one. The shade is a fixed
  45 % black over the picture (not a theme colour), swap has no key, and Crop
  still has no straighten or output size — Transform and Resize/Export own those.
- **A document change only refits an unusable frame.** A rotate keeps the
  document size and therefore the same rectangle; only a shrink or an edit that
  leaves the rectangle outside re-seeds. That rule was chosen, not measured
  against what a user expects of a rotate.
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
follow-up since; it predates rows 66 and 77–90 until the next `just install-dev`
(or `just install`). The keyboard, tooltip, menu, export, canvas, toolbar and
crop evidence all comes from `build/dev/bin/kogaview`.

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
   be a different result, and neither was asked for. Row 92 answered Crop's
   frame, lock and Reset/Clear questions; what is left is smaller: whether a
   lock deserves a key as well as a button (the three padlocks are `NoFocus`), a
   clearer cue than a placeholder when the ratio text does not parse, and whether
   Clear should also drop the ratio rather than only the rectangle.
5. **The warp is one pass over every pixel on a worker thread.** `spawn_draft`
   already renders drafts on a `std::thread::spawn`, but a corner drag on a 27 MP
   document with Live preview on re-renders the whole frame per settle. Profiling
   it before adding tiling (item 1) is the cheaper move.
6. **Decide whether `editor_resize_preview` and `editor_crop_preview` still
   have a front end.** Row 84 removed the only QML that asked for a resize
   draft and row 92 removed the crop Live preview row, so neither command has a
   window emitter. Both are tested in protocol/Core; keeping them for a future
   CLI is a contract decision, and deleting them would remove payload shapes
   that rows 73 and 74's preview work introduced.
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
10. **HEIC is still listed and refused, and the rest of Qt's formats are
    Viewer-only.** Row 93 made the advertised list true for Core's decoders and
    gave an undecodable file a translatable sentence. The remaining split is
    deliberate: `heic`/`heif` are listed because a phone photo should not be
    invisible, `jxl`, RAW, PSD and SVG open only through `kogaview open FILE`
    (Qt reads them, Core does not), and `pam` decodes but has no MIME type.
    Deciding which of those Core should own is a format decision with a native
    dependency each time.
11. **The rail's fold and the dock's tab are forgotten, and the app is only
    half icon-driven.** Row 94's `toolColumns` and row 95's `rightTab` and
    `toolZoneFolded` live in the view, so a user who folded the rail or chose
    History does it again next launch; panel *visibility* is now the opposite
    (three Core flags in `config.json`, row 96) and the dock *width* is
    deliberately session-only. Persisting the tab would mean a settings field
    and a protocol decision, not a bigger `Main.qml`. The twelve SVGs cover the
    Editor's rail only — the header, the menus and the other two workspaces
    still depend on the desktop's icon theme, so a full set is the next visual
    pass.
12. **`%` has no keyboard or pointer story yet.** The selector is a `ComboBox`
    with `focusPolicy: Qt.NoFocus`, so Tab never reaches it and no key switches
    a field between `px` and `%`; a unit change is a pointer-only action today.
    Whether the unit belongs in the field at all, or should follow the panel
    (all four fields at once), is a design question left open.
13. **The shared dock width has never been dragged, and "Show in folder" has
    never reached a file manager.** The three bindings are guarded, but a real
    splitter drag followed by a workspace switch is the evidence still missing;
    the reveal path needs this session's file manager (or a Flatpak portal run)
    to be watched selecting a file. `Original` also only follows one save — a
    save-over-the-same-path thumbnail refresh would be worth photographing.

14. **Resize's three modes are one picture deep.** `Stretch` is proven to keep
    every column on a striped fixture, `Cover` to cut the centre, and `Pad` to
    leave the leftover transparent; no photograph or metric shows which mode
    looks right on a real JPEG with a face or text in it, and the filter's
    quality is unchanged by rows 99–103. Whether `Stretch` should be the default
    for a *locked* ratio at all — a lock usually means "keep the shape" — is a
    wording question the form now answers by making the row visible, not a
    measured preference.
15. **The dock remembers nothing.** `referenceFolded`, `toolZoneHeight` and each
    view's `rightTab` are view state, so the next launch opens unfolded and split
    at its default; panel *visibility* is Core's (three `config.json` flags) and
    the dock *width* is one session value. Persisting the fold or the split would
    be a settings field and a protocol decision.
16. **"Show in folder" needs a desktop that has a file manager to prove the
    selection.** The nested-bus run proved activation (`dolphin --new-window
    --select <path>`), which is the branch that was broken; selecting inside an
    already-open window, the portal branch, the default-handler fallback and the
    sandbox skip are code order. A KDE session with Dolphin already running is
    the missing run.
17. **Reopening has one branch with no window evidence.** An Editor document
    whose file is rewritten under it is meant to decode again; only Core's
    comparison covers it. The same is true of the shell's unsaved-changes
    question for an Editor open: it is a source guard plus Core's command order,
    not a dialog somebody answered.
