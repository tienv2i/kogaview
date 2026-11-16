---
description: Toolchain, identity and canonical binary check before touching code
agent: build
---
Run `just doctor` and `git status --short` **both**, before writing the report.

Report, in this order:

1. every failing check, verbatim;
2. the dev/prod identity it resolved (dev build, native install, Flatpak) and
   whether they conflict;
3. the canonical binary path it names, and whether that binary is older than the
   sources;
4. the files already modified in the tree, quoted from `git status`, so in-flight
   work is not mistaken for this session's.

If a check fails, stop and say what is missing — do not start editing on a broken
baseline, and do not use a stale binary as evidence.