// Editor workspace tests: the view renders the published Editor state and turns
// clicks into explicit editor_* commands. Core owns the document; these tests
// load the real `crates/desktop/qml/EditorView.qml` (plus its toolbar Component)
// into a real `QQuickView` and feed it snapshots, exactly the way the shipped
// binary hangs it off the window.
//
// The view disables a tool unless the snapshot says the command can work, so a
// dead click (no command) is the same bug a user sees; asserting the emitted
// commands is the point. What a green run does NOT prove: that the preview looks
// right, that the icons resolve (offscreen loads no icon theme), or that Core
// accepts the commands — those need the real window and the Core tests.

#include <QColor>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickView>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QVariantMap>
#include <QWheelEvent>

#include "stubthumbnailcache.h"

namespace {

QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}

constexpr int kHostWidth = 1100;
constexpr int kHostHeight = 700;

} // namespace

class TestEditor : public QObject
{
  Q_OBJECT
private slots:
  void initTestCase();
  void init();
  void theResizeDialogStartsFromTheDocumentSize();
  void theResizeDialogIsCentredWhileItOpens();
  void thePointerShowsTheDocumentAndHistory();
  void emptyStateOffersToOpenAnImage();
  void theCanvasPaintsTheOpeningPreviewWhileTheDocumentDecodes();
  void theViewFollowsThePublishedDocument();
  void rotateAndFlipEmitTypedCommands();
  void undoRedoResetAndCloseEmitCommands();
  void resizeApplyEmitsTheTypedSize();
  void theResizePresetsAreMultiplesOf64();
  void typingOneSideKeepsTheChosenRatio();
  void theCurrentRatioLocksTheTypedPair();
  void theSizeSteppersNudgeBothSides();
  void resizeCarriesThePadFill();
  void theResizeDialogHasNoPreviewSurfaces();
  void thePaintToolSendsOneStrokeOnRelease();
  void theEraserStrokeCarriesItsModeAndBrush();
  void theKritaKeysPickTheToolsAndAdjustTheBrush();
  void ctrlZUndoesAndCtrlShiftZRedoes();
  void spacePansInsteadOfPainting();
  void thePointerThumbnailCarriesThePreviewIdentity();
  void cropApplyEmitsTheTypedRectangle();
  void theCropPresetsFitInsideTheDocument();
  void theCropRatioLinksTheSides();
  void theCropAnchorPlacesTheRectangle();
  void theLiveCropShowsOnlyItsOwnDraft();
  void theCropFrameIsDrawnAndDragged();
  void theCropFrameHidesWhileItsPreviewIsOn();
  void theTransformToolDragsCornersAndEdges();
  void theLiveTransformShowsOnlyItsOwnDraft();
  void anInvalidOrEmptySizeKeepsApplyDisabled();
  void thePaletteHoldsTheToolsAndTheInspectorTheirOptions();
  void thePaletteSelectsTheToolsOptions();
  void resetClearsTheToolFields();
  void saveAndSaveAsEmitTheirCommands();
  void toolbarTooltipsNameTheirShortcuts();
  void saveAsSuggestsTheCurrentLocation();
  void exportIsACopyWithItsOwnQualityAndMetadata();
  void exportOffersADeliverySize();
  void canvasSupportsViewerStyleZoomAndPan();
  void aLargePicturePansFreelyInBothAxes();
  void thePanHandlerTakesTouchpadsAndMiddleClicks();
  void aTouchpadWheelZoomsTheCanvasAtTheCursor();
  void aFittedDocumentFollowsTheWindowResize();
  void aManualZoomSurvivesTheWindowResize();

private:
  QQuickItem* visualItem(const QString& name) const;
  QObject* findObject(const QString& name) const;
  static QVariant readQml(QObject* object, const QString& expression);
  void clickItem(QQuickItem* item);
  /// Click a control that closes the Resize form and wait for its modal overlay
  /// to be gone. `opened` goes false one frame before the dim overlay does, and
  /// a click that lands in that frame belongs to the overlay.
  void closeResizeDialog(QQuickItem* control);
  void dragScene(const QPointF& from, const QPointF& to, int steps = 6);
  void typeInto(QQuickItem* field, const QString& text);
  void selectTool(const char* name);
  QObject* resizeDialogObject() const;
  void openResizeDialog();
  QVariantList commands() const { return m_commands->takeFirst(); }
  QVariantMap documentState() const;
  void setState(const QVariantMap& editor);
  QQuickItem* expectItem(const char* name) const;

  QQmlEngine m_engine;
  QQuickView* m_view = nullptr;
  QQuickItem* m_editor = nullptr;
  QObject* m_toolbar = nullptr;
  QSignalSpy* m_commands = nullptr;
  QSignalSpy* m_requestOpen = nullptr;
  QTemporaryDir m_host;
  QString m_previewOne;
  QString m_previewTwo;
};

void TestEditor::initTestCase()
{
  QVERIFY(m_host.isValid());
  const QString hostPath = m_host.path() + QStringLiteral("/host.qml");
  {
    QFile file(hostPath);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Text));
    file.write(QStringLiteral("import QtQuick\n"
                              "Item { objectName: \"editorHost\" }\n")
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

  const QString editorPath = qmlDir() + QStringLiteral("/EditorView.qml");
  QQmlComponent component(&m_engine, QUrl::fromLocalFile(editorPath));
  QVERIFY2(component.isReady(), qPrintable(component.errorString()));
  m_editor = qobject_cast<QQuickItem*>(component.create());
  QVERIFY(m_editor != nullptr);

  m_editor->setParentItem(qobject_cast<QQuickItem*>(m_view->rootObject()));
  m_editor->setWidth(kHostWidth);
  m_editor->setHeight(kHostHeight);

  // The toolbar is a Component the workspace exposes; Main.qml instantiates it.
  QObject* toolbarComponentObject = m_editor->property("toolbar").value<QObject*>();
  QVERIFY(toolbarComponentObject != nullptr);
  QQmlComponent* toolbarComponent = qobject_cast<QQmlComponent*>(toolbarComponentObject);
  QVERIFY(toolbarComponent != nullptr);
  // The toolbar Component was declared inside EditorView.qml, so its creation
  // context is the one that knows `view`; the Loader in Main.qml gets the same
  // resolution through the workspace loader.
  QVERIFY(toolbarComponent->creationContext() != nullptr);
  QObject* toolbarObject = toolbarComponent->create(toolbarComponent->creationContext());
  QVERIFY(toolbarObject != nullptr);
  QQuickItem* toolbarItem = qobject_cast<QQuickItem*>(toolbarObject);
  QVERIFY(toolbarItem != nullptr);
  m_toolbar = toolbarObject;
  toolbarItem->setParentItem(qobject_cast<QQuickItem*>(m_view->rootObject()));
  toolbarItem->setWidth(kHostWidth);
  toolbarItem->setHeight(50);

  m_previewOne = m_host.path() + QStringLiteral("/preview-1.png");
  m_previewTwo = m_host.path() + QStringLiteral("/preview-2.png");
  for (const QString& path : {m_previewOne, m_previewTwo}) {
    QImage image(40, 20, QImage::Format_RGB32);
    image.fill(Qt::magenta);
    QVERIFY2(image.save(path, "PNG"), qPrintable(path));
  }

  m_commands = new QSignalSpy(m_editor, SIGNAL(command(QVariant)));
  m_requestOpen = new QSignalSpy(m_editor, SIGNAL(requestOpen()));
  QVERIFY(m_commands->isValid());
  QVERIFY(m_requestOpen->isValid());
}

void TestEditor::init()
{
  // Cases start with empty tool fields. Which tool is selected is view state;
  // a case that needs Crop selects it, and the pointer default is asserted by
  // the first case before anything changes it.
  m_editor->setProperty("tool", QStringLiteral("pointer"));
  // The editor's forms are modal: a case that failed mid-form would otherwise
  // leave one blocking the next one's clicks. Both refill themselves from the
  // document on every open, so closing them is enough. `opened` goes false
  // before a popup's dim overlay is gone, and a click that lands during that
  // fade belongs to the overlay, so wait for the window to be free — exactly
  // as a person cannot click twice in the same frame.
  for (const char* name : {"resizeDialog", "exportDialog"}) {
    QObject* dialog = findObject(QString::fromLatin1(name));
    if (dialog == nullptr) {
      continue;
    }
    if (dialog->property("visible").toBool()) {
      QMetaObject::invokeMethod(dialog, "close");
    }
    QTRY_VERIFY_WITH_TIMEOUT(!dialog->property("visible").toBool(), 2000);
    if (qstrcmp(name, "resizeDialog") == 0) {
      dialog->setProperty("fillColor", QColor(QStringLiteral("#ffffff")));
    }
  }
  for (const char* name : {"cropWidth", "cropHeight"}) {
    if (QQuickItem* field = visualItem(QString::fromLatin1(name))) {
      field->setProperty("text", QString());
    }
  }
  for (const char* name : {"cropX", "cropY"}) {
    if (QQuickItem* field = visualItem(QString::fromLatin1(name))) {
      field->setProperty("text", QStringLiteral("0"));
    }
  }
  // Crop's options are view state, and a case that changed them must not
  // decide what the next one sees. The toggles also own a `checked` the control
  // writes itself, so reset both sides.
  m_editor->setProperty("cropRatio", QStringLiteral("original"));
  m_editor->setProperty("cropAnchor", QStringLiteral("center"));
  m_editor->setProperty("cropLivePreview", false);
  m_editor->setProperty("cropCurrentRatio",
                        QVariantMap{{QStringLiteral("width"), 0},
                                    {QStringLiteral("height"), 0}});
  m_editor->setProperty("transformLivePreview", false);
  m_editor->setProperty("transformCorners", QVariantList());
  m_editor->setProperty("paintMode", QStringLiteral("brush"));
  m_editor->setProperty("paintColor", QStringLiteral("#000000"));
  m_editor->setProperty("paintBackgroundColor", QStringLiteral("#ffffff"));
  m_editor->setProperty("paintSize", 24.0);
  m_editor->setProperty("paintOpacity", 100);
  m_editor->setProperty("paintStroke", QVariantList());
  m_editor->setProperty("paintStroking", false);
  m_editor->setProperty("panelsHidden", false);
  m_editor->setProperty("spacePanning", false);
  m_editor->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
  for (const char* name : {"cropLivePreviewButton", "transformLivePreviewButton"}) {
    if (QQuickItem* toggle = visualItem(QString::fromLatin1(name))) {
      toggle->setProperty("checked", false);
    }
  }
}

QObject* TestEditor::findObject(const QString& name) const
{
  QList<QObject*> pending{m_view->rootObject()};
  while (!pending.isEmpty()) {
    QObject* candidate = pending.takeFirst();
    if (candidate->objectName() == name) {
      return candidate;
    }
    pending.append(candidate->children());
    // Items created from C++ are not always QObject children of their visual
    // parent, so walk the visual tree as well.
    if (auto* item = qobject_cast<QQuickItem*>(candidate)) {
      const auto children = item->childItems();
      for (QQuickItem* child : children) {
        pending.append(child);
      }
    }
  }
  return nullptr;
}

QQuickItem* TestEditor::visualItem(const QString& name) const
{
  return qobject_cast<QQuickItem*>(findObject(name));
}

QVariant TestEditor::readQml(QObject* object, const QString& expression)
{
  QQmlExpression reader(QQmlEngine::contextForObject(object), object, expression);
  return reader.evaluate();
}

QQuickItem* TestEditor::expectItem(const char* name) const
{
  QQuickItem* item = visualItem(QString::fromLatin1(name));
  if (!item)
    qFatal("expected item %s was not found", name);
  return item;
}

void TestEditor::closeResizeDialog(QQuickItem* control)
{
  clickItem(control);
  QObject* dialog = resizeDialogObject();
  QTRY_VERIFY_WITH_TIMEOUT(!dialog->property("visible").toBool(), 2000);
}

void TestEditor::clickItem(QQuickItem* item)
{
  QVERIFY(item != nullptr);
  QVERIFY2(item->isVisible(), qPrintable(item->objectName()));
  const QPoint centre =
    item->mapToScene(QPointF(item->width() / 2.0, item->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(20);
}

/// A real left-button drag through the view: several small moves that keep the
/// press's implicit grab, the way a hand moves rather than a teleporting
/// cursor. Both overlays drive their own `MouseArea`, so this is the same path
/// a pointer takes; a handler that is not armed fails the assertion, not the
/// event injection.
void TestEditor::dragScene(const QPointF& from, const QPointF& to, int steps)
{
  const QPoint start = from.toPoint();
  QTest::mouseMove(m_view, start);
  QTest::qWait(20);
  QTest::mousePress(m_view, Qt::LeftButton, Qt::NoModifier, start);
  QCoreApplication::processEvents();
  for (int step = 1; step <= steps; ++step) {
    const QPoint point =
      (from + (to - from) * (static_cast<double>(step) / steps)).toPoint();
    QTest::mouseMove(m_view, point);
    QCoreApplication::processEvents();
  }
  QTest::mouseRelease(m_view, Qt::LeftButton, Qt::NoModifier, to.toPoint());
  QCoreApplication::processEvents();
  QTest::qWait(20);
}

/// Type into a field the way a hand does: focus it, select what is there and
/// key the new value in. Setting `text` from C++ is not the same path: it does
/// not emit `textEdited`, so it would skip the ratio link the user gets.
void TestEditor::typeInto(QQuickItem* field, const QString& text)
{
  QVERIFY(field != nullptr);
  field->forceActiveFocus();
  QTest::qWait(10);
  QTest::keyClick(m_view, Qt::Key_A, Qt::ControlModifier);
  for (const QChar character : text) {
    QTest::keyClick(m_view, static_cast<Qt::Key>(character.unicode()));
  }
  QTest::qWait(20);
}

/// Select a tool through the palette. Clicking the already selected Resize or
/// Crop returns to the pointer, so a case that merely wants a tool must not
/// click its button twice.
void TestEditor::selectTool(const char* name)
{
  const QString wanted = QString::fromLatin1(name);
  if (m_editor->property("tool").toString() == wanted) {
    return;
  }
  const QString button = QStringLiteral("tool") + wanted.left(1).toUpper() + wanted.mid(1);
  clickItem(expectItem(button.toLatin1().constData()));
  QCOMPARE(m_editor->property("tool").toString(), wanted);
}

QObject* TestEditor::resizeDialogObject() const
{
  QObject* dialog = findObject(QStringLiteral("resizeDialog"));
  if (dialog == nullptr) {
    qFatal("expected the Resize dialog was not found");
  }
  return dialog;
}

/// Resize is a dialog now, not a tool on the canvas: its palette button opens
/// the form, and the editor stays on the pointer while the form is up. Every
/// resize case starts here, so the folder path is exercised by the suite.
void TestEditor::openResizeDialog()
{
  QObject* dialog = resizeDialogObject();
  // A form that has just been answered is still fading out for a frame, and
  // its modal overlay takes the next click. Wait until the window is free
  // before pressing the palette button.
  // A form that has just been answered is still fading out for a frame, and
  // its modal overlay takes the next click. Wait until the window is free
  // before pressing the palette button.
  QTRY_VERIFY_WITH_TIMEOUT(!dialog->property("visible").toBool(), 2000);
  clickItem(expectItem("toolResize"));
  QTRY_VERIFY2(dialog->property("opened").toBool(), "the Resize dialog did not open");
  // Opening a form is not choosing a tool: the canvas stays on the pointer and
  // the palette button stays lit so the form has a visible source.
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QVERIFY(expectItem("toolResize")->property("highlighted").toBool());
}

QVariantMap TestEditor::documentState() const
{
  QVariantMap editor;
  editor.insert(QStringLiteral("path"), QStringLiteral("/pics/photo.png"));
  editor.insert(QStringLiteral("name"), QStringLiteral("photo.png"));
  editor.insert(QStringLiteral("width"), 4000);
  editor.insert(QStringLiteral("height"), 3000);
  editor.insert(QStringLiteral("canUndo"), false);
  editor.insert(QStringLiteral("canRedo"), false);
  editor.insert(QStringLiteral("modified"), false);
  editor.insert(QStringLiteral("history"), QVariantList{});
  editor.insert(QStringLiteral("redoCount"), 0);
  editor.insert(QStringLiteral("previewPath"), m_previewOne);
  editor.insert(QStringLiteral("previewRevision"), 1);
  editor.insert(QStringLiteral("previewModified"), Q_INT64_C(1700000000001));
  editor.insert(QStringLiteral("previewSize"), Q_INT64_C(2048));
  editor.insert(QStringLiteral("previewDraft"), QVariant());
  editor.insert(QStringLiteral("rendering"), false);
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/photo.png"));
  editor.insert(QStringLiteral("saved"), true);
  editor.insert(QStringLiteral("format"), QStringLiteral(".png"));
  editor.insert(QStringLiteral("saving"), false);
  editor.insert(QStringLiteral("opening"), false);
  return editor;
}

void TestEditor::setState(const QVariantMap& editor)
{
  m_commands->clear();
  m_requestOpen->clear();
  QVariantMap state;
  state.insert(QStringLiteral("editor"), editor);
  m_editor->setProperty("state", state);
  QTest::qWait(40);
}

void TestEditor::theResizeDialogStartsFromTheDocumentSize()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();

  // The form describes what is on screen before anything is typed: the
  // document's own pair, so the steppers start from a real number.
  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  QQuickItem* preset = expectItem("resizeSizePreset");
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(preset->property("currentIndex").toInt(), -1);
  QCOMPARE(preset->property("displayText").toString(), QStringLiteral("Custom"));

  // That pair is Core's no-op, so Apply says so before it is pressed.
  QVERIFY(!expectItem("resizeApply")->property("enabled").toBool());

  // The switch sits on the dialog's own dark surface. Its label comes from the
  // theme, not from the platform palette: a Popup built inside the workspace's
  // Loader resolves the platform's light palette, and the first screenshot of
  // this form showed the label dark-on-dark.
  const QColor themeText = readQml(m_editor, "theme.text").value<QColor>();
  QQuickItem* box = expectItem("resizePadToFit");
  QCOMPARE(readQml(box, "contentItem.color").value<QColor>(), themeText);
  QVERIFY(box->property("contentItem").value<QObject*>() != nullptr);

  // The whole form fits the dialog at the test host's size. `isVisible` does
  // not notice clipping by the Flickable, so this is the measurement that
  // catches a control hidden under the footer.
  QQuickItem* content = expectItem("resizeContent");
  QQuickItem* column = expectItem("resizeColumn");
  QVERIFY2(column->implicitHeight() + 40 <= content->height(),
           qPrintable(QStringLiteral("the form is %1 px tall in a %2 px viewport")
                          .arg(column->implicitHeight() + 40)
                          .arg(content->height())));

  // Reset is the same fresh state, and it sends nothing.
  width->setProperty("text", QStringLiteral("800"));
  height->setProperty("text", QStringLiteral("600"));
  QTest::qWait(20);
  QVERIFY(expectItem("resizeApply")->property("enabled").toBool());
  clickItem(expectItem("resizeReset"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(m_commands->count(), 0);
}

/// The style's enter transition is what exposed this: `opened` is emitted only
/// after it finishes, and for ~300 ms before that the popup was already visible
/// at the positioner's default corner before jumping to the centre. The case
/// installs a slow transition so it can inspect the first visible frame.
void TestEditor::theResizeDialogIsCentredWhileItOpens()
{
  setState(documentState());  // 4000 × 3000
  QObject* dialog = resizeDialogObject();
  const QVariant originalEnter = dialog->property("enter");
  // A failure must not leave the custom transition or an open modal behind for
  // the next case, so the cleanup runs on the failing path too.
  const auto restoreDialog = qScopeGuard([dialog, originalEnter]() {
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
  context.setContextProperty(QStringLiteral("__dialogUnderTest"), dialog);
  QQmlExpression slowEnter(
    &context, dialog,
    QStringLiteral("__dialogUnderTest.enter = Qt.createQmlObject("
                   "'import QtQuick; Transition { NumberAnimation { "
                   "property: \"opacity\"; from: 0; to: 1; duration: 600 } }', "
                   "__dialogUnderTest)"));
  slowEnter.evaluate();
  QVERIFY2(!slowEnter.hasError(), qPrintable(slowEnter.error().toString()));

  // Test setup can centre the form through an earlier width/height change.
  // Start from a corner, as the positioner does before `aboutToShow`, so this
  // case observes what the first visible frame really does.
  dialog->setProperty("x", 0.0);
  dialog->setProperty("y", 0.0);
  QCoreApplication::processEvents();

  clickItem(expectItem("toolResize"));
  QTRY_VERIFY_WITH_TIMEOUT(dialog->property("visible").toBool(), 1000);
  QVERIFY2(!dialog->property("opened").toBool(),
           "the enter transition finished before the first visible frame could be inspected");

  QQuickItem* parent = dialog->property("parent").value<QQuickItem*>();
  QVERIFY(parent != nullptr);
  const qreal expectedX =
    qRound((parent->width() - dialog->property("width").toDouble()) / 2.0);
  const qreal expectedY =
    qRound((parent->height() - dialog->property("height").toDouble()) / 2.0);
  QCOMPARE(dialog->property("x").toDouble(), expectedX);
  QCOMPARE(dialog->property("y").toDouble(), expectedY);
  // The form is filled before it is visible too, not only after the fade.
  QCOMPARE(expectItem("resizeWidth")->property("text").toString(), QStringLiteral("4000"));

  QTRY_VERIFY_WITH_TIMEOUT(dialog->property("opened").toBool(), 2000);
}

void TestEditor::thePointerShowsTheDocumentAndHistory()
{
  // A fresh Editor opens on the pointer: no tool, no Apply button, and the
  // Resize form stays closed until its palette button asks for it.
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QVERIFY(!resizeDialogObject()->property("opened").toBool());
  QVERIFY(!expectItem("applyCrop")->isVisible());

  QVariantMap editor = documentState();
  // Core publishes each history row as a code plus its numbers, never as an
  // English sentence: the wording is the interface language's business. A view
  // that printed the object would show "[object Object]" here.
  editor.insert(QStringLiteral("history"),
                QVariantList{QVariantMap{{QStringLiteral("code"), QStringLiteral("rotate_right")},
                                         {QStringLiteral("args"), QVariantList{}}},
                             QVariantMap{{QStringLiteral("code"), QStringLiteral("crop")},
                                         {QStringLiteral("args"),
                                          QVariantList{QStringLiteral("10"),
                                                       QStringLiteral("8"),
                                                       QStringLiteral("4"),
                                                       QStringLiteral("2")}}}});
  editor.insert(QStringLiteral("modified"), true);
  setState(editor);

  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Pointer"));
  QVERIFY(expectItem("imageName")->isVisible());
  QVERIFY(expectItem("imageSize")->isVisible());
  QVERIFY(expectItem("saveTarget")->isVisible());
  QVERIFY(expectItem("pointerThumbnail")->isVisible());
  QCOMPARE(expectItem("historyList")->property("count").toInt(), 2);
  QCOMPARE(expectItem("historyLine0")->property("text").toString(),
           QStringLiteral("1. ")
               + QCoreApplication::translate("UiLines", "Rotate right 90°"));
  QCOMPARE(expectItem("historyLine1")->property("text").toString(),
           QStringLiteral("2. ")
               + QCoreApplication::translate("UiLines", "Crop %1 × %2 at %3,%4")
                     .arg(QStringLiteral("10"))
                     .arg(QStringLiteral("8"))
                     .arg(QStringLiteral("4"))
                     .arg(QStringLiteral("2")));
  QCOMPARE(m_commands->count(), 0);
}

void TestEditor::emptyStateOffersToOpenAnImage()
{
  setState(QVariantMap{});  // no document
  QVERIFY(!m_editor->property("hasDocument").toBool());

  QQuickItem* open = expectItem("editorOpenButton");
  QQuickItem* rotate = expectItem("editsRotateLeft");
  QVERIFY(!rotate->property("enabled").toBool());
  QVERIFY(expectItem("toolPointer")->property("enabled").toBool());
  QVERIFY(!expectItem("toolResize")->property("enabled").toBool());
  QVERIFY(!expectItem("toolCrop")->property("enabled").toBool());

  clickItem(open);
  QCOMPARE(m_requestOpen->count(), 1);
  QCOMPARE(m_commands->count(), 0);
}

void TestEditor::theCanvasPaintsTheOpeningPreviewWhileTheDocumentDecodes()
{
  // A large JPEG is decoded twice: first at a reduced DCT scale, so the window
  // can draw the picture in about a third of the wait, then at full resolution
  // for the pixels an edit needs. While the second decode runs the published
  // state is the document's size with `opening: true`.
  QVariantMap opening = documentState();
  opening.insert(QStringLiteral("opening"), true);
  opening.insert(QStringLiteral("rendering"), true);
  opening.insert(QStringLiteral("previewPath"), m_previewTwo);
  setState(opening);

  QVERIFY(m_editor->property("hasDocument").toBool());
  QVERIFY(m_editor->property("opening").toBool());
  QVERIFY(!m_editor->property("documentReady").toBool());

  // The picture is already on the canvas, at the document's own size, so
  // nothing jumps when the full frame replaces the soft decode.
  QQuickItem* canvas = expectItem("canvas");
  QVERIFY(canvas->property("visible").toBool());
  QVERIFY2(canvas->property("source").toString().endsWith(QStringLiteral("preview-2.png")),
           qPrintable(canvas->property("source").toString()));
  QCOMPARE(m_editor->property("documentWidth").toReal(), 4000.0);
  QCOMPARE(m_editor->property("documentHeight").toReal(), 3000.0);

  // The tools wait: Core has no pixels yet, so a click could only be refused.
  QVERIFY(!expectItem("editsRotateLeft")->property("enabled").toBool());
  QVERIFY(!expectItem("toolResize")->property("enabled").toBool());
  QCOMPARE(m_commands->count(), 0);

  // The full frame lands.
  QVariantMap ready = documentState();
  ready.insert(QStringLiteral("previewPath"), m_previewTwo);
  setState(ready);
  QVERIFY(!m_editor->property("opening").toBool());
  QVERIFY(m_editor->property("documentReady").toBool());
  QVERIFY(expectItem("editsRotateLeft")->property("enabled").toBool());
  QVERIFY(expectItem("toolResize")->property("enabled").toBool());
  QVERIFY2(expectItem("canvas")->property("source").toString().endsWith(
               QStringLiteral("preview-2.png")),
           "the canvas lost the picture when the document landed");
}

void TestEditor::theViewFollowsThePublishedDocument()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("previewPath"), m_previewTwo);
  setState(editor);

  QVERIFY(m_editor->property("hasDocument").toBool());
  QVERIFY(!m_editor->property("modified").toBool());

  QQuickItem* rotate = expectItem("editsRotateLeft");
  QVERIFY(rotate->property("enabled").toBool());
  QQuickItem* undo = expectItem("undoButton");
  QQuickItem* redo = expectItem("redoButton");
  QQuickItem* reset = expectItem("resetButton");
  QVERIFY(!undo->property("enabled").toBool());
  QVERIFY(!redo->property("enabled").toBool());
  QVERIFY(!reset->property("enabled").toBool());

  // The canvas shows the published preview.
  QQuickItem* preview = expectItem("canvas");
  QVERIFY(preview->property("source").toString().endsWith(QStringLiteral("preview-2.png")));
  QTRY_COMPARE(preview->property("status").toInt(), 1);  // Image.Ready

  // After an edit Core publishes canUndo/canRedo and the modified flag.
  editor.insert(QStringLiteral("canUndo"), true);
  editor.insert(QStringLiteral("canRedo"), true);
  editor.insert(QStringLiteral("modified"), true);
  setState(editor);

  QVERIFY(undo->property("enabled").toBool());
  QVERIFY(redo->property("enabled").toBool());
  QVERIFY(reset->property("enabled").toBool());
}

void TestEditor::rotateAndFlipEmitTypedCommands()
{
  setState(documentState());
  // The tool palette lists every action that changes the picture; each sends
  // the same typed command the old toolbar icons did.
  clickItem(expectItem("editsRotateLeft"));
  clickItem(expectItem("editsRotateRight"));
  clickItem(expectItem("editsFlipHorizontal"));
  clickItem(expectItem("editsFlipVertical"));

  QCOMPARE(m_commands->count(), 4);
  QVariantMap first = m_commands->at(0).at(0).toMap();
  QCOMPARE(first.value("type").toString(), QStringLiteral("editor_rotate"));
  QCOMPARE(first.value("degrees").toInt(), -90);
  QVariantMap second = m_commands->at(1).at(0).toMap();
  QCOMPARE(second.value("type").toString(), QStringLiteral("editor_rotate"));
  QCOMPARE(second.value("degrees").toInt(), 90);
  QVariantMap third = m_commands->at(2).at(0).toMap();
  QCOMPARE(third.value("type").toString(), QStringLiteral("editor_flip"));
  QCOMPARE(third.value("axis").toString(), QStringLiteral("horizontal"));
  QVariantMap fourth = m_commands->at(3).at(0).toMap();
  QCOMPARE(fourth.value("type").toString(), QStringLiteral("editor_flip"));
  QCOMPARE(fourth.value("axis").toString(), QStringLiteral("vertical"));
}

void TestEditor::undoRedoResetAndCloseEmitCommands()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("canUndo"), true);
  editor.insert(QStringLiteral("canRedo"), true);
  editor.insert(QStringLiteral("modified"), true);
  setState(editor);

  clickItem(expectItem("undoButton"));
  clickItem(expectItem("redoButton"));
  clickItem(expectItem("resetButton"));
  clickItem(expectItem("editorClose"));

  QCOMPARE(m_commands->count(), 4);
  QCOMPARE(m_commands->at(0).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_undo"));
  QCOMPARE(m_commands->at(1).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_redo"));
  QCOMPARE(m_commands->at(2).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_reset"));
  QCOMPARE(m_commands->at(3).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_close"));
}

void TestEditor::resizeApplyEmitsTheTypedSize()
{
  setState(documentState());
  openResizeDialog();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  QQuickItem* apply = expectItem("resizeApply");
  width->setProperty("text", QStringLiteral("800"));
  height->setProperty("text", QStringLiteral("600"));
  QTest::qWait(20);
  QVERIFY(apply->property("enabled").toBool());

  closeResizeDialog(apply);
  QCOMPARE(m_commands->count(), 1);
  QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_resize"));
  QCOMPARE(command.value("width").toInt(), 800);
  QCOMPARE(command.value("height").toInt(), 600);
  // Resize has no anchor: where the result sits is a Crop decision.
  QVERIFY(!command.contains(QStringLiteral("anchor")));
  QVERIFY(command.value("fill").isNull());
  // Apply ends the question: the form is gone once the size has been asked.
  QTRY_VERIFY(!resizeDialogObject()->property("opened").toBool());
}

/// The dropdown offers concrete sizes for every ratio, whose sides are exact
/// multiples of 64, so a preset never produces fractional pixels at any scale.
/// Choosing one fills both fields and selects the ratio that goes with them.
void TestEditor::theResizePresetsAreMultiplesOf64()
{
  setState(documentState());
  openResizeDialog();

  const QVariantList ratios = m_editor->property("sizeRatios").toList();
  // A short list: the common shapes plus Free/Original/Keep current. The rare crops
  // that used to lengthen the dropdown (21:9, 5:4, 16:10, 2:3) stay out.
  QVERIFY2(ratios.size() >= 6, "the common ratios are present");
  QVERIFY2(ratios.size() <= 10, "the ratio list stayed short");
  QStringList ratioKeys;
  for (const QVariant& entry : ratios) {
    ratioKeys.append(entry.toMap().value("key").toString());
  }
  QVERIFY(ratioKeys.contains(QStringLiteral("free")));
  QVERIFY(ratioKeys.contains(QStringLiteral("original")));
  QVERIFY(ratioKeys.contains(QStringLiteral("current")));
  QVERIFY(ratioKeys.contains(QStringLiteral("1:1")));
  QVERIFY(ratioKeys.contains(QStringLiteral("16:9")));
  QVERIFY(!ratioKeys.contains(QStringLiteral("21:9")));
  QVERIFY(!ratioKeys.contains(QStringLiteral("5:4")));
  QVERIFY(!ratioKeys.contains(QStringLiteral("16:10")));
  QVERIFY(!ratioKeys.contains(QStringLiteral("2:3")));

  const QVariantList presets = m_editor->property("sizePresets").toList();
  // Three sizes per ratio, not every power of two: the list was cut from 47 to
  // 18 entries so `Custom` is not buried under rare samples.
  QVERIFY2(presets.size() >= 12, "concrete ratio + pixel presets are offered");
  QVERIFY2(presets.size() <= 20, "the preset list stayed short");
  int squareIndex = -1;
  int smallSquareIndex = -1;
  bool hasLargeSquare = false;
  for (int index = 0; index < presets.size(); ++index) {
    const QVariantMap preset = presets.at(index).toMap();
    const QString label = preset.value("label").toString();
    QVERIFY(!label.isEmpty());
    QVERIFY2(ratioKeys.contains(preset.value("ratio").toString()),
             qPrintable(QStringLiteral("%1 has an unknown ratio").arg(label)));
    QVERIFY2(preset.value("width").toInt() % 64 == 0,
             qPrintable(QStringLiteral("%1 width is not a multiple of 64").arg(label)));
    QVERIFY2(preset.value("height").toInt() % 64 == 0,
             qPrintable(QStringLiteral("%1 height is not a multiple of 64").arg(label)));
    if (preset.value("width").toInt() == 1024 && preset.value("height").toInt() == 1024) {
      squareIndex = index;
    }
    if (preset.value("width").toInt() == 512 && preset.value("height").toInt() == 512) {
      smallSquareIndex = index;
    }
    if (preset.value("width").toInt() == 2048 && preset.value("height").toInt() == 2048) {
      hasLargeSquare = true;
    }
  }
  QVERIFY2(squareIndex >= 0, "1:1 · 1024 × 1024 is missing");
  QVERIFY2(smallSquareIndex >= 0, "1:1 · 512 × 512 is missing");
  QVERIFY2(hasLargeSquare, "1:1 · 2048 × 2048 is missing");

  QQuickItem* dropdown = expectItem("resizeSizePreset");
  QVERIFY(dropdown->isVisible());
  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  // Nothing is armed on open: the dropdown starts on `Custom` and the fields
  // show the document's own size. `onActivated` (not
  // `onCurrentIndexChanged`) is what makes an index change the user's action,
  // so a preset only lands when picked.
  QCOMPARE(dropdown->property("currentIndex").toInt(), -1);
  QCOMPARE(dropdown->property("displayText").toString(), QStringLiteral("Custom"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QVERIFY(QMetaObject::invokeMethod(resizeDialogObject(), "choosePreset",
                                    Q_ARG(QVariant, squareIndex)));
  QTRY_COMPARE(width->property("text").toString(), QStringLiteral("1024"));
  QTRY_COMPARE(height->property("text").toString(), QStringLiteral("1024"));
  QCOMPARE(dropdown->property("displayText").toString(),
           QStringLiteral("1:1 · 1024 × 1024"));
  QCOMPARE(resizeDialogObject()->property("ratio").toString(), QStringLiteral("1:1"));
}

/// Resize lines the two sides up through the chosen ratio: typing one side
/// recalculates the other, so a field pair can never describe a shape the user
/// did not pick. "Free" is the only unlinked choice.
void TestEditor::typingOneSideKeepsTheChosenRatio()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();
  QCOMPARE(resizeDialogObject()->property("ratio").toString(), QStringLiteral("original"));

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");

  // The document's own 4:3 shape by default.
  typeInto(width, QStringLiteral("800"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));
  typeInto(height, QStringLiteral("1200"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1200"));

  // A square ratio keeps both sides equal.
  QVERIFY(QMetaObject::invokeMethod(resizeDialogObject(), "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("1:1")))));
  QCOMPARE(resizeDialogObject()->property("ratio").toString(), QStringLiteral("1:1"));
  typeInto(width, QStringLiteral("512"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("512"));

  // A 16:9 ratio is exact on both sides.
  QVERIFY(QMetaObject::invokeMethod(resizeDialogObject(), "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("16:9")))));
  typeInto(width, QStringLiteral("1024"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("576"));

  // Free stops linking: the other side stays where it was.
  QVERIFY(QMetaObject::invokeMethod(resizeDialogObject(), "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("free")))));
  typeInto(width, QStringLiteral("300"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("300"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("576"));
}

/// "Keep current ratio" freezes the W:H pair on screen and keeps later edits at
/// that shape. It belongs to the form that used it: the Resize dialog's lock
/// does not reach Crop, and a fresh visit asks the question again from the
/// document's size rather than resuming the last answer.
void TestEditor::theCurrentRatioLocksTheTypedPair()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  QVERIFY(QMetaObject::invokeMethod(dialog, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("free")))));
  typeInto(width, QStringLiteral("1000"));
  typeInto(height, QStringLiteral("700"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("700"));

  // Picking it snapshots what the two fields hold, not the document's 4:3.
  QVERIFY(QMetaObject::invokeMethod(dialog, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("current")))));
  QCOMPARE(dialog->property("ratio").toString(), QStringLiteral("current"));
  const QVariantMap captured = dialog->property("currentRatio").toMap();
  QCOMPARE(captured.value("width").toInt(), 1000);
  QCOMPARE(captured.value("height").toInt(), 700);

  typeInto(width, QStringLiteral("2000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1400"));
  typeInto(height, QStringLiteral("700"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1000"));

  // Crop has its own snapshot: a 3:2 crop must not change the 10:7 resize.
  closeResizeDialog(expectItem("resizeCancel"));
  QTRY_VERIFY(!dialog->property("opened").toBool());
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("free")))));
  typeInto(expectItem("cropWidth"), QStringLiteral("300"));
  typeInto(expectItem("cropHeight"), QStringLiteral("200"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("current")))));
  typeInto(expectItem("cropWidth"), QStringLiteral("600"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("400"));

  // A second visit is a new question: opening the form fills it from the
  // document again, and the previous lock is not silently resumed.
  selectTool("pointer");
  openResizeDialog();
  QCOMPARE(expectItem("resizeWidth")->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(expectItem("resizeHeight")->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(dialog->property("ratio").toString(), QStringLiteral("original"));
  QCOMPARE(m_commands->count(), 0);
}

/// Width and Height carry a small +/- pair. An empty field starts from the size
/// its placeholder shows, and a step takes the same link path as typing; Free
/// leaves the other side alone.
void TestEditor::theSizeSteppersNudgeBothSides()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  for (const char* name : {"resizeWidthStepUp", "resizeWidthStepDown",
                           "resizeHeightStepUp", "resizeHeightStepDown"}) {
    QVERIFY2(expectItem(name)->isVisible(), name);
  }

  // An empty field shows 4000 as its placeholder; + starts there, not at 1.
  width->setProperty("text", QString());
  clickItem(expectItem("resizeWidthStepUp"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4001"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3001"));
  clickItem(expectItem("resizeWidthStepDown"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));

  clickItem(expectItem("resizeHeightStepUp"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3001"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4001"));
  clickItem(expectItem("resizeHeightStepDown"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));

  // Three presses in a row keep moving both linked sides.
  for (int press = 1; press <= 3; ++press) {
    clickItem(expectItem("resizeWidthStepUp"));
    QCOMPARE(width->property("text").toString(), QString::number(4000 + press));
  }
  QCOMPARE(height->property("text").toString(), QStringLiteral("3002"));
  for (int press = 1; press <= 3; ++press) {
    clickItem(expectItem("resizeWidthStepDown"));
  }
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));

  // Both ends stay inside the validators instead of making the linked field
  // invalid and disabling Apply.
  width->setProperty("text", QStringLiteral("20000"));
  height->setProperty("text", QStringLiteral("20000"));
  clickItem(expectItem("resizeWidthStepUp"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("20000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("15000"));
  width->setProperty("text", QStringLiteral("1"));
  height->setProperty("text", QStringLiteral("1"));
  clickItem(expectItem("resizeWidthStepDown"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1"));

  // Free is the unlinked choice: nudging one side leaves the other.
  QVERIFY(QMetaObject::invokeMethod(dialog, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("free")))));
  width->setProperty("text", QStringLiteral("4000"));
  height->setProperty("text", QStringLiteral("3000"));
  clickItem(expectItem("resizeWidthStepUp"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4001"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(m_commands->count(), 0);
}

/// The pad colour travels with the typed command; the anchor does not exist any
/// more. Fitting the whole image and centring the leftover is Core's job, not
/// the view's.
void TestEditor::resizeCarriesThePadFill()
{
  setState(documentState());
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  // An anchor is a Crop idea: the Resize form must not have the 3 × 3 pad, nor
  // a Half shortcut.
  QVERIFY(findObject(QStringLiteral("anchor_center")) == nullptr);
  QVERIFY(findObject(QStringLiteral("anchor_top_left")) == nullptr);
  QVERIFY(findObject(QStringLiteral("halfSize")) == nullptr);

  QQuickItem* pad = expectItem("resizePadToFit");
  clickItem(pad);
  QTRY_VERIFY(dialog->property("padFit").toBool());
  QVERIFY(expectItem("resizeFillColorButton")->isVisible());

  // Pad to fit adds the colour row and its explanation, which is the tallest
  // the form gets. A short window scrolls it (this dialog caps its height at
  // the window), so the viewport has to be tall enough for everything at the
  // size this suite runs at — `isVisible` would not notice the Flickable's
  // clipping, and an early screenshot showed exactly that.
  QQuickItem* content = expectItem("resizeContent");
  QQuickItem* column = expectItem("resizeColumn");
  QVERIFY2(column->implicitHeight() + 40 <= content->height(),
           qPrintable(QStringLiteral("the padded form is %1 px tall in a %2 px viewport")
                          .arg(column->implicitHeight() + 40)
                          .arg(content->height())));

  dialog->setProperty("fillColor", QColor(255, 0, 0));
  expectItem("resizeWidth")->setProperty("text", QStringLiteral("1024"));
  expectItem("resizeHeight")->setProperty("text", QStringLiteral("576"));
  QTest::qWait(20);
  clickItem(expectItem("resizeApply"));

  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_resize"));
  QVERIFY(!command.contains(QStringLiteral("anchor")));
  const QVariantList fill = command.value("fill").toList();
  QCOMPARE(fill.size(), 3);
  QCOMPARE(fill.at(0).toInt(), 255);
  QCOMPARE(fill.at(1).toInt(), 0);
  QCOMPARE(fill.at(2).toInt(), 0);
}

/// The Resize form is fields and buttons, nothing else. It used to carry a
/// framed preview of the result; that frame showed the document's image
/// asynchronously and made the dialog read as "still loading" before it settled.
/// The size is typed, the canvas behind the modal already shows the picture, and
/// nothing in this form asks Core for a rendered draft.
void TestEditor::theResizeDialogHasNoPreviewSurfaces()
{
  setState(documentState());
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  QVERIFY2(findObject(QStringLiteral("resizePreview")) == nullptr,
           "the resize form still has a preview frame");
  QVERIFY2(findObject(QStringLiteral("resizeCaption")) == nullptr,
           "the resize form still has a preview caption");
  QVERIFY2(findObject(QStringLiteral("resizeLivePreview")) == nullptr,
           "the resize form still has a live-preview switch");
  QVERIFY2(!dialog->property("livePreview").isValid(),
           "the resize form still carries live-preview state");

  // Typing a new pair must not ask for a draft: no preview command leaves the
  // view, only Apply sends `editor_resize`.
  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  width->setProperty("text", QStringLiteral("800"));
  height->setProperty("text", QStringLiteral("800"));
  QTest::qWait(300);
  QCOMPARE(m_commands->count(), 0);

  QVERIFY(expectItem("resizeApply")->property("enabled").toBool());

  // Opening the form is one frame, not a box that grows as its contents settle:
  // the height is the content column's height, and it must not move after the
  // first layout pass. The old framed preview plus its caption made this dialog
  // read as "still loading" before it reached its final size.
  const qreal openedHeight = dialog->property("height").toReal();
  QTest::qWait(200);
  QCOMPARE(dialog->property("height").toReal(), openedHeight);

  closeResizeDialog(expectItem("resizeCancel"));
  QTRY_VERIFY(!dialog->property("opened").toBool());
}

/// The sidebar thumbnail must give the shared cache the preview file's identity,
/// not just its path. The preview names repeat every run (`preview-1.png`), so a
/// key of (path, edge, 0, 0) answered a fresh document with the previous run's
/// thumbnail: the canvas was right and the small preview was another picture.
void TestEditor::thePointerThumbnailCarriesThePreviewIdentity()
{
  StubThumbnailCache cache;
  m_editor->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(&cache)));

  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("previewModified"), Q_INT64_C(1700000000123));
  editor.insert(QStringLiteral("previewSize"), Q_INT64_C(4096));
  setState(editor);
  selectTool("pointer");

  QTRY_VERIFY_WITH_TIMEOUT(!cache.callsFor(m_previewOne).isEmpty(), 2000);
  const StubThumbnailCache::Call call = cache.lastCallFor(m_previewOne);
  QCOMPARE(call.modified, Q_INT64_C(1700000000123));
  QCOMPARE(call.size, Q_INT64_C(4096));
  // The thumbnail is the preview, not the source: asking for the source would
  // show the unedited original.
  QVERIFY(cache.callsFor(QStringLiteral("/pics/photo.png")).isEmpty());

  m_editor->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
}

void TestEditor::cropApplyEmitsTheTypedRectangle()
{
  setState(documentState());

  // Crop owns the right column only while it is the selected tool.
  selectTool("crop");
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("crop"));
  QCOMPARE(m_commands->count(), 0);

  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* apply = expectItem("applyCrop");
  QTRY_VERIFY(apply->isVisible());

  cropX->setProperty("text", QStringLiteral("4"));
  cropY->setProperty("text", QStringLiteral("6"));
  width->setProperty("text", QStringLiteral("100"));
  height->setProperty("text", QStringLiteral("50"));
  QTest::qWait(20);
  QVERIFY(apply->property("enabled").toBool());

  clickItem(apply);
  QCOMPARE(m_commands->count(), 1);
  QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_crop"));
  QCOMPARE(command.value("x").toInt(), 4);
  QCOMPARE(command.value("y").toInt(), 6);
  QCOMPARE(command.value("width").toInt(), 100);
  QCOMPARE(command.value("height").toInt(), 50);
}

/// A crop preset is a concrete size the document can really hold: offering one
/// that is wider or taller than the picture would arm Apply with a rectangle
/// Core has to reject.
void TestEditor::theCropPresetsFitInsideTheDocument()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");

  const QVariantList presets = m_editor->property("cropPresets").toList();
  QVERIFY2(presets.size() >= 10, "the fitting sizes are offered");
  int squareIndex = -1;
  for (int index = 0; index < presets.size(); ++index) {
    const QVariantMap preset = presets.at(index).toMap();
    const int width = preset.value("width").toInt();
    const int height = preset.value("height").toInt();
    const QString label = preset.value("label").toString();
    QVERIFY(!label.isEmpty());
    QVERIFY2(width <= 4000 && height <= 3000,
             qPrintable(QStringLiteral("%1 does not fit the document").arg(label)));
    QVERIFY2(width % 64 == 0,
             qPrintable(QStringLiteral("%1 width is not a multiple of 64").arg(label)));
    QVERIFY2(height % 64 == 0,
             qPrintable(QStringLiteral("%1 height is not a multiple of 64").arg(label)));
    if (width == 1024 && height == 1024) {
      squareIndex = index;
    }
  }
  QVERIFY2(squareIndex >= 0, "1:1 · 1024 × 1024 fits and is offered");

  QQuickItem* dropdown = expectItem("cropPreset");
  QVERIFY(dropdown->isVisible());
  QCOMPARE(dropdown->property("currentIndex").toInt(), -1);
  QCOMPARE(dropdown->property("displayText").toString(), QStringLiteral("Custom"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "chooseCropPreset",
                                    Q_ARG(QVariant, squareIndex)));
  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QTRY_COMPARE(width->property("text").toString(), QStringLiteral("1024"));
  QTRY_COMPARE(height->property("text").toString(), QStringLiteral("1024"));
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("1:1"));
  QCOMPARE(dropdown->property("displayText").toString(),
           QStringLiteral("1:1 · 1024 × 1024"));
  // The default centre anchor places the rectangle, not the top-left corner.
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("1488"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("988"));
  QCOMPARE(m_commands->count(), 0);
}

/// Crop links Width and Height the same way Resize does, and each size change
/// re-places the rectangle through the selected anchor.
void TestEditor::theCropRatioLinksTheSides()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("original"));

  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");

  // The document's own 4:3 shape, centred.
  typeInto(width, QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1200"));

  // A square ratio keeps both sides equal, and the rectangle stays centred.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("1:1")))));
  typeInto(width, QStringLiteral("512"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("512"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1744"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1244"));

  // Free stops linking: the other side stays where it was.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("free")))));
  typeInto(width, QStringLiteral("300"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("300"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("512"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1850"));

  // A ratio picked directly re-links the pair: 16:9 on a 300 px width is 169.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("16:9")))));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "relinkFields"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("169"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1416"));
  QCOMPARE(m_commands->count(), 0);
}

/// The anchor pad is what gives the crop rectangle a place: a corner pins that
/// corner of the document, an edge pins that edge, and the centre keeps the
/// rectangle centred. Typing X/Y is the user's own placement and is left alone.
void TestEditor::theCropAnchorPlacesTheRectangle()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");
  QVERIFY(findObject(QStringLiteral("cropAnchor_center")) != nullptr);
  QVERIFY(findObject(QStringLiteral("cropAnchor_top_left")) != nullptr);
  QVERIFY(findObject(QStringLiteral("cropAnchor_bottom_right")) != nullptr);

  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("1:1")))));
  typeInto(width, QStringLiteral("800"));
  typeInto(height, QStringLiteral("800"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1100"));

  clickItem(expectItem("cropAnchor_top_left"));
  QCOMPARE(m_editor->property("cropAnchor").toString(), QStringLiteral("top_left"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));

  clickItem(expectItem("cropAnchor_bottom_right"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("3200"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("2200"));

  clickItem(expectItem("cropAnchor_right"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("3200"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1100"));

  clickItem(expectItem("cropAnchor_top"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));

  // A hand-typed corner is not overwritten until the size changes again.
  QQuickItem* x = expectItem("cropX");
  QQuickItem* y = expectItem("cropY");
  x->setProperty("text", QStringLiteral("50"));
  y->setProperty("text", QStringLiteral("60"));
  QCOMPARE(x->property("text").toString(), QStringLiteral("50"));
  QCOMPARE(y->property("text").toString(), QStringLiteral("60"));

  // Picking a preset re-places the rectangle at the anchor too.
  const QVariantList presets = m_editor->property("cropPresets").toList();
  int index = -1;
  for (int i = 0; i < presets.size(); ++i) {
    if (presets.at(i).toMap().value("width").toInt() == 512) {
      index = i;
      break;
    }
  }
  QVERIFY(index >= 0);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "chooseCropPreset",
                                    Q_ARG(QVariant, index)));
  QTRY_COMPARE(x->property("text").toString(), QStringLiteral("1744"));
  QTRY_COMPARE(y->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(m_commands->count(), 0);
}

/// The crop draft is shown only under Crop with its toggle on, and only when
/// Core says it is a crop. A resize draft left in the state must not paint a
/// crop result, and the command that asks for one names the rectangle.
void TestEditor::theLiveCropShowsOnlyItsOwnDraft()
{
  QVariantMap draft;
  draft.insert(QStringLiteral("path"), m_previewTwo);
  draft.insert(QStringLiteral("kind"), QStringLiteral("crop"));
  draft.insert(QStringLiteral("width"), 200);
  draft.insert(QStringLiteral("height"), 150);
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("previewDraft"), draft);

  setState(editor);
  selectTool("crop");
  QQuickItem* canvas = expectItem("canvas");
  QQuickItem* toggle = expectItem("cropLivePreviewButton");
  QVERIFY(toggle->isVisible());
  QVERIFY(!m_editor->property("cropLivePreview").toBool());
  QVERIFY(canvas->property("source").toString().endsWith(QStringLiteral("preview-1.png")));
  QCOMPARE(canvas->property("width").toDouble(), 4000.0);

  clickItem(toggle);
  QVERIFY(m_editor->property("cropLivePreview").toBool());
  QVERIFY(toggle->property("checked").toBool());
  QVERIFY(toggle->property("highlighted").toBool());
  QTRY_VERIFY(canvas->property("source").toString().endsWith(QStringLiteral("preview-2.png")));
  QCOMPARE(canvas->property("width").toDouble(), 200.0);
  QCOMPARE(canvas->property("height").toDouble(), 150.0);
  // The document did not move: the draft is a preview, not a cut.
  QCOMPARE(m_editor->property("documentWidth").toDouble(), 4000.0);
  QCOMPARE(m_editor->property("modified").toBool(), false);

  // A resize draft under Crop is the other tool's result: it stays hidden.
  draft.insert(QStringLiteral("kind"), QStringLiteral("resize"));
  editor.insert(QStringLiteral("previewDraft"), draft);
  setState(editor);
  QTRY_VERIFY(canvas->property("source").toString().endsWith(QStringLiteral("preview-1.png")));
  QCOMPARE(canvas->property("width").toDouble(), 4000.0);

  // The command that asks Core for a crop draft carries the whole rectangle.
  m_commands->clear();
  selectTool("crop");
  m_editor->setProperty("cropLivePreview", false);
  expectItem("cropX")->setProperty("text", QStringLiteral("20"));
  expectItem("cropY")->setProperty("text", QStringLiteral("30"));
  expectItem("cropWidth")->setProperty("text", QStringLiteral("200"));
  expectItem("cropHeight")->setProperty("text", QStringLiteral("150"));
  clickItem(expectItem("cropLivePreviewButton"));
  QTRY_COMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_crop_preview"));
  QCOMPARE(command.value("x").toInt(), 20);
  QCOMPARE(command.value("y").toInt(), 30);
  QCOMPARE(command.value("width").toInt(), 200);
  QCOMPARE(command.value("height").toInt(), 150);
}

/// The crop frame is a second view of the four fields, not a second copy of the
/// rectangle: drawing one on the canvas writes the fields, dragging the frame
/// moves X/Y, and dragging a handle moves one side. Nothing reaches Core until
/// Apply, so the draft debounce is the only thing a drag triggers.
void TestEditor::theCropFrameIsDrawnAndDragged()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 200);
  editor.insert(QStringLiteral("height"), 150);
  setState(editor);
  selectTool("crop");
  // Zoom 1 puts the 200 × 150 picture at a known place in the 1100 × 700 host,
  // so handle positions are arithmetic rather than whatever fit chose.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);

  QQuickItem* canvasHost = expectItem("editorCanvasHost");
  QVERIFY(canvasHost != nullptr);
  QQuickItem* canvas = expectItem("canvas");
  const QPointF origin = canvas->mapToScene(QPointF(0, 0));

  // An empty frame: the overlay is armed, the rectangle is not drawn.
  QVERIFY(expectItem("cropOverlay")->isVisible());
  QVERIFY(!expectItem("cropFrame")->isVisible());
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("0"));

  // Drag a new rectangle: (10,10) to (90,70) in document pixels.
  dragScene(origin + QPointF(10, 10), origin + QPointF(90, 70));
  QTRY_COMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("10"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("10"));
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("80"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("60"));
  QQuickItem* frame = expectItem("cropFrame");
  QTRY_VERIFY(frame->isVisible());
  QCOMPARE(frame->mapToScene(QPointF(0, 0)).x(), origin.x() + 10.0);
  QCOMPARE(frame->mapToScene(QPointF(0, 0)).y(), origin.y() + 10.0);
  QCOMPARE(frame->width(), 80.0);
  QCOMPARE(frame->height(), 60.0);

  // Dragging the frame's inside moves the rectangle and keeps its size.
  const QPointF frameCentre = frame->mapToScene(QPointF(frame->width() / 2,
                                                       frame->height() / 2));
  dragScene(frameCentre, frameCentre + QPointF(20, 15));
  QTRY_COMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("30"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("25"));
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("80"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("60"));

  // A corner handle moves the two sides it owns; the opposite corner stays put.
  QQuickItem* bottomRight = expectItem("cropHandle_bottom_right");
  QVERIFY(bottomRight->isVisible());
  const QPointF handleCentre = bottomRight->mapToScene(
    QPointF(bottomRight->width() / 2, bottomRight->height() / 2));
  dragScene(handleCentre, handleCentre - QPointF(20, 10));
  QTRY_COMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("60"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("50"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("30"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("25"));

  // No command left the view: the frame is a rectangle being adjusted.
  QCOMPARE(m_commands->count(), 0);

  // The rectangle Apply sends is exactly the one on screen.
  clickItem(expectItem("applyCrop"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_crop"));
  QCOMPARE(command.value("x").toInt(), 30);
  QCOMPARE(command.value("y").toInt(), 25);
  QCOMPARE(command.value("width").toInt(), 60);
  QCOMPARE(command.value("height").toInt(), 50);
}

/// A crop draft is the cut result and fills the canvas at its own size, so the
/// rectangle's handles would sit outside it (or, for a full-width crop, point
/// at pixels that are not the source). The frame is drawn only while the
/// source is on screen; turning the preview off brings it back.
void TestEditor::theCropFrameHidesWhileItsPreviewIsOn()
{
  QVariantMap draft;
  draft.insert(QStringLiteral("path"), m_previewTwo);
  draft.insert(QStringLiteral("kind"), QStringLiteral("crop"));
  draft.insert(QStringLiteral("width"), 80);
  draft.insert(QStringLiteral("height"), 60);
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 200);
  editor.insert(QStringLiteral("height"), 150);
  editor.insert(QStringLiteral("previewDraft"), draft);
  setState(editor);
  selectTool("crop");
  expectItem("cropX")->setProperty("text", QStringLiteral("10"));
  expectItem("cropY")->setProperty("text", QStringLiteral("10"));
  expectItem("cropWidth")->setProperty("text", QStringLiteral("80"));
  expectItem("cropHeight")->setProperty("text", QStringLiteral("60"));
  QTest::qWait(20);

  // With the preview off, the draft is not drawn and the frame is.
  QVERIFY(m_editor->property("cropFrameShown").toBool());
  QVERIFY(expectItem("cropFrame")->isVisible());
  QVERIFY(expectItem("cropOverlay")->isEnabled());

  clickItem(expectItem("cropLivePreviewButton"));
  QVERIFY(m_editor->property("cropLivePreview").toBool());
  QTRY_VERIFY(!m_editor->property("cropFrameShown").toBool());
  QVERIFY(!expectItem("cropFrame")->isVisible());
  QVERIFY(!expectItem("cropOverlay")->isEnabled());

  clickItem(expectItem("cropLivePreviewButton"));
  QVERIFY(!m_editor->property("cropLivePreview").toBool());
  QTRY_VERIFY(m_editor->property("cropFrameShown").toBool());
  QVERIFY(expectItem("cropFrame")->isVisible());
}

/// Transform carries four source corners and nothing else. The canvas shows
/// them as four corner handles and four edge handles; a corner drag moves one
/// point, an edge drag moves the two corners that form the edge.
void TestEditor::theTransformToolDragsCornersAndEdges()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 200);
  editor.insert(QStringLiteral("height"), 150);
  setState(editor);
  selectTool("transform");
  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Transform"));
  QVERIFY(expectItem("transformOverlay")->isVisible());
  QVERIFY(expectItem("applyTransform")->isVisible());
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners.length")).toInt(), 4);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);

  // All four corners and all four edges are drawn, at the document's frame.
  for (int index = 0; index < 4; ++index) {
    QQuickItem* corner = visualItem(QStringLiteral("transformCorner_%1").arg(index));
    QVERIFY2(corner != nullptr && corner->isVisible(), "a corner handle is missing");
    QQuickItem* edge = visualItem(QStringLiteral("transformEdge_%1").arg(index));
    QVERIFY2(edge != nullptr && edge->isVisible(), "an edge handle is missing");
  }
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][0]")).toDouble(), 200.0);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][1]")).toDouble(), 150.0);
  QVERIFY(!expectItem("applyTransform")->property("enabled").toBool());

  // Corner 0: down and in, the way a keystone's top-left is dragged.
  QQuickItem* corner0 = expectItem("transformCorner_0");
  const QPointF cornerCentre =
    corner0->mapToScene(QPointF(corner0->width() / 2.0, corner0->height() / 2.0));
  dragScene(cornerCentre, cornerCentre + QPointF(20, 10));
  QTRY_VERIFY2(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][0]")).toDouble() - 20.0)
                 < 0.6,
               "the corner did not follow the pointer");
  QVERIFY(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][1]")).toDouble() - 10.0)
          < 0.6);
  // The other three corners are untouched: a corner drag is one point.
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[1][0]")).toDouble(), 200.0);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][1]")).toDouble(), 150.0);
  QVERIFY(expectItem("applyTransform")->property("enabled").toBool());

  // Edge 0 is the top edge: both of its corners move down together.
  QQuickItem* edge0 = expectItem("transformEdge_0");
  const QPointF edgeCentre =
    edge0->mapToScene(QPointF(edge0->width() / 2.0, edge0->height() / 2.0));
  dragScene(edgeCentre, edgeCentre + QPointF(0, 15));
  QTRY_VERIFY2(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][1]")).toDouble() - 25.0)
                 < 0.6,
               "the edge did not move its first corner");
  QVERIFY(qAbs(readQml(m_editor, QStringLiteral("transformCorners[1][1]")).toDouble() - 15.0)
          < 0.6);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[1][0]")).toDouble(), 200.0);

  // Apply carries the quad and nothing else, then returns to the identity so a
  // second press cannot record the same transform twice.
  clickItem(expectItem("applyTransform"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_transform"));
  const QVariantList corners = command.value("corners").toList();
  QCOMPARE(corners.size(), 4);
  const QVariantList first = corners.at(0).toList();
  QCOMPARE(first.size(), 2);
  QVERIFY(qAbs(first.at(0).toDouble() - 20.0) < 0.6);
  QVERIFY(qAbs(first.at(1).toDouble() - 25.0) < 0.6);
  QTRY_COMPARE(readQml(m_editor, QStringLiteral("transformCorners[0][0]")).toDouble(), 0.0);
  QVERIFY(!expectItem("applyTransform")->property("enabled").toBool());
}

/// Transform's draft is gated like the other two: its own kind, its own
/// toggle, and the document does not move. The command that asks for it names
/// the quad.
void TestEditor::theLiveTransformShowsOnlyItsOwnDraft()
{
  QVariantMap draft;
  draft.insert(QStringLiteral("path"), m_previewTwo);
  draft.insert(QStringLiteral("kind"), QStringLiteral("transform"));
  draft.insert(QStringLiteral("width"), 200);
  draft.insert(QStringLiteral("height"), 150);
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 200);
  editor.insert(QStringLiteral("height"), 150);
  editor.insert(QStringLiteral("previewDraft"), draft);
  setState(editor);
  selectTool("transform");

  QQuickItem* canvas = expectItem("canvas");
  QQuickItem* toggle = expectItem("transformLivePreviewButton");
  QVERIFY(toggle->isVisible());
  QVERIFY(!m_editor->property("transformLivePreview").toBool());
  QVERIFY(canvas->property("source").toString().endsWith(QStringLiteral("preview-1.png")));

  clickItem(toggle);
  QVERIFY(m_editor->property("transformLivePreview").toBool());
  QVERIFY(toggle->property("checked").toBool());
  QVERIFY(toggle->property("highlighted").toBool());
  QTRY_VERIFY(canvas->property("source").toString().endsWith(QStringLiteral("preview-2.png")));
  // The quad describes source pixels; the draft fills the canvas with the
  // result, so the frame steps aside while it is drawn.
  QVERIFY(!m_editor->property("transformFrameShown").toBool());
  QVERIFY(!expectItem("transformOverlay")->isVisible());
  QCOMPARE(canvas->property("width").toDouble(), 200.0);
  // The draft is a preview, not an edit.
  QCOMPARE(m_editor->property("documentWidth").toDouble(), 200.0);
  QCOMPARE(m_editor->property("modified").toBool(), false);

  // A crop draft under Transform is the other tool's result and stays hidden.
  draft.insert(QStringLiteral("kind"), QStringLiteral("crop"));
  editor.insert(QStringLiteral("previewDraft"), draft);
  setState(editor);
  QTRY_VERIFY(canvas->property("source").toString().endsWith(QStringLiteral("preview-1.png")));
  // The other tool's draft is not drawn here, so the quad belongs on screen.
  QVERIFY(m_editor->property("transformFrameShown").toBool());

  // Moving a corner with the toggle on asks Core for a transform draft that
  // carries that quad. The identity is never requested: there is nothing to
  // preview.
  m_commands->clear();
  m_editor->setProperty("transformLivePreview", false);
  toggle->setProperty("checked", false);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);
  QQuickItem* corner0 = expectItem("transformCorner_0");
  const QPointF centre =
    corner0->mapToScene(QPointF(corner0->width() / 2.0, corner0->height() / 2.0));
  dragScene(centre, centre + QPointF(30, 20));
  QCOMPARE(m_commands->count(), 0);
  QVERIFY2(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][0]")).toDouble() - 30.0)
             < 0.6,
           "the corner drag did not move the quad");
  clickItem(toggle);
  QTRY_COMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_transform_preview"));
  const QVariantList corners = command.value("corners").toList();
  QCOMPARE(corners.size(), 4);
  const QVariantList first = corners.at(0).toList();
  QVERIFY(qAbs(first.at(0).toDouble() - 30.0) < 0.6);
  QVERIFY(qAbs(first.at(1).toDouble() - 20.0) < 0.6);
}

void TestEditor::anInvalidOrEmptySizeKeepsApplyDisabled()
{
  setState(documentState());
  openResizeDialog();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  QQuickItem* apply = expectItem("resizeApply");
  width->setProperty("text", QString());
  height->setProperty("text", QStringLiteral("300"));
  QTest::qWait(20);
  QVERIFY(!apply->property("enabled").toBool());
  clickItem(apply);
  QCOMPARE(m_commands->count(), 0);
}

/// The palette and the inspector have one job each: the left lists the tools
/// and the actions that change pixels, the right holds the document details
/// under the pointer and the selected tool's options otherwise. Saving and the
/// undo/redo/reset actions live on the toolbar.
void TestEditor::thePaletteHoldsTheToolsAndTheInspectorTheirOptions()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("modified"), true);
  setState(editor);

  QQuickItem* left = expectItem("editorTools");
  QQuickItem* right = expectItem("editorInspector");
  QVERIFY(left->x() < right->x());

  auto inside = [](QQuickItem* container, QQuickItem* item) {
    const QPointF corner = item->mapToScene(QPointF(0, 0));
    const QPointF other = container->mapToScene(QPointF(0, 0));
    return corner.x() >= other.x() - 0.5 && corner.y() >= other.y() - 0.5 &&
           corner.x() + item->width() <= other.x() + container->width() + 0.5;
  };

  for (const char* tool : {"toolPointer", "toolResize", "toolCrop", "editsRotateLeft",
                           "editsRotateRight", "editsFlipHorizontal", "editsFlipVertical"}) {
    QQuickItem* item = expectItem(tool);
    QVERIFY2(inside(left, item), qPrintable(QStringLiteral("%1 is not in the tool palette")
                                                .arg(QString::fromLatin1(tool))));
  }
  // Undo, Redo and Reset moved to the toolbar; they are not palette buttons.
  //
  // Membership is checked through the item tree, not through coordinates: the
  // fixture parents the toolbar over the workspace (the real shell stacks it
  // above), so a wider toolbar eventually crosses the inspector's left edge in
  // `x` while still being a toolbar button. Ancestry is what the case is about,
  // and it does not move when a header grows a button.
  auto descendantOf = [](QQuickItem* item, QQuickItem* ancestor) {
    for (QQuickItem* walk = item; walk != nullptr; walk = walk->parentItem()) {
      if (walk == ancestor) return true;
    }
    return false;
  };
  QQuickItem* toolbarRoot = qobject_cast<QQuickItem*>(m_toolbar);
  QVERIFY(toolbarRoot != nullptr);
  for (const char* action : {"undoButton", "redoButton", "resetButton"}) {
    QQuickItem* item = expectItem(action);
    QVERIFY2(descendantOf(item, toolbarRoot),
             qPrintable(QStringLiteral("%1 is not on the toolbar")
                            .arg(QString::fromLatin1(action))));
    QVERIFY2(!descendantOf(item, left), qPrintable(QStringLiteral("%1 is still in the palette")
                                                       .arg(QString::fromLatin1(action))));
    QVERIFY2(!descendantOf(item, right),
             qPrintable(QStringLiteral("%1 is still in the inspector")
                            .arg(QString::fromLatin1(action))));
  }

  // Pointer: document details, thumbnail and the session history.
  selectTool("pointer");
  for (const char* option : {"toolOptionsHeading", "imageHeading", "imageName", "imageSize",
                             "saveTarget", "pointerThumbnail", "historyList"}) {
    QQuickItem* item = expectItem(option);
    QVERIFY2(inside(right, item), qPrintable(QStringLiteral("%1 is not in the inspector")
                                                 .arg(QString::fromLatin1(option))));
    QVERIFY2(item->isVisible(), qPrintable(QStringLiteral("%1 is not visible")
                                               .arg(QString::fromLatin1(option))));
  }

  // A canvas tool: only its options, inside the same inspector.
  selectTool("crop");
  for (const char* option : {"toolOptionsHeading", "cropWidth", "cropHeight",
                             "applyCrop", "resetToolFields", "cropPreset", "cropRatio",
                             "cropLivePreviewButton", "cropAnchorPad"}) {
    QQuickItem* item = expectItem(option);
    QVERIFY2(inside(right, item), qPrintable(QStringLiteral("%1 is not in the inspector")
                                                 .arg(QString::fromLatin1(option))));
    QVERIFY2(item->isVisible(), qPrintable(QStringLiteral("%1 is not visible")
                                               .arg(QString::fromLatin1(option))));
  }
  QVERIFY(!expectItem("pointerThumbnail")->isVisible());

  // Resize is not a column of the inspector any more: its controls live in its
  // own modal form, and the editor stays on the pointer underneath.
  selectTool("pointer");
  openResizeDialog();
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  for (const char* option : {"resizeWidth", "resizeHeight", "resizeApply", "resizeReset",
                             "resizeSizePreset", "resizeRatio", "resizePadToFit"}) {
    QQuickItem* item = expectItem(option);
    QVERIFY2(item->isVisible(), qPrintable(QStringLiteral("%1 is not visible")
                                               .arg(QString::fromLatin1(option))));
    QVERIFY2(!descendantOf(item, right), qPrintable(QStringLiteral("%1 is in the inspector")
                                                        .arg(QString::fromLatin1(option))));
  }
  QVERIFY(expectItem("imageName")->isVisible());
  closeResizeDialog(expectItem("resizeCancel"));

  // Saving lives on the toolbar, with no second copy in the inspector.
  QVERIFY(expectItem("editorToolbarSave")->isVisible());
  QVERIFY(expectItem("editorToolbarSaveAs")->isVisible());
  QVERIFY(findObject("editorSaveButton") == nullptr);
  QVERIFY(findObject("editorSaveAsButton") == nullptr);
}

/// The pointer is the no-op default. Crop swaps the inspector for its own
/// fields; Resize opens a modal form and leaves the pointer in place. No
/// command leaves the view until Apply is pressed.
void TestEditor::thePaletteSelectsTheToolsOptions()
{
  setState(documentState());
  QQuickItem* cropApply = expectItem("applyCrop");
  QQuickItem* resizeApply = expectItem("resizeApply");
  QQuickItem* imageName = expectItem("imageName");
  QQuickItem* heading = expectItem("toolOptionsHeading");
  QObject* dialog = resizeDialogObject();

  selectTool("pointer");
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QCOMPARE(heading->property("text").toString(), QStringLiteral("Pointer"));
  QVERIFY(imageName->isVisible());
  QVERIFY(!resizeApply->isVisible());
  QVERIFY(!cropApply->isVisible());
  QVERIFY(!expectItem("resizeSizePreset")->isVisible());
  QVERIFY(!expectItem("resizePadToFit")->isVisible());
  QVERIFY(!expectItem("cropX")->isVisible());
  QVERIFY(!expectItem("cropY")->isVisible());
  QVERIFY(!dialog->property("opened").toBool());

  clickItem(expectItem("toolCrop"));
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("crop"));
  QTRY_VERIFY(cropApply->isVisible());
  QCOMPARE(heading->property("text").toString(), QStringLiteral("Crop"));
  QVERIFY(!imageName->isVisible());
  QVERIFY(expectItem("cropX")->isVisible());
  QVERIFY(expectItem("cropY")->isVisible());
  QVERIFY(!expectItem("resizeSizePreset")->isVisible());
  QVERIFY(!expectItem("resizePadToFit")->isVisible());
  QVERIFY(!resizeApply->isVisible());
  QCOMPARE(m_commands->count(), 0);

  // Pressing the selected tool again means "no tool": back to the pointer.
  clickItem(expectItem("toolCrop"));
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QTRY_VERIFY(imageName->isVisible());
  QVERIFY(!cropApply->isVisible());

  // Resize is a question, not a mode: opening it keeps the pointer and leaves
  // the document details in the inspector. Closing it puts the palette's light
  // out again without sending anything.
  clickItem(expectItem("toolResize"));
  QTRY_VERIFY(dialog->property("opened").toBool());
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QCOMPARE(heading->property("text").toString(), QStringLiteral("Pointer"));
  QVERIFY(imageName->isVisible());
  QVERIFY(resizeApply->isVisible());
  QVERIFY(!cropApply->isVisible());
  QCOMPARE(m_commands->count(), 0);
  closeResizeDialog(expectItem("resizeCancel"));
  QTRY_VERIFY(!dialog->property("opened").toBool());
  QVERIFY(!expectItem("toolResize")->property("highlighted").toBool());
}

/// Reset clears the crop fields without sending a command, so a half-entered
/// rectangle never reaches Core. Resize's own Reset is the same question and is
/// covered by the fresh-dialog case.
void TestEditor::resetClearsTheToolFields()
{
  setState(documentState());
  selectTool("crop");
  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* preset = expectItem("cropPreset");
  width->setProperty("text", QStringLiteral("800"));
  height->setProperty("text", QStringLiteral("600"));
  cropX->setProperty("text", QStringLiteral("4"));
  cropY->setProperty("text", QStringLiteral("6"));
  preset->setProperty("currentIndex", 2);
  QCOMPARE(preset->property("currentIndex").toInt(), 2);

  clickItem(expectItem("resetToolFields"));
  QCOMPARE(width->property("text").toString(), QString());
  QCOMPARE(height->property("text").toString(), QString());
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(preset->property("currentIndex").toInt(), -1);
  QCOMPARE(m_commands->count(), 0);
}

/// Save is offered only when there is something to write, and both buttons send
/// the command the user asked for rather than touching the file themselves.
void TestEditor::saveAndSaveAsEmitTheirCommands()
{
  QVariantMap editor = documentState();
  setState(editor);

  QQuickItem* save = expectItem("editorToolbarSave");
  QVERIFY2(!save->property("enabled").toBool(),
           "a document already on disk must not offer a save");
  clickItem(save);
  QCOMPARE(m_commands->count(), 0);

  // An edit makes the document unsaved: Save wakes up and writes the source.
  editor.insert(QStringLiteral("modified"), true);
  editor.insert(QStringLiteral("saved"), false);
  editor.insert(QStringLiteral("canUndo"), true);
  setState(editor);
  QVERIFY(save->property("enabled").toBool());
  clickItem(save);
  QCOMPARE(m_commands->count(), 1);
  QCOMPARE(m_commands->at(0).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_save"));

  // Save as… never writes by itself: it asks the shell for a path, and the Save
  // button are both disabled while the published `saving` flag is on.
  QQuickItem* saveAs = expectItem("editorToolbarSaveAs");
  QSignalSpy requestSaveAs(m_editor, SIGNAL(requestSaveAs()));
  QVERIFY(requestSaveAs.isValid());
  clickItem(saveAs);
  QCOMPARE(requestSaveAs.count(), 1);
  QCOMPARE(m_commands->count(), 1);

  editor.insert(QStringLiteral("saving"), true);
  setState(editor);
  QVERIFY(!save->property("enabled").toBool());
  QVERIFY(!saveAs->property("enabled").toBool());
}

/// Tooltips name the key that reaches the same command, and only that key: the
/// Save pair carries its Ctrl shortcuts, while Undo, Redo and Reset have none
/// and just name the action.
void TestEditor::exportIsACopyWithItsOwnQualityAndMetadata()
{
  // ADR 0004 deferred Export's options; the dialog has to carry them and the
  // command has to say which target honours which. A copy is a delivery file,
  // so it must never suggest the document's own path.
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("path"), QStringLiteral("/pics/holiday.jpg"));
  editor.insert(QStringLiteral("name"), QStringLiteral("holiday.jpg"));
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/holiday.jpg"));
  editor.insert(QStringLiteral("format"), QStringLiteral(".jpg"));
  setState(editor);

  QVERIFY(QMetaObject::invokeMethod(m_editor, "openExportDialog"));
  QObject* dialog = findObject(QStringLiteral("exportDialog"));
  QVERIFY(dialog != nullptr);
  // `open()` completes on the next frame, so the popped-up state is waited for.
  QTRY_VERIFY(dialog->property("opened").toBool());
  QCOMPARE(expectItem("exportPathField")->property("text").toString(),
           QStringLiteral("/pics/holiday-export.jpg"));

  // A JPEG target is the one that can take both options.
  QVERIFY(expectItem("exportQuality")->property("enabled").toBool());
  QVERIFY(expectItem("exportMetadata")->property("enabled").toBool());

  m_editor->setProperty("exportQuality", 71);
  m_editor->setProperty("exportMetadata", true);
  clickItem(expectItem("exportConfirm"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->takeFirst().at(0).toMap();
  QCOMPARE(command.value(QStringLiteral("type")).toString(), QStringLiteral("editor_export"));
  QCOMPARE(command.value(QStringLiteral("path")).toString(),
           QStringLiteral("/pics/holiday-export.jpg"));
  QCOMPARE(command.value(QStringLiteral("quality")).toInt(), 71);
  QCOMPARE(command.value(QStringLiteral("metadata")).toBool(), true);
  QVERIFY(!dialog->property("opened").toBool());

  // A lossless target says the slider does not apply and cannot claim to keep
  // metadata, even with the box ticked: only JPEG→JPEG carries the segments.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "openExportDialog"));
  QTRY_VERIFY(dialog->property("opened").toBool());
  m_editor->setProperty("exportPath", QStringLiteral("/pics/holiday.png"));
  QVERIFY(!expectItem("exportQuality")->property("enabled").toBool());
  QVERIFY(!expectItem("exportMetadata")->property("enabled").toBool());
  QCOMPARE(m_editor->property("exportKeepsMetadata").toBool(), false);
  QVERIFY(expectItem("exportConfirm")->property("enabled").toBool());

  clickItem(expectItem("exportConfirm"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap lossless = m_commands->takeFirst().at(0).toMap();
  QCOMPARE(lossless.value(QStringLiteral("path")).toString(),
           QStringLiteral("/pics/holiday.png"));
  QCOMPARE(lossless.value(QStringLiteral("metadata")).toBool(), false);
}

/// Export can write a smaller copy without editing the document: the dialog
/// offers a long edge, the default keeps the document's own size, and the
/// command carries the choice as `max_edge`. The view only picks the number;
/// Core owns the arithmetic and the "never upscale" rule.
void TestEditor::exportOffersADeliverySize()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("path"), QStringLiteral("/pics/holiday.jpg"));
  editor.insert(QStringLiteral("name"), QStringLiteral("holiday.jpg"));
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/holiday.jpg"));
  editor.insert(QStringLiteral("format"), QStringLiteral(".jpg"));
  setState(editor);

  QVERIFY(QMetaObject::invokeMethod(m_editor, "openExportDialog"));
  QObject* dialog = findObject(QStringLiteral("exportDialog"));
  QVERIFY(dialog != nullptr);
  QTRY_VERIFY(dialog->property("opened").toBool());

  QQuickItem* size = expectItem("exportSize");
  const QVariantList edges = m_editor->property("exportEdges").toList();
  QCOMPARE(edges.size(), 6);

  // Every open starts at the document's own size, even after a previous run
  // picked a preset, so a second export cannot silently shrink.
  const int startEdge = m_editor->property("exportLongEdge").toInt();
  const int startIndex = size->property("currentIndex").toInt();

  // Picking the 1280 px row (index 4) is what the command carries.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "chooseExportSize",
                                    Q_ARG(QVariant, QVariant(4))));
  const int chosenEdge = m_editor->property("exportLongEdge").toInt();
  // The row the user sees is the size that will be written: a property set from
  // the harness (or any other caller) must move the combo box with it.
  const int chosenIndex = size->property("currentIndex").toInt();
  // Confirm before asserting, so a failure cannot leave the dialog open over the
  // next case (every dialog is modal, and the shell suspends the workspace).
  clickItem(expectItem("exportConfirm"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap chosen = m_commands->takeFirst().at(0).toMap();
  QCOMPARE(chosen.value(QStringLiteral("max_edge")).toInt(), 1280);
  QCOMPARE(chosenEdge, 1280);
  QCOMPARE(chosenIndex, 4);

  // Reopening the dialog forgets the choice: the fields describe this export,
  // not the last one.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "openExportDialog"));
  QTRY_VERIFY(dialog->property("opened").toBool());
  const int reopenedEdge = m_editor->property("exportLongEdge").toInt();
  const int reopenedIndex = size->property("currentIndex").toInt();
  clickItem(expectItem("exportConfirm"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap original = m_commands->takeFirst().at(0).toMap();
  QCOMPARE(original.value(QStringLiteral("max_edge")).toInt(), 0);
  QCOMPARE(startEdge, 0);
  QCOMPARE(startIndex, 0);
  QCOMPARE(edges.at(0).toInt(), 0);
  QCOMPARE(reopenedEdge, 0);
  QCOMPARE(reopenedIndex, 0);
}

void TestEditor::toolbarTooltipsNameTheirShortcuts()
{
  const QList<QPair<QString, QString>> expected = {
    { QStringLiteral("editorToolbarSave"), QStringLiteral("Save (Ctrl+S)") },
    { QStringLiteral("editorToolbarSaveAs"), QStringLiteral("Save as… (Ctrl+Shift+S)") },
    { QStringLiteral("undoButton"), QStringLiteral("Undo") },
    { QStringLiteral("redoButton"), QStringLiteral("Redo") },
    { QStringLiteral("resetButton"), QStringLiteral("Reset to original") },
    { QStringLiteral("editorZoomIn"), QStringLiteral("Zoom in") },
    { QStringLiteral("editorBack"), QStringLiteral("Back to browser") },
  };
  for (const auto& entry : expected) {
    const QByteArray name = entry.first.toLatin1();
    QQuickItem* item = expectItem(name.constData());
    QCOMPARE(readQml(item, QStringLiteral("ToolTip.text")).toString(), entry.second);
  }
}

/// The save dialog opens on the document's current place and format, so a user
/// who only wants a copy does not have to navigate back to the folder.
void TestEditor::saveAsSuggestsTheCurrentLocation()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/raw/photo.png"));
  editor.insert(QStringLiteral("format"), QStringLiteral(".jpg"));
  setState(editor);
  QCOMPARE(m_editor->property("saveAsPath").toString(),
           QStringLiteral("/pics/raw/photo.jpg"));

  // A document saved under another name suggests that name, not the source.
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/exports/holiday.webp"));
  editor.insert(QStringLiteral("format"), QStringLiteral(".webp"));
  setState(editor);
  QCOMPARE(m_editor->property("saveAsPath").toString(),
           QStringLiteral("/exports/holiday.webp"));
}

void TestEditor::canvasSupportsViewerStyleZoomAndPan()
{
  setState(documentState());

  // A large document is fitted into the canvas on open, rather than being
  // rendered at an arbitrary 100% scale.
  const double fitted = m_editor->property("zoom").toDouble();
  QVERIFY(fitted > 0.02);
  QVERIFY(fitted < 1.0);
  QCOMPARE(m_editor->property("offsetX").toDouble(), 0.0);
  QCOMPARE(m_editor->property("offsetY").toDouble(), 0.0);

  clickItem(expectItem("editorActualSize"));
  QCOMPARE(m_editor->property("zoom").toDouble(), 1.0);
  QVERIFY(!m_editor->property("autoFit").toBool());

  clickItem(expectItem("editorZoomIn"));
  QCOMPARE(m_editor->property("zoom").toDouble(), 1.25);
  clickItem(expectItem("editorZoomOut"));
  QCOMPARE(m_editor->property("zoom").toDouble(), 1.0);

  // Zooming at a point moves the document under that point and leaves the
  // presentation state local to the view (no editor command is emitted).
  QVERIFY(QMetaObject::invokeMethod(
      m_editor, "zoomAt", Q_ARG(QVariant, QVariant(2.0)),
      Q_ARG(QVariant, QVariant(900.0)), Q_ARG(QVariant, QVariant(500.0))));
  QVERIFY(m_editor->property("offsetX").toDouble() != 0.0 ||
          m_editor->property("offsetY").toDouble() != 0.0);
  QCOMPARE(m_commands->count(), 0);

  // While the scaled picture is still smaller than the canvas host on an axis,
  // that axis stays pinned to its centre: the offset it would need to keep the
  // cursor anchored is on the wrong side of the picture's own edge, so the
  // clamp removes it. This is what keeps a fitted picture from drifting.
  QMetaObject::invokeMethod(m_editor, "fit");
  QTest::qWait(20);
  QCOMPARE(m_editor->property("offsetX").toDouble(), 0.0);
  QCOMPARE(m_editor->property("offsetY").toDouble(), 0.0);
  QVERIFY(QMetaObject::invokeMethod(
      m_editor, "zoomAt", Q_ARG(QVariant, QVariant(1.25)),
      Q_ARG(QVariant, QVariant(1000.0)), Q_ARG(QVariant, QVariant(0.0))));
  QTest::qWait(20);
  const double scale = m_editor->property("zoom").toDouble();
  QQuickItem* canvasHost = qobject_cast<QQuickItem*>(
      findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(canvasHost != nullptr);
  const double scaledWidth = 4000.0 * scale;
  const double scaledHeight = 3000.0 * scale;
  // The clamp stops an axis at the overflow it has plus `panMargin`, which is
  // what makes a drag feel free; it still stops.
  const double margin = m_editor->property("panMargin").toDouble();
  QVERIFY(margin > 0.0);
  const double maxX = qMax(0.0, (scaledWidth - canvasHost->width()) / 2.0) + margin;
  const double maxY = qMax(0.0, (scaledHeight - canvasHost->height()) / 2.0) + margin;
  QVERIFY2(qAbs(m_editor->property("offsetX").toDouble()) <= maxX + 0.001,
           "offsetX left the picture's own bounds");
  QVERIFY2(qAbs(m_editor->property("offsetY").toDouble()) <= maxY + 0.001,
           "offsetY left the picture's own bounds");
  // Zooming at a far corner keeps that corner reachable: an axis the picture
  // does not fill can now move by the pan margin, which is what a free pan
  // means. It still cannot run away past it.
  if (scaledHeight <= canvasHost->height()) {
    QVERIFY(qAbs(m_editor->property("offsetY").toDouble()) <= margin + 0.001);
  }

  QVERIFY(findObject(QStringLiteral("editorWheelHandler")) != nullptr);
  QVERIFY(findObject(QStringLiteral("editorPanHandler")) != nullptr);
}

/// A picture shorter than the canvas can be dragged up and down. The first
/// implementation pinned every axis that did not overflow to 0, so a wide photo
/// in a wide host moved sideways and not vertically — which reads as a broken
/// pan. The clamp now allows a margin past every edge.
void TestEditor::aLargePicturePansFreelyInBothAxes()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 2400);
  editor.insert(QStringLiteral("height"), 1200);
  setState(editor);
  QMetaObject::invokeMethod(m_editor, "fit");
  QTest::qWait(20);

  QQuickItem* canvasHost =
    qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(canvasHost != nullptr);

  // Fit shows the whole picture, so the scaled height is below the host height:
  // before the fix this axis could not move at all.
  const double scale = m_editor->property("zoom").toDouble();
  QVERIFY2(1200.0 * scale < canvasHost->height(),
           qPrintable(QStringLiteral("the fixture must be shorter than the host: %1 vs %2")
                        .arg(1200.0 * scale)
                        .arg(canvasHost->height())));

  // A real drag, driven with QTest: a hand-built QMouseEvent reaches the
  // handler but never satisfies its grab.
  QQuickItem* canvas = expectItem("canvas");
  const QPointF start = canvas->mapToScene(QPointF(canvas->width() / 2.0, canvas->height() / 2.0));
  const QPoint target = start.toPoint();
  QTest::mouseMove(m_view, target);
  QTest::qWait(30);
  const bool hovered = m_editor->property("panHover").toBool();
  QVERIFY2(hovered, "the canvas hover never armed the pan handler");

  // Several small steps: Qt Quick keeps the implicit grab the press took, and a
  // teleporting cursor is not what a drag looks like on a real device.
  QTest::mousePress(m_view, Qt::LeftButton, Qt::NoModifier, target);
  QCoreApplication::processEvents();
  for (int step = 1; step <= 6; ++step) {
    QTest::mouseMove(m_view, target + QPoint(90 * step / 6, 60 * step / 6));
    QCoreApplication::processEvents();
  }
  QTest::mouseRelease(m_view, Qt::LeftButton, Qt::NoModifier, target + QPoint(90, 60));
  QCoreApplication::processEvents();
  QTest::qWait(20);

  const double offsetY = m_editor->property("offsetY").toDouble();
  const double offsetX = m_editor->property("offsetX").toDouble();
  QVERIFY2(qAbs(offsetY) > 1.0,
           qPrintable(QStringLiteral("a vertical drag did not pan a short picture: offsetY %1")
                        .arg(offsetY)));
  QVERIFY2(offsetX > 1.0,
           qPrintable(QStringLiteral("a horizontal drag did not pan: offsetX %1").arg(offsetX)));
  QVERIFY(qAbs(offsetY) <= 64.0 + 0.5);
  QCOMPARE(m_commands->count(), 0);
}

/// A touchpad drag reports a TouchPad device, and a middle click is not the left
/// button, so a handler that accepts neither setting is dead for both. Both are
/// asserted on the real handler, because neither is visible from the outside
/// until a laptop user tries to pan.
void TestEditor::thePanHandlerTakesTouchpadsAndMiddleClicks()
{
  setState(documentState());
  // The handler is not a visual item; its settings are read off the object.
  QObject* pan = findObject(QStringLiteral("editorPanHandler"));
  QVERIFY(pan != nullptr);

  // Qt 6 defaults `acceptedDevices` to Mouse only, which is why a touchpad drag
  // would silently do nothing.
  const auto devices = pan->property("acceptedDevices").value<QPointingDevice::DeviceTypes>();
  QVERIFY2(devices.testFlag(QPointingDevice::DeviceType::TouchPad),
           "the pan handler ignores touchpads");
  QVERIFY(devices.testFlag(QPointingDevice::DeviceType::Mouse));

  const auto buttons = pan->property("acceptedButtons").value<Qt::MouseButtons>();
  QVERIFY2(buttons.testFlag(Qt::LeftButton) && buttons.testFlag(Qt::MiddleButton),
           "the pan handler does not take a middle-button drag");

  // With Crop or Transform armed the left button belongs to the overlay: the
  // frame and the quad are drawn with it, so a drag must not also move the
  // picture. The middle button still pans in both.
  for (const char* name : {"crop", "transform"}) {
    selectTool(name);
    QCOMPARE(m_editor->property("tool").toString(), QString::fromLatin1(name));
    const auto armed = pan->property("acceptedButtons").value<Qt::MouseButtons>();
    QVERIFY2(!armed.testFlag(Qt::LeftButton) && armed.testFlag(Qt::MiddleButton),
             qPrintable(QStringLiteral("%1 still pans with the left button")
                          .arg(QString::fromLatin1(name))));
  }
}

/// A Wayland touchpad reports `pixelDelta` with a TouchPad pointing device, and
/// `WheelHandler` ignores every device but the mouse unless `acceptedDevices`
/// says otherwise. This drives the real handler, so a missing setting fails
/// here instead of only on a user's laptop.
/// Fit is a mode here too: resizing the window resizes the canvas host, and a
/// fitted document must refit instead of keeping the scale of the old window.
void TestEditor::aFittedDocumentFollowsTheWindowResize()
{
  // Re-open the document for real: `setState()` with the same path does not
  // emit `onDocumentPathChanged`, so a fit state left by another test would
  // leak in and the assertion below would test the harness, not the view.
  setState(QVariantMap{});
  setState(documentState());
  QVERIFY(QMetaObject::invokeMethod(m_editor, "fit"));
  QTest::qWait(20);
  auto* host = qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(host != nullptr);
  QVERIFY2(m_editor->property("autoFit").toBool(), "the document was not fitted on open");
  const double before = m_editor->property("zoom").toDouble();
  const qreal fullWidth = host->width();

  // 4000x3000 into the canvas the editor laid out at 1100x700.
  const double fittedFor = [host]() {
    return std::min((host->width() - 32) / 4000.0, (host->height() - 32) / 3000.0);
  }();
  QVERIFY2(qAbs(before - fittedFor) < 0.01,
           qPrintable(QStringLiteral("open fit is %1, expected %2")
                        .arg(before).arg(fittedFor)));

  // Shrink the real window: the whole editor layout follows it.
  m_view->resize(760, 460);
  m_editor->setWidth(760);
  m_editor->setHeight(460);
  QTRY_VERIFY_WITH_TIMEOUT(host->width() < fullWidth - 1, 2000);

  const double after = m_editor->property("zoom").toDouble();
  const double expected = std::min((host->width() - 32) / 4000.0,
                                   (host->height() - 32) / 3000.0);
  QVERIFY2(qAbs(after - expected) < 0.01,
           qPrintable(QStringLiteral("after the resize the zoom is %1, but the document fills "
                                     "%2 of the %3x%4 canvas")
                        .arg(after).arg(expected).arg(host->width()).arg(host->height())));
  // State delta, not stability.
  QVERIFY2(after < before - 0.01,
           qPrintable(QStringLiteral("zoom did not shrink with the window: %1 -> %2")
                        .arg(before).arg(after)));

  // The document now fits the smaller canvas.
  QVERIFY(qAbs(4000 * after) <= host->width());
  QVERIFY(qAbs(3000 * after) <= host->height());

  m_view->resize(kHostWidth, kHostHeight);
  m_editor->setWidth(kHostWidth);
  m_editor->setHeight(kHostHeight);
  QTRY_VERIFY_WITH_TIMEOUT(host->width() >= fullWidth, 2000);
}

/// A hand-chosen zoom is not auto fit and must survive a resize untouched.
void TestEditor::aManualZoomSurvivesTheWindowResize()
{
  setState(documentState());
  auto* host = qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(host != nullptr);
  const qreal fullWidth = host->width();
  QVERIFY(fullWidth > 300);
  clickItem(expectItem("editorActualSize"));
  QCOMPARE(m_editor->property("zoom").toDouble(), 1.0);
  QVERIFY(!m_editor->property("autoFit").toBool());

  m_view->resize(760, 460);
  m_editor->setWidth(760);
  m_editor->setHeight(460);
  QTRY_VERIFY_WITH_TIMEOUT(host->width() < 700, 2000);
  QCOMPARE(m_editor->property("zoom").toDouble(), 1.0);

  m_view->resize(kHostWidth, kHostHeight);
  m_editor->setWidth(kHostWidth);
  m_editor->setHeight(kHostHeight);
  QTRY_VERIFY_WITH_TIMEOUT(host->width() >= fullWidth, 2000);
  QCOMPARE(m_editor->property("zoom").toDouble(), 1.0);
  QVERIFY(!m_editor->property("autoFit").toBool());
}

void TestEditor::aTouchpadWheelZoomsTheCanvasAtTheCursor()
{
  setState(documentState());
  QMetaObject::invokeMethod(m_editor, "fit");
  QTest::qWait(20);

  QQuickItem* canvasHost =
    qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(canvasHost != nullptr);
  const QPointF local(canvasHost->width() * 0.75, canvasHost->height() * 0.30);
  const QPointF scene = canvasHost->mapToScene(local);
  const QPointF global = m_view->mapToGlobal(scene.toPoint());

  static auto* touchpad =
    new QPointingDevice(QStringLiteral("kogaview test touchpad"), 9003,
                        QInputDevice::DeviceType::TouchPad,
                        QPointingDevice::PointerType::Finger,
                        QInputDevice::Capability::Scroll | QInputDevice::Capability::PixelScroll,
                        1, 3);

  const double before = m_editor->property("zoom").toDouble();
  const bool autoFitBefore = m_editor->property("autoFit").toBool();
  // Pixel-delta scrolling, the shape a two-finger gesture produces.
  QWheelEvent event(scene, global, QPoint(0, 15), QPoint(0, 0), Qt::NoButton, Qt::NoModifier,
                    Qt::ScrollUpdate, false, Qt::MouseEventNotSynthesized, touchpad);
  QCoreApplication::sendEvent(m_view, &event);
  QCoreApplication::processEvents();

  const double after = m_editor->property("zoom").toDouble();
  QVERIFY2(after > before,
           qPrintable(QStringLiteral("touchpad wheel did not zoom: %1 -> %2")
                        .arg(before)
                        .arg(after)));
  QVERIFY2(autoFitBefore && !m_editor->property("autoFit").toBool(),
           "a wheel zoom did not leave fit mode");
  // The point under the cursor stays under the cursor, mapped through the same
  // document item in both directions so the item's scale is applied evenly.
  QQuickItem* canvas = qobject_cast<QQuickItem*>(findObject(QStringLiteral("canvas")));
  QVERIFY(canvas != nullptr);
  const QPointF documentPoint = canvas->mapFromScene(scene);
  const QPointF anchored = canvas->mapToScene(documentPoint);
  QVERIFY2(qAbs(anchored.x() - scene.x()) <= 0.5,
           qPrintable(QStringLiteral("cursor anchor drifted x by %1")
                        .arg(anchored.x() - scene.x())));
  QCOMPARE(m_commands->count(), 0);
}

/// The paint tool is a palette tool with an inspector; a drag on the canvas is
/// one command, carrying document-space points, the colour, the radius and the
/// opacity, and nothing is sent before the button comes up.
void TestEditor::thePaintToolSendsOneStrokeOnRelease()
{
  setState(documentState());
  QQuickItem* brushButton = expectItem("toolBrush");
  QTRY_VERIFY(brushButton->isVisible());
  clickItem(brushButton);
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("brush"));
  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Brush"));
  QVERIFY(expectItem("paintSwatch")->isVisible());
  QVERIFY(expectItem("paintSize")->isVisible());
  QVERIFY(!expectItem("applyCrop")->isVisible());
  QCOMPARE(m_commands->count(), 0);

  m_editor->forceActiveFocus();
  QQuickItem* host =
    qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(host != nullptr);
  // A press on the matte around the picture is not a dab: it would send a
  // stroke Core clips away, which still costs an undo step.
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier,
                    host->mapToScene(QPointF(2, 2)).toPoint());
  QTest::qWait(20);
  QCOMPARE(m_commands->count(), 0);

  const QPointF from =
    host->mapToScene(QPointF(host->width() * 0.35, host->height() * 0.5));
  const QPointF to =
    host->mapToScene(QPointF(host->width() * 0.65, host->height() * 0.5));
  dragScene(from, to, 8);

  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_paint_stroke"));
  const QVariantList points = command.value("points").toList();
  QVERIFY2(points.size() >= 2,
           qPrintable(QStringLiteral("a drag carried %1 point(s)").arg(points.size())));
  const QVariantList colour = command.value("color").toList();
  QCOMPARE(colour.size(), 3);
  QCOMPARE(colour.at(0).toInt(), 0);
  QCOMPARE(colour.at(1).toInt(), 0);
  QCOMPARE(colour.at(2).toInt(), 0);
  // 24 px diameter is a 12 px radius, and 100 % is alpha 1.
  QCOMPARE(command.value("radius").toDouble(), 12.0);
  QCOMPARE(command.value("opacity").toDouble(), 1.0);
  QCOMPARE(command.value("erase").toBool(), false);
  // The ephemeral stroke is gone; the preview the user sees next is Core's.
  QVERIFY(m_editor->property("paintStroke").toList().isEmpty());
  QCOMPARE(m_editor->property("paintStroking").toBool(), false);
}

void TestEditor::theEraserStrokeCarriesItsModeAndBrush()
{
  setState(documentState());
  m_editor->setProperty("paintColor", QStringLiteral("#ff0000"));
  m_editor->setProperty("paintSize", 80.0);
  m_editor->setProperty("paintOpacity", 50);

  clickItem(expectItem("toolEraser"));
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("eraser"));
  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Eraser"));

  m_editor->forceActiveFocus();
  QQuickItem* host =
    qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(host != nullptr);
  const QPointF from =
    host->mapToScene(QPointF(host->width() * 0.4, host->height() * 0.45));
  const QPointF to =
    host->mapToScene(QPointF(host->width() * 0.6, host->height() * 0.55));
  dragScene(from, to, 6);

  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_paint_stroke"));
  QCOMPARE(command.value("erase").toBool(), true);
  QCOMPARE(command.value("radius").toDouble(), 40.0);
  QCOMPARE(command.value("opacity").toDouble(), 0.5);
  const QVariantList colour = command.value("color").toList();
  QCOMPARE(colour.at(0).toInt(), 255);
  QCOMPARE(colour.at(1).toInt(), 0);
  QCOMPARE(colour.at(2).toInt(), 0);
}

/// The Krita defaults this slice maps live on the view, so they must not need
/// the pointer: B/E pick the paint modes, [ ] resize the brush (Shift by ten),
/// X swaps the colours, D resets them and Tab hides the panels.
void TestEditor::theKritaKeysPickTheToolsAndAdjustTheBrush()
{
  setState(documentState());
  m_editor->forceActiveFocus();

  QTest::keyClick(m_view, Qt::Key_B);
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("brush"));
  QTest::keyClick(m_view, Qt::Key_E);
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("eraser"));
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));

  const double start = m_editor->property("paintSize").toDouble();
  QTest::keyClick(m_view, Qt::Key_BracketRight);
  QCOMPARE(m_editor->property("paintSize").toDouble(), start + 1.0);
  QTest::keyClick(m_view, Qt::Key_BracketRight, Qt::ShiftModifier);
  QCOMPARE(m_editor->property("paintSize").toDouble(), start + 11.0);
  QTest::keyClick(m_view, Qt::Key_BracketLeft);
  QCOMPARE(m_editor->property("paintSize").toDouble(), start + 10.0);

  QCOMPARE(m_editor->property("paintColor").toString(), QStringLiteral("#000000"));
  QTest::keyClick(m_view, Qt::Key_X);
  QCOMPARE(m_editor->property("paintColor").toString(), QStringLiteral("#ffffff"));
  QCOMPARE(m_editor->property("paintBackgroundColor").toString(),
           QStringLiteral("#000000"));
  QTest::keyClick(m_view, Qt::Key_D);
  QCOMPARE(m_editor->property("paintColor").toString(), QStringLiteral("#000000"));
  QCOMPARE(m_editor->property("paintBackgroundColor").toString(),
           QStringLiteral("#ffffff"));

  // Typing into a field keeps its own keys: B/E/[/] must not fire from the
  // field's keystrokes, which is why the handlers live on the view and not on
  // a window-wide Shortcut.
  QQuickItem* field = expectItem("paintColorField");
  field->forceActiveFocus();
  QTest::qWait(10);
  QTest::keyClick(m_view, Qt::Key_B);
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("eraser"));
  m_editor->forceActiveFocus();

  QVERIFY(!m_editor->property("panelsHidden").toBool());
  QTest::keyClick(m_view, Qt::Key_Tab);
  QTRY_VERIFY(m_editor->property("panelsHidden").toBool());
  QVERIFY(!expectItem("editorTools")->isVisible());
  QVERIFY(!expectItem("editorInspector")->isVisible());
  QTest::keyClick(m_view, Qt::Key_Tab);
  QTRY_VERIFY(!m_editor->property("panelsHidden").toBool());
  QVERIFY(expectItem("editorTools")->isVisible());
  QVERIFY(expectItem("editorInspector")->isVisible());
  QCOMPARE(m_commands->count(), 0);
}

void TestEditor::ctrlZUndoesAndCtrlShiftZRedoes()
{
  setState(documentState());
  m_editor->forceActiveFocus();

  QTest::keyClick(m_view, Qt::Key_Z, Qt::ControlModifier);
  QCOMPARE(m_commands->count(), 1);
  QCOMPARE(m_commands->at(0).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_undo"));
  QTest::keyClick(m_view, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
  QCOMPARE(m_commands->count(), 2);
  QCOMPARE(m_commands->at(1).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_redo"));
}

/// Space is Krita's temporary pan: while it is held the left button moves the
/// picture instead of painting, and no stroke command is sent.
void TestEditor::spacePansInsteadOfPainting()
{
  setState(documentState());
  clickItem(expectItem("toolBrush"));
  m_editor->forceActiveFocus();
  // Fit shows the whole picture, so give the pan some room first.
  QMetaObject::invokeMethod(m_editor, "zoomIn");
  QMetaObject::invokeMethod(m_editor, "zoomIn");
  QTest::qWait(20);

  QObject* pan = findObject(QStringLiteral("editorPanHandler"));
  QVERIFY(pan != nullptr);
  QVERIFY2(!pan->property("acceptedButtons").value<Qt::MouseButtons>().testFlag(Qt::LeftButton),
           "the armed brush still gave the left button to the pan");

  QTest::keyPress(m_view, Qt::Key_Space);
  QTRY_VERIFY(m_editor->property("spacePanning").toBool());
  QVERIFY2(pan->property("acceptedButtons").value<Qt::MouseButtons>().testFlag(Qt::LeftButton),
           "Space did not hand the left button back to the pan");

  QQuickItem* host =
    qobject_cast<QQuickItem*>(findObject(QStringLiteral("editorCanvasHost")));
  QVERIFY(host != nullptr);
  const QPointF from =
    host->mapToScene(QPointF(host->width() * 0.5, host->height() * 0.5));
  const double beforeX = m_editor->property("offsetX").toDouble();
  dragScene(from, from + QPointF(70, 0), 6);

  QCOMPARE(m_commands->count(), 0);
  QVERIFY2(qAbs(m_editor->property("offsetX").toDouble() - beforeX) > 1.0,
           "Space + drag did not pan the picture");

  QTest::keyRelease(m_view, Qt::Key_Space);
  QTRY_VERIFY(!m_editor->property("spacePanning").toBool());
  QVERIFY2(!pan->property("acceptedButtons").value<Qt::MouseButtons>().testFlag(Qt::LeftButton),
           "the pan still owns the left button after Space came up");
}

QTEST_MAIN(TestEditor)
#include "tst_editor.moc"
