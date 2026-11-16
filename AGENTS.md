# AI Agent Instructions — Photo Manager & Editor

Read `docs/PRD.md`, `docs/ARCHITECTURE.md`, and `docs/WORKFLOW.md` before implementing features. Treat these as project requirements; record any deviation in an ADR.

## Agent configuration in this repository (OpenCode)
- This file is the always-loaded rulebook. `opencode.json` adds `docs/WORKFLOW.md` and `docs/SESSION-STATE.md` as `instructions`, so both are in context from the first turn, and refuses the file-editing tools for anything under the generated trees `build/` and `target/` (verified: an edit tool write there is answered `Permission denied: edit`; shell redirection is not restricted — permissions police tools, not the OS). OpenCode V2 reads `AGENTS.md` only (no `CLAUDE.md` fallback); a nested `AGENTS.md` applies to the subtree it sits in.
- Long-form procedures live in `.opencode/skills/`, loaded on demand instead of bloating every turn:
  - `real-window-verification` — build, launch, exercise, photograph, mutation-check and report a change. Load it before claiming anything works, and read its `references/dev-harness.md` for the `KOGAVIEW_DEV_*` hooks.
  - `qt-quick-pitfalls` — input handlers, transform math, binding loops, popup placement and menu width. Load it before editing QML or debugging presentation.
  - `cxx-qt` — the bridge (`bridge.rs`), its generated header, the `cxx-qt-build`/CMake wiring and the `KogaViewBridge` QML type. Load it before changing anything that crosses Rust ↔ Qt.
- `.opencode/commands/` wraps the repeatable steps: `/doctor`, `/rebuild`, `/test`, `/run`, `/logs`, `/verify`, `/handoff`. They are prompts, not a second command path — they still go through `just` and the same gateway.
- Scratch space is `/tmp/opencode` (isolated `XDG_*` roots, fixtures, screenshots). Generated artifacts, runtime state and temporary fixtures stay out of the repository, and project state is never parked in an external service.

## Instruction precedence and fast start
- Follow the nearest applicable `AGENTS.md`; explicit user requirements take precedence over repository guidance.
- When documents conflict, use the newer decision recorded in `docs/adr/` and update the stale document in the same change.
- Before editing: run `just doctor`, inspect `git status --short`, and identify the owning layer (protocol, Core, adapter, QML, or platform).
- After editing: run the narrowest relevant check, then the full `just test` gate when practical; run `cargo fmt --check` for Rust changes.
- Never report a test, launch, screenshot, or platform check that was not actually performed.

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
5. Inspect AppState, command journal, events, screenshot and real files/results (for Core domain commands), or visual/property deltas (for QML presentation state). Interface actions that emit no command (open a menu, trigger a signal, raise a dialog) change nothing in the journal — photograph them or assert a property instead of grepping.
6. If broken, diagnose by layer isolation (QML component -> C++ bridge -> Core -> OS):
   - Two different files, do not confuse them:
     - **Command journal**: `$XDG_STATE_HOME/kogaview[-dev]/journal/commands.jsonl` (this machine: `~/.local/state/kogaview-dev/journal/commands.jsonl`), from `app-core/src/journal.rs`. One line per **protocol command** that reached the gateway (an `Envelope`, the same for every front end), written *after* it ran, with `id`, `command` name, `ok`, `revision`, sanitized `paths`, and `message` or `message`+`error`. A rejected command is recorded too, with `ok:false` and the revision it did not bump. Bounded at the gateway: one malformed envelope is answered with `invalid_envelope` and never reaches the journal or the log. It is not a log and it is not the Event/undo history.
     - **Structured log**: `$XDG_STATE_HOME/kogaview[-dev]/logs/kogaview.jsonl.<YYYY-MM-DD>`, from `tracing` (`app-core/src/logging.rs`): daily-rolled, so the name carries a date and is **not** `kogaview.jsonl` (`just logs` prints the newest one). Fields carry `state_dir`/`log_dir`/`boot_id`, so a run is identifiable. Filter `info` by default, `kogaview_core`/`kogaview_desktop` at `debug`, override with `RUST_LOG`; a compact human-readable copy of the same events goes to stderr too, while `qInfo`/`qWarning` from C++ reach stderr only, so dev-hook evidence is never in the JSON log.
   - Triage in this order: log (boot id, `kogaview::scan`, `kogaview::command`) -> journal (ids, order, revisions) -> AppState revision.
     - Command ran and the journal shows the new revision but the UI did not move: the bug is in the render path (QML or the adapter that publishes state), not Core.
     - Command rejected: the journal keeps `ok:false` and the revision stays; at the default filter the log adds nothing, so re-run with `RUST_LOG=kogaview_core=debug` for the `kogaview::command` line that names the code and message.
     - Nothing at all in the journal: the action never produced a command (a dead handler, a menu item wired to nothing, a QML syntax error that removed the handler) — this is a QML/bridge bug found by reading the QML, not by reading files. QML warnings are not in either file on this build.
   - For UI/presentation bugs: isolate the QML component or handler with a minimal runner before debugging OS/compositor input injection. Do not jump to blaming Wayland/compositor when a pointer handler drops events.
   - Treat a passing regression test and a real-window check as different evidence, and write down which one you have:
     - `tests/qml/` loads the real `.qml` sources from `crates/desktop/qml/`, so a QML-only edit is covered by `just test qml` with **no** rebuild, while a C++ or Rust edit needs `just build` before the window can show it — a stale binary has passed for a fixed bug before.
     - The QML tests argue from what Qt Quick applies (properties, transforms, the commands a view emits), not from pixels: "the menu is wide enough", "the label is not elided" and "the chooser appeared" are only proven on the real window (a screenshot, or an asserted and changing property), never inferred from a green suite.
     - Anything that depends on the window font, the active style or the desktop (text metrics, menus, file and application dialogs, portals) gets one real-window check per change; a headless harness cannot stand in for the desktop's own UI, and a portal request that returns a handle does not prove a dialog was drawn.
   - Watch out for Qt 6 PointerHandler pitfalls: `WheelHandler.acceptedDevices` defaults to `PointerDevice.Mouse` only (ignoring Wayland/touchpad events unless set to `PointerDevice.AllDevices`).
   - Watch out for Qt Quick transforms: `Item.scale` transforms around `Item.Center` by default; do not bake `scale` into `x`/`y` item coordinates.
   - Watch out for bindings that read what they write: a `Menu.font` follows `Menu.implicitWidth`, so a `TextMetrics` inside the menu loops the binding ("Binding loop detected" every frame). Measure in C++ (`PlatformHelper::textWidths`) or in an item that does not feed back, and remember Qt 6.12 will not re-evaluate a binding whose function has side effects.
7. Fix in the owning layer -> re-verify isolated unit -> re-verify real UI scenario.
8. Mutation-check the fix selectively: revert the fix (or plant one small fault in a code path the fix owns), rebuild, confirm the new test **fails**, restore it and confirm it **passes**. A few targeted mutations, not the whole file — never a mutation framework or a batch script that walks the tree. Report what was mutated and what each mutation did to the suite.
9. Report what was actually run, OS/session, evidence, limitations and unverified areas.

## Delivery baseline and next milestones
- The repository currently contains the M0/M1 desktop shell and browsing slice.
- Do not repeat bootstrap work that already exists; use `docs/SESSION-STATE.md`
  and `docs/IMPLEMENTATION_PLAN.md` to select the next missing vertical slice.
- Keep the existing Cargo/CMake/Qt/CXX-Qt shell healthy while extending it.
- Preserve the typed protocol, revisioned AppState, command gateway, structured logs and journal.
- Extend `OpenImage` and browsing behavior through the same gateway before adding new front ends.
- Add local IPC transport, then MCP adapter, only after command contracts stabilize.
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
- Debug builds compile the `KOGAVIEW_DEV_*` hooks in `cpp/main.cpp` (evidence harness, never in a release build); each is inert unless its variable is set. They go through the same signals and helpers the UI uses (a dev command is a real `Envelope` and lands in the journal; a dev UI request emits the signal a click would), but they are synthetic triggers, not a person clicking: say so in the report, and prefer a real click when the desktop allows one.
- Debug builds can render headless (`QT_QPA_PLATFORM=offscreen`) plus `KOGAVIEW_DEV_SCREENSHOT` to photograph a menu or a dialog the desktop would not draw for a capture tool; that is evidence of the widget, not of the compositor. Offscreen is also not a faithful *render*: it loads no icon theme (`QIcon::themeName()` empty, every themed icon blank), so judge icons, and anything else that comes from the platform theme, on a real Wayland/X11 run of `KOGAVIEW_DEV_SCREENSHOT` — a window grab needs no compositor permission and works there.
- A desktop request that returns successfully is not a dialog that appeared. On this GNOME Wayland session `org.freedesktop.portal.OpenURI` is not implemented by the back end, the portal sends no `Response`, and no screen capture works (`grim`: "compositor doesn't support the screen capture protocol"); gate external-chooser behaviour on the portal version and always keep the default-handler fallback, and report the chooser as unverified when it cannot be seen.
- `just test` and `cargo fmt --check` before a commit. Never commit a scratch note (`next.txt` class of file) or an unrelated doc with a code fix; leave it as a separate, described change.
