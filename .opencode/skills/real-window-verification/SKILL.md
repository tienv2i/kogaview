---
name: real-window-verification
description: Use when a change in this repository has to be proven — building it, launching the real desktop app, exercising a feature, photographing evidence, mutation-checking a fix, or writing the completion report. Covers the isolated XDG launch, the KOGAVIEW_DEV_* harness, evidence by layer, and the honest-gap rules.
---

# Verifying a change on the real window (Tier 3)

`AGENTS.md` states the rule ("a green test suite does not prove a feature works on the real desktop").
This skill is the **Tier 3 (`/verify`)** recipe: what to run, in which order, and what each piece of evidence is actually worth. Check `docs/VERIFICATION-QUEUE.md` first for pending items that need deep verification.

Load `references/dev-harness.md` for the full `KOGAVIEW_DEV_*` list.

## 1. Baseline, before touching anything

```sh
git status --short          # what is already in flight
just doctor                 # only needed if environment/toolchain changed or build is broken
```

Record the dirty state and name the owning layer — protocol, Core, adapter (bridge), QML, or platform — because that decides which evidence will be able to fail.

## 2. Build, or do not claim anything

```sh
just build                  # prints the canonical binary: build/dev/bin/kogaview
```

A QML-only edit is picked up by `just test qml` **without** a rebuild, but the
*window* still needs one: a stale binary has passed for a fixed bug before. A
C++/Rust edit always needs `just build` before launch.

## 3. Launch the dev build

The dev build already uses its own app ID (`io.github.tienv2i.KogaView.Dev`) and
directories (`~/.local/state/kogaview-dev`, `~/.config/kogaview-dev`), separate
from the installed production app (`kogaview`):

```sh
QT_ASSUME_STDERR_HAS_CONSOLE=1 ./build/dev/bin/kogaview
```

Only override `XDG_STATE_HOME` / `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` under
`/tmp/opencode/kv/...` when testing a clean-start, changing locale/settings
without touching your dev `config.json`, or when you need a fresh single-run
journal.

Constraints that have actually cost time here:

- **One instance per app id.** A dev instance from an earlier run steals the app
  id, and every new window then reports `window is not exposed` for the
  screenshot. `pgrep -a kogaview` before starting; kill the stale one.
- `QT_ASSUME_STDERR_HAS_CONSOLE=1` keeps the compact human-readable copy of the
  `tracing` events on stderr, where `qInfo`/`qWarning` also go. QML warnings are
  in neither file.

## 4. Exercise it, like a person would

Prefer a real click/keypress. When the harness has to stand in, say so in the
report: a dev hook emits the signal a click would, or sends a real `Envelope`
through the gateway, but nobody pressed anything.

Drive the scenario from the workspace it belongs to (Browser/Viewer/Editor), and
always try one adjacent failure path: missing file, permission denied, rapid
repeat, restart.

## 5. Evidence, by the layer that owns the bug

| What changed | Evidence that can fail | What proves nothing |
|---|---|---|
| Protocol / Core command | command journal line (`ok`, `revision`), AppState delta, output file on disk | "the command returned" |
| Adapter / bridge | property value before ≠ after, journal revision reached the UI | a log line saying it ran |
| QML presentation (zoom, pan, scroll, menu) | a property/transform delta, or a photograph of the window | the journal (these emit no command), grep on the log |
| Menus / dialogs / text metrics | real-window screenshot: it is drawn, labels whole, chooser visible | `tests/qml` alone, a portal call that returned a handle |
| Packaging / desktop integration | installed `.desktop`, real `Open With`, sandboxed run | a green suite |

Read the journal and log in this order: log (boot id, `kogaview::scan`,
`kogaview::command`) → journal (id, order, revision) → AppState revision. Full
paths and field meanings: `AGENTS.md`, "Debugging by layer".

Nothing in the journal at all means the action never produced a command — a dead
handler, a menu item wired to nothing, or a QML error that removed the handler.
That is a QML bug; read the QML.

## 6. Photograph it

```sh
KOGAVIEW_DEV_SCREENSHOT=/tmp/opencode/kv/shot.png \
KOGAVIEW_DEV_SCREENSHOT_DELAY_MS=3000 \
KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT=1 \
./build/dev/bin/kogaview
```

- On this Wayland session a **real window** grab works (no compositor
  permission needed) and renders the icon theme.
- `QT_QPA_PLATFORM=offscreen` also produces a PNG, but loads **no icon theme**
  (`QIcon::themeName()` is empty, every themed icon blank). Use it to check
  layout and text, never icons, and never as proof that a dialog appeared.
- `grim` does not work here ("compositor doesn't support the screen capture
  protocol"), so the window grab is the only capture route.

A `docs/evidence/*.png` that goes into the repository is committed; scratch shots
stay in `/tmp/opencode`.

## 7. Mutation-check the fix, selectively

Revert the fix, or plant one small fault in a code path the fix owns, rebuild,
and confirm the new test **fails**; restore and confirm it **passes**. A handful
of targeted mutations, each aimed at a different claim — never a framework, never
a script that walks the tree.

Worked example (Viewer canvas menu, `docs/M1-REPORT.md` row 51): remove the
`popup()` call → the open test fails; drop a label from `Theme.menuEntryLabels` →
both the render test and the source-scan test fail; send `copy_to` instead of
`trash` → the command assertion fails with the actual command; delete the
`currentPath` guard → the no-image test fails; call `popup()` without the click
position → the placement assertion fails.

Report each mutation and what the suite did with it. Restore the file before
continuing, and re-run the suite afterwards so the report ends with a green run
you actually saw.

## 8. Write the report in the shape `docs/WORKFLOW.md` demands

Implemented behaviour · build and tests actually run · was the real app launched,
on which OS/session · UI actions actually performed · CLI/MCP actions · journal /
log / state / screenshot / file evidence · failures found and fixes verified ·
mutation check · **not verified, and why**.

"Não verificado" is a valid, expected line. Do not upgrade a synthetic click, an
offscreen render, a portal handle or a green suite into "works".
