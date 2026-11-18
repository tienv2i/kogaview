# Workspace and launch contract

## Three workspaces
- Browser: default startup; folders, thumbnails, library, search, sort and selection.
- Viewer: open one or more images, zoom, pan, fit, fullscreen, metadata, next/previous.
- Editor: explicit entry from Viewer; non-destructive recipe, preview, undo/redo and export.
- These are UI workspaces sharing one Core and state owner, not separate apps.

## Entry points (mandatory)
| Invocation | Expected behavior |
|---|---|
| `kogaview` | Start in Browser (unless explicit opt-in session restore policy) |
| `kogaview open FILE [FILE...]` | Start/switch to Viewer, open first file, navigation set contains supplied files |
| `kogaview FILE [FILE...]` | Alias for `open` |
| `kogaview open-folder DIR` | Start/switch to Browser, navigate to directory |
| File manager Open With image | Viewer |
| Browser double-click | Viewer |
| Viewer Edit | Editor |
| Main menu → Open in editor… | Editor, showing the chosen image (the explicit Editor entry point) |
| Back from Viewer | Restore Browser selection, filter, scroll |
| Back from Editor | Viewer, honoring unsaved edit/draft policy |

## Explorer root contract
- The tree root and the folder that is open are two different values, persisted
  as `tree_root` and `last_folder`. A session left with `~/Pictures` in the
  sidebar and `~/Pictures/Child` in the list comes back exactly like that: the
  two are restored independently, never collapsed into the deeper folder.
- The tree follows the list only when the list leaves the tree's subtree — a
  breadcrumb to an ancestor, the up button past the root, or any navigation to a
  folder outside it moves the root to that folder.
- Everything inside the subtree leaves the root alone: tree clicks, grid
  double-clicks and breadcrumbs down the tree, and also an explicit open (quick
  access, `Open folder`, launch argument) of a folder that is already in the
  tree. Opening the tree's own root is inside it, so it does not re-root either.
- On startup each saved path is validated on its own: the one that still exists
  wins and the other is derived from it (root → open, or open → root). Two
  missing folders mean nothing is open, like a first run.
- The toolbar exposes the same explicit open as the burger menu: an icon-only
  "Open folder" button. It asks the shell for the dialog (it never opens one
  itself) and the chosen folder re-roots the explorer, exactly like
  `kogaview open-folder DIR`.

## Symlinked folders
- A symbolic link to a folder is a folder everywhere: it is listed with the
  other folders, sorted with them, expanded, navigated and opened. Core decides
  this by resolving the link (`fs::metadata`), and a broken link stays a plain,
  unopenable file rather than disappearing from the listing.
- The link's *own* path is the path the app shows and remembers. Opening
  `photoslink` puts `photoslink` in the breadcrumbs, the tree root and the grid;
  it does not teleport to `photos`. This is why Core normalises user paths
  lexically (`ops::normalize_path`) instead of canonicalising them.
- Copying or moving a link copies or moves the link, and deleting it removes the
  link; the target and its contents are never touched. `canonicalize` survives
  only where folding the link is the point: refusing to copy a folder into
  itself through a link to it.

## Editor layout
- The header keeps only global actions: open, the zoom controls, Save / Save
  as…, Undo, Redo, Reset to original, back and close. The left **tool palette**
  lists Pointer, Resize, Crop, then Rotate/Flip; its labels are full width so
  none is elided at the 220 px default.
- **Pointer** is the no-op default and the Editor opens on it. Its right column
  shows the document title, size, save target, a cached thumbnail of the
  current preview and the session history. Resize and Crop replace that with their options
  (Width/Height for Resize, X/Y for Crop) and Apply/Apply crop. Clicking
  the selected Resize/Crop again returns to Pointer.
- **Resize links the two sides through a ratio.** The Ratio combo offers `Free`,
  `Original` and nine common ratios; typing one side recalculates the other, and
  only `Free` leaves them independent. The Size combo lists 47 concrete sizes,
  every side a multiple of 64 (for 1:1: 2048, 1536, 1024, 768, 512, 256), and
  picking one also selects the ratio it belongs to. Nothing is armed until the
  user acts: the list opens on `Custom` and Apply stays disabled while the
  fields are empty.
- **Resize has no anchor; Crop keeps its rectangle.** Where the cropped result
  sits is a Crop decision. When the target aspect differs, Core takes the
  centred cover rectangle before scaling, so pixels are never stretched.
- **Crop has the anchor, a ratio and fitting presets.** Width/Height link through
  the Crop Ratio combo (`Free`, `Original`, nine common ratios) exactly as Resize
  does, and the Size preset list offers only concrete 64-divisible sizes both of
  whose sides fit the document. The 3 × 3 anchor pad (four corners, four edges,
  centre; arrows plus an accessible name and tooltip for each) decides where a
  rectangle of that size sits: changing the size through the ratio, a preset or
  Reset re-places X/Y, while typing X/Y is the user's own placement. Apply stays
  disabled unless `x + width` and `y + height` stay inside the document.
- **Live preview renders the target without editing.** The Live preview toggle
  asks Core for a draft at the chosen size; the canvas draws that draft (and the
  zoom refits to it) while the status bar and history keep describing the real
  document. Crop uses the same draft, tagged `kind: "crop"`, so the canvas shows
  it only under Crop and never under Resize; toggling it off, leaving the tool,
  applying the edit, any other edit or undo/redo/reset drops the draft.
- **Pad to square runs before the scale.** Ticking it adds a fill colour picker
  (disabled while unticked) and Core pads the shorter side out to the longer one,
  centred, then takes the centred aspect cover and scales: a 1200 × 1600 portrait
  squared and scaled to 512 × 512 gets 64 px bands left and right of the
  picture. The history line names the fill
  (`Resize 512 × 512 · square #ff0000`).
- **The pointer thumbnail is the current preview, not the source.** It goes
  through the shared `ThumbnailCache`, which keys on the file's path *and* its
  mtime/size; Core publishes both for the preview, because the preview names
  restart at `preview-1.png` on every process and the path alone would let a
  cached thumbnail from an earlier run answer a new document.
- Selecting a tool or clearing its fields sends no command; Core still owns the
  history and the undo/redo state.

## Sidebar widths
- Both browser sidebars and both editor sidebars are resized by dragging the
  splitter at their inner edge (double-click restores the theme width). Each
  side has its own bounds so a panel can neither vanish nor swallow the centre
  pane, and hiding a panel hides its splitter.
- The width belongs to the view, the splitter only reports the dragged value, so
  nothing here writes state or persists to disk yet.
- The drag is measured in scene coordinates, never in the handle's own. The
  handle moves as the panel grows, so a handle-local `mouse.x` shrinks by exactly
  what the drag just added; fed back into the next move the panel advances by
  half the pointer's travel and alternates between two widths every frame
  (measured: 10/20/30/40 px of travel → 10/10/20/20 px of width), which the user
  sees as a lagging sidebar and a highlight line flickering in two places.

## Wheel scrolling
- Wheel scrolling goes through `WheelScroll.qml`, a `WheelHandler` subclass
  that takes the event before the view does and maps it deliberately: one notch
  (120 eighths of a degree) is `step` pixels, and a `horizontal` view scrolls
  from a vertical wheel.
- Two Qt defaults are wrong for a photo browser and are therefore replaced: Qt
  moves a view by ~72 px per notch whatever the item size (a third of a 194 px
  grid row, and the same 72 px for a 24 px tree row), and it only moves the axis
  the wheel reports, so a mouse wheel never moves a horizontal filmstrip at all.
- Steps are per view and set where the view is wired: the grid uses
  `cellHeight` (one row per notch), the folder tree 120 px, the quick-access
  list 96 px, the filmstrip 252 px (three tiles).
- A wheel event carrying `pixelDelta` (trackpad, touchscreen) is passed through
  unchanged, so continuous scrolling keeps its 1:1 feel; `angleDelta` is only
  used when there is no pixel delta.
- A handler cannot infer its view, so `view:` is set explicitly: a missing view
  scrolls nothing rather than silently scrolling the wrong item.

## Modal dialogs own the pointer
- Qt delivers pointer-handler events to items **under** a modal popup: the
  overlay blocks item events, not handler grabs, so a background `DragHandler`
  can win a drag that began on a dialog. `Main.qml` therefore disables the
  workspace `Loader` while `modalDialogOpen` is true — Settings, the
  unsaved-changes dialog, the delete confirmation and the fallback
  file/folder/save choosers.
- The Settings header moves the dialog in every workspace, and nothing pans or
  zooms behind the dialog; focus returns to the view when the loader re-enables.
  A `Menu` is modeless and deliberately not part of the gate.

## Keyboard operation
- Plain-key shortcuts live in the workspace that owns them — `Keys.onPressed`
  on `BrowserView.qml` and `Viewer.qml` — not in a window-wide `Shortcut`, which
  would also fire while a text field, menu or dialog has the keyboard. Other
  `Ctrl` and `Alt` combinations stay in `Main.qml`; the Browser's Ctrl+A is the
  one modified key a view owns.
- Viewer: Left/PageUp/Shift+Space previous, Right/PageDown/Space next,
  Home/End first/last (`viewer_open`), Up/Down pan 60 px, `+`/`=` zoom in,
  `-`/`_` zoom out, `0`/`1` actual size, `F` fit, `R` rotate right (Shift+R
  left), `H`/`V` flip, `T` toggle the filmstrip, Delete trash once, and
  Escape/Backspace back to the Browser.
- Browser: arrows move the grid selection (Up/Down by a real row), PageUp/PageDown
  by a viewport, Home/End to the listing's ends, Enter opens the keyboard cursor,
  Backspace goes to the parent, Ctrl+A selects the listing, Escape clears the
  selection (`select []`) and Delete trashes it once.
- Keys translate to the same typed commands a click emits: `select`, `navigate`,
  `open_file`, `viewer_next`/`viewer_previous`/`viewer_open`, `trash`,
  `toggle_filmstrip`, `set_workspace`. Zoom, pan, rotate and flip are Qt
  presentation state and emit no command, exactly like their toolbar buttons.
- Focus belongs to the view: both workspace roots are `focus: true` and take
  active focus on completion, while non-text controls that would otherwise eat an
  arrow (breadcrumb ellipsis, tree chevron, footer Cancel) are `Qt.NoFocus`.
- The Browser's keyboard cursor is presentation-only: Core owns `selection`, and
  the view only remembers the cell the next arrow walks from.
- A key with no image does nothing, and Delete ignores `isAutoRepeat`, so holding
  the key trashes once rather than walking the folder into the trash.
- Window-level keys: Ctrl+O/Ctrl+Shift+O (file/folder), Ctrl+S/Ctrl+Shift+S
  (Editor save/save-as), Ctrl+Q (quit), F5 (refresh) and Ctrl+1/2/3 (Browser/
  Viewer/Editor). Workspace switches go through the same guarded Editor-leave
  path as the switcher buttons.
- Tooltips name the shortcut of the control they describe, in the form
  `Rotate left (Shift+R)`. A control without a shortcut keeps its text plain, so
  a tooltip never advertises a key that does nothing.

## Explorer refresh contract
- Every operation that can change the folder tree on disk (copy, move, trash,
  delete, new folder, explicit refresh) bumps `treeRevision` once it completes.
  Merely selecting, navigating or switching workspace does not.
- When `UiState.tree_revision` changes the explorer rebuilds its rows from
  `list_folders` — including the already-expanded levels below the root — and
  keeps two things: the node expansion the user chose (a node they collapsed
  stays collapsed) and the folder currently on screen. The tree never navigates
  or re-roots itself as a side effect of a refresh.
- The reborn rows restore their expansion from the view-level `expandedPaths` /
  `collapsedPaths` maps, which outlive the nodes, and `followCurrent()` re-opens
  the path towards the current folder without overriding a manual collapse.
- Rationale: a change two levels down leaves the parent listing byte-identical,
  so no delegate is recreated and a one-level reload would keep showing stale
  grandchild rows while the grid was already fresh.

## Thumbnail cache contract
- The grid, the preview panel and the filmstrip never decode a full image to
  draw a small one. `ThumbnailCache` (C++) turns each image into one small file
  per (path, size, mtime, requested edge) under
  `$XDG_CACHE_HOME/kogaview[-dev]/thumbnails` and answers each tile directly.
- The key is a stable FNV-1a hash of `v3|path|edge|modified|size`, not
  `std::hash`/`QHash` (both are salted per process and would orphan every file
  after a restart). It carries mtime and size, so an edited image simply misses:
  there is no invalidation step and no way to show stale pixels. The extension
  records what was written — `.jpg` for opaque, `.png` when the source has
  transparency — and a `.fail` marker records an undecodable source so it is not
  retried on every scroll.
- The edge is bucketed (160/256/384/512/768, request twice the drawn size), so
  resizing the window reuses a neighbouring bucket instead of minting an entry
  per pixel width. `Qt::KeepAspectRatio` fit, EXIF orientation honoured, atomic
  write through `QSaveFile`.
- **Answers are targeted, not broadcast.** `request()` names the object that
  wants the thumbnail (`CachedThumbnail.qml`, the tile's `Image`); when the entry
  is ready only that object's `setThumbnail(key, url)` is called, on its own
  thread. There is no shared key → url map in QML: a map has to live in an
  observable property, reassigning it re-evaluates every binding that read it,
  and that turned one finished thumbnail into a re-evaluation of every tile on
  screen — 159 244 `keyFor` calls in a 12 s scroll through a 1 200-image folder.
- A tile asks **once per (entry, bucket)**: it waits until it has a drawn size and
  the version it keys on, then asks (`CachedThumbnail`'s settle timer), so a cold
  visit writes one entry per bucket actually drawn instead of one per
  intermediate layout state, and a tile recycled before the timer fires never
  mints a thumbnail for an image that already scrolled past.
- Decoding is rate-limited: half the cores, at most three threads, newest request
  first. Serving the queue in arrival order — or on every core — answers tiles
  that already left the screen and starves the thread that draws the window.
- A hit costs a hash lookup: known entries live in memory (`key → file`), so a
  hit neither stats the filesystem nor rewrites the entry. Eviction keeps the
  directory under a byte budget (256 MB, aims at 90% when it runs) and drops the
  least recently **used** entry first; use is tracked in memory and written back
  to the entry's mtime only on its first use in a session, which is what makes the
  order survive a restart without a file rewrite per tile per scroll. Failure
  markers count as zero bytes.
- Without a cache object the views fall back to `file://<path>`.

## Command contracts
- `app.open_files { paths: Vec<PathOrUri>, activation: bool }` -> viewer state and navigation context.
- `app.open_folder { path: PathOrUri, activation: bool }` -> browser state.
- `workspace.switch { target, expected_revision }`; `workspace.back`.
- `editor.enter { image_id }` explicit; opening image must NOT silently enter Editor.
- Input parsing, drag/drop, shortcuts, IPC and MCP translate to the SAME typed commands.
- Handle Unicode, spaces, missing paths, unsupported formats, symlinks and permissions with structured errors.
- UI observes committed state revision; Qt may own hover/focus/animation only.
- The window renders one snapshot, published in two halves because they change
  at different rates: the metadata (workspace, folders, selection, counts,
  status — around a kilobyte, no listing fields) after every command, and the
  folder listing (`entries`, `viewerImages` — ~200 bytes per item) only when its
  `listingEpoch` moves. Both come from Core; `crates/desktop/qml/StateSnapshot.qml`
  keeps the parsed listing between snapshots, so a `select` is one small parse
  and the grid keeps its delegates. A broken half is refused without blanking
  the other.

## Single instance
- A second invocation forwards open request to active app instance and activates the window when permitted.
- Startup races queue requests; do not open a second writer on the same SQLite DB.
- IPC identity and data directories must be separated between dev and production.

## Acceptance scenarios
1. Launch with no args: Browser visible; the startup record (`kogaview::startup`, in `logs/kogaview.jsonl.<date>`) shows the app starting and no `journal/commands.jsonl` line sets a workspace (`set_workspace`), so there is no implicit Editor.
2. Launch with JPEG path: Viewer visible with correct image; file manager Open With works.
3. Launch with directory: Browser displays folder contents; double-click opens Viewer; back restores browser context.
4. Viewer -> Editor -> back: source image unchanged; draft/unsaved behavior explicit.
5. Repeat 2 and 3 with app already running; ensure single instance.
6. Run equivalent `kogactl`/MCP commands; compare state revision, events and observable results.
7. Check logs and screenshots from the real UI; tests passing alone are insufficient.
