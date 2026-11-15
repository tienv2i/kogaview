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
  image and text clipboard, external open, folder reveal and the portal `OpenFile`
  application chooser behind "Open with…".
- QML shell: three `<icon> <text>` workspace switcher buttons (Browser, Viewer,
  Editor), per-workspace toolbar, burger menu
  (open file, open folder, theme toggle, exit), centred content and a status bar.
- Browser: quick access + explorer-style folder tree, collapsible one-row
  breadcrumbs, responsive async thumbnail grid, preview/metadata sidebar with a
  toggle, context menus for files, folders and quick-access entries sized to their
  longest label, Viewer filmstrip scrolled by the mouse wheel.
- Thumbnail cache (`cpp/thumbnailcache.{h,cpp}`): one small file per (image,
  size, mtime, requested edge) under `$XDG_CACHE_HOME/kogaview[-dev]/thumbnails`,
  generated off the GUI thread, keyed by a stable FNV-1a hash so entries survive
  a restart, evicted least-recently-used against a byte budget, with EXIF
  orientation honoured and undecodable sources remembered so they are not
  retried. Answers are **targeted**: a tile asks for its own key and is called
  back on its own `setThumbnail(key, url)`, so one finished thumbnail cannot
  re-evaluate the rest of the grid, and hits are answered from an in-memory
  index without touching the filesystem. Decoding runs on a small fixed pool
  (half the cores, at most three threads) that takes the newest request first.
  The grid, the preview panel and the filmstrip all draw from it.
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
| 2 | Tests | `just test` | PASS: 34 core + 3 protocol Rust tests, then 16 Qt Quick viewer tests, 27 Qt Quick browser/explorer tests and 15 thumbnail-cache tests |
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

| 37 | Thumbnail cache: one small file per (image, size, mtime, edge) | `kogaview_browser_cache_tests` (`tst_thumbnails.cpp`) driving the real `ThumbnailCache` over temporary images: `generatesOneFilePerImageAndEdge`, `aCachedEntryIsAnsweredWithoutReEncoding`, `aChangedImageGetsANewEntry`, `anUndecodableImageIsRememberedAsFailed`, `transparencyDecidesTheEncoding`, `orientationFromExifIsHonoured`, `aRestartFindsTheExistingEntries`, `evictionKeepsTheCacheUnderBudget`, `evictionIsLeastRecentlyUsed`, `decodingNeverUsesTheWholeMachine`, `answersOnlyTheObjectsThatAsked`, `aHitDoesNotRewriteTheEntry`, `clearRemovesEverything` | a 1600x1000 JPEG asked at edge 256 gives a 256x160 file, asked at 128 a second 128x80 file, and the original is untouched. A hit answers while the source file has been deleted — no decode warning is logged, `bytesUsed` and the entry count do not change — so it reads the cache and nothing else. Changing only the mtime, then only the size, each mints a new entry (3 for one path). A 400x200 JPEG whose EXIF says orientation 6 gives a 128x256 (upright) thumbnail; transparency survives as `.png` while opaque images stay `.jpg`, and the `.png` is found again by a later lookup after the source is gone. A second cache object over the same directory reports the same `bytesUsed` and answers the cached url. 8 entries against a 40 KB budget keep `bytesUsed` under it with fewer files than were generated, and no dangling entries. Eviction drops the least recently *used* entry: A, B, hit A, then C evicts B and keeps A. `clear` removes thumbnails and failure markers and the cache rebuilds afterwards. Each request names a requester object and is answered only through that object's `setThumbnail(key, url)`: a tile that asked gets the answer, a bystander that never asked does not, and a hit answers the caller without rewriting the entry — after five hits on one entry the file's mtime is unchanged, while the first use of a session does write it back so the LRU order survives a restart. `decodeThreads()` reports a pool of half the cores capped at three, and the test fails if it ever equals the core count |
| 38 | Grid, preview panel and filmstrip draw the cached thumbnails | `tests/qml/tst_browser.cpp` (`gridDrawsTheCachedThumbnail`, `previewDrawsTheCachedThumbnail`, `AFailedThumbnailFallsBackToTheOriginal`, `aRecycledTileIgnoresTheAnswerForAnotherEntry`) and `tests/qml/tst_viewer.cpp` (`filmstripDrawsCachedThumbnails`) against a stub cache object with the same shape as `ThumbnailCache` (requester-based `request`, answers delivered to the requester's `setThumbnail`) | the grid asks for the tile with the entry's `size`/`modified` and a bucketed edge (>= 160), draws **nothing** until the thumbnail arrives (so the placeholder shows instead of a second decode), then draws exactly the url the cache delivered; the folder in the same folder is never sent to the cache. The preview panel does the same for `selectionInfo`, and both return to `file://<path>` when the cache object is absent. The filmstrip looks the size/mtime up in the folder listing (`viewerImages` carries paths only), falls back to the original for a path the listing does not have, and returns to the original without a cache. An undecodable image falls back to the original tile and is not asked for again after the failure is reported. A tile that is handed the answer for another key — the case a recycled grid cell hits — drops it and still accepts its own answer |
| 39 | Cache and thumbnail-wiring regression check | 12 mutations applied one at a time to a backed-up copy of the real source — 10 in `cpp/thumbnailcache.cpp` and 2 in `CachedThumbnail.qml` — each rebuilt and re-run against the cache, browser and viewer suites, then reverted (`/tmp/opencode/mutation_check.py`) | **12/12 caught.** C++: drop the mtime from the key, drop the size from the key, drop `setAutoTransform`, ignore the `.fail` marker, always encode JPEG, rewrite the entry on every hit (`if (entry->persisted)` → nothing), never call the requester back, answer nobody after a decode, never evict, decode on every core. QML: ignore a stale key on the tile, never ask for a thumbnail. Three of them were initially **missed** — the "every core" and both QML ones — because no test looked at them: adding `decodingNeverUsesTheWholeMachine` and `aRecycledTileIgnoresTheAnswerForAnotherEntry`, plus the existing grid/preview expectations, turned all three into failures. The previous revision of this row listed mutations of the broadcast `key → url` map that no longer exists; this is the re-run over the targeted-delivery design. The 12-way sweep was a one-off script in `/tmp`; the rule drawn from it (`AGENTS.md` working-loop step 8) is to keep mutation checks selective and report them mutation by mutation, not to build a mutation framework |
| 40 | Thumbnail cache on the real binary: cold, then warm | `KOGAVIEW_DEV_COMMANDS`/`KOGAVIEW_DEV_STATE` on `build/dev/bin/kogaview` with `XDG_*` redirected to `/tmp/opencode/kvT`, over `/tmp/opencode/gallery` (6 × 3000x2000 JPEGs, a 2000x3000 portrait, a 3000x2000 JPEG whose EXIF says orientation 6, a 1600x1200 RGBA PNG and a 19-byte `broken.jpg`), plus `ls`/`du` on the cache directory | cold run: the directory starts empty and ends with 9 thumbnails (8 `.jpg`, 1 `.png`) plus 1 `.fail` marker, 296 KB in total, `entries 9 bytes 278609 generated 9`, and **one** `cannot decode` warning: a tile now asks once per (entry, bucket) instead of once per intermediate layout state, so the broken file is not decoded for three different sizes while the grid settles. Warm run over the same folder: startup reports `entries 9 bytes 278609` (the files are found and counted by `scanExisting`), then `hits 20 generated 0`, the directory listing is byte-identical before and after (same size, same name hash), and **no** `cannot decode` warning appears — the marker stopped the retry. Opening the Viewer asks for the buckets the filmstrip and the preview panel draw at: `entries 27 bytes 492963 hits 20 generated 18`, and the directory ends at 31 files (25 `.jpg`, 3 `.png`, 3 `.fail` — one marker per bucket asked for `broken.jpg`), 628 KB. `docs/evidence/M1-thumbnails.png` shows the grid and the preview panel drawn from the cache — `rotated-by-exif.jpg` upright in the preview (portrait, although the file says 3000x2000) while its grid cell is selected, `broken.jpg` an empty tile — and `docs/evidence/M1-thumbnails-filmstrip.png` the filmstrip drawing the same tiles, the EXIF-rotated one upright |
| 41 | Viewer → Browser switch on a photo folder (the reported "khựng") | `KOGAVIEW_DEV_LAG` on `build/dev/bin/kogaview`: a 4 ms precise timer whose lateness is reported once a second, so `worst_ms 43` means the GUI thread was not free for 43 ms in that second; command sequence `open_folder` → `open_file` → `set_workspace viewer` → `set_workspace browser` over 150 × 2016x1512 JPEGs, `XDG_*` in `/tmp/opencode/kvA*`, 9 s per run, run against the previous build (`HEAD`) and the reworked one with the same probe | previous build, cold: 187 ms in the first second (177 of 250 timer ticks fired), then 9, 6, 43 ms, and 3 568 cache answers over the run; warm: 21, 17, 3, 41 ms with 1 104 answers. Reworked, cold: 15, 16, 6, 22 ms (247, 246, 250, 245 ticks) with 17 answers; warm: 15, 11, 5, 29 ms with 90. The remaining 22–29 ms spike is the workspace switch building 150 grid delegates — the cache is not involved in it and the no-cache run shows it too. CPU for the run: 1.19 s → 0.71 s cold, 0.55 s → 0.46 s warm |
| 42 | Cache on vs cache off on a 1 200-image folder, old build vs new | same probe over 1 200 × 1200x900 JPEGs, one page of grid scroll every 250 ms for 12 s; `KOGAVIEW_DEV_NO_THUMBNAILS` supplies the *same binary* with no cache object, which is what separates "the cache does work" from "the cache does work on the GUI thread" | previous build, cold: 12–119 ms of stall per second and 35–85 of the 250 ticks missed, 4 695 answers, 1 284 thumbnails written, 11.74 s CPU. Previous build, warm: 10–35 ms and 22–60 ticks missed, 4 227 answers for 402 entries' worth of tiles, 3.94 s CPU. **No cache at all (same binary): 4–9 ms and 2–6 of the 250 ticks missed, 3.22 s CPU** — the old cache was both slower *and* jankier than not having a cache. Reworked cache, cold: 5–8 ms and 4–10 ticks missed (plus one 31 ms second for the initial folder scan), 393 thumbnails written, 5.36 s CPU; warm: 4–7 ms and 2–7 ticks missed, 428 answers, 3.04 s CPU. So the stalls and the ~10× redundant answering are gone and the cold CPU cost is the price of actually producing the files rather than of running them on the wrong thread |
| 43 | Why it was jankier than no cache | the probes above plus counters added to `keyFor`/`request`/the touch path on the previous build, and the A/B in row 42 | three causes, each measured on the old build: (1) `ThumbnailBook.qml` kept a `key → url` map in an observable property, and a property must be *reassigned* to notify — so one finished thumbnail re-evaluated every binding that had read the map; a counter showed 159 244 `keyFor` calls (one per binding evaluation) in the 12 s scroll run that produced 1 284 thumbnails; (2) a hit rewrote the entry's file to record the use, i.e. one file rewrite per answer on the GUI thread — 3 568 rewrites in the 150-photo cold run, the same number as the 3 568 answers — plus a `stat` of the cache directory per request; (3) decoding ran through `QThreadPool::globalInstance()`, so 8 decoders competed with the thread that draws the window. Warm-CPU was already close to no-cache's (3.94 s vs 3.22 s before the rework), i.e. the problem was never *how much* work but *where* it ran |
| 44 | Sidebar drag keeps up with the pointer | `tests/qml/tst_browser.cpp` (`splitterFollowsThePointerAcrossFrames`) dragging the real left splitter 80 px in 8 × 10 px steps with one 16 ms frame between the steps; plus a temporary 60 Hz probe (`KOGAVIEW_DEV_RESIZE`, added to `cpp/main.cpp` for the measurement and removed again) stepping `leftPanelWidth` 260 ↔ 460 over `/tmp/opencode/kvBig` (1 200 images) with the `KOGAVIEW_DEV_LAG` meter running | before the fix the panel advanced by **half** of the pointer's travel and alternated between two widths as frames went by: pointer travel 10/20/30/40/50/60/70/80 px gave widths 10/10/20/20/30/30/40/40, which is the "two blue border lines" report. The drag was reading the pointer in the handle's own coordinates and the handle moves with the panel, so every move fed the drag back into itself; reading it in scene coordinates makes the drag 1:1, and the width now equals `before + travel` on every frame. Frame cost is *not* the cause: with the sidebar resized at 60 Hz the worst lateness of a 4 ms precise timer was 3–8 ms per second against 1 ms idle (one width change costs ≤ 0.8 ms on the GUI thread), so no part of the layout had to be made faster |
| 45 | One wheel notch moves a view by a row instead of Qt's 72 px | `tests/qml/tst_browser.cpp` (`oneWheelNotchScrollsTheGrid`): 200 entries in a 194 px-row grid, one `angleDelta` −120 notch delivered through `QWindowSystemInterface`; the folder tree and the quick-access list use the same `WheelScroll` component | before: one notch moved `contentY` by 72 px — a third of a cell — which is the "scroll quá chậm" report; Qt moves a view by ~72 px whatever the item size. After: `WheelScroll { step: grid.cellHeight }` moves it 194 px (the test asserts ≥ 0.9 of a row), the tree 120 px and quick access 96 px. A mutation putting `notches * 72` back is caught by that test. The trackpad path is untouched: a wheel event *with* `pixelDelta` is passed through 1:1, so smooth two-finger scrolling keeps its feel and the zoom tests (rows 21–24) still pass |
| 46 | Viewer filmstrip follows a mouse wheel, both ways | `tests/qml/tst_viewer.cpp` (`theFilmstripScrollsWithTheWheel`, `theFilmstripFollowsATouchpad`): 40 images in `viewerImages`, a mouse notch and then a touchpad gesture over the middle of the strip; plus the real binary on `/tmp/opencode/kvGallery` with `KOGAVIEW_DEV_FILMSTRIP_WHEEL=1`, which sends notches through `QCoreApplication::sendEvent` to the window once the strip has a real width | before: `contentX` stayed 0. The strip is a horizontal `ListView` and Qt only moves the axis the wheel reports, which for a mouse wheel is the vertical one, so the filmstrip ignored it while the canvas under it zoomed instead. After: a notch *down* advances the strip (down = "towards the user" = next images, the direction the grid scrolls) and a notch *up* goes back; a touchpad's `pixelDelta` is followed 1:1 in the same directions; the canvas zoom does not change either way. On the real window: `contentX 0 -> 252 -> 504 -> 252` for notches −120, −120, +120 with zoom 0.408333 before and after, from a strip of 12 594 px in a 1 264 px viewport. Mutations caught (each rebuilt, run, then restored): `dx = -notches * step` → `+` fails both tests; `pixelDelta.x - pixelDelta.y` → `+` fails both; dropping `acceptedDevices: PointerDevice.AllDevices` fails only the touchpad test (the mouse path keeps working, which is what made this easy to miss); removing the `contentX` assignment fails both. |

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
has expanded and a `KogaView dev thumbnails:` line (entries, bytes, hits,
generated, directory), which is how "the sidebar root and the open folder are two
values", "navigation only re-roots when it leaves the subtree", "a file operation
refreshes the tree without losing the open position" and "the second run is
answered from the cache" are checked from a log.

Three hooks exist for the platform paths that normally need a click:
`KOGAVIEW_DEV_UI_REQUEST=open-folder|open-external|open-with` invokes the browser's
`requestOpenFolder`/`openExternal`/`openWith` signal after
`KOGAVIEW_DEV_UI_REQUEST_DELAY_MS` (argument in `KOGAVIEW_DEV_UI_REQUEST_ARG`,
optional `…_REPEAT_MS` to fire it again), `KOGAVIEW_DEV_PORTAL_DISMISS_MS` closes
the portal dialog through `PlatformHelper::dismissActiveDialog`, and
`KOGAVIEW_DEV_SCREENSHOT` captures the window. `KOGAVIEW_DEV_UI_REQUEST=context-menu`
is the fourth: it opens `fileMenu` on `…_ARG` (or `folderMenu` without one), which
is how rows 48 and 49 photograph a menu rather than a click. They go through the
same signals
and helpers the UI uses, so a log line proves the real path was taken — but they
are still synthetic triggers, not a person clicking (see the gaps).

The repeatable part of this is not the hooks: `just test` runs three C++ suites
that load the unchanged QML sources and assert on what Qt Quick actually does —
`tests/qml/tst_viewer.cpp` (transform maths and injected mouse/touchpad wheel
events, and the filmstrip), `tests/qml/tst_browser.cpp` (real clicks on the
workspace switcher and the explorer, asserted through the commands the views
emit, plus the grid and preview thumbnails) and `tests/qml/tst_thumbnails.cpp`
(the cache itself: keys, hits, eviction, EXIF, failure markers). These
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
| 47 | A click in a large folder does not re-serialise, copy and re-parse the whole listing | `just test` (`kogaview_state_tests`, `tst_statesnapshot.cpp`), a temporary probe in `crates/desktop/src/bridge.rs` (`KOGAVIEW_PERF`, removed again) timing `Core::folder_json`/`meta_json` on every `refresh_properties`, and the real binary on `/tmp/opencode/kvBig` (1 200 × 1200x900 JPEGs) with `KOGAVIEW_DEV_LAG` while `open_folder` + 3 × `select` ran | before: `stateJson` was the whole snapshot — 199 212 bytes, 16.5 ms to serialise — re-published, copied into the bridge and `JSON.parse`d in QML after *every* command, so a select cost 12–26 ms of GUI-thread work and the grid model was handed a new (equal) array each time. After: the metadata string carries **no** listing fields at all (654–868 bytes, 0.03–0.14 ms per refresh) and the listing travels under its own `listingEpoch` (198 558 bytes, 8.3 ms) only when the folder listing actually changes; a select re-publishes 841 bytes. `StateSnapshot.qml` keeps the parsed listing between snapshots (the `strictlyEquals` checks in `kogaview_state_tests` assert the array is the same object), so the grid is not rebuilt for a metadata-only change. The worst lateness of a 4 ms timer during the same sequence is 1–6 ms after the second second (33 ms in the first, the initial scan of 1 200 files). Editor/Viewer switches over the same folder measured 1–6 ms after their first second |
| 48 | Context menus are as wide as their longest label | `tests/qml/tst_browser.cpp` (`contextMenusFitTheirLongestLabel`, `aLongLabelWidensTheMenu`) opening the real `fileMenu`/`folderMenu`/`quickMenu`, reading each rendered `MenuItem`'s `contentItem` label position and comparing the room left for it with `QFontMetricsF`; and the real window under `QT_QPA_PLATFORM=offscreen` with `KOGAVIEW_DEV_UI_REQUEST=context-menu`, grabbed by `KOGAVIEW_DEV_SCREENSHOT` (`/tmp/opencode/menu-final2.png`) | before: the default Qt Quick Controls style this session runs (`QT_STYLE_OVERRIDE` is not set by the app; the measured metrics are the ones this machine's default style produces) fixes every `MenuItem` at `implicitWidth: 200`, so a longer label was elided mid-word — reproduced on the real window with a probe label, "Open with system application (…" and "Delete permanently (…) — grou…". The label is drawn at `entry.x` 6 (the entry's left padding) and its own width is exactly the text advance, so the menu needs `text + 6 + 6` plus its 1 px border each side; a QML measurement cannot do it because `Menu.font` follows `Menu.implicitWidth` (a `TextMetrics` in the menu loops the binding, measured: dozens of "Binding loop detected" per frame), and Qt 6.12 also refuses to re-evaluate a binding that calls a function with side effects. So `Platform.textWidths` measures the fixed list `Theme.menuEntryLabels` in C++ once at startup, `Main.qml` stores the widths on its theme and `Theme.menuWidth(widths)` turns them into `max(168, ceil(widest) + 12)`. After: the file menu is 168 px and every label is whole (`piping` the real window); with a 290 px probe label the same menu grows to 327 px. The floor of 168 px is why the three real menus are all 168 px at this font: the widest real label ("Remove from quick access", 148.4 px) fits it, so only a longer label shows the resize — which is what `aLongLabelWidensTheMenu` feeds it. Mutation caught: pinning `fileMenu` back to `implicitWidth: 200` fails `aLongLabelWidensTheMenu` ("the menu stayed 200 px while a 306.266 px label was listed"); restored, it passes. Pinning it on the *default* labels does not fail, because 168 px already covers them — recorded here so the test is not mistaken for a stronger one than it is |
| 49 | "Open with…" asks the desktop for its application chooser | the real binary on this GNOME Wayland session with `KOGAVIEW_DEV_UI_REQUEST=open-with`, grepping the journal-free stderr; a PyGObject probe (`/tmp/opencode/portalprobe.py`) issuing the same call independently; `gdbus introspect` and `busctl introspect` of the portal; `gio help open` | the entry is now "Open with…" and emits `BrowserView.openWith`, which `Main.qml` forwards to `Platform.openWith`; it does *not* call `openExternally` any more (asserted by `openWithAsksTheDesktopForAnApplicationChooser`, which activates the entry and requires `openWith` once and `openExternal` zero times). `PlatformHelper::openFileWithChooser` calls `org.freedesktop.portal.OpenURI.OpenFile` with `ask: true` and is gated on OpenURI version ≥ 2; the portal here reports version 5. `OpenFile` takes a file descriptor, not a URI — the first implementation passed a string and got "Type of message, "(ssa{sv})", does not match expected type "(sha{sv})"" from D-Bus, now it opens the file and sends a `QDBusUnixFileDescriptor`. Real log: `KogaView portal: OpenFile (ask) "file:///tmp/opencode/kvGallery/photo-012.jpg" handle "/org/freedesktop/portal/desktop/request/1_730/kogaview_103753_1"`, and the independent probe gets a handle too. Windows uses `rundll32.exe shell32.dll,OpenAs_RunDLL`. **Not verified:** that the chooser window is actually drawn. This GNOME back end does not implement `org.freedesktop.impl.portal.OpenURI` (only `gnome.portal`/`gtk.portal` provide `AppChooser`, and `xdg-desktop-portal-gnome` logs "Failed to associate portal window with parent window"), the portal sent no `Response` within 5–6 s for either KogaView or the bare `gdbus`/PyGObject probes, and no screen capture is available on this session (`grim`: "compositor doesn't support the screen capture protocol", no `gnome-screenshot`, empty `_NET_CLIENT_LIST`). `gio open --ask` does not exist upstream (checked: `gio: Unknown option --ask`), so it is not a fallback. When no chooser is available `openWith` opens the default handler and logs a warning rather than showing an error |

## Not verified here (honest gaps)

- No *physical* click was generated by this session, and keyboard interaction
  was not driven at all. Clicks on the workspace switcher, the explorer tree, the
  disclosure arrow, a grid cell and a breadcrumb are covered by
  `tests/qml/tst_browser.cpp`, which sends real `QTest` mouse events into the
  real QML sources and asserts on the emitted commands (rows 25–27); context
  menus, menu entries and the "copy image content" item are wired to the same
  commands; the menus' *width* and the "Open with…" entry are asserted (rows
  48–49), but a right click itself was never generated by this session. The
  pictures of an open menu come from `KOGAVIEW_DEV_UI_REQUEST=context-menu`,
  which pops the menu up through the same `popup()` a right click calls.
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
- "Open with…" (row 49) reaches the portal and gets a request handle, but the
  application chooser was not seen. On this GNOME session no back end implements
  `org.freedesktop.impl.portal.OpenURI` and `xdg-desktop-portal-gnome` logs
  "Failed to associate portal window with parent window"; neither KogaView nor
  an independent `gdbus`/PyGObject probe received a `Response` in 5–6 s, and no
  screen capture is possible here (`grim`: "compositor doesn't support the screen
  capture protocol"; no `gnome-screenshot`; empty `_NET_CLIENT_LIST`). Whether
  GNOME or KDE actually *draws* the chooser is therefore the owner's interactive
  check, and the Windows `rundll32.exe shell32.dll,OpenAs_RunDLL` path was not
  run at all on this machine.
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
- The thumbnail cache is disk-first on purpose: what lives in RAM is the
  `key → file` index inside `ThumbnailCache` plus one pending entry per tile that
  is waiting for an answer (a few hundred bytes each), not decoded pixels —
  `Image.cache` stays `false` for the tiles, so Qt's own pixmap cache is not a
  second, invisible copy of the gallery. A tile therefore re-decodes a ~10 KB
  thumbnail from disk when it scrolls back, measured here as indistinguishable
  from a hit; a decoded-pixmap LRU with its own budget is not implemented.
- The edge buckets (160/256/384/512/768) keep a resize from minting an entry per
  pixel width, and `CachedThumbnail` asks once, after the size and the version it
  keys on have settled, so a cold visit writes one file per bucket an image is
  actually drawn at instead of one per intermediate layout state (10 files for 9
  images above, against 28 for the same folder before). An image drawn in two
  places at two sizes — grid tile and preview panel, or filmstrip — still gets one
  file per bucket, and nothing prunes the losing buckets after a resize.
- Wheel scrolling (rows 45–46) was driven with injected
  `QWindowSystemInterface` wheel events under `QT_QPA_PLATFORM=offscreen`: no
  physical wheel or touchpad gesture was turned by this session. Only the grid
  and the filmstrip have a test of their own — the folder tree (120 px) and the
  quick-access list (96 px) use the same `WheelScroll` component with an explicit
  `step` but nothing asserts their distance, and nothing asserts that a horizontal
  touchpad swipe scrolls a vertical view, which it deliberately does.
- The responsiveness figures (rows 41–43) were measured with
  `QT_QPA_PLATFORM=offscreen` (software rendering) on this 8-core machine, with
  the meter in-process. They compare like with like — same probe, same fixtures,
  same machine, old build against new and cache against no cache — but the
  absolute milliseconds would differ on a compositing session, another core
  count or a slower disk.
- There is no user-facing "clear thumbnail cache" action or size setting; the
  budget is the built-in 256 MB and `ThumbnailCache::clear()` is only reachable
  from the dev harness and the tests.
- Cache eviction is per file, not per folder, and it is not aware of a file
  being replaced: an edited image simply leaves its old entry behind until the
  budget pushes it out.
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
- `docs/evidence/M1-root-vs-open.png` (tree rooted at `photos` while the list shows `photos/sub`, both restored from the configuration)
- `docs/evidence/M1-thumbnails.png` (grid and preview panel drawn from the thumbnail cache; the EXIF-rotated photo is upright, the undecodable one is an empty tile)
- `docs/evidence/M1-thumbnails-filmstrip.png` (Viewer filmstrip drawing cached 160 px tiles)

The browser and viewer screenshots above were captured before rows 25–27, so
they still show the icon-only mode buttons; `M1-explorer-root.png` shows the
current `<icon> <text>` toolbar.
- `docs/evidence/M1-editor.png`
