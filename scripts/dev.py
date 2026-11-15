#!/usr/bin/env python3
"""KogaView developer/agent command surface.

`just` is the public entry point; this script owns the build/run orchestration
so the recipes stay thin. Build failures are fatal: no stale binary is ever run.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = ROOT / "build" / "dev"
BINARY = BUILD_DIR / "bin" / "kogaview"
# QML suites the developer can select by name; every one loads the real `.qml`
# sources. The order is the order `test` builds and runs them in.
QML_TEST_SUITES = {
    "viewer": ("kogaview_qml_tests", BUILD_DIR / "bin" / "kogaview_qml_tests"),
    "browser": (
        "kogaview_browser_qml_tests",
        BUILD_DIR / "bin" / "kogaview_browser_qml_tests",
    ),
    "cache": (
        "kogaview_browser_cache_tests",
        BUILD_DIR / "bin" / "kogaview_browser_cache_tests",
    ),
    "state": ("kogaview_state_tests", BUILD_DIR / "bin" / "kogaview_state_tests"),
}
APP_ID_DEV = "io.github.tienv2i.KogaView.Dev"
APP_ID_PROD = "io.github.tienv2i.KogaView"
APP_DIR_DEV = "kogaview-dev"
APP_DIR_PROD = "kogaview"
PROJECT = "KogaView"


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, **kwargs)


def output(cmd: list[str]) -> str:
    try:
        result = subprocess.run(
            cmd, cwd=ROOT, capture_output=True, text=True, timeout=20, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def which(name: str) -> str | None:
    return shutil.which(name)


def qt_version() -> tuple[str | None, str | None, str | None]:
    for locator in ("qmake6", "qmake"):
        path = which(locator)
        if path:
            return (
                output([path, "-query", "QT_VERSION"]),
                output([path, "-query", "QT_INSTALL_PREFIX"]),
                output([path, "-query", "QT_INSTALL_QML"]),
            )
    return None, None, None


def xdg_state_home() -> Path:
    value = os.environ.get("XDG_STATE_HOME")
    if value:
        return Path(value)
    return Path.home() / ".local" / "state"


def xdg_config_home() -> Path:
    value = os.environ.get("XDG_CONFIG_HOME")
    if value:
        return Path(value)
    return Path.home() / ".config"


def log_dir() -> Path:
    return xdg_state_home() / APP_DIR_DEV / "logs"


def required_tools() -> list[tuple[str, str, str]]:
    """(display name, executable, install hint)"""
    return [
        ("Rust compiler", "rustc", "pacman -S rustup && rustup default stable"),
        ("Cargo", "cargo", "pacman -S rustup && rustup default stable"),
        ("CMake", "cmake", "pacman -S cmake"),
        ("just", "just", "pacman -S just"),
        ("C++ compiler", "c++", "pacman -S gcc"),
        ("Qt 6 qmake", "qmake6", "pacman -S qt6-base"),
        ("pkg-config", "pkg-config", "pacman -S pkgconf"),
    ]


def doctor() -> int:
    print(f"{PROJECT} doctor")
    print("=" * 60)
    print(f"Project root      : {ROOT}")
    print(f"Platform          : {platform.system()} {platform.release()} ({platform.machine()})")
    print(f"Session           : {os.environ.get('XDG_SESSION_TYPE', 'unknown')} "
          f"(DISPLAY={os.environ.get('DISPLAY', '-')}, "
          f"WAYLAND_DISPLAY={os.environ.get('WAYLAND_DISPLAY', '-')})")
    print(f"XDG_STATE_HOME    : {xdg_state_home()}")
    print(f"XDG_CONFIG_HOME   : {xdg_config_home()}")
    print(f"Log directory     : {log_dir()}")
    print(f"Config file       : {xdg_config_home() / APP_DIR_DEV / 'config.json'}")
    print()

    print("Toolchain")
    print("-" * 60)
    for display, exe, hint in required_tools():
        path = which(exe)
        version = ""
        if path:
            version = output([path, "--version"]).splitlines()[0] if exe != "qmake6" else ""
        print(f"{display:18}: {path or 'MISSING'}" + (f"  [{version}]" if version else ""))
        if not path:
            print(f"{'':18}  install: {hint}")

    version, prefix, qml_dir = qt_version()
    print(f"{'Qt version':18}: {version or 'unknown'}"
          + (f"  ({prefix})" if prefix else ""))
    if qml_dir:
        for module in ("QtQuick", "QtQuick/Controls", "QtQuick/Layouts", "QtQuick/Window"):
            present = (Path(qml_dir) / module).exists()
            print(f"{'Qt QML module':18}: {module}: {'ok' if present else 'MISSING'}")
    print()

    print("Identity and artifacts")
    print("-" * 60)
    print(f"{'Dev app ID':18}: {APP_ID_DEV}")
    print(f"{'Prod app ID':18}: {APP_ID_PROD}")
    print(f"{'Dev data dir':18}: {APP_DIR_DEV}")
    print(f"{'Prod data dir':18}: {APP_DIR_PROD}")
    print(f"{'Build mode':18}: dev (Debug preset) -> KogaView (Dev) identity")
    print(f"{'Canonical binary':18}: {BINARY}")
    if BINARY.exists():
        stat = BINARY.stat()
        print(f"{'Binary state':18}: present, {stat.st_size} bytes, "
              f"mtime {datetime.fromtimestamp(stat.st_mtime).isoformat(timespec='seconds')}")
    else:
        print(f"{'Binary state':18}: not built (run `just build`)")
    print()

    print("Installation conflicts")
    print("-" * 60)
    installed = which("kogaview")
    if installed:
        resolved = Path(installed).resolve()
        if resolved != BINARY.resolve():
            print(f"WARNING: `kogaview` on PATH resolves to {resolved}, not {BINARY}")
        else:
            print(f"`kogaview` on PATH is the dev artifact: {resolved}")
    else:
        print("No kogaview on PATH (no installed conflict).")

    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    for app_id in (APP_ID_DEV, APP_ID_PROD):
        desktop = data_home / "applications" / f"{app_id}.desktop"
        if desktop.exists():
            print(f"Desktop entry present: {desktop} (verify identity before claiming install)")

    latest = latest_log()
    if latest:
        print(f"Current dev log   : {latest}")
    else:
        print("Current dev log   : none yet")
    return 0


def setup() -> int:
    missing = [(display, hint) for display, exe, hint in required_tools() if not which(exe)]
    version, _prefix, qml_dir = qt_version()
    if not version:
        missing.append(("Qt 6", "pacman -S qt6-base qt6-declarative"))
    if qml_dir:
        for module in ("QtQuick", "QtQuick/Controls", "QtQuick/Layouts"):
            if not (Path(qml_dir) / module).exists():
                missing.append((f"QML module {module}", "pacman -S qt6-declarative"))

    if missing:
        print(f"{PROJECT} setup: missing prerequisites", file=sys.stderr)
        for display, hint in missing:
            print(f"  - {display}: {hint}", file=sys.stderr)
        return 1

    print(f"{PROJECT} setup: required toolchain present")
    print(f"  Rust   : {output(['rustc', '--version'])}")
    print(f"  CMake  : {output(['cmake', '--version']).splitlines()[0]}")
    print(f"  just   : {output(['just', '--version'])}")
    print(f"  Qt     : {version}")
    print(f"  dev ID : {APP_ID_DEV}")
    return 0


def build() -> int:
    setup_result = setup()
    if setup_result != 0:
        print("build: refusing to build with missing prerequisites", file=sys.stderr)
        return setup_result

    configure = run(["cmake", "--preset", "dev"])
    if configure.returncode != 0:
        print("build: CMake configure failed; no binary will be run", file=sys.stderr)
        return configure.returncode

    compile_result = run(["cmake", "--build", "--preset", "dev"])
    if compile_result.returncode != 0:
        print("build: compile failed; no binary will be run", file=sys.stderr)
        return compile_result.returncode

    if not BINARY.is_file() or not os.access(BINARY, os.X_OK):
        print(f"build: expected executable missing: {BINARY}", file=sys.stderr)
        return 1

    print(f"build: canonical binary {BINARY}")
    return 0


def run_app(args: list[str]) -> int:
    result = build()
    if result != 0:
        print("run: build failed; refusing to launch a stale or partial binary", file=sys.stderr)
        return result

    argv = [str(BINARY), *args]
    print("+ " + " ".join(argv), flush=True)
    os.execv(str(BINARY), argv)
    return 1  # unreachable


TEST_USAGE = "usage: just test [cargo|qml|viewer|browser|cache|state]"


def rust_tests() -> int:
    result = run(["cargo", "test", "--workspace"])
    if result.returncode != 0:
        print("test: cargo tests failed", file=sys.stderr)
    return result.returncode


def test(selection: list[str]) -> int:
    """Rust tests, the Qt Quick suites, or a named one of them.

    Bare `just test` is the pre-commit gate: everything. `just test cargo` and
    `just test <suite>` exist because that gate is ~19 s warm and ~45 s when a
    change forces a rebuild, most of it in suites the edit cannot affect — too
    slow to sit through while editing one file.
    """
    if len(selection) > 1:
        print(f"test: expected at most one selection\n{TEST_USAGE}", file=sys.stderr)
        return 2
    choice = selection[0] if selection else "all"
    if choice in ("all", "qml"):
        suites = dict(QML_TEST_SUITES)
    elif choice == "cargo":
        suites = {}
    elif choice in QML_TEST_SUITES:
        suites = {choice: QML_TEST_SUITES[choice]}
    else:
        print(f"test: unknown selection '{choice}'\n{TEST_USAGE}", file=sys.stderr)
        return 2

    if choice in ("all", "cargo"):
        cargo_result = rust_tests()
        if cargo_result != 0:
            return cargo_result
    if not suites:
        return 0
    return qml_tests(suites)


def qml_tests(suites: dict[str, tuple[str, Path]]) -> int:
    """Run the selected Qt Quick suites against the real QML sources.

    The tests load `crates/desktop/qml/*.qml` unchanged and assert on what Qt
    Quick actually does: viewer transforms (centring, zoom, flip) and the
    commands the browser/explorer emit for real clicks. A binding or gesture
    that regresses fails here instead of only being visible on screen.
    """
    setup_result = setup()
    if setup_result != 0:
        print("test: refusing to run the QML tests without prerequisites", file=sys.stderr)
        return setup_result

    # CMake reconfigures itself when `CMakeLists.txt` or the preset changes, so
    # configuring on every run only bought 0.9 s of latency. Configure once, when
    # there is no build tree yet.
    if not (BUILD_DIR / "CMakeCache.txt").is_file():
        configure = run(["cmake", "--preset", "dev"])
        if configure.returncode != 0:
            print("test: CMake configure failed; QML tests were not run", file=sys.stderr)
            return configure.returncode

    # One invocation for every selected target: CMake then overlaps what it can,
    # instead of paying the (single-threaded, CXX-Qt-linked) dependency walk once
    # per suite. Measured on this tree: 14.7 s in three calls, 11.5 s in one.
    targets: list[str] = []
    for target, _binary in suites.values():
        targets.extend(["--target", target])
    compile_result = run(["cmake", "--build", "--preset", "dev", *targets])
    if compile_result.returncode != 0:
        print("test: QML test build failed; no suite was run", file=sys.stderr)
        return compile_result.returncode

    # `offscreen` keeps the suites out of the desktop session; the input tests
    # drive explicit mouse/wheel events, so nothing depends on real input.
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    for name, (target, binary) in suites.items():
        if not binary.is_file():
            print(f"test: expected QML test binary missing: {binary}", file=sys.stderr)
            return 1
        print(f"+ {name}: {binary}", flush=True)
        result = run([str(binary)], env=env)
        if result.returncode != 0:
            print(f"test: QML suite failed ({target})", file=sys.stderr)
            return result.returncode
    return 0


def latest_log() -> Path | None:
    directory = log_dir()
    if not directory.is_dir():
        return None
    files = [path for path in directory.glob("kogaview.jsonl*") if path.is_file()]
    if not files:
        return None
    return max(files, key=lambda path: path.stat().st_mtime)


def logs() -> int:
    latest = latest_log()
    if latest is None:
        print(f"No log file under {log_dir()} yet. Run `just run` first.", file=sys.stderr)
        return 1
    print(f"# {latest}")
    try:
        lines = latest.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        print(f"logs: cannot read {latest}: {error}", file=sys.stderr)
        return 1
    for line in lines[-200:]:
        print(line)
    return 0


def not_implemented(command: str, milestone: str) -> int:
    print(
        f"NOT IMPLEMENTED: '{command}' lands in {milestone}. "
        "See docs/IMPLEMENTATION_PLAN.md.",
        file=sys.stderr,
    )
    return 2


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "doctor"
    if command in ("setup", "doctor", "build", "logs"):
        return {
            "setup": setup,
            "doctor": doctor,
            "build": build,
            "logs": logs,
        }[command]()
    if command == "test":
        return test(sys.argv[2:])
    if command == "run":
        return run_app(sys.argv[2:])
    if command in ("install", "uninstall", "package"):
        return not_implemented(command, "M6")
    if command in ("flatpak-build", "flatpak-run"):
        return not_implemented(command, "M6 (after sandbox verification)")
    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
