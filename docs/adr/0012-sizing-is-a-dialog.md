# ADR 0012 — A size is a question, so Resize is a dialog

- Status: accepted
- Date: 2026-11-21

## Context

Resize grew into the Inspector's biggest column: two linked fields with their own
steppers, a ratio combo, a filtered preset list, `Pad to fit` with its colour
picker, a live-preview toggle and a caption. It shared that column with Crop, so
the two tools competed for one 260 px space and the Inspector said nothing about
the document while either was armed. Resize is also not a *mode*: a crop is
something you do while the frame is on the canvas, but a new size is a question
with an answer, and after Apply there is nothing left armed.

The Settings dialog already established the house pattern for a question: a
`Dialog` with its own header (and header drag), a content column, explicit footer
buttons, Escape as Cancel and a centered position that a written `x`/`y` can
move. Resize had the extra requirement that its answer should be visible before
it is committed: the existing Core draft (`editor_resize_preview`) is exactly
that result, rendered on a worker without touching the document.

## Decision

- **Resize is a self-contained `ResizeDialog.qml`, opened from the palette.**
  The palette's `Resize…` button opens it and leaves `view.tool` on `pointer`;
  the button stays highlighted while the form is open so the palette says where
  the question came from. Crop and Transform remain inspector tools, because
  their answers are drawn on the picture.
- **The form owns its state for the length of one visit.** Width, height, ratio
  and the `Keep current ratio` snapshot, preset, pad colour and Live preview live
  in the dialog, reset from the document every time it opens. A new visit is a
  new question: a ratio lock that survived closing would describe a pair the user
  can no longer see.
- **The dialog shows the draft; the canvas does not.** A draft published while
  the form is open is drawn inside the dialog's own preview, and only while Live
  preview is on. The canvas keeps painting the document, so closing or cancelling
  needs no repaint and the result never appears behind the form's back. The draft
  path, the kind and the `ignoredDraft` guard (a draft older than this visit) are
  the same ones the tool panels use.
- **Apply is one typed command and then a close.** `editor_resize` carries
  `{width, height, fill}`; the dialog closes on the same click, and Apply is
  disabled while the pair is the document's own size, which Core refuses as a
  no-op. Cancel, × and Escape send nothing.
- **The dialog's palette is the theme's, not the platform's.** A `Popup` built
  inside the workspace's Loader resolves the platform (light) palette, and this
  Qt build ignores a QML `palette` write on a `CheckBox`, so the two switch
  labels were dark-on-dark. Their labels are a `Text` with the theme colour; the
  indicator stays the style's.

## Consequences

- The Inspector is back to one job: the armed tool's options. The pointer column
  shows the document while the size question is being answered.
- The dialog sizes itself to its content up to the window, and scrolls with a
  visible bar when a short window cannot hold `Pad to fit`'s extra row. A fixed
  height left a blank page in one language and clipped a wrapped sentence in
  another.
- `tests/qml/tst_editor.cpp` drives the real dialog (open it first; its controls
  are not visible until it is): the fresh document pair, the ratio link, the
  steppers, the pad fill, the live draft and the Apply command.
- The export dialog is untouched; turning it into a themed form is a separate
  change with its own visual questions.

## Revision — the framed preview is gone (2026-11-21)

The first version of this dialog carried a framed preview above the fields: the
document's picture, replaced by Core's draft while `Live preview` was on. On the
real window it read as a form that was still loading — the `Image` decoded
asynchronously inside the modal, so the frame and its caption settled after the
dialog had already appeared, and the form seemed to "burst out" on first open.

The preview was removed together with its `Live preview` switch and the whole
draft path:

- the size is typed as two numbers, and the picture is already visible behind
  the modal, so a second picture only competed with the fields;
- the form is now just fields, ratio, preset, pad and footer, and its height is
  the content column's own height from the first layout;
- the content column is measured at `dialog.width - 40` (the dialog's known
  width) instead of `parent.width - 40` (the popup's width, which is not final
  before it opens), so the first layout is not measured at a transient width;
- `editor_resize_preview` stays in the protocol and in Core — a front end may
  still ask for one — but the window emits it nowhere. Removing the command is a
  separate protocol decision, not part of this UI change.
