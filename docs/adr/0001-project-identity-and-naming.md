# ADR 0001 — Project identity and naming

- Status: accepted (app ID provisional)
- Date: 2026-11-15

## Context

The instruction bundle used `PhotoApp` as a placeholder product name, `photoapp`
and `photoctl` as placeholder executable names, and `io.github.example.PhotoApp`
as a placeholder reverse-DNS application ID. The project owner chose
**KogaView** as the product name and asked for the whole project to be renamed.

The application ID is used for desktop file names, MIME registration, Flatpak
metadata, single-instance coordination and the future IPC endpoint. It must be
stable and owned by the project before distribution. Runtime XDG directories use
the short name instead; see ADR 0002.

## Decision

- Product/display name: **KogaView**.
- Desktop executable: **`kogaview`**.
- Control client (from M5): **`kogactl`**.
- QML module URI: `io.github.tienv2i.KogaView`.
- Production app ID: `io.github.tienv2i.KogaView`.
- Development app ID: `io.github.tienv2i.KogaView.Dev`.
- Development identity is selected by the build profile: debug builds are Dev,
  release builds are production. A `KOGAVIEW_PROFILE` environment override is
  accepted only in debug builds for tests.
- The `dev-prod` preset (`just install-dev`) is deliberately **not** a third
  identity: it is `RelWithDebInfo`, so `NDEBUG` makes it production on every
  axis (app ID, directories, desktop entry) while `KOGAVIEW_DEV_HARNESS=ON`
  keeps the evidence hooks. A development *install* therefore shares the
  production identity, which is what lets it be driven on a real desktop
  without a second launcher entry. It must never be what a user installs —
  `just install` remains Release.
- XDG runtime directories are namespaced by the short application name, not the
  app ID: `$XDG_STATE_HOME/kogaview-dev/logs/` in development and
  `$XDG_STATE_HOME/kogaview/logs/` in production. See ADR 0002.
- Crate names use the `kogaview-` prefix (`kogaview-protocol`,
  `kogaview-core`, `kogaview-desktop`).

## Consequences

- All repository docs, scripts and packaging templates are renamed accordingly,
  deviating from the `photoapp`/`photoctl` names in the original bundle.
- The reverse-DNS ID is **provisional**: `io.github.tienv2i` must be confirmed
  as an owned namespace before M6 packaging. If it is not, change the ID in one
  place per layer (Rust identity module, CMake desktop metadata, packaging) and
  update this ADR.
- Dev and production builds must never share state, cache, database or IPC
  endpoints.
- Do not silently change the ID after users have installed a build; treat it as
  a migration.
