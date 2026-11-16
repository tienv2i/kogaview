// Translations compiled into the binary.
//
// The Qt side (`PlatformHelper`) translates its file-dialog labels without a
// `QTranslator`, so the catalogue has to be reachable from plain C++ the same
// way the QML strings reach Qt: as data in the executable. The source of truth
// is `i18n/kogaview_vi.ts`; `scripts/check_translations.py` fails the build when
// this table and that file drift apart, so the two cannot quietly disagree.
//
// An entry whose translation equals its source is left out and falls back to
// the English literal, which is what Qt does for an untranslated message.

#pragma once

#include <QString>

namespace kogaview::i18n {

struct Entry
{
  const char* source;
  const char* translation;
};

struct Catalogue
{
  const char* locale;
  /// Null-terminated: the last entry has a null `source`.
  const Entry* entries;
};


/// Every compiled catalogue, in the order the language picker lists them.
const Catalogue* const* catalogues();

/// The catalogue for `locale` (`vi`, `vi_VN`, …), or nullptr.
const Catalogue* catalogue(const QString& locale);

/// The translation of `source` in `locale`, or `source` itself. Same contract as
/// `QCoreApplication::translate`, including an empty result for an empty source.
QString translate(const QString& locale, const char* source);

} // namespace kogaview::i18n

// The tables live in one translation unit; the header only declares them.
