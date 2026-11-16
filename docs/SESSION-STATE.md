# Session handoff — state at 2026-11-16

A snapshot of where the tree stands, written so the next session does not have to
re-derive it. Nothing here is a plan; it is what was measured and what is left.

## Tree

- Branch `main`, HEAD `c167661` (`docs(agents): name the journal and the log as
  the separate files they are`), 21 commits, working tree clean.
- Only untracked file: `next.txt` — the project owner's scratch note. **Do not
  commit it** (see `AGENTS.md`).
- **Not pushed:** `origin` is `https://github.com/tienv2i/kogaview.git` and it has
  no branches at all (`git ls-remote --heads origin` → 0 refs); `git push` fails
  with `remote: No anonymous write access.` Credentials are needed before any of
  this is off the machine.
- Debug binary `build/dev/bin/kogaview`: `just build` re-ran at HEAD `c167661`
  and the binary reports `git_sha c167661`, so a run now matches the tree. Nothing
  in `build/` or `target/` is tracked.

## Environment the evidence below was produced on

Arch Linux, GNOME on Wayland (`wayland-0`), Qt 6.12.0, rustc 1.99.1, cmake 4.5.0.
Facts that shaped the work and will shape the next one:

- No screen capture on this session: `grim` reports "compositor doesn't support
  the screen capture protocol", there is no `gnome-screenshot`, and
  `_NET_CLIENT_LIST` is empty. Window evidence comes from
  `KOGAVIEW_DEV_SCREENSHOT` (`QQuickWindow::grabWindow`), which photographs the
  app's own window in **either** mode. Prefer the real Wayland run — see the
  offscreen trap below — and keep `QT_QPA_PLATFORM=offscreen` for the cases where
  a popup would steal focus or no compositor is running.
- **Offscreen is not a faithful render (found 2026-11-16).** The offscreen QPA
  plugin runs with `QIcon::themeName()` empty and search paths only `:/icons`, so
  every themed icon disappears: the workspace switcher buttons render as empty
  blue squares and the folder tree loses its arrows and folder glyphs. A probe
  built against Qt6Gui reports `themeName ""` / `hasThemeIcon("folder-open-symbolic") false`
  offscreen, and `themeName "Adwaita"`-era search paths (`/usr/share/icons`, …)
  with `true` on this Wayland session. Any screenshot judged on icons, or on
  anything else the platform theme provides, must come from the Wayland run
  (`KOGAVIEW_DEV_SCREENSHOT`, no `QT_QPA_PLATFORM`), which grabbed fine here
  (1280×820 PNG, tooltips included). Do not conclude "icons are broken" from an
  offscreen picture.
- `xdg-desktop-portal-gnome` does not implement `org.freedesktop.impl.portal.OpenURI`;
  the portal returns a request handle but sends no `Response`, for KogaView and
  for bare `gdbus`/PyGObject probes alike. A returned handle is **not** proof a
  chooser was drawn.
- Qt's `qWarning`/`qInfo` from C++ reach stderr only — never the JSON log. QML
  warnings were not seen in either file on this build.

## What the last three commits changed

| Commit | Change | Verified how |
|---|---|---|
| `aee4480` | `stateJson` no longer carries the folder listing; it travels separately under `listingEpoch`, so a click re-publishes ~800 B instead of ~200 KB | `just test` (`kogaview_state_tests`, `tst_statesnapshot.cpp`) + real binary on 1 200 images with a 4 ms timer lateness probe (`docs/M1-REPORT.md` row 47) |
| `3f4453b` | Context menus sized from their labels (`Platform.textWidths` → `Theme.menuWidth`), "Open with…" → portal `OpenFile` with `ask: true`, filmstrip scrolls with the mouse wheel both ways | rows 48/49 added, row 46 rewritten in `docs/M1-REPORT.md`; screenshots in `/tmp/opencode` at the time (not committed); `openFileWithChooser` observed issuing `OpenFile (ask)` and receiving a handle |
| `c167661` | `AGENTS.md` / `WORKFLOW.md` / `CLI.md` / `IMPLEMENTATION_PLAN.md` / `WORKSPACES.md` now name the command journal (`journal/commands.jsonl`) and the log (`logs/kogaview.jsonl.<date>`) as the separate files they are | measured on the real dev binary with `XDG_STATE_HOME` redirected; `just test` green |

## How to reproduce the verification loop

```sh
just build                     # cmake --preset dev && cmake --build --preset dev
just test                      # pre-commit gate: 3 Rust + 4 Qt suites (~20 s warm)
just test viewer               # or: cargo | browser | cache | qml
cargo fmt --check
```

Real-window evidence without a compositor capture tool — prefer the real session:

```sh
# real Wayland window; the only route that renders themed icons
XDG_STATE_HOME=/tmp/opencode/kvS XDG_CONFIG_HOME=/tmp/opencode/kvC \
XDG_CACHE_HOME=/tmp/opencode/kvK \
KOGAVIEW_DEV_SCREENSHOT=/tmp/opencode/shot-wayland.png \
KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT=1 ./build/dev/bin/kogaview

# headless variant (no compositor, no icon theme — see the offscreen trap above)
QT_QPA_PLATFORM=offscreen QT_ASSUME_STDERR_HAS_CONSOLE=1 \
XDG_STATE_HOME=/tmp/opencode/kvS XDG_CONFIG_HOME=/tmp/opencode/kvC \
XDG_CACHE_HOME=/tmp/opencode/kvK \
KOGAVIEW_DEV_SCREENSHOT=/tmp/opencode/shot.png KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT=1 \
./build/dev/bin/kogaview
```

Both were run on 2026-11-16 at HEAD `c167661`: the Wayland run saved a
1280×820 PNG with the toolbar icons drawn; the offscreen run saved 1280×820 with
them empty, which is the trap, not a regression.

Dev hooks (Debug builds only, inert unless the variable is set; full list and
semantics in the "Dev harness" section of `docs/M1-REPORT.md`):

`KOGAVIEW_DEV_COMMANDS`, `KOGAVIEW_DEV_STATE`, `KOGAVIEW_DEV_SCREENSHOT[_DELAY_MS]`,
`KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT`, `KOGAVIEW_DEV_EXIT_AFTER_MS`,
`KOGAVIEW_DEV_GEOM`, `KOGAVIEW_DEV_WHEEL`, `KOGAVIEW_DEV_FILMSTRIP_WHEEL`,
`KOGAVIEW_DEV_COPY_IMAGE`, `KOGAVIEW_DEV_UI_REQUEST` +
`_ARG`/`_DELAY_MS`/`_REPEAT_MS` (`open-folder`, `open-external`, `open-with`,
`context-menu`), `KOGAVIEW_DEV_PORTAL_DISMISS_MS`.

Reading evidence by hand:

```sh
just logs                                        # newest logs/kogaview.jsonl.<date>
tail -n 5 ~/.local/state/kogaview-dev/journal/commands.jsonl
```

The journal has one line per command that reached the gateway (`id`, `command`,
`ok`, `revision`, sanitized `paths`); a UI action that emits no command leaves no
trace in either file.

## Fixtures

`/tmp/opencode` has been emptied since the last session; the fixtures used for
the measurements are gone (a gallery of 150 JPEGs, a 1 200-image folder, the
`photos`/`photoslink`/`sub` tree for the explorer checks). The Qt suites do not
need them: `tst_viewer` and `tst_thumbnails` build their own trees in
`QTemporaryDir`, and `tst_browser` feeds the view a stubbed `listFolders` over
fake `/root/...` paths, so nothing touches the disk. To re-measure a UI at scale,
regenerate a folder of JPEGs (any size works — the thumbnail cache keys on size)
and point `KOGAVIEW_DEV_COMMANDS` at it.

## Known gaps, in the words they were last measured with

- **The application chooser has never been seen drawn.** `PlatformHelper::openFileWithChooser`
  issues `org.freedesktop.portal.OpenURI.OpenFile` with `ask: true` (gated on
  OpenURI ≥ 2, this session reports 5), hands over a `QDBusUnixFileDescriptor`,
  and gets a request handle back. Whether a window appears is unverified here; the
  Windows path (`rundll32.exe shell32.dll,OpenAs_RunDLL`) has not been run at all.
- **Menu width is proven by pixels, not by a test for every label.** All real
  labels fit the 168 px floor, so pinning the width back to 200 px does *not* fail
  the suite; only `aLongLabelWidensTheMenu` (a probe label > 200 px) catches a
  regression. Do not upgrade that test's reputation without adding a real long
  label.
- **No physical input was driven by this session** for wheel/touchpad behaviour:
  the events are injected with the same device type and payload libinput produces,
  on the real window, but no hand was on a mouse.
- **QML warnings going nowhere** was observed, not explained; neither file gets
  them on this build.
- **Icons and the offscreen trap.** A themed icon is resolved by the QPA plugin's
  platform theme; offscreen does not load one, so a headless matrix of screenshots
  would report the whole icon set as broken. Always capture at least one Wayland
  frame, and if icons *are* missing there, check `QIcon::themeName()` before
  looking at `Icon.qml`.

## Next natural step

The features the owner asked for in `next.txt` are in `3f4453b`; the open item is
verification, not implementation: get a machine (or a session) where the portal
chooser can be seen, and run `just test` after any change to the menu labels
(`Theme.menuEntryLabels` must list every label a menu can show, or the width is
sized from an incomplete set).
