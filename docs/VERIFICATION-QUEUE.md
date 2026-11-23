# Verification Queue (Pending Deep Checks)

Items below passed fast/standard automated checks (Tier 1 or Tier 2) but still
need Tier 3 verification (real window, screenshots, Vietnamese locale, failure
paths, or selective mutation checks).

When the user runs `/verify` (or asks for a deep check), work through the open
items below, record the real evidence, and remove verified items here (moving
their summary into `docs/M1-REPORT.md` during `/handoff`).

## Pending items

- [ ] **[2026-11-23] Manual pointer/keyboard feel on Wayland (Tier 3 human-input checks)**
  - **Already verified on real Wayland window (2026-11-23):**
    - `just build` + `just install-dev` (`/usr/local/bin/kogaview` + `/usr/local/libexec/kogaview`)
    - Real Wayland window grabs (`browser-vi.png`, `viewer-vi.png`, `editor-ops.png`, `browser-sorted-xl.png`) with 0 QML warnings
    - All 3 new rail icons (`hand.svg`, `canvas-size.svg`, `rotate-angle.svg`) render cleanly
    - Real gateway commands in `journal/commands.jsonl`: `editor_canvas_size` (800×500 → 1000×700 `top_left`, red fill, rev 6), `editor_rotate_angle` (25°, green fill, expanded canvas `1203 × 1058`, rev 8), `set_layout` (`name desc`, `xl` thumbnails, rev 4)
  - **Remaining human-hand checks:**
    - Physical mouse/keyboard test of `H` (Hand tool), `OpenHandCursor`/`ClosedHandCursor`, and holding `Space` / middle-click drag inside Crop (no-frame state), Transform, and Brush on Wayland
    - Visual inspection of `CanvasSizeDialog` popup and Browser Sort popup opened interactively in Vietnamese (`vi`)
