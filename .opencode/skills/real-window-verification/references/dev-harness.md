# `KOGAVIEW_DEV_*` evidence harness — reference

Compiled only into Debug builds (`#ifdef KOGAVIEW_DEV_HARNESS` in `cpp/main.cpp`,
set by the dev CMake preset). Each hook is inert unless its environment variable
is set, and none exists in a release build. Source of truth: `cpp/main.cpp`; this
page is the map, not the code.

Every hook goes through the same objects the UI uses — a dev command is a real
`Envelope` through the gateway, and a dev UI request emits the signal a click
would. That makes them useful evidence, but it is **synthetic** evidence: say so
in the report. Prefer a real click when the desktop allows one.

## State and commands

| Variable | Effect | What it proves |
|---|---|---|
| `KOGAVIEW_DEV_COMMANDS` | `;`-separated JSON command objects, dispatched through the gateway (e.g. `{"type":"open_folder","path":"/tmp/x"};{"type":"set_workspace","workspace":"viewer"}`) | the reachable state for a scenario, and that the command path works — it lands in `journal/commands.jsonl` |
| `KOGAVIEW_DEV_COMMANDS_START_MS` | delays the first dev command (default 600); later commands stay 900 ms apart | commands that must wait for an async command (e.g. `editor_open` decode) or for a slow debug-build first paint |
| `KOGAVIEW_DEV_COMMANDS_STAGGER_MS` | the gap between dev commands (default 900) | a batch that edits the open document needs ≥ 3 000–4 000, because the decode lands after the command that started it |
| `KOGAVIEW_DEV_STATE` | logs the explorer roots (`stateJson`) and what the thumbnail cache holds on disk | the tree is rooted where you think, cache hits/misses |
| `KOGAVIEW_DEV_GEOM` | every 400 ms, logs the viewer/viewport/canvas geometry, `zoom`, `contentX` of the filmstrip | scroll/zoom numbers over time, without touching the UI |

`KOGAVIEW_DEV_STATE` and the other `qInfo` hooks reach stderr only when
`QT_ASSUME_STDERR_HAS_CONSOLE=1` is set — Qt drops `qInfo` when stderr is not a
console (a piped run looks silent; `qWarning` still appears).

## Synthetic input

| Variable | Effect | What it proves |
|---|---|---|
| `KOGAVIEW_DEV_WHEEL` | one touchpad-typed wheel event (pixel delta, no angle delta) into the viewer | scroll-to-zoom on the real shell, with the real handler chain |
| `KOGAVIEW_DEV_FILMSTRIP_WHEEL` | three notches over the filmstrip, then logs where it settles | the glide target and the settled `contentX` |
| `KOGAVIEW_DEV_VIEWER_MENU` | right-button press/release in the middle of the viewing area, then logs click point, popup size and `menu.x/y` | the canvas menu opens through the real `TapHandler` |
| `KOGAVIEW_DEV_EDITOR_WHEEL` | four touchpad-typed wheel notches at 75 % / 30 % of the Editor canvas host, panning through the same `editorWheelHandler` a hand reaches; logs `zoom`/`offsetX`/`offsetY`/`autoFit` before and after, the `lastWheelX/Y` the handler recorded, and the drift of the document pixel under the cursor | wheel zoom-at-cursor in the Editor, and that the handler is actually reached |
| `KOGAVIEW_DEV_EDITOR_WHEEL_DELAY_MS` | delay before those notches (a decode needs ≥ 15 000 here) | |
| `KOGAVIEW_DEV_UI_REQUEST=editor-fit` / `editor-zoom` / `editor-pan` | `fit`, two `zoomIn`s, or "zoom until both axes overflow, then drag (120, 90)" through the view's own functions and handlers; each logs the presentation state before and after | Editor toolbar zoom, and a real pan through `DragHandler` |
| `KOGAVIEW_DEV_UI_REQUEST_ARG` (with `editor-pan`) | unused now — the hook zooms until it overflows instead of taking a step count | |
| `KOGAVIEW_DEV_UI_REQUEST=editor-pan-as` | zooms until both axes overflow, then drags 64 px on each axis through the real `DragHandler`, logging `offsetX`/`offsetY` before and after | the freer pan margin (a picture that overflows only slightly must still move) |
| `KOGAVIEW_DEV_UI_REQUEST=editor-resize` (+ `_ARG` = `WIDTHxHEIGHT` of a preset, default `1024x1024`) | clicks the real Resize tool button, writes the size dropdown through its own selection handler, then clicks Live preview; logs the preset index, ratio, tool and toggle | the Resize panel and the live draft on the real window when pointer warps do not reach it (the request is synthetic; no hand is on the mouse) |
| `KOGAVIEW_DEV_UI_REQUEST=editor-crop` (+ `_ARG` = `WIDTHxHEIGHT` of a fitting preset, default `1024x1024`; `_ARG2` = anchor key, default `center`) | clicks the real Crop tool button, picks the preset through the combo, clicks the named anchor button and arms Live preview; logs the anchor, ratio, tool, toggle and the four field values. The anchor button is found by walking the item tree, because a `Repeater` delegate is not a `findChild` reachable QObject | the Crop panel, the anchor placement and the live crop draft on the real window; same synthetic caveat |

Four notches are deliberate: one notch from fit only widens the picture past the
host horizontally, and `clampOffsets` correctly pins a shorter axis to 0, so an
anchor assertion at one or two notches would measure the clamp, not the zoom.

The pan hook drives `QTest::mousePress/mouseMove/mouseRelease`, not a hand-built
`QMouseEvent`: a `DragHandler` goes `active` for the latter but never satisfies
its own grab, so the offsets stayed at 0 and looked like a product bug. `QTest`
lives in the Debug build only (`CMakeLists.txt`), so no release binary links it.

All the above construct their events like the device they imitate, but no hand is
on the mouse. A previous session's rows calling them "measured on the real window"
mean the *window* was real, not the input.

## Shell-side requests

| Variable | Effect |
|---|---|
| `KOGAVIEW_DEV_UI_REQUEST` | `open-folder`, `open-external`, `open-with`, `context-menu` — emits the browser signal a click emits |
| `KOGAVIEW_DEV_UI_REQUEST_ARG` | the path to hand over; for `context-menu`, the entry whose `fileMenu` to pop |
| `KOGAVIEW_DEV_UI_REQUEST_DELAY_MS` | delay before firing (default is early) |
| `KOGAVIEW_DEV_UI_REQUEST_REPEAT_MS` | fire repeatedly — this is how "a dismissed dialog does not block the next one" was observed |
| `KOGAVIEW_DEV_PORTAL_DISMISS_MS` | calls `dismissActiveDialog()` on `PlatformHelper` after N ms, closing a portal dialog opened by a request |
| `KOGAVIEW_DEV_COPY_IMAGE` | calls `platform.copyImage(path)` 1 200 ms after start |
| `KOGAVIEW_DEV_UI_REQUEST=leave-guard` | calls `guardEditorLeave()` — the path a workspace switch, a window close and `Ctrl+Q` take — and logs whether the unsaved-changes dialog was asked for. `KOGAVIEW_DEV_UI_REQUEST_ARG` names the destination workspace; `_ARG2` is `discard`, `cancel` or `save`, which clicks the matching button in `unsavedDialog` after 1 500 ms | the unsaved-changes prompt, and that Discard/Cancel/Save actually decide the leave |
| `KOGAVIEW_DEV_FORMATS` | logs the image name filter, the save name filters and the interface languages `PlatformHelper` reports | the decoder list and the language table the pickers read |

A portal request that returns a handle is not a dialog that appeared. On this
machine `org.freedesktop.impl.portal.OpenURI` is unimplemented, so the response
never arrives and the chooser has never been seen drawn.

## Pictures and lifetime

| Variable | Effect |
|---|---|
| `KOGAVIEW_DEV_SCREENSHOT` | `QQuickWindow::grabWindow()` to that path, once exposed |
| `KOGAVIEW_DEV_SCREENSHOT_DELAY_MS` | how long to wait first (2 500–4 000 is typical) |
| `KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT` | quit after saving, so a headless run terminates |
| `KOGAVIEW_DEV_EXIT_AFTER_MS` | quit after N ms, for runs that are not about a picture |

`window is not exposed` usually means a stale instance already owns the app id —
`pgrep -a kogaview` and kill it, rather than lengthening the delay.

Offscreen (`QT_QPA_PLATFORM=offscreen`) loads no icon theme: `QIcon::themeName()`
is empty and every themed icon is blank. Judge layout there; judge icons only on
a Wayland run.