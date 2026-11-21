#!/usr/bin/env python3
"""KogaView developer/agent command surface.

`just` is the public entry point; this script owns the build/run orchestration
so the recipes stay thin. Build failures are fatal: no stale binary is ever run.
"""

from __future__ import annotations

import os
import platform
import re
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
    "toolbar": ("kogaview_toolbar_tests", BUILD_DIR / "bin" / "kogaview_toolbar_tests"),
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
# The optimized build that keeps the `KOGAVIEW_DEV_*` evidence hooks. It is
# RelWithDebInfo, so `cfg!(debug_assertions)` is off and the identity is the
# production one (`Profile::current()`), the same data directories and the same
# app ID as a release install. `just install-dev` puts *this* under the prefix
# so a development install can be exercised with the hooks the release lacks.
DEVPROD_DIR = ROOT / "build" / "dev-prod"
DEVPROD_BINARY = DEVPROD_DIR / "bin" / "kogaview"
PACKAGING_DIR = ROOT / "packaging" / "linux"
DESKTOP_TEMPLATE = PACKAGING_DIR / f"{APP_ID_PROD}.desktop.in"
ICON_SOURCE = PACKAGING_DIR / f"{APP_ID_PROD}.svg"
METAINFO_SOURCE = PACKAGING_DIR / f"{APP_ID_PROD}.metainfo.xml"
# Raster copies of `ICON_SOURCE` written beside it. The scalable SVG alone is not
# enough for the launcher: see `icon_fallbacks()`.
ICON_PIXMAP_SIZES = (16, 24, 32, 48, 64, 128, 256)
# The interface languages the launch surface is localised into. English is the
# source text and needs no translation; these come first in the pickers, so `vi`
# leads. `i18n/kogaview_vi.ts` holds the in-window strings (ADR 0006); the
# desktop entry and AppStream metadata are generated from these tables because
# neither format can read a Qt catalogue.
DESKTOP_LANGUAGES = {
    "vi": {
        "Name": "KogaView",
        "GenericName": "Trình xem ảnh",
        "Comment": "Duyệt, xem và chỉnh sửa ảnh",
        "Keywords": "ảnh;hình;thư viện ảnh;trình xem;chỉnh sửa;duyệt;",
        "summary": "Duyệt, xem và chỉnh sửa ảnh",
        "description": (
            "KogaView là trình duyệt, trình xem và trình chỉnh sửa ảnh. Ứng dụng "
            "quét một thư mục trong nền, hiển thị lưới ảnh thu nhỏ kèm bản xem "
            "trước, mở ảnh trong trình xem có thể thu phóng và kéo, và chỉnh sửa "
            "trên một bản làm việc của ảnh."
        ),
    },
}


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
        (DEVPROD_BINARY, f"dev-prod build, {APP_ID_PROD} (hooks compiled in)"),
        (PREFIX / "bin" / "kogaview", f"installed build, {APP_ID_PROD}"),
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
    # AVIF decoding is `image`'s `avif-native` feature; `dav1d-sys` finds it
    # through pkg-config and CMake links it into the executable (ADR 0005
    # revision). A missing library fails the build, so say so here.
    dav1d = output(["pkg-config", "--modversion", "dav1d"]) if which("pkg-config") else ""
    print(f"{'libdav1d (AVIF)':18}: {dav1d or 'MISSING (pacman -S libdav1d)'}")
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
    present = sum(1 for path in icon_fallbacks() if path.is_file())
    theme_dir = PREFIX / "share" / "icons" / "hicolor"
    cache = theme_dir / "icon-theme.cache"
    cached = False
    if cache.is_file():
        try:
            cached = APP_ID_PROD.encode() in cache.read_bytes()
        except OSError:
            cached = False
    print(
        f"Icon files        : {present}/{len(icon_fallbacks())} raster sizes + "
        f"{'SVG' if (theme_dir / 'scalable' / 'apps' / f'{APP_ID_PROD}.svg').is_file() else 'no SVG'}"
        f"; theme cache {'covers' if cached else 'does not cover'} {APP_ID_PROD}"
    )

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


def build_preset(preset: str, binary: Path) -> int:
    """Configure and build one preset; refuse to install anything else.

    A release build is what an installed app must be: the dev harness is off in
    a plain Release build (`CMakeLists.txt`), and the identity follows the
    profile, so this binary is `io.github.tienv2i.KogaView`, not `…​.Dev`.
    `dev-prod` is the development alternative: optimized, hooks compiled in, and
    still the production identity because `RelWithDebInfo` defines `NDEBUG`.
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
        ["cmake", "--preset", preset],
        ["cmake", "--build", "--preset", preset],
    ):
        result = run(step, env=environment)
        if result.returncode != 0:
            print(f"install: {' '.join(step)} failed; nothing was installed", file=sys.stderr)
            return result.returncode

    if not binary.is_file() or not os.access(binary, os.X_OK):
        print(f"install: expected executable missing: {binary}", file=sys.stderr)
        return 1
    return 0


def build_release() -> int:
    """Configure and build the release preset."""
    return build_preset("release", RELEASE_BINARY)


def installed_files() -> dict[str, Path]:
    """Every path `just install` owns. Nothing else is written or removed."""
    files = {
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
    for index, path in enumerate(icon_fallbacks(), start=1):
        files[f"icon {ICON_PIXMAP_SIZES[index - 1]}"] = path
    return files


def render_desktop_entry() -> str:
    """The desktop template with the install prefix and translations filled in.

    The template is the source of truth (and what `check_packaging.py` reads);
    only the binary directory depends on where the app is being installed. The
    translated keys (`Name[vi]`, `Comment[vi]`, …) are appended inside the
    `[Desktop Entry]` group directly after their English counterpart, because the
    gettext `localedir` alternative needs a `.mo` build step this repository
    does not have yet.
    """
    text = DESKTOP_TEMPLATE.read_text(encoding="utf-8").replace(
        "@BINDIR@", str(PREFIX / "bin")
    )
    for language, strings in DESKTOP_LANGUAGES.items():
        for key in ("Name", "GenericName", "Comment", "Keywords"):
            text = _after_desktop_key(text, key, f"{key}[{language}]={strings[key]}")
    return text


def _after_desktop_key(text: str, key: str, line: str) -> str:
    """Put `line` directly after the `key=` line of the first group."""
    marker = f"\n{key}="
    start = text.index(marker)
    end = text.index("\n", start + len(marker)) + 1
    return text[:end] + line + "\n" + text[end:]


def icon_fallbacks() -> list[Path]:
    """The raster sizes `just install` writes beside the SVG.

    GNOME's shell, the dock and the app grid read icons through GLib's icon
    theme *cache*: one flat file per theme directory, holding only the size
    buckets its `index.theme` lists. A prefix that installs only
    `scalable/apps` has no such bucket, so the launcher draws an empty square,
    while everything that reads the directory directly (an Open With dialog,
    GTK's own lookup) still finds the SVG. These raster copies land in buckets
    the target desktops' caches cover.
    """
    return [
        PREFIX
        / "share"
        / "icons"
        / "hicolor"
        / f"{edge}x{edge}"
        / "apps"
        / f"{APP_ID_PROD}.png"
        for edge in ICON_PIXMAP_SIZES
    ]


def render_metainfo() -> str:
    """The AppStream metadata with its translated strings filled in.

    AppStream localisation is XML (`xml:lang=` on each element), but writing the
    Vietnamese copy by hand next to the English in one file invites the two to
    drift. The translations live in `DESKTOP_LANGUAGES` beside the desktop
    entry's, and this function is the only writer.

    The base file stays the English source (`appstreamcli validate` checks it,
    and a translator reads it there); the generated file is what `just install`
    writes. ElementTree cannot round-trip the comments that explain the file, so
    the insertion is done on the text, after the element's own closing tag.
    """
    text = METAINFO_SOURCE.read_text(encoding="utf-8")
    for language, strings in DESKTOP_LANGUAGES.items():
        text = _localise_element(text, "name", "KogaView", strings["Name"], language)
        text = _localise_element(
            text, "summary", "Browse, view and edit photos", strings["summary"], language
        )
        text = _insert_translated_paragraph(
            text, _xml_escape(strings["description"]), language
        )
    return text


def _xml_escape(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _localise_element(
    text: str, element: str, expected: str, value: str, language: str
) -> str:
    """Copy `<element>expected</element>` as a translated sibling right after it.

    `expected` is what makes the match unique: `<name>` appears twice in the file
    (the component's and the developer's), and only the component's is shown in
    an app centre, so matching on the text keeps the copy in the right place and
    a reworded English source fails here instead of silently duplicating it.
    """
    close = f"</{element}>"
    english = f"<{element}>{expected}{close}"
    if text.count(english) != 1:
        raise SystemExit(
            f"metainfo: expected one <{element}>{expected}</{element}>, "
            f"found {text.count(english)}"
        )
    end = text.index(english) + len(english)
    translated = f'\n  <{element} xml:lang="{language}">{_xml_escape(value)}</{element}>'
    return text[:end] + translated + text[end:]


def _insert_translated_paragraph(text: str, value: str, language: str) -> str:
    """Append a translated `<p>` after the last English paragraph."""
    block_start = text.index("<description>")
    block_end = text.index("</description>", block_start)
    anchor = text.rindex("</p>", block_start, block_end) + len("</p>")
    paragraph = f'\n    <p xml:lang="{language}">{value}</p>'
    return text[:anchor] + paragraph + text[anchor:]


def rasterise_icon(size: int, destination: Path) -> int:
    """Render the SVG icon into `size`×`size` pixels at `destination`.

    PySide6 ships `QSvgRenderer`; a desktop without PySide6 can still install the
    scalable icon, so a missing renderer is reported and the PNG list shrinks
    rather than failing the install.
    """
    try:
        from PySide6.QtCore import Qt  # noqa: F401  (import proves the binding)
        from PySide6.QtGui import QImage, QPainter
        from PySide6.QtSvg import QSvgRenderer
    except ImportError:
        print(
            "install: PySide6 not available; installing only the scalable icon "
            "(the GNOME dock and app grid may draw it blank). "
            "Install `pyside6` or run `just install` on a build machine with it.",
            file=sys.stderr,
        )
        return 1
    image = QImage(size, size, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(0)
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    QSvgRenderer(str(ICON_SOURCE)).render(painter)
    painter.end()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not image.save(str(destination), "PNG"):
        print(f"install: cannot write {destination}", file=sys.stderr)
        return 1
    return 0


def merge_icon_cache(theme_dir: Path) -> None:
    """Let the icon theme cache cover the size buckets this install writes.

    A theme cache is a flat file that can only hold the size buckets its
    `index.theme` lists. GNOME's hicolor default lists no `48x48` bucket, and
    the prefix owns no `index.theme`, so `gtk-update-icon-cache` would either
    refuse or silently record nothing. Adding just the missing `[<bucket>]`
    sections to the prefix's own copy is enough: directories are resolved
    through the theme search path, so the system's `index.theme` still supplies
    the rest. Merging instead of copying keeps a future hicolor update from
    being shadowed by a stale full copy.
    """
    system_index = Path("/usr/share/icons/hicolor/index.theme")
    local_index = theme_dir / "index.theme"
    if not system_index.is_file():
        print(f"install: {system_index} is missing; icon cache not rebuilt", file=sys.stderr)
        return
    text = system_index.read_text(encoding="utf-8")
    missing: list[str] = []
    for edge in ICON_PIXMAP_SIZES:
        if f"\n{edge}x{edge}/apps" in text:
            continue
        section = (
            f"\n[{edge}x{edge}/apps]\n"
            f"Size={edge}\n"
            "Context=Applications\n"
            "Type=Threshold\n"
        )
        text = text.rstrip("\n") + "\n" + section
        missing.append(f"{edge}x{edge}/apps")
    if missing:
        print(f"install: icon cache index gains {', '.join(missing)}")
    staged = RELEASE_DIR / "icons" / "index.theme"
    staged.parent.mkdir(parents=True, exist_ok=True)
    staged.write_text(text, encoding="utf-8")
    result = run(privileged(["install", "-D", "-m644", str(staged), str(local_index)]))
    if result.returncode != 0:
        print(
            f"install: cannot write {local_index}; the icon cache will not cover "
            "the raster sizes",
            file=sys.stderr,
        )


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
    merge_icon_cache(theme_dir)
    if which("gtk-update-icon-cache"):
        # `-f` rewrites the file even if the mtimes look unchanged, and `-t`
        # ignores the directory timestamp check: a cache that is half written is
        # worse than none, because the launcher then draws a blank icon.
        run(privileged(["gtk-update-icon-cache", "-f", "-t", str(theme_dir)]))
    else:
        print(
            f"install: gtk-update-icon-cache is missing; the GNOME dock and app "
            f"grid may draw a blank icon for the cache at {theme_dir}",
            file=sys.stderr,
        )


def forget_icon_caches() -> None:
    """Report the caches a running launcher keeps, so the caller can say what to do.

    GNOME Shell, the dock and GTK app centres resolve an icon once and keep it
    for the session. `gtk-update-icon-cache` rewrites the theme's cache, which is
    the signal they watch, but a *miss* may already have been memoised. The user
    hicolor theme has its own cache and is searched before the prefix, so a
    stale copy there is worth naming instead of silently trusting it.
    """
    user_cache = Path.home() / ".local" / "share" / "icons" / "hicolor" / "icon-theme.cache"
    try:
        stale = user_cache.is_file() and APP_ID_PROD.encode() not in user_cache.read_bytes()
    except OSError:
        return
    if stale:
        print(
            "install: note: "
            f"{user_cache} predates this install and has no {APP_ID_PROD} entry; "
            "launchers that cached a miss may need a session restart to redraw it"
        )


def current_image_handler() -> str:
    return output(["xdg-mime", "query", "default", "image/jpeg"]) or "none"


def install(*, development: bool = False) -> int:
    """Install KogaView under the prefix.

    `development` installs the `dev-prod` binary — the same app ID, the same data
    directories and the same desktop entry as a release install, plus the
    `KOGAVIEW_DEV_*` hooks — so a development build can be driven on the real
    desktop without a second identity. `just install` always builds Release and
    is what a user gets.
    """
    stage = DEVPROD_DIR if development else RELEASE_DIR
    binary = DEVPROD_BINARY if development else RELEASE_BINARY
    result = (build_preset("dev-prod", DEVPROD_BINARY) if development
              else build_release())
    if result != 0:
        return result

    # Everything the install writes is staged under the build directory first,
    # so a failure anywhere below leaves the system untouched.
    rendered = stage / f"{APP_ID_PROD}.desktop"
    rendered.write_text(render_desktop_entry(), encoding="utf-8")
    rendered_metainfo = stage / f"{APP_ID_PROD}.metainfo.xml"
    rendered_metainfo.write_text(render_metainfo(), encoding="utf-8")
    validator = which("desktop-file-validate")
    if validator:
        check = run([validator, str(rendered)])
        if check.returncode != 0:
            print("install: the desktop entry is invalid; nothing was installed", file=sys.stderr)
            return check.returncode
    appstream = which("appstreamcli")
    if appstream:
        check = run([appstream, "validate", "--no-net", str(rendered_metainfo)])
        if check.returncode != 0:
            print(
                "install: the AppStream metadata is invalid; nothing was installed",
                file=sys.stderr,
            )
            return check.returncode

    # The raster fallbacks come from the one SVG, rendered here rather than
    # committed, so the icon cannot fork into two drawings.
    rendered_pixmaps: list[Path] = []
    for edge in ICON_PIXMAP_SIZES:
        staged = stage / "icons" / f"{edge}x{edge}" / f"{APP_ID_PROD}.png"
        if rasterise_icon(edge, staged) != 0:
            break
        rendered_pixmaps.append(staged)

    targets = installed_files()
    sources = {
        "binary": (binary, "755"),
        "desktop entry": (rendered, "644"),
        "icon": (ICON_SOURCE, "644"),
        "AppStream metadata": (rendered_metainfo, "644"),
    }
    for index, staged in enumerate(rendered_pixmaps):
        sources[f"icon {ICON_PIXMAP_SIZES[index]}"] = (staged, "644")

    handler_before = current_image_handler()
    for name in list(targets):
        if name not in sources:
            # A raster size the staging step could not produce (no PySide6).
            del targets[name]
            continue
        source, mode = sources[name]
        result = run(privileged(["install", "-D", f"-m{mode}", str(source), str(targets[name])]))
        if result.returncode != 0:
            print(f"install: cannot write {targets[name]}; stopping here", file=sys.stderr)
            return result.returncode

    refresh_desktop_caches()
    forget_icon_caches()

    flavour = ("development build (RelWithDebInfo, KOGAVIEW_DEV_* hooks, "
               "production identity)" if development
               else "release build")
    print(f"install: {PROJECT} {APP_ID_PROD} installed under {PREFIX} — {flavour}")
    for name, target in targets.items():
        print(f"  {name:18} {target}")
    print(f"  image viewer group  Categories={desktop_categories()}")
    print(f"  interface names     {desktop_languages_summary()}")
    print(
        "  default handler     unchanged: image/jpeg opens with "
        f"'{handler_before}'. KogaView is offered in Open With; make it the "
        "default yourself with `xdg-mime default "
        f"{APP_ID_PROD}.desktop image/jpeg`."
    )
    print(f"  remove it with      just uninstall")
    return 0


def desktop_languages_summary() -> str:
    """Which languages the desktop entry and AppStream file carry a name in."""
    languages = ["en"] + list(DESKTOP_LANGUAGES)
    return ", ".join(languages) + f" ({len(languages)} locales)"


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

    # The merged `index.theme` is derived, not a user file: leaving it behind
    # would keep advertising size buckets with no icons in them.
    index = PREFIX / "share" / "icons" / "hicolor" / "index.theme"
    if index.is_file():
        run(privileged(["rm", "-f", str(index)]))

    refresh_desktop_caches()
    forget_icon_caches()
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
    "state|settings|editor|language|toolbar]"
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
    if command == "install-dev":
        return install(development=True)
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
