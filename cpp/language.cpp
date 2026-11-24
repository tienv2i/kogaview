#include "language.h"

#include <QCoreApplication>
#include <QDebug>
#include <QEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLibraryInfo>
#include <QMetaObject>
#include <QQmlEngine>
#include <QResource>
#include <QVariant>

namespace {
/// The `.qm` catalogue lives in a resource file of its own, built by `rcc` and
/// registered once. A resource the QML module owned would be registered by Qt
/// itself, but only under `/qt/qml`, which is not where a translator looks.
bool registerTranslations()
{
#ifdef KOGAVIEW_TRANSLATIONS_RCC
  static const bool registered = QResource::registerResource(QStringLiteral(KOGAVIEW_TRANSLATIONS_RCC));
  if (!registered) {
    qWarning() << "KogaView language: cannot register" << QStringLiteral(KOGAVIEW_TRANSLATIONS_RCC);
  }
  return registered;
#else
  // A build without lrelease has no catalogue; every string stays its English
  // source text, which is a supported state, not an error.
  return false;
#endif
}
} // namespace

InterfaceLanguage::InterfaceLanguage(QQmlEngine* engine, QObject* rootObject,
                                     QString requestedOverride, QObject* parent)
  : QObject(parent)
  , m_engine(engine)
  , m_root(rootObject)
{
  registerTranslations();
  // `KOGAVIEW_UI_LANG` is the harness override; it wins for the whole run, so a
  // stored setting cannot drag a screenshot back to English halfway.
  if (!requestedOverride.isEmpty()) {
    apply(requestedOverride);
  }
}

void InterfaceLanguage::apply(const QString& requested)
{
  const QString locale = requested == QLatin1String("system") || requested.isEmpty()
                           ? QString()
                           : requested;
  if (locale == m_current) {
    return;
  }
  m_current = locale;
  QCoreApplication::removeTranslator(&m_appTranslator);
  QCoreApplication::removeTranslator(&m_qtTranslator);
  if (!locale.isEmpty()) {
    // Which locale is installed, for the labels `PlatformHelper` spells itself
    // (the file-dialog filters are translated without a translator).
    m_appTranslator.setProperty("kogaviewLocale", locale);
    if (m_appTranslator.load(QStringLiteral("kogaview_") + locale, QStringLiteral(":/i18n"))) {
      QCoreApplication::installTranslator(&m_appTranslator);
    }
    // Qt's own strings (standard buttons, file dialogs); absent is fine.
    const QString qtDir = QLibraryInfo::path(QLibraryInfo::TranslationsPath);
    if (m_qtTranslator.load(QStringLiteral("qtbase_") + locale, qtDir)) {
      QCoreApplication::installTranslator(&m_qtTranslator);
    }
  }
  qInfo().noquote() << "KogaView language" << (locale.isEmpty() ? "system" : locale);
  // The bridge ships the language and the snapshot, and QML rebuilds the views
  // from the new strings.
  // `Main.qml` owns a `retranslateBridge()` that pushes the new snapshot; a
  // scene without one (the language test's bare host item) is not an error.
  if (m_root != nullptr &&
      m_root->metaObject()->indexOfMethod("retranslateBridge()") >= 0) {
    QMetaObject::invokeMethod(m_root, "retranslateBridge");
  }
  // `QQmlEngine::retranslate()` is what re-runs the bindings that read a
  // translated string: a `LanguageChange` event on the application does not
  // reach a QML engine (`QCoreApplication::installTranslator` only notifies
  // widgets), which is why the first attempt left every label English while a
  // binding that happened to re-evaluate was translated. The engine is loaded
  // before this object exists, so there is no "too early" case to guard.
  if (m_engine != nullptr) {
    m_engine->retranslate();
  }
  if (m_root != nullptr) {
    m_root->setProperty("interfaceLanguage", m_current);
  }
  emit localeChanged();
}

void InterfaceLanguage::setRootObject(QObject* rootObject)
{
  m_root = rootObject;
  if (m_root != nullptr && !m_current.isEmpty()) {
    m_root->setProperty("interfaceLanguage", m_current);
  }
}

void InterfaceLanguage::reapply()
{
  if (m_root == nullptr) {
    return;
  }
  auto* bridge = m_root->findChild<QObject*>(QStringLiteral("bridge"));
  if (bridge == nullptr) {
    return;
  }
  const QString json = bridge->property("stateJson").toString();
  if (json.isEmpty()) {
    return;
  }
  const QJsonObject state = QJsonDocument::fromJson(json.toUtf8()).object();
  if (state.contains(QStringLiteral("language"))) {
    apply(state.value(QStringLiteral("language")).toString());
  }
}
