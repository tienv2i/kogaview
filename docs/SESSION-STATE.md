# Session State — KogaView v1.2.0

## Current Release
- **Version**: `1.2.0` (`Cargo.toml`, `CMakeLists.txt`, `packaging/linux/io.github.tienv2i.KogaView.metainfo.xml`, `packaging/arch/PKGBUILD`, `packaging/rpm/kogaview.spec`)
- **Branch**: `main`
- **Status**: v1.2.0 release — progressive 1-by-1 Viewer toolbar compaction, synced & persisted 4-edge Compact HUD, on-demand Simple-mode sidebar & filmstrip toggles, and shared Editor Crop-style `DimensionRatioGrid`.

## Summary of v1.2.0 Changes (since v1.1.0)
- **Viewer Toolbar & Progressive Compaction**:
  - Added 4-tier progressive toolbar compaction (`full` → `compact` → padded 1-button `collapsed` workspace switcher dropdown → hide `1 / N` counter → 1-by-1 right-to-left button folding into `⋯` overflow menu).
  - Promoted **Rotate left**, **Rotate right**, **Flip horizontal**, **Flip vertical**, and **Reset view** directly onto the Viewer toolbar; ordered **Info & color**, **Viewer mode & layout**, and **Canvas background** at the trailing right edge so they fold first.
  - Raised minimum window floor to `580 × 480` so toolbars and viewports never squeeze into unusable sizes.
- **Simple Mode Flexibility**:
  - In `Simple` mode, both the right sidebar (**Info** + **Color & Light** tabs) and bottom **Filmstrip** stay hidden by default on entry, and can now be toggled open/closed on demand from the toolbar, overflow menu, or keyboard (`T`).
- **Compact / Fullscreen Floating HUD**:
  - Fixed drag-grip vs `ImageCanvas` pan conflict (`MouseArea { preventStealing: true }` + `inputBlocked: compactHud.dragging`).
  - Synchronized Compact HUD controls and order with the Standard toolbar, including 1-by-1 overflow folding (`compactHudOverflowMenu`) for narrow or vertical-docked windows.
  - Persisted `compactHudEdge` (`top` / `bottom` / `left` / `right`) and `compactHudPinned` in Core `LayoutState` (`crates/app-protocol/src/lib.rs`, `Main.qml`, `SettingsDialog.qml`, `Viewer.qml`).
- **Editor Dimension & Ratio Grid**:
  - Extracted shared `DimensionRatioGrid.qml` (Crop-style Width / Height / Ratio fields with 2-of-3 lock toggles) and adopted it in `EditorResizePanel.qml` and `EditorCanvasSizePanel.qml`.

## Verification
- `cargo fmt --check`: PASS
- `just test cargo` (full Rust workspace), `just test translations`, `just test packaging`: PASS
- QML suites (`viewer` 50, `browser` 63, `toolbar` 18, `settings` 23, `batch`, `cache`, `state`, `dialogs`, `language`): ALL PASS.
- Release binary installed via `just install-dev` (`/usr/local/bin/kogaview` + `/usr/local/libexec/kogaview`).
- Scratch directory `/tmp/opencode` cleaned.
- Known test debt: `tests/qml/tst_editor.cpp` still contains legacy test cases targeting the removed modal `ResizeDialog` and removed Brush/Eraser UI buttons.
