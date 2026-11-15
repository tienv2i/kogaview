# Desktop integration and MIME contract

## Linux
- Use one stable reverse-DNS production App ID owned by the project; `io.github.tienv2i.KogaView` is a PLACEHOLDER and must be changed before shipping.
- Ship `.desktop` named `${APP_ID}.desktop`, icon `${APP_ID}`, AppStream metadata and image MIME associations.
- Desktop `Exec=kogaview open %F` requires support for multiple positional file arguments after `open`.
- Declare only supported codecs (initial JPEG, PNG, WebP, GIF, TIFF, BMP subject to actual build support).
- Open directory via explicit `kogaview open-folder DIR`; do not claim folder MIME handler unless implemented and tested.
- Do not forcibly replace user's default image viewer; user selects default via desktop settings.
- Honor XDG directories, portal file chooser, Wayland and KDE/GNOME theme integration.

## Windows
- Installer registers supported file types / Open With and optional folder context menu (only if implemented).
- Proper quoting/Unicode command-line handling, per-user install policy and uninstall behavior.
- Respect existing default apps; don't hijack file associations.

## Runtime checks
- Verify file manager Open With JPEG -> Viewer; no-argument launch -> Browser; directory command -> Browser.
- Verify MIME registration after install and after uninstall; check desktop launcher icon/name.
- Verify existing running instance receives new file/folder requests.
- Verify native and Flatpak installs independently, never assume desktop integration works because unit tests pass.
