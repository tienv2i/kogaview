# Session State — KogaView v1.1.0

## Current Release
- **Version**: `1.1.0` (`Cargo.toml`, `CMakeLists.txt`, `packaging/linux/io.github.tienv2i.KogaView.metainfo.xml`, `packaging/arch/PKGBUILD`, `packaging/rpm/kogaview.spec`)
- **Branch**: `main`
- **Status**: v1.1.0 release — streamlined UI, 3 Viewer chrome modes (`Compact`, `Simple`, `Standard`), 3 Viewer display modes (`Single`, `Dual page`, `Webtoon` with Smart Auto-Fit), Fullscreen (`F11`), 4-edge dockable Compact HUD with floating Color & Light popover, and Editor vertical right panel rail.

## Summary of v1.1.0 Changes (since v1.0.0)
- **Viewer Modes & Streamlined Toolbar**:
  - 3 persisted chrome modes (`viewerUiMode`: `"simple"` default, `"standard"`, `"compact"`) and 3 display modes (`viewerDisplayMode`: `"single"` default, `"dual"`, `"webtoon"`) plus `mangaRtl`, `mangaCoverSeparate`, `mangaPageGap` in `LayoutState`.
  - Streamlined Viewer toolbar (15 → 11 buttons, 3 → 2 separators): grouped Rotate/Flip/Reset into a single `Rotate & flip` menu, added direct `Color & light`, `Viewer mode & layout (M)`, and `Fullscreen (F11)` buttons.
  - Removed Quick Access & Explorer from Viewer and `Settings → Viewer`; added default Viewer `Open mode` and `Display mode` selectors in `Settings → Viewer`.
  - Fixed dynamic window auto-fit chrome sizing (`viewerChromeHeight` / `viewerChromeWidth` in `Main.qml`) so opening images directly from the file manager hugs the image with zero top/bottom gaps.
- **Modular Viewer Components**:
  - `ViewerModePopup.qml`: unified layout + display mode + contextual options popover (single-click applies live; double-click applies and closes).
  - `ViewerCompactHud.qml`: 4-edge dockable floating HUD (`top`/`bottom`/`left`/`right`) with magnetic drag snap, right-click edge/pin menu, and auto-hide hover zone shared by Compact and Fullscreen modes.
  - `ViewerColorPopover.qml`: translucent non-dimming floating `ColorAdjustPanel` popover positioned opposite the docked HUD edge and synced bidirectionally with `RightDock`.
  - `ViewerDualSpread.qml`: smart two-page spread renderer using header-only `Platform.imageSize(path)` (cover separation, auto solo landscape, LTR/RTL, immediate refit on option changes).
  - `ViewerWebtoonView.qml`: virtualized vertical `ListView` (`reuseItems: true`, bounded `cacheBuffer`, `originY`-safe scrolling, header-only pre-layout, Smart Auto-Fit `Auto`/`Width`/`Height`/`100%`, debounced `sourceSize` cap).
- **Editor Right Rail**:
  - `SidePanelRail.qml`: right vertical panel rail in Editor (`Tool options`, `Info`, `History`, `Original`, plus bottom **Hide all panels** button).

## Verification
- `cargo fmt --check`: PASS
- `just test cargo`, `just test translations` (543 strings), `just test packaging`: PASS
- QML suites (`viewer` 49, `browser` 63, `batch`, `cache`, `state`, `settings` 23, `dialogs`, `language`, `toolbar` 18): ALL PASS.
- Real Wayland window screenshots verified with 0 QML warnings/errors for Browser, Viewer (`Simple/Single` fresh auto-fit, `Compact` 4-edge HUD, `Dual`, `Webtoon`), and Editor.
- Known test debt: `tests/qml/tst_editor.cpp` still contains legacy test cases targeting the removed modal `ResizeDialog` and removed Brush/Eraser UI buttons.
