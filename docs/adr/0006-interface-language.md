# ADR 0006 — Interface language: English source text, Vietnamese catalogue, switchable while open

- Status: accepted
- Date: 2026-11-16

## Context

The owner asked for English and Vietnamese, prepared now and selectable in the
settings dialog. The constraints that shape it:

- Core is Qt-free, so Core cannot call `tr()`. Core does own the status line and
  some user-visible text today.
- Flatpak readiness: the catalogue must travel inside the binary, not be read
  from `/usr/share`.
- QML is embedded at build time; the `.qm` files have to be produced by the same
  build (`lrelease`) and registered where a translator looks.
- A language change has to work while the window is open, without a restart.

## Decision

- **English is the source language.** Every string is written in English in the
  QML (`qsTr("…")`) and the Vietnamese catalogue translates it. A missing entry
  degrades to English, which is a supported state, not an error.
- **`Language` is protocol state**: `system | en | vi` in
  `kogaview-protocol`, set by `set_language {locale}` and by
  `set_settings {language}`. It is published in `AppState` like the theme, so it
  is journaled, revisioned and identical for every front end.
- **The catalogue is a resource of its own.** `lrelease` turns
  `i18n/kogaview_vi.ts` into `kogaview_vi.qm`; CMake writes a small `.qrc`
  index (Qt 6's `rcc` refuses a bare `.qm` argument) and runs `rcc --binary` into
  `build/dev/i18n/kogaview_translations.rcc`, whose path is passed to
  `cpp/language.cpp` as `KOGAVIEW_TRANSLATIONS_RCC`.
  `InterfaceLanguage` registers it at `:/i18n/` — the prefix the QTranslator
  searches — instead of leaving it under the QML module's `/qt/qml`, where no
  translator looks.
- **`QQmlEngine::retranslate()` is the switch.** `installTranslator` posts a
  `LanguageChange` event that reaches widgets, not a QML engine: the first
  attempt translated the translator's own strings and left every label English.
  `InterfaceLanguage::apply()` installs the translators, asks the bridge for a
  fresh snapshot, then retranslates the engine, which re-runs every binding that
  read a translated string.
- **`Main.qml` drives it, not C++.** CXX-Qt declares the bridge's notifier
  signals private (`QObject::connect` to `stateJsonChanged` returns false), so
  the QML side watches `bridge.language` and the published snapshot and calls
  the `LanguageInstaller` context property (`InterfaceLanguage`). The property
  is named `LanguageInstaller` because `QtQuick.Window`'s own `Language` enum
  shadows a context property called `Language`.
- **Menus are measured in the current language.** `Theme.menuEntryLabels` holds
  the labels inside `qsTr(…)` — a loop over variables is invisible to `lupdate`,
  which is why the menus stayed English through the first translation pass —
  and `Main.qml` re-measures them with `Platform.textWidths` when the language
  changes, because a menu has to fit what it draws.
- **C++ keeps a small table of its own.** `PlatformHelper` spells some strings
  itself (file-dialog name filters) before any translator is installed, so
  `cpp/translations.cpp` carries the subset C++ needs. `scripts/check_translations.py`
  fails `just test` when that table and the `.ts` disagree or when a catalogue
  entry is unfinished.
- **Qt's own strings are not relied on.** `qtbase_<locale>.qm` is the system's
  file — this machine ships 33 `qtbase_*` catalogues and none for `vi` — so the
  app's dialogs use explicit `qsTr` buttons ("Huỷ", "Lưu", "Tạo") instead of
  `standardButtons`, which would draw English inside a Vietnamese window.

## Consequences

- A new language is a `.ts` file plus one line in `PlatformHelper::languages()`
  and the `Language` enum; no C++ string changes.
- **Core-authored text is still English.** The status line ("Ready", "Editing
  photo-1.jpg · 2400 × 1600", "7 items · 6 images") is built in Core with
  `format!`, and Core cannot translate. Making it translatable means publishing
  a *status code plus arguments* and translating at the presentation edge — a
  protocol change that this milestone does not make, recorded here so it is a
  known gap rather than an oversight. Folder names ("Pictures") are filesystem
  names and are correctly left alone.
- The binary carries the catalogue; a language pack cannot be added by dropping
  a file next to the executable, by design.
