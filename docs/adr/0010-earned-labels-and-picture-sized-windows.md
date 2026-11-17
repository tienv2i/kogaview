# ADR 0010 — Labels are earned, and the window sizes itself to the picture

- Status: accepted
- Date: 2026-11-17
- Related: ADR 0001 (Qt/QML shell), ADR 0002 (persisted configuration)

## Context

Two layout complaints, one cause: the shell let a window be a size the interface
could not actually draw.

**1. The toolbar had no compact mode, and no floor.** Narrowing the window
squashed the header row: the three workspace buttons kept their words
("Browser", "Viewer", "Editor", "Menu"), the workspace toolbar after them was
pushed past the right edge, and buttons lost their right half. There was no
minimum size, so the window could be dragged to a width where the interface was
structurally broken. A hard-coded floor (a "magic 940") was the obvious patch
and the wrong one: it would drift from the real row every time a button was
added, and it could not be checked by anything.

**2. Opening a file from the shell ignored the picture's shape.** The window
always opened at a fixed size, so a 9000×600 panorama spent most of the frame
empty and a 300×200 thumbnail opened in a frame twenty times its area. A large
photo was then *upscaled* to fill the viewport, which is soft for no reason.

## Decision

### Labels are earned, not clipped

`ToolbarMetrics.qml` measures the real pieces of the header: the icon square
(34 px), what a label adds beside it, the separator, the row's own 4 px gaps and
8 px side margins, the trailing busy indicator and menu button, and — because
they are not buttons — the Viewer's `"3 / 12"` counter and the Editor's
`"100 %"` zoom, both measured with `TextMetrics` at their widest likely value.

Two numbers come out of it:

- `compactToolbarWidth` — the row with every label off. This is the **window
  floor** (`minimumWindowWidth`), widened by the side panels so the Editor still
  has a canvas.
- `labelThreshold` — the row with the switcher's and the menu's labels shown,
  plus 16 px of slack for Qt's whole-pixel text rounding.

`Main.qml` reads the window width against the threshold and passes one boolean
down. A `CompactToolbarButton` then asks its layout for its icon square or for
`labelledWidth`; the two states are discrete, so a label is never half-drawn or
clipped. The word is still available in both states through `text` and the
tooltip.

The floor is enforced in QML as well as through `minimumWidth`: on this
GNOME/Wayland session a *programmatic* `resize(200, …)` was accepted for a window
whose `minimumWidth` is 870, so `onWidthChanged` re-applies the floor with
`Qt.callLater`. A user's drag is clamped by the compositor; the shell does not
depend on that.

### The threshold follows the interface language

The measured labels are fetched with `qsTranslate(context, …)` — the
`WorkspaceSwitcher` context for the three workspace words, `Main` for the menu —
and not with `qsTr()`. `qsTr()` would look each string up in `ToolbarMetrics`'
own context, which the catalogue does not have, so the file would measure the
English source while the window drew a longer translation. That is not
hypothetical: it is how the Vietnamese interface first ran — 94 px wider in its
labels than the arithmetic that decided when labels may appear — and it fitted
only because `labelledToolbarWidth` happens to budget the widest workspace.

Measured on the real window with the widest workspace (Editor) open: the labelled
row's own `implicitWidth` is 1039 px in English and 1133 px in Vietnamese, and
the threshold moves with it — **1131 px** English, **1225 px** Vietnamese, the
same 210 px of headroom in both.

`scripts/check_translations.py` now scans the QML for both `qsTr("…")` (the
source must be in the `.ts`) and `qsTranslate("Ctx", "src")` (the context *and*
the source must be) after stripping comments, so a moved label or a stale context
fails the gate instead of silently measuring English.

### The window is sized to the picture, once, at launch

`PlatformHelper::imageSize()` reads the size from the header only
(`QImageReader::size()`, `setAutoTransform(true)`), so no full decode happens
before the window exists. `windowSizeForImage()` then:

- fits the picture into the **picture box** — 92 % of the screen minus the
  chrome (16 px wide; 50 + 32 + 106 + 16 px tall) — with a further 0.98 factor
  when scaling *down*;
- never goes below the floor (width `minimumWindowWidth`, height 420);
- never upscales: a small picture stays at 100 %, shows a quiet hint
  (`Small image shown at 100 % — scroll or press + to enlarge`) and the window
  shrinks towards it, so the empty space is the picture's own aspect, not the
  chrome's.

Only the launch path resizes. Opening a folder inside the running app never
moves the window.

GNOME re-applied its own geometry on map (a 1639×1104 request became
1920×1125), so `fitWindowToImage` stores `openedWindowSize` and re-applies it
through `Qt.callLater(enforceOpenedWindowSize)` plus a 250 ms retry.
`Viewer.fittedZoom()` caps at `Math.min(1, …)`, and the size is set before the
picture decodes, so the window never shows a picture that is then re-fitted in
view — the wheel and the zoom buttons still go past 100 %. That ordering is
argued from the launch path, not from a frame-by-frame capture: a window grab
only ever shows the settled window (see Consequences).

### The filmstrip follows the picture, not the folder

A folder holding one image shows no filmstrip (it would be a strip of one
thumbnail under a picture that is already the whole view). The stored
`filmstrip` preference is untouched — it still decides the strip for every
folder where a strip means something.

## Consequences

- The floor and the threshold are *computed*, and `tests/qml/tst_toolbar.cpp`
  checks them against a copy of the real header row (`tst_ToolbarRow.qml`) and
  against the real toolbars' button/separator counts. That test is what caught
  the arithmetic being 84 px short of the live row, and then 8 px short, while
  this change was being made.
- Adding a toolbar button means updating the count in `ToolbarMetrics.qml`; the
  suite fails if it is forgotten. A text readout added to a toolbar must be
  measured there too, and the suite fails if it is not.
- The floor is wider than the absolute minimum because it includes the side
  panels and the widest workspace's readouts. At the floor the compact row has
  visible slack; that is the price of never squeezing the Editor's canvas.
- Oversized windows on very wide screens are capped by the screen, not by the
  image: a 9000×600 panorama opens at 1731×420 and fits at 19 %.
- The threshold is now a per-language number, so a translation with much longer
  words moves it: the gate keeps the measurements honest, but nobody has
  reviewed the Vietnamese words for width — they are simply measured.
- `KOGAVIEW_DEV_SCREENSHOT` raises and activates the window before grabbing and
  waits up to 20 s for it to be exposed, failing the run if it never is. It does
  not grab an unexposed window any more: on this session such a grab returned
  the last committed frame, which right after the launch resize was the pre-fit
  one — a picture at the wrong zoom with no hint, while the window's own
  properties said `zoom 1`. Every screenshot in `docs/evidence/` is a window
  grab of an exposed window, not a compositor capture.
- Not covered: a maximised/fullscreen toggle, a multi-monitor DPI change while
  open, and a real pointer-drag resize (this session has no scripted resize
  tool). First paint was not photographed frame by frame: the screenshots show
  the settled window, and "fitted from the first frame" rests on the launch path
  setting the size and the fit before the picture decodes, not on a capture.
