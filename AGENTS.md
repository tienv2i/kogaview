# AI Agent Instructions — Photo Manager & Editor

Read `docs/PRD.md`, `docs/ARCHITECTURE.md`, and `docs/WORKFLOW.md` before implementing features. Treat these as project requirements; record any deviation in an ADR.

## Non-negotiable rules
- Rust modular monolith, Qt 6/QML with CXX-Qt bridge; target GNOME, KDE Plasma, and Windows.
- UI is the eyes: render AppState and translate interactions into typed Envelope commands. No domain mutations, business rules, filesystem I/O, or image processing in QML.
- Core is the brain: independent of Qt, owns domain logic, state transitions, image operations and I/O orchestration.
- Command Bus is the nervous system: UI, CLI, IPC, and MCP use the same command semantics, validation, authorization, results and state effects. Queries and events are separate types.
- One authoritative state owner, revisioned state, ordered mutations, conflict detection. Qt may keep ephemeral presentation-only state.
- Non-destructive editing; never overwrite source images by default.
- Long-running work must be asynchronous, bounded, cancellable and observable.
- Secure local IPC by default. Agent tools require explicit capabilities for sensitive actions.
- Log structured traces, sequential journal, state revisions, task lifecycle and events; redact sensitive data.
- A green test suite does NOT prove a feature works. Build, launch and exercise the real UI; inspect logs, screenshots and actual outputs. Do not claim verification that did not occur.

## Working loop
1. Read docs and identify the smallest end-to-end vertical slice.
2. Implement protocol -> Core -> adapter -> QML with clear ownership.
3. Build and run the real desktop app, inspect startup logs.
4. Exercise feature by mouse/keyboard/drag-and-drop as applicable, then via CLI/MCP when exposed.
5. Inspect AppState, command journal, events, screenshot and real files/results.
6. If broken, trace logs -> reproduce -> isolate root cause -> fix -> rerun scenario. Use targeted tests as support, not as the only proof.
7. Report what was actually run, OS/session, evidence, limitations and unverified areas.

## First implementation milestone
- Bootstrap Cargo workspace and CMake/Qt/CXX-Qt desktop shell.
- Define typed protocol, AppState revision, in-process command gateway, structured logs and minimal journal.
- Implement `OpenImage` end-to-end from QML and CLI through the same gateway, with an observable state transition and rendered image.
- Add local IPC transport, then MCP adapter, after command contracts stabilize.
- Avoid prematurely splitting into too many crates, building a second command path, or introducing GPU complexity before profiling.

## Flatpak readiness (mandatory from day one)
- Design sandbox-compatible filesystem, desktop integration and IPC; do not assume unrestricted host access.
- Read `docs/FLATPAK.md` before changing file access, portals, IPC, screenshots, build dependencies or packaging.
- Use XDG paths and Qt platform facilities; prefer portals for sandboxed file selection and external URI handling.
- Keep Linux host CLI/Agent connectivity an explicit security/transport design decision; do not bypass sandbox with broad permissions.
- Flatpak packaging may be deferred, but no feature may knowingly make later sandbox deployment impractical without a documented ADR.

## Launch, workspaces and build (mandatory)
- Read `docs/WORKSPACES.md`, `docs/BUILD.md`, `docs/CLI.md`, and `docs/DESKTOP.md` before implementation.
- Three workspaces: Browser (default launch and open-folder), Viewer (open image/file-manager activation), Editor (explicit edit action). Workspace navigation is a Core command, not QML-only state.
- Use `just` as the single developer command entry point. Never run stale binary after build failure or confuse dev/native-installed/Flatpak identities.
- Register image MIME/Open With from day one; never change user default handler silently.
- The provided `justfile` and `scripts/dev.py` are honest bootstrap placeholders: implement build/run/install recipes and verify on real UI before marking done.
