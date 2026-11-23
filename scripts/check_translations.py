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
* `crates/desktop/qml/UiLines.qml` is the only place a Core line becomes a
  sentence. Core publishes `UiText { code, args }`, so a code with no `case` in
  that file would show the user a raw identifier — this script fails it.

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
CONTEXT = re.compile(r"<context>\s*<name>(?P<name>[^<]+)</name>(?P<body>.*?)</context>", re.S)
TRANSLATION = re.compile(
    r"<translation(?P<attrs>[^>]*)>(?P<text>.*?)</translation>", re.S
)
# One row of the C++ table: { "source", "translation" },
ENTRY = re.compile(r'\{\s*"(?P<source>(?:[^"\\]|\\.)*)"\s*,\s*"(?P<translation>(?:[^"\\]|\\.)*)"\s*\}')

# The translatable strings the QML draws: `qsTr("…")`. The argument is captured
# as a run of literal characters and `\` escapes, so a concatenated call
# (`qsTr("a" + b`) stops at the closing quote of its first literal rather than
# swallowing the file, which is the failure a careless regex gives here.
QML_TR = re.compile(r'qsTr\(\s*"(?P<text>(?:[^"\\\n]|\\.)*)"')
# `qsTranslate("Context", "source")` — the explicit-context form. Both halves are
# checked: a context the catalogue does not have would make Qt answer with the
# source text, which is how a measurement silently degrades to English.
QML_QSTRANSLATE = re.compile(
    r'qsTranslate\(\s*"(?P<context>(?:[^"\\\n]|\\.)*)"\s*,\s*"(?P<text>(?:[^"\\\n]|\\.)*)"'
)
QML_ESCAPE = {"\\": "\\", '"': '"', "'": "'", "n": "\n", "t": "\t", "r": "\r"}
QML_DIR = ROOT / "crates" / "desktop" / "qml"
# The `lupdate` project. It is the list of files the catalogue is built from.
TS_PRO = ROOT / "i18n" / "kogaview_ts.pro"

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


def catalogue() -> tuple[dict[str, str], dict[str, set[str]], list[str], list[str]]:
    """The `.ts` as {source: translation}, {context: {sources}}, unfinished, empty."""
    text = TS_PATH.read_text(encoding="utf-8")
    translations: dict[str, str] = {}
    by_context: dict[str, set[str]] = {}
    unfinished: list[str] = []
    empty: list[str] = []
    for context_match in CONTEXT.finditer(text):
        context = context_match.group("name")
        for match in MESSAGE.finditer(context_match.group("body")):
            body = match.group("body")
            source = SOURCE.search(body)
            translation = TRANSLATION.search(body)
            if source is None or translation is None:
                continue
            key = unescape_xml(source.group("text"))
            value = unescape_xml(translation.group("text"))
            by_context.setdefault(context, set()).add(key)
            if "unfinished" in translation.group("attrs"):
                unfinished.append(key)
            elif not value.strip():
                empty.append(key)
            # The same English text appears in several contexts (a menu in
            # `Main`, the same item in `BrowserView`); every copy must say the
            # same thing.
            if key in translations and translations[key] != value:
                empty.append(f"{key} (contexts disagree)")
            translations.setdefault(key, value)
    return translations, by_context, unfinished, empty


def strip_comments(text: str) -> str:
    """Remove `//` and `/* */` comments, leaving string literals alone.

    A comment that mentions `qsTr(...)` in prose must not be counted — and, the
    other way round, a string inside a comment must not be able to *satisfy* the
    check for a missing one. The scan is simple because QML comments are: it
    tracks whether the current character is inside a `"…"` literal, and only
    then is a `//` a comment rather than the middle of a URL.
    """
    out: list[str] = []
    index = 0
    in_string = False
    in_block = False
    while index < len(text):
        char = text[index]
        pair = text[index : index + 2]
        if in_block:
            if pair == "*/":
                in_block = False
                index += 2
            else:
                # Keep newlines so reported positions stay meaningful.
                out.append("\n" if char == "\n" else " ")
                index += 1
            continue
        if in_string:
            out.append(char)
            if char == "\\" and index + 1 < len(text):
                out.append(text[index + 1])
                index += 2
                continue
            if char == '"':
                in_string = False
            index += 1
            continue
        if pair == "//":
            end = text.find("\n", index)
            if end < 0:
                break
            index = end
            continue
        if pair == "/*":
            in_block = True
            out.append("  ")
            index += 2
            continue
        if char == '"':
            in_string = True
        out.append(char)
        index += 1
    return "".join(out)


def qml_strings() -> tuple[dict[str, list[str]], list[tuple[str, str, str]]]:
    """What the QML asks for: `({source: [files]}, [(context, source, file)]).

    `lupdate` would produce these from the `.pro`, but it is a Qt tool the build
    may not have, and the gate must not depend on it: a new `qsTr()` that never
    reached the catalogue is exactly the case this check exists to catch. The
    one that got away — the small-picture hint, `Small image shown at 100 % …` —
    was in the QML, absent from the `.ts`, and drew English in a Vietnamese
    window while every other check passed.

    `qsTranslate` is reported separately because its context matters as much as
    its text: the catalogue is keyed by context, so `qsTranslate("A", "x")` with
    no `A` context returns the untranslated `x`.
    """
    found: dict[str, list[str]] = {}
    translated: list[tuple[str, str, str]] = []
    for path in sorted(QML_DIR.glob("*.qml")):
        # Test fixtures live in the same directory so their local types resolve
        # as siblings, but they are not part of the interface.
        if path.name.startswith("tst_"):
            continue
        text = strip_comments(path.read_text(encoding="utf-8"))
        for match in QML_TR.finditer(text):
            literal = match.group("text")
            source = re.sub(
                r"\\(.)",
                lambda m: QML_ESCAPE.get(m.group(1), m.group(1)),
                literal,
            )
            found.setdefault(source, []).append(path.name)
        for match in QML_QSTRANSLATE.finditer(text):
            context = re.sub(
                r"\\(.)", lambda m: QML_ESCAPE.get(m.group(1), m.group(1)), match.group("context")
            )
            source = re.sub(
                r"\\(.)", lambda m: QML_ESCAPE.get(m.group(1), m.group(1)), match.group("text")
            )
            translated.append((context, source, path.name))
    return found, translated


def pro_sources() -> set[str]:
    """The QML files the `lupdate` project names, by basename.

    `lupdate` only reads the files this list names, and the failure is silent in
    both directions: a file that draws a translated string but is missing here
    is never extracted, and the *next* `lupdate` marks the entries that file
    already had `vanished` — which `lrelease` drops without a word. That is how
    `UiLines.qml` came to hold the only copy of thirty status sentences while
    the catalogue still believed they had no source.
    """
    text = TS_PRO.read_text(encoding="utf-8")
    # Comments out, then the backslash continuations of `SOURCES = …` joined.
    text = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    text = text.replace("\\\n", " ")
    match = re.search(r"^SOURCES\s*=\s*(?P<body>.*)$", text, re.M)
    if match is None:
        return set()
    return {entry.rsplit("/", 1)[-1] for entry in match.group("body").split()}


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


# Every Rust source that can publish a line: Core's gateway and handlers, and the
# Editor's own crate, which the split in `docs/adr/0023` moved out of `app-core`.
CORE_DIRS = (
    ROOT / "crates" / "app-core" / "src",
    ROOT / "crates" / "app-editor" / "src",
)
UI_LINES = QML_DIR / "UiLines.qml"

# `UiText::new("code")` and `UiText::with("code", …)`, including the form that
# wraps onto the next line (rustfmt does when the argument list is long).
CORE_CODE = re.compile(r'UiText::(?:new|with)\(\s*"(?P<code>[a-z_]+)"')
# The line table's cases. A case is expected to draw a `qsTr`.
QML_CASE = re.compile(r'case\s+"(?P<code>[^"]*)":\s*(?:return\s+(?P<body>[^;]*);)?')


def core_codes() -> tuple[set[str], set[str]]:
    """The codes Core can publish, and the codes `UiLines.qml` draws.

    Both are read from the sources rather than from a list here: a code added to
    Core and forgotten in the QML would reach the status bar as an identifier,
    and a case whose code Core no longer publishes is dead weight that no
    reviewer notices.
    """
    published: set[str] = set()
    for directory in CORE_DIRS:
        for path in sorted(directory.glob("*.rs")):
            # The Editor's suite is a file of its own, and its fixtures build
            # lines of their own too; neither is something a window can show.
            if path.name == "tests.rs":
                continue
            text = path.read_text(encoding="utf-8")
            # Test modules build lines of their own (`selected`, `cancelled`);
            # they are not part of what Core can publish to the window. The test
            # module is the last item in the file, so its `#[cfg(test)]` is at
            # column 0 — the two indented ones inside `Core` gate test-only
            # helpers.
            test_module = text.find("\n#[cfg(test)]\n")
            if test_module != -1:
                text = text[:test_module]
            for match in CORE_CODE.finditer(text):
                published.add(match.group("code"))
    drawn: set[str] = set()
    for match in QML_CASE.finditer(UI_LINES.read_text(encoding="utf-8")):
        drawn.add(match.group("code"))
    return published, drawn


def main(argv: list[str]) -> int:
    list_only = "--list" in argv
    if not TS_PATH.is_file():
        print(f"translations: missing {TS_PATH}", file=sys.stderr)
        return 1
    if not TABLE_PATH.is_file():
        print(f"translations: missing {TABLE_PATH}", file=sys.stderr)
        return 1

    strings, by_context, unfinished, empty = catalogue()
    compiled = table()
    problems: list[str] = []

    # Every string the interface draws must be in the catalogue. This runs
    # before the table check so a missing entry is reported once, by file.
    drawn, translated = qml_strings()
    for source in sorted(drawn):
        if source not in strings:
            where = ", ".join(sorted(set(drawn[source])))
            problems.append(
                f'qsTr("{source}") in {where} is not in kogaview_vi.ts — '
                "add it there (or run `lupdate i18n/kogaview_ts.pro`)"
            )
    # `qsTranslate` has to name a context the catalogue really has: with a wrong
    # or stale context Qt answers with the source text, so the caller silently
    # measures (or draws) English while every other check passes.
    for context, source, file in sorted(translated):
        if context not in by_context:
            problems.append(
                f'qsTranslate("{context}", "{source}") in {file}: '
                f"the .ts has no context {context!r}"
            )
        elif source not in by_context[context]:
            problems.append(
                f'qsTranslate("{context}", "{source}") in {file}: '
                f"context {context!r} has no source {source!r}"
            )

    # Every file that draws a string has to be in the `lupdate` project, or the
    # catalogue will never be built from it.
    listed = pro_sources()
    drawing = {name for names in drawn.values() for name in names}
    drawing |= {file for _, _, file in translated}
    for name in sorted(drawing - listed):
        problems.append(
            f"{name} draws a translated string but i18n/kogaview_ts.pro does "
            "not list it — add it to SOURCES, or `lupdate` will never extract "
            "the string and will drop the ones it already has"
        )
    for name in sorted(listed - {path.name for path in QML_DIR.glob("*.qml")}):
        problems.append(
            f"i18n/kogaview_ts.pro lists {name}, which is not a file in "
            "crates/desktop/qml"
        )

    # Every line Core publishes has to have a sentence. The empty code is the
    # "hide the status bar" line and is handled in the table like the rest.
    published, drawn_codes = core_codes()
    for code in sorted(published - drawn_codes):
        problems.append(
            f'Core publishes the line "{code}", which UiLines.qml does not draw '
            "— add a case with a qsTr for it"
        )
    for code in sorted(drawn_codes - published - {""}):
        problems.append(
            f'UiLines.qml draws the line "{code}", which no Core UiText publishes '
            "— remove the dead case"
        )

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
            f"{len({source for source, _ in compiled})} of them compiled into C++, "
            f"{len(drawn)} drawn by the QML, "
            f"{len(translated)} looked up by context"
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
