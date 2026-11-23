# KogaView — Roadmap & Technical Specification (v1.1 → v2.0)

> Self-contained engineering specification so any contributor or AI coding agent can implement each vertical slice independently while preserving KogaView's architecture (`docs/ARCHITECTURE.md`) and design system (`docs/UI-DESIGN-SYSTEM.md`).

---

## Release v1.1 — Advanced Viewer Modes & Integrated Compare

### 1. Viewer Display Modes (`viewer_mode` in `LayoutConfig`)

Persist in `crates/app-protocol/src/lib.rs` (`LayoutConfig`) & `crates/app-core`:
- `viewer_mode: String` — `"single"` (default) | `"strip"` | `"webtoon"` | `"double"` | `"compare"`
- `manga_rtl: bool` (default `false`; `true` = Right-to-Left Japanese manga order)
- `manga_cover_separate: bool` (default `true`; page 0 stands alone so spreads pair `(1,2), (3,4)...`)
- `manga_page_gap: u16` (default `8`, clamped `0..=64`)

#### UI Placement (Zero Toolbar Bloat)
- **Single compact Mode Popover button** on `Viewer.qml` toolbar (next to Filmstrip toggle, styled like Browser's Sort button):
  - Radio list of modes: `Single`, `Filmstrip full`, `Webtoon (vertical)`, `Double page (book)`, `Compare`.
  - Contextual sub-controls shown *only inside the popover* when `Double page` or `Webtoon` is active: Reading direction (`LTR →` / `RTL ←`), `Separate cover page` checkbox, `Page gap` (`0 / 8 / 16 px`).
- **Two window-state icon buttons** at the right edge of `Viewer.qml` toolbar (using bundled SVGs in `crates/desktop/qml/icons/`):
  - **Pin (Always on Top)** (`Ctrl+Shift+P`): toggles `Qt.WindowStaysOnTopHint` on `Main.qml` `ApplicationWindow`. Tooltip notes X11/Windows support and Wayland compositor limitations.
  - **Fullscreen** (`F11` / `F`): toggles `Window.FullScreen`, hides top bar, sidebars, filmstrip, and status bar; shows translucent **Floating HUD** when pointer enters top/bottom 48 px edge, auto-hiding after `2000 ms` idle; `Esc` or `F11` exits cleanly and restores prior dock visibility.

#### Behavioral & Performance Contracts
1. **Filmstrip Full (`strip`)**:
   - Horizontal virtualized `ListView` (`orientation: ListView.Horizontal`, `cacheBuffer: width * 1.5`), each delegate fit-height with `asynchronous: true`.
   - Mouse wheel (vertical or horizontal) scrolls smoothly; double-click switches to `single` on that image; viewport center index updates `viewerIndex` debounced at `120 ms`.
   - Auto-hides bottom thumbnail filmstrip to avoid duplication.
2. **Webtoon (`webtoon`)**:
   - Vertical virtualized `ListView` (`orientation: ListView.Vertical`, `cacheBuffer: height * 1.5`), fit-width with global zoom multiplier and configurable `manga_page_gap`.
   - Smooth vertical wheel scroll; center page syncs `viewerIndex` debounced at `120 ms`; auto-hides bottom filmstrip.
3. **Double Page / Book (`double`)**:
   - Precomputes `spreads: [[i], [j, k], ...]` using fast header-only `Platform.imageSize(path)` (never full-image decode):
     - If `manga_cover_separate` and `images.length > 1`, index `0` is a solo spread `[0]`.
     - Any landscape image (`width > height`) automatically occupies a solo spread `[i]` so panoramic double-page spreads are never paired off-by-one.
   - Renders `[left, right]` (LTR) or `[right, left]` (RTL) inside a shared `ImageCanvas` so zoom/pan/Color & Light apply seamlessly across both pages.
   - `Left`/`Right` arrows and `Space` advance by one spread (direction respects `manga_rtl`).
4. **Viewer Compare (`compare`)**:
   - User picks Image B via `SystemDialogs.openFiles`, right-click *"Compare with…"* in Browser/filmstrip, or drag-and-drop onto the viewport.
   - Supports 3 layouts: **Split Curtain** (draggable vertical divider `splitPos: 0.0..1.0`), **Side-by-Side**, and **Hold `\` to Toggle**.
   - **Synchronized 1:1 Zoom & Pan** via shared `ImageCanvas` transform (`zoom`, `offsetX`, `offsetY`), normalizing Image B's display rect to match Image A's viewport frame when resolutions differ.

---

### 2. Editor Integrated Compare (3 Sources)

Add a **Compare toggle + source selector** on `EditorView.qml` toolbar (presentation-only overlay on `canvasHost`, 60 fps, zero Core round-trip):

| Source key | Left (Before) | Right (After) |
|---|---|---|
| `original` | `editor.originalPreviewPath` (saved/original file on disk) | Current working document preview (or active tool live preview) |
| `before_tool` | Current committed working preview (`editor.previewPath`) | Active uncommitted tool live preview (Color & Light `MultiEffect`, Rotate, Resize, Canvas Size, Transform) |
| `external` | User-picked reference image via `SystemDialogs` | Current working document preview |

- Draggable vertical split curtain (`splitPos: 0.0..1.0`) with crisp handle + subtle `Before` / `After` pill badges at top corners.
- Clipped directly in `canvasHost` coordinates so zoom, pan, and canvas background stay 100% aligned.

---

## Release v1.2 / v2.0 — Local AI Pipeline & LoRA Dataset Workflow

### Architecture Constraints (Mandatory)
1. **Separate crate**: `crates/app-ai` (optional Cargo feature `ai`, enabled in release builds without bundling model weights).
2. **On-demand Model Manager**:
   - Weights stored in `$XDG_DATA_HOME/kogaview/models/` (never inside the binary or repo).
   - `Settings → AI` tab shows installed models, download/remove actions with SHA-256 verification, and execution provider (`CPU` / `CUDA` / `ROCm` / `DirectML` / `CoreML`).
3. **Command Bus & Async Tasks**:
   - Every AI action is a typed `Command` (`editor_ai_remove_bg`, `editor_ai_inpaint`, `editor_ai_remove_gemini_logo`, `batch_ai_caption`) running on bounded background workers with progress events, cancellation, journal logging, and full Editor **Undo/Redo** snapshots.

### Target AI Capabilities
1. **Background Removal (`editor_ai_remove_bg` + Batch)**:
   - Model: **RMBG-2.0** or **BiRefNet** via `ort` (ONNX Runtime).
   - Output: RGBA8 with refined alpha mask; immediately inspectable with Editor Compare curtain + Checkerboard backdrop.
2. **Gemini Logo Removal (`editor_ai_remove_gemini_logo` + Batch)**:
   - Automatic bottom-right corner mask proposal (proportional to image dimensions, user-adjustable box in Editor) → **LaMa ONNX** inpainting.
   - Supports 1-click single-image and folder-wide Batch mode.
3. **General Watermark Removal (`editor_ai_inpaint`)**:
   - Lightweight AI-only mask tool (rectangle / freehand mask overlay, strictly ephemeral for the AI request — never a general painting tool) → **LaMa ONNX** inpainting.
4. **LoRA Captioning (`editor_ai_caption` & `batch_ai_caption`)**:
   - **Engine A (Offline ONNX)**: **WD14 Tagger** (fast tag extraction, threshold slider, underscore→space toggle, character/general tag filtering).
   - **Engine B (Local VLM API)**: OpenAI-compatible localhost endpoint (`Ollama` / `llama.cpp` / `LM Studio` at `http://127.0.0.1:...`) with customizable system prompt for natural-language Flux / SDXL / Wan LoRA captions.
   - **Dataset ergonomics**: Read/edit sidecar `<image_stem>.txt` directly in Editor sidebar; Batch mode supports `trigger_word`, prefix/suffix, skip-existing vs overwrite, and live progress/cancel.
