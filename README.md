# KogaView — Photo Manager & Editor

KogaView is a cross-platform native desktop photo viewer, library manager and
non-destructive editor. Every public operation is intended to be reachable both
from the UI and from typed commands (CLI, local IPC, MCP).

This repository is currently at **M0: build/runtime foundation**. It contains a
real CXX-Qt/QML shell, the developer command surface and structured logging.
The image library, editing, IPC and packaging are not implemented yet.

## Quick start

```sh
just setup     # check toolchain and platform requirements
just build     # configure + build the dev app into build/dev/bin/kogaview
just run       # build, then launch exactly that binary
just doctor    # versions, identity, canonical artifact, conflicts
just logs      # locate and tail the current dev instance log
```

Arguments are forwarded, e.g. `just run open /path/to/photo.jpg` (the launch
matrix itself lands in M1).

## Documentation

Read `AGENTS.md` first, then:

- `docs/PRD.md` — product requirements
- `docs/ARCHITECTURE.md` — core/UI split, command bus, persistence
- `docs/WORKFLOW.md` / `docs/WORKSPACES.md` — delivery evidence and workspace routing
- `docs/BUILD.md` — build/run/install contract
- `docs/CLI.md` — `kogaview` launch surface and target `kogactl` client
- `docs/DESKTOP.md` — MIME / Open With integration
- `docs/FLATPAK.md` — sandbox constraints
- `docs/IMPLEMENTATION_PLAN.md` — milestones and gates
- `docs/M0-REPORT.md` — what was actually built, run and verified
- `docs/adr/` — recorded decisions

## Identity

| | Dev build | Production build |
|---|---|---|
| Name | KogaView (Dev) | KogaView |
| App ID | `io.github.huynhat.KogaView.Dev` | `io.github.huynhat.KogaView` |

The app ID is provisional until the project namespace is confirmed; see
`docs/adr/0001-project-identity-and-naming.md`.

## License

MIT — see `LICENSE`.
