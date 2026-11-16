# KogaView — Photo Manager & Editor

KogaView is a cross-platform native desktop photo viewer, library manager and
non-destructive editor. Every public operation is intended to be reachable both
from the UI and from typed commands (CLI, local IPC, MCP).

This repository is currently at **M1: desktop shell and browsing**. It contains a
real CXX-Qt/QML app with the Browser, Viewer and Editor workspaces, a persisted
configuration, portal file dialogs, async folder scanning and a typed command
gateway in Core. Editing, IPC, MCP and packaging are not implemented yet.

## Quick start

```sh
just setup     # check toolchain and platform requirements
just build     # configure + build the dev app into build/dev/bin/kogaview
just run       # build, then launch exactly that binary
just doctor    # versions, identity, canonical artifact, conflicts
just logs      # locate and tail the current dev instance log
```

Arguments are forwarded, e.g. `just run open /path/to/photo.jpg` or
`just run open-folder ~/Pictures`. See `docs/CLI.md`.

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
- `docs/M1-REPORT.md` — desktop shell evidence and known gaps
- `docs/adr/` — recorded decisions

## Working with an agent

The repository is wired for [OpenCode](https://opencode.ai):

- `AGENTS.md` — the rulebook, loaded automatically (the only instructions file
  OpenCode V2 reads; there is no `CLAUDE.md`).
- `opencode.json` — pins `docs/WORKFLOW.md` and `docs/SESSION-STATE.md` as
  always-on instructions and refuses tool edits under `build/` and `target/`.
- `.opencode/skills/` — `real-window-verification` (build, launch, evidence,
  mutation checks), `qt-quick-pitfalls` (QML traps) and `cxx-qt` (the Rust ↔ Qt
  bridge), loaded on demand.
- `.opencode/commands/` — `/doctor`, `/rebuild`, `/test`, `/run`, `/logs`,
  `/verify`, `/handoff`, all thin prompts over `just`.

## Identity

| | Dev build | Production build |
|---|---|---|
| Name | KogaView (Dev) | KogaView |
| App ID | `io.github.tienv2i.KogaView.Dev` | `io.github.tienv2i.KogaView` |
| Config | `~/.config/kogaview-dev/config.json` | `~/.config/kogaview/config.json` |
| State | `~/.local/state/kogaview-dev/` | `~/.local/state/kogaview/` |
| Cache | `~/.cache/kogaview-dev/` | `~/.cache/kogaview/` |

The app ID is provisional until the project namespace is confirmed; see
`docs/adr/0001-project-identity-and-naming.md`. Runtime directories deliberately
use the short name; see `docs/adr/0002-runtime-directories-and-config.md`.

## License

MIT — see `LICENSE`.
