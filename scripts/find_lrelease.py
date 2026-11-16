#!/usr/bin/env python3
"""Print the first Qt Linguist `lrelease` found, for CMake to run.

`lrelease` ships with Qt's *tools* package, which is not always installed even
when Qt itself is (this machine: qt6-base provides Qt6 but no lrelease; a
PySide6 wheel does). The build must not depend on a particular distribution
layout, so this looks at the conventional places, a few explicit overrides and
finally `PATH`, and fails with a message that says how to supply one.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def candidates() -> list[Path]:
    """Paths to try, in priority order. Explicit overrides first, then the
    distribution's Qt tools, then a bundled PySide6, then `PATH`."""
    found: list[Path] = []
    for variable, tool in (("LRELEASE", "lrelease"), ("LUPDATE", "lrelease")):
        # lupdate and lrelease ship together; pointing at one points at the bin
        # directory the other lives in.
        override = os.environ.get(variable)
        if override:
            found.append(Path(override).with_name(tool))
    for root in (
        Path("/usr/lib/qt6"),
        Path("/usr/lib/qt"),
        Path("/usr/local/lib/qt6"),
        Path("/opt/qt6"),
    ):
        found.append(root / "bin" / "lrelease")
        found.append(root / "lrelease")
    # PySide6 wheels bundle the tool next to the Python bindings.
    for library in Path("/usr/lib").glob("python3*/site-packages/PySide6"):
        found.append(library / "lrelease")
    for prefix in dict.fromkeys((Path(sys.prefix), Path(sys.base_prefix))):
        libraries = prefix / "lib"
        if libraries.is_dir():
            found.extend(libraries.glob("python*/site-packages/PySide6/lrelease"))
    # A PySide6 installation reachable from this interpreter carries the tool
    # (this machine: a project venv's `PySide6` has it, the system one does not).
    import importlib.util

    spec = importlib.util.find_spec("PySide6")
    if spec is not None and spec.origin:
        found.append(Path(spec.origin).parent / "lrelease")
    for name in ("lrelease", "lrelease-qt6"):
        on_path = shutil.which(name)
        if on_path:
            found.append(Path(on_path))
    return found


def main() -> int:
    options = candidates()
    if os.environ.get("KOGAVIEW_LRELEASE"):
        options.insert(0, Path(os.environ["KOGAVIEW_LRELEASE"]))
    for candidate in options:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            print(candidate)
            return 0
    print(
        "lrelease not found: install the Qt Linguist tools (e.g. `qt6-tools`), "
        "or point LRELEASE at the binary",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
