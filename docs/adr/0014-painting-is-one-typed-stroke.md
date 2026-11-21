# ADR 0014 — Painting is one typed stroke, and the canvas only previews it

- Status: accepted
- Date: 2026-11-21

## Context

The Editor could rotate, crop, resize, transform and export, but it could not
put a pixel anywhere. The owner asked for real paint tools modelled on Krita —
a round brush and an eraser with a colour, a size and an opacity — plus Krita's
default shortcuts, and the repository rule is that QML never touches pixels:
Core owns the document, QML renders it and emits typed commands.

A freehand stroke is also the first Editor interaction that is continuous in
time. A zoom is presentation-only, and every existing edit is a single command
whose result can be rendered once; a stroke has many points and must appear
under the pointer as it is drawn.

## Decision

- **One stroke is one command, sent on release.** `editor_paint_stroke` carries
  `points` (document pixels), `color` (three RGB bytes), `radius`,
  `opacity` (`0 < opacity ≤ 1`) and `erase`. Points are collected while the
  button is down; nothing reaches Core until it comes up, so a stroke that is
  abandoned (Escape, focus loss, Space for pan) changes none. A press with no
  drag is one point and still paints a dot.
- **`erase` defaults to `false`.** The field is `#[serde(default)]`, so a client
  written before the eraser existed still sends a brush stroke rather than a
  missing-field error.
- **Core paints the pixels.** `paint_stroke` builds a coverage mask over the
  stroke's bounding box: each segment contributes a round-capped capsule about
  one pixel anti-aliased, and the mask takes the **maximum** coverage of every
  segment instead of summing them, so overlapping dabs at a join do not darken
  a semi-transparent stroke. A brush blends its colour source-over; the eraser
  only lowers destination alpha, with the same mask. The result is one
  `EditOperation::Paint`, which snapshots for undo — a warp and a paint have the
  same "cannot be inverted cheaply" problem, unlike rotate and flip.
- **The canvas draws the stroke while it is in flight.** `EditorView.qml` keeps
  `paintStroke` and a `Canvas` overlay in host coordinates; this is presentation
  state, exactly like zoom and pan, and it is cleared when the command is sent.
  The pixels that persist are Core's new preview, which arrives asynchronously.
- **The eraser is a mode of the same tool.** `tool === "paint"` with
  `paintMode` `brush` or `eraser`, the way Krita's freehand brush and eraser
  share one paint engine. The palette shows both, `B`/`E` select them, and one
  inspector column owns colour, size (1–400 px) and opacity (1–100 %).
- **Krita's keys live on the Editor view, not on window-wide `Shortcut`s.**
  Plain keys (`B`, `E`, `[`, `]`, `X`, `D`, `Space`, `+`, `-`, `Tab`) are handled
  by `Keys` on the view root, so a text field that has focus consumes them
  first: typing `b` into the colour field must not arm the brush. `Ctrl+Z` and
  `Ctrl+Shift+Z` (and `Ctrl+Y`) are handled there too, so they undo the
  document, not a field. Palette buttons are `focusPolicy: Qt.NoFocus` so a
  click cannot take the keyboard away from the view.
- **Space is temporary pan, and it ends a stroke rather than swallowing it.**
  While Space is held the paint overlay is disabled and the pan handler takes
  the left button back. The pointer handler already accepted only the middle
  button while Crop or Transform owns the left one; Paint joins that rule.
- **Tab hides the Editor's own panels.** Krita's canvas-only mode takes the
  whole window; here the shell's toolbar is not the Editor's to hide, so the two
  side panels and their splitters go and the picture gets their width.

## Consequences

- A stroke is one undo step, and the history line says `Brush stroke` or
  `Eraser stroke`; the status bar's line is a `UiText` code, translated by
  `UiLines.qml` like every other sentence Core words itself.
- A very long stroke is capped at 4096 points and consecutive points closer than
  half a document pixel are dropped, so a held button cannot build an unbounded
  command.
- Erasing leaves transparent pixels in the document, which PNG and the preview
  keep and JPEG cannot; the exported copy therefore flattens them the way the
  format always does.
- The brush is one hard-edged round tip. Pressure, tilt, softness, spacing,
  blending modes and a colour picker eyedropper are not modelled; the colour
  field and eight swatches are the whole palette question for now.
- The overlay is cleared when the button comes up, so the picture returns to
  Core's previous preview for the moment the new one takes to render. The
  alternative — holding the overlay until `previewRevision` advances — was not
  built.
