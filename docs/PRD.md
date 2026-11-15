# Product Requirements — Photo Manager & Editor

## Goal
Cross-platform native desktop photo viewer, library manager and simple non-destructive editor. Entire public feature set is accessible to human users through UI and to scripts/agents through typed commands.

## Functional scope
- Browse folders and image library; thumbnails, grid, image viewer, zoom/pan, fit, fullscreen, slideshow.
- Search, filter, sort, tags, favorites, collections; read EXIF, orientation and ICC profiles.
- Index metadata in SQLite; watch filesystem changes; handle missing/moved/renamed files; use stable image IDs.
- Edit: rotate, flip, crop, resize, exposure, brightness, contrast, saturation; live preview, before/after, undo/redo, batch export.
- Non-destructive edit recipes and explicit export; source originals preserved by default.
- CLI, local IPC and MCP support for commands, queries, task status, event subscriptions and permitted screenshots.
- Localization; system fonts, palette, icon theme, DPI/scale, native dialogs and accessibility on GNOME/KDE/Windows where available.

## Non-functional requirements
- Responsive UI: decoding, scanning, thumbnailing and exports off GUI thread; bounded CPU/memory and caches.
- Reliable saves: temporary files, atomic rename when supported, recovery after interruption; SQLite migrations and transactions.
- Observability: structured logs, sequential command journal, correlated event timeline, state revisions, screenshots, diagnostic bundle.
- Security: filesystem scope, least privilege, local IPC access control, dangerous-action confirmation, log redaction, safe replay sandbox.
- Correctness: revision/conflict checks, typed errors, idempotent retry policy, reproducible edit operations where practical.
- Packaging: Flatpak-ready architecture from day one (sandbox, XDG paths, portals, permissions, IPC); package later. Linux native packages and Windows installer as needed; smoke-check on each target platform.

## Acceptance principle
No feature is marked verified solely because build/tests/CI pass. Launch the real app, interact through UI, inspect visible state and real output, compare equivalent CLI/MCP operation, and document what could not be verified.

## Suggested delivery phases
1. Shell + typed command protocol + state + `OpenImage` vertical slice.
2. Viewer, library indexing, thumbnails and caching.
3. Non-destructive editing, history and export.
4. IPC, MCP, journal replay and agent diagnostics.
5. Native integration, packaging, profiling and platform verification.

## Launch and workspaces
- No-argument launch -> Browser; open file(s) -> Viewer; open folder -> Browser; Editor requires explicit entry.
- File manager image Open With must activate Viewer; existing instance must accept requests. See `WORKSPACES.md` and `CLI.md`.
- Unified build/run/install entry point and native MIME integration are initial requirements, not later polish.
