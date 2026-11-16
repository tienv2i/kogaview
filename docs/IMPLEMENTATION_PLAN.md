# Implementation Plan — KogaView (Photo Manager & Editor)

Status: **approved; M0 complete (2026-11-15)**
Scope of analysis: this repository only (`AGENTS.md`, `README.md`, `docs/*`, `justfile`, `scripts/dev.py`, `packaging/*`) plus the local toolchain. No code from other projects was read.

This plan turns the specification bundle into an ordered, verifiable delivery sequence. It does not itself implement features. Deviations from `docs/` require an ADR in `docs/adr/`.

---

## 1. What the bundle actually is

| Artifact | Role | Current state |
|---|---|---|
| `AGENTS.md` | Binding engineering rules and first-milestone definition | Spec |
| `docs/PRD.md` | Product scope, non-functional requirements, phases | Spec |
| `docs/ARCHITECTURE.md` | Crate/module layout, command bus, persistence, security, testing | Spec |
| `docs/WORKFLOW.md` | Delivery, debugging and evidence rules, completion report | Spec |
| `docs/WORKSPACES.md` | Browser/Viewer/Editor behavior and launch matrix | Spec |
| `docs/BUILD.md` | `just` contract, dev/prod identity, canonical artifact | Spec (contract only) |
| `docs/CLI.md` | `kogaview` launch surface, target `kogactl` surface | Spec (nothing implemented) |
| `docs/DESKTOP.md` | Linux/Windows MIME and Open With contract | Spec |
| `docs/FLATPAK.md` | Sandbox constraints and future acceptance checklist | Spec |
| `justfile` | Thin dispatcher to `scripts/dev.py` | Implemented (M0) |
| `scripts/dev.py` | `setup`/`doctor`/`build`/`run`/`test`/`logs` orchestration | Implemented (M0); install/package refuse until M6 |
| `packaging/*` | Desktop file template, notes | Template only |
| `README.md` | Describes the current M0 state | Updated |

M0 created the Cargo workspace, CMake/CXX-Qt project, Rust/QML shell, logging, tests and the `just` build/run surface. The image library, command bus and packaging remain future work.

## 2. Binding contracts extracted from the docs

These are the constraints the implementation must satisfy; they drive the plan's structure.

1. **Single path for every mutation:** `UI | CLI | MCP -> adapters -> Command Gateway -> handlers/Core -> AppState + infrastructure -> events -> adapters/UI`. No adapter mutates domain state directly.
2. **Qt is presentation only.** QML may hold hover/focus/animation state; it must not do filesystem I/O, image processing, or business rules.
3. **Core is Qt-independent** and owns domain logic, state transitions, I/O orchestration.
4. **One authoritative state owner**, monotonic revisions, ordered mutations, stale-revision detection, idempotency for retries.
5. **Typed protocol:** Envelope (protocol version, request id, command, context/expected revision, idempotency, correlation), Result (`completed`/`accepted`/`failed`, state revision, task id), Query and Event as distinct types.
6. **Long work is asynchronous, bounded, cancellable, observable.**
7. **Non-destructive editing**; originals preserved; explicit export with staged/atomic writes.
8. **Three workspaces** owned by Core state, with an exact launch matrix (no args -> Browser, file -> Viewer, folder -> Browser, Editor only by explicit action).
9. **Single instance** with request forwarding; dev/prod/Flatpak identities, XDG dirs, DB and IPC endpoints are separate.
10. **Flatpak-ready from day one**: XDG paths, portal-friendly file access, stable image identity separate from paths, no broad permissions, least-privilege IPC.
11. **Observability:** structured logs, sequential sanitized command journal, correlated events, revisions, task lifecycle, screenshots, diagnostic bundle.
12. **Verification is real execution**, not tests alone: launch the app, interact, inspect state/journal/logs/screenshot/files, and report unverified areas honestly.
13. **`just` is the only developer entry point**; `just run` must build and launch the exact fresh artifact, never a stale binary.
14. **No premature crate explosion, no second command path, no GPU-first design.**

## 3. Gaps, ambiguities and decisions required

| # | Gap / inconsistency | Why it matters | Proposed resolution |
|---|---|---|---|
| D1 | ~~Product naming inconsistent~~ | App ID leaks into desktop file, Flatpak, XDG dirs, socket names, DB path | **Resolved in ADR 0001**: KogaView, `kogaview`/`kogactl`, `io.github.tienv2i.KogaView` (+ `.Dev`) |
| D2 | App ID namespace ownership is unconfirmed | Cannot ship MIME/Flatpak metadata if the namespace is not owned | Using `io.github.tienv2i.KogaView` provisionally; confirm ownership before M6 |
| D3 | `justfile` shell portability | Target includes Windows | **Resolved**: recipes use the default shell and only call `python3 scripts/dev.py`; Windows verification still pending |
| D4 | ~~`scripts/dev.py` placeholder~~ | `doctor` must detect Qt/QML modules, compiler, display, IDs, conflicts | **Resolved in M0**; sqlite/index checks arrive with M2 |
| D5 | `app.open_files { activation }` semantics are undefined | In-process UI vs forwarded request differ | Define: `activation=true` means "raise/focus the window if permitted"; forwarding preserves the flag; in-process UI always sets it |
| D6 | Protocol details are named but not specified (error codes, event kinds, query list, revision rules) | Contract tests and CLI/MCP parity depend on it | Write `docs/adr/0001-command-protocol.md` in M1 and freeze v1 before IPC/MCP |
| D7 | `editor.enter { image_id }` appears before image identity work | Contract stability | Define opaque `ImageId` now (serde newtype), back it with content hash later; never expose raw path as ID |
| D8 | Query surface is unspecified (`debug state`, task status, search, etc.) | Needed by `kogactl`/MCP | Minimal v1 queries: `state.snapshot`, `task.status`, `task.list`; extend per milestone |
| D9 | Capability model has no source for in-process UI | Screenshot/delete authorization | In-process local user = full local capability set; IPC/MCP require explicit grants; formalize in M5 |
| D10 | CI and history | Hygiene and reproducibility | **Partially resolved**: MIT license, `.gitignore`, initial commit. CI deferred until a remote/runner exists; do not claim CI coverage |
| D11 | ~~Qt 6.12 + CXX-Qt 0.10 compatibility unproven~~ | Blocks everything | **Resolved in M0**: builds and runs with Qt 6.12.0 and CXX-Qt 0.10.0 on Arch/Wayland |
| D12 | Screenshot capture under Wayland is not guaranteed | Every milestone's evidence gate needs screenshots | **Resolved for app windows**: M0 dev harness uses `QQuickWindow::grabWindow` after exposure; GNOME Shell desktop capture is denied to this app. Formalize as `debug.screenshot` in M1 |
| D13 | Editor undo/redo vs command journal distinction is stated but not modeled | Risk of conflating two histories | Separate `EditHistory` (recipe ops) from `CommandJournal` (all requests); ADR in M4 |
| D14 | ICC/color management depth is unspecified | Scope creep risk | M3 minimum: orientation + embedded ICC pass-through where Qt supports it; document limitations; no wide-gamut promises |

## 4. Verified local environment baseline (this machine)

| Item | Finding | Consequence |
|---|---|---|
| OS | Arch Linux, rolling | `pacman` available; `setup` should check distro packages rather than assume Debian |
| Session | Wayland (`wayland-0`), `DISPLAY=:0` | Real UI verification is feasible; must also check X11 fallback later |
| Rust | `rustc 1.99.1`, cargo present, crates.io reachable, `cxx-qt 0.10.0` already cached | CXX-Qt spike is viable offline-ish |
| Qt | 6.12.0, `/usr/lib/cmake/Qt6` with Quick, QuickControls2, Widgets, DBus, Sql, Svg; QML modules present | Sufficient for the desktop shell |
| CMake | 4.5.0 installed for M0 | `just setup` verifies it before building |
| just | 1.59.0 installed for M0 | `just` is the only developer entry point |
| C++ | `g++`, `pkg-config` present; sqlite3 3.54, libjpeg/png/webp present | Native deps OK |
| Package manager | `pacman` (no `apt-get`) | Setup instructions must be distro-aware |
| Git | repo initialized; initial M0 commit created | History starts at M0 |

M0 verified that `just setup`, `just build`, `just run`, `just test`, `just doctor` and `just logs` work; a broken build makes `just run` refuse to launch.

## 5. Target repository layout (incremental, not all at once)

```text
Cargo.toml                     # workspace; small initial member set
rust-toolchain.toml            # pinned toolchain (MSRV documented)
CMakeLists.txt + CMakePresets.json
justfile                       # thin dispatcher only
scripts/dev.py                 # cross-platform orchestration, real recipes
crates/
  app-protocol/                # M1: Envelope/Command/Query/Event/Result/Error/ImageId
  app-core/                    # M1: AppState, gateway, handlers, journal, task registry
  app-image/                   # M2/M3: decode, orientation, transforms, export
  app-storage/                 # M2: SQLite, cache, migrations, atomic writes
  app-runtime/                 # M2: tokio/rayon workers, progress, cancellation, limits
  app-observe/                 # M1 thin, M5 full: tracing, journal sink, bundle, replay
  app-ipc/                     # M5: UDS (Linux) / named pipe (Windows)
  app-mcp/                     # M5: MCP adapter over the same gateway
  app-platform/                # M6: portals, dialogs, theme, accessibility
  app-cli/                     # M5: kogactl; kogaview arg parsing if split
  desktop/                     # M0: CXX-Qt bridge, Qt adapter
  desktop/qml/                 # QML sources compiled into the QML module (no disk loading in release)
cpp/main.cpp                   # C++ entry point; only owns Qt application startup
docs/adr/                      # decision log
tests/                         # contract, IPC, golden-image, UI smoke
packaging/                     # existing templates, later real metadata
```

Initial crate set is deliberately **three**: `app-protocol`, `app-core`, `desktop` (plus the `kogaview` binary target). Split later only when a boundary is proven.

### Runtime identity (decided in M0)

| Aspect | Dev | Production |
|---|---|---|
| App name | `KogaView (Dev)` | `KogaView` |
| App ID | `io.github.tienv2i.KogaView.Dev` | `io.github.tienv2i.KogaView` |
| State/log/journal | `$XDG_STATE_HOME/kogaview-dev/` | `$XDG_STATE_HOME/kogaview/` |
| Cache | `$XDG_CACHE_HOME/kogaview-dev/` | `$XDG_CACHE_HOME/kogaview/` |
| Config/data | `$XDG_CONFIG_HOME/kogaview-dev/config.json` | `$XDG_CONFIG_HOME/kogaview/config.json` |
| IPC endpoint (M5) | `$XDG_RUNTIME_DIR/io.github.tienv2i.KogaView.Dev/control.sock` | `io.github.tienv2i.KogaView/control.sock` |
| Protocol version | same v1 | same v1 |

Runtime directories use the short application name while the reverse-DNS app ID stays
responsible for desktop identity; see ADR 0002. The build emits a compile-time
profile constant; runtime env override is allowed only for tests, never for
installed binaries.

## 6. Delivery milestones

Each milestone is a vertical slice with a hard evidence gate. A milestone is done only when the **real app** was launched and the evidence recorded; unit tests are supporting evidence.

### M0 — Build/runtime foundation and CXX-Qt spike (effort S–M, highest technical risk) — **complete**

Goal: a real, reproducibly built Qt window launched by `just run`, with correct identity and logging.

Work:
- Install/verify prerequisites (`cmake`, `just`); `just setup` and `just doctor` report distro, compiler, Qt/QML modules, display, app ID, paths, build mode, conflicts.
- Create Cargo workspace + `rust-toolchain.toml`; add initial crates with empty-but-compiling APIs.
- Create CMake project using CXX-Qt 0.10 + Corrosion (or the supported CXX-Qt CMake integration), Qt 6 Quick/QuickControls2.
- Build canonical artifact at a fixed path (e.g. `build/dev/bin/kogaview`); `CMAKE_RUNTIME_OUTPUT_DIRECTORY` or preset controls it.
- Minimal QML shell: Browser placeholder window, system palette/font, high-DPI untouched.
- Rewrite `scripts/dev.py`: `build`, `run`, `test`, `logs`, `install` (still refusing until implemented), strict fail-fast, no fallback binary.
- Logging skeleton: `tracing` JSON to XDG state dir (`logs/kogaview.jsonl.<date>`), one startup record with identity/version/SHA/profile/protocol version. Qt version is reported by `just doctor`. No journal yet (M1 adds `journal/commands.jsonl`).
- `.gitignore`, MIT LICENSE, initial commit. CI is deferred until a remote/runner exists and is not claimed as present.
- **Spike check:** CXX-Qt generated QObject with one invokable + one property, bound to QML.

Evidence gate (met on Arch Linux / GNOME Wayland):
- `just setup`/`doctor` output and toolchain versions recorded.
- `just build` succeeds; `just run` launches the exact `build/dev/bin/kogaview` artifact.
- Window screenshot captured through the dev-only Qt harness; startup JSON log contains app ID, profile, version, protocol version and boot ID.
- Broken-build check: `just build` failed and `just run` refused to launch (exit 2, no process).
- Bridge check: QML button invoked `devProbe`, Rust incremented `probeCount` and wrote a structured log record.

M0-only harness: `KOGAVIEW_DEV_SCREENSHOT` uses `QQuickWindow::grabWindow` after exposure and is compiled only in Debug builds. M1 replaces it with the permission-checked `debug.screenshot` command. GNOME Shell's desktop-wide screenshot D-Bus method denied access, confirming that app-window capture is the supported path here.

Fallback not needed: CXX-Qt 0.10 built successfully with Qt 6.12.

### M1 — Protocol, state, gateway, browsing vertical slice (effort M) — **in progress**

Goal: `kogaview`, `kogaview open FILE`, `kogaview open-folder DIR`, and UI-driven navigation all produce one observable Core state transition and render.

Work:
- `app-protocol` v1: `Envelope`, `Command` (`app.open_files`, `app.open_folder`, `workspace.switch`, `workspace.back`, `editor.enter` stub), `Query`, `Event`, `Result`, `ErrorCode`, `ImageId`, `PathOrUri`, `Context`, `protocol_version = 1`.
- Future ADR: wire JSON shape, revision rules (every mutation carries optional `expected_revision`; UI sends the last observed revision; stale -> typed `STALE_REVISION`), idempotency key scope, event sequencing, error taxonomy, timestamps excluded from semantic equality.
- `app-core`: `AppState` (revision, active workspace, browser {folder, entries, selection}, viewer {images, current}, status), reducer-style handlers, single ordered command queue (one owner task, not scattered mutexes), journal writer (sanitized, append-only JSONL), event bus (sequence IDs) with backpressure policy, task registry placeholder.
- Startup/activation mapping: CLI args -> the same `Envelope` commands as UI. No-arg -> Browser; `open` -> Viewer with deterministic navigation set; alias positional files; `open-folder` -> Browser; typing `kogaview FILE` works; invalid input -> structured error + non-zero exit + no GUI state change.
- Image open: validate path/format, canonicalize while preserving a stable identity placeholder, read metadata, commit Viewer state. Phase 1 rendering may use Qt's image provider via a `file://` URL supplied by Core, but **Core decides** what is open; QML only displays it. Unsafe/unsupported/missing paths surface typed errors.
- Qt bridge: one QObject exposing read-only `revision`, `workspace`, `browserFolder`, `browserItems` (list model later), `currentImageUrl`, `currentIndex`, `lastError`, plus invokables that only submit commands. Adapter observes events and updates properties; no QML `FolderListModel`, no QML file reads/writes.
- QML: Browser empty/dir placeholder, Viewer with image + fit + next/previous + Back, Editor placeholder only reachable through explicit Edit action.
- `debug.screenshot` implemented as a dev-only, adapter-orchestrated capture after render readiness (foundation for all later evidence).
- Contract tests for protocol serialization/revision behavior; core unit tests for command semantics.

Evidence gate (all must be shown):
- Launch matrix: no args -> Browser; `open FILE` -> Viewer showing the actual image; positional alias; `open-folder DIR` -> Browser listing; invalid file -> non-zero exit and typed error.
- UI actions: double-click item (when directory listing exists), Viewer Back restores Browser folder/selection, Edit enters Editor, Back returns.
- Journal excerpt with request ids, ordering, state revisions; startup + open logs; state snapshot; screenshots of Browser and Viewer.
- Restart check: no second state owner; no implicit Editor.
- Explicitly note what is still stubbed (single-instance forwarding, DB, thumbnails).

### M2 — Browser library: indexing, thumbnails, caching, watching (effort L)

- `app-storage`: SQLite WAL schema + migrations, image table with stable `ImageId` (content hash + size; path as mutable attribute), folders, metadata, thumbnails cache keys.
- `app-runtime`: bounded tokio/rayon scan + thumbnail pipeline, progress/cancel, limits (max dimensions/memory), task queries/events.
- Browser: virtualized grid, selection, sort/filter/search basics, thumbnail cache keyed by source revision/size/profile, missing/moved/renamed reconciliation, filesystem watch.
- Startup reconciliation and recovery; access revalidation (revoked/missing).
- Evidence: scan a real folder (large + Unicode + symlink + unreadable files), measure UI responsiveness, kill mid-scan and restart, verify DB/cache contents, compare CLI-opened folder state.

### M3 — Viewer completeness and metadata (effort M)

- Zoom/pan/fit/fullscreen/slideshow, deterministic next/previous, EXIF orientation, ICC pass-through, metadata panel, keyboard shortcuts, error placeholders for corrupt files.
- Bounded preview decode and cache; memory ceiling test with large images.
- Evidence: real large/HiDPI/EXIF-rotated images, screenshots, memory observation, CLI equivalent state.

### M4 — Non-destructive Editor, history, export (effort L)

- Working-document model per ADR 0003 (already landed with M1: decode once, apply edits directly, undo/redo as a bounded step stack). Remaining: exposure/brightness/contrast/saturation operations, before/after, and **export**: batch task, staged temp + atomic rename, collision policy, preserve source (hash before/after), cancellation cleanup.
- The `EditOperation` recipe stays serializable so a session format can be built on it; the display renders the materialized document, not a replay of the recipe.
- Evidence: edit -> preview -> export -> reopen exported file; verify original bytes unchanged; kill during export and check recovery; editor history vs command journal compared.

### M5 — IPC, `kogactl`, MCP, diagnostics, replay (effort L)

- `app-ipc`: Unix domain socket with peer credentials and permissions; Windows named pipe; single-instance lock and request forwarding (including startup race queueing).
- `kogactl`: status/open/open-folder/workspace/debug commands with identical Envelope semantics, `accepted` vs `completed`, progress/cancel.
- `app-mcp`: tools/resources mapped to existing commands/queries only; explicit capabilities for sensitive actions (screenshots, writes, deletes).
- `app-observe`: journal correlation, `debug logs/trace/state/events/tasks/screenshot/bundle`, redaction, sandboxed replay with explicit nondeterminism reporting.
- ADR 0004: capability model and IPC authorization; ADR 0005: Flatpak host-CLI transport decision (do not widen sandbox).
- Evidence: same scenario through UI, CLI and MCP with matching state revision/results; denial-path tests; bundle opened and inspected.

### M6 — Native integration, packaging, platform verification (effort L)

- Final App ID/name; `.desktop` (dev + prod variants), icons, AppStream, MIME list limited to codecs actually verified; `just install` to user prefix, clean `uninstall` that preserves user data; never hijack defaults.
- Open With JPEG -> Viewer with running instance forwarding; no-arg launcher -> Browser; folder command -> Browser.
- Windows installer/associations only when a Windows machine is available; otherwise mark unverified.
- Flatpak: build manifest, portals for file selection/URI opening, verify sandboxed open/edit/export/restart, permissions review. Only then claim Flatpak support.
- Evidence: installed desktop entry inspection, MIME registration before/after uninstall, screenshots from installed (non-dev) build, platform matrix with honest "not verified" cells.

## 7. Cross-cutting tracks (active from M0/M1)

| Track | Minimum commitment | Detailed in |
|---|---|---|
| Security | path/URI validation, no QML I/O, sanitized journal, no secrets in logs, capability gate before screenshots/writes over IPC, IPC permissions | M5 ADRs, `docs/FLATPAK.md` |
| Observability | structured JSON logs (`logs/kogaview.jsonl.<date>`), request/correlation ids, command journal from M1 (`journal/commands.jsonl`), events from M1, screenshots from M1, bundle from M5 | M1, M5 |
| Performance | decode/scan/thumbnail/export off GUI thread; bounded caches; image dimension/memory limits; virtualized grid; measure before optimizing | M2–M4 |
| Correctness | revision conflicts, idempotent retries, atomic saves, recovery records, reconciliation | M1, M2, M4 |
| i18n/a11y | externalized strings, system fonts/palette/DPI, keyboard navigation, accessible names; no fake GNOME Adwaita fidelity claims. **Started in M1:** English source text + a Vietnamese catalogue compiled into the binary, switchable while the window is open (ADR 0006); Core's status text is still English until it becomes a code + arguments | M3/M6 |
| Reproducibility | pinned toolchain and deps, vendoring plan for Flatpak offline builds, CI uses same `just` commands | M0, M6 |

## 8. Verification protocol (applies to every milestone)

1. Build from clean with `just build`; confirm the binary path and timestamp used by `just run`.
2. Launch the real app in the current session; read startup logs before touching the UI.
3. Perform the scenario by mouse/keyboard (and drag-and-drop/file manager where relevant).
4. Capture a screenshot after render readiness; inspect the actual visible result.
5. Inspect the command journal (`$XDG_STATE_HOME/kogaview[-dev]/journal/commands.jsonl`), state revision, events and task status; open output files from disk. The structured log (`logs/kogaview.jsonl.<date>`) is a separate file and does not contain journal or event records, so read both.
6. Repeat via CLI, then MCP when available; compare semantic state/results.
7. Exercise failure paths: missing file, permission denied, cancellation, repeated clicks, restart.
8. Fill the `WORKFLOW.md` completion report; list unverified items explicitly.

No milestone is closed on green tests or CI alone.

## 9. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| CXX-Qt 0.10 vs Qt 6.12 incompatibility | Medium | Blocks M0 | Timeboxed spike first; pinned fallback plan + ADR |
| Wayland screenshot limitations | Medium | Evidence gap | Adapter window capture; document limits; portal later |
| Scope explosion (indexing, ICC, editing, IPC, Flatpak) | High | Slipped delivery | Vertical slices and hard gates; no phase skipping |
| SQLite/filesystem divergence | Medium | Data loss/corruption | WAL, staged writes, recovery records, reconciliation tests + real kill tests |
| Accidental second instance / second DB writer | Medium | Corruption | Startup lock + socket ownership before DB open; test race |
| Flatpak later forces rework of file access/IPC | Medium | Rework | XDG + portal abstractions from M1; stable IDs not paths; capability design in M5 |
| Silent UI/business logic in QML | Medium | Architecture violation | Review checklist per PR; QML linting; adapter API limited to commands/queries |
| Stale binary or false "installed" claims | Low–Medium | Misleading results | `just run` fail-fast; `doctor` identity check; evidence includes paths/versions |
| Editor undo/redo conflated with journal | Medium | Wrong recovery semantics | Separate models + ADR before M4 |
| Large-image memory blowup | Medium | Crashes | Dimension/pixel limits, bounded decode, preview scaling, tests with real files |

## 10. Immediate next actions (M1, ordered)

1. Write the wire-format ADR (Envelope shape, revision rules, error taxonomy, event sequencing, idempotency).
2. Implement `app-protocol` v1 types and contract tests.
3. Implement the Core `AppState`, single ordered gateway, journal sink and event bus.
4. Add CLI argument mapping for `kogaview`, `kogaview open FILE...`, positional files and `kogaview open-folder DIR`.
5. Replace the M0 probe with the real state bridge and QML Browser/Viewer/Editor placeholders.
6. Implement image open (path validation, metadata, Core-owned viewer state) and remove the M0 screenshot harness in favor of the command-backed `debug.screenshot`.
7. Run the full M1 evidence gate on the real UI, including failure paths, then stop for review.

## 11. Definition of Done (global)

- Real UI exercised; screenshots, logs, journal, state revision and output files inspected.
- Equivalent CLI (and MCP when available) semantics verified.
- Failure paths and restart behavior checked.
- No QML business logic, no bypass of the Command Gateway, no stale binary.
- Flatpak implications reviewed when touching file access, dialogs, IPC, screenshots or dependencies.
- Evidence and unverified areas reported using the `WORKFLOW.md` template.
