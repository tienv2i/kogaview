---
description: Update SESSION-STATE, M1-REPORT and AGENTS.md from what was actually run
agent: build
---
Update in this order:

1. `docs/SESSION-STATE.md` — keep it compact (~50–80 lines: branch, HEAD,
   environment facts that changed, current summary, next focus). Move older
   details into `docs/SESSION-STATE-ARCHIVE.md` so context stays small.
2. `docs/VERIFICATION-QUEUE.md` — ensure any Tier 1/2 unverified items are
   recorded (or cleared if Tier 3 verified them).
3. `docs/M1-REPORT.md` — a new row (next number) for each verified change
   delivered: what changed, the tests and mutations that (dis)proved it, and
   the real-window evidence actually captured, with the numbers measured.
4. `AGENTS.md` — only when a rule, command or ownership boundary changed; never
   for a feature.

Rules:

- every number must come from a command run in this session — never copy figures
  forward or describe a screenshot that was not taken;
- keep a "not verified" line explicit, with the reason;
- do not commit scratch files or mix an unrelated doc change into a code fix.

Arguments: `$ARGUMENTS`, when given, is the topic the handoff should emphasize.