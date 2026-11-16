// Language regression tests: switching the interface language while the window
// is open has to re-draw the labels, and it took three attempts to get there.
//
//  1. `installTranslator` alone left every label English: the `LanguageChange`
//     event it posts reaches widgets, not a QML engine.
//  2. The `.qm` was in the QML module's resource, under `/qt/qml`, where no
//     translator looks; the catalogue is now its own `rcc` at `:/i18n/`.
//  3. The engine was only retranslated after the *second* language change (a
//     "has it been built yet" latch), so the first switch — the one a user makes
//     in the settings dialog — changed nothing on screen.
//
// The test drives the real `InterfaceLanguage` against a real `QQmlEngine` and
// a real binding, and asserts the drawn string changes and changes back. What a
// green run does NOT prove: that the window draws it (that is a screenshot in
// `docs/evidence/`), or that every label in the app was wrapped in `qsTr` —
// `scripts/check_translations.py` guards the catalogue, not the sources.

#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QScopedPointer>
#include <QTest>

#include "language.h"

namespace {

/// One binding, in the `Theme` context — the context the menu labels live in,
/// so the assertion covers the catalogue that the menus actually read.
constexpr auto kScene = R"(
import QtQuick 2.0
Item {
  objectName: "host"
  property string label: qsTranslate("Theme", "Open")
  property string folderLabel: qsTranslate("BrowserView", "Quick access")
}
)";

QObject* loadScene(QQmlEngine& engine)
{
  QQmlComponent component(&engine);
  component.setData(kScene, QUrl(QStringLiteral("qrc:/tst_language.qml")));
  if (component.isError()) {
    qWarning() << component.errorString();
    return nullptr;
  }
  return component.create();
}

} // namespace

class TestLanguage : public QObject
{
  Q_OBJECT

private slots:
  void switchingToVietnameseRewritesTheLabels()
  {
    QQmlEngine engine;
    QScopedPointer<QObject> root(loadScene(engine));
    QVERIFY(root != nullptr);
    QCOMPARE(root->property("label").toString(), QStringLiteral("Open"));

    // The override argument is what `KOGAVIEW_UI_LANG` passes; empty means "the
    // stored setting decides", which is the path a settings change takes.
    InterfaceLanguage language(&engine, root.data(), QString());
    QVERIFY(language.locale().isEmpty());

    language.apply(QStringLiteral("vi"));
    QCOMPARE(language.locale(), QStringLiteral("vi"));
    QCOMPARE(root->property("label").toString(), QStringLiteral("Mở"));
    QCOMPARE(root->property("folderLabel").toString(), QStringLiteral("Truy cập nhanh"));

    // Back to the desktop's language: the same binding must return to the
    // source text, not stay on the last translation.
    language.apply(QString());
    QVERIFY(language.locale().isEmpty());
    QCOMPARE(root->property("label").toString(), QStringLiteral("Open"));
  }

  void theHarnessOverrideAppliesBeforeAnythingIsDrawn()
  {
    QQmlEngine engine;
    QScopedPointer<QObject> root(loadScene(engine));
    QVERIFY(root != nullptr);

    // `KOGAVIEW_UI_LANG=vi` is handed to the constructor, which runs after the
    // window exists: the first frame is already translated.
    InterfaceLanguage language(&engine, root.data(), QStringLiteral("vi"));
    QCOMPARE(language.locale(), QStringLiteral("vi"));
    QCOMPARE(root->property("label").toString(), QStringLiteral("Mở"));
  }

  void aLocaleWithoutACatalogueKeepsTheSourceText()
  {
    QQmlEngine engine;
    QScopedPointer<QObject> root(loadScene(engine));
    QVERIFY(root != nullptr);

    InterfaceLanguage language(&engine, root.data(), QString());
    // No `kogaview_de.qm` is compiled in; an unknown locale must not blank the
    // interface or crash the translator swap.
    language.apply(QStringLiteral("de"));
    QCOMPARE(language.locale(), QStringLiteral("de"));
    QCOMPARE(root->property("label").toString(), QStringLiteral("Open"));
  }
};

QTEST_MAIN(TestLanguage)
#include "tst_language.moc"
