# Architecture

## Core invariant
`Qt/QML UI | CLI | MCP -> adapters -> Command Gateway -> handlers/Core -> AppState + infrastructure -> state events -> adapters/UI`

UI owns only ephemeral presentation state (hover, focus, animations). Core owns domain and session state. No adapter may bypass command handlers for business mutations. Screenshots are UI adapter actions orchestrated via a permission-checked command/query, executed on the GUI thread after rendering is ready.

## Suggested modules (start small, split as needed)
- `app-protocol`: serde typed Envelope, Command, Query, Event, Result, errors and versioning.
- `app-domain`: image IDs, edit recipes, domain invariants.
- `app-state`: authoritative AppState, revisions, reducers, snapshots, patches.
- `app-core`: command gateway, handlers, orchestration and authorization.
- `app-image`: decoding, ICC/orientation, image transforms, preview and export.
- `app-storage`: SQLite, filesystem, cache, migrations, atomic save and recovery.
- `app-runtime`: Tokio I/O orchestration, Rayon CPU work, progress/cancel/limits.
- `app-observe`: tracing, journal, event stream, diagnostic bundle and replay.
- `app-ipc`: Unix domain socket on Linux, named pipe on Windows.
- `app-mcp`: MCP adapter that translates tools/resources to existing commands/queries.
- `app-platform`: desktop theme, native dialogs, portal and accessibility integration.
- `app-cli`: human/script CLI.
- `desktop`: Qt 6 QML, CXX-Qt Rust bridge and platform UI adapter.

Today's tree is four members, not the full list: `app-protocol`, `app-core`,
`app-editor` (the Editor's document, operations and pixels — ADR 0023) and
`desktop`. The rest of the list is where a boundary goes when it is proven, not
a scaffold to fill in.

## Command protocol
- Envelope: `protocol_version`, `request_id`, `command`, `payload`, `context.expected_revision` (where relevant), optional idempotency key and correlation context.
- Result: `request_id`, `status` (`completed` / `accepted` / `failed`), typed result/error, `state_revision` where applicable, `task_id` for accepted asynchronous work.
- Query: read-only; Event: sequenced state/task notification; neither is a disguised command.
- Long tasks report progress/cancellation/completion through task query and event stream.
- Mutations have a single ordering point. Reject or explicitly resolve stale revisions; retry-safe requests must not apply twice.
- Semantically identical commands under equivalent initial conditions have equivalent domain effects, not necessarily identical timestamps or task IDs.

## Persistence, history and replay
- SQLite WAL for indexes/metadata; transactionally persist state/journal where feasible.
- Filesystem and SQLite are not one atomic transaction: use staged writes, recovery records and reconciliation.
- Command journal records sanitized input, result, ordering, correlation and revision; it is distinct from domain events and undo/redo history.
- Edit recipe stores operations; preview and export render from original + recipe.
- Snapshots accelerate recovery. Replay must isolate side effects, control external inputs and explicitly report nondeterminism.
- Events have sequence IDs, subscriptions, resume strategy and backpressure handling.

## Performance and security
- Lazy loading, virtualized grids, preview/thumbnail LRU caches keyed by source/edit revision/size/color profile.
- Enforce image dimensions/memory limits; consider malformed files untrusted input.
- Prefer CPU pipeline first, GPU only after profiling.
- Local IPC not exposed over public TCP by default; Linux socket permissions, Windows named-pipe ACL; capability checks for filesystem writes, deletes and screenshot capture.
- Integrate Qt system palette/fonts/scale; do not manually double-scale; GNOME Adwaita fidelity may need extra integration beyond Qt Quick Controls.

## Testing strategy
Core unit/property tests, command contract tests, image golden tests, IPC integration tests and platform UI smoke tests are useful but secondary to real feature execution and evidence. Do not introduce a full event-sourcing framework or microservices by default.

## Flatpak and sandbox boundary
- See `docs/FLATPAK.md` for the deployment contract. Platform adapters abstract portal-backed file picking, URI opening, desktop services and permission grants.
- Do not treat host filesystem paths or unrestricted session D-Bus as guaranteed capabilities. Persist stable file identity separately from paths, and handle revoked/missing access.
- External CLI/MCP access to a sandboxed instance is a separate, explicitly authorized IPC boundary; in-process UI commands remain unchanged.
- Keep dependency/build metadata suitable for reproducible, offline Flatpak builds.

## Workspace and activation
- `AppState` includes `active_workspace` and Browser/Viewer/Editor state; Core owns navigation transitions and restoration context.
- CLI args, file-manager activation, QML interactions and MCP requests map to the same typed commands.
- Dev/prod/Flatpak app identities and IPC namespaces are distinct; file access must remain portal/sandbox-compatible. See `WORKSPACES.md`, `BUILD.md`, `DESKTOP.md`.

## Shared Desktop & QML Component Libraries (v1.1.0)
- **`ImageCanvas.qml`**: Shared GPU-friendly image viewport for both Viewer and Editor (zoom-at-cursor, free pan via `panMargin`, double-click Fit/100%, document↔viewport coordinate mapping).
- **`SidePanelRail.qml`**: Vertical panel toggle rail with bottom Hide-all action (used for Editor's right panels).
- **`ViewerModePopup.qml` / `ViewerCompactHud.qml` / `ViewerColorPopover.qml`**: Modular Viewer chrome controls — unified layout/display popover (single-click preview, double-click apply & close), 4-edge dockable magnetic-snap Floating HUD for Compact & Fullscreen modes, and non-dimming floating Color & Light popover synced with `RightDock`.
- **`ViewerDualSpread.qml` / `ViewerWebtoonView.qml`**: Modular Viewer display engines — header-only smart two-page spread pairing (LTR/RTL, cover & landscape handling) inside `ImageCanvas`, and virtualized continuous vertical Webtoon reader with Smart Auto-Fit and bounded VRAM decoding.
- **`DialogFrame.qml` / `DialogFooter.qml`**: Shared app-themed dialog chrome with auto-fit height, interactive edge/corner resizing, and overflow-only scrollbars.
- **`SystemDialogs.qml`**: Unified XDG Desktop Portal facade (`FileChooser.OpenFile`, `SaveFile`, directory selection) with Qt fallback for non-portal environments.
- **`ColorPickerDialog.qml`**: App-themed color chooser with 2D Saturation–Value spectrum, vertical Hue bar, RGB steppers, Hex input, quick swatches, and XDG Portal `Screenshot.PickColor` screen eyedropper.
- **`ColorAdjustPanel.qml`**: Shared Light & Color adjustment controls (Brightness, Contrast, Saturation with steppers & sliders), reused for Viewer (view-only 60 fps `MultiEffect` preview) and Editor (`editor_adjust_color` Core command).
- **`EditorResizePanel.qml` / `EditorCanvasSizePanel.qml` / `UnitField.qml`**: Modular sidebar panels with `px` / `%` unit selection and live 60 fps GPU canvas previews.
- **C++ Platform & Cache Services (`cpp/`)**: `ThumbnailCache` (bounded worker pool + synchronous `lookup()` hit path), `PlatformHelper` (XDG Portals, theme palette sync, clipboard), and `InputFocusDismissFilter` (clears text input focus on outside clicks so workspace shortcuts such as `Space` always respond immediately).
