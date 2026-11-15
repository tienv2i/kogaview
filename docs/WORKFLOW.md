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
1. Capture timestamp, environment, app version, correlation/request ID, recent structured logs, journal sequence, state revision, task ID, screenshot and relevant file details.
2. Trace `UI event -> Envelope -> gateway -> handler -> I/O/task -> state commit -> event -> UI render`.
3. Replay the smallest safe command sequence in an isolated workspace, or reproduce with real UI/Agent IPC; minimize the sequence when possible.
4. Compare before/after snapshots, expected/actual state, file output and visual result; identify root cause and fix in the owning layer.
5. Re-run the same real scenario, check logs for new errors and test one adjacent failure case. Add focused regression tests where useful, not as a substitute for real verification.

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
- Not verified / blockers:

## Hard rules
- Green tests are insufficient. No mock-only validation.
- Do not silently substitute API calls for a UI interaction requirement.
- If GUI cannot run in the environment, explicitly say UI verification is pending; do not fabricate screenshots or success.
- Diagnostics and replay must redact secrets and protect user files; screenshot capture needs authorization.

## Flatpak-readiness review
When touching file access, native dialogs, clipboard, URI opening, notifications, screenshots, IPC or build dependencies: check the sandbox implications against `docs/FLATPAK.md`. Do not claim Flatpak compatibility until an actual sandboxed build/install/run has been performed. When packaging is added, verify file selection, reopen/export, CLI/Agent access (if supported), Wayland behavior and logs inside the Flatpak sandbox.

## Launch verification gate
- Verify real `kogaview` no-args -> Browser, `open FILE` -> Viewer, `open-folder DIR` -> Browser, and Viewer -> Editor via explicit action.
- Verify Linux Open With via installed `.desktop`, then Windows associations when Windows is available. Check existing-instance forwarding.
- Do not mark build/run/install recipes complete until `just run` demonstrably builds and launches the exact fresh artifact.
