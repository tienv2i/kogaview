# ADR 0005 — Image formats are compiled into the binary, never fetched at run time

- Status: accepted
- Date: 2026-11-16

## Context

KogaView should open "the usual" photo files and a few less usual ones, and the
owner asked for broader format support with "automatically download the
libraries it needs". That last part conflicts with the deployment target:

- `AGENTS.md` requires Flatpak readiness from day one and `docs/FLATPAK.md`
  forbids assuming unrestricted host access. A sandbox has no network unless it
  declares one, and downloading a decoder at run time would mean fetching and
  loading native code from the internet — an update channel, a signature story,
  and a way for the app to fail offline.
- Decoders reach the app through the Rust `image` crate. Its format support is a
  set of Cargo features, resolved at build time by the same toolchain that builds
  everything else.

## Decision

- **Every decoder is a Cargo feature of the `image` crate, compiled in.**
  `crates/app-core/Cargo.toml` (today `crates/app-editor/Cargo.toml`, ADR 0023)
  enables `png`, `jpeg`, `gif`, `webp`, `bmp`,
  `tiff`, `avif`, `dds`, `exr`, `ff`, `hdr`, `ico`, `pnm`, `qoi` and `tga`. The
  build needs no network, the sandbox needs no network, and a file either opens
  or the app says why.
- **No runtime download, ever.** There is no plugin directory, no "install this
  codec" path and no remote code. Adding a format is a source change plus a
  rebuild, which is the same review path as any other change.
- **AVIF decoding needs `avif-native`, not `avif` (revision 2026-11-21).**
  `image`'s `avif` feature is the pure-Rust ravif **encoder**; the decoder is
  behind `avif-native`, which links the system `libdav1d`. Both features are
  enabled. `dav1d-sys` finds the library through `pkg-config`, and
  `CMakeLists.txt` names `PkgConfig::DAV1D` on the executable's link line —
  without that the C++ link fails on every `dav1d_*` symbol, which is what
  sank the first attempt. A Flatpak or Windows build has to carry libdav1d;
  `just doctor` reports the version or says it is missing.
- **`has_decoder` builds the decoder.** Naming a format is not having one:
  `ImageReader::format()` answered true for AVIF while the decoder was absent,
  so the Editor started a worker and then showed the platform's English
  sentence. `has_decoder` now constructs the decoder, and `editor_open`
  refuses before a worker is spawned.
- **HEIC/HEIF stay listed but undecodable.** `kogaview_protocol::IMAGE_EXTENSIONS`
  includes `heic`/`heif` so the browser shows such files as images and the file
  dialog accepts them; `has_decoder()` reports the truth, and the Editor refuses
  them with "no decoder for this format" instead of failing deeper in. They are
  a patent-encumbered format with no pure-Rust decoder; removing them from the
  list would hide files the user can see in their folder.
- **The extension list is the single source of truth.** The file-dialog filter,
  the browser's "is this an image" test and the save filters all derive from
  `IMAGE_EXTENSIONS` (or the encoder list next to it), and a Core test asserts
  every extension in the list resolves through
  `image::ImageFormat::from_extension`, skipping `heic`/`heif` for the reason
  above.

## Consequences

- A larger binary (all decoders linked) in exchange for a build that works
  offline and inside a sandbox.
- `libdav1d` is a native build dependency of the Editor's AVIF support; it must
  be packaged with the app, not fetched at run time.
- A format that only a native library can decode is not supported until someone
  takes on that packaging decision in an ADR of its own.
- `image::ImageFormat::from_extension` does not know `jpe`, `heic` or `jxl`;
  `.jpe` is listed and decodes by content sniffing, `.pam` decodes as PNM but is
  not listed (shared-mime-info has no MIME type for it). Those quirks are
  recorded because they look like bugs from outside.

## Revision 2026-11-21 — AVIF was advertised with an encoder only

`image` 0.25.10's `avif` feature compiles `ravif` (an encoder) and no decoder.
The list, the file dialog, the desktop entry and the Viewer (through Qt) all
accepted AVIF, but the Editor failed with `The image format Avif is not
supported`, and `has_decoder` said `true` because it only looked at
`ImageReader::format()`. Measured on a real 64 × 48 AVIF (ffmpeg,
`libaom-av1`): `open_document` failed before, succeeded after.

The fix is two parts. `avif-native` is enabled, and `CMakeLists.txt` links
`PkgConfig::DAV1D` into the executable, which is the line the first attempt
lacked; the Rust staticlib alone cannot satisfy the symbols. `just doctor` now
prints the libdav1d version. `has_decoder` builds the real decoder, and
`editor_open` rejects an undecodable file synchronously with the translatable
`no_decoder` line instead of `ok: true` followed by an English library error.

`.jpe` joined `IMAGE_EXTENSIONS` in the same pass: shared-mime-info maps it to
`image/jpeg`, `image` decodes it by content, and only `from_extension` does not
name it. HEIC/HEIF remain the only listed-but-undecodable formats; the packaging
check still excludes them from `MimeType=`.

The same check found the fallback chooser's list spelled a second time in
`cpp/platform.cpp` — with no `.jpe`, so the Browser showed the file and the
dialog's filter hid it. That list now carries `.jpe`,
`scripts/check_packaging.py` compares the two spellings (missing and extra
entries are both named), and the two mutations that prove the comparison work
are dropping `.jpe` and adding `jxl` to the C++ array.

## Revision — the feature list lives with the Editor (2026-11-22)

The decision is unchanged: every decoder is a Cargo feature, compiled in, and
the build needs no network. The list is no longer `crates/app-core/Cargo.toml`'s.
ADR 0023 moved the Editor — and with it `image`, its format features and the
`jpeg-decoder` reader for a 1/2, 1/4 or 1/8 JPEG decode — into `crates/app-editor`.
`app-core` now names `kogaview-editor` and carries no format features of its own;
`avif-native` still links the system `libdav1d`, so `CMakeLists.txt` and `just
doctor` are as they were.
