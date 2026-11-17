# Build, run, install and package contract

## One entry point
Use `just` as the developer/agent command surface; Cargo + CMake + CXX-Qt are implementation details. Never run an arbitrary old binary after a failed build.

| Recipe | Contract |
|---|---|
| `just setup` | Check Rust, CMake, Qt6, C++ toolchain, just and platform requirements |
| `just build` | Build debug app into a known output directory; fail on any error |
| `just run [ARGS]` | Build first; execute exact artifact just built; forward all args |
| `just test [SELECT]` | Run tests: the translation and packaging checks, the Cargo workspace tests, then the Qt Quick suites that load the real `crates/desktop/qml/*.qml` (offscreen QPA) and assert on what Qt Quick does — viewer transforms plus the commands the browser/explorer emit for real clicks. Still not proof the interactive UI is usable. Bare `just test` is the pre-commit gate; `cargo`, `translations`, `packaging`, `qml`, `viewer`, `browser`, `cache`, `state`, `settings`, `editor` or `language` narrow it to one part so the feedback loop stays seconds long |
| `just doctor` | Print versions, app ID, binary paths, build mode, runtime mode and installation conflicts |
| `just logs` | Locate/read current dev instance structured logs |
| `just install` / `uninstall` | Native install/remove into `KOGAVIEW_PREFIX` (`/usr/local` by default) without silently deleting user data, and without changing the default image viewer — see "Install contract" below |
| `just package` | Produce native distributable |
| `just flatpak-build` / `flatpak-run` | Later: sandbox build and actual runtime verification |

### Two-tier feedback loop
- While editing, run only what the edit can break: `just test cargo` (`~0.3 s`,
  or the length of a Rust rebuild), `just test viewer` (`~1 s`),
  `just test browser` (`~7 s`), `just test cache` (`~11 s`). Same suites, same
  assertions — just not the other ones.
- Before a commit, run bare `just test`: that is the gate, and a green single
  suite says nothing about the suites it did not run. It costs whatever its
  suites cost — `~19 s` when nothing has to be rebuilt, `~45 s` when a change
  forces one (measured on this tree; the builds are the variable part, not the
  orchestration).
- The gate configures CMake only when `build/dev/CMakeCache.txt` is missing and
  otherwise lets `cmake --build` regenerate (it does, inside the build), and it
  builds every selected target in one `cmake --build` invocation instead of one
  call per suite — worth `~3 s` (`14.7 s → 11.5 s`) on a run that rebuilds all
  three.

## Translations in the build
- `i18n/kogaview_vi.ts` is compiled by `lrelease` into
  `build/dev/i18n/kogaview_translations.rcc` (a generated `.qrc` plus
  `rcc --binary`, because Qt 6's `rcc` refuses a bare `.qm` argument) and
  registered at `:/i18n/` by `cpp/language.cpp`. A build without `lrelease`
  still links and runs: every string stays its English source text.
- `lrelease`/`lupdate` are found by `scripts/find_lrelease.py`; a PySide6 copy
  works, e.g. `PATH=/tmp/opencode/lrel/bin:$PATH just build`, or set
  `KOGAVIEW_LRELEASE`.
- `lupdate i18n/kogaview_ts.pro` refreshes the catalogue after QML string
  changes; `just test translations` (part of the full gate) fails when the
  catalogue and the C++ table in `cpp/translations.cpp` disagree or an entry is
  unfinished.

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

## Install contract

`just install` always builds the optimized `release` preset before installing;
it never copies `build/dev` or a stale artifact. The default prefix is
`/usr/local`; set `KOGAVIEW_PREFIX` to install elsewhere, for example:

```sh
KOGAVIEW_PREFIX="$HOME/.local" just install
```

The native Linux install owns exactly these files:

- `${prefix}/bin/kogaview`
- `${prefix}/share/applications/io.github.tienv2i.KogaView.desktop`
- `${prefix}/share/icons/hicolor/scalable/apps/io.github.tienv2i.KogaView.svg`
- `${prefix}/share/icons/hicolor/{16x16,24x24,32x32,48x48,64x64,128x128,256x256}/apps/io.github.tienv2i.KogaView.png`
- `${prefix}/share/metainfo/io.github.tienv2i.KogaView.metainfo.xml`

It also writes `${prefix}/share/icons/hicolor/index.theme` — the system
`hicolor/index.theme` plus the size sections it is missing, which the icon cache
needs — and refreshes the desktop database and the hicolor icon cache
(`gtk-update-icon-cache -f -t`). The rasters are rendered from the SVG with
PySide6 so the drawing cannot fork. `just uninstall` removes only those files,
including the generated `index.theme`; it keeps the user's config,
state/journal/logs and cache. The install registers supported image MIME types
for **Open With** but does not run `xdg-mime default`; the existing default
viewer is never changed silently.

`just test packaging` runs `scripts/check_packaging.py`. The check keeps the
desktop MIME list synchronized with the protocol's advertised extensions and
shared-mime-info, requires the `Graphics;Viewer;` menu categories, validates
the desktop entry and AppStream metadata, checks the application ID across the
desktop file, icon and metadata, checks that every language in
`DESKTOP_LANGUAGES` has both its desktop keys and its `xml:lang` in the
metadata, and checks that the raster icon list is non-empty and named after the
app ID under `apps/`.

## Completion gate
Build success -> launch real app -> exercise Browser/Viewer/Editor -> inspect logs/journal -> inspect screenshots and output files -> report actual platforms verified. A green test suite is never the final gate.
