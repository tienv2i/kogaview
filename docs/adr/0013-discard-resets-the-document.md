# ADR 0013 — Discard resets the document before the workspace changes

- Status: accepted
- Date: 2026-11-21

## Context

The Viewer and the Editor are one photograph seen two ways, so a switch from the
Viewer carries the picture it shows into the Editor (ADR 0003 and row 66's
linking rule). That rule had a hole: "a document already open wins" was written
as "only link into an empty Editor", so this sequence kept the old picture:

1. open `one.png` in the Editor and edit it (unsaved);
2. switch to the Viewer — the unsaved-changes dialog appears;
3. answer **Discard**, open `two.png` in the Viewer;
4. return to the Editor: it still shows `one.png`.

Core protects unsaved work on purpose: a switch must never throw away edits
silently. The hole was on the shell's side — Discard closed the question but sent
no command, so Core still considered the document modified and refused to
replace it. And even with a reset, "a document already open wins" would have
rejected the switch that the Viewer explicitly asked for.

## Decision

- **Discard is `editor_reset` followed by the leave.** The shell sends
  `[{ editor_reset }, { set_workspace | editor_close }]` through `sendSequence`,
  in that order, so Core sees a saved document before it sees the workspace
  change. Quitting is exempt: the document does not survive the window, and a
  reset would write a preview for a process that is leaving.
- **A switch from the Viewer follows the Viewer, saved or not.** `SetWorkspace`
  records the previous workspace and passes `from_viewer`; when it is true the
  Editor opens the Viewer's current picture even if another document is open.
  The normalized paths are compared first, so re-entering the Editor on the same
  picture is not a reload.
- **A switch from anywhere else still keeps the open document**, and unsaved
  edits are never replaced: `link_viewer_into_editor` refuses when the document
  has no save target. The window's three-way dialog remains the only way to
  discard them.
- **The shell half is a source guard.** `Main.qml` needs the real
  `KogaViewBridge`, so `tst_settings` asserts that `leaveAfterDiscard` sends
  `editor_reset` inside the same sequence and that the quit path returns before
  it. Core's half is
  `core::tests::switching_to_the_editor_carries_the_viewer_image`, which walks
  the whole sequence including the unsaved case and the reset-made-saved case.

## Consequences

- The rule is now stated where it belongs: the Editor follows the picture the
  Viewer is showing when the user comes *from* the Viewer; every other route
  keeps the document the user chose.
- The shell sends one more command on Discard, so the journal shows
  `editor_reset` immediately before the workspace change instead of only the
  change. A reset that fails leaves the workspace switch in place, which is the
  pre-existing behaviour of any multi-command sequence.
- `pendingLeave` is cleared before the sequence is sent and the dialog's
  `onClosed` clears it too, so a dismissed question cannot fire twice.
