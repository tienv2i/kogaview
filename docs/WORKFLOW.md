# Engineering, Debugging and Verification Workflow

## Default delivery cycle
1. Define expected visible behavior, state effect, real output and command contract.
2. Implement a vertical slice, build, launch desktop app and review startup logs.
3. Exercise real UI (click, drag/drop, shortcut, file picker as relevant), capture screenshot after render readiness.
4. Check command journal, state revisions, events, task status and output files. Open exported images again when relevant.
5. Exercise the equivalent CLI/IPC/MCP command when implemented; compare semantic state/results.
6. Try failure paths (missing file, permission denied, cancellation, rapid repeated actions, app restart).
7. Report evidence and remaining limitations. Never claim a target OS was tested unless it was actually run.

## Bug fixing: log-first and reproduce-first
1. Identify the owning layer:
   - **Domain bugs** (workspace transitions, file loading, commands, edits): follow Core trace `UI event -> Envelope -> gateway -> handler -> I/O/task -> state commit -> event -> UI render`. Capture logs, journal, state revision, and task ID.
   - **Presentation bugs** (Viewer zoom/pan/rotate/flip, layout, hover/visual states): live purely in QML/presentation state and do NOT emit Core journal entries. Do not waste time searching `kogaview.jsonl` for presentation actions; inspect QML properties, signals, and transforms directly.
2. Isolate before escalating to OS/compositor complexity:
   - If an input handler (`WheelHandler`, `TapHandler`, `DragHandler`) appears dead, **inspect handler properties at runtime** (`acceptedDevices`, `acceptedButtons`, target) before suspecting Wayland/OS window focus. In Qt 6, `WheelHandler` drops Touchpad/Wayland virtual pointers unless `acceptedDevices: PointerDevice.AllDevices` is set.
   - For visual math bugs (zoom anchors, canvas centering): verify transform formulas in a minimal script. Remember `Item.scale` in Qt Quick expands around `Item.Center` by default; do not bake `scale` into `x`/`y` item bindings.
3. Replay the smallest safe command sequence in an isolated workspace, or reproduce with real UI/Agent IPC; minimize the sequence when possible.
4. Compare before/after snapshots, expected/actual state, file output and visual result; identify root cause and fix in the owning layer.
5. Re-run the same real scenario, check logs for new errors and test one adjacent failure case. Add focused regression tests where useful, not as a substitute for real verification.
6. Mutation-check the fix before calling it done: revert the fix, or plant one small fault in a code path the fix owns, rebuild, and confirm the new test fails; then restore and confirm it passes. Keep it selective — the few mutations that prove the test can see the bug, not a sweep over every line, and never a mutation framework or a generator script. Name each mutation and its result in the report (`/tmp` scripts are scratch, not artefacts).

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
- Green tests are insufficient. No mock-only validation.
- A regression test nobody has seen failing is unproven: revert the fix once and watch it fail before trusting it. Mutation checks stay selective (the code path the fix owns, a handful of faults), never a sweep and never a framework.
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
