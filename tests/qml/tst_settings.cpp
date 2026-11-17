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
  void escapeRevertsThePreview();
  void theButtonsReadDefaultsCancelApplyOk();
  void okSavesTheChoicesAndCloses();
  void applySavesAndLeavesTheDialogOpen();
  void defaultsRestoreTheBuiltInValuesWithoutSaving();
  void everyChangePreviewsImmediately();
  void cancelUndoesThePreview();
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

void TestSettings::escapeRevertsThePreview()
{
  openDialog();
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));
  QSignalSpy reverted(m_dialog, SIGNAL(revertRequested()));

  QTest::keyClick(m_view, Qt::Key_Escape);
  QTest::qWait(50);

  QVERIFY(!dialogVisible());
  QCOMPARE(saved.count(), 0);
  // Escape is Cancel: whatever was previewed is undone, not kept.
  QCOMPARE(reverted.count(), 1);
}

/// The footer's wording and order are the contract: a value-restoring button
/// apart on the left, then Cancel · Apply · OK with OK as the default action.
void TestSettings::theButtonsReadDefaultsCancelApplyOk()
{
  openDialog();
  QQuickItem* defaults = item("settingsDefaults");
  QQuickItem* cancel = item("settingsCancel");
  QQuickItem* apply = item("settingsApply");
  QQuickItem* ok = item("settingsOk");
  QVERIFY(defaults != nullptr && cancel != nullptr && apply != nullptr && ok != nullptr);

  QCOMPARE(defaults->property("text").toString(), QStringLiteral("Defaults"));
  QCOMPARE(cancel->property("text").toString(), QStringLiteral("Cancel"));
  QCOMPARE(apply->property("text").toString(), QStringLiteral("Apply"));
  QCOMPARE(ok->property("text").toString(), QStringLiteral("OK"));

  // Left to right on the real footer.
  const auto leftOf = [](QQuickItem* a, QQuickItem* b) {
    return a->mapToScene(QPointF(0, 0)).x() < b->mapToScene(QPointF(0, 0)).x();
  };
  QVERIFY2(leftOf(defaults, cancel), "Defaults is not left of Cancel");
  QVERIFY2(leftOf(cancel, apply), "Cancel is not left of Apply");
  QVERIFY2(leftOf(apply, ok), "Apply is not left of OK");
  // OK is the default action.
  QVERIFY(ok->property("highlighted").toBool());
  QVERIFY(!apply->property("highlighted").toBool());
  // Nothing has changed yet, so Apply has nothing to do.
  QVERIFY2(!apply->property("enabled").toBool(),
           "Apply is enabled with nothing pending");
}

void TestSettings::okSavesTheChoicesAndCloses()
{
  openDialog();
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));
  QSignalSpy reverted(m_dialog, SIGNAL(revertRequested()));
  QVERIFY(saved.isValid());

  // Toggle a value first: a pass has to carry a *changed* choice, not the
  // defaults the dialog opened with.
  QQuickItem* remember = item("settingsRemember");
  QVERIFY(remember != nullptr);
  const bool initialRemember = remember->property("checked").toBool();
  remember->setProperty("checked", !initialRemember);
  QTest::qWait(20);

  QQuickItem* ok = item("settingsOk");
  const QPoint centre =
    ok->mapToScene(QPointF(ok->width() / 2.0, ok->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(50);

  QCOMPARE(saved.count(), 1);
  QCOMPARE(reverted.count(), 0);
  const QList<QVariant> arguments = saved.first();
  QCOMPARE(arguments.at(0).toString(), m_dialog->property("initialTheme").toString());
  QCOMPARE(arguments.at(1).toBool(), !initialRemember);
  QCOMPARE(arguments.at(2).toBool(), m_dialog->property("initialBackground").toBool());
  QCOMPARE(arguments.at(3).toString(), m_dialog->property("initialLanguage").toString());
  QVERIFY(!dialogVisible());
}

void TestSettings::applySavesAndLeavesTheDialogOpen()
{
  openDialog();
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));
  QSignalSpy reverted(m_dialog, SIGNAL(revertRequested()));

  QQuickItem* themeChoice = item("settingsTheme");
  QVERIFY(themeChoice != nullptr);
  const int initialTheme = themeChoice->property("currentIndex").toInt();
  themeChoice->setProperty("currentIndex", initialTheme == 1 ? 0 : 1);
  QTest::qWait(20);

  QQuickItem* apply = item("settingsApply");
  QVERIFY2(apply->property("enabled").toBool(), "Apply is disabled after a change");
  const QPoint centre =
    apply->mapToScene(QPointF(apply->width() / 2.0, apply->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(50);

  QCOMPARE(saved.count(), 1);
  QVERIFY2(dialogVisible(), "Apply closed the dialog");
  QCOMPARE(saved.first().at(0).toString(),
           initialTheme == 1 ? QStringLiteral("dark") : QStringLiteral("light"));
  // The change was written, so Apply is pending again only after the next edit.
  QVERIFY2(!apply->property("enabled").toBool(),
           "Apply is still enabled after it saved the pending change");

  // And a second edit re-enables it, so the dialog stays usable.
  themeChoice->setProperty("currentIndex", initialTheme);
  QTest::qWait(20);
  QVERIFY(apply->property("enabled").toBool());

  // Closing with the × after a save does not undo the saved values.
  QTest::keyClick(m_view, Qt::Key_Escape);
  QTest::qWait(50);
  QVERIFY(!dialogVisible());
  QCOMPARE(reverted.count(), 0);
}

void TestSettings::defaultsRestoreTheBuiltInValuesWithoutSaving()
{
  openDialog();
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));
  QSignalSpy previewed(m_dialog, SIGNAL(previewRequested(QString, bool, bool, QString)));

  // Put the form somewhere away from the built-in values first.
  QQuickItem* themeChoice = item("settingsTheme");
  QQuickItem* remember = item("settingsRemember");
  QQuickItem* background = item("settingsBackground");
  m_dialog->setProperty("initialTheme", "light");
  themeChoice->setProperty("currentIndex", 1);
  remember->setProperty("checked", false);
  background->setProperty("checked", false);
  QTest::qWait(20);

  QQuickItem* defaults = item("settingsDefaults");
  const QPoint centre =
    defaults->mapToScene(QPointF(defaults->width() / 2.0, defaults->height() / 2.0)).toPoint();
  previewed.clear();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(50);

  // Back to light=false (dark), remember=true, thumbnails=true.
  QCOMPARE(themeChoice->property("currentIndex").toInt(), 0);
  QVERIFY(remember->property("checked").toBool());
  QVERIFY(background->property("checked").toBool());
  // Previewed, not saved, and still open.
  QVERIFY2(previewed.count() >= 1, "Defaults did not preview the restored values");
  QCOMPARE(saved.count(), 0);
  QVERIFY(dialogVisible());
}

void TestSettings::everyChangePreviewsImmediately()
{
  openDialog();
  QSignalSpy previewed(m_dialog, SIGNAL(previewRequested(QString, bool, bool, QString)));
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));

  // Start from a known value so the change below is a real change: an
  // assignment to the value already shown emits nothing, which is correct.
  QQuickItem* themeChoice = item("settingsTheme");
  themeChoice->setProperty("currentIndex", 0);
  QTest::qWait(30);
  previewed.clear();
  themeChoice->setProperty("currentIndex", 1);
  QTest::qWait(30);
  QCOMPARE(previewed.count(), 1);
  QCOMPARE(previewed.last().at(0).toString(), QStringLiteral("light"));
  // A preview is not a save.
  QCOMPARE(saved.count(), 0);

  QQuickItem* remember = item("settingsRemember");
  const bool initialRemember = remember->property("checked").toBool();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier,
                    remember->mapToScene(QPointF(remember->width() / 2.0,
                                                 remember->height() / 2.0)).toPoint());
  QTest::qWait(30);
  QCOMPARE(previewed.count(), 2);
  QCOMPARE(previewed.last().at(1).toBool(), !initialRemember);
  QCOMPARE(saved.count(), 0);
}

/// Cancel puts the preview back the way the dialog found it: the form and the
/// shell both go back, and nothing was written.
void TestSettings::cancelUndoesThePreview()
{
  openDialog();
  QSignalSpy previewed(m_dialog, SIGNAL(previewRequested(QString, bool, bool, QString)));
  QSignalSpy saved(m_dialog, SIGNAL(saveRequested(QString, bool, bool, QString)));
  QSignalSpy reverted(m_dialog, SIGNAL(revertRequested()));

  QQuickItem* themeChoice = item("settingsTheme");
  const int initialTheme = themeChoice->property("currentIndex").toInt();
  themeChoice->setProperty("currentIndex", initialTheme == 1 ? 0 : 1);
  QTest::qWait(30);
  QVERIFY(previewed.count() >= 1);

  QQuickItem* cancel = item("settingsCancel");
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier,
                    cancel->mapToScene(QPointF(cancel->width() / 2.0,
                                               cancel->height() / 2.0)).toPoint());
  QTest::qWait(50);

  QVERIFY(!dialogVisible());
  QCOMPARE(saved.count(), 0);
  QCOMPARE(reverted.count(), 1);
  // The last preview the shell receives restores the opening theme.
  QCOMPARE(previewed.last().at(0).toString(),
           initialTheme == 1 ? QStringLiteral("light") : QStringLiteral("dark"));
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
