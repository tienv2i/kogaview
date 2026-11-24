# ADR 0024: Out-of-Process AI Plugin Architecture

- **Status**: Accepted (2026-11-24)
- **Context**: KogaView must stay lightweight, fast-starting, and Flatpak/sandbox-compatible while offering opt-in AI image features (starting with Remove Background via `rembg`-compatible ONNX models). Bundling ONNX Runtime, CUDA/ROCm, or PyTorch inside the main `kogaview` binary would bloat installs, slow cold start, and risk crashing the desktop shell on GPU driver errors.

## Decision

1. **Out-of-process JSONL-stdio plugin protocol (`apiVersion: 1`)**:
   - Plugins live under `$XDG_DATA_HOME/kogaview[-dev]/plugins/<plugin-id>/` with a static `manifest.json`.
   - At startup and on refresh, Core reads only `manifest.json` files (kilobytes, zero spawned processes, zero RAM/VRAM).
   - When an AI command is invoked through the Command Gateway, `PluginHost` lazy-spawns the plugin executable, exchanges JSON Lines over `stdin`/`stdout` (`run`, `cancel`, `shutdown` → `progress`, `done`, `error`), and passes image buffers via temporary PNG files in `$XDG_CACHE_HOME/kogaview[-dev]/ai-ipc/`.
   - Idle workers receive `{"op":"shutdown"}` after `ai.autoUnloadSecs` (default 60s) so 100% of RAM/VRAM is released back to the OS.
2. **Default CPU with Auto/GPU fallback**:
   - `AiDevice` defaults to `Cpu` so every machine works reliably without driver setup.
   - Users can choose `Auto`, `Cpu`, or `Gpu` in `Settings → AI`. In `Auto`/`Gpu` mode, the worker attempts GPU execution providers and automatically falls back to CPU with a diagnostic note if the driver is unavailable or VRAM is exhausted.
3. **On-demand Model Manager (`$XDG_DATA_HOME/kogaview[-dev]/models/`)**:
   - Models are never bundled or pre-downloaded.
   - Built-in Remove Background catalog offers 3 quality tiers (`u2netp` ~5 MB Fast, `rmbg-1.4` ~44 MB Balanced default, `isnet-general-use` ~176 MB High) plus user-selected local `.onnx` files.
   - Downloads run asynchronously with progress, cancellation, atomic `.part` rename, and optional SHA-256 verification.
4. **Non-destructive Editor integration**:
   - Plugin outputs are read by Core and pushed onto `EditorDocument` as `EditOperation::AiResult { label, pixels }`, giving instant Undo/Redo without modifying source files.

## Consequences

- `kogaview` core binary has zero AI runtime dependencies.
- First official plugin (`kogaview-plugin-rembg`) is a standalone Rust + `ort` (ONNX Runtime) binary; community/custom plugins can be written in any language (Rust, Python, C++, Go) speaking the same `jsonl-stdio` contract.
