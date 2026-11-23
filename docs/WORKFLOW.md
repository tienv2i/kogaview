# Engineering, Debugging and Verification Workflow

This document is the operational companion to `AGENTS.md`: it defines how to
investigate and verify a change, while `AGENTS.md` remains the authority for
architecture and non-negotiable ownership rules.

## Verification Tiers (Fast by default, Deep on demand)

| Tier | When to use | What to run | Real window / screenshots | Mutation check |
|---|---|---|---|---|
| **Tier 1 — Fast (default)** | After a single feature edit or small fix | Narrowest target (`just test cargo`, `just test <suite>`, `just test translations`) + `cargo fmt --check` (Rust) | Not required | No (for bugfixes, write the failing test *first* — TDD) |
| **Tier 2 — Standard** | Before a commit or after batching edits | Full `just test` once + `cargo fmt --check` | Only if visible UI (layout, dialog, menu, font, icon, theme) changed | Optional |
| **Tier 3 — Deep (`/verify`)** | When the user requests deep verification or before a milestone | Full `just test`, real desktop app, screenshots, log/journal, failure paths, EN + VI, clearing `docs/VERIFICATION-QUEUE.md` | Required | Selective (for key bugfixes/invariants) |

- **Log what was skipped:** Every Tier 1 or Tier 2 completion must record unverified aspects (e.g., real window check, Vietnamese layout, full gate, failure paths) in `docs/VERIFICATION-QUEUE.md` so Tier 3 (`/verify`) can clear them systematically.
- **No false claims:** Tier 1/2 green tests mean *"test-checked, pending Tier 3 verification"* — never *"proven on the real desktop"*.

## Before editing

1. Run `git status --short` to see what is already in flight. Run `just doctor` only when starting on a new/changed environment or troubleshooting build/toolchain issues.
2. Read the relevant requirement documents and note the expected visible behavior, state delta, command (if any), and real output.
3. Choose the smallest vertical slice and the narrowest test target.

## Default delivery cycle
1. Define expected visible behavior, state effect, real output and command contract.
2. Implement a vertical slice and run **Tier 1** checks (narrowest test target + `cargo fmt --check` for Rust).
3. Before committing or finishing a larger slice, run **Tier 2** (`just test` once; launch the real dev app directly with `kogaview-dev` if visible UI changed).
4. Record any skipped deep checks in `docs/VERIFICATION-QUEUE.md`.
5. When the user runs `/verify` (or at milestone close), execute **Tier 3**: launch the real desktop app, exercise UI/CLI/MCP paths, try failure paths (missing file, permission denied, cancellation, rapid repeated actions, app restart), capture screenshots, check command journal/logs/state revisions, and clear verified items from `docs/VERIFICATION-QUEUE.md`.
6. Report evidence and remaining limitations honestly. Never claim a target OS was tested unless it was actually run.

## Bug fixing: log-first and reproduce-first
1. Identify the owning layer:
   - **Domain bugs** (workspace transitions, file loading, commands, edits): follow Core trace `UI event -> Envelope -> gateway -> handler -> I/O/task -> state commit -> event -> UI render`. Capture logs (`$XDG_STATE_HOME/kogaview[-dev]/logs/kogaview.jsonl.<date>`, `state_dir` and `boot_id` are in the startup record), journal (`…/journal/commands.jsonl`: `id`, `ok`, `revision`), state revision, and task ID.
   - **Presentation bugs** (Viewer zoom/pan/rotate/flip, filmstrip scroll, layout, hover/visual states, context-menu width): live purely in QML/presentation state and emit no Core journal entries at all — do not search either file for them. The structured log is `logs/kogaview.jsonl.<date>` (daily-rolled; `just logs` prints the newest) and the command journal is `journal/commands.jsonl`; neither records a zoom, a scroll offset, a menu opening or a QML warning. Inspect QML properties, signals and transforms directly, or photograph the window.
   - Commands the views do emit do land in `journal/commands.jsonl` with an `id`, `ok` and a `revision`, and a rejected one (`ok:false`) leaves the revision unchanged — that journal is the only place a rejection is recorded at the default log filter (`RUST_LOG=kogaview_core=debug` adds the reason).
2. Isolate before escalating to OS/compositor complexity:
   - If an input handler (`WheelHandler`, `TapHandler`, `DragHandler`) appears dead, **inspect handler properties at runtime** (`acceptedDevices`, `acceptedButtons`, target) before suspecting Wayland/OS window focus. In Qt 6, `WheelHandler` drops Touchpad/Wayland virtual pointers unless `acceptedDevices: PointerDevice.AllDevices` is set.
   - For visual math bugs (zoom anchors, canvas centering): verify transform formulas in a minimal script. Remember `Item.scale` in Qt Quick expands around `Item.Center` by default; do not bake `scale` into `x`/`y` item bindings.
3. Replay the smallest safe command sequence in an isolated workspace, or reproduce with real UI/Agent IPC; minimize the sequence when possible.
4. Compare before/after snapshots, expected/actual state, file output and visual result; identify root cause and fix in the owning layer.
5. Prefer TDD for bugfixes: add a focused regression test and watch it fail *before* applying the fix, then re-run and watch it pass. Record any skipped real-window check in `docs/VERIFICATION-QUEUE.md`.
6. At **Tier 3 (`/verify`)**, re-run on the real window, check logs for new errors, test an adjacent failure case, and perform selective mutation checks for high-risk invariants (never a mutation framework or full-file sweep).

## Diagnostics CLI targets (to implement, not assumed present)
```sh
kogactl debug status
kogactl debug logs --last 200
kogactl debug trace --request-id req-001
kogactl debug state
kogactl debug events --since 120
kogactl debug tasks
kogactl debug screenshot
kogactl debug bundle --output bug-report.zip
kogactl debug replay --journal bug-001.jsonl --sandbox
```

## Completion report template
- Implemented behavior:
- Build and tests run (pass/fail):
- Real app launched? OS, desktop session, version:
- UI actions actually performed:
- CLI/MCP actions actually performed:
- Journal/log/state/screenshot/file evidence:
- Failures found and fixes verified:
- Mutation check (each mutation and what the suite did):
- Not verified / blockers:

## Hard rules
- Green tests are insufficient to claim desktop verification. Always label Tier 1/2 results as test-checked (pending Tier 3) and log skipped checks in `docs/VERIFICATION-QUEUE.md`.
- A regression test nobody has seen failing is unproven: prefer writing the failing test *before* the fix (TDD), or run a selective mutation check at Tier 3. Never use a mutation framework or sweep every line.
- Assertions must verify meaningful state transitions (`after != before`); a test asserting invariant stability where no state changed (e.g. `zoom 1.0 -> 1.0`) is a false positive and does not constitute proof.
- Do not silently substitute API calls for a UI interaction requirement.
- Do not jump to OS/compositor level input debugging before verifying that the QML Handler accepted the pointing device.
- If GUI cannot run in the environment, explicitly say UI verification is pending; do not fabricate screenshots or success.
- Diagnostics and replay must redact secrets and protect user files; screenshot capture needs authorization.

## Flatpak-readiness review
When touching file access, native dialogs, clipboard, URI opening, notifications, screenshots, IPC or build dependencies: check the sandbox implications against `docs/FLATPAK.md`. Do not claim Flatpak compatibility until an actual sandboxed build/install/run has been performed. When packaging is added, verify file selection, reopen/export, CLI/Agent access (if supported), Wayland behavior and logs inside the Flatpak sandbox.

## Launch verification gate
- Verify real `kogaview` no-args -> Browser, `open FILE` -> Viewer, `open-folder DIR` -> Browser, and Viewer -> Editor via explicit action.
- Verify Linux Open With via installed `.desktop`, then Windows associations when Windows is available. Check existing-instance forwarding.
- Do not mark build/run/install recipes complete until `just run` demonstrably builds and launches the exact fresh artifact.
