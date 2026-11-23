// Dialogs' shared chrome: one title bar, one body inset, one action row.
//
// The three forms grew in three sittings and drifted apart — the title bar was
// 52 px in all of them but the × sat at a different distance from the edge, the
// drag clamp was copy-pasted, the batch footer was 60 px of `PanelAction`s
// while Settings' was a stock button row, and Settings and Resize mixed a fixed
// label column with natural-width labels, so two rows of the same form started
// at two different x. The chrome now lives in `DialogFrame.qml` /
// `DialogFooter.qml` / `FormRow.qml` / `FormSection.qml`; this suite loads the
// real forms and asserts that they all wear it.
//
// What a green run does NOT prove: that the result *looks* tidy (that needs the
// real window), or that the type sizes and the elisions are readable at the
// window font. It pins the numbers and the structure — the parts that drifted
// silently, because each form was individually plausible.

#include <QDir>
#include <QGuiApplication>
#include <QFile>
#include <QColor>
#include <QQmlExpression>
#include <QHash>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QRegularExpression>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

namespace {

constexpr int kHostWidth = 900;
constexpr int kHostHeight = 700;

/// The chrome's numbers, as `DialogFrame.qml` declares them. The point of the
/// test is that every form reads these and none re-states them.
constexpr int kHeaderHeight = 52;
constexpr int kFooterHeight = 60;
constexpr int kBodyPadding = 20;
constexpr int kLabelWidth = 96;
constexpr int kRowGap = 8;
constexpr int kFooterMargin = 12;

/// A form that is a window of its own: the file, the root of its object names
/// and the title its title bar must read.
struct Form
{
  QString file;
  QString prefix;
  QString title;
};

const QVector<Form> kForms{
  { QStringLiteral("SettingsDialog.qml"), QStringLiteral("settings"), QStringLiteral("Settings") },
  { QStringLiteral("ResizeDialog.qml"), QStringLiteral("resize"), QStringLiteral("Resize image") },
  { QStringLiteral("BatchResizeDialog.qml"), QStringLiteral("batch"), QStringLiteral("Batch resize") },
};

} // namespace

class TestDialogs : public QObject
{
  Q_OBJECT

private slots:
  void initTestCase();
  void cleanup();
  void everyFormWearsTheSameTitleBar();
  void everyFormKeepsTheSameBodyInset();
  void everyFormEndsInTheSameActionRow();
  void theRowsLineUpOnOneLabelColumn();
  void noFormRebuildsItsOwnChrome();
  void aFormTallerThanTheWindowScrolls();
  void aNarrowWindowNarrowsTheForm();
  void theCrossIsCancelInEveryForm();
  void everyFormPaintsItsControlsInTheTheme();
  void cleanupTestCase();

private:
  QObject* form(const QString& prefix) const { return m_forms.value(prefix); }
  /// A named item anywhere in the window: a popup's parts are `QObject`s of the
  /// popup and live in the overlay, not under the view root.
  QQuickItem* visualItem(const QString& name) const;
  QQuickItem* item(const QString& prefix, const char* suffix) const;
  void openForm(const QString& prefix);
  void closeForm(const QString& prefix);
  /// A real click at an item's centre, the way a user presses it.
  void clickItem(QQuickItem* target);

  /// The QML the binary is built from.
  static QString qmlDir() { return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR); }

  QQmlEngine m_engine;
  QQuickView* m_view = nullptr;
  QHash<QString, QObject*> m_forms;
  QTemporaryDir m_hostDir;
};

void TestDialogs::initTestCase()
{
  QVERIFY(m_hostDir.isValid());
  const QString hostPath = m_hostDir.path() + QStringLiteral("/host.qml");
  {
    QFile file(hostPath);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Text));
    file.write(QStringLiteral("import QtQuick\n"
                              "Item { objectName: \"dialogHost\" }\n")
                 .toUtf8());
  }

  m_view = new QQuickView(&m_engine, nullptr);
  m_view->setResizeMode(QQuickView::SizeRootObjectToView);
  m_view->resize(kHostWidth, kHostHeight);
  m_view->setSource(QUrl::fromLocalFile(hostPath));
  QVERIFY2(m_view->status() == QQuickView::Ready,
           qPrintable(m_view->errors().isEmpty() ? QString()
                                                 : m_view->errors().first().toString()));
  m_view->show();
  QVERIFY(QTest::qWaitForWindowExposed(m_view));

  // The real files, from the app's own directory so each resolves its siblings
  // (`Theme.qml`, `PanelAction.qml`, `FormRow.qml`) the way the binary does.
  for (const Form& entry : kForms) {
    QQmlComponent component(
      &m_engine, QUrl::fromLocalFile(QStringLiteral(KOGAVIEW_QML_SOURCE_DIR) + QLatin1Char('/')
                                     + entry.file));
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));
    QObject* popup = component.create();
    QVERIFY2(popup != nullptr, qPrintable(component.errorString()));
    popup->setParent(m_view->rootObject());
    popup->setProperty("parent", QVariant::fromValue<QObject*>(m_view->rootObject()));
    popup->setObjectName(entry.prefix + QStringLiteral("Dialog"));
    m_forms.insert(entry.prefix, popup);
  }
}

void TestDialogs::cleanup()
{
  for (const Form& entry : kForms) {
    if (form(entry.prefix) != nullptr && form(entry.prefix)->property("visible").toBool()) {
      QMetaObject::invokeMethod(form(entry.prefix), "close");
      QTest::qWait(20);
    }
  }
  m_view->resize(kHostWidth, kHostHeight);
  QTest::qWait(20);
}

void TestDialogs::cleanupTestCase() { delete m_view; }

QQuickItem* TestDialogs::visualItem(const QString& name) const
{
  QList<QQuickItem*> pending{ m_view->contentItem() };
  while (!pending.isEmpty()) {
    QQuickItem* candidate = pending.takeFirst();
    if (candidate->objectName() == name) {
      return candidate;
    }
    pending.append(candidate->childItems());
  }
  return nullptr;
}

QQuickItem* TestDialogs::item(const QString& prefix, const char* suffix) const
{
  return visualItem(prefix + QString::fromLatin1(suffix));
}

void TestDialogs::openForm(const QString& prefix)
{
  QObject* dialog = form(prefix);
  QVERIFY2(dialog != nullptr, qPrintable(prefix));
  // The Resize form opens on a document size; without one its fields would be
  // empty placeholders, which is not what a user sees.
  if (prefix == QLatin1String("resize")) {
    dialog->setProperty("documentWidth", 1200);
    dialog->setProperty("documentHeight", 800);
    dialog->setProperty("documentReady", true);
  }
  QMetaObject::invokeMethod(dialog, "open");
  QTRY_VERIFY(dialog->property("visible").toBool());
  QTest::qWait(50);
}

void TestDialogs::closeForm(const QString& prefix)
{
  QObject* dialog = form(prefix);
  QMetaObject::invokeMethod(dialog, "close");
  QTRY_VERIFY(!dialog->property("visible").toBool());
}

void TestDialogs::clickItem(QQuickItem* target)
{
  QVERIFY(target != nullptr);
  const QPointF centre =
    target->mapToScene(QPointF(target->width() / 2, target->height() / 2));
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre.toPoint());
}

/// A form is a popup, and a popup's content hangs off the window's overlay
/// instead of off the window's own item tree — so it inherits neither the
/// shell's palette (`Main.qml` writes one from `appTheme`) nor the app's ink.
/// Every stock control a form still needs was therefore painted by the
/// desktop's own palette: white boxes with near-black text on a dark form, and
/// in light mode a dark form around light boxes. The frame writes the palette
/// from its theme now, in both themes and for every form.
void TestDialogs::everyFormPaintsItsControlsInTheTheme()
{
  for (const Form& entry : kForms) {
    QObject* dialog = form(entry.prefix);
    QVERIFY2(dialog != nullptr, qPrintable(entry.prefix));
    QObject* theme = dialog->property("theme").value<QObject*>();
    QVERIFY2(theme != nullptr, qPrintable(entry.prefix));
    // A popup's palette is resolved when its content is built, so the form has
    // to be on screen: a closed popup answers with the desktop's default.
    openForm(entry.prefix);

    for (const bool dark : { true, false }) {
      theme->setProperty("dark", dark);
      QTest::qWait(20);
      const auto colour = [theme](const char* name) {
        return theme->property(name).value<QColor>();
      };
      // Read through QML: a popup's palette is the one its content resolves, and
      // that is the value a stock control inside the form ends up drawing with.
      const auto paletteColour = [dialog](const char* role) {
        QQmlExpression probe(QQmlEngine::contextForObject(dialog), dialog,
                             QStringLiteral("String(palette.%1)").arg(QLatin1String(role)));
        return QColor(probe.evaluate().toString());
      };
      QCOMPARE(paletteColour("window"), colour("surface"));
      QCOMPARE(paletteColour("windowText"), colour("text"));
      QCOMPARE(paletteColour("text"), colour("text"));
      QCOMPARE(paletteColour("base"), colour("thumb"));
      QCOMPARE(paletteColour("buttonText"), colour("text"));
      QCOMPARE(paletteColour("highlight"), colour("accent"));
      QCOMPARE(paletteColour("highlightedText"), colour("accentText"));
      QCOMPARE(paletteColour("placeholderText"), colour("textMuted"));
    }
    theme->setProperty("dark", true);
    QTest::qWait(20);
    closeForm(entry.prefix);
  }
}

/// One title bar: 52 px, the form's own title, and a × at the same distance
/// from the right edge in every form.
void TestDialogs::everyFormWearsTheSameTitleBar()
{
  for (const Form& entry : kForms) {
    openForm(entry.prefix);
    QQuickItem* header = item(entry.prefix, "Header");
    QVERIFY2(header != nullptr, qPrintable(entry.prefix + QStringLiteral(" has no header")));
    QCOMPARE(header->implicitHeight(), qreal(kHeaderHeight));
    QCOMPARE(header->height(), qreal(kHeaderHeight));

    // The title sits 18 px in from the left edge, and the × 10 px in from the
    // right one — the same pair in every form, because it is written once.
    QQuickItem* title = item(entry.prefix, "Title");
    QVERIFY2(title != nullptr, qPrintable(entry.prefix + QStringLiteral(" has no title")));
    QCOMPARE(title->property("text").toString(), entry.title);
    QCOMPARE(title->mapToItem(header, QPointF(0, 0)).x(), 18.0);

    QQuickItem* close = item(entry.prefix, "Close");
    QVERIFY2(close != nullptr, qPrintable(entry.prefix + QStringLiteral(" has no ×")));
    QCOMPARE(close->mapToItem(header, QPointF(0, 0)).x() + close->width(),
             header->width() - 10.0);
    // A keyboard visitor reaches the × by Escape, not by tabbing: it must not
    // take a tab stop that the fields need.
    QVERIFY(!close->property("activeFocusOnTab").toBool());

    closeForm(entry.prefix);
  }
}

/// One body inset: 20 px on all four sides, and the same 20 px under the last
/// row as scroll range, so the bottom margin does not vanish exactly when the
/// form overflows.
void TestDialogs::everyFormKeepsTheSameBodyInset()
{
  for (const Form& entry : kForms) {
    openForm(entry.prefix);
    QQuickItem* content = item(entry.prefix, "Content");
    QQuickItem* column = item(entry.prefix, "Column");
    QVERIFY2(content != nullptr && column != nullptr, qPrintable(entry.prefix));
    // The body scrolls rather than clipping a tall form under the footer.
    QVERIFY(content->property("clip").toBool());

    QCOMPARE(column->x(), qreal(kBodyPadding));
    QCOMPARE(column->y(), qreal(kBodyPadding));
    QCOMPARE(column->width(), content->width() - 2 * qreal(kBodyPadding));
    QCOMPARE(content->property("contentHeight").toReal(),
             column->implicitHeight() + 2 * qreal(kBodyPadding));

    closeForm(entry.prefix);
  }
}

/// One action row: 60 px, 12 px margins, 8 px gap, and the app's own buttons —
/// never a stock `Button`, whose words come from the platform's catalogue.
void TestDialogs::everyFormEndsInTheSameActionRow()
{
  for (const Form& entry : kForms) {
    openForm(entry.prefix);
    QQuickItem* footer = item(entry.prefix, "Footer");
    QVERIFY2(footer != nullptr, qPrintable(entry.prefix + QStringLiteral(" has no footer")));
    QCOMPARE(footer->height(), qreal(kFooterHeight));
    QCOMPARE(footer->x(), qreal(kFooterMargin));
    QCOMPARE(footer->width(), form(entry.prefix)->property("width").toReal()
                                - 2 * qreal(kFooterMargin));
    QCOMPARE(footer->property("spacing").toReal(), double(kRowGap));

    int verbs = 0;
    int primaries = 0;
    for (QQuickItem* child : footer->childItems()) {
      // The spacer between a value-restoring verb and the rest is an unnamed
      // `Item`; only the verbs carry a name.
      if (child->objectName().isEmpty()) {
        continue;
      }
      QVERIFY2(QString::fromLatin1(child->metaObject()->className())
                 .contains(QStringLiteral("PanelAction")),
               qPrintable(QStringLiteral("%1's %2 is not the app's own button")
                            .arg(entry.prefix, child->objectName())));
      ++verbs;
      // Exactly one verb is painted with the accent, and it is the last one:
      // the default action sits where the eye (and the keyboard's Enter) lands.
      if (child->property("primary").toBool()) {
        ++primaries;
        QCOMPARE(child, footer->childItems().last());
      }
    }
    QVERIFY2(verbs >= 2, qPrintable(entry.prefix + QStringLiteral(" has no verbs")));
    QCOMPARE(primaries, 1);

    closeForm(entry.prefix);
  }
}

/// One label column: every control in a form starts at the same x, so a form
/// has one left edge to read at instead of a stair-step. Settings' two
/// right-aligned rows (Theme, Language) opt out on purpose and fill the row.
void TestDialogs::theRowsLineUpOnOneLabelColumn()
{
  const double expected = kLabelWidth + kRowGap;
  // Resize mixes `FormRow`s with a grid of Width/Height fields; both must land
  // on the column.
  openForm(QStringLiteral("resize"));
  QQuickItem* resizeColumn = item(QStringLiteral("resize"), "Column");
  QVERIFY(resizeColumn != nullptr);
  for (const char* name : { "resizeWidth", "resizeHeight", "resizeSizePreset", "resizeFit",
                            "resizeFilter" }) {
    QQuickItem* control = visualItem(QString::fromLatin1(name));
    QVERIFY2(control != nullptr, name);
    QCOMPARE(control->mapToItem(resizeColumn, QPointF(0, 0)).x(), expected);
  }
  closeForm(QStringLiteral("resize"));

  // The batch form is the same body under a different title, so the same rule
  // holds there.
  openForm(QStringLiteral("batch"));
  QQuickItem* batchColumn = item(QStringLiteral("batch"), "Column");
  QVERIFY(batchColumn != nullptr);
  for (const char* name : { "batchResizeWidth", "batchResizeHeight" }) {
    QQuickItem* control = visualItem(QString::fromLatin1(name));
    QVERIFY2(control != nullptr, name);
    QCOMPARE(control->mapToItem(batchColumn, QPointF(0, 0)).x(), expected);
  }
  closeForm(QStringLiteral("batch"));
}

/// The frame is the only chrome there is, and no form opens itself.
///
/// `Main.qml`, `EditorView.qml` and `BrowserView.qml` cannot be instantiated
/// here — they need the real bridge — and the Export, New folder, Delete and
/// Unsaved dialogs live inside them, so the only way to hold those four to the
/// standard is to read the sources. What is asserted is the absence this change
/// created: no form declares a bare `Dialog`, none uses the platform's
/// `DialogButtonBox` or `MessageDialog` (their words come from
/// `qtbase_<locale>.qm`, which a Vietnamese window cannot rely on), and none
/// writes `onAboutToShow` — the frame owns that handler, and a form's opening
/// work is `prepare()`.
///
/// Comment lines are skipped on purpose: several of these files *name*
/// `MessageDialog` and `onAboutToShow` while explaining why they no longer use
/// them, and a guard that cannot tell a note from a call would have to be
/// deleted the first time somebody documented the reason.
void TestDialogs::noFormRebuildsItsOwnChrome()
{
  const QDir dir(qmlDir());
  QVERIFY2(dir.exists(), "the QML source directory is missing");
  const QStringList files = dir.entryList({ QStringLiteral("*.qml") }, QDir::Files);
  QVERIFY(files.contains(QStringLiteral("Main.qml")));

  // `Dialog {` exactly: `DialogFrame {`, `FolderDialog {`, `FileDialog {` and
  // `ColorDialog {` all contain the word and are not what this looks for.
  const QRegularExpression bareDialog(QStringLiteral("(?<![A-Za-z0-9_.])Dialog\\s*\\{"));

  for (const QString& name : files) {
    // The frame is the one file that declares a `Dialog`; every form extends it.
    if (name == QLatin1String("DialogFrame.qml")) {
      continue;
    }
    QFile file(dir.filePath(name));
    QVERIFY2(file.open(QIODevice::ReadOnly | QIODevice::Text), qPrintable(name));
    const QStringList lines = QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'));
    for (int index = 0; index < lines.size(); ++index) {
      const QString line = lines.at(index).trimmed();
      if (line.startsWith(QLatin1String("//")) || line.startsWith(QLatin1Char('*'))) {
        continue;
      }
      const QString where = QStringLiteral("%1:%2").arg(name).arg(index + 1) + QStringLiteral(": ");
      QVERIFY2(!line.contains(QLatin1String("DialogButtonBox")),
               qPrintable(where + QStringLiteral("uses the platform's button row")));
      QVERIFY2(!line.contains(QLatin1String("MessageDialog")),
               qPrintable(where + QStringLiteral("uses the platform's question box")));
      QVERIFY2(!line.contains(QLatin1String("onAboutToShow")),
               qPrintable(where + QStringLiteral("opens itself; a form implements prepare()")));
      QVERIFY2(!bareDialog.match(line).hasMatch(),
               qPrintable(where + QStringLiteral("declares a bare Dialog, not a DialogFrame")));
    }
  }

  // The forms of their own are frames, and so are the four inside the shell.
  int frames = 0;
  for (const QString& name : files) {
    QFile file(dir.filePath(name));
    QVERIFY2(file.open(QIODevice::ReadOnly | QIODevice::Text), qPrintable(name));
    if (QString::fromUtf8(file.readAll()).contains(QLatin1String("DialogFrame {"))) {
      ++frames;
    }
  }
  QVERIFY2(frames >= 6, qPrintable(QStringLiteral("only %1 files wear the frame").arg(frames)));
  for (const char* inShell : { "Main.qml", "EditorView.qml", "BrowserView.qml" }) {
    QFile file(dir.filePath(QLatin1String(inShell)));
    QVERIFY2(file.open(QIODevice::ReadOnly | QIODevice::Text), inShell);
    QVERIFY2(QString::fromUtf8(file.readAll()).contains(QLatin1String("DialogFrame {")),
             qPrintable(QStringLiteral("%1 has no framed dialog").arg(QLatin1String(inShell))));
  }
}

/// The window always wins: a form taller than the window is clipped to it and
/// scrolls, instead of drawing its verbs past the bottom edge.
void TestDialogs::aFormTallerThanTheWindowScrolls()
{
  m_view->resize(kHostWidth, 300);
  QTest::qWait(20);

  openForm(QStringLiteral("resize"));
  QObject* dialog = form(QStringLiteral("resize"));
  QQuickItem* content = item(QStringLiteral("resize"), "Content");
  QQuickItem* footer = item(QStringLiteral("resize"), "Footer");
  QVERIFY(content != nullptr && footer != nullptr);

  const double height = dialog->property("height").toReal();
  QVERIFY2(height <= 300 - 48 + 1, qPrintable(QString::number(height)));
  // The chrome keeps its own height and the body is the part that gives: the
  // content no longer fits, so the scroll range is positive...
  QCOMPARE(content->height(), height - kHeaderHeight - kFooterHeight);
  QVERIFY2(content->property("contentHeight").toReal() > content->height(), "the body does not scroll");
  // ... and the verbs are still drawn inside the frame, not past its bottom.
  const double dialogTop = dialog->property("y").toReal();
  const QPointF verbsBottom = footer->mapToScene(QPointF(0, footer->height()));
  QVERIFY2(verbsBottom.y() <= dialogTop + height + 1, "the verbs are drawn past the bottom edge");
  // The overflow is said out loud: a bar, not a form that silently cuts a row
  // in half at the fold.
  QQuickItem* bar = nullptr;
  for (QQuickItem* candidate : content->findChildren<QQuickItem*>()) {
    if (candidate->inherits("QQuickScrollBar")) {
      bar = candidate;
      break;
    }
  }
  QVERIFY2(bar != nullptr, "the body has no scroll bar");
  QVERIFY2(bar->isVisible(), "the scroll bar is hidden while the content overflows");
  QVERIFY2(bar->property("size").toReal() < 1.0, "the scroll bar says the content fits");

  closeForm(QStringLiteral("resize"));
}

/// A narrow window narrows the form and the body follows: the column is never
/// wider than the frame it is drawn in.
void TestDialogs::aNarrowWindowNarrowsTheForm()
{
  m_view->resize(400, kHostHeight);
  QTest::qWait(20);

  for (const Form& entry : kForms) {
    openForm(entry.prefix);
    QObject* dialog = form(entry.prefix);
    QQuickItem* content = item(entry.prefix, "Content");
    QQuickItem* column = item(entry.prefix, "Column");
    QVERIFY2(content != nullptr && column != nullptr, qPrintable(entry.prefix));
    QCOMPARE(dialog->property("width").toReal(), 400.0 - 48.0);
    QCOMPARE(column->width(), content->width() - 2 * qreal(kBodyPadding));
    closeForm(entry.prefix);
  }
}

/// The × is Cancel in every form: it closes and sends nothing, even when the
/// form is holding an answer the default verb would have sent.
void TestDialogs::theCrossIsCancelInEveryForm()
{
  // Resize: type a new width — Apply becomes live — then leave by the ×.
  openForm(QStringLiteral("resize"));
  QSignalSpy resized(form(QStringLiteral("resize")), SIGNAL(resizeRequested(int, int, QVariant, int, QString, QString)));
  QVERIFY(resized.isValid());
  QQuickItem* width = item(QStringLiteral("resize"), "Width");
  QVERIFY(width != nullptr);
  // A `UnitField` is a row: the unit selector sits beside the text, and the
  // text control is the one that takes the keyboard.
  QQuickItem* input = width->property("inputField").value<QQuickItem*>();
  QVERIFY(input != nullptr);
  input->forceActiveFocus();
  QTest::qWait(10);
  QTest::keyClick(m_view, Qt::Key_A, Qt::ControlModifier);
  for (const QChar character : QStringLiteral("640")) {
    QTest::keyClick(m_view, static_cast<Qt::Key>(character.unicode()));
  }
  QTRY_VERIFY(item(QStringLiteral("resize"), "Apply")->property("enabled").toBool());
  clickItem(item(QStringLiteral("resize"), "Close"));
  QTRY_VERIFY(!form(QStringLiteral("resize"))->property("visible").toBool());
  QCOMPARE(resized.count(), 0);

  // Batch: answered, then left by the × — nothing runs.
  openForm(QStringLiteral("batch"));
  QSignalSpy ran(form(QStringLiteral("batch")), SIGNAL(runRequested(QVariant)));
  QVERIFY(ran.isValid());
  form(QStringLiteral("batch"))->setProperty("selectionPaths", QStringList{ QStringLiteral("/pics/a.png") });
  clickItem(item(QStringLiteral("batch"), "Close"));
  QTRY_VERIFY(!form(QStringLiteral("batch"))->property("visible").toBool());
  QCOMPARE(ran.count(), 0);

  // Settings: previewed, then left by the × — the shell is told to put the
  // preview back.
  openForm(QStringLiteral("settings"));
  QSignalSpy reverted(form(QStringLiteral("settings")), SIGNAL(revertRequested()));
  QVERIFY(reverted.isValid());
  clickItem(item(QStringLiteral("settings"), "Close"));
  QTRY_VERIFY(!form(QStringLiteral("settings"))->property("visible").toBool());
  QCOMPARE(reverted.count(), 1);
}

QTEST_MAIN(TestDialogs)
#include "tst_dialogs.moc"
