# ADR 0022 — A layout owned by Core, and one left dock for every workspace

- Status: accepted
- Date: 2026-11-22
- Related: ADR 0002 (the configuration file), ADR 0018 (the tool rail and
  presentational units), ADR 0019 (the Editor's split dock), ADR 0020 (one
  right dock, a content-sized tool zone), ADR 0021 (reopening a file)

## Context

Five problems came out of using the three workspaces side by side:

1. **Only the Browser had a file list.** The Viewer and the Editor could open a
   file but could not browse to one, and the Browser's list was one column with
   a heading: its shortcuts and its folder tree could not be answered
   separately.
2. **The visibility control sat on the column it hid.** The Browser had a
   toolbar button, an overflow entry and a canvas-menu entry for its sidebar;
   the shell carried `View > Sidebar` (rows 104–105), a menu of menus whose
   checkbox rows could not even be photographed.
3. **The layout was scattered and half-forgotten.** Dock widths were one QML
   session value, `right_panel` and friends were three `config.json` booleans,
   and the Editor's rail columns, reference height and open tab were view
   state that every launch reset.
4. **The Editor's reference dock kept a share it did not need.** Row 105 fixed
   the tool frame at 340 px, so a short Info page left a hole below it; a later
   content-sized frame could still not give the tool frame the room back
   without the divider.
5. **Nothing outside QML could read or write a layout.** A CLI or an agent had
   no way to say "show the Editor's history at 300 px" even though every one of
   those facts is a preference, not a picture.

The request was: one shared left dock of two independent panels in all three
workspaces; the Editor's rail as a panel; a reference dock that takes only the
height it needs; the panel list moved into Settings; the burger menu flattened
and right-aligned; and every layout fact remembered.

## Decision

### 1. One left dock, two panels, in three workspaces

`LeftDock.qml` owns the surface, the width and the splitter; the pages are
shared components:

- `QuickAccessPanel.qml` — the saved shortcuts, with the shared add/remove
  menu.
- `ExplorerPanel.qml` — the folder tree, one instance per workspace.

Each view declares the dock and asks Core's layout whether a panel is drawn.
A hidden panel is not drawn but keeps its place in the stack, so hiding Quick
access does not turn the Explorer into a different panel. Hiding both hides the
whole column and its splitter (`sidebarShown` in each view), which is also what
removes the last flag a user needs to remember.

A folder click is a browse request. In the Browser the tree sends `navigate`
and stays; in the Viewer and the Editor it sends `open_folder`, which is the
one command whose Core handler also moves the workspace to the Browser
(`open_folder` sets the Browser, `navigate` does not), because neither
workspace has a grid to browse in and a silent `navigate` would change a state
nothing on screen draws. The Explorer's context menu is one `FolderMenu.qml` in
all three views.

### 2. The tool rail is a panel too

`editor.tools` is an ordinary panel key: the rail and the quick-edit grid below
it can be hidden from Settings like Quick access or Info, and the canvas then
takes their width. Arming a tool reopens `editor.options` (row 105's rule); it
does not reopen the rail, because a person who put the tools away said so.

### 3. `LayoutState` is protocol state, and `set_layout` is the command

```rust
pub struct LayoutState {
    left_width: u32,             // shared left dock
    right_width: u32,            // shared right dock
    panels: BTreeMap<String, bool>,
    editor_tool_columns: u8,     // the rail: 1 or 2
    editor_reference_height: u32, // 0 = as tall as the page needs
    editor_reference_tab: String, // info | history | original
}
```

- Fourteen dotted keys (`browser.quickAccess` … `editor.original`) because the
  same question has a different answer per workspace: the Viewer may keep its
  files list shut while the Browser shows both. The list lives once, in
  `LAYOUT_PANEL_KEYS`.
- `Command::SetLayout` (`set_layout`) is the one write; `layout` lives in
  `Config`, `UiState` and `StateMeta`, so a view and a CLI read the same
  numbers.
- `sanitized()` is the contract: widths clamp to 180–560 and 200–640, the rail
  to 1–2, a dragged reference height to ≤ 900, an unknown tab becomes `info`,
  unknown panel keys are dropped and a key a file forgot is put back **as
  visible**. A file from a newer build therefore does not silently hide panels.
- An absent key means visible (`panel(key)`), so a view never has to distinguish
  "unset" from "on".
- `from_legacy` reads the four pre-layout booleans once: `left_panel: false`
  hides every left panel in all three workspaces, `right_panel: false` hides the
  Browser's pages, `right_panel_viewer`/`right_panel_editor` their own. The
  fields are then not written back; the next save carries only `layout`.

### 4. Views request a layout; the shell decides when it is saved

Every view emits `layoutRequested(patch)` — a splitter drag, a tab click, a
rail fold, a dock resize — and never writes the layout itself. `Main.qml`
merges the patch into `previewLayout` (the document's `activeLayout`), and:

- while Settings is open, the merge *is* the preview (`adoptLayout`);
- otherwise it sends `set_layout`.

Toggling a panel from Settings therefore draws the new window before anything
is written, and Cancel restores the opening layout without a round trip.

`set_layout` is written on arrival (a layout is a preference, not a document)
and its reply is silent in the window: the journal keeps the `layout_saved`
line, but a tab click cannot announce "Layout saved" on every turn.

### 5. Settings › Appearance owns the panel list

The dialog is four pages behind one strip: **General** (look, language, the two
dock widths), **Browser**, **Editor** and **Viewer** (each workspace's panel
checkboxes). One shared `panelRow` component draws every row, and `Reset layout`
restores Core's defaults.

The rows draw their own `Text` in the theme's colour. A `CheckBox` inside a
`Popup` resolves the *platform* palette — light on this desktop — and its stock
content item drew near-black words on the dark form (measured `#2b2f36` on
`#181b21`), a list a person cannot read. The indicator stays the style's.

### 6. The reference dock takes what its page needs

`editorReferenceHeight` is `0` by default, meaning "the page's own height":
`referenceShownHeight` is `max(140, min(contentHeight, height − 240))`, the dock
is `Layout.fillHeight: false` + `Layout.alignment: Qt.AlignBottom`, and the
tool frame above absorbs the rest — so a two-line Info page does not leave a
hole and does not push the picture. Dragging the divider writes a real height
(`PanelSplitter.released`, `direction: -1`), which is saved with the layout, and
a double-click returns to `0`. Nothing about a drag reaches Core until it
ends, so one drag is one `set_layout`, not one per pixel.

### 7. The old commands stay, the old controls go

`ToggleLeftPanel` and `ToggleRightPanel` remain in the protocol and Core: a
replayed journal or a future CLI can still ask for "the other side", and they
toggle every panel on that side. No window control emits them any more, and
`tst_settings` fails a view source that starts to.

## Consequences

- A layout change is a journal line and a `config.json` write, and the window
  says nothing about it; the one human sentence is the journal's
  `layout_saved`.
- The layout is one schema a future CLI or agent surface can write, with the
  same clamp rules as the window. A width the splitter could not reach is also
  a width the command refuses to store.
- The window has one authoritative layout. A view that forgets to route an
  interaction through `layoutRequested` loses that change on the next launch —
  which is the failure mode the tests are written to catch, not a hidden write.
- The menu lost its submenu (the burger is flat and right-aligned), and there is
  no key that opens the panel list: the list is a settings page, not a
  transient menu.
- Zoom, pan, hover, the open page's scroll offset and the in-flight stroke stay
  presentation state. A panel's existence, its width, the Editor's split, its
  tab and the rail's columns are remembered.

## Alternatives rejected

- **Keep visibility in QML and persist with `set_settings`.** Settings already
  has a shape, but the layout would then be a corner of the look and a CLI
  would have to know the window's panel names instead of Core's dotted keys.
- **One boolean for Quick access *and* Explorer.** The request was explicitly
  two panels; a user who wants the tree but not the shortcuts is the case that
  motivated the split.
- **A `View > Sidebar` menu (rows 104–105).** A menu about the window holding a
  list about a column, reached through a second menu that a closed burger menu
  could not even draw for a screenshot.
- **A percentage for the reference height.** A share changes meaning when the
  window resizes; the user dragged a number of pixels, and `0` already means
  "whatever the page needs".
- **Fourteen top-level `config.json` booleans.** The sanitizer, the CLI and the
  window would each carry their own list; `LAYOUT_PANEL_KEYS` is already the
  list.
