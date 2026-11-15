# M0 Completion Report — Build/runtime foundation

Date: 2026-11-15
Commit at verification: `70c4a6cc1402`
Milestone: M0 (see `docs/IMPLEMENTATION_PLAN.md`)

## Implemented behavior

- Cargo workspace with three initial crates: `kogaview-protocol`,
  `kogaview-core`, `kogaview_desktop` (CXX-Qt static library) plus the
  `kogaview` CMake/Qt executable.
- CXX-Qt 0.10 + CMake (Corrosion) + Qt 6.12 shell; QML module
  `io.github.tienv2i.KogaView`, Browser placeholder with header/footer identity.
- Core identity: dev/prod app IDs, display names, XDG state/cache/config/data
  paths, build version and git SHA, protocol version constant.
- Structured JSON logging to the XDG state directory plus compact stderr, with
  startup/shutdown records and a boot ID. `KOGAVIEW_PROFILE` is honored only in
  debug builds.
- Real `just` surface: `setup`, `doctor`, `build`, `run`, `test`, `logs`.
  `install`, `package`, `flatpak-*` still fail intentionally.
- Canonical artifact `build/dev/bin/kogaview`; `just run` builds first and
  refuses to launch on build failure.
- Temporary M0 bridge probe (`devProbe`) proving QML → Rust invokable and
  property update. To be removed in M1.
- Debug-only app-window screenshot harness (`QQuickWindow::grabWindow`) for
  evidence. To be replaced by the permission-checked `debug.screenshot` in M1.
- MIT license, ADR 0001 for naming/identity, updated docs and packaging template
  to KogaView naming (`kogaview`, `kogactl`).

## Build and tests run

| Command | Result |
|---|---|
| `just setup` | pass; Rust 1.99.1, CMake 4.5.0, just 1.59.0, Qt 6.12.0 |
| `just build` (clean, after `rm -rf build/dev`) | pass; ~2 min; binary at `build/dev/bin/kogaview` |
| `just test` | pass; 6 unit tests (5 core, 1 protocol), 0 failed |
| `just run` (with screenshot harness env) | pass; launched exact canonical artifact |
| Broken-build check | pass: `just build` exit 2; `just run` exit 2, no process launched |

## Real app launched

- OS: Arch Linux (rolling), kernel 7.2.15.
- Session: GNOME on Wayland (`wayland-0`), Qt 6.12.0.
- Window showed `KogaView (Dev)`, version `0.1.0`, git SHA `70c4a6cc1402`,
  profile `dev`, app ID `io.github.tienv2i.KogaView.Dev`, workspace `browser`,
  state revision `0`, protocol `v1`.

## UI actions actually performed

- Launched with no arguments; Browser placeholder rendered.
- Used keyboard input injection (temporary `ydotool`, removed afterwards) to
  focus the probe button and activate it. `probeCount` incremented to 10 and
  Rust emitted matching structured log records.
- Captured the app window after render readiness via the debug harness.

No file open, folder navigation, editing, zoom/pan or drag-and-drop exists yet;
those are M1+ behavior and were not claimed.

## CLI/MCP actions actually performed

- `just`, `just setup`, `just doctor`, `just build`, `just run`, `just test`,
  `just logs` were exercised.
- `kogaview` argument launch matrix (`open FILE`, `open-folder DIR`) is **not
  implemented** yet (M1).
- `kogactl` and MCP do not exist yet (M5).

## Evidence

- Screenshot (Browser): `docs/evidence/M0-browser.png`
- Screenshot (bridge probe, count 10): `docs/evidence/M0-bridge-probe.png`
- Log directory:
  `$XDG_STATE_HOME/io.github.tienv2i.KogaView.Dev/logs/kogaview.jsonl.2026-11-15`
- Startup record (abridged):

```json
{"timestamp":"2026-11-15T06:50:46.374214Z","level":"INFO","fields":{"message":"application starting","app_id":"io.github.tienv2i.KogaView.Dev","display_name":"KogaView (Dev)","profile":"dev","version":"0.1.0","git_sha":"70c4a6cc1402","protocol_version":1,"state_dir":"/home/huynhat/.local/state/io.github.tienv2i.KogaView.Dev","log_dir":"/home/huynhat/.local/state/io.github.tienv2i.KogaView.Dev/logs","boot_id":"boot-1794725446374-723513"},"target":"kogaview::startup"}
```

- Probe record:

```json
{"timestamp":"2026-11-15T06:45:30.932313Z","level":"INFO","fields":{"message":"M0 bridge probe","probe_message":"probe from QML","probe_count":9},"target":"kogaview::bridge"}
```

- `just doctor` confirmed the canonical binary, dev app ID, Qt/QML modules,
  Wayland session, absent install conflict and current log path.

## Failures found and fixes verified

1. CXX-Qt panicked on `../qml/Main.qml`: QML file was outside the crate and the
   relative path escaped the module export. Moved QML to `crates/desktop/qml/`
   and rebuilt clean.
2. CMake target mismatch: crate package `kogaview-desktop` vs Corrosion target
   `kogaview_desktop` prevented header export. Renamed the package to
   `kogaview_desktop`; generated header now exports and compiles.
3. CXX-Qt rejects `#[allow(...)]` on the bridge module. Moved the allow to the
   crate root.
4. `scripts/dev.py` had an f-string parenthesis bug; fixed and re-ran `setup`,
   `doctor`, `build`, `run`, `test`, `logs`.
5. Duplicate JSON `message` key in the probe log; renamed the field to
   `probe_message` and rebuilt.
6. GNOME Shell desktop screenshot D-Bus method returned `AccessDenied`; switched
   evidence capture to the app-window Qt harness. This also matches the
   architecture guidance for screenshots.

## Not verified / limitations

- M1 launch matrix (`kogaview open FILE`, `open-folder DIR`, Viewer/Editor
  navigation), image decoding, command gateway, journal and state revisions are
  not implemented.
- No release build, native install, MIME/Open With, Flatpak, Windows, single
  instance or IPC verification.
- CI is not configured; the repository has no remote/runner.
- HiDPI scaling, screen-reader behavior and GNOME/KDE theme fidelity were not
  measured.
- The M0 probe and screenshot harness are temporary and must not ship as-is.
