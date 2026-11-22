# ADR 0019 — The Editor's right column is a tool zone over three reference tabs

- Status: accepted
- Date: 2026-11-21
- Related: ADR 0018 (the tool rail and view-only presentation state), ADR 0012
  (sizing is a dialog), ADR 0011 (the crop frame), ADR 0010 (measured widths)

## Context

The Editor's right column was one thing at a time: with the pointer selected it
showed the document's name, size, save target, thumbnail and history; arming
Crop, Transform or Brush replaced all of it with that tool's fields. Two
consequences were reported as wrong:

1. **The reference disappeared under a tool.** Cropping is exactly when a user
   wants the history ("what have I already done to this?") and the thumbnail
   ("what does the whole picture look like now?"), and exactly when the column
   stopped showing them. The default tool — the pointer, which is the state the
   Editor opens in — showed them but had no room for anything else.
2. **The options and the document were treated as the same question.** They are
   not: the options belong to the armed tool and are transient; the document's
   identity, its edit history and its preview belong to the picture and last
   the whole session.

The request was therefore a dock split in two: the tool's options on top, a
draggable divider, and Info / History / Preview as tabs below, with the tab and
the split remembered for the session (no settings, no protocol).

## Decision

### One column, two zones

`EditorView.qml`'s inspector (`objectName: "editorInspector"`, unchanged) is now
a `ColumnLayout` of:

1. **The tool zone** (`editorToolZone`): a 34 px heading row (the tool's name
   and a fold toggle), a scrolling options area (`toolOptionsScroll`) and a
   pinned action row (Apply / Reset / Clear).
2. **`PanelDivider`** (`editorRightDivider`), a 7 px drag handle.
3. **The reference zone**: `PanelTabs` (`editorRightTabs`) over a `StackLayout`
   (`editorReferencePages`) holding the Info, History and Preview pages.

The zone's height is `rightToolZoneHeight` (default 440), clamped to at least
`headerHeight + 40` and at most `height - 180` so the tab strip and a page are
always on screen. The divider writes that property through `moved`; a
double-click restores 440.

### The tool zone exists only while a tool does

The pointer has no options, so the zone is the heading alone and the divider is
hidden; the tabs take the whole dock and the Editor opens on the document's
Info. Arming Crop, Transform, Brush or Eraser gives the heading a chevron and
opens the options; the heading's text names the armed tool (`Crop`,
`Transform`, `Brush`, `Eraser`), so the column says what the fields below it are
for. The fold button (`toolZoneToggle`) collapses the options to the heading and
hides the divider and the pinned action row; arming another tool automatically
unfolds, because the fold is a decision about this visit rather than a setting.

**The pinned row hides with the fold.** Apply is the armed tool's verb, so a
folded zone is a receded tool: the user asked for the tabs' room, and one click
on the same chevron brings the verb back. The alternative — keeping 69 px of
buttons under a folded 34 px heading — would have kept the dock from ever being
mostly reference.

### The tabs are drawn here, not a `TabBar`

`PanelTabs.qml` is a row of `AbstractButton`s, one per `{key, label, icon}` the
view passes in:

- **The platform's `TabBar` paints the platform's strip.** This app forces a
  dark window palette; a `TabBar` (like the context menus and the Resize form's
  switch labels before it) arrives light, with its own selected-page chrome.
  Drawing the strip in the app's own colours keeps it part of the dock.
- **Every tab needs a stable name.** The strip gives each button
  `editorTab_<key>`, each drawing `editorTabIcon_<key>` and each label
  `editorTabLabel_<key>`, so the QML suite can assert which tab is open and
  which labels folded. A style's internal tab buttons have no such contract.
- **The strip owns no sentence.** Labels and icons arrive from the view, whose
  `rightTabEntries` is where the four new strings live; `PanelTabs.qml` draws
  what it is given, so it is never a second translation context.

`rightTab` (default `"info"`) is the open tab and `rightTabIndex` maps it to the
`StackLayout`. The pages keep the object names the old column had —
`imageHeading`, `imageName`, `imageSize`, `saveTarget`, `historyList`,
`pointerThumbnail`, `previewCaption` — so the harness, the tests and the
thumbnails' identity plumbing did not have to move.

### A narrow dock folds the labels, and the verbs keep their words

Under 240 px the tab labels go and the drawings, their tooltips and their
accessible names carry the tab. The action row is a `GridLayout`, and its
column count is **measured, not assumed**:

- The style gives a `Button` an 80 px minimum. Three of those plus the two 6 px
  gaps need 252 px, so at the default 260 px dock (236 px of row) the three verbs
  do not fit even in English, and the three-column version of this row was
  squeezing them to 74.6 px (61 px at 220 px), below the minimum at which the
  labels elide — which is what turned the Vietnamese `Bỏ khung` into `Bỏ khu…`
  at 260 px.
- `cropActionsStack` on the view compares the row's real width with the sum of
  the three buttons' `implicitWidth`s. When it is set, Apply spans both columns
  and Reset/Clear share the next line; when it clears, the three share equal
  cells. Because `implicitWidth` is the translated label, the rule follows the
  interface language rather than a dock width: English stacks at 260, Vietnamese
  keeps `Bỏ khung` whole on its own line there instead of eliding it.
- Transform has two verbs and stays two-up at every width.

### Nothing here is a command

`rightTab`, `rightToolZoneHeight`, `toolZoneFolded` and `rightPanelWidth` are
view properties: switching a tab, dragging the divider and folding the options
write no journal entry and send no `Envelope`, exactly like the rail's
`toolColumns`. They are remembered for the session and reset on the next launch;
persisting them would be a settings/protocol change, not a bigger `Main.qml`.

## Consequences

- A tool no longer hides the document's identity, its history or its preview;
  the tab stays open across a tool switch (the QML case arms Crop with Preview
  open and asserts the thumbnail is still there).
- The dock costs vertical space in a tool: the default split leaves the tab
  page `inspector.height - 440` tall, and a short tool page (Brush) leaves empty
  space in the zone rather than shrinking the split per tool. A split that
  jumped with each tool would move the tabs under the pointer.
- The new strings are four — `Info`, `Preview` (`History` already existed),
  `Collapse tool options` and `Expand tool options` — all in the
  `EditorView` context, so `ToolbarMetrics`' measured rows did not change.
- The fold, the tab and the split are forgotten on the next launch, like the
  rail's column count; this is stated rather than hidden.
- No protocol, Core, journal or log change: the dock is the eyes, and the
  absence of a journal line is the expected evidence for a tab click.

## Alternatives rejected

- **Qt Quick Controls `TabBar` + `TabButton`.** The style's strip and the
  missing object names, as above. The dock could not own its own colours and
  the suite could not name a tab.
- **Tabs in the window's header toolbar.** The header's rows are already
  measured (`ToolbarMetrics`) for a floor of 580 px, and the tabs describe the
  document, not the window; putting them in the header would have made the
  Browser and Viewer pay for an Editor control.
- **Remembering the tab and the split in `config.json`.** A persisted view
  preference is a settings field and a `set_settings` shape; the user asked for
  memory "for the session", and a protocol decision should not ride on a layout
  pass.
- **A tool-options drawer that overlays the tabs.** An overlay would cover the
  very reference the split exists to keep visible.

## Revision — 2026-11-22 (ADR 0020)

The dock is now shared by all three workspaces, so this ADR describes one
workspace's earlier shape. Two of its decisions are superseded:

- **The divider and the fixed `rightToolZoneHeight` are gone.** The tool zone
  is as tall as its options, capped only when the window cannot keep 180 px of
  reference below it (ADR 0020). `PanelDivider.qml` is deleted.
- **The third tab is `Original`, not `Preview`.** It draws the saved file on
  disk (`editor.savePath`) through Core's published mtime/size, not the working
  preview (ADR 0020).

Everything else still stands: `PanelTabs` is still self-drawn, the tab strip
still folds its labels under 240 px, the action row is still measured
(`cropActionsStack`), and the pointer still owns no options.

## Revision — 2026-11-22 (ADR 0022)

The split this ADR describes is now a preference Core owns, not view state:

- **The split, the tab and the rail's columns are `LayoutState` fields.** A drag
  that ends, a tab click or the rail's fold sends `set_layout` through the
  shell; a launch opens where the last one ended. `toolZoneHeight` is now
  `editorReferenceHeight` and its `0` means "as tall as the open page needs",
  which is the default.
- **The fold is gone.** `toolZoneFolded` and `referenceFolded` had one job —
  give half the column to the other half — and hiding the individual panels
  (ADR 0022) does that and more, so the chevron and its two state flags are
  deleted. The divider stays: height is not visibility.
- **The tool rail is one of the layout's panels.** `editor.tools` can be hidden
  like the reference pages, and the quick-edit grid below it goes with it.

Everything else still stands: the tabs are self-drawn (`PanelTabs`), the action
row is measured (`cropActionsStack`), and the pointer still owns no options.
