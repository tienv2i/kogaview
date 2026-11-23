---
description: Run the full gate (Cargo workspace + Qt Quick suite) and report failures by name
agent: build
---
Run `just test` unless the argument names a narrower scope (`just test qml`,
`just test browser`, `just test viewer`).

Report:

- the totals line verbatim;
- for every failure: test name, the assertion message, and whether it points at a
  QML property/transform claim or a Rust unit claim;
- anything skipped, and why it matters.

Do not describe a passing run as proof the feature works on the real desktop —
the QML suite argues from properties and emitted commands, not from pixels, and
a Rust unit test proves the domain logic, not the desktop. Say which kind of
evidence this run is (Tier 1/2), and record any skipped real-window checks in
`docs/VERIFICATION-QUEUE.md` for `/verify` (Tier 3).