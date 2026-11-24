# Verification Queue (Pending Deep Checks)

Items below passed fast/standard automated checks (Tier 1 or Tier 2) but still
need Tier 3 verification (real window, screenshots, Vietnamese locale, failure
paths, or selective mutation checks).

When the user runs `/verify` (or asks for a deep check), work through the open
items below, record the real evidence, and remove verified items here (moving
their summary into `docs/M1-REPORT.md` during `/handoff`).

## Pending items

- [ ] **[2026-11-24] v1.2.0 manual Wayland feel checks (Tier 3 human-input checks)**
  - Physical drag-resize of the window across all progressive toolbar compaction tiers (`full` → `compact` → `collapsed` → hide counter → 1-by-1 button fold) and Compact HUD 4-edge drag + restart persistence check.
  - Physical mouse/keyboard test of `H` (Hand tool), `OpenHandCursor`/`ClosedHandCursor`, and holding `Space` / middle-click drag inside Editor tools on Wayland.
