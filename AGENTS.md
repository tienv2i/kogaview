# AI Agent Instructions — Photo Manager & Editor

Read `docs/PRD.md`, `docs/ARCHITECTURE.md`, and `docs/WORKFLOW.md` before implementing features. Treat these as project requirements; record any deviation in an ADR.

## Non-negotiable rules
- Rust modular monolith, Qt 6/QML with CXX-Qt bridge; target GNOME, KDE Plasma, and Windows.
- UI is the eyes: render AppState and translate interactions into typed Envelope commands. No domain mutations, business rules, filesystem I/O, or image processing in QML.
- Core is the brain: independent of Qt, owns domain logic, state transitions, image operations and I/O orchestration.
- Command Bus is the nervous system: UI, CLI, IPC, and MCP use the same command semantics, validation, authorization, results and state effects. Queries and events are separate types.
- One authoritative state owner, revisioned state, ordered mutations, conflict detection. Qt owns ephemeral presentation-only state (Viewer zoom/pan/rotation/flip, hover, focus, animations); Core owns domain, persistence, and workspace navigation.
- Non-destructive editing; never overwrite source images by default.
- Long-running work must be asynchronous, bounded, cancellable and observable.
- Secure local IPC by default. Agent tools require explicit capabilities for sensitive actions.
- Log structured traces, sequential journal, state revisions, task lifecycle and events; redact sensitive data.
- A green test suite does NOT prove a feature works. Build, launch and exercise the real UI; inspect logs, screenshots and actual outputs. Do not claim verification that did not occur. Meaningful verification must assert state delta (`after != before`), never accept unchanged state as proof.

## Working loop
1. Read docs and identify the smallest end-to-end vertical slice.
2. Implement protocol -> Core -> adapter -> QML with clear ownership.
3. Build and run the real desktop app, inspect startup logs.
4. Exercise feature by mouse/keyboard/drag-and-drop as applicable, then via CLI/MCP when exposed.
5. Inspect AppState, command journal, events, screenshot and real files/results (for Core domain commands), or visual/property deltas (for QML presentation state).
6. If broken, diagnose by layer isolation (QML component -> C++ bridge -> Core -> OS):
   - For domain bugs: trace logs (`kogaview.jsonl`) -> command journal -> state revision.
   - For UI/presentation bugs: isolate the QML component or handler with a minimal runner before debugging OS/compositor input injection. Do not jump to blaming Wayland/compositor when a pointer handler drops events.
   - Watch out for Qt 6 PointerHandler pitfalls: `WheelHandler.acceptedDevices` defaults to `PointerDevice.Mouse` only (ignoring Wayland/touchpad events unless set to `PointerDevice.AllDevices`).
   - Watch out for Qt Quick transforms: `Item.scale` transforms around `Item.Center` by default; do not bake `scale` into `x`/`y` item coordinates.
7. Fix in the owning layer -> re-verify isolated unit -> re-verify real UI scenario.
8. Mutation-check the fix selectively: revert the fix (or plant one small fault in a code path the fix owns), rebuild, confirm the new test **fails**, restore it and confirm it **passes**. A few targeted mutations, not the whole file — never a mutation framework or a batch script that walks the tree. Report what was mutated and what each mutation did to the suite.
9. Report what was actually run, OS/session, evidence, limitations and unverified areas.

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
- `justfile` and `scripts/dev.py` implement `setup`, `doctor`, `build`, `test`, `run` and `logs`; `install`, `uninstall`, `package` and the Flatpak recipes still return `NOT IMPLEMENTED` (M6). Implement and verify them on the real UI before marking them done.
- `just test` runs the Cargo workspace tests plus the Qt Quick suite in `tests/qml/`, which loads the real QML sources and asserts on the transforms Qt Quick applies. Use it as support, not as proof: presentation fixes still need the real window.
