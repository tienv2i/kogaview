# Desktop integration and MIME contract

## Linux
- Use one stable reverse-DNS production App ID owned by the project: `io.github.tienv2i.KogaView`.
- Ship `.desktop` named `${APP_ID}.desktop`, icon `${APP_ID}`, AppStream metadata and image MIME associations.
- Desktop `Exec=kogaview open %F` requires support for multiple positional file arguments after `open`.
- Declare only supported codecs. The current desktop entry is checked by
  `scripts/check_packaging.py` against `IMAGE_EXTENSIONS`, the compiled
  decoders and shared-mime-info; `.heic`/`.heif` remain browser-visible but are
  not declared because this build has no decoder.
- Open directory via explicit `kogaview open-folder DIR`; do not claim folder MIME handler unless implemented and tested.
- Do not forcibly replace user's default image viewer; user selects default via desktop settings.
- Honor XDG directories, portal file chooser, Wayland and KDE/GNOME theme integration.
- `just install` builds the release artifact and installs the binary, desktop
  entry, an SVG icon plus seven raster copies of it, and AppStream metadata under
  `/usr/local` by default; `KOGAVIEW_PREFIX` overrides the prefix. The desktop
  entry uses `Categories=Graphics;Viewer;Photography;`, `GenericName=Image Viewer`
  and `StartupWMClass=KogaView`.
- **The icon needs the rasters, not just the SVG.** GNOME's dock, the shell's app
  grid and the app centre read icons through GLib's icon theme *cache*: one flat
  file per theme directory that can only hold the size buckets listed in that
  theme's `index.theme`. A prefix that installed only
  `hicolor/scalable/apps/<id>.svg` gave the launcher nothing to cache, so the dock
  drew an empty square with the app's name beside it — while the Open With dialog,
  which reads the directory directly, still found the SVG and drew it. `just
  install` therefore renders `<id>.png` at 16/24/32/48/64/128/256 from the one
  SVG, writes a prefix-local `hicolor/index.theme` that adds only the missing
  size sections (the system one still supplies the rest), and runs
  `gtk-update-icon-cache -f -t`. `just doctor` reports
  `Icon files : 7/7 raster sizes + SVG; theme cache covers <id>`.
  Rendering needs PySide6 (`QSvgRenderer`); without it the install keeps going
  with the SVG alone and says the dock may draw blank.
- Launch-surface languages: the desktop entry and the AppStream file carry
  `Name[vi]`/`GenericName[vi]`/`Comment[vi]`/`Keywords[vi]` and
  `<name|summary|p xml:lang="vi">`. They are generated from one table,
  `DESKTOP_LANGUAGES` in `scripts/dev.py`, beside the Qt catalogue that the
  window itself uses (`i18n/kogaview_vi.ts`, ADR 0006) — a language added to one
  and forgotten in the other would show a Vietnamese window inside an English
  launcher, so `just test packaging` checks both ends.
- Installation is Open With registration only. It does not run `xdg-mime
  default`, so the user's existing default handler is preserved. `just
  uninstall` removes only KogaView's installed files (binary, entry, icon,
  rasters, metadata and the generated `index.theme`) and keeps user data.
- Derived files (the thumbnail cache) live under the XDG cache directory and are
  therefore safe to delete at any time: `<cache>/thumbnails`, with `<cache>` from
  `kogaview_cache_dir()` so the `-dev` naming rule is not duplicated in C++.
  Losing it costs one regeneration, never correctness — every key carries the
  source's size and mtime.

## Windows
- Installer registers supported file types / Open With and optional folder context menu (only if implemented).
- Proper quoting/Unicode command-line handling, per-user install policy and uninstall behavior.
- Respect existing default apps; don't hijack file associations.

## Runtime checks
- Verify file manager Open With JPEG -> Viewer; no-argument launch -> Browser; directory command -> Browser.
- Verify MIME registration after install and after uninstall; check desktop launcher icon/name.
- Run `just test packaging` before installation; it validates the MIME list,
  viewer categories, desktop entry, icon identity and AppStream metadata.
- Verify existing running instance receives new file/folder requests.
- Verify native and Flatpak installs independently, never assume desktop integration works because unit tests pass.

## XDG portal usage
- `FileChooser` has **no** `OpenFolder` method. A folder dialog is `OpenFile`
  with `directory: true` (interface version 3+); when the version is lower the
  caller must fall back to the Qt dialog instead of sending an unknown method.
- D-Bus replies carry request handles as `QDBusObjectPath`. Reading one with
  `QVariant::toString()` yields an empty string, which is indistinguishable from
  a failed call — use the object-path accessor.
- `Response` must be subscribed to *before* the method call, on the request path
  predicted from `QDBusConnection::sessionBus().baseService()` plus the
  `handle_token`. A portal may answer immediately (cancel, denial, synchronous
  backend); a subscription installed after the reply would miss it. If the
  portal returns a different path, move the subscription there.
- `parent_window` is `x11:<window id>` where that can be expressed (xcb) and
  empty otherwise, which only makes the dialog non-modal. Wayland would need an
  xdg-foreign export that is not implemented yet.
- A timed-out or abandoned request must be closed (`Request.Close`) so no dialog
  outlives the request; the client also closes it when the window goes away.
- Opening files/folders with their default handler goes through
  `OpenURI.OpenURI` so it keeps working inside a sandbox, with
  `QDesktopServices::openUrl` as the non-portal fallback.
