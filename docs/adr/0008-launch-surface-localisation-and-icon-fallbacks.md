# ADR 0008 — Localising the launch surface, and why the icon needs rasters

- Status: accepted
- Date: 2026-11-17
- Related: ADR 0006 (interface language), ADR 0007 (native Linux install)

## Context

Two problems showed up together once KogaView was installed for real.

**1. The launch surface stayed English.** ADR 0006 gave the in-window interface
a Qt catalogue (`i18n/kogaview_vi.ts`) and a live switcher. Nothing in the
desktop entry or the AppStream metadata is drawn by Qt, though: GNOME's app grid,
the dock, the Open With dialog and an app centre all read
`io.github.tienv2i.KogaView.desktop` and
`io.github.tienv2i.KogaView.metainfo.xml` directly. A Vietnamese window inside an
English launcher is exactly the half-translated result that reads as a bug.

**2. The dock and app grid drew a blank icon with the app's name beside it,
while the Open With dialog drew it correctly.** The cause is the icon theme
cache. GLib resolves themed icons through `<theme>/icon-theme.cache`, a flat
file that can only hold the size buckets named in that theme's `index.theme`.
The install put the icon only in `hicolor/scalable/apps`, the prefix owns no
`index.theme`, and the prefix cache therefore had no bucket to record — while
code that lists the directory (GTK's own lookup, the file dialog) still found
the SVG. Measured: `Gtk.IconTheme.lookup_icon` answered with the SVG at every
size, yet the prefix `icon-theme.cache` did not contain the app id.

## Decision

**One table, two renderers.** `DESKTOP_LANGUAGES` in `scripts/dev.py` maps a
language tag to the desktop keys (`Name`, `GenericName`, `Comment`, `Keywords`)
and to the AppStream fields (`summary`, `description`). `render_desktop_entry()`
appends `Name[vi]=`, `GenericName[vi]=`, … inside `[Desktop Entry]`;
`render_metainfo()` appends `<name xml:lang="vi">`, `<summary xml:lang="vi">` and
a translated `<p>` after the English block. The files in `packaging/linux/` stay
the English source.

We did **not** use gettext's `localedir`/`.mo` route for the desktop entry: it
needs a `msgfmt` step and a `Localedir`-shaped layout this repository has no
build for yet, and it would put the desktop strings in a second catalogue that
the Qt one has to be reconciled with. The `[key[lang]=value]` form is read by
every desktop Environment without extra build steps.

**Raster fallbacks beside the SVG.** `just install` renders the one SVG into
`hicolor/{16,24,32,48,64,128,256}x…/apps/<id>.png` with PySide6's
`QSvgRenderer`, writes a prefix-local `hicolor/index.theme` that adds only the
size sections the system file lacks, and runs `gtk-update-icon-cache -f -t`.
Only the missing sections are merged so a future `hicolor-icon-theme` update is
not shadowed by a stale full copy. The PNGs are generated, never committed, so
the icon cannot fork into two drawings.

## Consequences

- A language added to `DESKTOP_LANGUAGES` is checked by
  `scripts/check_packaging.py`, which requires each key and an `xml:lang` in the
  metadata for it. It also requires a non-empty raster list, so removing the
  PNGs from the install fails the gate rather than silently returning to blank
  icons.
- Rendering the icon depends on PySide6 on the installing machine. Without it
  the install continues with the SVG and warns; the dock may then draw blank.
- A launcher that already cached the *miss* may keep the empty square until the
  session restarts. `just install` names the stale user cache
  (`~/.local/share/icons/hicolor/icon-theme.cache`) when it has no entry for
  the app, instead of claiming the fix is immediate.
- The AppStream `<p>` translation is appended, not interleaved, following
  AppStream's own rule that a localised paragraph repeats the element.
- Flatpak will need the same assets; the renderer is a plain script and can be
  reused, but no Flatpak build has been run (see `docs/FLATPAK.md`).
