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
- A crop frame can be dragged anywhere on the document, but the ratio lock still
  only links the typed fields; keeping a ratio *during* a drag is a separate
  decision.
- The transform is one quad: no rotation of the quad, no lens/barrel model, no
  multi-point mesh. Those are different features with different guarantees.
