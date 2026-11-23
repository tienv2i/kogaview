---
description: Tier 3 deep verification on the real window — clears docs/VERIFICATION-QUEUE.md
agent: build
---
Load the `real-window-verification` skill and follow it end to end for
`$ARGUMENTS`. If no argument is given, read `docs/VERIFICATION-QUEUE.md` and
verify the pending items listed there, removing each item once verified.

The report must contain:

- the commands actually run, and the totals they printed;
- whether the real desktop app was launched, on which OS/session;
- what was done in the UI (and whether the input was a real click or synthetic);
- the evidence by layer — journal line, AppState delta, screenshot, file on disk;
- selective mutations (where applicable) that made a test fail, and the restored green run;
- an explicit "not verified" list with the reason (kept in `docs/VERIFICATION-QUEUE.md`).

Do not state that a scenario was exercised unless it was.