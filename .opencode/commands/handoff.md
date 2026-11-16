---
description: Update SESSION-STATE, M1-REPORT and AGENTS.md from what was actually run
agent: build
---
Update in this order:

1. `docs/SESSION-STATE.md` — working tree (branch, HEAD, dirty/untracked files),
   environment facts that changed, what was measured this session, and the next
   natural vertical slice.
2. `docs/M1-REPORT.md` — a new row (next number) for each change delivered:
   what changed, the tests and mutations that (dis)proved it, and the
   real-window evidence actually captured, with the numbers measured.
3. `AGENTS.md` — only when a rule, command or ownership boundary changed; never
   for a feature.

Rules:

- every number must come from a command run in this session — never copy figures
  forward or describe a screenshot that was not taken;
- keep a "not verified" line explicit, with the reason;
- do not commit scratch files or mix an unrelated doc change into a code fix.

Arguments: `$ARGUMENTS`, when given, is the topic the handoff should emphasize.