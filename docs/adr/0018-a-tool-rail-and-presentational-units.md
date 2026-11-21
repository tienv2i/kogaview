# ADR 0018 — An icon rail, and units that are only a spelling

- Status: accepted
- Date: 2026-11-21
- Related: ADR 0012 (sizing is a dialog), ADR 0011 (crop frame), ADR 0010
  (measured rows and the window floor)

## Context

The Editor's left column had become a second toolbar: a 220 px sidebar with a
`Tools` heading, four full-width text rows for the pointer, Resize, Crop and
Transform, a second heading with four rotate/flip rows, and the pointer's
document thumbnail and history under them. Every entry was a word, so the
column spent a fifth of the window's width saying "Rotate left", and the
picture lost that width at every zoom. The request was the drawing-first
column a paint program has, and — because the request came with number fields
on screen — a way to read the size fields in units other than pixels.

Two questions had to be answered before code:

1. **Whose icons?** The desktop themes disagree. Breeze ships
   `transform-crop-symbolic`, `draw-brush` and friends; Adwaita and Papirus
   ship a fraction of them. An icon-only rail whose icons come from the theme
   is a row of empty buttons on the desktops that lack them, and the rail has
   no text to fall back on.
2. **What is a unit?** A `%` of the document, an inch, or a number the user
   retypes? The document model has pixels and no DPI: Core decodes a frame,
   edits it, and writes pixels back. Nothing in the protocol carries a
   physical size or a resolution.

## Decision

### The left column is a rail, and its fold is session state

`EditorView.qml`'s left `Rectangle` keeps `objectName: "editorTools"` — the
harness and the tests already address it — but it is now a `GridLayout` of
34 px square buttons, two columns by default, 88 px wide
(`16 + 2·34 + 4`). One control at the bottom of the column flips it to a
single column (50 px), which hides the `Tools` heading instead of eliding it to
"T…"; the tooltips already name every button.

- `toolColumns` is a plain QML property. A rail width is a presentation
  preference like the zoom, it is not persisted, and it is not a protocol
  field: nothing in Core changes because a column of buttons folded.
- The left `PanelSplitter` and `leftPanelWidth` are gone. A rail dragged wide
  is a column again, which is the thing this change removed; the right
  inspector still has its own splitter and width.
- The tools are still the same four tools plus paint. Selecting one writes
  `view.tool`; Resize still opens its dialog and stays lit while the form is
  up (ADR 0012). Undo/Redo/Reset stay on the header; the rail keeps the four
  quick pixel edits (rotate/flip) below a divider.

### The drawings are ours, and the button draws them itself

Twelve monochrome SVGs live in `crates/desktop/qml/icons/` and are registered
by `crates/desktop/icons.qrc` under the QML module's own resource prefix
(`:/qt/qml/io/github/tienv2i/KogaView/qml`), so `iconSource: "icons/crop.svg"`
resolves both in the built binary (the `.qrc`) and in the QML suites (the real
files beside the sources). `crates/desktop/build.rs` adds the `.qrc` through
`CxxQtBuilder::qrc`.

`ToolRailButton.qml` gives the button its own `contentItem` holding an
`IconImage`, rather than setting `icon.source` and letting the style draw it:

- The Basic style draws a file `icon.source`; **Breeze does not**. Breeze's
  `Button` content item reads `icon.name` only, so on this GNOME/Breeze desktop
  every square showed the same generic document glyph, and the first
  real-window grab of the rail was a column of identical pages.
- `IconImage` is the renderer the styles use internally; it keeps the SVG's
  alpha and takes `color`, so one dark drawing is tinted muted, hover,
  accent-for-active and 40 % for disabled, from `Theme`.
- **The drawing has its own size.** `AbstractButton` sizes the content *item*
  to the control, so an `IconImage` declared as the content item itself was
  re-sized at run time — the icons looked one size when the Editor opened and
  another after the first click. The content item is now a wrapper that may be
  34 px; the `IconImage` inside it is a fixed 20 × 20 (`iconSize`), its
  `sourceSize` is 40 so the SVG is rasterised for a 200 % display, and
  `fillMode: PreserveAspectFit` keeps the drawing from stretching. Both numbers
  are logical pixels, which Qt scales by the interface scale. The suite reads
  the wrapper's `iconDrawing` property, not the content item's own size.

The protocol and the tests still read `icon.source` — the paint is a
consequence of it, not a second source of truth.

### A unit is a spelling of a pixel quantity

`UnitField.qml` is a row: a `TextField` and a `px`/`%` `ComboBox` beside it,
4 px apart, with the selector matching the field's height. It is used by Crop's
Width/Height and by the Resize dialog's Width/Height. An inline selector was
tried first and removed: it had no room for its own height and read as part of
the number, and a 42 px box elided `px` to a single clipped letter.

- **A place has no unit.** Crop's X and Y stay plain pixel fields
  (`unitsVisible: false`), because a fraction of the picture is a size, not a
  position. The protocol never carried a unit for them either.
- **Nothing on the wire changes.** `pixels()` is what the panels read and
  `setPixels()` is how a programmatic write lands; both answer whole pixels.
  A `%` is `value / 100 · unitReference`, where the reference is the
  document's **width** for Width and its **height** for Height, so `50 %` of a
  1200 × 800 picture is 600 × 400.
- **A unit change is a re-display, not an edit.** `onUnitChanged` rewrites the
  text from `lastPixels` (the quantity the field already described) and does not
  go through `textEdited`, so it cannot trip the ratio link, the
  auto-follow flags or a preset. `px → % → px` returns the same number the
  user had, including a one-pixel step of a large document (`0.03 %` of
  4000 px round-trips as 1 px).
- **`pixels()` is a function, not a bound property.** `TextField` emits
  `textEdited` before it notifies `text`, so a value derived from `text` is one
  keystroke stale inside the handler that reacts to the key that was just
  pressed. That is exactly why the old code called `parseInt(text)`; the
  function preserves it.
- **The row exposes the text control.** A `RowLayout` cannot take the keyboard,
  so `inputField` names the real `TextField`; the dialog focuses that, the Tab
  order (`nextField`/`previousField`) is forwarded to it, and `accepted` is
  re-emitted so Enter still applies the form.
- **`%` is written with two decimals in the `C` locale**, because the interface
  language may use a decimal comma and the field must not refuse a `12.5` for
  that reason.
- `mm`/`cm`/`inch` are deliberately absent. They would be a guess at 96 dpi
  against a document that carries no resolution; the honest spelling of a
  pixel count today is pixels, or a fraction of the frame.

## Consequences

- The rail costs 88 px instead of 220, and 50 px folded; the canvas gains the
  difference at every zoom. The window floor and the toolbar tiers (ADR 0015,
  ADR 0017) are unaffected — they count the header, not the view's columns.
- `icons.qrc` is a second resource file in a crate that already registers the
  QML module; `IconImage` comes from `QtQuick.Controls.impl`, the module the
  style plugins themselves import. Both are Qt Quick Controls' own facilities,
  not a new dependency, and neither needs QIcon or an icon theme at run time.
- A unit switch cannot change what Apply sends, so a 25 % crop and a 1000 px
  crop of a 4000 px document are the same command with the same `x`.
- The canvas is positioned on whole pixels (`Math.round` on `canvas.x`/`y`).
  A centred picture at an odd host width used to sit at `x.5`, and a crop
  dragged from document pixel 10 started at 11; the rail's width change made
  the parity flip visible, which is how the half-pixel offset was found.
- A future DPI would be a Core decision (a document property, a protocol
  field), not a new entry in this combo box.

## Alternatives considered

- **Themed `icon.name`.** Rejected: the icon would be missing on at least one
  of the three target desktops, and the rail has no words to fall back on.
- **Setting `icon.color` and trusting the style.** Rejected by measurement:
  Basic drew the tinted file icon, Breeze drew a generic document instead, and
  an offscreen test could not see the difference because it runs under Basic.
- **A `MultiEffect` colourisation over an `Image`.** It rendered nothing under
  Breeze's content-item layout in the probe, and it costs an FBO per icon;
  `IconImage` is the renderer Qt Quick Controls already ships for this.
- **A `unit` field on the resize and crop payloads.** Rejected: Core has no
  DPI, and a percentage recomputed in Rust would be a second place that can
  round differently from the field the user typed in.

## Revision — 2026-11-21 (the follow-up pass)

The first real-window grab of this work showed three problems the suite could
not: the inline `px` selector clipped its label to one letter and had no height
of its own, the rail's drawings changed size on the first tool click, and the
crop panel's button was a sentence among one-word verbs. This revision records
the answers, which are part of this ADR rather than a second decision:

- **The selector is beside the field.** `UnitField` became a `RowLayout` (a
  `TextField` plus a 56 px `ComboBox` whose height follows the row). A child
  cannot be drawn outside a `TextField`, and 42 px was too narrow for `px` and
  the style's arrow. Call sites keep the same names because `text`,
  `acceptableInput`, `placeholderText`, `horizontalAlignment`, `font`,
  `accepted`, `editingFinished` and `textEdited` are aliased/forwarded; the
  keyboard goes to the `inputField` alias.
- **A place has no unit.** X and Y pass `unitsVisible: false`; they still use
  `pixels()`/`setPixels()` so the crop rectangle has one spelling internally,
  but no fraction of the picture is offered for a coordinate.
- **The drawing keeps its size.** The content item is a wrapper and the
  `IconImage` inside it is `iconSize` (20 px) with a 2× `sourceSize`; the
  control is `buttonSize` (34 px). Both are logical pixels.
- **The crop button is `Apply`.** The Enter key is still handled by the Crop
  tool's own key handler (`Qt.Key_Return`/`Qt.Key_Enter` call `applyCrop()`),
  but the label no longer advertises it; `Apply crop (Enter)` is retired from
  the catalogue and `Apply` reuses the word the Resize and Settings forms
  already translate.
- **Nothing chosen dims the picture.** See ADR 0011's follow-up note; the
  overlay's shade is now always present while Crop is armed, and switches
  between the whole-picture rectangle and the four strips.
- **Back leads the Editor's toolbar.** See ADR 0015's shared-Back revision.
