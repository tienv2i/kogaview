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

#include <QColor>
#include <QFont>
#include <QFile>
#include <QGuiApplication>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QScopeGuard>
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
  void theDialogIsCentredWhileItOpens();
  void aWrittenPositionSticks();
  void draggingTheHeaderMovesTheDialog();
  void escapeRevertsThePreview();
  void theButtonsReadDefaultsCancelApplyOk();
  void okSavesTheChoicesAndCloses();
  void applySavesAndLeavesTheDialogOpen();
  void defaultsRestoreTheBuiltInValuesWithoutSaving();
  void everyChangePreviewsImmediately();
  void cancelUndoesThePreview();
  void theThemePickerOpensOnTheStoredTheme();
  void theHintLineLeavesRoomForItsDiacritics();
  void theCloseButtonStillClicksThroughTheDragHandler();
  void theShellSuspendsTheWorkspaceWhileAModalDialogIsOpen();
  void theShellBindsTheCopyKeysItsMenusName();
  void theDiscardAnswerResetsTheDocumentBeforeLeaving();
  void theShellAsksBeforeReplacingAnUnsavedDocument();
  void theShellSharesOneLayoutAndRevealsThroughThePlatform();
  void theShellKeepsThePanelListInSettings();
  void theAppearanceSectionsEditAndSaveTheLayout();

private:
  /// The dialog is a `Popup`: its header, content and buttons are QObjects of
  /// the popup item, which lives in the window's overlay, not under the view
  /// root. Walking the window's content item reaches all of them.
  QQuickItem* visualItem(const QString& name) const;
  QQuickItem* item(const char* name) const;
  void openDialog();
  /// The first `CheckBox` under `root`, in page order. The panel rows are a
  /// `Repeater`, and a delegate is not a QObject child of the Repeater, so the
  /// walk goes through the visual tree.
  QQuickItem* firstCheckBox(QQuickItem* root) const;
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

QQuickItem* TestSettings::firstCheckBox(QQuickItem* root) const
{
  QList<QQuickItem*> pending{root};
  while (!pending.isEmpty()) {
    QQuickItem* candidate = pending.takeFirst();
    if (candidate->inherits("QQuickCheckBox") && candidate->isVisible()) {
      return candidate;
    }
    pending.append(candidate->childItems());
  }
  return nullptr;
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

/// The Settings dialog had the same `onOpened` centring as Resize. A slow enter
/// transition makes the popup visible (and uncentred) before `opened` fires.
void TestSettings::theDialogIsCentredWhileItOpens()
{
  const QVariant originalEnter = m_dialog->property("enter");
  // A failure must not leave the custom transition or an open modal behind for
  // the next case, so the cleanup runs on the failing path too.
  const auto restoreDialog = qScopeGuard([dialog = m_dialog, originalEnter]() {
    if (dialog->property("visible").toBool()) {
      QMetaObject::invokeMethod(dialog, "close");
    }
    for (int wait = 0; wait < 200 && dialog->property("visible").toBool(); ++wait) {
      QTest::qWait(10);
    }
    dialog->setProperty("enter", originalEnter);
  });

  // The transition is created in QML: QQuickTransition has no public C++
  // header, and an assignment through the dialog's own `enter` property is
  // exactly what a style does.
  QQmlContext context(m_engine.rootContext());
  context.setContextProperty(QStringLiteral("__dialogUnderTest"), m_dialog);
  QQmlExpression slowEnter(
    &context, m_dialog,
    QStringLiteral("__dialogUnderTest.enter = Qt.createQmlObject("
                   "'import QtQuick; Transition { NumberAnimation { "
                   "property: \"opacity\"; from: 0; to: 1; duration: 600 } }', "
                   "__dialogUnderTest)"));
  slowEnter.evaluate();
  QVERIFY2(!slowEnter.hasError(), qPrintable(slowEnter.error().toString()));

  // Test setup can centre the form through an earlier width/height change.
  // Start from a corner, as the positioner does before `aboutToShow`, so this
  // case observes what the first visible frame really does.
  m_dialog->setProperty("x", 0.0);
  m_dialog->setProperty("y", 0.0);
  QCoreApplication::processEvents();

  QMetaObject::invokeMethod(m_dialog, "open");
  QTRY_VERIFY(dialogVisible());
  QVERIFY2(!m_dialog->property("opened").toBool(),
           "the enter transition finished before the first visible frame could be inspected");
  QCOMPARE(property("x"), 90.0);
  QCOMPARE(property("y"), 40.0);

  QTRY_VERIFY_WITH_TIMEOUT(m_dialog->property("opened").toBool(), 2000);
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
  // OK is the default action: the one verb painted with the accent.
  QVERIFY2(ok->property("primary").toBool(), "OK is not the default action");
  QVERIFY(!apply->property("primary").toBool());
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

/// The form opens on what is stored, whatever the controls happen to hold. A
/// `ComboBox` writes its own `currentIndex` when its model is re-evaluated, and
/// the theme picker's model is two translated strings — the interface language
/// lands after boot, so the picker was left on `Dark` while the stored theme was
/// light. `themeCode()` then answered `dark`, and simply opening Settings
/// flipped the whole window to dark, around a dark form and the desktop's light
/// controls. Measured on the real window in light mode.
/// The line under the form is prose, not a caption. At 11 px its line box was
/// shorter than the Vietnamese marks: every accented word had its top and its
/// bottom bitten off — measured on the real window, `Thay đổi được xem trước…`
/// lost the hook of `ổ` and the dot of `ụ`. It is 12 px now, the smallest size
/// in this window that leaves the marks whole, so the size is pinned rather than
/// left to the next tidy-up.
void TestSettings::theHintLineLeavesRoomForItsDiacritics()
{
  openDialog();
  QQuickItem* hint = item("settingsHint");
  QVERIFY2(hint != nullptr, "the form has no hint line");
  const QFont font = hint->property("font").value<QFont>();
  QVERIFY2(font.pixelSize() >= 12,
           qPrintable(QStringLiteral("the hint line is %1 px, which clips the marks")
                        .arg(font.pixelSize())));
}

void TestSettings::theThemePickerOpensOnTheStoredTheme()
{
  // The popup's content is built on the first open, so the picker has to be
  // fetched once before the form can be put back the way boot leaves it.
  openDialog();
  QQuickItem* themeChoice = item("settingsTheme");
  QVERIFY(themeChoice != nullptr);
  m_dialog->setProperty("visible", false);
  QTest::qWait(20);
  QVERIFY(!dialogVisible());

  m_dialog->setProperty("initialTheme", QStringLiteral("light"));
  // What the control's own model reset does to the picker: the wrong entry,
  // silently, with no change event to correct it.
  themeChoice->setProperty("currentIndex", 0);
  QTest::qWait(20);

  QSignalSpy previewed(m_dialog, SIGNAL(previewRequested(QString, bool, bool, QString)));
  openDialog();

  QCOMPARE(themeChoice->property("currentIndex").toInt(), 1);
  QQmlExpression code(QQmlEngine::contextForObject(m_dialog), m_dialog,
                      QStringLiteral("themeCode()"));
  QCOMPARE(code.evaluate().toString(), QStringLiteral("light"));
  // Opening a form is not a change: nothing is previewed before the user
  // touches it, so the window keeps the theme it had.
  QCOMPARE(previewed.count(), 0);
  m_dialog->setProperty("initialTheme", QStringLiteral("dark"));
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

/// `Main.qml` cannot be instantiated here — it needs the real `KogaViewBridge` —
/// so the shell half of the modal contract is asserted in its source: every
/// modal dialog must switch the workspace loader off. Without that the Viewer's
/// pan handler receives the pointer through the popup and steals the header
/// drag (`tst_viewer::aModalDialogOwnsThePointer` covers the other half).
void TestSettings::theShellSuspendsTheWorkspaceWhileAModalDialogIsOpen()
{
  QFile main(qmlDir() + QStringLiteral("/Main.qml"));
  QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
  const QString source = QString::fromUtf8(main.readAll());

  QVERIFY2(source.contains(QStringLiteral("enabled: !root.modalDialogOpen")),
           "the workspace loader is not gated on the modal dialogs");

  // The gate only helps if every modal dialog feeds the property. The block
  // ends at the first blank line, so a dialog added elsewhere does not count.
  const int start = source.indexOf(QStringLiteral("readonly property bool modalDialogOpen:"));
  QVERIFY2(start >= 0, "Main.qml has no modalDialogOpen property");
  const int end = source.indexOf(QStringLiteral("\n\n"), start);
  QVERIFY(end > start);
  const QString block = source.mid(start, end - start);
  const char* dialogs[] = {"settingsDialog", "unsavedDialog", "deleteDialog",
                           "fileFallback",   "folderFallback", "saveFallback"};
  for (const char* dialog : dialogs) {
    QVERIFY2(block.contains(QStringLiteral("%1.visible").arg(QLatin1String(dialog))),
             qPrintable(QStringLiteral("%1 does not suspend the workspace")
                          .arg(QLatin1String(dialog))));
  }
}

/// The context menus name `Ctrl+Shift+C` and `Ctrl+Alt+C` beside their copy
/// entries, and those words are literals in `Viewer.qml`/`BrowserView.qml`
/// (`tst_viewer::theCopyEntriesNameTheirKeys`). Nothing in a menu can bind a
/// key, so the binding is a pair of `Shortcut`s in the shell — which cannot be
/// instantiated here. This guard pins the shell half: the same two sequences,
/// which handler each runs, and the modal gate. A renamed or re-bound key now
/// fails a test instead of leaving a menu advertising a key that does nothing.
void TestSettings::theShellBindsTheCopyKeysItsMenusName()
{
  QFile main(qmlDir() + QStringLiteral("/Main.qml"));
  QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
  const QString source = QString::fromUtf8(main.readAll());

  // The `Shortcut { … }` block that declares `sequence`, so the handler checked
  // is the one bound to that key rather than any handler in the file.
  const auto shortcutFor = [&source](const QString& sequence) {
    const int at = source.indexOf(QStringLiteral("sequence: \"%1\"").arg(sequence));
    if (at < 0) return QString();
    const int begin = source.lastIndexOf(QStringLiteral("Shortcut {"), at);
    const int end = source.indexOf(QStringLiteral("\n    }"), at);
    if (begin < 0 || end < begin) return QString();
    return source.mid(begin, end - begin);
  };

  const QString copyContent = shortcutFor(QStringLiteral("Ctrl+Shift+C"));
  QVERIFY2(!copyContent.isEmpty(), "no Shortcut is bound to Ctrl+Shift+C");
  QVERIFY2(copyContent.contains(QStringLiteral("onActivated: root.copyImageContent()")),
           "Ctrl+Shift+C does not copy the image content the menu names it for");
  QVERIFY2(copyContent.contains(QStringLiteral("enabled: !root.modalDialogOpen")),
           "Ctrl+Shift+C ignores the modal gate");

  const QString copyPath = shortcutFor(QStringLiteral("Ctrl+Alt+C"));
  QVERIFY2(!copyPath.isEmpty(), "no Shortcut is bound to Ctrl+Alt+C");
  QVERIFY2(copyPath.contains(QStringLiteral("onActivated: root.copySelectedPaths()")),
           "Ctrl+Alt+C does not copy the path the menu names it for");
  QVERIFY2(copyPath.contains(QStringLiteral("enabled: !root.modalDialogOpen")),
           "Ctrl+Alt+C ignores the modal gate");
}

/// The Discard answer to the unsaved-changes question has to drop the edits for
/// real, and it has to do it *before* the workspace changes. Core compares the
/// open document with the Viewer's picture and refuses to replace a modified
/// one, so without this `editor_reset` the Editor reopened the old image after
/// the user had already said Discard (the reported bug). The other half — what
/// Core does with the two commands — is
/// `core::tests::switching_to_the_editor_carries_the_viewer_image`.
void TestSettings::theDiscardAnswerResetsTheDocumentBeforeLeaving()
{
  QFile main(qmlDir() + QStringLiteral("/Main.qml"));
  QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
  const QString source = QString::fromUtf8(main.readAll());

  const int start = source.indexOf(QStringLiteral("function leaveAfterDiscard()"));
  QVERIFY2(start >= 0, "Main.qml has no leaveAfterDiscard");
  const int end = source.indexOf(QStringLiteral("\n    }"), start);
  QVERIFY2(end > start, "leaveAfterDiscard never closes");
  const QString body = source.mid(start, end - start);

  const int reset = body.indexOf(QStringLiteral("editor_reset"));
  QVERIFY2(reset >= 0, "Discard leaves the document modified");
  // Order inside one `sendSequence` call, which is what the gateway preserves:
  // the reset is the first command, the leave or the open the next.
  QVERIFY2(body.contains(QStringLiteral(
               "sendSequence([{ type: \"editor_reset\" }].concat(following))")),
           "Discard did not send the reset before the workspace change");
  // An Open replaces the document too, and Core refuses to replace one that is
  // dirty, so Discard builds the same reset-then-open sequence for it.
  QVERIFY2(body.contains(QStringLiteral("leave.editorOpen")),
           "Discard does not restart the open it was asked during");
  // Quitting is the exception: the document does not survive the window, and
  // reverting it first would write a preview for a process that is leaving.
  const int quit = body.indexOf(QStringLiteral("runLeave(\"quit\")"));
  QVERIFY2(quit >= 0 && quit < reset, "the quit path resets the document first");
}

/// Opening a second picture used to replace the working document with no
/// question, losing every unsaved edit; opening the *same* picture used to
/// tear it down and decode it again, losing the undo history. Core now refuses
/// to replace a dirty document and treats a reopening as a no-op, so the shell
/// is where the question is asked and every entry point has to go through it.
void TestSettings::theShellAsksBeforeReplacingAnUnsavedDocument()
{
  QFile main(qmlDir() + QStringLiteral("/Main.qml"));
  QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
  const QString source = QString::fromUtf8(main.readAll());

  const int guardStart = source.indexOf(QStringLiteral("function requestEditorOpen("));
  QVERIFY2(guardStart >= 0, "Main.qml has no requestEditorOpen");
  const int guardEnd = source.indexOf(QStringLiteral("\n    }"), guardStart);
  QVERIFY2(guardEnd > guardStart, "requestEditorOpen never closes");
  const QString guard = source.mid(guardStart, guardEnd - guardStart);
  QVERIFY2(guard.contains(QStringLiteral("editorHasUnsavedChanges")),
           "the open does not look at unsaved edits");
  QVERIFY2(guard.contains(QStringLiteral("unsavedDialog.open()")),
           "the open replaces a dirty document without asking");
  QVERIFY2(guard.contains(QStringLiteral("pendingLeave")),
           "the answer has nowhere to be remembered");
  QVERIFY2(guard.contains(QStringLiteral("runEditorOpen(")),
           "the clean path never reaches the open itself");

  // Every way in goes through the guard: the chooser's answer, the two view
  // menus, and the Editor's own Open button (which is the chooser).
  const int handle = source.indexOf(QStringLiteral("root.requestEditorOpen(paths[0])"));
  QVERIFY2(handle >= 0, "the chooser's answer bypasses the guard");
  const int menus = source.count(QStringLiteral("root.requestEditorOpen(path, true)"));
  QVERIFY2(menus == 2,
           qPrintable(QStringLiteral("%1 view menus open the editor without asking")
                          .arg(2 - menus)));
  // The view menus and the chooser are the only three places; a direct
  // `editor_open` outside `editorOpenCommands` would be a fourth, unguarded one.
  const int direct = source.count(QStringLiteral("{ type: \"editor_open\""));
  QVERIFY2(direct == 1,
           qPrintable(QStringLiteral("%1 places build an editor_open command")
                          .arg(direct)));
}

/// `Main.qml` owns the three things the workspaces share about their layout:
/// the copy on screen (so a width dragged in the Browser is the width the
/// Editor opens at), the one command that saves it, and the shell call that
/// reveals a path in the desktop's own file manager. The views only report an
/// interaction (`layoutRequested`, `revealPath`); this pins the shell half,
/// which cannot be instantiated here.
void TestSettings::theShellSharesOneLayoutAndRevealsThroughThePlatform()
{
  QFile main(qmlDir() + QStringLiteral("/Main.qml"));
  QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
  const QString source = QString::fromUtf8(main.readAll());

  // One layout, taken from Core's state and replaced by the preview while the
  // Settings form is open.
  QVERIFY2(source.contains(QStringLiteral("readonly property var activeLayout: root.previewLayout")),
           "the shell does not merge the preview over the saved layout");
  QVERIFY2(source.contains(QStringLiteral("|| root.state.layout")),
           "the saved layout is not the fallback");
  const int wired = source.count(QStringLiteral("layout: root.activeLayout"));
  QVERIFY2(wired == 3,
           qPrintable(QStringLiteral("the shared layout reaches %1 views, expected 3").arg(wired)));
  const int asked = source.count(QStringLiteral("onLayoutRequested: function(patch) { root.requestLayout(patch) }"));
  QVERIFY2(asked == 3,
           qPrintable(QStringLiteral("%1 views ask for a layout change, expected 3").arg(asked)));
  // Two writers, one command: a drag merges its patch into the layout on
  // screen, the form sends the layout it edited. Nothing else writes it.
  const int sent = source.count(QStringLiteral("{ type: \"set_layout\""));
  QVERIFY2(sent == 2,
           qPrintable(QStringLiteral("%1 places send set_layout, expected 2").arg(sent)));
  QVERIFY2(source.contains(QStringLiteral("settingsDialog.adoptLayout(next)")),
           "a change made while the form is open is not previewed there");

  // A layout drag is not a command per pixel: the splitters report on release.
  const QStringList views = { QStringLiteral("BrowserView.qml"),
                              QStringLiteral("Viewer.qml"),
                              QStringLiteral("EditorView.qml") };
  for (const QString& name : views) {
    QFile view(qmlDir() + QLatin1Char('/') + name);
    QVERIFY2(view.open(QIODevice::ReadOnly | QIODevice::Text),
             qPrintable(QStringLiteral("cannot read %1").arg(name)));
    const QString text = QString::fromUtf8(view.readAll());
    QVERIFY2(text.contains(QStringLiteral("signal layoutRequested(var patch)")),
             qPrintable(QStringLiteral("%1 has no layout channel").arg(name)));
    QVERIFY2(text.contains(QStringLiteral("onReleased: function(width)")),
             qPrintable(QStringLiteral("%1 saves a drag before it ends").arg(name)));
  }

  const int reveal = source.count(
    QStringLiteral("onRevealPath: function(path) { Platform.revealInFolder(path); }"));
  QVERIFY2(reveal == 3,
           qPrintable(QStringLiteral("%1 reveal requests reach the platform, expected 3")
                        .arg(reveal)));
}

/// Panel visibility has exactly one home: Settings › Appearance. The four
/// sections are drawn from `SettingsDialog.qml`'s own lists, the shell seeds the
/// form from the saved layout and sends it back through `set_layout`, and no
/// workspace carries a checkbox, a gutter or a toolbar button of its own.
/// Settings › Appearance is where the layout is edited. A row is a preview,
/// Apply asks the shell to persist the layout *with* the rest of the form, and
/// "Reset layout" restores Core's own defaults — the same numbers, not a second
/// copy that drifts.
void TestSettings::theAppearanceSectionsEditAndSaveTheLayout()
{
  m_dialog->setProperty("initialLayout",
                        QVariantMap{
                          {QStringLiteral("leftWidth"), 260},
                          {QStringLiteral("rightWidth"), 300},
                          {QStringLiteral("editorToolColumns"), 2},
                          {QStringLiteral("editorReferenceHeight"), 0},
                          {QStringLiteral("editorReferenceTab"), QStringLiteral("info")},
                          {QStringLiteral("panels"),
                           QVariantMap{{QStringLiteral("browser.quickAccess"), true}}}});
  openDialog();

  QSignalSpy previews(m_dialog, SIGNAL(layoutPreviewRequested(QVariant)));
  QSignalSpy saves(m_dialog, SIGNAL(layoutSaveRequested(QVariant)));

  // Four sections, each with its own page; the strip's `onActivated` writes
  // `section`, which is what this does.
  const QVector<QPair<QString, QString>> sections = {
    {QStringLiteral("general"), QStringLiteral("settingsGeneralPage")},
    {QStringLiteral("browser"), QStringLiteral("settingsBrowserPage")},
    {QStringLiteral("editor"), QStringLiteral("settingsEditorPage")},
    {QStringLiteral("viewer"), QStringLiteral("settingsViewerPage")}};
  for (const auto& section : sections) {
    m_dialog->setProperty("section", section.first);
    QTest::qWait(20);
    QQuickItem* page = item(section.second.toUtf8().constData());
    QVERIFY2(page != nullptr,
             qPrintable(QStringLiteral("the %1 section has no page").arg(section.first)));
    QVERIFY2(page->isVisible(),
             qPrintable(QStringLiteral("the %1 page is not drawn for its section")
                          .arg(section.first)));
  }

  // One panel row: the first Browser checkbox is `browser.quickAccess`. Toggling
  // it previews the new layout without writing anything.
  m_dialog->setProperty("section", QStringLiteral("browser"));
  QTest::qWait(20);
  QQuickItem* page = item("settingsBrowserPage");
  QVERIFY(page != nullptr);
  QQuickItem* row = firstCheckBox(page);
  QVERIFY2(row != nullptr, "the Browser section offers no panel rows");
  QVERIFY2(row->property("checked").toBool(), "the saved visible panel opened unchecked");

  // A `CheckBox` inside a `Popup` resolves the platform palette, so the stock
  // content item drew near-black words on this dark form. The row now draws its
  // own label in the theme's colour, and that is the fact asserted here: the
  // text is the panel's name and it is legible against the dialog's surface.
  QQuickItem* content = row->property("contentItem").value<QQuickItem*>();
  QVERIFY2(content != nullptr, "the panel row draws no content item");
  QVERIFY2(content->property("text").toString() == row->property("text").toString(),
           "the panel row's words are not its panel's name");
  QObject* theme = m_dialog->property("theme").value<QObject*>();
  QVERIFY2(theme != nullptr, "the form has no theme to draw with");
  const QColor label = content->property("color").value<QColor>();
  const QColor surface = theme->property("surface").value<QColor>();
  QCOMPARE(label, theme->property("text").value<QColor>());
  QVERIFY2(qAbs(label.lightnessF() - surface.lightnessF()) > 0.35,
           qPrintable(QStringLiteral("the panel row's words are not legible: %1 on %2")
                        .arg(label.name(), surface.name())));
  const QPoint rowCentre =
    row->mapToScene(QPointF(row->width() / 2.0, row->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, rowCentre);
  QTest::qWait(30);
  QVERIFY2(previews.count() >= 1, "a panel row did not preview its layout");
  const QVariantMap previewed = previews.last().at(0).toMap();
  QCOMPARE(previewed.value(QStringLiteral("panels")).toMap()
             .value(QStringLiteral("browser.quickAccess")).toBool(),
           false);
  QCOMPARE(saves.count(), 0);

  // Apply saves the form, layout included, and stays open.
  QQuickItem* apply = item("settingsApply");
  QVERIFY(apply != nullptr);
  QVERIFY2(apply->isEnabled(), "Apply is disabled with a pending panel change");
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier,
                    apply->mapToScene(QPointF(apply->width() / 2.0,
                                              apply->height() / 2.0)).toPoint());
  QTest::qWait(40);
  QCOMPARE(saves.count(), 1);
  const QVariantMap saved = saves.last().at(0).toMap();
  QCOMPARE(saved.value(QStringLiteral("leftWidth")).toInt(), 260);
  QCOMPARE(saved.value(QStringLiteral("panels")).toMap()
             .value(QStringLiteral("browser.quickAccess")).toBool(),
           false);
  QVERIFY2(!m_dialog->property("hasPendingChanges").toBool(),
           "Apply left the form with the change still pending");
  QVERIFY(dialogVisible());

  // "Reset layout" is a preview of Core's defaults, not a save: every panel
  // back on, the shared left dock at 260 (the protocol's own default), the
  // reference dock content-sized again.
  m_dialog->setProperty("section", QStringLiteral("general"));
  QTest::qWait(20);
  QQuickItem* reset = item("settingsResetLayout");
  QVERIFY(reset != nullptr);
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier,
                    reset->mapToScene(QPointF(reset->width() / 2.0,
                                              reset->height() / 2.0)).toPoint());
  QTest::qWait(30);
  const QVariantMap defaults = m_dialog->property("editedLayout").toMap();
  QCOMPARE(defaults.value(QStringLiteral("leftWidth")).toInt(), 260);
  QCOMPARE(defaults.value(QStringLiteral("rightWidth")).toInt(), 300);
  QCOMPARE(defaults.value(QStringLiteral("editorToolColumns")).toInt(), 2);
  QCOMPARE(defaults.value(QStringLiteral("editorReferenceHeight")).toInt(), 0);
  QCOMPARE(defaults.value(QStringLiteral("editorReferenceTab")).toString(),
           QStringLiteral("info"));
  const QVariantMap panels = defaults.value(QStringLiteral("panels")).toMap();
  QCOMPARE(panels.size(), 12);
  QCOMPARE(panels.value(QStringLiteral("browser.quickAccess")).toBool(), true);
  QCOMPARE(saves.count(), 1);
}

void TestSettings::theShellKeepsThePanelListInSettings()
{
  QFile dialog(qmlDir() + QStringLiteral("/SettingsDialog.qml"));
  QVERIFY2(dialog.open(QIODevice::ReadOnly | QIODevice::Text), "SettingsDialog.qml is missing");
  const QString form = QString::fromUtf8(dialog.readAll());

  QVERIFY2(form.contains(QStringLiteral("readonly property var sections")),
           "the form has no section strip");
  const QStringList sections = { QStringLiteral("general"), QStringLiteral("browser"),
                                 QStringLiteral("editor"), QStringLiteral("viewer") };
  for (const QString& key : sections) {
    QVERIFY2(form.contains(QStringLiteral("key: \"%1\"").arg(key)),
             qPrintable(QStringLiteral("the form has no %1 section").arg(key)));
  }
  // Every key the protocol knows must be offered, or a panel Core remembers
  // could never be switched again.
  const QStringList keys = {
    QStringLiteral("browser.quickAccess"),  QStringLiteral("browser.explorer"),
    QStringLiteral("browser.preview"),      QStringLiteral("browser.batch"),
    QStringLiteral("viewer.info"),          QStringLiteral("editor.quickAccess"),
    QStringLiteral("editor.explorer"),      QStringLiteral("editor.tools"),
    QStringLiteral("editor.options"),       QStringLiteral("editor.info"),
    QStringLiteral("editor.history"),       QStringLiteral("editor.original")
  };
  for (const QString& key : keys) {
    QVERIFY2(form.contains(QLatin1Char('"') + key + QLatin1Char('"')),
             qPrintable(QStringLiteral("the form never offers %1").arg(key)));
  }
  QVERIFY2(form.contains(QStringLiteral("signal layoutSaveRequested(var layout)")),
           "the form cannot save a layout");
  QVERIFY2(form.contains(QStringLiteral("function adoptLayout(layout)")),
           "a dock change made behind the form is not adopted");

  QFile main(qmlDir() + QStringLiteral("/Main.qml"));
  QVERIFY2(main.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
  const QString source = QString::fromUtf8(main.readAll());
  QVERIFY2(source.contains(QStringLiteral("settingsDialog.initialLayout = JSON.parse(JSON.stringify(root.state.layout")),
           "the form does not open on the saved layout");
  QVERIFY2(source.contains(QStringLiteral("onLayoutPreviewRequested: function(layout)")),
           "the form's preview never reaches the window");
  QVERIFY2(source.contains(QStringLiteral("onLayoutSaveRequested: function(layout)")),
           "the form's save never reaches Core");
  QVERIFY2(!source.contains(QStringLiteral("title: qsTr(\"View\")")),
           "the burger menu still has a View submenu");
  QVERIFY2(!source.contains(QStringLiteral("workspacePanelEntries")),
           "the shell still draws a panel menu");

  const QStringList views = { QStringLiteral("BrowserView.qml"),
                              QStringLiteral("Viewer.qml"),
                              QStringLiteral("EditorView.qml") };
  for (const QString& name : views) {
    QFile view(qmlDir() + QLatin1Char('/') + name);
    QVERIFY2(view.open(QIODevice::ReadOnly | QIODevice::Text),
             qPrintable(QStringLiteral("cannot read %1").arg(name)));
    const QString text = QString::fromUtf8(view.readAll());
    QVERIFY2(!text.contains(QStringLiteral("toggle_right_panel")),
             qPrintable(QStringLiteral("%1 still sends a sidebar toggle command").arg(name)));
    QVERIFY2(!text.contains(QStringLiteral("PanelMenu")),
             qPrintable(QStringLiteral("%1 still draws the checklist gutter").arg(name)));
    QVERIFY2(!text.contains(QStringLiteral("sidebar-show-right-symbolic")),
             qPrintable(QStringLiteral("%1 still has a sidebar toolbar/menu button").arg(name)));
    QVERIFY2(!text.contains(QStringLiteral("readonly property var panelEntries")),
             qPrintable(QStringLiteral("%1 still publishes a menu-fed panel list").arg(name)));
  }

  // The Editor's reference dock is content-sized at the bottom: a fixed
  // tool-zone height would contradict "only as tall as the page needs".
  QFile editor(qmlDir() + QStringLiteral("/EditorView.qml"));
  QVERIFY(editor.open(QIODevice::ReadOnly | QIODevice::Text));
  const QString editorText = QString::fromUtf8(editor.readAll());
  QVERIFY2(!editorText.contains(QStringLiteral("toolZoneHeight")),
           "the Editor still has a fixed tool frame");
  QVERIFY2(editorText.contains(QStringLiteral("editorReferenceHeight")),
           "the reference dock's dragged height is not a layout value");
}

QTEST_MAIN(TestSettings)
#include "tst_settings.moc"
