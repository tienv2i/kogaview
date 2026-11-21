# ADR 0020 — One right dock for the three workspaces, and a tool zone that hugs its content

- Status: accepted
- Date: 2026-11-22
- Related: ADR 0019 (the Editor's split dock), ADR 0018 (the tool rail and
  view-only presentation state), ADR 0012 (sizing is a dialog), ADR 0015/0017
  (the measured toolbar), ADR 0002 (the configuration file), ADR 0004 (export)

## Context

The three workspaces had three different right-hand columns:

1. **The Browser's** was an inline preview plus a metadata grid, drawn with its
   own splitter and its own `rightPanelWidth`.
2. **The Viewer's** did not exist: the file's type, size, dimensions, mtime and
   path were only in the Browser's column, and a picture opened with
   `kogaview open FILE` had nowhere to show them.
3. **The Editor's** was ADR 0019's split dock: a fixed 440 px tool zone, a
   draggable divider, and Info / History / Preview tabs.

Four problems came out of using it:

- **The fixed zone left a hole.** Brush's options stop around 300 px, so a
  440 px zone put 140 px of empty column between the last field and the action
  row; a short window still scrolled a ScrollView that was taller than the zone
  it was in, because `Layout.maximumHeight` on a `ScrollView` is not honoured.
- **The divider was a third thing to drag** in a column that already has a
  splitter, and it had to be clamped so the tabs could not disappear.
- **`Preview` was the working preview, not the file.** After a save-as the tab
  drew Core's in-memory render, so "what is on disk?" — the question the tab's
  name implies — had no answer.
- **Visibility was mostly a Browser idea.** Hiding the right panel was one
  `config.json` boolean, and the Editor's dock and the Viewer's (new) column
  had no flag of their own.

The request was: one right dock, the same in all three workspaces; the Editor's
tool zone as tall as its content; the third tab showing the file on disk; and a
"Show in folder" entry in the Browser and Viewer menus.

## Decision

### One component, one page at a time

`RightDock.qml` owns only the surface, the strip and the stack:

```qml
RightDock {
    tabs: [...]
    currentKey: ...
    PreviewPanel { ... }
    InfoPanel { ... }
}
```

`default property alias pages: stack.data`, so a view lists its pages in order.
`stripShown` is `tabs.length > 1`: a single page needs no tab, and an invisible
`PanelTabs` in a `ColumnLayout` takes no room, which is why a one-page dock
starts at its first page instead of leaving an empty 34 px strip.

The pages are shared components, not copies:

- `PreviewPanel.qml` — heading, the cached thumbnail frame, caption and
  placeholder. The Browser's sidebar and the Editor's Original tab both use it.
- `InfoPanel.qml` — the file's name, type, size, dimensions, mtime and path,
  the Editor's saved/unsaved state, or a selection count. It renders the core
  of the Browser's old metadata grid, the Viewer's new page and the Editor's
  Info tab.
- `HistoryPanel.qml` — the Editor's history list.

`RightDock.qml` draws no sentence of its own; the tab labels come from the
view's `tabs` array, so the component is not a second translation context.

### Visibility belongs to Core, one flag per workspace

`ToggleRightPanel` gained `workspace: Option<Workspace>` with
`#[serde(default)]`, so an older payload still means "the one on screen". The
three answers are separate because the columns answer different questions: a
narrow Viewer may want its information panel while the Browser's preview stays
shut, and the Editor's dock is the tool options.

- `Config` keeps `right_panel` (the Browser's, the field the file has always
  had) and adds `right_panel_viewer` / `right_panel_editor`, both `true`.
- `UiState` mirrors them as `rightPanel`, `rightPanelViewer` and
  `rightPanelEditor`; Core copies the config into the state after
  `UiState::new`, so a config from before this change loads with both new
  panels open.
- A handler that toggles the flag also `save_config()`s, exactly like the
  Browser's existing toggle.

The three views read their own flag (`state.rightPanel`,
`state.rightPanelViewer`, `state.rightPanelEditor`) and their toolbar toggle's
check mark reads the same value.

### The width is one session value, clamped per view

`Main.qml` owns `property real rightPanelWidth: appTheme.previewWidth`. Each
view binds to it and emits `panelWidthRequested(width)` when its splitter is
dragged; each view draws `dockWidth`, its own clamp of that value. A width
chosen in the Browser is the width the Viewer and Editor open with, which is
what "one dock" means in practice.

It is **not** persisted: the splitter is presentation state (ADR 0018's rule),
and a settings field would be a protocol/config decision for a drag gesture.
The Browser's clamp is `200…640` like the other two.

### The tool zone is as tall as its content

The divider is gone and `rightToolZoneHeight` with it. `EditorView.qml`'s
inspector is a `ColumnLayout` of:

1. the heading row (`toolOptionsHeading` + the fold chevron),
2. the options host,
3. the pinned action row (`cropActions`),
4. the `PanelTabs` strip,
5. the `StackLayout` pages.

The options host is an `Item` around the `ScrollView`, with

```qml
Layout.preferredHeight: visible ? Math.min(column.implicitHeight + 10, optionsCap) : 0
Layout.maximumHeight: Layout.preferredHeight
```

and `optionsCap = max(40, height - 180 - headerHeight - actionRowHeight - 10)`.
The `Item` exists because a `Layout.maximumHeight` on a `ScrollView` is ignored
(it answers a layout with its content's implicit height): a 430 px window
still drew a 362 px ScrollView and pushed the tabs out of the dock. Only a
window that cannot also keep 180 px of reference makes the options scroll.

The pointer has no options, so its zone is the heading and one muted line,
`This tool has no options.`; it has no action row. Brush and Eraser have
options and no action row. Crop has Apply / Reset / Clear, Transform Apply /
Reset — the row is part of the zone and folds with it.

The heading is always `<tool name> options` (including `Pointer options`), so
the column says whose fields are below it whether or not a tool is armed.

### Resize returns to the pointer

`openResizeDialog()` sets `tool = "pointer"` before opening the form. The form
is modal and owns its fields; leaving a Crop-shaped tool armed behind it made
the tool zone contradict the dialog and could leave an Apply button armed on a
rectangle the user had not framed.

### The third tab is `Original`, and it is the file on disk

The tab was `Preview` and drew `editor.previewPath`. It is now `Original`
(`original` key, `icons/original.svg`), draws `editor.savePath` — the source
until Save/Save As — and Core publishes that file's identity:

```rust
fn file_identity(path: &Path) -> (u64, u64)   // mtime in ms, byte size
```

`EditorState.file_modified` / `file_size` are set on open, on every publish and
after every save (`apply_save_result`). The identity is not decoration: the
thumbnail cache keys on path **and** mtime/size, so saving over the same path
with new bytes must ask for a new thumbnail. The tab's caption reads
`saved-one.png · 20 KB` and its placeholder `No saved file yet`.

### "Show in folder" is the shell's, not a view's

The Browser's file / folder / quick menus and the Viewer's canvas menu emit
`revealPath(path)`; `Main.qml` calls
`PlatformHelper::revealInFolder`. The order is:

1. Not sandboxed (`/.flatpak-info` absent) **and**
   `org.freedesktop.FileManager1` on the session bus: `ShowItems` for a file,
   `ShowFolders` for a folder. This selects the file in the window the desktop
   already has, which is what "show in folder" means.
2. Otherwise the portal's `OpenURI` on the containing folder.
3. Otherwise `QDesktopServices::openUrl`.
4. If the platform helper refuses, the existing `dialogError`.

Inside a Flatpak the direct bus call is skipped because the host service is not
reachable from the sandbox; the portal is the path there. A desktop that does
not implement the portal still gets the default-handler fallback, which is why
step 3 stays.

### The menus and the toolbar

The three new labels are **appended** to `Theme.menuEntryLabels` (indices 39
`Show in folder`, 40 `Toggle information panel`, 41 `Toggle tool and reference
panel`) because the views address entries by number; nothing at 0–38 moved.
`ToolbarMetrics` counts the new right-panel toggles: Viewer `viewerButtons` 13,
Editor `editorButtons` 14. They are `visible: !miniToolbar` and mirrored in the
overflow menus, so the 580 px floor and the mini counts do not change.

## Consequences

- A tab, a dock toggle and a splitter keep their existing `objectName`s
  (`imageName`, `imageSize`, `saveTarget`, `historyList`, `previewCaption`,
  `editorTab_*`), so the harness and the suites mostly moved rather than
  rewrote; `pointerThumbnail`/`previewCaption` became
  `originalThumbnail`/`originalCaption` because the page is no longer the
  working preview.
- The tool zone's height changes with the armed tool. That is the point (no
  hole under Brush), but it means the tabs move up when a short tool is armed;
  a fixed zone was the alternative and was measured to be worse.
- `PanelDivider.qml` is deleted: a drag handle for a height that no longer
  exists would be dead code, and the reference zone now gets whatever the
  options leave.
- The `Original` tab needs a saved file to be interesting; before the first
  save it shows the source and says the document is unsaved in the Info tab.
- A reveal is a desktop request: a portal that answers but draws nothing is not
  a dialog, so the entry's behaviour is only as verifiable as this session's
  file manager allows (there is none here — see the M1 report).
- Core grew three state fields and a protocol field; no new command path. A
  toggle is a real `Envelope` and lands in the journal; a tab, a fold or a
  splitter drag does not, which is the expected evidence.
- Twelve new strings (three menus, five Editor, two panels, one Viewer) are in
  the `.ts` under the contexts that draw them; `InfoPanel`/`PreviewPanel`/
  `HistoryPanel` are their own contexts, which is why the moved label
  translations had to follow them.

## Alternatives rejected

- **Keep the divider and shrink the zone per tool.** Moving the tabs under the
  pointer on every tool switch is worse than a short tool leaving space; the
  divider was also the third drag target in a column that already has one.
- **One `rightPanel` boolean for all three workspaces.** A narrow Viewer and a
  wide Browser want different answers, and the Editor's dock is not a preview.
- **Persist the dock width in `config.json`.** A splitter drag is presentation
  state; adding a field would make the config describe a gesture, and the views
  clamp to different ranges anyway.
- **Draw the working preview in the third tab.** That was the old behaviour,
  and it answered a question the canvas already answers.
- **Open the folder with `xdg-open` from QML.** QML does not do I/O, and a
  sandbox needs the portal; the platform helper is the one place that knows the
  difference.
- **A separate "Show in folder" command.** It changes no domain state and has
  no result beyond the desktop's own action; it is a platform request, like
  opening a URI.

## Revision notes

- ADR 0019 is superseded in two places: the divider and its fixed 440 px zone
  are gone, and the third tab is `Original`. Its self-drawn `PanelTabs` strip
  and its measured action row are unchanged and still current.

## Revision — the split is back, as a divider between two halves (2026-11-22)

Removing the 440 px divider fixed the hole under a short tool, but it also took
away the only way to say "more options, less reference". The dock now has both
answers, and they are different objects:

- **A `PanelSplitter` with `orientation: Qt.Vertical`** sits between the tool
  zone and the tab strip. It writes `toolZoneHeight` (`0` means "hug the
  options"), clamped so 160 px of reference stays; a double-click returns to
  hugging. It is drawn only while a tool with options is armed and neither half
  is folded.
- **The strip's chevron** (`PanelTabs.foldRequested`) puts the pages away,
  leaving the 34 px strip at the bottom of the dock. The tool zone then fills
  the freed height (`referenceFolded`) — the fold the user asked for: the three
  tabs stay visible and switchable, only their pages go.

Neither sends a command. A split or a fold is presentation state like a tab
click; the journal stays silent, which is the expected evidence.

`RightDock` grew `folded`/`foldTooltip` and `stripHeight`; the pages stay
instantiated behind `visible: !folded`, so unfolding is one property write.
`PanelSplitter` gained an orientation so the same component resizes a width or a
height. `tst_editor` has one case per half
(`theReferenceTabsFoldToTheirStrip`, `theDividerSetsTheToolZoneHeight`), and the
fold case also asserts that a tab still switches while its page is hidden.

## Revision — "Show in folder" asks the bus instead of inspecting it (2026-11-22)

The first version gated on `QDBusConnection::sessionBus().interface()
->isServiceRegistered("org.freedesktop.FileManager1")`. On a desktop whose file
manager is D-Bus-activated and not yet running, that is false at the moment of
the click, so the request fell through to the portal or the default handler even
though `FileManager1` was exactly what would have selected the file.

The helper now skips the gate and sends the call with a 5 s reply timeout: if no
file manager is running, the bus activates it. A missing file or folder is
answered with `That file is no longer there.` before any request; a sandbox
still skips the direct bus call; `FileManager1` → portal → `QDesktopServices` is
the unchanged order, and each branch logs which one answered.
