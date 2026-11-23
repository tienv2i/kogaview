# ADR 0025 — One foreground/background pair per Editor, and new canvas has one colour

- Status: accepted
- Date: 2026-11-23
- Related: ADR 0014 (painting is one typed stroke), ADR 0012 (sizing is a
  dialog), ADR 0011 (crop grows the canvas), ADR 0018 (the tool rail),
  ADR 0022 (a layout owned by Core), ADR 0004 (saving an edited image)

## Context

ADR 0014 put Photoshop's two colours in the brush's tool options: a foreground
box raised over a background one, each with its own `ColorDialog`, plus the swap
arrow (`X`) and the reset square (`D`). The background had no reader — a stroke
carries only the foreground — so it was "the other place a colour is kept, so `D`
always has somewhere to reset to".

Three new-canvas features then each grew their own answer:

1. **Resize's pad** had a `backgrounds` list in the form (`None` plus three
   named colours plus *Custom colour…*), and the form owned the answer:
   `ResizeDialog.qml` kept `backgroundMode` and `customColor` itself.
2. **Crop's grow** had a *Grow fill* dropdown in the crop panel, with its own
   list and its own index (`cropFill`, `cropFillIndex`, `chooseCropFill`).
3. The **brush** kept the third pair, in the paint options.

So the same question — "what is the colour of the canvas this command adds?" —
was answered by three controls with three defaults, in three places, and none of
them was reachable unless its own tool was armed. Setting grey in Crop's grow row
and then padding in Resize gave you white; the pair in the paint options was
invisible unless the brush was armed, and could not be changed at all while
resizing.

The request: one global foreground/background pair, in the Editor's tool rail as
Photoshop draws it, integrated into the panels and dialogs that use it.

## Decision

### The pair is the Editor's, not the brush's

`EditorView.qml` owns three pieces of view state and nothing else does:

```qml
property string foregroundColor: "#000000"
property string backgroundColor: "#ffffff"
property bool backgroundTransparent: false
```

`ColourPair.qml` draws them — the foreground box raised over the background one
inside one 34 × 34, the swap arrow and the reset square — and only emits
`foregroundClicked`, `backgroundClicked`, `swapRequested`, `resetRequested`. It
holds no colour of its own, so a box cannot show a value the next command would
not use.

The pair is drawn in the tool rail, under the tool buttons and above the rail's
foot, when a document is ready. With the rail put away (Settings › Appearance
can hide any panel, ADR 0022), the same component is drawn in the paint options
above the hex field, from the same two properties: the colours are never
unreachable, and the two copies cannot disagree. Its inner object names are the
instance's own name plus a role (`colourPairForegroundSwatch`,
`optionsColourPairBackgroundSwatch`), so a test or a dev hook that reads "the
foreground box" cannot land on the copy that is not on screen.

### Two roles, two different questions

- **Foreground** — the colour of a mark placed *inside* the picture. It is
  opaque RGB, three bytes, exactly what `editor_paint_stroke` carries. It has no
  transparent state: transparency in the document is the eraser's `erase` flag,
  not a colour, and a transparent foreground would be a second, invisible
  eraser.
- **Background** — the material of *new canvas*: resize padding, the border a
  growing crop adds, and later the corners an arbitrary-angle rotate would
  leave. **Transparent is a valid background**, and it is drawn as the
  checkerboard (`Checkerboard.qml`), because a `Rectangle` cannot draw "no
  colour".

The wire is unchanged. `EditorResize { fill, fill_alpha, mode }` and
`EditorCrop { fill, fill_alpha }` already carried a concrete colour per command,
so the pair is a *default source*, not protocol state:

- a concrete background travels as its three bytes and `fill_alpha: 255`;
- a transparent background travels as `[0, 0, 0]` plus `fill_alpha: 0` — the
  bytes are irrelevant at alpha zero, so no third state was added;
- a Grow rectangle wholly inside the picture sends no fill at all, because there
  is no border to paint.

`backgroundBytes()`, `backgroundAlpha()` and `foregroundBytes()` on the view are
the three functions that read the pair; every command builder calls them
(`ResizeDialog.fillForCommand`/`fillAlpha`, the crop's Apply, the stroke).

### One background list, shared by every place that asks

`BackgroundPopup.qml` is the background's own list: `Transparent`, `White`,
`Black`, `Gray`, `Custom color…`. A `ColorDialog` cannot say "no colour", so the
background role needs a list beside the ordinary chooser. One component, opened
under the swatch that was clicked, serves all three places:

| Place | Control | Opens |
|---|---|---|
| Tool rail | the pair's background box | `backgroundPopup` |
| Paint options, rail hidden | the fallback pair's background box | `backgroundPopup` |
| Crop panel, Grow | `cropBackgroundSwatch` | `backgroundPopup` |
| Resize form, Pad | `resizeBackgroundSwatch` | the form's `resizeBackgroundPopup` |

The foreground keeps an ordinary `ColorDialog` (`foregroundColorDialog`) and the
hex field, because a list of five colours cannot say `#2f81f7`.

**Dialogs edit the global background; no operation keeps its own.** The Resize
form's `backgrounds`, `backgroundMode` and `customColor` are gone; it takes
`backgroundColor`, `backgroundTransparent` and `documentIsJpeg` as properties
and answers with `backgroundTransparentRequested`/`backgroundColorRequested`,
which the Editor applies to the pair. Its pad row shows the Editor's background,
and choosing `Gray` there is the same state the rail's box shows the moment the
form closes. Crop's grow row is a swatch, not a dropdown, for the same reason.

### What came with it

- **Renames**, so the code says the roles and not the tool: `paintColor` →
  `foregroundColor`, `paintBackgroundColor` → `backgroundColor`,
  `paintColorBytes` → `foregroundBytes`, `setPaintColor` →
  `setForegroundColor`, `setPaintBackgroundColor` → `setBackgroundColor`,
  `swapPaintColors` → `swapColours`, `resetPaintColors` → `resetColours`. The
  paint *tool* keeps its name (`paintSize`, `paintOpacity`, `paintSwatches`):
  those are the stroke's, not the colours'.
- **`swapColours()` cannot make the foreground transparent.** `X` exchanges the
  two colours and the foreground is always opaque, so a transparent background
  swapped forward becomes a concrete colour (its last painted value). The
  transparency therefore stays with the background role, which is the role that
  can use it.
- **Crop's `Reset options` leaves the background alone.** The background is the
  Editor's, and Reset resets the *crop* — the frame, the locks, the ratio, the
  mode. A reset that silently painted the next grown border white would be the
  per-tool ownership this ADR removes.
- **A JPEG says what it will do.** `documentIsJpeg` (the open document's
  extension) turns on a one-line note in the background list: a JPEG has no
  alpha, and Core's encoder composites it over white
  (`crates/app-editor/src/codec.rs`). The list still offers `Transparent` — the
  picture on screen really is clear, and an Export to PNG keeps it — and says
  what the document's own save will do at the only moment the answer can still
  change.
- **`resize_pad_needs_colour` is unreachable from the interface.** The form no
  longer has a `None` mode, so pad always carries a fill; the rule stays in
  `crates/app-editor/src/validate.rs` for a client that sends one without.

## Consequences

- The pair is Editor-wide view state, like zoom and pan: it is not persisted,
  not in `LayoutState`, and a new document starts black over white. Two
  documents share it, because it is one Editor.
- The protocol, Core's validation and the batch worker did not change. A
  background is still one colour plus one alpha byte per command, and the
  history line still names what was applied (`resize pad W × H`).
- One control was added to the rail and one row changed shape in each of Crop
  and Resize; no new paint tool, no batch colour change, no transform fill.
- `tst_editor` covers it: `theColourPairIsTheEditorsOnePair` (the rail's pair
  for every tool, 34 × 34, the two choosers, the list's five rows, the
  transparent state, `X`/`D`, the hex field's validation, and the fallback pair
  when `editor.tools` is hidden), `theJpegWarningSitsInTheBackgroundList`,
  `resizeCarriesThePadFill` (the pad row reads and writes the global
  background), `aGrowingCropReachesOutsideThePicture` (the pushed-out border
  travels as `fill_alpha: 0`) and `resetRestoresTheCropOptionsAndKeepsTheFrame`.
  Seen on the real window: the rail's pair, the list under the background box,
  Resize's pad row with the global background, Crop's grow swatch transparent,
  and the fallback pair with the rail put away
  (`docs/evidence/M1-colour-pair*.png`).
- Not built: no eyedropper, no per-document pair, no "recent colours", no
  swap of the *background* forward (`Shift+X` is not a thing), and no rotation
  fill — the arbitrary-angle rotate still adds its corners the way it did.
