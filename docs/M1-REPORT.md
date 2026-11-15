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
| 2 | Tests | `just test` | PASS: 17 core + 3 protocol tests |
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
| 21 | Viewer layout and centring | Qt Quick harness loading the real `Viewer.qml` (`offscreen` QPA) that asserts `canvas.mapToItem(viewport, …)` corners, plus pixel measurement of the runtime screenshots | bbox centre equals viewport centre within 1 px for fit, 100 %, 3× (clipped on all sides) and 90°/180°/270° rotation, flipped H/V, for both a 1200×800 and a 600×900 image; panning by (40, −25) moves the image by exactly (40, −25); `zoomAt` keeps the image point under the cursor fixed (measured drift 0.00 px at three cursor positions). Real binary: image spans x 177–1102 (centre 639.5) of a 1280-wide viewport, y 57–674 = 617 px = 800 × 0.77175, unclipped |

### Dev harness used for evidence

The Debug binary enables `KOGAVIEW_DEV_*` hooks; every hook is inert unless its
environment variable is set. Used here: `KOGAVIEW_DEV_COMMANDS` (dispatch
protocol commands), `KOGAVIEW_DEV_SCREENSHOT*` (grab the window),
`KOGAVIEW_DEV_COPY_IMAGE`, `KOGAVIEW_DEV_EXIT_AFTER_MS` and `KOGAVIEW_DEV_GEOM`
(log the viewer canvas geometry behind the centring measurements). The geometry
log relies on the stable `objectName`s `viewer`, `viewerViewport` and
`viewerCanvas`.

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
  anchored at the cursor (the anchoring maths is verified; the input path is
  not, see below).
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
- Panning and scroll-to-zoom were **not** driven with input events. Panning is
  verified only through the transform maths (offsets move the image by exactly
  the offset). Scroll-to-zoom is **deferred**: the handler supports mouse
  `angleDelta` and touchpad `pixelDelta` with cursor anchoring, and the anchored
  zoom itself is verified by calling `zoomAt` directly, but no wheel event ever
  reached a QML `WheelHandler` in this session from any injection path —
  `QTest.wheelEvent()` and `QGuiApplication::sendEvent(window, QWheelEvent)`
  reported delivery while the handler stayed silent on this Wayland session, and
  GNOME's RemoteDesktop `NotifyPointerAxisDiscrete` arrived at the app as a
  drag/pan (`DragHandler` became active) rather than as a wheel event on the
  fullscreen test window, so that harness cannot be trusted either. `QTest`
  wheel injection does reach `WheelHandler` under the `offscreen` QPA plugin,
  which is why an earlier revision of this report wrongly claimed on-device
  verification; that claim is withdrawn. Confirming scroll-to-zoom needs a real
  mouse/touchpad or a `uinput`-backed injector, neither of which was available.
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
- `docs/evidence/M1-editor.png`
