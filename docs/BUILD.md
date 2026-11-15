# Build, run, install and package contract

## One entry point
Use `just` as the developer/agent command surface; Cargo + CMake + CXX-Qt are implementation details. Never run an arbitrary old binary after a failed build.

| Recipe | Contract |
|---|---|
| `just setup` | Check Rust, CMake, Qt6, C++ toolchain, just and platform requirements |
| `just build` | Build debug app into a known output directory; fail on any error |
| `just run [ARGS]` | Build first; execute exact artifact just built; forward all args |
| `just test` | Run tests: Cargo workspace tests, then the Qt Quick suites that load the real `crates/desktop/qml/*.qml` (offscreen QPA) and assert on what Qt Quick does — viewer transforms plus the commands the browser/explorer emit for real clicks. Still not proof the interactive UI is usable |
| `just doctor` | Print versions, app ID, binary paths, build mode, runtime mode and installation conflicts |
| `just logs` | Locate/read current dev instance structured logs |
| `just install` / `uninstall` | Native install/remove without silently deleting user data |
| `just package` | Produce native distributable |
| `just flatpak-build` / `flatpak-run` | Later: sandbox build and actual runtime verification |

## Isolation and identity
- Dev app name `KogaView (Dev)`, production `KogaView`; distinct app IDs, config/data/cache, socket endpoints and database by default.
- Version/build metadata: semantic version, git SHA, build profile, Qt version and protocol version.
- `just run` refuses to launch if build fails; don't fall back to installed or previous executable.
- Never overwrite installed production data during development.
- CI uses same underlying build commands as local `just` recipes.

## Integration notes
- Start with Qt6/CMake/Cargo/CXX-Qt supported toolchain and pinned compatible versions; validate on each target OS.
- Define a single canonical executable location via CMake build preset or script; do not guess path from `target/`.
- Avoid embedding business logic in `justfile`; it orchestrates scripts/build system only.
- `install` is a separate explicit action; `run` must not install.
- For Flatpak, use the same production app ID/desktop metadata; do not grant broad filesystem or D-Bus permissions merely to make development IPC work.

## Completion gate
Build success -> launch real app -> exercise Browser/Viewer/Editor -> inspect logs/journal -> inspect screenshots and output files -> report actual platforms verified. A green test suite is never the final gate.
