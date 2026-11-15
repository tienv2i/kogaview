# ADR 0002 — Runtime directories and persisted configuration

- Status: accepted
- Date: 2026-11-15

## Context

ADR 0001 namespaced every XDG root by the reverse-DNS application ID, for
example `$XDG_STATE_HOME/io.github.tienv2i.KogaView.Dev/logs/`. That is correct
for desktop integration, but it is hostile for humans and for support: users
are asked to inspect or back up a file inside a directory whose name mirrors a
domain, and the same long string appears in logs, Flatpak paths and
documentation.

The reverse-DNS ID also remains provisional (ADR 0001), so tying on-disk user
data to it would force a migration when the namespace is confirmed.

The UI phase additionally needs a durable place for user preferences (theme,
quick access list, last folder, panel and filmstrip visibility) that survives
restarts and is shared by every front end.

## Decision

- **Runtime directories use the short application name**, not the app ID:
  - production: `$XDG_CONFIG_HOME/kogaview/`, `$XDG_STATE_HOME/kogaview/`,
    `$XDG_CACHE_HOME/kogaview/`, `$XDG_DATA_HOME/kogaview/`;
  - development: the same roots with `kogaview-dev`.
- The reverse-DNS application ID stays in charge of **desktop identity only**:
  `.desktop` file name, `QGuiApplication::setDesktopFileName`, portal
  registration, Flatpak metadata, MIME registration and the future IPC endpoint
  under `$XDG_RUNTIME_DIR`.
- The configuration file is `$XDG_CONFIG_HOME/kogaview[-dev]/config.json`.
  It is the only file users are expected to edit by hand.
- Logs and the command journal remain under `$XDG_STATE_HOME/kogaview[-dev]/`
  (`logs/`, `journal/`), screenshots under `screenshots/`, and the thumbnail
  cache under `$XDG_CACHE_HOME/kogaview[-dev]/`.
- Config writes are atomic: serialise to `config.json.tmp` in the same
  directory, `fsync`, then `rename` over `config.json`.
- A missing config is created with defaults. A corrupt config is copied to
  `config.json.corrupt`, replaced with defaults and reported in the log; startup
  never fails because of configuration.
- Default theme is **dark**. Default quick access is `~/Pictures` (when it
  exists) followed by the home directory.
- Dev and production roots never overlap. Debug builds select the dev profile;
  `KOGAVIEW_PROFILE` may override it in debug builds only.

## Consequences

- Paths are short, readable and stable across the provisional app ID.
- Desktop files, portal identity and Flatpak metadata must keep using the
  reverse-DNS ID; two naming schemes now coexist deliberately, so every new
  path helper must state which one it uses.
- If the app ID changes before release, no user data has to move.
- Adding a config field requires a `serde(default)` default so that older files
  keep loading; the schema is additive, not versioned, for now.
- Flatpak overrides of `XDG_CONFIG_HOME`/`XDG_STATE_HOME` still isolate the
  sandboxed app; nothing depends on unrestricted host access.
