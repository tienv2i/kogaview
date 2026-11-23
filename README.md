# KogaView — Fast Native Photo Manager, Viewer & Non-Destructive Editor

**KogaView** is a fast, native desktop photo manager, viewer, and non-destructive image editor built with **Rust** and **Qt 6 / QML** via **CXX-Qt**. Designed for Linux desktops (GNOME, KDE Plasma, Wayland/X11) with first-class **XDG Desktop Portal** and **Flatpak** readiness, every domain action flows through a single typed command gateway in Rust Core with revisioned state, structured logs, and a command journal.

---

## Highlights (v1.1.0)

### Browser Workspace
- **Async background folder scanning & disk-cached thumbnails**: Bounded worker pool (`ThumbnailCache`) with instant synchronous cache hits, warm view-mode delegates, LRU disk eviction, and EXIF orientation support.
- **Three view modes & 5 thumbnail sizes**: Switch smoothly between **Thumbnails**, **Icons**, and **Details** views with 5 size presets (`XS`, `S`, `M`, `L`, `XL`).
- **Sorting & navigation**: Sort by Name, Date Modified, File Size, or Type (ascending/descending), breadcrumb navigation, Quick Access favorites, Explorer folder tree, and live Preview / Info / Batch sidebar.
- **Batch processing**: Batch **Resize**, **Crop** (with 3×3 anchor grid, `px`/`%` units, and aspect ratios), and **Convert** over selected images or folders with progress tracking, cancellation, and safe non-overwriting defaults.

### Viewer Workspace
- **Three UI chrome modes (`M`)**: Switch seamlessly between **Simple** (toolbar only — default when opening images, with exact dynamic window auto-fit), **Compact** (image-only with a translucent **4-edge dockable Floating HUD** featuring magnetic drag-to-snap and right-click edge/pin controls), and **Standard** (full workspace with right Info/Color dock, filmstrip, and status bar).
- **Three image display modes**:
  - **Single**: Smooth scroll-to-zoom at cursor, double-click Fit / 100%, free pan at any zoom level, grouped **Rotate & flip** menu (`Shift+R`, `R`, `H`, `V`, Reset view), and canvas background selector.
  - **Dual page (book / manga)**: Smart two-page spread pairing using fast header-only image dimensions — automatic solo spreads for cover pages and panoramic landscape artwork, **LTR → / RTL ←** reading order, configurable page gap (`0 / 8 / 16 px`), and 60 fps zoom/pan inside the shared `ImageCanvas`.
  - **Webtoon (vertical)**: Virtualized continuous vertical reader (`ListView` with `reuseItems` and bounded VRAM cache), header-only pre-layout (zero layout shift), and **Smart Auto-Fit** (`Auto` / `Width` / `Height` / `100%`) plus smooth `Ctrl+Wheel` column-width zoom with debounced decode caps.
- **Fullscreen (`F11`)**: Distraction-free full-screen viewing reusing the 4-edge Floating HUD; `F11` or `Esc` restores prior window geometry and mode.
- **View-only Light & Color adjustments**: Live 60 fps GPU preview (Brightness, Contrast, Saturation) accessible from both the toolbar/RightDock in Standard/Simple mode and a non-dimming floating popover in Compact/Fullscreen mode, synchronized bidirectionally and never written to disk.
- **Configurable defaults in Settings**: Choose default Viewer open layout (`Simple` / `Standard` / `Compact`) and display mode (`Single` / `Dual` / `Webtoon`) in `Settings → Viewer`.

### Editor Workspace (Non-Destructive)
- **Live 60 fps GPU previews**: Never overwrites originals until explicitly saved (with automatic backup on overwrite) and supports full **Undo / Redo / Reset** history.
- **Vertical right panel rail**: One-click switching for `Tool options`, `Info`, `History`, `Original`, plus a bottom **Hide all panels** button.
- **Tools**:
  - **Pointer & Hand (`H` / `Space` + Drag)** with Krita-style free canvas panning.
  - **Resize** sidebar panel with `px` / `%` units, aspect-ratio lock, scale presets, Stretch / Cover / Pad fit modes, resampling filters (`Lanczos3`, `Catmull-Rom`, `Nearest`), and live canvas preview.
  - **Canvas Size** sidebar panel with `px` / `%` units, 3×3 anchor grid, shared background fill, and live expansion/crop preview.
  - **Crop** with interactive handles, `a:b` / `a/b` / decimal ratio input, independent Width / Height / Ratio locks, Grow-canvas mode, and anchor placement.
  - **Transform** (Free Transform & Scale Canvas) with modifier keys (`Shift` ratio, `Alt` center, `Ctrl` snap) and live GPU preview.
  - **Rotate by angle** (`-180° .. +180°`) with live bounding-box expansion preview.
  - **Color & Light** adjustments (Brightness, Contrast, Saturation) with 60 fps GPU preview and exact pixel commit in Rust Core.
- **App-themed Color Picker**: 2D Saturation–Value spectrum, vertical Hue bar, RGB steppers, Hex input, quick swatches, and **Screen Eyedropper** via XDG Desktop Portal (`org.freedesktop.portal.Screenshot.PickColor`).
- **Export & Save As**: Native XDG Desktop Portal file dialogs, format conversion (PNG, JPEG, WebP, TIFF, GIF, BMP, TGA, QOI), quality control, and metadata options.

### Desktop & UX
- **Light & Dark themes** with synchronized Qt palette and custom Fusion styling.
- **Bilingual UI**: English (`en`) and Vietnamese (`vi`), switchable live in Settings.
- **Consistent dialogs**: Shared `DialogFrame` with auto-fit height, interactive edge/corner resizing, and smart scrollbars.

---

## Quick Start

### Prerequisites
- **Rust** (stable toolchain, `cargo`)
- **CMake** ≥ 3.24 & **Ninja** (or Make)
- **Qt 6** (`Core`, `Gui`, `Qml`, `Quick`, `QuickControls2`, `QuickEffects`, `DBus`, `LinguistTools`)
- **just** (`justfile` task runner) and **Python 3**

### Build, Test & Run

```sh
just setup         # verify toolchain and Qt 6 dependencies
just build         # configure + build dev binary (build/dev/bin/kogaview)
just run           # build and launch the dev app
just test          # run Rust workspace, translation, packaging, and QML suites
just install       # build optimized release and install to /usr/local
just install-dev   # build optimized dev-prod with dev hooks and install
just uninstall     # remove installed binary and desktop integration
just doctor        # inspect versions, app identity, and environment
```

CLI arguments are forwarded directly:

```sh
kogaview open /path/to/photo.jpg
kogaview open-folder ~/Pictures
kogaview --version
```

---

## Architecture

- **Core (`crates/app-core`, `crates/app-editor`, `crates/app-protocol`)**: Qt-independent Rust modular monolith owning domain state, typed `Envelope` command gateway, non-destructive image pipeline, batch jobs, config persistence, structured tracing logs, and command journal.
- **Desktop Adapter & UI (`crates/desktop`, `cpp/`)**: CXX-Qt bridge, C++ `ThumbnailCache` & `PlatformHelper` (XDG Desktop Portal FileChooser, Screenshot.PickColor, OpenURI), and Qt 6 / QML views (`BrowserView`, `Viewer`, `EditorView`).

### Runtime Identity

| | Dev build | Production build |
|---|---|---|
| Name | KogaView (Dev) | KogaView |
| App ID | `io.github.tienv2i.KogaView.Dev` | `io.github.tienv2i.KogaView` |
| Config | `~/.config/kogaview-dev/config.json` | `~/.config/kogaview/config.json` |
| State | `~/.local/state/kogaview-dev/` | `~/.local/state/kogaview/` |
| Cache | `~/.cache/kogaview-dev/` | `~/.cache/kogaview/` |

---

## Documentation

- [`docs/PRD.md`](docs/PRD.md) — product requirements
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Core/UI split, command bus, persistence
- [`docs/WORKSPACES.md`](docs/WORKSPACES.md) — Browser, Viewer, and Editor routing
- [`docs/BUILD.md`](docs/BUILD.md) — build, run, and install contract
- [`docs/CLI.md`](docs/CLI.md) — CLI launch surface
- [`docs/FLATPAK.md`](docs/FLATPAK.md) — sandbox and portal constraints
- [`docs/adr/`](docs/adr/) — Architecture Decision Records

## License

MIT — see [`LICENSE`](LICENSE).
