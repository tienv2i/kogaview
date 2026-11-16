---
description: Prove a change on the real window — evidence, mutation check, honest report
agent: build
---
Load the `real-window-verification` skill and follow it end to end for
`$ARGUMENTS` (or for the change just made, if no argument is given).

The report must contain:

- the commands actually run, and the totals they printed;
- whether the real desktop app was launched, on which OS/session;
- what was done in the UI (and whether the input was a real click or synthetic);
- the evidence by layer — journal line, AppState delta, screenshot, file on disk;
- one or more mutations that made a new test fail, and the restored green run;
- an explicit "not verified" list with the reason.

Do not state that a scenario was exercised unless it was.