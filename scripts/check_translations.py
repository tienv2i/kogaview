#!/usr/bin/env python3
"""Keep the compiled-in translation table and the `.ts` catalogue in agreement.

There are two copies of every translated string in this tree and neither can be
derived from the other at build time:

* `i18n/kogaview_vi.ts` is what `lrelease` compiles into `:/i18n/` for the QML
  bindings (`qsTr`), which is where the interface text is drawn.
* `cpp/translations.cpp` is a plain C++ table, because `PlatformHelper` spells
  some strings itself (the file-dialog name filters) before any translator is
  installed, and `QCoreApplication::translate` would answer with the source text
  there.

The table is a *subset*: it carries only the strings C++ needs, and the rest
live in the `.ts` alone. What is not allowed is the two disagreeing, which is
silent — a menu says "Sao chép tới…" while the dialog says "Sao chép đến…", and
nothing fails. This script fails that case, plus an unfinished or empty
translation in the catalogue, plus a table entry whose source text is gone.

    python3 scripts/check_translations.py            # check
    python3 scripts/check_translations.py --list     # print the drift only

`just test` runs it before the suites; a build without the check is a build that
cannot tell whether its own strings agree.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TS_PATH = ROOT / "i18n" / "kogaview_vi.ts"
TABLE_PATH = ROOT / "cpp" / "translations.cpp"

# `<message>` blocks, with the source and translation of each. `lupdate` writes
# them in this order, but the check must not depend on it.
MESSAGE = re.compile(
    r"<message>(?P<body>.*?)</message>", re.S
)
SOURCE = re.compile(r"<source>(?P<text>.*?)</source>", re.S)
TRANSLATION = re.compile(
    r"<translation(?P<attrs>[^>]*)>(?P<text>.*?)</translation>", re.S
)
# One row of the C++ table: { "source", "translation" },
ENTRY = re.compile(r'\{\s*"(?P<source>(?:[^"\\]|\\.)*)"\s*,\s*"(?P<translation>(?:[^"\\]|\\.)*)"\s*\}')

UNESCAPE = {"\\": "\\", '"': '"', "n": "\n", "t": "\t"}


def unescape_cpp(text: str) -> str:
    out = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text):
            index += 1
            out.append(UNESCAPE.get(text[index], text[index]))
        else:
            out.append(char)
        index += 1
    return "".join(out)


def unescape_xml(text: str) -> str:
    return (
        text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&apos;", "'")
        .replace("&amp;", "&")
    )


def catalogue() -> tuple[dict[str, str], list[str], list[str]]:
    """The `.ts` as {source: translation}, plus unfinished and empty sources."""
    text = TS_PATH.read_text(encoding="utf-8")
    translations: dict[str, str] = {}
    unfinished: list[str] = []
    empty: list[str] = []
    for match in MESSAGE.finditer(text):
        body = match.group("body")
        source = SOURCE.search(body)
        translation = TRANSLATION.search(body)
        if source is None or translation is None:
            continue
        key = unescape_xml(source.group("text"))
        value = unescape_xml(translation.group("text"))
        if "unfinished" in translation.group("attrs"):
            unfinished.append(key)
        elif not value.strip():
            empty.append(key)
        # The same English text appears in several contexts (a menu in `Main`,
        # the same item in `BrowserView`); every copy must say the same thing.
        if key in translations and translations[key] != value:
            empty.append(f"{key} (contexts disagree)")
        translations.setdefault(key, value)
    return translations, unfinished, empty


def table() -> list[tuple[str, str]]:
    """Every row of the C++ table, in file order.

    A list, not a dict: the table repeats a source once per context (the same
    menu entry is spelled for the Browser and for the Viewer), and collapsing
    those would let one row disagree with the other without failing.
    """
    text = TABLE_PATH.read_text(encoding="utf-8")
    return [
        (
            unescape_cpp(match.group("source")),
            unescape_cpp(match.group("translation")),
        )
        for match in ENTRY.finditer(text)
    ]


def main(argv: list[str]) -> int:
    list_only = "--list" in argv
    if not TS_PATH.is_file():
        print(f"translations: missing {TS_PATH}", file=sys.stderr)
        return 1
    if not TABLE_PATH.is_file():
        print(f"translations: missing {TABLE_PATH}", file=sys.stderr)
        return 1

    strings, unfinished, empty = catalogue()
    compiled = table()
    problems: list[str] = []

    for source in sorted(unfinished):
        problems.append(f'unfinished translation in the .ts: "{source}"')
    for source in sorted(empty):
        problems.append(f'empty or contradictory translation in the .ts: "{source}"')
    for source, translation in compiled:
        if source not in strings:
            problems.append(
                f'cpp/translations.cpp translates "{source}", which the .ts no longer has'
            )
        elif strings[source] != translation:
            problems.append(
                f'"{source}" disagrees: .ts says "{strings[source]}", '
                f'cpp/translations.cpp says "{translation}"'
            )
    rows: dict[str, str] = {}
    for source, translation in compiled:
        if source in rows and rows[source] != translation:
            problems.append(
                f'cpp/translations.cpp translates "{source}" two ways: '
                f'"{rows[source]}" and "{translation}"'
            )
        rows.setdefault(source, translation)

    if list_only or not problems:
        print(
            f"translations: {len(strings)} strings in {TS_PATH.name}, "
            f"{len({source for source, _ in compiled})} of them compiled into C++"
        )
    if problems:
        print(f"translations: {len(problems)} problem(s)", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "translations: edit i18n/kogaview_vi.ts, then run "
            "`lupdate i18n/kogaview_ts.pro` from the repository root",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
