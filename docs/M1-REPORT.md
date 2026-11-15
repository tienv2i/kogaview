# M1 report — desktop shell, browsing and the command gateway

- Date: 2026-11-15
- Environment: Arch Linux, GNOME on Wayland (`XDG_SESSION_TYPE=wayland`,
  `XDG_CURRENT_DESKTOP=GNOME`), Qt 6.12.0, rustc 1.99.1, CXX-Qt 0.10
- Artifact exercised: `build/dev/bin/kogaview` (dev profile, app ID
  `io.github.tienv2i.KogaView.Dev`)

## What this phase delivers

- Renamed project namespace to `io.github.tienv2i` (desktop template, docs,
  scripts, QML module URI).
- Runtime directories and the persisted configuration moved to the short
  application name (`~/.config/kogaview-dev/config.json`), see ADR 0002.
- `kogaview-protocol` v1: `Envelope`, `Command`, `Query`, `Theme`, `Workspace`,
  `ProtocolError`.
- `kogaview-core`: single ordered command gateway, revisioned `UiState`,
  append-only command journal, atomic configuration with corrupt-file fallback,
  async folder scanning, file operations (copy/move/trash/delete), quick-access
  list management.
- Qt adapter: one `KogaViewBridge` QObject exposing a JSON state snapshot plus
  `dispatch`, `query`, `poll`. QML renders the snapshot and submits envelopes;
  it performs no domain mutation.
- `PlatformHelper` (C++): XDG portal `FileChooser` dialogs with a Qt fallback,
  image and text clipboard, external open and folder reveal.
- QML shell: three icon mode buttons, per-workspace toolbar, burger menu
  (open file, open folder, theme toggle, exit), centred content and a status bar.
- Browser: quick access + explorer-style folder tree, collapsible one-row
  breadcrumbs, responsive async thumbnail grid, preview/metadata sidebar with a
  toggle, context menus for files, folders and quick-access entries.
- Viewer: back, previous/next, zoom in/out, fit, 100%, rotate left/right, flip
  horizontal/vertical, filmstrip toggle, panning and scroll-to-zoom.
- Editor: placeholder with two sidebars, empty centre and status bar.

## Verification actually performed

All commands were run from the repository root on the real binary. Where noted,
`XDG_CONFIG_HOME`/`XDG_STATE_HOME`/`XDG_CACHE_HOME` were redirected to
`/tmp/opencode/kv*` so that the interactive instance used by the project owner
did not change the evidence.

| # | Scenario | Command (abridged) | Result |
|---|---|---|---|
| 1 | Build | `just build` | PASS, artifact `build/dev/bin/kogaview` |
| 2 | Tests | `just test` | PASS: 17 core + 3 protocol Rust tests, then 14 Qt Quick viewer tests |
| 3 | Formatting | `cargo fmt --all -- --check` | PASS |
| 4 | Version | `kogaview --version` | `KogaView (Dev) 0.1.0 (io.github.tienv2i.KogaView.Dev)` |
| 5 | Config creation | first run, then `cat ~/.config/kogaview-dev/config.json` | file created with dark theme, `~/Pictures` + `~` quick access, panels and filmstrip on |
| 6 | Browser + folder | `kogaview open-folder /tmp/opencode/photos` | 6 items / 5 images, breadcrumbs `/ › tmp › opencode › photos`, tree and thumbnails rendered — `docs/evidence/M1-browser-dark.png` |
| 7 | Viewer | `kogaview open /tmp/opencode/photos/portrait.jpg` (also `sunset.png`) | image centred, counter `2 / 5`, filmstrip auto-positioned on the current image — `docs/evidence/M1-viewer.png` |
| 8 | Editor | dev gateway hook `set_workspace editor` | placeholder with two sidebars and status bar — `docs/evidence/M1-editor.png` |
| 9 | Theme persistence | dev hook `toggle_theme`, then restart without arguments | `config.json` became `"theme": "light"`; the next run restored the light theme and the last folder — `docs/evidence/M1-browser-light.png` |
| 10 | Folder restore | restart with no arguments | scan of the persisted `last_folder` completed (`folder scan complete … items=6 images=5`) |
| 11 | Copy | gateway `copy_to` on a scratch tree | file present twice, source kept |
| 12 | Move | gateway `move_to` on a directory | directory relocated, source gone |
| 13 | Permanent delete | gateway `delete_permanently` | directory removed |
| 14 | Trash | gateway `trash` on `$HOME/kogaview-trash-test.txt` | file removed and present in `~/.local/share/Trash/{files,info}` with a `.trashinfo` entry |
| 15 | Trash failure path | `gio trash` on a `/tmp` file | gio refuses trashing on system internal mounts; Core reports the failure instead of deleting |
| 16 | Clipboard image | dev hook `copyImage`, then `wl-paste --list-types` and `wl-paste --type image/png` | `image/png` offered; pasted image is 600×900 and pixel-identical to `portrait.jpg` |
| 17 | Journal | `~/.local/state/kogaview-dev/journal/commands.jsonl` | one JSON line per command with id, name, revision, result and sanitized paths |
| 18 | Structured logs | `~/.local/state/kogaview-dev/logs/kogaview.jsonl.*` | startup record with app ID, profile, version, git SHA, protocol version, state/log dirs, boot ID |
| 19 | Deep breadcrumbs | `open-folder` of a seven-level path under `/tmp/opencode/deep/` | breadcrumbs stay on one row: `/ › … › third-long…ment-gamma › … › leaf`; the root stays visible and `…` opens the hidden parents — `docs/evidence/M1-browser-deep-crumbs.png` |
| 20 | Viewer navigation | dev hook `viewer_next` twice from `sunset.png` | moved to `mono.bmp` at `1 / 5`, wrapping the ordered set (`mono, portrait, square, sunset, wide`); revisions 3 and 4 |
| 21 | Viewer layout and centring | `tests/qml/tst_viewer.cpp` loading the real `Viewer.qml` (offscreen QPA) and asserting on `canvas.mapToItem(viewport, …)` corners, plus pixel measurement of the runtime screenshots | bbox centre equals viewport centre within 1 px for fit, 100 %, 3× (clipped on all sides) and 90°/180°/270° rotation, flipped H/V, for both a 1200×800 and a 600×900 image; panning by (40, −25) moves the image by exactly (40, −25). Real binary: image spans x 177–1102 (centre 639.5) of a 1280-wide viewport, y 57–674 = 617 px = 800 × 0.77175, unclipped |
| 22 | Scroll-to-zoom | `tests/qml/tst_viewer.cpp` (run by `just test`) injecting a touchpad-typed wheel event (`pixelDelta` 15, `angleDelta` 0) and a mouse wheel (`angleDelta` ±120) into the real `Viewer.qml`; plus one injection into the running app window (`KOGAVIEW_DEV_WHEEL=1`) | touchpad: `0.6000 → 0.6966` (`1.01^15`), mouse: `0.6000 → 0.7182` and back (`1.0015^120`); the image point under the cursor stayed within 0.5 px at three cursor positions, with and without an explicit scroll phase. In the running app the injected touchpad scroll gave `zoom 0.77175 → 0.895978` with `offsetY 0 → −7.08`, i.e. anchored on the cursor rather than on the viewport centre |
| 23 | Pointer-device gating (negative control) | same suite with `acceptedDevices` forced to `PointerDevice.Mouse` | touchpad-typed wheel events are dropped (zoom stays `0.6`) and zoom again as soon as the handler accepts all devices; mouse wheels work either way. This confirms that `acceptedDevices: PointerDevice.AllDevices` is what makes touchpad scroll-to-zoom work |
| 24 | Regression check of the suite itself | temporarily restored `x: viewport.width / 2 - width * scale / 2 …` and re-ran the suite | 13 failures, including a cursor-anchor drift of −96.6 px, so the suite does fail when the bug returns |

### Dev harness used for evidence

The Debug binary enables `KOGAVIEW_DEV_*` hooks; every hook is inert unless its
environment variable is set. Used here: `KOGAVIEW_DEV_COMMANDS` (dispatch
protocol commands), `KOGAVIEW_DEV_SCREENSHOT*` (grab the window),
`KOGAVIEW_DEV_COPY_IMAGE`, `KOGAVIEW_DEV_EXIT_AFTER_MS`, `KOGAVIEW_DEV_GEOM`
(log the viewer canvas geometry behind the centring measurements) and
`KOGAVIEW_DEV_WHEEL` (inject one touchpad-typed wheel event into the running
window to observe scroll-to-zoom on the real shell). The geometry log relies on
the stable `objectName`s `viewer`, `viewerViewport`, `viewerCanvas` and
`viewerWheelHandler`.

The repeatable part of this is not the hooks: `just test` runs
`tests/qml/tst_viewer.cpp`, which loads the unchanged `Viewer.qml`, asserts on
the transforms Qt Quick applies and injects explicit mouse/touchpad wheel
events, so these regressions fail the pipeline instead of only showing up on
screen.

### Bugs found and fixed during verification

- QML root object never loaded: `IconLabel` is not a public Qt Quick type. It was
  replaced by a themed non-interactive `Icon` component. The loader now reports
  compile and instantiation errors instead of returning a silent `-1`.
- `theme: theme` inside components that declare their own `theme` property
  self-bound to the default (dark) `Theme`, so light mode left the sidebars,
  breadcrumbs and preview dark. The root theme now has a distinct `appTheme` id.
- `Viewer.rotation` shadowed `Item.rotation`; renamed to `rotationAngle`.
- Checked toolbar buttons and separators used the platform palette and looked
  wrong on the custom surfaces; replaced with themed `ToolbarButton` /
  `ToolbarSeparator`.
- Collapsing the breadcrumbs hid the filesystem root, so a long path offered no
  anchor. The root now always stays visible and the middle elides behind `…`.
- The viewer canvas was positioned with `x: viewport.width / 2 - width * scale / 2`.
  `scale` and `rotation` already pivot on the item centre, so multiplying by
  `scale` counted the zoom twice: the first image of a session was drawn down
  and to the right (measured image centre x = 776 in a 1280-wide viewport) with
  its bottom edge clipped, and the wrong position was never recomputed. The
  position now uses the unscaled size,
  `x: (viewport.width - width) / 2 + view.offsetX`, which is scale-invariant
  because the pivot is the centre.
- Flip mirrored the image about the `Scale` transform's default origin, the
  item's top-left corner, so "flip horizontal" moved it out of the viewport
  (bbox centre went to x = −560). The flip transform now pivots on the canvas
  centre.
- Scroll-to-zoom ignored touchpad scrolling: the handler only read
  `angleDelta`, while Wayland delivers two-finger scrolling as continuous
  `pixelDelta` with `angleDelta` zero. Both are now supported, and zoom is
  anchored at the cursor.
- `WheelHandler` filters by pointer device type and dropped touchpad wheel
  events, so scrolling did nothing on a laptop. It now accepts
  `PointerDevice.AllDevices`; the regression test in row 23 fails without it.
- The QML `WheelEvent` exposes `x`/`y`, not `position`; anchoring now uses the
  actual properties.
- Qt logs (including QML warnings) are routed to journald when stderr is not a
  TTY; evidence runs set `QT_ASSUME_STDERR_HAS_CONSOLE=1`.

## Not verified here (honest gaps)

- Pointer and keyboard interaction was not driven by this session: the project
  owner was exercising the app interactively in parallel. Clicking the workspace
  buttons, opening context menus, choosing menu entries and the "copy image
  content" menu item are wired to the same commands and functions verified above,
  but the click paths themselves were not captured as evidence by this report.
- Portal dialogs: only availability is logged and the Qt fallback exists.
  A second simultaneous instance cannot register the same portal app ID (`Could
  not register app ID: Connection already associated with an application ID`), so
  the portal dialog was not exercised while the owner's instance was running.
- Scroll-to-zoom is now verified with injected events (rows 21–24), but no
  physical input was driven by this session: no mouse wheel or touchpad gesture
  was generated by hand, so the last centimetre — a compositor delivering a real
  libinput gesture to the window — rests on the project owner's interactive
  check plus the fact that the injected events carry the same touchpad device
  type and `pixelDelta`/`angleDelta` payload libinput produces. Panning is
  verified through the transform maths (offsets move the image by exactly the
  offset) and by `DragHandler` becoming active under compositor-injected pointer
  motion, not by a real drag.
- Pointer injection history, for the next person: `QTest.wheelEvent()` and
  `QGuiApplication::sendEvent(window, QWheelEvent)` both delivered nothing while
  the handler still filtered touchpad devices — that was the bug, not the
  harness. A `QWheelEvent` with phase `ScrollUpdate` is accepted by
  `QWindowSystemInterface::handleWheelEvent()` only through
  `sendEvent()`/`dispatchWheel()`; `handleWheelEvent()` returns `false` for
  mid-gesture phases on Qt 6.12, so use `NoScrollPhase` there or dispatch the
  event to the window directly.
- Thumbnails are decoded by Qt's `Image` element per delegate; there is no
  thumbnail cache, downscale pipeline or EXIF orientation yet (M2/M3).
- Viewer rotate/flip are presentation-only and reset when the image changes.
- No single-instance coordination or IPC: a second instance shares the same
  config, journal and logs. Observed during verification when the interactive
  instance changed the filmstrip setting under the evidence instance.
- Flatpak, `.desktop` installation, MIME registration and Windows were not run.
- `gio trash` refuses paths on system internal mounts such as `/tmp`; only
  `$HOME` files were confirmed to land in the freedesktop trash.

## Evidence files

- `docs/evidence/M1-browser-dark.png`
- `docs/evidence/M1-browser-light.png`
- `docs/evidence/M1-browser-deep-crumbs.png`
- `docs/evidence/M1-viewer.png`
- `docs/evidence/M1-viewer-scroll-zoom.png` (injected touchpad scroll: zoom 0.77175 → 0.895978, anchored on the cursor)
- `docs/evidence/M1-editor.png`
