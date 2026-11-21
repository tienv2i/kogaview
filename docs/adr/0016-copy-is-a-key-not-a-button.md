# ADR 0016 — Copy is a key, not a button

- Status: accepted
- Date: 2026-11-21
- Related: ADR 0015 (mini toolbar), ADR 0010 (labels are earned)

## Context

The Canvas menu (Viewer) and the file/folder menus (Browser) already offered
*copy image content* and *copy file path*, but nothing on the keyboard reached
them, and no menu entry said which keys did. The request was explicit: add the
shortcuts and the key hints in the right-click menus, and **no** copy buttons on
the toolbar — the toolbar is already the busiest part of the window.

Two constraints made the obvious answers wrong:

- `Ctrl+C` is the standard copy key, and here it belongs to a focused text
  field: the Editor's hex colour, its size fields, the export path, the folder
  name. A window-level `Ctrl+C` would eat it.
- Qt Quick Controls' `MenuItem` has an `Action.shortcut` and never draws it, and
  appending `\tCtrl+Shift+C` to `text` renders the tab as nothing (measured).
  The hint has to be a thing of its own.

## Decision

### Two keys, in the window

`Main.qml` declares two `Shortcut`s:

| key | handler | copies |
|---|---|---|
| `Ctrl+Shift+C` | `root.copyImageContent()` | the pixels of the one image the workspace is looking at |
| `Ctrl+Alt+C` | `root.copySelectedPaths()` | the path of that image, or the Browser's selection (or its folder) |

Both are `enabled: !root.modalDialogOpen`: a modal dialog owns the keyboard, so
the copy keys wait. `Ctrl+C` itself is left alone.

The handlers read Core's state — `viewerPath`, `selection`,
`selectionInfo.isImage`, `currentFolder` — because only the shell sees whichever
workspace is up, and the views' menu entries call the same
`Platform.copyImage`/`copyText`. The Editor has no copy entry, so the keys do
nothing there; a Browser selection of more than one file copies no image content
and says so in a toast.

### The hint is a column of its own

`MenuShortcut.qml` is a right-aligned label inside the `MenuItem`
(`objectName: "shortcutHint"`, `z: 2` so it sits above the entry's content item).
`Theme.menuShortcutLabels` lists every key a menu can name, `Main.qml` measures
them with `Platform.textWidths`, and `Theme.menuWidth(widths, shortcutWidths)`
reserves the widest key plus a 24 px gap — so the menu keeps one width from one
right click to the next and no key can be drawn over the words it belongs to.

Key names are **not** translated: `Ctrl+Shift+C` is a legend for physical keys,
not a word. The entries' own words stay in `Theme.menuEntryLabels`.

### The hint takes its colour from the entry, not from `palette`

A `Menu` popup is painted by the platform style with the platform's colours,
while a `palette.*` lookup inside it resolves the *window's* palette — which this
app forces to the dark theme. `palette.windowText` therefore painted white hints
on the popup's light background (measured: `#fcfcfc` on `#efefef`) and they were
invisible. The label reads `parent.contentItem.color`, the colour the style
actually painted the entry's text with, and dims it to 70 %.

### The key and the hint cannot drift apart unchecked

The menu says `Ctrl+Shift+C` as a literal in `Viewer.qml`/`BrowserView.qml`; the
binding is a `Shortcut` in `Main.qml`, which a QML test cannot instantiate (it
needs the bridge). The view suites pin the menu half
(`theCopyEntriesNameTheirKeys`), and
`tst_settings::theShellBindsTheCopyKeysItsMenusName` reads `Main.qml` and pins the
shell half: the same two sequences, the handler each runs, and the modal gate.

## Consequences

- The two copy actions are reachable without a menu, in every workspace that has
  them, and the menus say how.
- The menus are one key column wider (~24 px plus the widest key), which is why
  the widths are measured rather than guessed.
- "Copy to…" gets no key: it opens a destination chooser, so a key would have to
  open a dialog rather than do something.
- The Editor's copy surface is Save/Export, not the clipboard; the keys
  deliberately do nothing there.
- The bindings are proven on a real window by handing each `Shortcut` the
  `QShortcutEvent` its handler consumes (`KOGAVIEW_DEV_KEY`); what that does not
  prove is the compositor delivering a physical key, which this session cannot
  do (see `docs/SESSION-STATE.md`).
