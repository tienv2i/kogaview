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

## Revision — Transform is a frame first, and its preview is always drawn (2026-11-23)

Row 82 shipped Transform as a keystone quad with a `Live preview` switch: four
corners that each go wherever the pointer goes, and a draft that replaced the
canvas while the frame stepped aside. The owner asked for two things this
revision answers: the drag should behave like a window border — the side across
from the pointer stays where it is — and the preview should not be a switch at
all, because "phải luôn ở live preview". No protocol or Core change belongs to
this pass: the wire still carries four corners in document pixels and Core still
warps them onto the document's own frame.

- **Two modes, one of them built.** `transformMode` is `frame` (the default) or
  `perspective`. `frame` keeps the four corners on an axis-aligned rectangle;
  `perspective` is row 82's quad, kept in the code and in the suite but drawn
  **disabled**, with the reason under the row: putting the four sides on four
  planes is a layers question the Editor has not answered yet. An option that
  exists and cannot be armed is information; one that is missing is a question
  the window refuses to answer.
- **`frame` is a live resize.** A corner drag moves that corner and pins the one
  across from it; an edge drag puts the whole side where the pointer is and
  leaves the opposite side alone. Both write the same four corners through
  `setTransformFrame`, which keeps the box inside the picture, never narrower or
  shorter than a pixel, and rounds to the tenth of a pixel the command carries,
  so a drag and a typed number agree. This is the gesture that straightens a
  photograph of a page, which is the common case; a keystone needs the quad and
  the quad needs layers.
- **The preview is asked for, never armed.** The `Live preview` button and
  `transformLivePreview` are gone. The frame requests a draft as soon as it
  leaves the identity (`onTransformCornersChanged` → the same 200 ms
  `draftDebounce` a typed crop side uses), and `requestDraft` still refuses a
  frame equal to the document because there is nothing to show.
- **The draft is a thumbnail in the tool options, not the canvas.** This
  supersedes row 82's "both overlays hide while their own draft is on the
  canvas" for Transform. A draft fills the canvas and describes pixels that are
  no longer on screen, which is why the frame had to step aside; with the
  preview in the options the corners stay the command and stay draggable while
  the answer is visible. `transformPreview` gates it on the tool, on
  `kind: "transform"` and on a frame that has actually moved, so a draft of
  another kind, or a frame put back on the identity, hides it without sending
  anything.
- **The canvas never draws a draft.** `displayedWidth`/`displayedHeight` are the
  document's own size and the canvas image is `editor.previewPath`, so the
  picture under the pointer is always the source. The gates that hid the Crop and
  Paint overlays while `previewDraft !== null` were the toggle's leftovers —
  Crop's draft left the UI in row 92 — and are removed with it.
- **Consequences.** Keystone correction of a real photograph (four independent
  corners) is not reachable from the window in this build; the model and the
  command are untouched, so the day layers land the mode is a switch away. The
  draft is still a full warp on the worker per settle — the thumbnail is drawn
  smaller, not computed smaller — so the cost of a 27 MP document is what row
  82 recorded. The tool rail's tooltip now says what the tool does in this build
  (`Straighten the picture by dragging the frame's corners and edges`).

## Revision — the answer is drawn on the canvas (2026-11-23)

The revision above kept the frame's answer in the tool options as a 104 px
thumbnail, on the argument that a picture drawn under the corners is a picture
you cannot aim at. The owner answered it: the preview belongs on the big
picture — "chức năng transform chỉnh lại cơ chế hiển thị transform trực tiếp
trong phần hiển thị ảnh lớn chứ không phải cần khung preview nhỏ, không cần giải
thích bên phải". No protocol change, no Core change: the draft was already a
full-size warp of the document's own frame.

- **The canvas draws the draft.** `displayedWidth`/`displayedHeight` and the
  canvas `Image` follow `transformPreview` while it exists, so the picture on
  screen *is* the straightened result, at the draft's own size (a draft rendered
  in another frame is drawn at that frame, not stretched into the document's).
  `transformPreview` is unchanged as a gate: the tool, `kind: "transform"`, and a
  frame that has actually left the identity.
- **The frame stays on top of it.** `transformFrameShown`, the four edges and
  the eight handles are drawn over the draft and stay draggable, so a drag shows
  its own result while it happens. That was the whole defect of the switch the
  first revision removed: the answer arrived and the thing being aimed with left.
- **The tool options are the mode row, and nothing else.** `transformPreviewBox`,
  `transformPreviewImage`, `transformPerspectiveReason`, `transformHint` and
  `transformSizeHint` are gone; the panel is `Khung` / `Phối cảnh` and the two
  verbs. Why `Phối cảnh` is shut is a **tooltip** on the disabled button — the
  sentence is kept, the paragraph is not. The panel is the tool's, not a
  lecture's.
- **One render per pause, not per pointer move.** `onTransformCornersChanged`
  restarted nothing and called `requestDraft` directly, so `draftDebounce` only
  governed typed crop sides: a corner drag asked Core for a full-size warp on
  every pointer move. Measured on the real window as a stream of
  `editor_transform_preview` commands. It is `draftDebounce.restart()` now, and
  the suite pins the whole drag at one command.
- **Consequences.** The canvas no longer shows the source while Transform is
  armed and moved, so a straightening is judged where it will be applied; a
  corner the user wants to place against the *source* pixels has to be placed
  against the result. The draft is still a full warp per settle (a thumbnail was
  drawn smaller, never computed smaller), and the 200 ms pause is the cost of a
  drag. Apply still sends `editor_transform` and puts the frame back on the
  document's corners, which disarms Apply until the next drag.

## Revision — Free Transform, Scale Canvas, GPU live preview and shared bounding-box modifiers (2026-11-23)

Using `warp_quad` for the `Frame` bounding box inverted user expectation:
pulling a corner inward zoomed the sub-rectangle back out to fill the entire
document frame (reading as an unwanted auto-fit) while a 200 ms CPU draft
round-trip froze the canvas during drags.

- **Two Krita-style icon modes replace `Frame` / disabled `Perspective`.**
  The disabled `Perspective` button is removed. `Transform options` shows an
  icon-only mode row (`transformModeFree` / `transformModeScale`) with tooltips:
  - **Free Transform (`free`, default):** scale and reposition the image inside
    the fixed `W × H` document frame; uncovered canvas uses the Editor's
    `ColourPair` background (or checkerboard when transparent). Apply sends
    `Command::EditorFreeTransform` (`editor_free_transform`), which resamples
    the full-resolution document and composites it onto a `W × H` canvas in
    Core (undoable by snapshot).
  - **Scale Canvas (`scale`):** drag the bounding box to resize the document's
    own `W × H` dimensions directly while keeping the current viewport `zoom`
    fixed (no `autoFit` jump during drag). Apply reuses `editor_resize`
    (`mode: "stretch"`).
- **60 fps GPU live preview in QML.** Transform no longer sends
  `editor_transform_preview` on drag. `transformCanvasLayer` transforms the
  existing `<= 2048 px` preview texture directly on the GPU so even large
  documents drag smoothly inside the bounding box; full-resolution resampling
  runs asynchronously in Core only on Apply.
- **Shared bounding-box modifiers for Crop and Transform.** Both tools share
  `computeBoxHandleDrag` / `computeBoxMoveDrag` / `snapDocCoord`:
  `Shift` locks aspect ratio (or locks axis while moving), `Alt` resizes
  symmetrically around the centre, `Ctrl` snaps to document edges/centre or
  10 px steps, and held `Space` pans the canvas.
