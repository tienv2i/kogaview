# Session handoff — state at 2026-11-17

Three sessions' worth of work on the same day: the launch surface speaks
Vietnamese and the dock icon draws, the mouse wheel moves at the rate the device
reports, fit is a mode that survives a window resize while Settings previews
live and saves on Apply/OK, the toolbar drops its labels instead of being
squashed while a shell-opened window is sized to the picture, and the label
threshold now follows the interface language instead of measuring English.

Nothing here is a plan; it is what was measured, what was not, and why.

## Tree

- Branch `main`, working tree clean. This session's commits are on top of
  `b72de13` and are listed in `git log`; the last three are the toolbar/window
  work, its language follow-up, and their report rows.
- `cpp/main.cpp` is **unchanged** by the toolbar commit; the language follow-up
  changes exactly one thing in it — `KOGAVIEW_DEV_SCREENSHOT` now treats
  `isExposed()` as a hint (a covered window on this session reports itself
  unexposed while `grabWindow()` still renders), waiting up to 8 s and then
  grabbing anyway. Temporary hooks used on the real window and removed again:
  `KOGAVIEW_DEV_WHEEL_LOG`, `KOGAVIEW_DEV_GRID_SCROLL` (wheel session),
  `KOGAVIEW_DEV_RESIZE` and `KOGAVIEW_DEV_SETTINGS_STEPS` (fit/settings session),
  and `KOGAVIEW_DEV_RESIZE` with `KOGAVIEW_DEV_RESIZE_SHOT` twice (toolbar, and
  the Vietnamese threshold). Only the evidence survives, in rows 62–65 of
  `docs/M1-REPORT.md`.
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
- **No `xdotool`, no `wmctrl`.** A window cannot be resized or clicked from a
  script on this session; both real-window checks below therefore drove the app
  through a temporary debug hook calling `QQuickWindow::resize` or a button's
  `click()`, not through a hand.

## What changed

| Row (`docs/M1-REPORT.md`) | Change | Verified how |
|---|---|---|
| 62 | Dock/app-grid icon was blank while Open With drew it; launch surface had no Vietnamese | prefix `icon-theme.cache` contains the app id; `Gtk.IconTheme.lookup_icon` answers PNG 16–256 and SVG at 96/512; `GioUnix.DesktopAppInfo` returns `Trình xem ảnh` under `vi_VN`; `just doctor` reports `7/7 raster sizes + SVG` |
| 63 | The mouse wheel scrolled ~29× too slowly in the grid and filmstrip | a notch is `angleDelta ±120` *plus* `pixelDelta ±10`; after the fix one notch = 645 px = 3 × 215 px, every settled offset a multiple of 645 |
| 64 | Fit did not survive a resize (Viewer `fit()` cleared its own flag; neither view refitted on a window resize); Settings applied nothing until Save | real window: 1920×935 fit `1.52717` → 760×520 fit `0.539` → 1100×700 fit `0.833`, screenshot whole; settings preview `dark → light` with `config.json` untouched, Cancel restored, Apply wrote `set_settings` rev 2 and stayed open |
| 65 | Toolbar squashed below its floor; shell-opened windows ignored the picture's shape; the Vietnamese threshold was computed from English labels and the small-image hint had no translation | real window with a temporary resize hook: row 683 px compact / 921 px labelled (English Viewer), 1039 (English Editor), 1015 / 1133 (Vietnamese), floor **870** re-applied after requests for 200–869, labels on at exactly **1131** and off at 1130 in English, on at exactly **1225** and off at 1224 in Vietnamese (Editor); 2400×1600 → 1339×1086, 300×200 → 878×420 at 100 % with the hint, 9000×600 → 1731×420 at 19 %, 700×700 → 878×904; screenshots in `docs/evidence/M1-toolbar-*.png` and `M1-window-*.png` (Vietnamese ones suffixed `-vi`) |

## Test gate

`PATH=/tmp/opencode/lrel/bin:$PATH just test` — exit 0:

```
translations: 134 strings in kogaview_vi.ts, 105 of them compiled into C++
packaging: 19 MIME types, 3 categories, icon and metainfo named …
cargo: 60 passed + 4 passed
viewer 29 · browser 35 · cache 15 · state 7 · settings 13 · editor 18 · language 5 · toolbar 11
```

`cargo fmt --check` clean. `cargo clippy --workspace --all-targets -- -D warnings` reports two
pre-existing `derivable_impls` errors in `crates/app-protocol/src/lib.rs` (`Default for
Workspace`/`Theme`), untouched by this change.

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

- **The dock and app grid were never photographed.** Proven at the icon-theme and
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

## Next natural step

1. **Status text as data** — publish `status { code, args }`, translate at the
   presentation edge; removes the last English strings in a Vietnamese window.
2. **Export** the working document with real options (JPEG quality, metadata) —
   ADR 0004 left them out.
3. **Editor open speed** (row 60): downscaled JPEG decode for the preview, tiled
   decode for the document.
