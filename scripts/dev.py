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
    "settings": ("kogaview_settings_tests", BUILD_DIR / "bin" / "kogaview_settings_tests"),
    "editor": ("kogaview_editor_tests", BUILD_DIR / "bin" / "kogaview_editor_tests"),
    "language": (
        "kogaview_language_tests",
        BUILD_DIR / "bin" / "kogaview_language_tests",
    ),
}
APP_ID_DEV = "io.github.tienv2i.KogaView.Dev"
APP_ID_PROD = "io.github.tienv2i.KogaView"
APP_DIR_DEV = "kogaview-dev"
APP_DIR_PROD = "kogaview"
PROJECT = "KogaView"
# `just install` writes into the system prefix: /usr/local by default, which is
# outside every package manager's ownership. `KOGAVIEW_PREFIX` moves it (a
# per-user install is `KOGAVIEW_PREFIX=$HOME/.local just install`).
PREFIX = Path(os.environ.get("KOGAVIEW_PREFIX", "/usr/local"))
RELEASE_DIR = ROOT / "build" / "release"
RELEASE_BINARY = RELEASE_DIR / "bin" / "kogaview"
PACKAGING_DIR = ROOT / "packaging" / "linux"
DESKTOP_TEMPLATE = PACKAGING_DIR / f"{APP_ID_PROD}.desktop.in"
ICON_SOURCE = PACKAGING_DIR / f"{APP_ID_PROD}.svg"
METAINFO_SOURCE = PACKAGING_DIR / f"{APP_ID_PROD}.metainfo.xml"


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, **kwargs)


def lrelease() -> str:
    """The Qt Linguist `lrelease` the build should use, empty when none is
    installed. `scripts/find_lrelease.py` owns the search order."""
    return output([sys.executable, str(ROOT / "scripts/find_lrelease.py")]).strip()


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


def installed_identity(binary: Path) -> str:
    """Which identity a `kogaview` on PATH is, by where it lives.

    The identity follows the build profile (ADR 0001): the Debug preset is
    `…​.Dev`, the Release preset is the production ID. A binary from anywhere
    else cannot be identified from its path, and saying so is better than
    guessing.
    """
    for path, label in (
        (BINARY, f"dev build, {APP_ID_DEV}"),
        (RELEASE_BINARY, f"release build, {APP_ID_PROD}"),
        (PREFIX / "bin" / "kogaview", f"installed release build, {APP_ID_PROD}"),
    ):
        if binary == path.resolve():
            return label
    return "unknown binary (not built here)"


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

    linguist = lrelease()
    print(f"{'Qt lrelease':18}: {linguist or 'MISSING (set KOGAVIEW_LRELEASE)'}")
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
            print(f"`kogaview` on PATH resolves to {resolved} (not the dev artifact)")
            print(f"  installed identity: {installed_identity(resolved)}")
        else:
            print(f"`kogaview` on PATH is the dev artifact: {resolved}")
    else:
        print("No kogaview on PATH (no installed conflict).")

    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    for base in (PREFIX / "share" / "applications", data_home / "applications"):
        for app_id in (APP_ID_DEV, APP_ID_PROD):
            desktop = base / f"{app_id}.desktop"
            if desktop.exists():
                print(f"Desktop entry present: {desktop} ({app_id})")
    installed_binary = PREFIX / "bin" / "kogaview"
    if installed_binary.is_file():
        stat = installed_binary.stat()
        print(
            f"Installed binary  : {installed_binary}, {stat.st_size} bytes, "
            f"mtime {datetime.fromtimestamp(stat.st_mtime).isoformat(timespec='seconds')}"
        )
    else:
        print(f"Installed binary  : none under {PREFIX} (run `just install`)")

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

    environment = os.environ.copy()
    linguist = lrelease()
    if linguist:
        environment["KOGAVIEW_LRELEASE"] = linguist
    configure = run(["cmake", "--preset", "dev"], env=environment)
    if configure.returncode != 0:
        print("build: CMake configure failed; no binary will be run", file=sys.stderr)
        return configure.returncode

    compile_result = run(["cmake", "--build", "--preset", "dev"], env=environment)
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


# --- install / uninstall -----------------------------------------------------
#
# The install is the release build with the production identity (ADR 0001), so
# an installed KogaView never shares config, state, cache, log or journal with
# the dev build. It writes four files and refreshes two desktop caches:
#
#   ${prefix}/bin/kogaview
#   ${prefix}/share/applications/io.github.tienv2i.KogaView.desktop
#   ${prefix}/share/icons/hicolor/scalable/apps/io.github.tienv2i.KogaView.svg
#   ${prefix}/share/metainfo/io.github.tienv2i.KogaView.metainfo.xml
#
# It does not make KogaView the default image viewer: the MIME list only puts it
# in "Open With", and `xdg-mime default` stays the user's decision (docs/DESKTOP.md).


def build_release() -> int:
    """Configure and build the release preset; refuse to install anything else.

    A release build is what an installed app must be: the dev harness is
    compiled only into Debug (`CMakeLists.txt`), and the identity follows the
    profile, so this binary is `io.github.tienv2i.KogaView`, not `…​.Dev`.
    """
    setup_result = setup()
    if setup_result != 0:
        print("install: refusing to build with missing prerequisites", file=sys.stderr)
        return setup_result

    environment = os.environ.copy()
    linguist = lrelease()
    if linguist:
        environment["KOGAVIEW_LRELEASE"] = linguist
    for step in (
        ["cmake", "--preset", "release"],
        ["cmake", "--build", "--preset", "release"],
    ):
        result = run(step, env=environment)
        if result.returncode != 0:
            print(f"install: {' '.join(step)} failed; nothing was installed", file=sys.stderr)
            return result.returncode

    if not RELEASE_BINARY.is_file() or not os.access(RELEASE_BINARY, os.X_OK):
        print(f"install: expected executable missing: {RELEASE_BINARY}", file=sys.stderr)
        return 1
    return 0


def installed_files() -> dict[str, Path]:
    """Every path `just install` owns. Nothing else is written or removed."""
    return {
        "binary": PREFIX / "bin" / "kogaview",
        "desktop entry": PREFIX / "share" / "applications" / f"{APP_ID_PROD}.desktop",
        "icon": PREFIX
        / "share"
        / "icons"
        / "hicolor"
        / "scalable"
        / "apps"
        / f"{APP_ID_PROD}.svg",
        "AppStream metadata": PREFIX / "share" / "metainfo" / f"{APP_ID_PROD}.metainfo.xml",
    }


def render_desktop_entry() -> str:
    """The desktop template with the install prefix filled in.

    The template is the source of truth (and what `check_packaging.py` reads);
    only the binary directory depends on where the app is being installed.
    """
    text = DESKTOP_TEMPLATE.read_text(encoding="utf-8")
    return text.replace("@BINDIR@", str(PREFIX / "bin"))


def sudo_is_passwordless() -> bool:
    if os.geteuid() == 0:
        return True
    try:
        result = subprocess.run(
            ["sudo", "-n", "true"], capture_output=True, check=False, timeout=10
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def privileged(cmd: list[str]) -> list[str]:
    """Run `cmd` as root, without prompting when the password is not needed.

    `sudo -n` first: an agent has no terminal to type into, and a silent failure
    is better than a command that hangs waiting for a password. A human running
    `just install` by hand gets the normal prompt when `-n` is refused.
    """
    if os.geteuid() == 0:
        return cmd
    if sudo_is_passwordless():
        return ["sudo", "-n", "--", *cmd]
    return ["sudo", "--", *cmd]


def refresh_desktop_caches() -> None:
    applications = PREFIX / "share" / "applications"
    if which("update-desktop-database"):
        run(privileged(["update-desktop-database", str(applications)]))
    theme_dir = PREFIX / "share" / "icons" / "hicolor"
    if (theme_dir / "index.theme").is_file() and which("gtk-update-icon-cache"):
        run(privileged(["gtk-update-icon-cache", "-f", "-t", str(theme_dir)]))
    else:
        # No local copy of the theme's index.theme: GTK still searches this
        # directory through the hicolor search path, there is just no cache of
        # it to rebuild.
        print(f"{theme_dir} has no index.theme; icon cache not rebuilt")


def current_image_handler() -> str:
    return output(["xdg-mime", "query", "default", "image/jpeg"]) or "none"


def install() -> int:
    result = build_release()
    if result != 0:
        return result

    rendered = RELEASE_DIR / f"{APP_ID_PROD}.desktop"
    rendered.write_text(render_desktop_entry(), encoding="utf-8")
    validator = which("desktop-file-validate")
    if validator:
        check = run([validator, str(rendered)])
        if check.returncode != 0:
            print("install: the desktop entry is invalid; nothing was installed", file=sys.stderr)
            return check.returncode

    targets = installed_files()
    sources = {
        "binary": (RELEASE_BINARY, "755"),
        "desktop entry": (rendered, "644"),
        "icon": (ICON_SOURCE, "644"),
        "AppStream metadata": (METAINFO_SOURCE, "644"),
    }
    handler_before = current_image_handler()
    for name, target in targets.items():
        source, mode = sources[name]
        result = run(privileged(["install", "-D", f"-m{mode}", str(source), str(target)]))
        if result.returncode != 0:
            print(f"install: cannot write {target}; stopping here", file=sys.stderr)
            return result.returncode

    refresh_desktop_caches()

    print(f"install: {PROJECT} {APP_ID_PROD} installed under {PREFIX}")
    for name, target in targets.items():
        print(f"  {name:18} {target}")
    print(f"  image viewer group  Categories={desktop_categories()}")
    print(
        "  default handler     unchanged: image/jpeg opens with "
        f"'{handler_before}'. KogaView is offered in Open With; make it the "
        "default yourself with `xdg-mime default "
        f"{APP_ID_PROD}.desktop image/jpeg`."
    )
    print(f"  remove it with      just uninstall")
    return 0


def desktop_categories() -> str:
    for line in render_desktop_entry().splitlines():
        if line.startswith("Categories="):
            return line.partition("=")[2]
    return "(none)"


def uninstall() -> int:
    """Remove the installed files; never touch the user's own data.

    The config, state (logs, journal) and cache directories belong to the user,
    not to the package: an uninstall that deleted them would throw away their
    settings and their unsaved session history.
    """
    targets = installed_files()
    missing = [target for target in targets.values() if not target.exists()]
    if len(missing) == len(targets):
        print(f"uninstall: nothing of {APP_ID_PROD} is installed under {PREFIX}")
        return 0

    for name, target in targets.items():
        result = run(privileged(["rm", "-f", str(target)]))
        if result.returncode != 0:
            print(f"uninstall: cannot remove {target}", file=sys.stderr)
            return result.returncode
        print(f"  removed {name:18} {target}")

    refresh_desktop_caches()
    print(f"uninstall: {APP_ID_PROD} removed from {PREFIX}")
    for kept in (
        xdg_config_home() / APP_DIR_PROD,
        xdg_state_home() / APP_DIR_PROD,
        Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / APP_DIR_PROD,
    ):
        if kept.exists():
            print(f"  kept (your data)   {kept}")
    print("  the default image handler was never changed, so it stays as it is")
    return 0



TEST_USAGE = (
    "usage: just test [cargo|translations|packaging|qml|viewer|browser|cache|"
    "state|settings|editor|language]"
)


def translation_tests() -> int:
    """The `.ts` catalogue and the C++ table that mirrors it must agree.

    Neither copy is derived from the other at build time (see
    `scripts/check_translations.py` for why), so a disagreement is silent: a
    menu and a native dialog would show two translations of one English string.
    """
    return run([sys.executable, "scripts/check_translations.py"]).returncode


def packaging_tests() -> int:
    """The desktop entry, icon and AppStream metadata must match the code.

    `just install` writes claims into the desktop's own databases — which image
    types KogaView opens, which menu group it appears in — and nothing else in
    the build notices when those drift from the decoders or from the app ID.
    """
    return run([sys.executable, "scripts/check_packaging.py"]).returncode


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
    elif choice in ("cargo", "translations", "packaging"):
        suites = {}
    elif choice in QML_TEST_SUITES:
        suites = {choice: QML_TEST_SUITES[choice]}
    else:
        print(f"test: unknown selection '{choice}'\n{TEST_USAGE}", file=sys.stderr)
        return 2

    if choice in ("all", "translations"):
        translation_result = translation_tests()
        if translation_result != 0:
            return translation_result
    if choice in ("all", "packaging"):
        packaging_result = packaging_tests()
        if packaging_result != 0:
            return packaging_result
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
    if command == "install":
        return install()
    if command == "uninstall":
        return uninstall()
    if command == "package":
        return not_implemented(command, "M6")
    if command in ("flatpak-build", "flatpak-run"):
        return not_implemented(command, "M6 (after sandbox verification)")
    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
