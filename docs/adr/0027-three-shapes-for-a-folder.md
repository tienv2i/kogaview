# ADR 0027 — A folder has three shapes, and the shape is a layout value

- Status: accepted
- Date: 2026-11-23
- Related: ADR 0022 (a layout owned by Core), ADR 0018 (the tool rail),
  ADR 0026 (one dialog frame)

## Context

The Browser had exactly one way to draw a folder: a `GridView` of large cells,
each one a decoded thumbnail under its name. That is the right shape for picking
a photo and the wrong one for the three questions a file manager is also asked —
*what is in here*, *what kind of file is that*, and *how big is it / when did it
change*. A folder of two hundred pictures opened as two hundred decodes whether
or not anybody looked at them, and a folder of documents opened as a wall of
"missing image" placeholders with no size, no type and no date anywhere in the
window.

The request: bring the Browser the view modes a file explorer has. The owner
named the three a file manager offers — icons, thumbnails, details.

The three shapes want different things from the same listing:

| shape | what one entry costs | what it answers |
| --- | --- | --- |
| `thumbnails` | one cache lookup and one decode | "which picture is this?" |
| `icons` | one drawing, no decode | "what kind of file is this?" |
| `details` | one line of text | "what is it, how big, when did it change?" |

## Decision

### Three shapes, one listing

`BrowserView.qml` draws the folder as `thumbnails`, `icons` or `details` and
`viewMode` is the only switch:

- **`thumbnails`** is the grid that was always there, unchanged: a cell per
  entry, its picture decoded into it, the name under it.
- **`icons`** is the same `GridView` at a smaller cell, drawing the file *kind*
  rather than the file — a folder for a folder, the image glyph for an image, the
  page glyph for anything else. It asks the cache for nothing:
  `thumbnailable: entry.isImage && !iconsShown`, so the cache is not asked to
  mint a thumbnail that will never be shown.
- **`details`** is a `ListView` of 30 px lines under a header row that names the
  four columns — `Name`, `Type`, `Size`, `Modified` — read from the same
  `detailsTypeWidth`/`detailsSizeWidth`/`detailsModifiedWidth` numbers the rows
  read, so a header cannot stair-step away from its column. The header does not
  scroll with the list: a column you cannot name once you are past the first
  screenful is a column you have to remember.

Only the shape on screen holds delegates (`model: detailsShown ? entries : []`),
because a hidden grid with a live model would decode a thumbnail per entry for a
picture nobody is looking at — the same reason `icons` asks for none.

The `Type` column is named the way Core already names a file: a folder is
`Folder`, a document is its extension (`.png`, `.jpg` — the token Core's `kind`
carries), and a name with no extension says `File`. Only those two words are
translated; an extension is the same in every language. The date is
`Theme.formatDateShort` — the locale's short date and the time. `Theme.formatDate`
draws the whole localised line, weekday and zone included, which needs the width
of a panel; a fixed-width column that ends in an ellipsis is not a date.

### The choice is a layout value, not a QML variable

`LayoutState` gained `browser_view` (camelCase `browserView` on the wire, one of
`LAYOUT_VIEW_MODES`, sanitized to `thumbnails` when a build does not know the
value). The switch does not set a property: it emits the same
`layoutRequested({browserView: …})` → `set_layout` a splitter drag emits, so the
shape is remembered across launches like a dock's width and a CLI can change it.
Nothing about the listing, the selection or the scan protocol moved — the view
already had every field it needs in each `Entry`.

A file manager that forgets how you asked to see a folder asks again every
launch, which is why this is Core's value and not a view preference.

### The switch lives in the path bar

Three 30 × 28 buttons at the end of the crumb bar — where a file manager puts
them — drawn by the app (the platform's `ToolButton` painted its icon with the
palette), the current one armed with the accent and its icon in the accent ink,
each with `Accessible.name`, and `Show as <shape>` on hover. Three new SVGs
(`view-thumbnails`, `view-icons`, `view-details`) in the repository's stroke
style, registered in `icons.qrc`.

### One list the keyboard and a click act on

The keyboard helpers used `grid.currentIndex` and
`grid.positionViewAtIndex` directly, which is a `GridView` interface. They now
go through `activeView` (the grid in the two grid shapes, the list in the third)
and one `revealIndex()`, so `↑`/`↓`/`Home`/`End`/type-ahead/`Ctrl`-range behave
in all three, and `gridColumns()` answers `1` in the list because a row step in a
list of lines is one entry.

## Consequences

- **Three shapes, one listing, one remembered value.** `tests/qml/tst_browser.cpp`
  gained four cases (63 now, from 59): the switch's three buttons and their
  armed state, the empty shapes holding no delegates, the icon shape asking for
  no thumbnail, the details rows' four columns and their width, the click and
  double-click on a row, the keyboard walking the list one line at a time, and an
  unknown saved value resting on thumbnails instead of a blank listing. Five
  mutations were run and restored: `detailsShown` fixed at `false`,
  `viewMode` returning `"thumbnails"` always, `gridColumns()` losing the list
  case, `entryKind` losing the folder word, `detailsModifiedWidth` at 60 px (the
  date then needs 77 px in a 60 px column, and the case says so).
- **A real bug the tests could not see, found by a grab.** The dev hook clicked
  the switch by name with `findChild`, which cannot reach a `Repeater` delegate —
  a delegate is drawn but carries no QObject parent. The first screenshots proved
  the buttons were on screen (the log said "not clickable") while the click did
  nothing; the hook now walks the item tree.
- **Column widths are measured, then asserted.** The first details shot showed
  `Tên` 24 px right of the names (the header had no icon column) and a date
  clipped to "20…" (a fixed 152 px column under `formatDate`'s full line). The
  header now leaves the icon's width blank, and the cell uses
  `formatDateShort`; the test asserts the date's `implicitWidth` fits its column,
  so a locale with longer words fails the suite instead of the screenshot.
- **Not changed:** no scan, thumbnail-cache or selection protocol moved; no new
  Core command; the `Entry` a folder already publishes is enough for all three
  shapes. One layout field is the whole persistence.
- **Not built:** no sorting by column, no per-folder view mode (one mode for every
  folder), no column resizing or reordering, and no icon cache for the small
  shape (the glyph is resolved from the icon theme per cell, which is cheap at
  this size).
- **Not verified:** the icon glyphs' colours on a light theme were not looked at
  (one monochrome `textMuted` drawing serves both); a folder with thousands of
  entries was not timed in the details shape (it creates one 30 px row per
  visible line, no decodes).
