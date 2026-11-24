# Developer task entrypoint. Business logic lives in scripts/dev.py and the
# build system, never in these recipes.
_default:
    @just --list

setup:
    @python3 scripts/dev.py setup

doctor:
    @python3 scripts/dev.py doctor

build:
    @python3 scripts/dev.py build

run *args:
    @python3 scripts/dev.py run {{args}}

# `just test` = everything (the pre-commit gate). Narrow it while iterating:
#   just test cargo | viewer | browser | cache | state | settings | editor | qml
test *args:
    @python3 scripts/dev.py test {{args}}

logs:
    @python3 scripts/dev.py logs

install:
    @python3 scripts/dev.py install

# Development install: reuses the existing `build/dev/bin/kogaview` binary (only
# building `dev` when missing) behind a `KOGAVIEW_PROFILE=prod` wrapper so it
# shares the installed app ID, config directory and desktop entry without a
# second Release/RelWithDebInfo build.
install-dev:
    @python3 scripts/dev.py install-dev

uninstall:
    @python3 scripts/dev.py uninstall

package:
    @python3 scripts/dev.py package

flatpak-build:
    @python3 scripts/dev.py flatpak-build

flatpak-run:
    @python3 scripts/dev.py flatpak-run

# Optional AI plugin: builds the standalone Rust ONNX Remove Background worker
# and installs its binary, runtime libs, and manifest into the XDG user plugins directory.
build-plugin-rembg:
    cargo build --manifest-path plugins/kogaview-plugin-rembg/Cargo.toml --release
    @python3 -c 'import os, pathlib, shutil; home = pathlib.Path.home(); data = pathlib.Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")); src = pathlib.Path("plugins/kogaview-plugin-rembg"); rel = src / "target/release"; bin_src = rel / "kogaview-plugin-rembg"; libs = list(rel.glob("libonnxruntime*.so*")) + list(rel.glob("onnxruntime*.dll")); [ (d.mkdir(parents=True, exist_ok=True), (d/"bin").mkdir(exist_ok=True), shutil.copy2(src/"manifest.json", d/"manifest.json"), shutil.copy2(bin_src, d/"bin/kogaview-plugin-rembg"), [shutil.copy2(l, d/"bin"/l.name) for l in libs]) for d in [data/"kogaview-dev/plugins/kogaview-rmbg-onnx", data/"kogaview/plugins/kogaview-rmbg-onnx"] ]; print("Installed kogaview-plugin-rembg +", len(libs), "runtime lib(s) to", data/"kogaview[-dev]/plugins/kogaview-rmbg-onnx")'
