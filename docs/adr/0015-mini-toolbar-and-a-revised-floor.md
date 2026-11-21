# ADR 0015 — The toolbar folds before the window stops shrinking

- Status: accepted
- Date: 2026-11-21
- Related: ADR 0010 (labels are earned, picture-sized windows)

## Context

ADR 0010 gave the header two states — `<icon> <label>` and icon only — and set
the window floor to the **icon-only row**. That arithmetic was honest but it
made the floor ~798 px, and every workspace had to draw its whole action row at
that width: the Browser's six buttons, the Viewer's twelve, the Editor's
thirteen. A window narrower than the widest of them could not exist, even
though most of those buttons are used rarely and the recording was made on a
1920-wide screen where no one noticed.

The request was the other way round: a *compact* toolbar for a small window, and
a minimum window size that matches it.

## Decision

### Three tiers, all measured

`ToolbarMetrics.qml` still measures the real pieces of the header row. The
answers now read as three ranges instead of two:

| window width | header |
|---|---|
| `≥ labelThreshold` (~1114 px English, ~1208 px Vietnamese) | icon + label for the switcher and Menu, every workspace icon |
| `≥ compactToolbarWidth` (~782 px) | every workspace icon, no labels |
| `< compactToolbarWidth` | **mini**: a few buttons per workspace, the rest in one `⋮` |

`Main.qml` publishes `toolbarMini` and hands it to all three views; nothing else
reads the width. The mini row is not a different widget: it is the same
`ToolbarButton`s, some of them with `visible: !view.miniToolbar`, plus one
overflow button with `visible: view.miniToolbar`.

### What each workspace keeps

Chosen by how often the action is reached for while the window is small:

- Browser — **4**: go up, refresh, open folder, overflow.
- Viewer — **5**: back, previous, next, fit, overflow, plus the `3 / 12` counter
  (a readout, not a button).
- Editor — **7**: open, save, undo, redo, back, close, overflow. The zoom
  readout goes, because the buttons that change it are in the menu.

Everything folded keeps its label, icon and key: the overflow menus read their
words from `Theme.menuEntries` (indices appended at 31, so no existing index
moved) and name the same keys their tooltips do.

### The overflow button is not budgeted twice

`browserButtons`/`viewerButtons`/`editorButtons` stay the *compact* row and do
not count the overflow button; `browserMiniButtons`/… count the mini row
*including* it. Counting the overflow button in both would budget room for a
button the compact row never draws, and the arithmetic would drift from the live
row by one square — which `tst_toolbar` checks against the real sources.

The mini row draws no separators: at 9 px each, when the row is being folded,
they buy nothing.

### The floor is the mini row, plus a picture

```
minimumWindowWidth = max(miniToolbarWidth, sidePanelWidth + pictureWidth)
                   = max(~463, 260 + 320) = 580 px
```

The toolbar alone would allow ~463 px, but a window is not only a toolbar: one
sidebar and a picture worth looking at is the smallest useful workspace. 580 is
the measured answer, not a magic number, and both terms move with the same
metrics the row is built from. The floor is still enforced twice — `minimumWidth`
for the compositor and the `onWidthChanged` guard for this Wayland session, which
accepts a programmatic resize below a window's minimum.

## Consequences

- A window can now be 580 px wide instead of ~798, and no control is ever
  half-drawn at any width: the row is either labelled, icon-only or folded.
- A folded action costs one click. That is a deliberate trade against a window
  that cannot shrink; the menus are 4–10 rows, not a catalogue.
- At exactly the floor, with **both** side panels open, the Browser's grid is
  about 55 px wide and the Editor's canvas about 100 px. The panels are the
  user's own choice, they can be dragged from their splitters, and the mini row
  keeps their toggles in the overflow menu. The alternative — a floor of
  `260 + 260 + 320 = 840` — would have been wider than the row it replaced and
  defeated the request, so the trade is recorded rather than hidden.
- The label threshold, the compact width and the mini width all come from one
  file, so a new toolbar button moves all three together. `tst_toolbar` counts
  the real sources and fails when a count drifts.
- The mini row hides the side-panel toggles from the Browser's toolbar, so the
  overflow menu (`⋮` → *Toggle quick access and folder tree* / *Toggle preview
  and metadata panel*) is the only pointer route to them at that width. Their
  check marks follow Core's state because they send the same `toggle_*_panel`
  commands.

## Revision — 2026-11-21 (ADR 0017)

The three tiers stand, but the tier is no longer chosen from one global row.
`compactToolbarWidth` was built from the widest workspace (the Editor), and
`toolbarMini` compared the window against it whichever view was open, so the
Browser folded at ~782 px although its own six buttons need 438. Each workspace
now has its own compact, folded and labelled row, and `ToolbarMetrics.modeFor`
decides per workspace. `compactToolbarWidth` survives only as the widest-row
aggregate the floor and tests use; `Main.qml` publishes `toolbarMode` instead of
`toolbarCompactThreshold`. The floor is unchanged at 580 px. See ADR 0017.
