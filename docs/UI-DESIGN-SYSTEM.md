# KogaView — UI/UX Design System & Engineering Constraints

> **Mandatory reference for all contributors and AI coding agents.**
> Any new view, panel, dialog, or toolbar control MUST obey these rules so KogaView stays visually cohesive, responsive at 60 fps, theme-accurate in Light & Dark modes, and free of Qt 6 / Wayland regressions.

---

## 1. Visual Hierarchy & Layout Principles

1. **Zero toolbar bloat**:
   - Never add more than 1–2 top-level buttons for a feature group. Group related modes into a **compact dropdown / popover** (like Browser's Sort button) or a **segmented switch** (like Browser's 3 view modes).
   - Keep `ToolbarMetrics.qml` and `tests/qml/tst_toolbar.cpp` in sync whenever toolbar button counts change.
   - Always support `miniToolbar` overflow folding so narrow windows never clip controls.
2. **Spatial rhythm & alignment**:
   - Standard margins: `12 px` outer panel inset, `8–10 px` section spacing, `6 px` row/control spacing, `4 px` tight button group spacing.
   - All form labels in a vertical stack share a single aligned `labelWidth` (e.g. `50–56 px` in sidebars, `FormRow` in dialogs).
   - Tool rails use an even 2-column symmetrical grid (`ToolRailButton`) with 1 px horizontal dividers (`theme.border`) separating functional groups.
3. **Theme fidelity (Light & Dark)**:
   - **Never hardcode colors** (`#fff`, `#000`, `#333`, etc.) for chrome, text, borders, or backgrounds. Always bind to `theme.background`, `theme.surface`, `theme.sidebar`, `theme.thumb`, `theme.text`, `theme.textMuted`, `theme.border`, `theme.hover`, `theme.selection`, `theme.accent`, `theme.danger`.
   - KogaView forces Qt `Fusion` style (`cpp/main.cpp`) and syncs `QPalette` via `Platform.applyThemePalette(...)` so popups, menus, and stock controls follow Light/Dark mode on GNOME, KDE Plasma, and Windows.
4. **Icons (never ship blank buttons)**:
   - Desktop icon themes (Papirus, Adwaita, Breeze) do **not** share the same symbolic icon names.
   - Any icon-only tool button, tab icon, or mode icon MUST use a **bundled monochrome 24×24 SVG** in `crates/desktop/qml/icons/` registered in `crates/desktop/icons.qrc` (drawn in `#000` so `AbstractButton.icon.color` tints it with `theme.text`).
   - Always verify icons on a **real Wayland/X11 window** — `QT_QPA_PLATFORM=offscreen` loads no icon theme and hides missing-icon bugs.

---

## 2. Mandatory Shared Component Libraries (Reuse, Never Duplicate)

Before writing a new control, reuse these existing libraries in `crates/desktop/qml/`:

| Component | Purpose | Rule |
|---|---|---|
| `ImageCanvas.qml` | Image viewport (zoom-at-cursor, free pan via `panMargin`, double-click Fit/100%, doc↔host coords) | Both Viewer and Editor MUST use `ImageCanvas` for image viewports. |
| `DialogFrame.qml` + `DialogFooter.qml` | App-themed modal dialog chrome (auto-fit height, resize edges/corner, overflow-only scrollbar) | Every app modal dialog MUST inherit `DialogFrame`. Declare child popups (`ColorPickerDialog`, `FolderDialog`) as `property` members (not default children) so they are never inserted into `bodyColumn`. |
| `SystemDialogs.qml` | XDG Desktop Portal file/folder/save dialogs with Qt fallback | Never instantiate raw `FileDialog` / `FolderDialog` in new views; call `SystemDialogs`. |
| `ColorPickerDialog.qml` | App-themed color chooser (2D SV spectrum, vertical Hue bar, RGB steppers, Hex, XDG `Screenshot.PickColor` eyedropper) | Never use Qt's stock `ColorDialog` in new UI. |
| `ColorAdjustPanel.qml` | Brightness / Contrast / Saturation sliders + numeric steppers | Reused by both Viewer (view-only) and Editor (Core command). |
| `UnitField.qml` | Numeric dimension input with `px` / `%` unit selector | Required for any image/canvas Width & Height input. |
| `AppMenu.qml` + `MenuShortcut.qml` | Theme-aware popup menus with right-aligned shortcut column | Menu widths MUST be measured via `Platform.textWidths` in `Theme.qml` — never via `TextMetrics` inside the `Menu` (causes Qt 6 binding loops). |
| `CachedThumbnail.qml` + `ThumbnailBook.qml` | Disk-cached async thumbnails with synchronous hit path (`ThumbnailCache::lookup`) | Never bind `Image { source: "file://" + path }` directly inside a multi-image grid/strip. |
| `RightDock.qml` / `LeftDock.qml` / `PanelSplitter.qml` | Tabbed sidebars and draggable splitters | Keep dock chrome consistent across all 3 workspaces. |

---

## 3. Strict Qt 6 / QML Engineering Rules (Anti-Patterns to Avoid)

1. **No broken `SpinBox` bindings**:
   - Qt Quick Fusion `SpinBox` breaks `value: <expr>` bindings after user interaction and clips arrows at narrow widths.
   - Use the `−` / `TextField` + `Binding { when: !activeFocus; restoreMode: Binding.RestoreNone }` / `+` (`autoRepeat: true`, `focusPolicy: Qt.NoFocus`) stepper pattern (see `ColorAdjustPanel.qml`).
2. **Keyboard focus & shortcuts (`Space`, arrows, tool keys)**:
   - Toolbar buttons, sliders, checkboxes, and stepper `−`/`+` buttons MUST set `focusPolicy: Qt.NoFocus`.
   - `InputFocusDismissFilter` in `cpp/main.cpp` automatically blurs `TextField`/`TextArea` when clicking outside and restores focus to `browser` / `viewer` / `editor`. Every text input should also handle `Keys.onEscapePressed: focus = false`.
3. **Pointer handlers on Wayland**:
   - Every `WheelHandler` and `DragHandler` MUST set `acceptedDevices: PointerDevice.AllDevices` (the default `PointerDevice.Mouse` silently ignores Wayland touchpads).
4. **No heavy work or domain mutations in QML**:
   - UI is the eyes; Core is the brain. Persistent preferences (`LayoutConfig`), file operations, and image pixel edits MUST travel as typed `Envelope` commands through `bridge.rs` → `app-core`.
   - Ephemeral presentation state (zoom, pan, fullscreen, always-on-top, live GPU preview sliders before Apply) stays in QML.
5. **GPU live preview efficiency**:
   - Use `layer.enabled: active` + `layer.effect: MultiEffect { ... }` so GPU offscreen layers cost **zero memory/overhead** when adjustments are neutral (`0`).
   - For multi-page views (Webtoon / Filmstrip Full), virtualize with `ListView`, cap `cacheBuffer` to `~1.0–1.5 × viewport`, use `asynchronous: true`, and debounce `viewer_open` updates (`120 ms`) during scroll.
6. **Translations (EN + VI)**:
   - Every user-visible string MUST use `qsTr(...)`, every new QML file with `qsTr(...)` MUST be listed in `crates/desktop/build.rs` AND `i18n/kogaview_ts.pro`, and every string MUST have a consistent Vietnamese translation in `i18n/kogaview_vi.ts` (verified by `just test translations`).
   - Reuse canonical wording when a string already exists in another context (avoid contradictory translations for the same source string).

---

## 4. Verification Gate Before Merging Any UI Change

1. `cargo fmt --check`
2. `just test translations && just test packaging`
3. Relevant QML & Cargo suites (`just test cargo`, `just test viewer`, `just test browser`, `just test toolbar`, `just test dialogs`, etc.)
4. Real Wayland/X11 window launch + `KOGAVIEW_DEV_SCREENSHOT` inspection — confirm zero QML warnings on stderr, crisp icons, aligned controls, and visible state delta (`after != before`).
