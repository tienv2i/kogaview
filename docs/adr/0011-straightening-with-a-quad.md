# ADR 0011 — Straightening the frame: a quad, one projective warp, the document's size

- Status: accepted
- Date: 2026-11-20

## Context

`docs/PRD.md` lists the Editor's edits as "rotate, flip, crop, resize, exposure,
brightness, contrast, saturation", and ADR 0003 gave each of them a serializable
operation and a place in the undo stack. None of them can fix the most common
reason a photo looks wrong: the camera was not parallel to the subject, so a
rectangle in the world arrives as a quadrilateral. The Editor could crop the
edges off such a picture, but it could not make the sides parallel, and the
canvas itself was type-only — Crop's rectangle had no frame to place.

Two questions had to be answered before pixels moved:

1. What does the user name? The four corners of the subject, or a set of
   independent horizontal/vertical adjustments?
2. What shape is the output, and how does it undo? A warp destroys the pixels
   outside the named region and cannot be recreated from its parameters.

The project rules constrain the answer: the UI must not own domain rules or do
pixel work, every edit is an explicit serializable command, undo and history are
Core's, and an edit that cannot be described to the user should not be invented.
The first implementation of the math also failed in a way worth recording: the
inverse homography was used as the forward map, so the result came out pinched
rather than straightened.

## Decision

- **A transform is four source corners, clockwise from the top left.** The
  protocol carries `corners: [[f64; 2]; 4]` in document pixels, in the
  document's own winding — top-left, top-right, bottom-right, bottom-left. This
  is what a keystone correction names, and it is one array, so a future front end
  (CLI, IPC, MCP) sends the same thing a drag produces. The canvas also draws
  four **edge** handles, but they are a view affordance: an edge drag moves the
  two corners that form it, and the wire format never sees an edge.
- **The quad is remapped onto the document's own frame.** The output keeps the
  document's width and height; the homography maps the destination unit square
  onto the source quad and samples it bilinearly (pixel centres, edges clamped).
  The alternatives were rejected on purpose: cropping to the quad's aspect would
  change the document size as a side effect of a straightening, and padding would
  introduce bars nobody asked for — `Resize` already owns exact `W × H` and
  `fold`/fill, and Export owns delivery copies at another size.
- **Identity is a no-op and the winding is part of the contract.**
  `is_identity_quad` (within `1e-6`) answers "nothing changed", so Apply is not
  armed for the untouched frame and an identity quad cannot record a history
  step. A quad wound the other way is a mirror of the frame: `Flip` owns
  mirroring, with its own history line, so a reversed quad is refused rather
  than silently applied as a flip. Folded, pinched and collinear quads are
  refused too, as are corners outside the frame — `transform_outside` names the
  corner and the frame so the sentence the window draws is specific.
- **Undo is a snapshot.** `Rotate` and `Flip` invert themselves; `Crop` and
  `Resize` already carry snapshots, and a warp joins them, because the pixels
  outside the quad are not in the result and no parameter can bring them back.
  The existing history budget (12 steps / 160 MiB) applies unchanged.
- **The live draft is the existing draft path with a kind.** `editor_transform`
  applies and records; `editor_transform_preview` renders the same operation to
  `draft-{generation}.png`, publishes `kind: "transform"` and leaves the
  document, its history and its save target alone. The view draws a draft only
  while the matching tool and its own Live preview toggle are on.
- **The canvas is a second input to the same fields.** A crop frame drag writes
  `cropX`/`cropY`/`width`/`height`; a quad drag writes `transformCorners`. No
  drag state is stored, so the inspector, the presets, Apply and the draft all
  read one source of truth. While Crop or Transform is armed the left pointer
  belongs to the overlay (the pan keeps the middle button), and both overlays
  hide while their own draft is on the canvas, because a draft is the result and
  a frame over it would describe pixels that are no longer there.

## Consequences

- `docs/PRD.md`'s edit list gains perspective straightening; the operation is
  not in the original enumeration and this ADR is the record of the addition.
- Outside the quad the sampler clamps to the border pixel, so the leftover
  smears instead of becoming transparent — accepted as the honest default until
  someone asks for a fill or alpha mode.
- The warp is one pass over every output pixel on the draft worker. A 27 MP
  document with Live preview on re-renders the whole frame per settle; tiling or
  region-of-interest decoding is a follow-up, not a promise of this ADR.
- A crop frame can be dragged anywhere on the document; keeping a ratio *during*
  a drag was left open by this ADR and is decided in the revision below.

## Revision — the crop tool finished (2026-11-21)

Row 82 gave Crop a frame on the canvas. This revision answers what that frame
left open; the protocol and Core do not change.

- **A crop tool starts with a frame.** Arming Crop seeds the largest rectangle of
  the chosen ratio at four fifths of the picture, centred (`seedCropFrame`). The
  four fields stay the only source of truth, so the seeded frame is exactly what
  Apply sends; an existing typed rectangle is never overwritten, and Reset
  restores the seeded frame rather than an empty form. A document-size change
  replaces a rectangle that is empty or no longer fits, one event-loop turn
  later (`cropSeedDebounce`), and leaves a rectangle that still fits exactly as
  it is. The turn is load-bearing: a state publish changes width and height in
  one write while QML emits one signal at a time, and seeding from the width
  change alone can fit the frame to the previous height.
- **Crop defaults to `free`.** A crop tool with no constraint should keep the
  shape the user draws; picking a ratio is the lock. Resize's dialog keeps
  `original`, because scaling a picture usually keeps its shape. This supersedes
  the consequence above.
- **A chosen ratio survives the drag.** A corner handle pins the opposite corner
  and fits the dragged box to the ratio; a side handle pins the opposite side and
  grows the other axis around the rectangle's centre. A create-drag is fitted the
  same way before it is clamped to the document, so a square drag draws a
  square. `free` keeps row 82's behaviour exactly.
- **The frame shows the result and the composition.** The picture outside the
  frame is dimmed in four pieces computed from the same document rectangle the
  frame and the command read, and two vertical plus two horizontal rule-of-thirds
  lines sit inside it. Both disappear with the frame while a live draft is on the
  canvas, for row 82's reason: a draft is the result, and a frame over it would
  describe pixels that are gone.
- **Orientation is a turn, not a retype.** `swapCropOrientation` rotates the
  rectangle through 90° around its own centre, keeps it inside the document,
  maps a named ratio to its counterpart (4:3 ↔ 3:4, 16:9 ↔ 9:16, 1:1 → 1:1) and
  turns any other shape into "Keep current ratio". It is presentation only: no
  command is sent until Apply.
- **The keyboard is the pointer's second hand.** With Crop armed, arrows move the
  frame, Shift moves 10 px, Alt resizes around the centre (and derives the linked
  side), Enter applies and Escape puts the tool down. A focused field still
  consumes these first because the handler is on the view.
- **Apply refuses a no-op.** A rectangle equal to the whole document is what Core
  answers with `edit_noop`, so `cropCanApply()` requires a valid rectangle *and*
  a changed one; the button is disabled instead of sending a command that can
  only be rejected.
- **Applying leaves the tool usable.** `applyCrop()` puts its form down before
  the command; the size debounce then seeds a fresh frame on the cropped
  document, so the tool stays armed on the result rather than on an empty panel.
- **Guides and the ratio lock are the view's, not the protocol's.** No new field
  crosses Rust ↔ Qt: a crop is still `{x, y, width, height}`, and the thirds,
  shade, swapped orientation and keyboard all write those four numbers.
- The transform is one quad: no rotation of the quad, no lens/barrel model, no
  multi-point mesh. Those are different features with different guarantees.

## Revision — Crop grows the canvas (2026-11-21)

The crop rectangle can now answer a second question: should the result be the
picture (Center), or the picture with a new border (Grow)? This one does change
the protocol and Core, because a rectangle outside the document needs signed
coordinates and a colour the pixels outside the picture are painted with.

- **The fill colour is the mode.** `editor_crop` carries
  `fill: Option<[u8; 3]>` and `fill_alpha: u8`. Without a fill the rectangle must
  stay inside the picture — the ordinary cut, exactly as before. With a fill it
  may start at a negative `x`/`y` and reach past the right and bottom edges: the
  result is the rectangle's canvas, the picture is copied into the part of that
  canvas it occupies, and every other pixel is the fill at the requested alpha.
  `fill_alpha = 0` is the transparent grow. Older payloads default to no fill
  and opaque, so a client that does not know Grow keeps the Center rule.
- **A grow must still be a border.** A rectangle that misses the picture entirely
  would only produce a coloured page, so `crop_outside_document` refuses it: at
  least one pixel of the picture must be inside. The same `MAX_DOCUMENT_PIXELS`
  ceiling as a resize applies, reported as `crop_too_large`.
- **The canvas is the preview.** In Grow the inspector shows the fill row
  (Transparent, Black, White, Gray, Custom color…) and the canvas paints the part
  of the frame that is not the picture with that colour, so the border is seen
  before Apply. Picking Grow also steps the fitted view back once
  (`revealCropGrowth`), because the canvas host clips at its own edge and a
  fitted picture leaves too little margin for a handle to be dragged outward; a
  view that already has that room is left alone.
- **The frame and the fields stay one rectangle.** Grow relaxes the same four
  fields, the same eight handles and the same drag code; negative X/Y are typed
  and dragged, and `setCropRect` only enforces the one-pixel overlap in Grow.
  Switching back to Center pulls any outside rectangle into the picture again so
  Apply cannot stay armed on a rectangle Core would reject.
- **A grown crop is a snapshot, like every crop.** The pixels outside the old
  picture do not exist in the source, so the operation cannot be inverted by a
  second crop; it records a snapshot and uses the same undo budget. A history
  line says `Grow to W × H · #rrggbb border` (or `transparent border`), while a
  crop without a fill keeps `Crop W × H at X,Y`.

## Revision — Crop is drawn, not seeded (2026-11-21)

The crop frame was still a thing the tool placed for the user: arming Crop
seeded a rectangle, so the first thing on screen was a guess. This revision
makes the rectangle the user's answer and gives the panel a way to say which of
its three shape values is an input.

- **Crop opens unframed.** `enterCropTool()` clears the four fields and the
  locks and nothing else; the frame appears when the user drags one out, clicks
  the picture without travelling (which asks for the whole picture), types a
  side, picks a preset or picks an anchor. A click while a frame already exists
  does not replace it — the create surface is `enabled` only while
  `cropHasRect()` is false, and the frame owns a press that starts on it.
- **Width, Height and Ratio are inputs with locks, not a ratio table.** Each
  field carries a padlock drawn on a `Canvas` (a themed icon would depend on the
  desktop, and the emoji glyph was blank here). The locks are the old
  "Which of the three is derived?" question asked directly: Width+Ratio makes
  Height a consequence, Height+Ratio makes Width one, and Width+Height makes the
  ratio a consequence (its field is disabled and follows the pair). A third lock
  is refused through either of the two paths that implement the rule, so the
  button snaps back instead of showing a state the view does not hold.
- **Ratio is text, and free is empty.** `3:2`, `3/2`, `3x2` and a bare `2` parse;
  the display is reduced by its gcd, so a 1024 × 768 preset reads `4:3`. An empty
  field (whose placeholder says `Free`) means unconstrained, which is a clearer
  statement than a "Free" row in a dropdown. A preset still sets a concrete size
  and writes the same ratio field.
- **A locked side is a lock on the canvas too.** The drag path already pinned an
  axis for a locked side; now the panel's locks are the only source of that rule.
  Two pinned values fix the shape, so `cropResizable` is false and the eight
  handles do nothing while moving the frame from the inside still works.
- **Typing one free side follows the document's shape.** The first keystrokes of
  `800` into an empty Width would otherwise leave `8 × 6` behind; while the other
  side has not been typed in this rectangle (`cropHeightAuto` / `cropWidthAuto`)
  it follows the ratio, or the document's aspect when the ratio is free. A
  preset, a drag, a click, a ratio and Clear reset those flags, so a side the
  user typed is never silently rewritten.
- **Reset and Clear are different statements.** Reset restores the panel's
  options (unlock all three, ratio free, mode Center, transparent fill, preset
  Custom, anchor Center) and leaves the frame where it is. Clear puts the frame
  down, empties the fields and releases the locks while keeping the options, so
  the frame is gone and a chosen ratio, mode, colour or anchor survives.
- **Apply frames the result.** `applyCrop()` records the rectangle's size before
  sending; when the published document arrives at that size, `settleAppliedCrop`
  releases the locks and puts a frame over the whole new document, so the next
  crop starts from what the user can see. A document change that is not the
  pending cut is handled by the existing clamp/refit instead.
- **The crop live draft is gone from the UI.** `editor_crop_preview` still exists
  in protocol/Core with its tests, but no QML emits it and the crop Live preview
  row, its toggle and the crop hint labels were removed; the Transform tool keeps
  its own draft and hint. The sidebar order is the interaction order: X/Y/W/H/
  Ratio, a separator, mode and fill, a separator, preset and anchor, a separator,
  Apply / Reset / Clear.
- **`swapCropOrientation` is removed.** With the rectangle drawn by hand and the
  ratio reduced to one text field, a one-button turn was a second way to say what
  a drag or the fields already say. The swap button and its QML helper are gone.
- No protocol or Core change belongs to this pass: a crop is still
  `{x, y, width, height}` plus the row-91 fill fields, and the locks, ratio text,
  Clear and settle are all presentation state writing those numbers.

### Follow-up: no rectangle means nothing is selected

The frame's shade used to require a rectangle: with none, the picture stayed
bright and the only cue was an empty form. It now dims the whole picture at the
same 45 % while `cropFrameShown` is false, and the four edge strips take over
the moment a rectangle exists — so "nothing chosen" and "this part is kept" are
two different pictures. The dim is one rectangle sized from the same document
projection the frame and the four strips read, so it cannot disagree with the
picture.
