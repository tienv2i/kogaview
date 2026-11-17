# ADR 0009 — Fit as a mode, and a Settings dialog that previews

- Status: accepted
- Date: 2026-11-17
- Related: ADR 0002 (persisted configuration), ADR 0006 (interface language)

## Context

Two separate complaints, one shape: a control that only took effect at one
moment.

**1. Fit was a one-shot.** `Viewer.fit()` computed the scale and then set
`autoFit = false` itself, so there was no "fitted" state to keep. The Editor
already kept the flag, but neither view reacted to a *window* resize: both only
refitted when the image (or the document) changed size. The result was the one
thing a viewer must never do — resize the window and the picture is either small
with a border or spilling out of the frame.

**2. Settings was all-or-nothing.** The dialog copied the stored values on open,
changed nothing until Save, and had one "Reset" that only reset the theme (and
closed the window), so the label was already wrong about two of its four fields.
A user picking "Light" or a language had no way to see the result until they had
committed to it.

## Decision

**Fit is a mode.** `Viewer.fit()` sets `autoFit = true`; every deliberate zoom
(`setZoom`, wheel, buttons, 100 %) clears it. While it is on, the view re-fits on
any change to what is being fitted into:

- the viewport (`onWidthChanged`/`onHeightChanged` on `viewport`), which covers
  the window, a panel split *and* the filmstrip appearing;
- the item itself (`onWidthChanged`/`onHeightChanged` on the root), which is the
  window path;
- the rotation (`onRotationAngleChanged`), because a quarter turn swaps which
  side must fit;
- the image (`onStatusChanged`), which covers a 0-size viewport at load.

`EditorView` does the same against `canvasHost`. Its document rotation is an
undoable edit, not presentation state, so it already arrives through
`onDocumentWidthChanged`.

Both views funnel through one helper, `refitOrClamp()`: fitted views refit,
hand-chosen zooms only re-clamp their pan. That keeps a manual 250 % zoom exactly
where the user put it while never letting a fitted picture leave the frame.

**Settings previews, and saves on demand.** The dialog emits `previewRequested`
on every control change. The shell applies it *without writing anything*:

- the theme becomes an ephemeral `Main.qml` override (`previewTheme`) that the
  theme binding prefers over `state.theme`;
- the language goes through the existing live translator switch
  (`applyInterfaceLanguage`), which the menu already uses.

Buttons, in the order GTK and KDE use: `Defaults` apart on the left, then
`Cancel · Apply · OK` on the right, `OK` as the default action.

| Button | Saves | Closes | What it means |
|---|---|---|---|
| Defaults | no | no | restore the built-in values into the form and preview them |
| Cancel | no | yes | put back what the dialog found, then close |
| Apply | yes | no | persist the form; stay open for the next change |
| OK | yes | yes | persist and close |

Escape, × and Cancel all run the same path: nothing was written, so dropping
the preview restores both the form and the window.

`DialogButtonBox` is deliberately **not** used for the footer. It re-sorts its
buttons by role, so declaration order is not drawn order — measured: with
Defaults (Reset), Cancel (Reject), Apply (Apply) and OK (Accept) declared in that
order, OK landed leftmost at `x=446`. The footer is a plain `RowLayout`, where
the order is literal and a test can assert it from real positions.

## Consequences

- QML owns exactly one piece of non-presentation-looking state, `previewTheme`.
  It is allowed because a preview that had to be persisted first would not be a
  preview; it is discarded on Cancel and cleared on every save, and the stored
  value still comes only from the `set_settings` command. Anything else invented
  this way should be questioned.
- The persisted configuration is never touched by a preview, so a crash mid
  preview leaves the stored settings as they were.
- `Apply` is insensitive while the form matches what was last saved, so "Apply"
  answers whether pressing it would do anything.
- A fitted picture at 100 % or below still gets a 2 % margin; a picture smaller
  than the viewport is scaled *up* to fit (the previous behaviour, kept).
- `tests/qml/tst_viewer.cpp::theFilmstripFollowsATouchpad` had to fit after the
  layout settled: showing the strip now changes the viewport, which correctly
  refits a fitted picture, so a `zoomBefore` captured earlier was a stale scale.
- Not covered: printing, a maximised/fullscreen toggle (no such feature yet), and
  a multi-monitor DPI change mid-session.
