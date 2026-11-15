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
| Back from Viewer | Restore Browser selection, filter, scroll |
| Back from Editor | Viewer, honoring unsaved edit/draft policy |

## Explorer root contract
- The explorer tree is rooted at the folder an explicit open selected (quick
  access, `Open folder`, launch argument, or the restored `last_folder`).
- Clicking a folder in the tree expands it and shows that folder in the grid;
  double-clicking a folder in the grid, using a breadcrumb or going up navigates
  the same way. None of these re-root the tree.
- Only an explicit open moves the root: it is the one action that also persists
  `last_folder`.

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

## Command contracts
- `app.open_files { paths: Vec<PathOrUri>, activation: bool }` -> viewer state and navigation context.
- `app.open_folder { path: PathOrUri, activation: bool }` -> browser state.
- `workspace.switch { target, expected_revision }`; `workspace.back`.
- `editor.enter { image_id }` explicit; opening image must NOT silently enter Editor.
- Input parsing, drag/drop, shortcuts, IPC and MCP translate to the SAME typed commands.
- Handle Unicode, spaces, missing paths, unsupported formats, symlinks and permissions with structured errors.
- UI observes committed state revision; Qt may own hover/focus/animation only.

## Single instance
- A second invocation forwards open request to active app instance and activates the window when permitted.
- Startup races queue requests; do not open a second writer on the same SQLite DB.
- IPC identity and data directories must be separated between dev and production.

## Acceptance scenarios
1. Launch with no args: Browser visible; journal shows startup; no implicit Editor.
2. Launch with JPEG path: Viewer visible with correct image; file manager Open With works.
3. Launch with directory: Browser displays folder contents; double-click opens Viewer; back restores browser context.
4. Viewer -> Editor -> back: source image unchanged; draft/unsaved behavior explicit.
5. Repeat 2 and 3 with app already running; ensure single instance.
6. Run equivalent `kogactl`/MCP commands; compare state revision, events and observable results.
7. Check logs and screenshots from the real UI; tests passing alone are insufficient.
