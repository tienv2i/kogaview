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

#include <QFile>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QScopedPointer>
#include <QUrl>
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
  property string folderLabel: qsTranslate("QuickAccessPanel", "Quick access")
}
)";

/// A scene that holds the real `crates/desktop/qml/UiLines.qml` and calls it the
/// way the views do: `lines.text(line, interfaceLanguage)`. `interfaceLanguage`
/// is the property `InterfaceLanguage::apply` writes, so a language switch
/// reaches the call without a binding to re-evaluate.
QByteArray linesScene()
{
  return QStringLiteral(
             "import QtQuick 2.0\n"
             "import \"%1\" as KogaView\n"
             "Item {\n"
             "  objectName: \"host\"\n"
             "  property string interfaceLanguage: \"\"\n"
             "  property var lines: KogaView.UiLines {}\n"
             "  function line(code, args) {\n"
             "    return lines.text({ code: code, args: args }, interfaceLanguage)\n"
             "  }\n"
             "}\n")
      .arg(QUrl::fromLocalFile(QStringLiteral(KOGAVIEW_QML_SOURCE_DIR)).toString())
      .toUtf8();
}

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

  /// Core publishes a rejection as `{ code, args }` (`ProtocolError.ui`). The
  /// window draws it through `UiLines`, so the sentence has to follow the
  /// interface language — an English rejection in a Vietnamese window is the
  /// bug this covers — and a code the table does not know must not print a raw
  /// identifier.
  void aRejectedCommandIsDrawnInTheInterfaceLanguage()
  {
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData(linesScene(), QUrl(QStringLiteral("qrc:/tst_language_lines.qml")));
    QScopedPointer<QObject> root(component.create());
    QVERIFY2(root != nullptr, qPrintable(component.errorString()));

    const auto line = [&root](const QString& code, const QStringList& args) {
      QVariant text;
      const bool called = QMetaObject::invokeMethod(
          root.data(), "line", Q_RETURN_ARG(QVariant, text), Q_ARG(QVariant, code),
          Q_ARG(QVariant, args));
      return called ? text.toString() : QStringLiteral("<not called>");
    };

    // The English sentence before any translator is installed.
    QCOMPARE(line(QStringLiteral("not_a_folder"), {QStringLiteral("/tmp/pic")}),
             QStringLiteral("/tmp/pic is not a folder"));
    // A crop Core rejected: the code and every number it carries.
    QCOMPARE(line(QStringLiteral("crop_does_not_fit"),
                  {QStringLiteral("512"), QStringLiteral("384"), QStringLiteral("0"),
                   QStringLiteral("0"), QStringLiteral("1200"), QStringLiteral("1600")}),
             QStringLiteral("A 512 × 384 crop at 0,0 does not fit the 1200 × 1600 image"));

    InterfaceLanguage language(&engine, root.data(), QString());
    language.apply(QStringLiteral("vi"));
    QCOMPARE(line(QStringLiteral("not_a_folder"), {QStringLiteral("/tmp/pic")}),
             QStringLiteral("/tmp/pic không phải là thư mục"));
    QCOMPARE(line(QStringLiteral("crop_does_not_fit"),
                  {QStringLiteral("512"), QStringLiteral("384"), QStringLiteral("0"),
                   QStringLiteral("0"), QStringLiteral("1200"), QStringLiteral("1600")}),
             QStringLiteral("Bản cắt 512 × 384 tại 0,0 không vừa với ảnh 1200 × 1600"));

    // A code this interface does not know yet still says something: its
    // arguments, not the raw identifier.
    QCOMPARE(line(QStringLiteral("not_a_case_yet"), {QStringLiteral("a"), QStringLiteral("b")}),
             QStringLiteral("a b"));

    // Leave the process in the desktop's own language; the translators are only
    // removed by another `apply`.
    language.apply(QString());
  }

  /// `Main.qml` needs the real bridge, so the toast half is asserted in its
  /// source: a rejection is drawn from `error.ui` (the translatable line) and
  /// falls back to the English `message` only when Core sent no line.
  void theToastDrawsTheLineCoreSent()
  {
    QFile main(QStringLiteral(KOGAVIEW_QML_SOURCE_DIR "/Main.qml"));
    QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
    const QString source = QString::fromUtf8(main.readAll());

    const int start = source.indexOf(QStringLiteral("if (!result.ok && result.error)"));
    QVERIFY2(start >= 0, "Main.qml no longer handles a rejected command");
    const int end = source.indexOf(QStringLiteral("} else if (command.type"), start);
    QVERIFY(end > start);
    const QString block = source.mid(start, end - start);

    const int line = block.indexOf(QStringLiteral("result.error.ui"));
    const int message = block.indexOf(QStringLiteral("result.error.message"));
    QVERIFY2(line >= 0, "the rejection is not drawn from Core's line");
    QVERIFY2(message > line,
             "the English message is drawn before the translated line, so a "
             "Vietnamese window would show Core's English");
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
