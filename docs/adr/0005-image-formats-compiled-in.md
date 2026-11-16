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
  `crates/app-core/Cargo.toml` enables `png`, `jpeg`, `gif`, `webp`, `bmp`,
  `tiff`, `avif`, `dds`, `exr`, `ff`, `hdr`, `ico`, `pnm`, `qoi` and `tga`. The
  build needs no network, the sandbox needs no network, and a file either opens
  or the app says why.
- **No runtime download, ever.** There is no plugin directory, no "install this
  codec" path and no remote code. Adding a format is a source change plus a
  rebuild, which is the same review path as any other change.
- **`avif-native` is deliberately not enabled.** It links the system `libdav1d`;
  the first attempt failed at link time with undefined `dav1d_*` symbols, and
  making it work would add a native dependency that a Flatpak build has to carry
  and CMake has to be told to link. The pure-Rust `avif` feature decodes AVIF
  without that, so the format is supported and the packaging problem is not
  created.
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
- A format that only a native library can decode is not supported until someone
  takes on that packaging decision in an ADR of its own.
- `image::ImageFormat::from_extension` does not know `jpe` or `heic`; `.pam`
  decodes as PNM. Those quirks are recorded because they look like bugs from
  outside.
