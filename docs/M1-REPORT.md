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
- QML shell: three `<icon> <text>` workspace switcher buttons (Browser, Viewer,
  Editor), per-workspace toolbar, burger menu
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
| 2 | Tests | `just test` | PASS: 34 core + 3 protocol Rust tests, then 14 Qt Quick viewer tests and 21 Qt Quick browser/explorer tests |
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
| 25 | Workspace switcher shows icon *and* text | `tests/qml/tst_browser.cpp` (run by `just test`) loading the real `WorkspaceSwitcher.qml`, asserting `display == AbstractButton.TextBesideIcon`, non-empty `icon.name`, the label, a content width wider than the icon alone and a button at least as wide as its content; plus `docs/evidence/M1-explorer-root.png` | Browser/Viewer/Editor each render as `<icon> <text>`; clicking Viewer emits `selected("viewer")` and the checked state follows the workspace Core reports |
| 26 | Explorer keeps its root | `tests/qml/tst_browser.cpp` driving real mouse events (`QTest::mouseClick`/`mouseDClick`) on the tree row, the disclosure arrow, the grid cell, a quick-access entry and a breadcrumb; plus `KOGAVIEW_DEV_COMMANDS` + `KOGAVIEW_DEV_STATE` on the real binary | tree row → `navigate:/root/dirA` (never `open_folder`) and the node expands; disclosure arrow toggles without emitting a command; grid double-click on a folder → `navigate`, on an image → `open_file`; quick access → `open_folder:/fav`. Real binary: `open_folder photos` → `rootFolder photos / currentFolder photos`; `navigate photos/sub` → `rootFolder photos / currentFolder photos/sub` — the tree stayed rooted at `photos` while the grid showed `sub` (`docs/evidence/M1-explorer-root.png`) |
| 27 | Explorer regression check | reintroduced each old behaviour in turn (tree click and grid double-click sending `open_folder`, tree rooted at `currentFolder`, icon-only mode buttons) and re-ran `kogaview_browser_qml_tests` | each mutation is caught: `treeClickNavigatesWithoutRerooting`, `gridDoubleClickOnFolderNavigates`, `treeIsRootedAtTheOpenedFolder` and `switcherShowsIconAndText` fail respectively; the restored sources pass 11/11 |
| 28 | Tree refreshes after a right-click file operation | `tests/qml/tst_browser.cpp` (`treeRefreshRebuildsNodesAndKeepsPosition`, `treeRefreshReachesAnUnchangedParent`, `treeRefreshRespectsUserCollapse`, `treeIsNotReloadedWithoutATreeRevision`) loading the real `BrowserView.qml` with a stub `listFolders` that gains a folder mid-test; plus `KOGAVIEW_DEV_COMMANDS` + `KOGAVIEW_DEV_STATE` on the real binary | a folder created inside the open `sub` folder appears under the same still-expanded `sub` row, a sibling row survives, the root row stays `photos`, `currentFolder` stays `photos/sub` and the refresh emits no command; a node the user collapsed stays collapsed; selection/status-only state changes reload nothing. Real binary: `new_folder` in `photos/sub` → `treeRevision 0 → 1`, tree row `after-refresh` appears under `sub`, breadcrumbs and grid still on `photos/sub`, root still `photos` (`docs/evidence/M1-tree-refresh.png`, which is the `move_to` case: the moved folder leaves `sub` and appears at the `photos` level while `sub` stays open) |
| 29 | Tree refresh regression check | reintroduced each failure mode in turn (no `treeRevision` watcher, no `expandedPaths` restore on recreated nodes, auto-reveal ignoring a deliberate collapse, a non-recursive reload) and re-ran `kogaview_browser_qml_tests` | each mutation is caught: the two refresh tests time out, `treeRefreshRebuildsNodesAndKeepsPosition` loses the expansion, `treeRefreshRespectsUserCollapse` and `treeChevronOnlyTogglesTheNode` re-expand, and `treeRefreshReachesAnUnchangedParent` still shows the stale children; the restored sources pass 15/15 |
| 30 | Symlinked folders behave like folders | `cargo test -p kogaview-core` (`symlinked_folders_are_listed_as_folders`, `copying_a_symlink_copies_the_link_only`, `deleting_a_symlinked_folder_keeps_its_target`, `normalize_path_cleans_segments_but_keeps_links`, `normalize_path_does_not_resolve_a_symlink`) on a scratch tree holding `target/`, `aaa/`, `picture.png` and three links (`link → target`, `image-link.png → picture.png`, `broken → nowhere`); plus `KOGAVIEW_DEV_COMMANDS` + `KOGAVIEW_DEV_STATE` on the real binary with `/tmp/opencode/photoslink → /tmp/opencode/photos` | `list_folders` returns `aaa, link, target` — the link sorts with the real folders instead of falling into the file section; `link` has `is_dir` and its own path, `image-link.png` stays an image and `broken` still appears as a plain file (not hidden). Copying/moving the link recreates a link with the same target and duplicates nothing; deleting it keeps `target/inside.txt`. Real binary: `open_folder /tmp/opencode/photoslink` → `rootFolder /tmp/opencode/photoslink`, `navigate …/photoslink/sub` → `currentFolder /tmp/opencode/photoslink/sub`, tree expanded `…/photoslink …/photoslink/sub` — the link's path survives, where `canonicalize` used to replace it with `/tmp/opencode/photos`; breadcrumbs read `/ › tmp › opencode › photoslink › sub` and the tree renders `photoslink` with a folder icon (`docs/evidence/M1-symlink-folder.png`) |
| 31 | Symlink regression check | reverted `read_entries` to `DirEntry::metadata()` (never follows the link) and `copy_recursive` to following links, then re-ran `cargo test -p kogaview-core` | 2 failures (`symlinked_folders_are_listed_as_folders`, `copying_a_symlink_copies_the_link_only`) out of 22; the restored sources pass 22/22 |
| 32 | XDG portal open mechanism | `gdbus introspect` of `org.freedesktop.portal.Desktop`, a PyGObject probe (`scripts/portal_probe.py`) that mimics the client, and the real binary driven through `KOGAVIEW_DEV_UI_REQUEST=open-folder` / `open-external` | three real defects fixed. (a) `FileChooser` has no `OpenFolder` method — every folder dialog failed with `No such method “OpenFolder”` and silently fell back to the Qt dialog; folder picking is now `OpenFile` with `directory: true`, and the caller falls back when `FileChooser` version < 3. (b) The reply handle is a `QDBusObjectPath`; `QVariant::toString()` returns an empty string for it, so every request was logged as `empty request path for "OpenFile"` after the portal had opened it — read it with its own accessor now. (c) `Response` is now subscribed on the predicted handle (`/…/request/<our bus name>/<token>`, derived from `baseService()`) *before* the method call, so a fast cancel or denial is not missed. Also `parent_window` is `x11:<winId>` on xcb (empty elsewhere, dialogs then non-modal), `Request.Close` dismisses a timed-out/abandoned dialog (also from the destructor), and "open with the system application"/reveal go through `org.freedesktop.portal.OpenURI.OpenURI` with `QDesktopServices` as fallback. Old binary log: `portal: "OpenFolder" failed: "No such method “OpenFolder”"` then `portal: empty request path for "OpenFile"`; new log: `portal: "OpenFile" requested at "/org/freedesktop/portal/desktop/request/1_286/kogaview_<pid>_1" parent "<none>"`, `portal: closed "…/kogaview_<pid>_1"` on dismissal, and `portal: OpenURI "file:///tmp/opencode/photos" (directory) handle "/org/…/kogaview_<pid>_1"`. The probe printed `returned handle … matches prediction: True`. Dismissal was observed end to end with `KOGAVIEW_DEV_PORTAL_DISMISS_MS` plus a repeated request: `closed "…/kogaview_<pid>_1"` → `no answer after dismissal, request dropped` → `requested at "…/kogaview_<pid>_2"`, i.e. a dismissed dialog does not block the next one |
| 33 | Toolbar "Open folder" button and resizable sidebars | `tests/qml/tst_browser.cpp` (`toolbarOffersAnOpenFolderButton`, `leftSidebarIsResizable`, `sidebarResizeIsClamped`, `rightSidebarResizesInward`, `splitterDoubleClickRestoresTheDefault`, `splitterFollowsPanelVisibility`) instantiating the real toolbar component and dragging the real `PanelSplitter` handles with `QTest::mousePress`/`mouseMove`/`mouseRelease`; plus the real binary | the toolbar button is icon-only (`folder-open-symbolic`), a click emits `requestOpenFolder()` and no `command`, which `Main.qml` turns into the shell's folder dialog; a +80 px drag moves `leftPanelWidth` *and* the panel's actual `width` by 80; a −600 px / +4000 px drag clamps at the splitter's `minimum`/`maximum`; dragging the right handle inward by 90 px widens the right panel by 90; double-click restores the theme width; hiding a panel hides its handle. Real binary: `docs/evidence/M1-symlink-folder.png` shows the open-folder icon between refresh and new-folder and both splitter bars at the sidebar edges |
| 34 | Sidebar/toolbar regression check | reintroduced four failure modes in turn (drop `onMoved` from the left splitter, make `PanelSplitter.clamp` the identity, flip the right splitter's `direction` to +1, leave the open-folder button's `onClicked` empty) and re-ran `kogaview_browser_qml_tests` | each mutation is caught by exactly one test — `leftSidebarIsResizable`, `sidebarResizeIsClamped`, `rightSidebarResizesInward` and `toolbarOffersAnOpenFolderButton` respectively; the restored sources pass 21/21 |

| 35 | Explorer root and open folder restored separately | `cargo test -p kogaview-core` (`the_root_and_the_open_folder_are_saved_apart`, `walking_out_of_the_tree_re_roots_the_saved_value`, `restoring_a_session_keeps_the_tree_above_the_open_folder`, `restoring_derives_the_value_that_is_missing`, `restoring_deleted_folders_opens_nothing`, plus the policy tests `the_root_survives_navigation_inside_the_tree`, `a_sibling_with_a_common_prefix_is_outside_the_tree`, `leaving_the_subtree_moves_the_root`, `both_saved_folders_are_restored_separately`, `a_missing_folder_is_derived_from_the_surviving_one`, `a_folder_outside_the_saved_root_is_repaired`); plus `KOGAVIEW_DEV_COMMANDS`/`KOGAVIEW_DEV_STATE` on the real binary | the tree root and the open folder are two persisted values (`config.json` → `"tree_root": "…/photos"`, `"last_folder": "…/photos/sub"`); restarting restores `rootFolder …/photos` with `currentFolder …/photos/sub` and the tree expanded down to `sub` (`docs/evidence/M1-root-vs-open.png`). Live sequence, root/current after each command: `open_folder photos` → `photos/photos`; explicit `open_folder photos/sub` (inside the tree) → `photos/photos/sub`; `navigate photos/sub/deep` → `photos/photos/sub/deep`; `navigate /tmp/opencode` (leaves the subtree) → `/tmp/opencode//tmp/opencode`; `navigate /tmp/opencode/photos` (inside again) → `/tmp/opencode//tmp/opencode/photos`. `navigate` now persists the open folder too, and only when the value really changed |
| 36 | Root/list regression check | reintroduced four failure modes in turn (make `open_folder` always re-root, restore the tree collapsed into the open folder, persist only `last_folder`, persist only on explicit open) and re-ran `cargo test -p kogaview-core` | each mutation is caught — `the_root_and_the_open_folder_are_saved_apart` for three of them and `restoring_a_session_keeps_the_tree_above_the_open_folder` for the restore; the restored sources pass 34/34 |

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

`KOGAVIEW_DEV_STATE` prints `rootFolder`/`currentFolder`/`workspace`/`treeRevision`
once at startup and after every dev command, plus the paths the tree currently
has expanded, which is how "the sidebar root and the open folder are two values",
"navigation only re-roots when it leaves the subtree" and "a file operation
refreshes the tree without losing the open position" are checked from a log.

Three hooks exist for the platform paths that normally need a click:
`KOGAVIEW_DEV_UI_REQUEST=open-folder|open-external` invokes the browser's
`requestOpenFolder`/`openExternal` signal after `KOGAVIEW_DEV_UI_REQUEST_DELAY_MS`
(argument in `KOGAVIEW_DEV_UI_REQUEST_ARG`, optional `…_REPEAT_MS` to fire it
again), `KOGAVIEW_DEV_PORTAL_DISMISS_MS` closes the portal dialog through
`PlatformHelper::dismissActiveDialog`, and `KOGAVIEW_DEV_SCREENSHOT` captures the
window. They go through the same signals
and helpers the UI uses, so a log line proves the real path was taken — but they
are still synthetic triggers, not a person clicking (see the gaps).

The repeatable part of this is not the hooks: `just test` runs two Qt Quick
suites that load the unchanged QML sources and assert on what Qt Quick actually
does — `tests/qml/tst_viewer.cpp` (transform maths and injected mouse/touchpad
wheel events) and `tests/qml/tst_browser.cpp` (real clicks on the workspace
switcher and the explorer, asserted through the commands the views emit). These
regressions fail the pipeline instead of only showing up on screen.

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
- The workspace mode buttons were icon-only, so Browser, Viewer and Editor could
  not be told apart without hovering for the tooltip. They now render
  `<icon> <text>`, and `ToolbarButton` grows beyond its 34 px square instead of
  clipping the label.
- Every click in the folder tree sent `open_folder`, which persisted the folder
  as the new root and re-rooted the tree on itself: browsing the tree destroyed
  the folder the user had opened. `UiState.root_folder` now records the folder an
  explicit open selected; tree clicks, grid double-clicks, breadcrumbs and the
  up button send `navigate`, which changes `current_folder` only. Quick access
  and "Open folder" remain the only actions that re-root the explorer.
- Qt logs (including QML warnings) are routed to journald when stderr is not a
  TTY; evidence runs set `QT_ASSUME_STDERR_HAS_CONSOLE=1`.
- Symlinked folders were invisible as folders: `DirEntry::metadata()` never
  follows a link, so a link to a folder was listed as a file — it had no
  disclosure arrow, could not be expanded and was not navigable. The listing now
  resolves the link (`fs::metadata`, falling back to a plain file for a broken
  link) while keeping the link's own path.
- `canonicalize` on every user-visible path defeated the above: opening
  `photoslink` reported `photos` in the breadcrumbs, the tree root and the grid,
  so browsing a link teleported the user to its target. `ops::normalize_path`
  now cleans `.`/`..` lexically and leaves link resolution to the kernel;
  `canonicalize` is kept only for the copy-into-itself guard, where folding the
  link is exactly what is wanted.
- Copying a symlinked folder duplicated the whole target and produced a real
  folder in the destination; `copy_recursive` now recreates the link.
- The portal "Open folder" dialog never worked: the client called a
  non-existent `FileChooser.OpenFolder` method and, even for `OpenFile`, read
  the returned `QDBusObjectPath` with `QVariant::toString()` (always empty), so
  every request was treated as failed and silently replaced by the Qt dialog.
  Folders now use `OpenFile` + `directory: true`, the handle is read with its
  own accessor, and `Response` is subscribed on the predicted handle before the
  call so an early answer is not lost.
- The explorer root and the open folder were stored as one value
  (`config.last_folder`), and startup assigned it to both, so a session left with
  `~/Pictures` in the sidebar and `~/Pictures/Child` open reopened with the tree
  re-rooted at `Child`. They are now separate (`tree_root` + `last_folder`), and
  the tree follows the list only when the list leaves its subtree.
- `QTest::mouseMove` does keep the implicit grab taken by `mousePress`, so it
  drives a `MouseArea` drag; whole `QWindowSystemInterface::handleMouseEvent`
  moves injected that way never reached the item. The splitter tests use the
  former.

## Not verified here (honest gaps)

- No *physical* click was generated by this session, and keyboard interaction
  was not driven at all. Clicks on the workspace switcher, the explorer tree, the
  disclosure arrow, a grid cell and a breadcrumb are covered by
  `tests/qml/tst_browser.cpp`, which sends real `QTest` mouse events into the
  real QML sources and asserts on the emitted commands (rows 25–27); context
  menus, menu entries and the "copy image content" item are wired to the same
  commands but their click paths are not captured as evidence here.
- Portal dialogs are still not realised in this environment, so *user
  interaction* with them is unverified. What was verified is the client side:
  the portal service is present (`FileChooser` v4, `OpenURI` v5), it accepts our
  `OpenFile`/`OpenURI` calls and answers with the predicted request handle
  (`scripts/portal_probe.py` reproduces this independently of the app),
  and our own `Request.Close` is issued on dismissal. What was **not** seen: no
  dialog appeared and no `Response` was ever emitted — `dbus-monitor` recorded
  none, and the request object is gone immediately after the reply (a `Close`
  answers `UnknownMethod: Object does not exist`). This session has no user
  journal for `xdg-desktop-portal` (`journalctl --user` shows no entries), and a
  second instance cannot register the portal app ID (`Could not register app ID:
  Connection already associated with an application ID`), so the cause could not
  be attributed. The Qt fallback therefore still carries the real workload here.
- Resizable sidebars: the widths are memory-only. Nothing is persisted and no
  minimum window width is enforced, so a very wide left panel simply squeezes
  the grid; the drag itself is driven by `QTest` mouse events, not by a person.
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
- `docs/evidence/M1-explorer-root.png` (current folder `photos/sub` in the grid and the breadcrumbs while the tree stays rooted at `photos`)
- `docs/evidence/M1-tree-refresh.png` (after `move_to`: the tree row `after-refresh` left `photos/sub` and appeared at the `photos` level, with `sub` still expanded and still the folder on screen)

The browser and viewer screenshots above were captured before rows 25–27, so
they still show the icon-only mode buttons; `M1-explorer-root.png` shows the
current `<icon> <text>` toolbar.
- `docs/evidence/M1-editor.png`
