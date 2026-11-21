# ADR 0017 — The toolbar tier belongs to the workspace on screen

- Status: accepted
- Date: 2026-11-21
- Related: ADR 0015 (mini toolbar and the revised floor), ADR 0010 (measured rows)

## Context

ADR 0015 gave the header three states — labels, icons only, folded — but chose
them from **one** number: `compactToolbarWidth`, built from the *widest*
workspace (the Editor, thirteen buttons). `toolbarMini` was
`window.width < compactToolbarWidth` whichever workspace was open.

That is honest for the floor — some workspace can always be the open one — but
wrong for the row on screen. Measured in the test font:

| workspace | row with every icon | row with labels |
|---|---|---|
| Browser | 438 px | 653 px |
| Viewer | 771 px | 986 px |
| Editor | 782 px | 997 px |

So the Browser folded into its overflow menu at every width below ~782 px even
though its own six buttons need 438 — three hundred pixels sat unused while
actions hid themselves. The labels were withheld until the Editor's ~1000 px
for the same reason, so a 900 px window showed no words although the Browser's
row would have fitted them. The user's report was exactly that: the toolbar
"collapses itself while there is still a lot of room", and the three workspace
switch buttons were not part of the decision (they were in the widest sum, not
in the row being drawn).

## Decision

### One row per workspace, three widths each

`ToolbarMetrics` now measures the header row for **each** workspace:

- `browserCompactRowWidth` / `viewerCompactRowWidth` / `editorCompactRowWidth`
- `browserMiniRowWidth` / `viewerMiniRowWidth` / `editorMiniRowWidth`
- `browserLabelledRowWidth` / … (the compact row plus the switcher labels and
  the Menu label)

All three are built by the same `rowWidth(switcherWidth, workspaceWidth)`, which
includes the switcher's three buttons, the separator, the workspace toolbar, the
busy indicator, the Menu button and every gap. The switcher is therefore counted
in the row that is actually drawn, not only in a global maximum.

The widest variants (`compactToolbarWidth`, `miniToolbarWidth`,
`labelledToolbarWidth`) are now derived from those rows, so the floor and the
tests still have one arithmetic and no second set of constants.

### The mode is a function of workspace and width

```qml
modeFor(workspace, width) → "full" | "compact" | "mini"
```

`Main.qml` publishes one binding:

```qml
readonly property string toolbarMode:
    toolbarMetrics.modeFor(root.state.workspace || "browser", root.width)
```

and the views still read `toolbarMini: root.toolbarMini` and the switcher/menu
`showLabels: root.toolbarLabels`. Switching workspace re-evaluates the same
binding, which is what makes the three switcher buttons participate: they
select which measured row the window must fit. The old
`toolbarCompactThreshold` property is gone; there is no second place to keep in
step.

### The floor did not move

`minimumWindowWidth` is still `max(widest mini row, 260 + 320) = 580 px`, and it
is still enforced twice. A window at the floor draws the widest folded row, so
every workspace can be shown there. At 580 the Browser does not fold at all —
its icon row is 438 — which is the desired outcome, not a gap: folding is only
for rows that do not fit.

## Consequences

- At 600 px the Browser shows all six icons while the Viewer and the Editor
  fold; at 700 px the Browser shows its labels while they still fold; at
  800–900 px the Viewer and Editor show icons; only past ~1000 px do all three
  show labels. That is one row measured three ways instead of one row for every
  view.
- Switching to a heavier workspace at a fixed width can drop the labels (Browser
  full at 700 px → Editor mini at 700 px). That is the cost of measuring the
  drawn row: the alternative was withholding the labels from every workspace
  until the Editor could afford them, which is the complaint this ADR answers.
- The Browser's overflow menu is unreachable at any legal window size on this
  machine (floor 580 > its 438 px row). It stays in the view as the rule's
  consequence, and a future floor (e.g. panels hidden) would make it reachable
  without another decision.
- The thresholds are still measured text and follow the interface language;
  the numbers above are the test host's font, the real window measures a little
  wider (665 / 1011 for the Browser / Editor label points in the screenshots'
  log), which is why the tests use the same `modeFor` the shell uses instead of
  hard-coded pixels.
- `tst_toolbar` measures the fixture once per workspace in each mode and drives
  `modeFor` at all three boundaries; the old single-threshold test could not
  see a per-workspace bug at all.
