// Installing the interface language, live.
//
// Qt has no cross-process way to change a translator once a window is drawn: a
// `QTranslator` swap only matters after `QEvent::LanguageChange` reaches the
// engine, and every binding that reads a translated string has to re-run. This
// object owns that sequence so it is testable and has one owner:
//
//  - the shell calls `apply()` on the first snapshot (the stored language);
//  - `Main.qml` calls `apply()` again from `onLanguageChanged`, because QML can
//    see the bridge's notifier while C++ cannot (CXX-Qt declares those signals
//    private), and calls `reapply()` after every command, so a `set_language`
//    that lands in a snapshot without a property change is not missed.
//
// The translations themselves are `:/i18n/kogaview_<locale>.qm` (built from
// `i18n/kogaview_vi.ts`) plus Qt's own `qtbase_<locale>.qm`.

#pragma once

#include <QObject>
#include <QPointer>
#include <QString>
#include <QTranslator>

class QQmlEngine;

class InterfaceLanguage : public QObject
{
  Q_OBJECT
public:
  InterfaceLanguage(QQmlEngine* engine, QObject* rootObject, QString requestedOverride,
                    QObject* parent = nullptr);

  /// The locale the interface is in now (`vi`), or empty for the desktop's own
  /// language, whose strings are the English source text. A property, not a
  /// getter alone: QML reads `LanguageInstaller.locale`.
  Q_PROPERTY(QString locale READ locale NOTIFY localeChanged)
  QString locale() const { return m_current; }
signals:
  void localeChanged();

public slots:
  /// Install `locale` (`system` or empty = none). A no-op when it is already
  /// installed; otherwise the translators are swapped and every view is told
  /// to re-read its strings.
  void apply(const QString& locale);
  /// Re-read a language from the bridge's published snapshot and apply it if it
  /// changed. This is the path a `set_settings {language}` takes.
  void reapply();

private:
  QPointer<QQmlEngine> m_engine;
  QPointer<QObject> m_root;
  QTranslator m_appTranslator;
  QTranslator m_qtTranslator;
  QString m_current;
};
