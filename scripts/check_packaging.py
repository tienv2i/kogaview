#!/usr/bin/env python3
"""Check the Linux desktop assets before they are installed.

`just install` writes four things into the prefix: the binary, a desktop entry,
an icon and AppStream metadata. Three of those carry claims that can drift away
from the code without anything failing:

* `MimeType=` names the file types the launcher offers KogaView for. It has to
  agree with `kogaview_protocol::IMAGE_EXTENSIONS` *and* with the decoders the
  build actually enables (ADR 0005) — offering a file the app cannot open is a
  worse bug than not listing it.
* `Categories=` decides where the app appears in the desktop's menu. The owner
  asked for the image-viewer group, which is `Graphics;Viewer;`.
* The AppStream `id`, the desktop file name, the icon file name and `Icon=` all
  have to be the same string, or the app centre cannot pair them.

The check reads `shared-mime-info`'s glob table for the MIME names instead of
trusting a second hand-written list, renders the desktop template the way
`just install` does, and runs `desktop-file-validate` / `appstreamcli validate`
when those tools are installed.

    python3 scripts/check_packaging.py
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev  # noqa: E402  (the module owns the paths and the renderer)

ROOT = dev.ROOT
PROTOCOL_SOURCE = ROOT / "crates" / "app-protocol" / "src" / "lib.rs"
MIME_GLOBS = Path("/usr/share/mime/globs2")

# Listed by the browser so such files are visible and selectable, but with no
# decoder behind them: the desktop entry must not claim them (ADR 0005).
UNDECODABLE = {"heic", "heif"}

EXTENSIONS = re.compile(
    r"pub const IMAGE_EXTENSIONS: &\[&str\] = &\[(?P<body>.*?)\];", re.S
)
QUOTED = re.compile(r'"([^"]+)"')


def advertised_extensions() -> list[str]:
    """`IMAGE_EXTENSIONS` from the protocol crate — the one list the browser,
    the file dialog and the save filters all read."""
    match = EXTENSIONS.search(PROTOCOL_SOURCE.read_text(encoding="utf-8"))
    if match is None:
        raise SystemExit("packaging: cannot find IMAGE_EXTENSIONS in the protocol crate")
    return QUOTED.findall(match.group("body"))


def mime_globs() -> dict[str, set[str]]:
    """`{mime: {"*.jpg", …}}` from shared-mime-info.

    A missing table is not a failure: a machine without shared-mime-info cannot
    install a desktop entry that resolves anyway. The check then skips the
    glob comparison and says so.
    """
    table: dict[str, set[str]] = {}
    if not MIME_GLOBS.is_file():
        return table
    for line in MIME_GLOBS.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("#") or not line:
            continue
        parts = line.split(":")
        if len(parts) < 3:
            continue
        mime, glob = parts[1], parts[2]
        table.setdefault(mime, set()).add(glob)
    return table


def desktop_entry(text: str) -> dict[str, str]:
    """The `Key=Value` pairs of a desktop entry, ignoring comments and groups."""
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line or line.startswith("#") or line.startswith("["):
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def validate_with(tool: str, path: Path, extra: list[str]) -> list[str]:
    if dev.which(tool) is None:
        return []
    result = dev.subprocess.run(
        [tool, *extra, str(path)], capture_output=True, text=True, check=False
    )
    if result.returncode == 0:
        return []
    return [f"{tool} rejected {path.name}:\n{result.stdout}{result.stderr}".strip()]


def metainfo_text() -> str:
    """The AppStream file `just install` writes, translations included."""
    return dev.render_metainfo()


def main() -> int:
    problems: list[str] = []
    extensions = advertised_extensions()
    globs = mime_globs()

    entry_text = dev.render_desktop_entry()
    entry = desktop_entry(entry_text)
    claimed = [mime for mime in entry.get("MimeType", "").split(";") if mime]

    # 1. Every codec the app opens is offered, and nothing it cannot open is.
    for extension in extensions:
        if extension in UNDECODABLE:
            continue
        if globs:
            candidates = {
                mime for mime, patterns in globs.items() if f"*.{extension}" in patterns
            }
            if not candidates:
                problems.append(
                    f'no MIME type in shared-mime-info covers ".{extension}"'
                )
                continue
            if not candidates & set(claimed):
                problems.append(
                    f'".{extension}" is a supported codec but no MIME type in '
                    f"MimeType= covers it (expected one of {sorted(candidates)})"
                )
        elif not any(f"*.{extension}" in globs.get(mime, set()) for mime in claimed):
            # Without the glob table only the listed names can be checked.
            pass

    for mime in claimed:
        if globs and mime not in globs:
            problems.append(
                f'MimeType= names "{mime}", which shared-mime-info does not know'
            )
            continue
        if globs:
            covered = {
                pattern.lstrip("*.")
                for pattern in globs.get(mime, set())
                if pattern.startswith("*.")
            }
            if not covered & {ext for ext in extensions if ext not in UNDECODABLE}:
                problems.append(
                    f'MimeType= names "{mime}", which no supported extension uses'
                )

    # 2. The menu group the owner asked for.
    categories = {name for name in entry.get("Categories", "").split(";") if name}
    for required in ("Graphics", "Viewer"):
        if required not in categories:
            problems.append(f'Categories= is missing "{required}" (image viewer group)')

    # 3. One identity across entry, icon, metainfo and AppStream.
    if entry.get("Icon") != dev.APP_ID_PROD:
        problems.append(f'Icon= is "{entry.get("Icon")}", expected {dev.APP_ID_PROD}')
    icon = dev.ICON_SOURCE
    if not icon.is_file():
        problems.append(f"icon asset missing: {icon.relative_to(ROOT)}")
    elif icon.stem != dev.APP_ID_PROD:
        problems.append(f"icon file {icon.name} is not named after the app ID")
    if not dev.DESKTOP_TEMPLATE.name.startswith(dev.APP_ID_PROD):
        problems.append("desktop template is not named after the app ID")

    metainfo = dev.METAINFO_SOURCE
    if not metainfo.is_file():
        problems.append(f"AppStream metadata missing: {metainfo.relative_to(ROOT)}")
    else:
        text = metainfo.read_text(encoding="utf-8")
        if f"<id>{dev.APP_ID_PROD}</id>" not in text:
            problems.append(f"metainfo <id> is not {dev.APP_ID_PROD}")
        if f"<launchable type=\"desktop-id\">{dev.APP_ID_PROD}.desktop</launchable>" not in text:
            problems.append(
                "metainfo <launchable> does not name the installed desktop entry"
            )
        if metainfo.name != f"{dev.APP_ID_PROD}.metainfo.xml":
            problems.append("metainfo file is not named after the app ID")

    # 4. The launcher's command line has to be the multi-file one.
    exec_line = entry.get("Exec", "")
    if not exec_line.endswith("/kogaview open %F"):
        problems.append(f'Exec= is "{exec_line}", expected …/kogaview open %F')
    if entry.get("TryExec", "") != f"{dev.PREFIX}/bin/kogaview":
        problems.append(f'TryExec= is "{entry.get("TryExec")}", expected the prefix binary')
    if entry.get("Terminal") != "false":
        problems.append("Terminal= must be false for a windowed app")

    # 5. Every launch-surface language is present where the desktop reads it.
    #    A catalogue string and a desktop key are two different files, so a
    #    language added to one and forgotten in the other shows up as an English
    #    launcher inside a Vietnamese window.
    for language, strings in dev.DESKTOP_LANGUAGES.items():
        for key in ("Name", "GenericName", "Comment", "Keywords"):
            value = entry.get(f"{key}[{language}]")
            if not value:
                problems.append(f'desktop entry has no {key}[{language}]=')
            elif value != strings[key]:
                problems.append(
                    f'{key}[{language}]= is "{value}", expected "{strings[key]}" '
                    "from DESKTOP_LANGUAGES"
                )
        if f'xml:lang="{language}"' not in metainfo_text():
            problems.append(f"AppStream metadata carries no {language} translation")

    # 6. The icon is installed in size buckets the launcher's cache can hold, and
    #    the SVG is still there for the sizes above them.
    fallbacks = dev.icon_fallbacks()
    if not fallbacks:
        problems.append("no raster icon sizes are installed; the GNOME dock may draw blank")
    for path in fallbacks:
        if path.parent.name != "apps" or path.stem != dev.APP_ID_PROD:
            problems.append(f"raster icon {path} is not named after the app ID in apps/")

    # 7. The tools the desktop itself uses, on the rendered file.
    with tempfile.TemporaryDirectory() as scratch:
        rendered = Path(scratch) / f"{dev.APP_ID_PROD}.desktop"
        rendered.write_text(entry_text, encoding="utf-8")
        problems += validate_with("desktop-file-validate", rendered, [])
        if metainfo.is_file():
            problems += validate_with(
                "appstreamcli", metainfo, ["validate", "--no-net", "--explain"]
            )

    if problems:
        print(f"packaging: {len(problems)} problem(s)", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(
        f"packaging: {len(claimed)} MIME types, {len(categories)} categories, "
        f"icon and metainfo named {dev.APP_ID_PROD}"
        + ("" if globs else " (no shared-mime-info: globs not compared)")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
