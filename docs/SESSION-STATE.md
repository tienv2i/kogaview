# Session State — KogaView v1.0.0

## Current Release
- **Version**: `1.0.0` (`Cargo.toml`, `CMakeLists.txt`, `packaging/linux/io.github.tienv2i.KogaView.metainfo.xml`)
- **Branch**: `main`
- **Status**: Feature-complete v1.0.0 release across Browser, Viewer, and Editor workspaces.

## Summary of v1.0.0 Capabilities
- **Browser**: Async background scan + C++ `ThumbnailCache` with synchronous hit lookup (`lookup()`), 3 view modes (`Thumbnails`, `Icons`, `Details`), 5 thumbnail sizes (`XS`–`XL`), sorting (`Name`, `Modified`, `Size`, `Type`, asc/desc), Quick Access, Explorer, Preview/Info/Batch dock, Batch Resize/Crop/Convert with `SystemDialogs` (XDG Portal) & `ColorPickerDialog`.
- **Viewer**: Shared `ImageCanvas` with free pan, scroll-to-zoom at cursor, double-click Fit/100%, 90° rotate/flip, Reset view, filmstrip with bundled icon, canvas background selector (theme / checkerboard / solid / custom), and view-only Light & Color adjustments (60 fps `MultiEffect` GPU preview in RightDock `Color` tab, never saved).
- **Editor**: Non-destructive editing with full Undo/Redo/Reset and automatic backup on overwrite; 8-tool symmetrical rail (`Pointer`, `Hand`, `Resize`, `Canvas Size`, `Crop`, `Transform`, `Rotate by angle`, `Color & light`) — Brush & Eraser removed from UI; sidebar live 60 fps GPU preview panels (`EditorResizePanel`, `EditorCanvasSizePanel`, `ColorAdjustPanel`, `Rotate`, `Transform`, `Crop` with `a:b` / `a/b` / decimal ratio & current-ratio lock); app-themed `ColorPickerDialog` with 2D SV spectrum, vertical Hue bar, RGB steppers, and XDG Portal `Screenshot.PickColor` eyedropper; window-wide `InputFocusDismissFilter` so clicking outside any input restores workspace shortcuts (`Space`, etc.) immediately.
- **Desktop & i18n**: Light/Dark theme with synchronized Fusion palette, live English (`en`) / Vietnamese (`vi`) switching (490 translated strings), XDG Desktop Portal dialogs, AppStream metadata, and desktop integration.

## Verification
- `cargo fmt --check`: PASS
- `just test cargo` (124 tests), `translations`, `packaging`, `viewer` (44), `browser`, `batch` (14), `cache` (15), `state`, `settings`, `dialogs` (12), `language` (7), `toolbar` (19): ALL PASS.
- Real Wayland window screenshots verified for Browser, Viewer, and Editor (no QML warnings/errors, `editor_adjust_color` journaled and rendered).
- Known test debt: `tests/qml/tst_editor.cpp` still contains legacy test cases targeting the removed modal `ResizeDialog` and removed Brush/Eraser UI buttons.
