// Settings dialog regression tests: the three things the dialog got wrong when
// it first shipped are all geometry/event facts, so they are asserted here
// instead of being remembered in a report.
//
// The tests load the real `crates/desktop/qml/SettingsDialog.qml` into a real
// `QQuickView` (the dialog is a `Popup`, so the view root is a bare host item and
// the dialog is parented to it, the way `Main.qml` hangs it on the window):
//
//  1. the dialog was pinned with `anchors.centerIn`, so a written `x` snapped
//     back within one frame and it could not be moved at all;
//  2. `closePolicy: NoAutoClose` made Escape a no-op, unlike a normal dialog;
//  3. the content `ColumnLayout` sat at (0, 0) flush against the header and the
//     side borders (`anchors.margins` is inert on an item that is only sized,
//     not anchored).
//
// What a green run does NOT prove: that the dialog *looks* right (that needs the
// real window), or that the modal obscurer blocks the rest of the app (a probe
// did that with injected mouse/wheel/key events, see docs/M1-REPORT.md).

#include <QFile>
#include <QGuiApplication>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

namespace {

QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}

constexpr int kHostWidth = 800;
constexpr int kHostHeight = 600;

} // namespace

class TestSettings : public QObject
{
  Q_OBJECT
private slots:
  void initTestCase();
  void cleanup();
  void opensCentredWithAnInsetContentColumn();
  void aWrittenPositionSticks();
  void draggingTheHeaderMovesTheDialog();
  void escapeClosesWithoutSaving();
  void theSaveButtonCarriesTheChoices();
  void theCloseButtonStillClicksThroughTheDragHandler();

private:
  /// The dialog is a `Popup`: its header, content and buttons are QObjects of
  /// the popup item, which lives in the window's overlay, not under the view
  /// root. Walking the window's content item reaches all of them.
  QQuickItem* visualItem(const QString& name) const;
  QQuickItem* item(const char* name) const;
  void openDialog();
  qreal property(const char* name) const { return m_dialog->property(name).toReal(); }
  bool dialogVisible() const { return m_dialog->property("visible").toBool(); }

  QQmlEngine m_engine;
  QQuickView* m_view = nullptr;
  QObject* m_dialog = nullptr;
  QTemporaryDir m_host;
};

void TestSettings::initTestCase()
{
  QVERIFY(m_host.isValid());
  const QString hostPath = m_host.path() + QStringLiteral("/host.qml");
  {
    QFile file(hostPath);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Text));
    file.write(QStringLiteral("import QtQuick\n"
                              "Item { objectName: \"settingsHost\" }\n")
                 .toUtf8());
  }

  m_view = new QQuickView(&m_engine, nullptr);
  m_view->setResizeMode(QQuickView::SizeRootObjectToView);
  m_view->resize(kHostWidth, kHostHeight);
  m_view->setSource(QUrl::fromLocalFile(hostPath));
  QCOMPARE(m_view->status(), QQuickView::Ready);
  QVERIFY(m_view->rootObject() != nullptr);
  m_view->show();
  QVERIFY(QTest::qWaitForWindowExposed(m_view));

  // Loaded from the app's own directory so the dialog resolves `Theme.qml` the
  // same way the shipped binary does.
  QQmlComponent component(&m_engine,
                          QUrl::fromLocalFile(qmlDir() + QStringLiteral("/SettingsDialog.qml")));
  QVERIFY2(component.isReady(), qPrintable(component.errorString()));
  m_dialog = component.create();
  QVERIFY(m_dialog != nullptr);
  m_dialog->setParent(m_view->rootObject());
  m_dialog->setProperty("parent", QVariant::fromValue(m_view->rootObject()));
}

void TestSettings::cleanup()
{
  if (m_dialog != nullptr && dialogVisible()) {
    m_dialog->setProperty("visible", false);
    QTest::qWait(20);
  }
  QVERIFY(!dialogVisible());
}

QQuickItem* TestSettings::visualItem(const QString& name) const
{
  QList<QQuickItem*> pending{m_view->contentItem()};
  while (!pending.isEmpty()) {
    QQuickItem* candidate = pending.takeFirst();
    if (candidate->objectName() == name) {
      return candidate;
    }
    pending.append(candidate->childItems());
  }
  return nullptr;
}

QQuickItem* TestSettings::item(const char* name) const
{
  return visualItem(QString::fromLatin1(name));
}

void TestSettings::openDialog()
{
  QMetaObject::invokeMethod(m_dialog, "open");
  QTest::qWait(50);
  QVERIFY(dialogVisible());
}

void TestSettings::opensCentredWithAnInsetContentColumn()
{
  openDialog();

  // 800x600 host, 620x520 dialog: centred at (90, 40) without an anchor.
  QCOMPARE(property("x"), 90.0);
  QCOMPARE(property("y"), 40.0);

  QQuickItem* content = item("settingsContent");
  QQuickItem* column = item("settingsColumn");
  QVERIFY(content != nullptr);
  QVERIFY(column != nullptr);

  // The bug: the column sat at (0, 0) with width == content width, so the first
  // row of controls touched the header and the side borders.
  QCOMPARE(column->x(), 20.0);
  QCOMPARE(column->y(), 20.0);
  QCOMPARE(column->width(), content->width() - 40.0);
  // ... and the scroll range keeps the same 20 px under the last row, otherwise
  // the bottom margin disappears exactly when the content overflows.
  QCOMPARE(content->property("contentHeight").toReal(), column->implicitHeight() + 40.0);
}

void TestSettings::aWrittenPositionSticks()
{
  openDialog();
  QCOMPARE(property("x"), 90.0);

  // `anchors.centerIn` used to own x/y: this write reverted to 90 within a
  // frame, which is also why dragging could never work.
  m_dialog->setProperty("x", 5.0);
  m_dialog->setProperty("y", 7.0);
  QTest::qWait(50);

  QCOMPARE(property("x"), 5.0);
  QCOMPARE(property("y"), 7.0);
}

void TestSettings::draggingTheHeaderMovesTheDialog()
{
  openDialog();
  const qreal startX = property("x");
  const qreal startY = property("y");

  QQuickItem* header = item("settingsHeader");
  QVERIFY(header != nullptr);
  // Grab the title area, left of the close button.
  const QPoint from = header->mapToScene(QPointF(120, header->height() / 2.0)).toPoint();
  QTest::mousePress(m_view, Qt::LeftButton, Qt::NoModifier, from);
  for (int step = 1; step <= 4; ++step) {
    QTest::mouseMove(m_view, from + QPoint(-20 * step, 10 * step));
  }
  QTest::mouseRelease(m_view, Qt::LeftButton, Qt::NoModifier, from + QPoint(-80, 40));
  QTest::qWait(50);

  // State delta, not stability: the dialog must end up somewhere else.
  QCOMPARE(property("x"), startX - 80.0);
  QCOMPARE(property("y"), startY + 40.0);
  QVERIFY(dialogVisible());
}

void TestSettings::escapeClosesWithoutSaving()
{
  openDialog();
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));

  QTest::keyClick(m_view, Qt::Key_Escape);
  QTest::qWait(50);

  QVERIFY(!dialogVisible());
  QCOMPARE(saved.count(), 0);
}

void TestSettings::theSaveButtonCarriesTheChoices()
{
  openDialog();
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));
  QVERIFY(saved.isValid());

  // The footer is built from explicit `Button`s (Qt's `standardButtons` would
  // draw the system's translations, and this machine has no `qtbase_vi`), so
  // the AcceptRole wiring — click → `accepted` → `saveRequested` — is what has
  // to be proven. A `ReferenceError` in that handler used to close the dialog
  // and save nothing, which is why this test toggles a value first: a pass has
  // to carry a *changed* choice, not the defaults.
  QQuickItem* remember = item("settingsRemember");
  QVERIFY(remember != nullptr);
  const bool initialRemember = remember->property("checked").toBool();
  remember->setProperty("checked", !initialRemember);
  QTest::qWait(20);

  QQuickItem* save = item("settingsSave");
  QVERIFY(save != nullptr);
  QCOMPARE(save->property("text").toString(), QStringLiteral("Save"));
  const QPoint centre =
    save->mapToScene(QPointF(save->width() / 2.0, save->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(50);

  QCOMPARE(saved.count(), 1);
  const QList<QVariant> arguments = saved.first();
  QCOMPARE(arguments.at(0).toString(), m_dialog->property("initialTheme").toString());
  QCOMPARE(arguments.at(1).toBool(), !initialRemember);
  QCOMPARE(arguments.at(2).toBool(), m_dialog->property("initialBackground").toBool());
  QCOMPARE(arguments.at(3).toString(), m_dialog->property("initialLanguage").toString());
  QVERIFY(!dialogVisible());
}

void TestSettings::theCloseButtonStillClicksThroughTheDragHandler()
{
  openDialog();
  QQuickItem* close = item("settingsClose");
  QVERIFY(close != nullptr);

  // The header drag must not eat a plain click on the close button.
  const QPoint centre =
    close->mapToScene(QPointF(close->width() / 2.0, close->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(50);

  QVERIFY(!dialogVisible());
}

QTEST_MAIN(TestSettings)
#include "tst_settings.moc"
