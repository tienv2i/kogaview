# Desktop integration and MIME contract

## Linux
- Use one stable reverse-DNS production App ID owned by the project; `io.github.tienv2i.KogaView` is a PLACEHOLDER and must be changed before shipping.
- Ship `.desktop` named `${APP_ID}.desktop`, icon `${APP_ID}`, AppStream metadata and image MIME associations.
- Desktop `Exec=kogaview open %F` requires support for multiple positional file arguments after `open`.
- Declare only supported codecs (initial JPEG, PNG, WebP, GIF, TIFF, BMP subject to actual build support).
- Open directory via explicit `kogaview open-folder DIR`; do not claim folder MIME handler unless implemented and tested.
- Do not forcibly replace user's default image viewer; user selects default via desktop settings.
- Honor XDG directories, portal file chooser, Wayland and KDE/GNOME theme integration.
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
