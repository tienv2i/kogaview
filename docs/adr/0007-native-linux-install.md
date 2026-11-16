# ADR 0007: Native Linux install is release-only and does not hijack defaults

- **Status:** Accepted
- **Date:** 2026-11-16

## Context

KogaView needs to appear in Linux file managers' **Open With** actions and in
the image-viewer application group. Development binaries must not be confused
with the installed application, and installation must not silently change the
user's default image viewer.

## Decision

`just install` builds the CMake `release` preset and installs the production
identity `io.github.tienv2i.KogaView`. The default prefix is `/usr/local`; the
`KOGAVIEW_PREFIX` environment variable may override it. The install owns only:

1. `${prefix}/bin/kogaview`;
2. `${prefix}/share/applications/io.github.tienv2i.KogaView.desktop`;
3. `${prefix}/share/icons/hicolor/scalable/apps/io.github.tienv2i.KogaView.svg`;
4. `${prefix}/share/metainfo/io.github.tienv2i.KogaView.metainfo.xml`.

The desktop entry declares the codecs actually supported by the compiled
build, uses `Categories=Graphics;Viewer;Photography;`, and executes
`kogaview open %F` so a multi-file Open With request is preserved. It registers
the types for Open With but does not invoke `xdg-mime default`. `just uninstall`
removes only the four owned files and never deletes XDG config, state, journal,
logs or cache data.

The packaging check is part of the test gate. It compares the desktop MIME
claims with the protocol extension list and shared-mime-info, validates the
desktop and AppStream files, and keeps the app ID consistent across the
desktop entry, icon and metadata.

## Consequences

- A release build is required before installation, preventing a stale Debug
  artifact or development harness from being installed.
- Users must choose KogaView as their default handler themselves through their
  desktop environment.
- Flatpak and Windows packaging remain separate work; they must reuse the
  production identity without assuming this native install is sandbox-safe.
- The current reverse-DNS ID is project-owned for this repository but should be
  revisited if the project is transferred.
