# KogaView Plugin Ecosystem (`v2.0.0`)

KogaView uses a **strictly out-of-process, lazy-loaded plugin architecture** ([ADR 0024](adr/0024-ai-plugin-architecture.md)) so the core photo viewer stays lightweight and starts instantaneously.

## Core Design Principles
- **Zero startup cost**: KogaView only reads lightweight `manifest.json` files under `$XDG_DATA_HOME/kogaview/plugins/` (or `kogaview-dev/plugins/`). No plugin binaries or AI models are loaded when opening the app.
- **Process isolation (`jsonl-stdio`)**: Each plugin runs in its own OS process communicating over line-delimited JSON on stdin/stdout (`run`, `progress`, `done`, `error`, `cancel`, `shutdown`), then exits after completing its job to release all RAM/VRAM.
- **On-demand model downloads**: AI weights (`.onnx`) and OCR language packs (`.traineddata`, `vocab.txt`, `ppocr_keys_v1.txt`) are downloaded on demand into `$XDG_DATA_HOME/kogaview[-dev]/models/` via **Settings → Plugins** with live progress bars, cancellation, and atomic `.part` staging.
- **Safe Quick Actions**: File-modifying Quick Actions (Remove Background, Upscale, Strip EXIF, Optimize) never silently destroy originals — they create numbered sibling backups (`photo.png~`, `photo.png.2~`, `photo.png.3~`), atomically overwrite the target file, and refresh the Viewer.

---

## Installing & Managing Plugins

Build and install all 6 official plugins at once:

```sh
just build-plugins
```

Or install individual plugins into `~/.local/share/kogaview[-dev]/plugins/`:

```sh
just build-plugin-rembg       # AI Background Removal (ONNX)
just build-plugin-upscale     # AI Super-Resolution 2x/4x (ONNX)
just build-plugin-utils       # Non-AI Strip EXIF/GPS & Optimize
just build-plugin-ocr         # Offline Tesseract OCR (5 languages + region crop)
just build-plugin-translate   # Read & Translate (Tesseract + Google Translate)
just build-plugin-ai-ocr      # AI OCR (Manga-OCR + RapidOCR PP-OCRv4 ONNX)
```

Open **Settings → Plugins** in KogaView to:
- Inspect discovered plugins, versions, IDs, Quick Actions, and Ready/Unavailable status.
- Filter and download models by category (**All** · **Background** · **Upscale** · **OCR languages**).
- Point any ONNX model slot to a local `.onnx` file (**Local file…**) or delete downloaded models to reclaim disk space.

---

## Official Plugins Reference

### 1. `kogaview-plugin-rembg` — AI Background Removal (ONNX)
- **Plugin ID**: `kogaview.rmbg.onnx`
- **Source**: [`plugins/kogaview-plugin-rembg/`](../plugins/kogaview-plugin-rembg/)
- **Permissions**: `network: false`, `gpu: false` (static CPU ONNX Runtime, 0 external `.so` dependencies)
- **Where it appears**:
  - **Editor**: Tool rail → **Remove Background** (non-destructive `EditOperation::AiResult`, supports Undo/Redo/Reset and edge feathering).
  - **Browser & Viewer**: Right-click → **Quick actions** → Remove Background (General / Anime / Portrait / Fast).
- **Available On-Demand Models (8 models)**:

| Model ID | Name | Tier | Approx. Size | Best For |
|---|---|---|---|---|
| `silueta` | Silueta (Fast & compact) | `fast` | ~43 MB | Quick cutouts on lower-RAM CPUs |
| `u2netp` | U2Net-p (Lightweight) | `fast` | ~4.7 MB | Ultra-fast previews & simple subjects |
| `isnet-general-use` | ISNet General | `general` | ~176 MB | General photography & products |
| `u2net` | U2Net General | `general` | ~176 MB | Classic general-purpose segmentation |
| `isnet-anime` | ISNet Anime | `anime` | ~176 MB | Anime illustrations, cel-shaded characters & manga art |
| `u2net_human_seg` | U2Net Human Segmentation | `portrait` | ~176 MB | Full-body & half-body people |
| `birefnet-general-lite` | BiRefNet General Lite | `quality` | ~224 MB | High-detail edges, hair & complex silhouettes |
| `birefnet-portrait` | BiRefNet Portrait | `portrait` | ~973 MB | Studio-grade portrait & fine hair matting |

---

### 2. `kogaview-plugin-upscale` — AI Super-Resolution 2× / 4× (ONNX)
- **Plugin ID**: `kogaview.upscale.onnx`
- **Source**: [`plugins/kogaview-plugin-upscale/`](../plugins/kogaview-plugin-upscale/)
- **Permissions**: `network: false`, `gpu: false`
- **Features**:
  - **Tiled inference** with overlap blending so large images never exhaust RAM.
  - **Full alpha channel preservation** (transparent PNGs stay transparent after upscaling).
  - Automatic scale-factor detection from the loaded ONNX graph.
- **Where it appears**: Browser & Viewer right-click → **Quick actions**.
- **Available On-Demand Models (4 models)**:

| Model ID | Name | Scale | Best For |
|---|---|---|---|
| `realesrgan-x4plus` | Real-ESRGAN x4+ (General) | 4× | Photos, landscapes, real-world textures |
| `realesrgan-x4plus-anime` | Real-ESRGAN x4+ Anime 6B | 4× | Anime art, manga scans, digital line art |
| `swin2sr-x2` | Swin2SR 2× | 2× | Crisp 2× enlargement with minimal artifacts |
| `swin2sr-x4` | Swin2SR 4× | 4× | High-fidelity 4× restoration |

---

### 3. `kogaview-plugin-utils` — Non-AI Image Utilities
- **Plugin ID**: `kogaview.utils`
- **Source**: [`plugins/kogaview-plugin-utils/`](../plugins/kogaview-plugin-utils/)
- **Permissions**: `network: false`, `gpu: false` · **No models required** (~1.8 MB binary)
- **Quick Actions (Browser & Viewer)**:
  - **Strip EXIF / GPS metadata**: Re-encodes pixel data without camera/GPS/XMP tags for privacy before sharing (keeps backup `<file>~`).
  - **Optimize file size**: Smart compression pass to shrink PNG/JPEG/WebP file sizes while preserving visual quality.

---

### 4. `kogaview-plugin-ocr` — Offline Tesseract OCR
- **Plugin ID**: `kogaview.ocr.tesseract`
- **Source**: [`plugins/kogaview-plugin-ocr/`](../plugins/kogaview-plugin-ocr/)
- **Permissions**: `network: false`, `gpu: false` · Uses system `tesseract` + on-demand `.traineddata` packs
- **Features**:
  - **5 Supported Languages**: English (`eng`, built-in), Vietnamese (`vie`), Japanese (`jpn`), **Japanese Vertical / Manga** (`jpn_vert` with `--psm 5`), Chinese Simplified (`chi_sim`), and Korean (`kor`).
  - **Tier-1 Complex Background Preprocessing**: Automatically upscales small crops 2× (`Lanczos3`), stretches 2%–98% grayscale contrast, and retries opposite polarity for white text on dark manga backgrounds.
  - **Two entry points**:
    1. **Quick Actions (Browser & Viewer)**: Full-image OCR directly to desktop clipboard (`Copy text (OCR — English / Vietnamese / Japanese / Chinese / Korean)`).
    2. **Interactive Region OCR (Viewer)**: Right-click → **Scan text region (OCR)** (or switch to **OCR only** in the `L` overlay) to drag-select multiple frames offline.
- **On-Demand Language Packs** (Settings → Plugins → **OCR languages**):
  - `vie.traineddata` (~1.5 MB), `jpn.traineddata` (~2.5 MB), `jpn_vert.traineddata` (~2.9 MB), `chi_sim.traineddata` (~2.5 MB), `kor.traineddata` (~1.7 MB).

---

### 5. `kogaview-plugin-translate` — Read & Translate (Tesseract + Google Translate)
- **Plugin ID**: `kogaview.translate`
- **Source**: [`plugins/kogaview-plugin-translate/`](../plugins/kogaview-plugin-translate/)
- **Permissions**: `network: true` (Google Translate HTTPS via `curl` with automatic retry), `gpu: false`
- **Features**:
  - Shares the same `$XDG_DATA_HOME/kogaview[-dev]/models/` Tesseract language packs as `kogaview-plugin-ocr`.
  - Supports both **cropped speech-bubble regions** (with Tier-1 preprocessing) and **full-page translation** (groups Tesseract TSV word boxes into paragraph blocks).
  - Supports all **5 input & output languages**: English, Japanese (Horizontal & Vertical), Vietnamese, Chinese, and Korean.

---

### 6. `kogaview-plugin-ai-ocr` — AI OCR: Manga-OCR & RapidOCR (ONNX)
- **Plugin ID**: `kogaview.ocr.ai`
- **Source**: [`plugins/kogaview-plugin-ai-ocr/`](../plugins/kogaview-plugin-ai-ocr/)
- **Permissions**: `network: true` (optional Google Translate when in `Translate` mode; **100% offline** in `OCR only` mode), `gpu: false`
- **Engines**:
  1. **Manga-OCR** (`l0wgear/manga-ocr-2025-onnx`):
     - ViT Vision Encoder (`22.3 MB`) + BERT Japanese Decoder (`118 MB`) + `vocab.txt` (`24 KB`).
     - Purpose-built for **Japanese manga**: vertical/horizontal text, furigana, stylized comic fonts, screentones, and text overlaid on complex artwork.
  2. **RapidOCR** (`SWHL/RapidOCR` PP-OCRv4):
     - DBNet Text Detector (`4.7 MB`) + SVTR/CTC Recognizer (`10.8 MB`) + `ppocr_keys_v1.txt` (`26 KB`).
     - Purpose-built for **text on complex colored backgrounds**, manhwa/manhua, UI screenshots, and multi-line full-page detection.
- **Usage**: Download the desired engine's 3 files in **Settings → Plugins → OCR languages**, then select **`Manga-OCR`** or **`RapidOCR`** in the **`OCR:`** dropdown of the Viewer Translate overlay (`L`).

---

## Using the Viewer Read & Translate Overlay (`L`)

1. Open any image or manga chapter in **Viewer** (works in **Single**, **Dual**, and **Webtoon** modes).
2. Press **`L`** (or right-click → **Read & translate** / **Scan text region (OCR)**).
3. Choose:
   - Mode: **`Translate`** | **`OCR only`** | **`Pan`**
   - Engine: **`Tesseract`** | **`Manga-OCR`** | **`RapidOCR`**
   - Languages: **`From:`** (6 options) `⇄` **`To:`** (5 options)
4. **Drag** on any speech bubble (or click **Translate page / Scan page**). Repeat for as many bubbles as you want on the same page.
5. **Interact with bubbles**:
   - **Drag** the `⋮⋮` header bar to move a bubble out of the way of artwork (also draggable for the top bar and result card; double-click to reset).
   - **Select & copy text** directly inside any bubble or the result card (`Ctrl+C`).
   - Click **`Orig` / `Trans`** on a bubble (or **`Original` / `Translation`** on the result card) to toggle between recognized text and translation (1 language shown at a time).
   - Click **`↻`** on a bubble or **`Retry`** on the result card to re-run OCR & translation in-place.
   - Click **`Aa`** to adjust **Font family**, **Auto vs Fixed size**, **`A−` / `A+`**, or **Reset**.
6. **Navigate seamlessly**:
   - **Scroll wheel** zooms (or scrolls in Webtoon).
   - **Hold `Space` + left-drag** or **middle-mouse drag** pans smoothly while auto-hiding the 2 floating popups.
   - Click **`Review`** to hide both popups and bubble headers so you can read translated pages cleanly with normal pan and `Space` page stepping.
7. **Persistence**:
   - Every bubble and position is auto-saved to `<folder>/.kogaview/translation/<filename>.json` and auto-loaded next time you open that image.
   - Click **`Delete saved`** on the top bar to remove the sidecar file cleanly.

---

## Writing a Custom Plugin

Create a folder under `$XDG_DATA_HOME/kogaview/plugins/<your-plugin>/` containing:
- `manifest.json` (`apiVersion: 1`, `id`, `name`, `version`, `entry.command`, `entry.protocol: "jsonl-stdio"`, `permissions`, `models`, `capabilities`, `quickActions`)
- Executable binary at `entry.command` speaking line-delimited JSON:
  - **Input (stdin)**: `{"id":"1","op":"run","action":"...","input":"/path/img.png","output":"/tmp/out.png","modelPath":"...","device":"cpu","params":{...}}` and `{"op":"shutdown"}`.
  - **Output (stdout)**:
    - Progress: `{"id":"1","event":"progress","percent":50,"stage":"Processing…"}`
    - Success: `{"id":"1","event":"done","meta":{...}}`
    - Error: `{"id":"1","event":"error","code":"...","message":"..."}`

Click **Refresh plugins** in **Settings → Plugins** — KogaView discovers your plugin immediately without restarting.
