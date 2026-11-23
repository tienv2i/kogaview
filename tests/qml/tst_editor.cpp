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

#include <utility>

#include "stubthumbnailcache.h"

namespace {

QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}

constexpr int kHostWidth = 1100;
constexpr int kHostHeight = 700;

/// A command answered the way the gateway answers it: state is published while
/// the signal is still being emitted, before `command()` returns to QML. The
/// crop test uses it to prove the fields are empty in time for the document-size
/// handlers to seed a fresh frame.
class CommandAnswerer : public QObject
{
  Q_OBJECT
public:
  CommandAnswerer(QObject* editor, QVariantMap editorState)
    : m_editor(editor), m_editorState(std::move(editorState))
  {
  }

public slots:
  void answer(const QVariant&)
  {
    QVariantMap state;
    state.insert(QStringLiteral("editor"), m_editorState);
    m_editor->setProperty("state", state);
  }

private:
  QObject* m_editor;
  QVariantMap m_editorState;
};

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
  void theConstraintButtonLocksTheTwoSides();
  void resizeCarriesThePadFill();
  void theResizeKeyboardReachesWidthHeightAndApply();
  void theResizeDialogHasNoPreviewSurfaces();
  void thePaintToolSendsOneStrokeOnRelease();
  void theEraserStrokeCarriesItsModeAndBrush();
  void theKritaKeysPickTheToolsAndAdjustTheBrush();
  void theColourPairIsTheEditorsOnePair();
  void theJpegWarningSitsInTheBackgroundList();
  void ctrlZUndoesAndCtrlShiftZRedoes();
  void spacePansInsteadOfPainting();
  void theOriginalThumbnailCarriesTheSavedFileIdentity();
  void cropStartsWithNoFrameAndClickBuildsOne();
  void cropApplyEmitsTheTypedRectangle();
  void theCropPresetsFitInsideTheDocument();
  void aGrowingCropReachesOutsideThePicture();
  void theCropRatioLinksTheSides();
  void theCropAnchorPlacesTheRectangle();
  void theCropLocksChooseWhichFieldIsAnInput();
  void theCropFieldsCreateTheFrame();
  void theCropFrameIsDrawnAndDragged();
  void theCropRatioLocksTheFrameDrag();
  void aLockedSidePinsTheFrameDrag();
  void theCropKeysNudgeResizeAndApply();
  void theAppliedCropLeavesAFreshFrame();
  void theCropFrameRefitsAfterADocumentChange();
  void theCropFrameDrawsItsGuidesAndShade();
  void theTransformToolDragsCornersAndEdges();
  void theTransformPreviewIsDrawnOnTheCanvas();
  void boundingBoxModifiersWorkInCropAndTransform();
  void anInvalidOrEmptySizeKeepsApplyDisabled();
  void theMiniToolbarFoldsTheSecondaryActions_data();
  void theMiniToolbarFoldsTheSecondaryActions();
  void thePaletteHoldsTheToolsAndTheInspectorTheirOptions();
  void thePaletteSelectsTheToolsOptions();
  void theInspectorSplitsToolsFromThreeReferenceTabs();
  void theReferenceDockFitsItsPage();
  void thePanelChecklistHidesAndRestoresTheSidebar();
  void armingAToolBringsItsPanelBack();
  void theDividerRemembersTheReferenceHeight();
  void thePointerSaysItHasNoOptions();
  void theReferenceZoneKeepsRoomWhenTheWindowIsShort();
  void theResizeFormReturnsToThePointer();
  void theOriginalTabShowsTheSavedFile();
  void theToolRailIsAnIconColumn();
  void theUnitsAreAnotherSpellingOfTheSamePixels();
  void theResizeFormTakesPercentagesToo();
  void resetRestoresTheCropOptionsAndKeepsTheFrame();
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
  /// Accept every patch the view asks for, as the shell does.
  void applyLayoutRequested(const QVariant& patch);

private:
  QQuickItem* visualItem(const QString& name) const;
  /// The shell's half of the layout contract, for a view loaded on its own: a
  /// patch is merged into `layout`, the same call `Main.qml` makes.
  void resetLayout();
  void layoutPatched(const QVariant& patch);
  void setLayoutValue(const QString& key, const QVariant& value);
  QVariantMap m_layout;
  QObject* findObject(const QString& name) const;
  static QVariant readQml(QObject* object, const QString& expression);
  void clickItem(QQuickItem* item);
  /// Scroll the tool-options column until `item` is inside its viewport. The
  /// pinned Crop action row wraps to two rows in the default 260 px dock, so
  /// the anchor pad sits just under the fold; a hand scrolls it into view.
  void scrollOptionsIntoView(QQuickItem* item);
  /// Click a control that closes the Resize form and wait for its modal overlay
  /// to be gone. `opened` goes false one frame before the dim overlay does, and
  /// a click that lands in that frame belongs to the overlay.
  void closeResizeDialog(QQuickItem* control);
  void dragScene(const QPointF& from, const QPointF& to, int steps = 6);
  void typeInto(QQuickItem* field, const QString& text);
  /// Choose a unit from the selector inside a `UnitField`, the way the
  /// dropdown's own signal does, so the field's handler is the path under test.
  void chooseUnit(const char* field, const QString& unit);
  /// Type a ratio the way a hand does, including the `:` or `/` separator
  /// (`typeInto` maps one QChar to one key, which cannot type a shifted colon).
  void typeRatioInto(QQuickItem* field, const QString& text);
  void selectTool(const char* name);
  /// Open one of the dock's reference tabs and wait for the page to follow.
  void selectRightTab(const char* key);
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
  // A crop tool starts free: a frame dragged on the picture keeps the shape the
  // user drew, and picking a ratio is the lock. This is read before `init()`
  // writes the per-case state, so it observes the QML declaration's default,
  // not a convention this suite applies.
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("free"));

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

  QVERIFY(QObject::connect(m_editor, SIGNAL(layoutRequested(QVariant)),
                           this, SLOT(applyLayoutRequested(QVariant))));
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
      // The form owns fitMode/filter now — the background is the Editor's, so
      // it is reset below with the rest of the pair. A case that chose a mode
      // must not decide what the next one opens on.
      dialog->setProperty("fitMode", QStringLiteral("stretch"));
      dialog->setProperty("filter", QStringLiteral("auto"));
      dialog->setProperty("constraint", true);
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
  m_editor->setProperty("cropRatio", QStringLiteral("free"));
  m_editor->setProperty("cropAnchor", QStringLiteral("center"));
  m_editor->setProperty("cropMode", QStringLiteral("center"));
  m_editor->setProperty("cropLockWidth", false);
  m_editor->setProperty("cropLockHeight", false);
  m_editor->setProperty("cropLockRatio", false);
  // The rail's fold and the fields' units are view state; a case must not
  // decide what the next one opens on. The fold is layout state, so it is an
  // entry in the map `resetLayout()` already wrote.

  for (const char* name : {"cropWidth", "cropHeight", "cropX", "cropY", "resizeWidth", "resizeHeight"}) {
    if (QQuickItem* field = visualItem(QString::fromLatin1(name))) {
      field->setProperty("unit", QStringLiteral("px"));
    }
  }
  m_editor->setProperty("pendingCropResult", QVariant());
  if (QQuickItem* box = visualItem(QStringLiteral("cropMode"))) {
    box->setProperty("currentIndex", 0);
  }
  m_editor->setProperty("transformMode", QStringLiteral("free"));
  m_editor->setProperty("transformCorners", QVariantList());
  m_editor->setProperty("paintMode", QStringLiteral("brush"));
  // The pair is Editor-wide view state: a case that swapped, reset or picked a
  // background must not decide what the next one opens on.
  m_editor->setProperty("foregroundColor", QStringLiteral("#000000"));
  m_editor->setProperty("backgroundColor", QStringLiteral("#ffffff"));
  m_editor->setProperty("backgroundTransparent", false);
  m_editor->setProperty("paintSize", 24.0);
  m_editor->setProperty("paintOpacity", 100);
  m_editor->setProperty("paintStroke", QVariantList());
  m_editor->setProperty("paintStroking", false);
  m_editor->setProperty("spacePanning", false);
  // The dock widths, the rail's columns, the reference tab and the panel list
  // are the saved layout, which the shell owns: a case must not decide what the
  // next one opens on. This is the same map Core hands the window.
  resetLayout();
  m_editor->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
  // Zoom, pan and fit are presentation state that survives a case. Two cases
  // deliberately zoom in and pan, and a later case that derives a click from
  // the canvas used to inherit where the picture had been left — it then
  // landed outside the window (or on the picture, for a case that clicks the
  // matte) and the click did the wrong thing. Every case starts fitted and
  // centred, which is also what the window does when a document arrives; a
  // case that wants 1:1 asks for it with `actualSize()`.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "fit"));
  for (const char* name : {"cropLockWidth", "cropLockHeight", "cropLockRatio"}) {
    if (QQuickItem* control = visualItem(QString::fromLatin1(name))) {
      control->setProperty("checked", false);
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

void TestEditor::scrollOptionsIntoView(QQuickItem* item)
{
  QVERIFY(item != nullptr);
  QQuickItem* flickable = item->parentItem();
  while (flickable != nullptr && !flickable->property("contentY").isValid())
    flickable = flickable->parentItem();
  QVERIFY(flickable != nullptr);
  const qreal contentY = flickable->property("contentY").toReal();
  const qreal top = item->mapToItem(flickable, QPointF(0, 0)).y() + contentY;
  const qreal bottom = top + item->height();
  const qreal height = flickable->height();
  qreal target = contentY;
  if (top - target < 4)
    target = top - 4;
  if (bottom - target > height - 4)
    target = bottom - height + 4;
  const qreal max = qMax<qreal>(
    0, flickable->property("contentHeight").toReal() - flickable->height());
  flickable->setProperty("contentY", qBound<qreal>(0, target, max));
  QTest::qWait(30);
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
static QQuickItem* textInput(QQuickItem* field)
{
  if (!field) return nullptr;
  QQuickItem* input = field->property("inputField").value<QQuickItem*>();
  return input ? input : field;
}

void TestEditor::typeInto(QQuickItem* field, const QString& text)
{
  QVERIFY(field != nullptr);
  // A `UnitField` is a row: the selector is beside the text, and the text
  // control is the one that takes the keyboard.
  field = textInput(field);
  field->forceActiveFocus();
  QTest::qWait(10);
  QTest::keyClick(m_view, Qt::Key_A, Qt::ControlModifier);
  for (const QChar character : text) {
    QTest::keyClick(m_view, static_cast<Qt::Key>(character.unicode()));
  }
  QTest::qWait(20);
}

void TestEditor::chooseUnit(const char* field, const QString& unit)
{
  const QString name = QString::fromLatin1(field) + QStringLiteral("Unit");
  QQuickItem* box = expectItem(name.toLatin1().constData());
  const int index = unit == QStringLiteral("%") ? 1 : 0;
  // The same signal a selection emits, so the field's own handler is the path
  // under test rather than a property write that could bypass it.
  QVERIFY2(QMetaObject::invokeMethod(box, "activated", Q_ARG(int, index)),
           qPrintable(name + QStringLiteral(" has no activated()")));
  QTest::qWait(10);
}

void TestEditor::typeRatioInto(QQuickItem* field, const QString& text)
{
  QVERIFY(field != nullptr);
  field = textInput(field);
  field->forceActiveFocus();
  QTest::qWait(10);
  QTest::keyClick(m_view, Qt::Key_A, Qt::ControlModifier);
  for (const QChar character : text) {
    Qt::Key key = static_cast<Qt::Key>(character.unicode());
    if (character == QLatin1Char(':')) {
      key = Qt::Key_Colon;
    } else if (character == QLatin1Char('/')) {
      key = Qt::Key_Slash;
    }
    QTest::keyClick(m_view, key);
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

/// The dock's reference tabs are presentation, like the rail's fold: clicking
/// one writes `rightTab` and sends no command.
void TestEditor::selectRightTab(const char* key)
{
  const QString wanted = QString::fromLatin1(key);
  if (m_editor->property("rightTab").toString() == wanted) {
    return;
  }
  clickItem(expectItem(QStringLiteral("editorTab_%1").arg(wanted).toLatin1().constData()));
  QTRY_COMPARE(m_editor->property("rightTab").toString(), wanted);
}

/// The saved layout the view sees. The shell owns it (`state.layout`), the
/// view reports interactions, and the patch is merged here exactly as
/// `Main.qml`'s `mergeLayout` does — one key at a time, panels included.
void TestEditor::layoutPatched(const QVariant& patch)
{
  const QVariantMap current = m_layout;
  const QVariantMap changes = patch.toMap();
  QVariantMap next;
  const QStringList keys = { QStringLiteral("leftWidth"), QStringLiteral("rightWidth"),
                             QStringLiteral("editorToolColumns"),
                             QStringLiteral("editorReferenceHeight"),
                             QStringLiteral("editorReferenceTab") };
  for (const QString& key : keys) {
    next.insert(key, changes.contains(key) ? changes.value(key) : current.value(key));
  }
  QVariantMap panels = current.value(QStringLiteral("panels")).toMap();
  const QVariantMap changedPanels = changes.value(QStringLiteral("panels")).toMap();
  for (auto it = changedPanels.begin(); it != changedPanels.end(); ++it) {
    panels.insert(it.key(), it.value());
  }
  next.insert(QStringLiteral("panels"), panels);
  m_layout = next;
  m_editor->setProperty("layout", next);
}

void TestEditor::resetLayout()
{
  QVariantMap layout;
  layout.insert(QStringLiteral("leftWidth"), 260);
  layout.insert(QStringLiteral("rightWidth"), 260);
  layout.insert(QStringLiteral("editorToolColumns"), 2);
  layout.insert(QStringLiteral("editorReferenceHeight"), 0);
  layout.insert(QStringLiteral("editorReferenceTab"), QStringLiteral("info"));
  QVariantMap panels;
  const QStringList keys = {
    QStringLiteral("browser.quickAccess"),  QStringLiteral("browser.explorer"),
    QStringLiteral("browser.preview"),      QStringLiteral("browser.batch"),
    QStringLiteral("viewer.quickAccess"),   QStringLiteral("viewer.explorer"),
    QStringLiteral("viewer.info"),          QStringLiteral("editor.quickAccess"),
    QStringLiteral("editor.explorer"),      QStringLiteral("editor.tools"),
    QStringLiteral("editor.options"),       QStringLiteral("editor.info"),
    QStringLiteral("editor.history"),       QStringLiteral("editor.original")
  };
  for (const QString& key : keys) {
    panels.insert(key, true);
  }
  layout.insert(QStringLiteral("panels"), panels);
  m_layout = layout;
  m_editor->setProperty("layout", layout);
}

void TestEditor::setLayoutValue(const QString& key, const QVariant& value)
{
  QVariantMap patch;
  patch.insert(key, value);
  layoutPatched(patch);
}

void TestEditor::applyLayoutRequested(const QVariant& patch)
{
  layoutPatched(patch);
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
  // The identity of the file the Original tab draws: a path repeats after a
  // save and on the next run, these two numbers do not.
  editor.insert(QStringLiteral("fileModified"), Q_INT64_C(1700000000002));
  editor.insert(QStringLiteral("fileSize"), Q_INT64_C(123456));
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
  // The Editor's dock is a Core-owned panel like the Browser's. The flag is
  // set here because a case that only publishes a document has no window
  // configuration behind it; the toggle itself is Core's (see `tst_settings`
  // and the Core tests).
  state.insert(QStringLiteral("rightPanelEditor"), true);
  state.insert(QStringLiteral("language"), QStringLiteral("en"));
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

  // The keyboard path: the form opens with the width focused and selected, so
  // Ctrl+Alt+I then typing replaces the number instead of appending to it.
  QTRY_VERIFY(textInput(width)->hasActiveFocus());
  QTRY_COMPARE(textInput(width)->property("selectedText").toString(), QStringLiteral("4000"));

  // That pair is Core's no-op, so Apply says so before it is pressed.
  QVERIFY(!expectItem("resizeApply")->property("enabled").toBool());

  // The chain starts locked to the document's shape, the fit starts on the
  // lossless stretch, and the filter starts on Auto: the three answers the form
  // offers are described before anything is typed.
  QQuickItem* chain = expectItem("resizeConstraint");
  QVERIFY(chain->isVisible());
  QVERIFY(chain->property("checked").toBool());
  QQuickItem* fit = expectItem("resizeFit");
  QVERIFY(fit->isVisible());
  QCOMPARE(fit->property("count").toInt(), 3);
  QCOMPARE(fit->property("currentIndex").toInt(), 0);
  QCOMPARE(fit->property("currentText").toString(), QStringLiteral("Stretch to size"));
  // Only a pad paints the leftover, so the background row is not on screen
  // until that mode is chosen.
  QVERIFY(!expectItem("resizeBackground")->isVisible());
  QCOMPARE(expectItem("resizeFilter")->property("currentIndex").toInt(), 0);
  QCOMPARE(expectItem("resizeFilter")->property("currentText").toString(),
           QStringLiteral("Auto"));

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
           QStringLiteral("Pointer options"));
  // The pointer's dock opens on Info: the document's name, size and save
  // target. The history and the thumbnail are one tab each, not rows that a
  // tool would push away.
  QCOMPARE(m_editor->property("rightTab").toString(), QStringLiteral("info"));
  QVERIFY(expectItem("imageName")->isVisible());
  QVERIFY(expectItem("imageSize")->isVisible());
  QVERIFY(expectItem("saveTarget")->isVisible());
  QVERIFY(!expectItem("originalThumbnail")->isVisible());
  QVERIFY(!expectItem("historyList")->isVisible());

  selectRightTab("history");
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

  selectRightTab("original");
  QVERIFY(expectItem("originalThumbnail")->isVisible());
  QVERIFY(!expectItem("originalCaption")->property("text").toString().isEmpty());
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

  QCOMPARE(m_commands->count(), 3);
  QCOMPARE(m_commands->at(0).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_undo"));
  QCOMPARE(m_commands->at(1).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_redo"));
  QCOMPARE(m_commands->at(2).at(0).toMap().value("type").toString(),
           QStringLiteral("editor_reset"));
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
  QCOMPARE(command.value("fill_alpha").toInt(), 255);
  QCOMPARE(command.value("filter").toString(), QStringLiteral("auto"));
  // Apply ends the question: the form is gone once the size has been asked.
  QTRY_VERIFY(!resizeDialogObject()->property("opened").toBool());
}

/// The dropdown offers concrete sizes for every ratio, whose sides are exact
/// multiples of 64, so a preset never produces fractional pixels at any scale.
/// Choosing one fills both fields and becomes the shape the chain keeps; the
/// shared ratio table is Crop's now, so this case checks it is still the short
/// common list the two tools were given.
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
  // The preset also becomes the shape the chain keeps, without a ratio combo.
  const QVariantMap locked = resizeDialogObject()->property("lockedRatio").toMap();
  QCOMPARE(locked.value("width").toInt(), 1024);
  QCOMPARE(locked.value("height").toInt(), 1024);
}

/// The chain is the whole aspect lock: on, typing one side recalculates the
/// other from the shape the form captured; off, the pair is two independent
/// numbers. There is no ratio list to disagree with it.
void TestEditor::typingOneSideKeepsTheChosenRatio()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();
  QCOMPARE(resizeDialogObject()->property("constraint").toBool(), true);

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");

  // The document's own 4:3 shape by default.
  typeInto(width, QStringLiteral("800"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));
  typeInto(height, QStringLiteral("1200"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1200"));

  // Unlocking stops the link: the other side stays where it was.
  QVERIFY(QMetaObject::invokeMethod(resizeDialogObject(), "setConstraint",
                                    Q_ARG(QVariant, false)));
  typeInto(width, QStringLiteral("300"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("300"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1200"));

  // Locking again captures the pair on screen — 300:1200 — not the document's
  // 4:3, which is what makes "constrain" useful after a custom pair is typed.
  QVERIFY(QMetaObject::invokeMethod(resizeDialogObject(), "setConstraint",
                                    Q_ARG(QVariant, true)));
  typeInto(width, QStringLiteral("600"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("2400"));
}

/// The lock is a snapshot of the pair on screen, and it belongs to this form:
/// Crop's ratio table is untouched, and a fresh visit asks the question again
/// from the document's size rather than resuming the previous answer.
void TestEditor::theCurrentRatioLocksTheTypedPair()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  QVERIFY(QMetaObject::invokeMethod(dialog, "setConstraint",
                                    Q_ARG(QVariant, false)));
  typeInto(width, QStringLiteral("1000"));
  typeInto(height, QStringLiteral("700"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("700"));

  // Enabling the chain snapshots what the two fields hold, not the document.
  QVERIFY(QMetaObject::invokeMethod(dialog, "setConstraint",
                                    Q_ARG(QVariant, true)));
  const QVariantMap captured = dialog->property("lockedRatio").toMap();
  QCOMPARE(captured.value("width").toInt(), 1000);
  QCOMPARE(captured.value("height").toInt(), 700);

  typeInto(width, QStringLiteral("2000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1400"));
  typeInto(height, QStringLiteral("700"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1000"));

  // Crop has its own ratio table: a 3:2 crop must not change the resize lock.
  closeResizeDialog(expectItem("resizeCancel"));
  QTRY_VERIFY(!dialog->property("opened").toBool());
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("free")))));
  typeInto(expectItem("cropWidth"), QStringLiteral("300"));
  typeInto(expectItem("cropHeight"), QStringLiteral("200"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("3:2")))));
  typeInto(expectItem("cropWidth"), QStringLiteral("600"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("400"));

  // A second visit is a new question: opening the form fills it from the
  // document again, and the previous lock is not silently resumed.
  selectTool("pointer");
  openResizeDialog();
  QCOMPARE(expectItem("resizeWidth")->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(expectItem("resizeHeight")->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(dialog->property("constraint").toBool(), true);
  const QVariantMap fresh = dialog->property("lockedRatio").toMap();
  QCOMPARE(fresh.value("width").toInt(), 4000);
  QCOMPARE(fresh.value("height").toInt(), 3000);
  QCOMPARE(m_commands->count(), 0);
}

/// The chain button is the lock. Pressing it off leaves the two fields
/// independent; pressing it on captures the pair and links them again. The old
/// +/- steppers are gone, so this is the only view-owned way to change the
/// shape without typing.
void TestEditor::theConstraintButtonLocksTheTwoSides()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  QQuickItem* chain = expectItem("resizeConstraint");
  QVERIFY(chain->isVisible());
  QVERIFY(chain->property("checked").toBool());
  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");

  // Pressing the chain off leaves Height alone.
  clickItem(chain);
  QVERIFY(!dialog->property("constraint").toBool());
  width->setProperty("text", QStringLiteral("1000"));
  QMetaObject::invokeMethod(width, "textEdited");
  QCOMPARE(width->property("text").toString(), QStringLiteral("1000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));

  // Pressing it on locks the 1000 × 3000 pair on screen.
  clickItem(chain);
  QVERIFY(dialog->property("constraint").toBool());
  const QVariantMap locked = dialog->property("lockedRatio").toMap();
  QCOMPARE(locked.value("width").toInt(), 1000);
  QCOMPARE(locked.value("height").toInt(), 3000);
  width->setProperty("text", QStringLiteral("500"));
  QMetaObject::invokeMethod(width, "textEdited");
  QCOMPARE(height->property("text").toString(), QStringLiteral("1500"));
  QCOMPARE(m_commands->count(), 0);
}

/// The fit mode says what an aspect change does, and only the pad carries a
/// background. What travels in the command is the mode, the colour the pad
/// paints (if any) and the kernel; the anchor does not exist any more, and
/// neither does a silent centre crop that Core alone decides.
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

  // Three modes, in the order the form shows them, and the lossless one first.
  QQuickItem* fit = expectItem("resizeFit");
  QCOMPARE(fit->property("count").toInt(), 3);
  QCOMPARE(fit->property("currentText").toString(), QStringLiteral("Stretch to size"));
  // `Stretch to size` has no background to pick.
  QVERIFY(!expectItem("resizeBackground")->isVisible());

  // The default command is a stretch with no fill: the size is the whole
  // request, and Core must not decide to discard the edges.
  expectItem("resizeWidth")->setProperty("text", QStringLiteral("1024"));
  expectItem("resizeHeight")->setProperty("text", QStringLiteral("576"));
  QTest::qWait(20);
  clickItem(expectItem("resizeApply"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap stretch = m_commands->at(0).at(0).toMap();
  QCOMPARE(stretch.value("type").toString(), QStringLiteral("editor_resize"));
  QCOMPARE(stretch.value("mode").toString(), QStringLiteral("stretch"));
  QCOMPARE(stretch.value("fill").toList().size(), 0);
  QVERIFY(!stretch.contains(QStringLiteral("anchor")));

  // `Crop to fill` is the old behaviour, now asked for on purpose. It still
  // carries no fill, because it paints nothing.
  QTRY_VERIFY(!dialog->property("opened").toBool());
  openResizeDialog();
  dialog->setProperty("fitMode", QStringLiteral("cover"));
  expectItem("resizeWidth")->setProperty("text", QStringLiteral("1024"));
  expectItem("resizeHeight")->setProperty("text", QStringLiteral("576"));
  QTest::qWait(20);
  QVERIFY(!expectItem("resizeBackground")->isVisible());
  clickItem(expectItem("resizeApply"));
  QCOMPARE(m_commands->count(), 2);
  const QVariantMap cover = m_commands->at(1).at(0).toMap();
  QCOMPARE(cover.value("mode").toString(), QStringLiteral("cover"));
  QCOMPARE(cover.value("fill").toList().size(), 0);

  // `Fit with background` is the only mode with a colour, and choosing it is
  // what puts the background row on screen.
  QTRY_VERIFY(!dialog->property("opened").toBool());
  openResizeDialog();
  dialog->setProperty("fitMode", QStringLiteral("pad"));
  QTRY_VERIFY(expectItem("resizeBackground")->isVisible());
  QQuickItem* background = expectItem("resizeBackground");
  QVERIFY(background->isVisible());
  // The row is not a list any more: a padding paints the Editor's one
  // background, so the row names the colour the pair holds and its swatch is
  // the way to the list that changes it.
  QVERIFY(expectItem("resizeBackgroundSwatch")->isVisible());
  QVERIFY(!expectItem("resizeBackgroundCheckerboard")->isVisible());
  QCOMPARE(expectItem("resizeBackgroundName")->property("text").toString(),
           QStringLiteral("#ffffff"));

  // A colour picked anywhere is the same background, and the pad carries it as
  // it always did: three RGB bytes, an opaque alpha, the chosen filter and the
  // mode that reads them.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setBackgroundColor",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("#ff0000")))));
  dialog->setProperty("filter", QStringLiteral("bicubic"));
  QCOMPARE(expectItem("resizeBackgroundName")->property("text").toString(),
           QStringLiteral("#ff0000"));
  expectItem("resizeWidth")->setProperty("text", QStringLiteral("1024"));
  expectItem("resizeHeight")->setProperty("text", QStringLiteral("576"));
  QTest::qWait(20);
  clickItem(expectItem("resizeApply"));

  QCOMPARE(m_commands->count(), 3);
  const QVariantMap command = m_commands->at(2).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_resize"));
  QCOMPARE(command.value("mode").toString(), QStringLiteral("pad"));
  const QVariantList fill = command.value("fill").toList();
  QCOMPARE(fill.size(), 3);
  QCOMPARE(fill.at(0).toInt(), 255);
  QCOMPARE(fill.at(1).toInt(), 0);
  QCOMPARE(fill.at(2).toInt(), 0);
  QCOMPARE(command.value("fill_alpha").toInt(), 255);
  QCOMPARE(command.value("filter").toString(), QStringLiteral("bicubic"));

  // A transparent background is the same pad with alpha 0, so Core can leave
  // the leftover clear instead of painting a colour there. The row shows the
  // checkerboard, because the background is still a colour with no alpha.
  QTRY_VERIFY(!dialog->property("opened").toBool());
  openResizeDialog();
  dialog->setProperty("fitMode", QStringLiteral("pad"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setBackgroundTransparent",
                                    Q_ARG(QVariant, QVariant(true))));
  QVERIFY(expectItem("resizeBackgroundCheckerboard")->isVisible());
  QCOMPARE(expectItem("resizeBackgroundName")->property("text").toString(),
           QStringLiteral("Transparent"));
  expectItem("resizeWidth")->setProperty("text", QStringLiteral("1024"));
  expectItem("resizeHeight")->setProperty("text", QStringLiteral("576"));
  QTest::qWait(20);
  clickItem(expectItem("resizeApply"));
  QCOMPARE(m_commands->count(), 4);
  const QVariantMap clear = m_commands->at(3).at(0).toMap();
  QCOMPARE(clear.value("mode").toString(), QStringLiteral("pad"));
  // The bytes are Core's to ignore at alpha zero, but they are still the pair's
  // colour: a command that sent the painted colour with alpha 0 would describe
  // a background the next reader could paint, so the convention is pinned here
  // as it is for Crop's own clear border.
  QCOMPARE(clear.value("fill").toList(), QVariantList({0, 0, 0}));
  QCOMPARE(clear.value("fill_alpha").toInt(), 0);
}

/// Ctrl+Alt+I opens the form through the window shortcut; inside it the
/// keyboard route is Width (selected) → Tab → Height → Enter → Apply. This case
/// drives the form's own focus path (the window shortcut is a source guard in
/// `tst_settings`): open on the palette, type a width, Tab, type a height, Enter.
void TestEditor::theResizeKeyboardReachesWidthHeightAndApply()
{
  setState(documentState());
  openResizeDialog();
  QObject* dialog = resizeDialogObject();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  QTRY_VERIFY(textInput(width)->hasActiveFocus());
  QTRY_COMPARE(textInput(width)->property("selectedText").toString(), QStringLiteral("4000"));

  // Typing replaces the selected document width.
  typeInto(width, QStringLiteral("800"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));

  // Tab lands on Height, and typing there keeps the chain's shape.
  QTest::keyClick(m_view, Qt::Key_Tab);
  QTRY_VERIFY(textInput(height)->hasActiveFocus());
  typeInto(height, QStringLiteral("900"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("900"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1200"));

  // Enter is Apply, not the default button of some other control.
  QTest::keyClick(m_view, Qt::Key_Return);
  QTRY_COMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_resize"));
  QCOMPARE(command.value("width").toInt(), 1200);
  QCOMPARE(command.value("height").toInt(), 900);
  QTRY_VERIFY(!dialog->property("opened").toBool());
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

/// The Original tab's thumbnail is keyed on the saved file's path and identity,
/// not on the working preview. A save rewrites the file, so its mtime and size
/// are what tell a fresh picture from the one the cache answered last time;
/// asking for the preview would show the unsaved pixels instead.
void TestEditor::theOriginalThumbnailCarriesTheSavedFileIdentity()
{
  StubThumbnailCache cache;
  m_editor->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(&cache)));

  setState(documentState());
  selectTool("pointer");
  selectRightTab("original");

  QTRY_VERIFY_WITH_TIMEOUT(
    !cache.callsFor(QStringLiteral("/pics/photo.png")).isEmpty(), 2000);
  const StubThumbnailCache::Call call =
    cache.lastCallFor(QStringLiteral("/pics/photo.png"));
  QCOMPARE(call.modified, Q_INT64_C(1700000000002));
  QCOMPARE(call.size, Q_INT64_C(123456));
  // A real size bucket, not the zero the panel asked for while it was handed
  // the cache instead of the `ThumbnailBook` that maps a drawn size onto one.
  QVERIFY2(call.edge >= 160,
           qPrintable(QStringLiteral("the tile asked the cache for edge %1").arg(call.edge)));
  // The working preview is not the file on disk.
  QVERIFY(cache.callsFor(m_previewOne).isEmpty());

  m_editor->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
}

/// Crop does not guess: arming the tool leaves the picture unframed, and the
/// frame is the user's answer — drawn on the canvas or typed in the panel. A
/// click without travel asks for the whole picture, which is the one rectangle
/// that is always legal; a click while a frame already exists changes nothing.
void TestEditor::cropStartsWithNoFrameAndClickBuildsOne()
{
  setState(documentState());
  selectTool("crop");

  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* frame = expectItem("cropFrame");
  QQuickItem* createArea = expectItem("cropCreateArea");
  QQuickItem* apply = expectItem("applyCrop");

  QCOMPARE(width->property("text").toString(), QString());
  QCOMPARE(height->property("text").toString(), QString());
  QVERIFY(!frame->isVisible());
  QVERIFY(!apply->property("enabled").toBool());
  QVERIFY2(createArea->property("enabled").toBool(),
           "an unframed crop does not accept a new frame");
  QCOMPARE(m_commands->count(), 0);

  // A press and release at one point is a click, not a zero-size drag: it
  // takes the whole picture. The canvas is the view's fitted picture, so the
  // point is inside the window.
  QQuickItem* canvas = expectItem("canvas");
  const QPointF origin = canvas->mapToScene(QPointF(0, 0));
  const QPoint click = (origin + QPointF(120, 90)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, click);
  QTest::qWait(30);

  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));
  QVERIFY(frame->isVisible());
  // `MouseArea.enabled` is the property that decides whether it takes input;
  // the inherited `QQuickItem::enabled` is a different flag on this type.
  QVERIFY2(!createArea->property("enabled").toBool(),
           "a framed crop is still offering to create");
  // The whole picture is Core's `edit_noop`, so Apply stays down.
  QVERIFY(!apply->property("enabled").toBool());

  // A click inside the existing frame moves it by nothing; it does not replace
  // it with another whole-picture frame.
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier,
                    (origin + QPointF(50, 40)).toPoint());
  QTest::qWait(30);
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(m_commands->count(), 0);
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

  // The size first: changing a side re-places the rectangle through its anchor.
  // X/Y are the user's own placement and are typed last.
  typeInto(width, QStringLiteral("100"));
  typeInto(height, QStringLiteral("50"));
  cropX->setProperty("text", QStringLiteral("4"));
  cropY->setProperty("text", QStringLiteral("6"));
  QTest::qWait(20);
  QVERIFY(apply->property("enabled").toBool());
  QVERIFY(expectItem("cropFrame")->isVisible());

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
/// Core has to reject. Picking one also builds the frame when none exists.
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
  QVERIFY(expectItem("cropFrame")->isVisible());
  QCOMPARE(m_commands->count(), 0);
}

/// Crop's second answer to "may the frame leave the picture?": Grow lets the
/// rectangle start outside the picture and carries a fill colour for the new
/// border, while Center keeps the old inside-only rule.
void TestEditor::aGrowingCropReachesOutsideThePicture()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");

  // Center is the ordinary cut; Grow adds the fill row and the wider range.
  QQuickItem* mode = expectItem("cropMode");
  QVERIFY(mode->isVisible());
  QCOMPARE(m_editor->property("cropMode").toString(), QStringLiteral("center"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropMode",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("grow")))));
  QCOMPARE(m_editor->property("cropMode").toString(), QStringLiteral("grow"));
  // The border is painted with the Editor's background — the same colour a
  // padded resize uses — so Grow shows that swatch and not a list of its own.
  QVERIFY(expectItem("cropBackgroundSwatch")->isVisible());
  QVERIFY(findObject(QStringLiteral("cropBackground")) == nullptr);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setBackgroundColor",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("#000000")))));
  QCOMPARE(m_editor->property("backgroundColor").toString(), QStringLiteral("#000000"));
  QVERIFY(!expectItem("cropBackgroundCheckerboard")->isVisible());

  // A negative origin is part of the typed command: the new canvas begins
  // before the picture, and the rectangle reaches past both far edges. The
  // size is typed first because changing a side re-places the rectangle through
  // its anchor; the origin is the user's own placement and is typed last.
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* cropWidth = expectItem("cropWidth");
  QQuickItem* cropHeight = expectItem("cropHeight");
  typeInto(cropWidth, QStringLiteral("4200"));
  typeInto(cropHeight, QStringLiteral("3100"));
  typeInto(cropX, QStringLiteral("-100"));
  typeInto(cropY, QStringLiteral("-50"));
  QTest::qWait(20);
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("-100"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("-50"));

  // The border the command paints is previewed on the canvas before Apply.
  QQuickItem* growTop = expectItem("cropGrowTop");
  QVERIFY(growTop->isVisible());
  QVERIFY2(growTop->width() > 0 && growTop->height() > 0,
           "the grown border was not drawn above the picture");

  QQuickItem* apply = expectItem("applyCrop");
  QVERIFY(apply->property("enabled").toBool());
  clickItem(apply);
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_crop"));
  QCOMPARE(command.value("x").toInt(), -100);
  QCOMPARE(command.value("y").toInt(), -50);
  QCOMPARE(command.value("width").toInt(), 4200);
  QCOMPARE(command.value("height").toInt(), 3100);
  QCOMPARE(command.value("fill").toList(), QVariantList({0, 0, 0}));
  QCOMPARE(command.value("fill_alpha").toInt(), 255);

  // Transparent is the same grow with alpha 0: the border exists, but it is
  // clear rather than black.
  m_commands->clear();
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setBackgroundTransparent",
                                    Q_ARG(QVariant, QVariant(true))));
  QVERIFY(m_editor->property("backgroundTransparent").toBool());
  // A transparent background is drawn, not left blank: the swatch the border
  // row shows turns into the checkerboard.
  QVERIFY(expectItem("cropBackgroundCheckerboard")->isVisible());
  typeInto(cropWidth, QStringLiteral("4020"));
  typeInto(cropHeight, QStringLiteral("3020"));
  typeInto(cropX, QStringLiteral("-10"));
  typeInto(cropY, QStringLiteral("-10"));
  QTest::qWait(20);
  QVERIFY(apply->property("enabled").toBool());
  clickItem(apply);
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap clear = m_commands->at(0).at(0).toMap();
  QCOMPARE(clear.value("fill").toList(), QVariantList({0, 0, 0}));
  QCOMPARE(clear.value("fill_alpha").toInt(), 0);

  // A Grow rectangle that fits inside the picture has no border to paint, so it
  // travels as the ordinary cut: a present fill would invite Core to grow the
  // canvas it is already the size of.
  m_commands->clear();
  typeInto(cropWidth, QStringLiteral("800"));
  typeInto(cropHeight, QStringLiteral("600"));
  typeInto(cropX, QStringLiteral("100"));
  typeInto(cropY, QStringLiteral("100"));
  QTest::qWait(20);
  QCOMPARE(m_editor->property("cropMode").toString(), QStringLiteral("grow"));
  QVERIFY(apply->property("enabled").toBool());
  clickItem(apply);
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap inside = m_commands->at(0).at(0).toMap();
  QCOMPARE(inside.value("x").toInt(), 100);
  QCOMPARE(inside.value("y").toInt(), 100);
  QVERIFY2(inside.value("fill").isNull(),
           "an inside Grow rectangle must not carry a fill");

  // Back in Center the same field values are pulled inside the picture again,
  // so Apply cannot stay armed on a rectangle Core would reject.
  m_commands->clear();
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropMode",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("center")))));
  QCOMPARE(m_editor->property("cropMode").toString(), QStringLiteral("center"));
  QVERIFY(cropX->property("text").toInt() >= 0);
  QVERIFY(cropY->property("text").toInt() >= 0);
  QVERIFY(!expectItem("cropBackgroundSwatch")->isVisible());
}

/// Crop links Width and Height through its ratio field, and each size change
/// re-places the rectangle through the selected anchor.
void TestEditor::theCropRatioLinksTheSides()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");
  // A crop tool starts unconstrained: the frame drawn on the picture keeps the
  // shape the user drew, and a ratio is an explicit lock.
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("free"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("original")))));

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

  scrollOptionsIntoView(expectItem("cropAnchor_top_left"));
  clickItem(expectItem("cropAnchor_top_left"));
  QCOMPARE(m_editor->property("cropAnchor").toString(), QStringLiteral("top_left"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));

  scrollOptionsIntoView(expectItem("cropAnchor_bottom_right"));
  clickItem(expectItem("cropAnchor_bottom_right"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("3200"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("2200"));

  scrollOptionsIntoView(expectItem("cropAnchor_right"));
  clickItem(expectItem("cropAnchor_right"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("3200"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1100"));

  scrollOptionsIntoView(expectItem("cropAnchor_top"));
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

  // Picking a preset re-places the rectangle at the anchor too, and builds one
  // when the tool is still unframed.
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

/// The three locks decide which fields are inputs. Width+Height fix the shape
/// (Ratio becomes a consequence and its field is disabled); Width+Ratio derive
/// Height; Height+Ratio derive Width. A third lock is refused, and the refused
/// button snaps back rather than showing a lock the view does not hold.
void TestEditor::theCropLocksChooseWhichFieldIsAnInput()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");

  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* ratio = expectItem("cropRatio");
  QQuickItem* lockWidth = expectItem("cropLockWidth");
  QQuickItem* lockHeight = expectItem("cropLockHeight");
  QQuickItem* lockRatio = expectItem("cropLockRatio");
  QVERIFY(width->isVisible());
  QVERIFY(lockWidth->isVisible());
  QVERIFY(lockHeight->isVisible());
  QVERIFY(lockRatio->isVisible());
  QVERIFY(width->property("enabled").toBool());
  QVERIFY(height->property("enabled").toBool());
  QVERIFY(ratio->property("enabled").toBool());

  // A frame to lock: 800 × 600 at four thirds, centred.
  typeInto(width, QStringLiteral("800"));
  typeInto(height, QStringLiteral("600"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("1600"));

  // Width locked: Height is still an input and follows the typed value.
  clickItem(lockWidth);
  QVERIFY(m_editor->property("cropLockWidth").toBool());
  QVERIFY(!width->property("enabled").toBool());
  QVERIFY(height->property("enabled").toBool());
  typeInto(height, QStringLiteral("300"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("300"));

  // Width+Ratio: the shape is fixed, so Height is derived and disabled.
  clickItem(lockRatio);
  QVERIFY(m_editor->property("cropLockRatio").toBool());
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("8:3"));
  QVERIFY(!height->property("enabled").toBool());
  QVERIFY(!ratio->property("enabled").toBool());
  // A side plus the ratio fixes the shape, so a handle has nothing to change.
  QVERIFY2(!m_editor->property("cropResizable").toBool(),
           "Width+Ratio still let a handle reshape the frame");

  // Unlocking Width leaves the ratio as the lock; Height is editable again.
  clickItem(lockWidth);
  QVERIFY(!m_editor->property("cropLockWidth").toBool());
  QVERIFY(height->property("enabled").toBool());
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("8:3"));
  QVERIFY(m_editor->property("cropResizable").toBool());

  // Height+Ratio derives Width instead.
  clickItem(lockHeight);
  QVERIFY(!width->property("enabled").toBool());
  QVERIFY(!height->property("enabled").toBool());
  QVERIFY2(!m_editor->property("cropResizable").toBool(),
           "Height+Ratio still let a handle reshape the frame");

  // All three is not a state: the third lock is refused and the button snaps
  // back off.
  clickItem(lockWidth);
  QVERIFY(!m_editor->property("cropLockWidth").toBool());
  QVERIFY(m_editor->property("cropLockHeight").toBool());
  QVERIFY(m_editor->property("cropLockRatio").toBool());
  QVERIFY(!lockWidth->property("checked").toBool());

  // Height alone: Width is the input. The unlocked ratio still links the
  // sides, but the locked Height wins, so Width changes and the ratio follows
  // the new pair.
  clickItem(lockRatio);
  QVERIFY(!m_editor->property("cropLockRatio").toBool());
  QVERIFY(m_editor->property("cropLockHeight").toBool());
  QVERIFY(width->property("enabled").toBool());
  typeInto(width, QStringLiteral("500"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("500"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("300"));

  // Width+Height settle the ratio as a consequence, with the field disabled.
  clickItem(lockWidth);
  QVERIFY(m_editor->property("cropLockWidth").toBool());
  QVERIFY(!m_editor->property("cropLockRatio").toBool());
  QVERIFY(!ratio->property("enabled").toBool());
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("5:3"));

  // And the ratio cannot be locked on top of two sides.
  clickItem(lockRatio);
  QVERIFY(!m_editor->property("cropLockRatio").toBool());
  QVERIFY(!lockRatio->property("checked").toBool());
  QCOMPARE(m_commands->count(), 0);
}

/// The panel is a second way to build the frame when the canvas is not the
/// handiest surface: a typed side, a preset or an anchor all place a rectangle
/// without a drag.
void TestEditor::theCropFieldsCreateTheFrame()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");

  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* frame = expectItem("cropFrame");
  QQuickItem* apply = expectItem("applyCrop");

  // One typed side is enough: the other follows the free shape's document
  // aspect, and the anchor places the rectangle.
  QVERIFY(!frame->isVisible());
  typeInto(width, QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1200"));
  QVERIFY(frame->isVisible());
  QVERIFY(apply->property("enabled").toBool());

  // Clear puts the frame down and empties the fields; the options stay.
  clickItem(expectItem("clearCrop"));
  QCOMPARE(width->property("text").toString(), QString());
  QCOMPARE(height->property("text").toString(), QString());
  QVERIFY(!frame->isVisible());
  QVERIFY(!apply->property("enabled").toBool());

  // The anchor alone is a creation path too: with nothing typed it asks for
  // the whole picture, which is the one rectangle that cannot be applied.
  scrollOptionsIntoView(expectItem("cropAnchor_top_left"));
  clickItem(expectItem("cropAnchor_top_left"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("3000"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));
  QVERIFY(frame->isVisible());
  QVERIFY(!apply->property("enabled").toBool());

  // Clear again, then type a ratio: a shape alone does not invent a frame, but
  // the next typed side uses it.
  clickItem(expectItem("clearCrop"));
  QVERIFY(!frame->isVisible());
  typeRatioInto(expectItem("cropRatio"), QStringLiteral("3:2"));
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("3:2"));
  QVERIFY(!frame->isVisible());
  typeInto(width, QStringLiteral("600"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("400"));
  // Clear kept the top-left anchor the case chose above, so the frame is
  // placed there; the ratio is what decided its 3:2 height.
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));
  QVERIFY(frame->isVisible());
  QCOMPARE(m_commands->count(), 0);
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

  // Nothing is framed until the user draws one.
  QVERIFY(!expectItem("cropFrame")->isVisible());

  // Drag a rectangle: (10,10) to (90,70) in document pixels. Crop starts free,
  // so the shape is exactly the drag.
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

/// A chosen ratio is a lock on the canvas too: a corner keeps the opposite
/// corner fixed and the shape, and an edge keeps its opposite side fixed while
/// the other axis grows around the frame's centre.
void TestEditor::theCropRatioLocksTheFrameDrag()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 400);
  editor.insert(QStringLiteral("height"), 400);
  setState(editor);
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);

  // A 4:5 frame gets squared by the ratio; the anchor keeps it centred.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(40)),
                                    Q_ARG(QVariant, QVariant(40)),
                                    Q_ARG(QVariant, QVariant(320)),
                                    Q_ARG(QVariant, QVariant(320))));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("1:1")))));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "reshapeCropToRatio"));
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("320"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("320"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("40"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("40"));

  QQuickItem* canvas = expectItem("canvas");
  const QPointF origin = canvas->mapToScene(QPointF(0, 0));

  // Bottom-right corner from (360,360) back to (240,240): the top-left corner
  // stays where it is and the square shrinks to 200 × 200.
  dragScene(origin + QPointF(360, 360), origin + QPointF(240, 240));
  QTRY_COMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("200"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("200"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("40"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("40"));

  // The right edge keeps the left side at 40 and grows both sides around the
  // frame's vertical centre: 260 × 260 at y 10.
  dragScene(origin + QPointF(240, 140), origin + QPointF(300, 140));
  QTRY_COMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("260"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("260"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("40"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("10"));
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("1:1"));

  // Shift+Alt+Right is the keyboard's resize: it steps Width 10 px and derives
  // the square Height, keeping the frame's centre.
  m_editor->forceActiveFocus();
  QTest::keyClick(m_view, Qt::Key_Right, Qt::AltModifier | Qt::ShiftModifier);
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("270"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("270"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("35"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("5"));
  QCOMPARE(m_commands->count(), 0);
}

/// A locked side is a lock on the canvas too: dragging a handle changes only
/// the axis that is still free, so the value the user pinned cannot move. Two
/// pinned sides fix the shape, and then the handles do nothing at all while the
/// frame can still be moved.
void TestEditor::aLockedSidePinsTheFrameDrag()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 400);
  editor.insert(QStringLiteral("height"), 300);
  setState(editor);
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(100)),
                                    Q_ARG(QVariant, QVariant(100)),
                                    Q_ARG(QVariant, QVariant(200)),
                                    Q_ARG(QVariant, QVariant(150))));

  QQuickItem* canvas = expectItem("canvas");
  const QPointF origin = canvas->mapToScene(QPointF(0, 0));

  // Height locked: the bottom-right corner drag widens the frame even though
  // the pointer also moved down; Height stays at 150.
  clickItem(expectItem("cropLockHeight"));
  QVERIFY(!m_editor->property("cropHeightEditable").toBool());
  dragScene(origin + QPointF(300, 250), origin + QPointF(340, 290));
  QTRY_COMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("240"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("150"));
  QCOMPARE(m_editor->property("cropFrameShown").toBool(), true);

  // Width locked instead: the same corner changes only Height.
  clickItem(expectItem("cropLockHeight"));
  clickItem(expectItem("cropLockWidth"));
  QVERIFY(!m_editor->property("cropWidthEditable").toBool());
  dragScene(origin + QPointF(340, 250), origin + QPointF(390, 280));
  QTRY_COMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("180"));
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("240"));

  // Two sides pinned: handles are refused, the rectangle is not resized.
  clickItem(expectItem("cropLockHeight"));
  QVERIFY(!m_editor->property("cropResizable").toBool());
  dragScene(origin + QPointF(340, 280), origin + QPointF(390, 330));
  QTest::qWait(30);
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("240"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("180"));
  QCOMPARE(m_commands->count(), 0);
}

/// The crop tool owns the arrow keys while it is armed: they nudge the frame,
/// Shift steps 10 px and Alt resizes around its centre. Enter applies the
/// rectangle on screen and Escape puts the tool down; a tool without a frame
/// sends nothing.
void TestEditor::theCropKeysNudgeResizeAndApply()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 400);
  editor.insert(QStringLiteral("height"), 300);
  setState(editor);
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(100)),
                                    Q_ARG(QVariant, QVariant(100)),
                                    Q_ARG(QVariant, QVariant(200)),
                                    Q_ARG(QVariant, QVariant(150))));
  m_editor->forceActiveFocus();

  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");

  QTest::keyClick(m_view, Qt::Key_Right);
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("101"));
  QTest::keyClick(m_view, Qt::Key_Right, Qt::ShiftModifier);
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("111"));
  QTest::keyClick(m_view, Qt::Key_Down);
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("101"));

  // Free ratio: Alt+Left takes one pixel off Width and leaves Height alone.
  QTest::keyClick(m_view, Qt::Key_Left, Qt::AltModifier);
  QCOMPARE(width->property("text").toString(), QStringLiteral("199"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("150"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("112"));

  // Escape puts the tool down, and an arrow no longer moves the frame.
  QTest::keyClick(m_view, Qt::Key_Escape);
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QVERIFY(!expectItem("cropFrame")->isVisible());
  QTest::keyClick(m_view, Qt::Key_Right);
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("112"));
  QCOMPARE(m_commands->count(), 0);

  // Re-arming Crop starts unframed, so Enter has nothing to send yet.
  selectTool("crop");
  QVERIFY(!expectItem("cropFrame")->isVisible());
  m_editor->forceActiveFocus();
  QQuickItem* apply = expectItem("applyCrop");
  QVERIFY(!apply->property("enabled").toBool());
  QTest::keyClick(m_view, Qt::Key_Return);
  QCOMPARE(m_commands->count(), 0);

  // A rectangle built in the panel is what Enter applies.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(50)),
                                    Q_ARG(QVariant, QVariant(60)),
                                    Q_ARG(QVariant, QVariant(120)),
                                    Q_ARG(QVariant, QVariant(90))));
  QTRY_VERIFY(apply->property("enabled").toBool());
  QTest::keyClick(m_view, Qt::Key_Return);
  QTRY_COMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_crop"));
  QCOMPARE(command.value("x").toInt(), 50);
  QCOMPARE(command.value("y").toInt(), 60);
  QCOMPARE(command.value("width").toInt(), 120);
  QCOMPARE(command.value("height").toInt(), 90);
}

/// Another edit can shrink the document under an armed Crop frame. A rectangle
/// that no longer fits cannot be applied; it is pulled inside the new picture
/// in one move, and a rectangle that still fits is never touched.
void TestEditor::theCropFrameRefitsAfterADocumentChange()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 400);
  editor.insert(QStringLiteral("height"), 300);
  setState(editor);
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(50)),
                                    Q_ARG(QVariant, QVariant(50)),
                                    Q_ARG(QVariant, QVariant(300)),
                                    Q_ARG(QVariant, QVariant(200))));

  // Shrink to 200 × 150: the 300 × 200 rectangle is outside now, so it is
  // clamped to the whole new picture at (0, 0).
  QVariantMap smaller = editor;
  smaller.insert(QStringLiteral("width"), 200);
  smaller.insert(QStringLiteral("height"), 150);
  setState(smaller);
  QTRY_COMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("200"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("150"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("0"));
  // The whole picture is Core's `edit_noop`, so Apply is not armed by the refit.
  QVERIFY(!expectItem("applyCrop")->property("enabled").toBool());

  // Grow to 800 × 600: the frame still fits, so it must not move.
  QVariantMap bigger = editor;
  bigger.insert(QStringLiteral("width"), 800);
  bigger.insert(QStringLiteral("height"), 600);
  setState(bigger);
  QTest::qWait(40);
  QCOMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("200"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("150"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(m_commands->count(), 0);
}

/// What a crop tool draws while the rectangle exists: rule-of-thirds guides
/// inside the frame and the discarded picture dimmed outside it. With no frame
/// nothing is chosen, so the whole picture is dimmed instead.
void TestEditor::theCropFrameDrawsItsGuidesAndShade()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 400);
  editor.insert(QStringLiteral("height"), 300);
  setState(editor);
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);

  QVERIFY(!expectItem("cropFrame")->isVisible());
  // Nothing is chosen yet, so the whole picture is dimmed and the four edge
  // strips have nothing to cover: they are zero-sized, not visible halves.
  QVERIFY(expectItem("cropShadeEmpty")->isVisible());
  QCOMPARE(expectItem("cropShadeTop")->height(), 0.0);
  QCOMPARE(expectItem("cropShadeLeft")->width(), 0.0);

  QQuickItem* canvas = expectItem("canvas");
  const QPointF origin = canvas->mapToScene(QPointF(0, 0));
  dragScene(origin + QPointF(10, 10), origin + QPointF(170, 130));

  QQuickItem* frame = expectItem("cropFrame");
  QTRY_VERIFY(frame->isVisible());
  QCOMPARE(frame->width(), 160.0);
  QCOMPARE(frame->height(), 120.0);

  const auto near = [](qreal actual, qreal expected) {
    return qAbs(actual - expected) < 0.01;
  };
  QVERIFY(near(expectItem("cropGridVertical1")->x(), frame->width() / 3.0));
  QVERIFY(near(expectItem("cropGridVertical2")->x(), frame->width() * 2.0 / 3.0));
  QVERIFY(near(expectItem("cropGridHorizontal1")->y(), frame->height() / 3.0));
  QVERIFY(near(expectItem("cropGridHorizontal2")->y(), frame->height() * 2.0 / 3.0));

  QVERIFY(expectItem("cropShade")->isVisible());
  QVERIFY(!expectItem("cropShadeEmpty")->isVisible());
  // At 100 % the frame starts 10 px in and ends 30 px short of the far edges,
  // so each shade piece is exactly that leftover.
  QCOMPARE(expectItem("cropShadeLeft")->width(), 10.0);
  QCOMPARE(expectItem("cropShadeRight")->width(), 230.0);
  QCOMPARE(expectItem("cropShadeTop")->height(), 10.0);
  QCOMPARE(expectItem("cropShadeBottom")->height(), 170.0);
  QCOMPARE(m_commands->count(), 0);
}

/// Applying a crop leaves the tool armed on the cropped document with a frame
/// over the whole result: the next crop starts from what the user can see. The
/// gateway publishes the new document before `command()` returns, and this case
/// answers the command with a synchronous state change, exactly as the real
/// gateway does.
void TestEditor::theAppliedCropLeavesAFreshFrame()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 1200);
  editor.insert(QStringLiteral("height"), 640);
  setState(editor);
  selectTool("crop");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(200)),
                                    Q_ARG(QVariant, QVariant(20)),
                                    Q_ARG(QVariant, QVariant(800)),
                                    Q_ARG(QVariant, QVariant(600))));
  // A lock describes the rectangle that is about to disappear.
  clickItem(expectItem("cropLockWidth"));
  QVERIFY(m_editor->property("cropLockWidth").toBool());
  m_commands->clear();

  // The answered state is the same document at the cut size, so its path does
  // not change and the pending result is not discarded as a new file.
  QVariantMap cropped = editor;
  cropped.insert(QStringLiteral("width"), 800);
  cropped.insert(QStringLiteral("height"), 600);
  CommandAnswerer answerer(m_editor, cropped);
  connect(m_editor, SIGNAL(command(QVariant)), &answerer, SLOT(answer(QVariant)));

  QQuickItem* apply = expectItem("applyCrop");
  QTRY_VERIFY(apply->property("enabled").toBool());
  clickItem(apply);
  disconnect(m_editor, SIGNAL(command(QVariant)), &answerer, SLOT(answer(QVariant)));

  QCOMPARE(m_commands->count(), 1);
  const QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_crop"));
  QCOMPARE(command.value("width").toInt(), 800);
  QCOMPARE(command.value("height").toInt(), 600);

  QCOMPARE(m_editor->property("documentWidth").toInt(), 800);
  QCOMPARE(m_editor->property("documentHeight").toInt(), 600);
  QTRY_COMPARE(expectItem("cropWidth")->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(expectItem("cropHeight")->property("text").toString(), QStringLiteral("600"));
  QCOMPARE(expectItem("cropX")->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(expectItem("cropY")->property("text").toString(), QStringLiteral("0"));
  QVERIFY(expectItem("cropFrame")->isVisible());
  QVERIFY2(!m_editor->property("cropLockWidth").toBool(),
           "a lock survived the rectangle it described");
  QVERIFY(!apply->property("enabled").toBool());

  // A rectangle that keeps the whole document is Core's `edit_noop`, so Apply
  // says so instead of sending it; any smaller rectangle arms it again.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropRect",
                                    Q_ARG(QVariant, QVariant(0)),
                                    Q_ARG(QVariant, QVariant(0)),
                                    Q_ARG(QVariant, QVariant(799)),
                                    Q_ARG(QVariant, QVariant(600))));
  QVERIFY(apply->property("enabled").toBool());
}

/// Reset is a statement about the panel, not about the picture: it restores the
/// options to their defaults and leaves the frame where the user put it. Clear
/// is the other half: it puts the frame down and keeps the options.
void TestEditor::resetRestoresTheCropOptionsAndKeepsTheFrame()
{
  setState(documentState());
  selectTool("crop");
  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* preset = expectItem("cropPreset");

  typeInto(width, QStringLiteral("800"));
  typeInto(height, QStringLiteral("600"));
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("1200"));

  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("4:3")))));
  scrollOptionsIntoView(expectItem("cropAnchor_bottom_right"));
  clickItem(expectItem("cropAnchor_bottom_right"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropMode",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("grow")))));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setBackgroundColor",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("#000000")))));
  clickItem(expectItem("cropLockWidth"));
  preset->setProperty("currentIndex", 2);
  QCOMPARE(preset->property("currentIndex").toInt(), 2);
  const QString keptX = cropX->property("text").toString();
  const QString keptY = cropY->property("text").toString();

  clickItem(expectItem("resetCropOptions"));
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("free"));
  QCOMPARE(m_editor->property("cropAnchor").toString(), QStringLiteral("center"));
  QCOMPARE(m_editor->property("cropMode").toString(), QStringLiteral("center"));
  // The pair belongs to the Editor, not to this panel: Reset is a statement
  // about Crop's own options, so the background stays where the user put it.
  QCOMPARE(m_editor->property("backgroundColor").toString(), QStringLiteral("#000000"));
  QVERIFY(!m_editor->property("cropLockWidth").toBool());
  QVERIFY(!m_editor->property("cropLockHeight").toBool());
  QVERIFY(!m_editor->property("cropLockRatio").toBool());
  QCOMPARE(preset->property("currentIndex").toInt(), -1);
  // The rectangle is exactly where it was.
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));
  QCOMPARE(cropX->property("text").toString(), keptX);
  QCOMPARE(cropY->property("text").toString(), keptY);
  QVERIFY(expectItem("cropFrame")->isVisible());
  QCOMPARE(m_commands->count(), 0);

  // Clear removes the frame and releases the locks, but the mode, the border
  // colour, the ratio and the anchor are panel options and stay.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setRatio",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("4:3")))));
  scrollOptionsIntoView(expectItem("cropAnchor_top_left"));
  clickItem(expectItem("cropAnchor_top_left"));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setCropMode",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("grow")))));
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setBackgroundColor",
                                    Q_ARG(QVariant, QVariant(QStringLiteral("#000000")))));
  clickItem(expectItem("cropLockHeight"));
  clickItem(expectItem("clearCrop"));

  QCOMPARE(width->property("text").toString(), QString());
  QCOMPARE(height->property("text").toString(), QString());
  QCOMPARE(cropX->property("text").toString(), QStringLiteral("0"));
  QCOMPARE(cropY->property("text").toString(), QStringLiteral("0"));
  QVERIFY(!expectItem("cropFrame")->isVisible());
  QVERIFY(!m_editor->property("cropLockWidth").toBool());
  QVERIFY(!m_editor->property("cropLockHeight").toBool());
  QVERIFY(!m_editor->property("cropLockRatio").toBool());
  QCOMPARE(m_editor->property("cropMode").toString(), QStringLiteral("grow"));
  QCOMPARE(m_editor->property("backgroundColor").toString(), QStringLiteral("#000000"));
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("4:3"));
  QCOMPARE(m_editor->property("cropAnchor").toString(), QStringLiteral("top_left"));

  // And the empty state still accepts a new frame.
  scrollOptionsIntoView(expectItem("cropAnchor_top_left"));
  clickItem(expectItem("cropAnchor_top_left"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QVERIFY(expectItem("cropFrame")->isVisible());
  QCOMPARE(m_commands->count(), 0);
}

/// Transform offers two icon-only modes (Free Transform and Scale Canvas) with
/// no disabled Perspective button. Dragging handles resizes the bounding box
/// with zero `editor_transform_preview` commands, and Apply emits
/// `editor_free_transform` (in Free mode) or `editor_resize` (in Scale mode).
void TestEditor::theTransformToolDragsCornersAndEdges()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 200);
  editor.insert(QStringLiteral("height"), 150);
  setState(editor);
  selectTool("transform");
  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Transform options"));
  QVERIFY(expectItem("transformOverlay")->isVisible());
  QVERIFY(expectItem("applyTransform")->isVisible());
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners.length")).toInt(), 4);

  // Two Krita-style icon buttons; Perspective is gone.
  QCOMPARE(m_editor->property("transformMode").toString(), QStringLiteral("free"));
  QCOMPARE(expectItem("transformModeFree")->property("active").toBool(), true);
  QCOMPARE(expectItem("transformModeScale")->property("active").toBool(), false);
  QVERIFY2(visualItem(QStringLiteral("transformModePerspective")) == nullptr,
           "Perspective button should be removed");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);

  for (int index = 0; index < 4; ++index) {
    QQuickItem* corner = visualItem(QStringLiteral("transformCorner_%1").arg(index));
    QVERIFY2(corner != nullptr && corner->isVisible(), "a corner handle is missing");
    QQuickItem* edge = visualItem(QStringLiteral("transformEdge_%1").arg(index));
    QVERIFY2(edge != nullptr && edge->isVisible(), "an edge handle is missing");
  }
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][0]")).toDouble(), 200.0);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][1]")).toDouble(), 150.0);
  QVERIFY(!expectItem("applyTransform")->property("enabled").toBool());

  // Corner 0 moves in by 20 × 10; bottom-right stays anchored.
  QQuickItem* corner0 = expectItem("transformCorner_0");
  const QPointF cornerCentre =
    corner0->mapToScene(QPointF(corner0->width() / 2.0, corner0->height() / 2.0));
  dragScene(cornerCentre, cornerCentre + QPointF(20, 10));
  QTRY_VERIFY2(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][0]")).toDouble() - 20.0)
                 < 1.1,
               "the corner did not follow the pointer");
  QVERIFY(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][1]")).toDouble() - 10.0)
          < 1.1);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][0]")).toDouble(), 200.0);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][1]")).toDouble(), 150.0);
  QVERIFY(expectItem("applyTransform")->property("enabled").toBool());

  // Edge 0 (top edge) moves down by 15 px; bottom edge stays at 150.
  QQuickItem* edge0 = expectItem("transformEdge_0");
  const QPointF edgeCentre =
    edge0->mapToScene(QPointF(edge0->width() / 2.0, edge0->height() / 2.0));
  dragScene(edgeCentre, edgeCentre + QPointF(0, 15));
  QTRY_VERIFY2(qAbs(readQml(m_editor, QStringLiteral("transformCorners[0][1]")).toDouble() - 25.0)
                 < 1.1,
               "the edge did not follow the pointer");
  QCOMPARE(readQml(m_editor, QStringLiteral("transformCorners[2][1]")).toDouble(), 150.0);

  // Live preview is GPU-only in QML: no `editor_transform_preview` command is sent.
  QTest::qWait(300);
  QCOMPARE(m_commands->count(), 0);

  // Apply in Free Transform sends `editor_free_transform` with the exact rect.
  clickItem(expectItem("applyTransform"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap freeCmd = m_commands->at(0).at(0).toMap();
  QCOMPARE(freeCmd.value("type").toString(), QStringLiteral("editor_free_transform"));
  QCOMPARE(freeCmd.value("x").toInt(), 20);
  QCOMPARE(freeCmd.value("y").toInt(), 25);
  QCOMPARE(freeCmd.value("width").toInt(), 180);
  QCOMPARE(freeCmd.value("height").toInt(), 125);
  QTRY_COMPARE(readQml(m_editor, QStringLiteral("transformCorners[0][0]")).toDouble(), 0.0);
  QVERIFY(!expectItem("applyTransform")->property("enabled").toBool());

  // Switch to Scale Canvas mode: dragging corner 2 outward and applying emits
  // `editor_resize` (stretch) with the new dimensions.
  m_commands->clear();
  clickItem(expectItem("transformModeScale"));
  QCOMPARE(m_editor->property("transformMode").toString(), QStringLiteral("scale"));
  QCOMPARE(expectItem("transformModeScale")->property("active").toBool(), true);
  QQuickItem* corner2 = expectItem("transformCorner_2");
  const QPointF brCentre =
    corner2->mapToScene(QPointF(corner2->width() / 2.0, corner2->height() / 2.0));
  dragScene(brCentre, brCentre + QPointF(40, 30));
  QTRY_VERIFY(qAbs(readQml(m_editor, QStringLiteral("transformRect().width")).toDouble() - 240.0)
              < 1.1);
  QVERIFY(qAbs(readQml(m_editor, QStringLiteral("transformRect().height")).toDouble() - 180.0)
          < 1.1);
  clickItem(expectItem("applyTransform"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap scaleCmd = m_commands->at(0).at(0).toMap();
  QCOMPARE(scaleCmd.value("type").toString(), QStringLiteral("editor_resize"));
  QCOMPARE(scaleCmd.value("width").toInt(), 240);
  QCOMPARE(scaleCmd.value("height").toInt(), 180);
  QCOMPARE(scaleCmd.value("mode").toString(), QStringLiteral("stretch"));
}

/// Live Transform preview renders directly inside the bounding box on the GPU
/// canvas in both Free Transform and Scale Canvas modes, without changing
/// `zoom` (`autoFit` never fights the drag) or sending Core preview commands.
void TestEditor::theTransformPreviewIsDrawnOnTheCanvas()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 200);
  editor.insert(QStringLiteral("height"), 150);
  setState(editor);
  selectTool("transform");
  QVERIFY(QMetaObject::invokeMethod(m_editor, "fit"));
  QTest::qWait(20);

  const double zoomBefore = m_editor->property("zoom").toDouble();
  QVERIFY(zoomBefore > 0.0);
  QVERIFY(expectItem("transformCanvasLayer")->isVisible());
  QVERIFY(!expectItem("canvas")->isVisible());

  // Free Transform: dragging corner 0 shrinks `freeTransformImage` inside the
  // fixed `freeTransformFrame` to match the bounding box at `zoomBefore`.
  QQuickItem* corner0 = expectItem("transformCorner_0");
  const QPointF tl = corner0->mapToScene(QPointF(corner0->width() / 2.0, corner0->height() / 2.0));
  dragScene(tl, tl + QPointF(40 * zoomBefore, 30 * zoomBefore));
  QTRY_VERIFY(qAbs(readQml(m_editor, QStringLiteral("transformRect().x")).toDouble() - 40.0) < 2.0);
  QCOMPARE(m_editor->property("zoom").toDouble(), zoomBefore);
  QQuickItem* freeImg = expectItem("freeTransformImage");
  QVERIFY(freeImg->isVisible());
  QVERIFY(qAbs(freeImg->x() - 40.0 * zoomBefore) < 2.5);
  QVERIFY(qAbs(freeImg->width() - 160.0 * zoomBefore) < 2.5);

  // Scale Canvas: `scaleTransformImage` matches the dragged bounding box and
  // keeps `zoom` unchanged.
  clickItem(expectItem("transformModeScale"));
  QTest::qWait(20);
  QQuickItem* scaleImg = expectItem("scaleTransformImage");
  QVERIFY(scaleImg->isVisible());
  QQuickItem* corner2 = expectItem("transformCorner_2");
  const QPointF br = corner2->mapToScene(QPointF(corner2->width() / 2.0, corner2->height() / 2.0));
  dragScene(br, br - QPointF(50 * zoomBefore, 30 * zoomBefore));
  QTRY_VERIFY(qAbs(readQml(m_editor, QStringLiteral("transformRect().width")).toDouble() - 150.0)
              < 2.0);
  QCOMPARE(m_editor->property("zoom").toDouble(), zoomBefore);
  QVERIFY(qAbs(scaleImg->width() - 150.0 * zoomBefore) < 2.5);
  QCOMPARE(m_commands->count(), 0);
}

/// Shared bounding-box modifiers (`Shift` = aspect ratio / axis lock,
/// `Alt` = resize from centre, `Ctrl` = snap) work identically in both Crop
/// and Transform.
void TestEditor::boundingBoxModifiersWorkInCropAndTransform()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("width"), 400);
  editor.insert(QStringLiteral("height"), 200);
  setState(editor);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "actualSize"));
  QTest::qWait(20);

  const double originX = m_editor->property("canvasOriginX").toDouble();
  const double originY = m_editor->property("canvasOriginY").toDouble();

  // --- Transform: Shift locks 2:1 ratio, Alt resizes from centre, Ctrl snaps.
  selectTool("transform");
  QVariantMap startRect;
  startRect.insert(QStringLiteral("x"), 0);
  startRect.insert(QStringLiteral("y"), 0);
  startRect.insert(QStringLiteral("width"), 400);
  startRect.insert(QStringLiteral("height"), 200);

  // Shift on bottom-right corner dragged to (200, 180): aspect 2:1 forces 200 × 100.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "dragTransformCorner",
                                    Q_ARG(QVariant, 2),
                                    Q_ARG(QVariant, originX + 200.0),
                                    Q_ARG(QVariant, originY + 180.0),
                                    Q_ARG(QVariant, int(Qt::ShiftModifier)),
                                    Q_ARG(QVariant, startRect)));
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().width")).toInt(), 200);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().height")).toInt(), 100);

  // Alt on bottom-right corner dragged to (300, 150) around centre (200, 100):
  // half-size 100 × 50 -> rect (100, 50, 200 × 100).
  QVERIFY(QMetaObject::invokeMethod(m_editor, "dragTransformCorner",
                                    Q_ARG(QVariant, 2),
                                    Q_ARG(QVariant, originX + 300.0),
                                    Q_ARG(QVariant, originY + 150.0),
                                    Q_ARG(QVariant, int(Qt::AltModifier)),
                                    Q_ARG(QVariant, startRect)));
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().x")).toInt(), 100);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().y")).toInt(), 50);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().width")).toInt(), 200);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().height")).toInt(), 100);

  // Ctrl snaps pointer (323, 147) to 10 px grid -> 320 × 150.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "dragTransformCorner",
                                    Q_ARG(QVariant, 2),
                                    Q_ARG(QVariant, originX + 323.0),
                                    Q_ARG(QVariant, originY + 147.0),
                                    Q_ARG(QVariant, int(Qt::ControlModifier)),
                                    Q_ARG(QVariant, startRect)));
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().width")).toInt(), 320);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().height")).toInt(), 150);

  // Move with Shift locks to dominant axis (dx = 45, dy = 12 -> dx = 45, dy = 0).
  QVERIFY(QMetaObject::invokeMethod(m_editor, "moveTransformBox",
                                    Q_ARG(QVariant, startRect),
                                    Q_ARG(QVariant, 45.0),
                                    Q_ARG(QVariant, 12.0),
                                    Q_ARG(QVariant, int(Qt::ShiftModifier))));
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().x")).toInt(), 45);
  QCOMPARE(readQml(m_editor, QStringLiteral("transformRect().y")).toInt(), 0);

  // --- Crop: same modifiers on create-drag and handle-drag.
  selectTool("crop");
  // Shift on free create-drag from (40, 20) to (160, 80) produces a 1:1 square (60 × 60).
  QVERIFY(QMetaObject::invokeMethod(m_editor, "dragCropCreate",
                                    Q_ARG(QVariant, originX + 40.0),
                                    Q_ARG(QVariant, originY + 20.0),
                                    Q_ARG(QVariant, originX + 160.0),
                                    Q_ARG(QVariant, originY + 80.0),
                                    Q_ARG(QVariant, int(Qt::ShiftModifier))));
  QCOMPARE(readQml(m_editor, QStringLiteral("cropRect.width")).toInt(), 60);
  QCOMPARE(readQml(m_editor, QStringLiteral("cropRect.height")).toInt(), 60);

  // Alt on crop bottom-right handle resizes symmetrically around centre (70, 50).
  QVariantMap cropStart;
  cropStart.insert(QStringLiteral("x"), 40);
  cropStart.insert(QStringLiteral("y"), 20);
  cropStart.insert(QStringLiteral("width"), 60);
  cropStart.insert(QStringLiteral("height"), 60);
  QVERIFY(QMetaObject::invokeMethod(m_editor, "dragCropHandle",
                                    Q_ARG(QVariant, 2),
                                    Q_ARG(QVariant, 2),
                                    Q_ARG(QVariant, originX + 120.0),
                                    Q_ARG(QVariant, originY + 90.0),
                                    Q_ARG(QVariant, int(Qt::AltModifier)),
                                    Q_ARG(QVariant, cropStart)));
  QCOMPARE(readQml(m_editor, QStringLiteral("cropRect.x")).toInt(), 20);
  QCOMPARE(readQml(m_editor, QStringLiteral("cropRect.y")).toInt(), 10);
  QCOMPARE(readQml(m_editor, QStringLiteral("cropRect.width")).toInt(), 100);
  QCOMPARE(readQml(m_editor, QStringLiteral("cropRect.height")).toInt(), 80);
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

/// Below the full icon row the Editor keeps open, save, undo, redo, back and
/// close, and folds zoom, save-as, export and reset into one overflow button.
/// The count is `ToolbarMetrics.editorMiniButtons`, so the window floor and the
/// row that is drawn cannot disagree.
void TestEditor::theMiniToolbarFoldsTheSecondaryActions_data()
{
  QTest::addColumn<bool>("mini");
  QTest::newRow("compact") << false;
  QTest::newRow("mini") << true;
}

void TestEditor::theMiniToolbarFoldsTheSecondaryActions()
{
  QFETCH(bool, mini);
  auto* row = qobject_cast<QQuickItem*>(m_toolbar);
  QVERIFY(row != nullptr);
  row->setWidth(kHostWidth);
  m_editor->setProperty("miniToolbar", mini);
  QCoreApplication::processEvents();

  int buttons = 0;
  QQuickItem* overflow = nullptr;
  std::function<void(QQuickItem*)> walk = [&](QQuickItem* root) {
    for (QQuickItem* candidate : root->childItems()) {
      if (QString::fromLatin1(candidate->metaObject()->className())
            .contains(QStringLiteral("ToolbarButton"))) {
        if (candidate->objectName() == QStringLiteral("editorOverflowButton")) {
          overflow = candidate;
        }
        if (candidate->isVisible()) {
          ++buttons;
        }
      }
      walk(candidate);
    }
  };
  walk(row);
  QVERIFY2(overflow != nullptr, "the toolbar has no overflow button");
  QCOMPARE(overflow->isVisible(), mini);
  QCOMPARE(buttons, mini ? 7 : 13);

  if (mini) {
    QVERIFY(QMetaObject::invokeMethod(overflow, "click"));
    QObject* menu = m_editor->findChild<QObject*>(QStringLiteral("editorOverflowMenu"));
    QVERIFY2(menu != nullptr, "the editor has no overflow menu");
    QTRY_VERIFY2(menu->property("visible").toBool(), "the overflow menu did not open");
    const int rows = menu->property("count").toInt();
    // Close first: a failed count used to leave the popup open over the next
    // case's click, which read as a broken tab strip.
    QMetaObject::invokeMethod(menu, "close");
    QTRY_VERIFY(!menu->property("visible").toBool());
    // zoom out/in, fit, actual size, a separator, save as, export, a separator
    // and reset: nine rows. The dock toggle moved to the burger menu's
    // `View > Sidebar` submenu, so it is not a toolbar row any more.
    QCOMPARE(rows, 9);
  }
  m_editor->setProperty("miniToolbar", false);
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

  // Pointer: the dock opens on Info. Thumbnail and history are their own tabs,
  // so no tool can push them away.
  selectTool("pointer");
  selectRightTab("info");
  for (const char* option : {"toolOptionsHeading", "imageHeading", "imageName", "imageSize",
                             "saveTarget"}) {
    QQuickItem* item = expectItem(option);
    QVERIFY2(inside(right, item), qPrintable(QStringLiteral("%1 is not in the inspector")
                                                 .arg(QString::fromLatin1(option))));
    QVERIFY2(item->isVisible(), qPrintable(QStringLiteral("%1 is not visible")
                                               .arg(QString::fromLatin1(option))));
  }
  QVERIFY(!expectItem("originalThumbnail")->isVisible());
  QVERIFY(!expectItem("historyList")->isVisible());

  selectRightTab("history");
  QVERIFY2(inside(right, expectItem("historyList")),
           "the history list is not in the inspector");
  QVERIFY(expectItem("historyList")->isVisible());

  selectRightTab("original");
  QVERIFY2(inside(right, expectItem("originalThumbnail")),
           "the preview is not in the inspector");
  QVERIFY(expectItem("originalThumbnail")->isVisible());

  // A canvas tool: its options sit above the same tabs, and the open tab stays
  // open. That is the whole point of the split — the picture being cropped and
  // the history of how it got there are visible at the same time.
  selectTool("crop");
  for (const char* option : {"toolOptionsHeading", "cropWidth", "cropHeight",
                             "cropLockWidth", "cropLockHeight", "cropLockRatio",
                             "applyCrop", "resetCropOptions", "clearCrop",
                             "cropPreset", "cropRatio", "cropAnchorPad"}) {
    QQuickItem* item = expectItem(option);
    QVERIFY2(inside(right, item), qPrintable(QStringLiteral("%1 is not in the inspector")
                                                 .arg(QString::fromLatin1(option))));
    QVERIFY2(item->isVisible(), qPrintable(QStringLiteral("%1 is not visible")
                                               .arg(QString::fromLatin1(option))));
  }
  QVERIFY(expectItem("originalThumbnail")->isVisible());

  // Resize is not a column of the inspector any more: its controls live in its
  // own modal form, and the editor stays on the pointer underneath.
  selectTool("pointer");
  selectRightTab("info");
  openResizeDialog();
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  for (const char* option : {"resizeWidth", "resizeHeight", "resizeApply", "resizeReset",
                             "resizeSizePreset", "resizeConstraint", "resizeFit",
                             "resizeFilter"}) {
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
  selectRightTab("info");
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QCOMPARE(heading->property("text").toString(), QStringLiteral("Pointer options"));
  QVERIFY(imageName->isVisible());
  QVERIFY(!resizeApply->isVisible());
  QVERIFY(!cropApply->isVisible());
  QVERIFY(!expectItem("resizeSizePreset")->isVisible());
  QVERIFY(!expectItem("resizeBackground")->isVisible());
  QVERIFY(!expectItem("cropX")->isVisible());
  QVERIFY(!expectItem("cropY")->isVisible());
  QVERIFY(!dialog->property("opened").toBool());

  clickItem(expectItem("toolCrop"));
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("crop"));
  QTRY_VERIFY(cropApply->isVisible());
  QCOMPARE(heading->property("text").toString(), QStringLiteral("Crop options"));
  // The tool zone opens above the tabs instead of replacing the document
  // panel: the open Info page is still there, which is what the split buys.
  QVERIFY(imageName->isVisible());
  QVERIFY(expectItem("cropX")->isVisible());
  QVERIFY(expectItem("cropY")->isVisible());
  QVERIFY(!expectItem("resizeSizePreset")->isVisible());
  QVERIFY(!expectItem("resizeBackground")->isVisible());
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
  QCOMPARE(heading->property("text").toString(), QStringLiteral("Pointer options"));
  QVERIFY(imageName->isVisible());
  QVERIFY(resizeApply->isVisible());
  QVERIFY(!cropApply->isVisible());
  QCOMPARE(m_commands->count(), 0);
  closeResizeDialog(expectItem("resizeCancel"));
  QTRY_VERIFY(!dialog->property("opened").toBool());
  QVERIFY(!expectItem("toolResize")->property("highlighted").toBool());
}

/// The dock is two zones: the armed tool's options above, the document itself
/// as three tabs below. The split is what keeps the preview and the history on
/// screen while Crop is in hand; the tab, the split and the fold are
/// presentation state and no command leaves the view.
void TestEditor::theInspectorSplitsToolsFromThreeReferenceTabs()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("history"),
                QVariantList{QVariantMap{{QStringLiteral("code"), QStringLiteral("rotate_right")},
                                         {QStringLiteral("args"), QVariantList{}}}});
  setState(editor);

  QQuickItem* zone = expectItem("editorToolZone");
  // The pointer has no options, and the frame stays the standard height every
  // tool gets; only the contents change.
  QVERIFY(!expectItem("toolOptionsScroll")->isVisible());
  QVERIFY(expectItem("toolOptionsHeading")->isVisible());
  const qreal frameHeight = zone->height();
  QVERIFY2(frameHeight > 200.0,
           qPrintable(QStringLiteral("the pointer frame is %1 px tall").arg(frameHeight)));
  QVERIFY(expectItem("infoPanel")->isVisible());
  QVERIFY(!expectItem("historyPanel")->isVisible());
  QVERIFY(!expectItem("originalPanel")->isVisible());

  // One page at a time, and a tab click is not a command.
  selectRightTab("history");
  QVERIFY(expectItem("historyPanel")->isVisible());
  QVERIFY(!expectItem("infoPanel")->isVisible());
  selectRightTab("original");
  QVERIFY(expectItem("originalPanel")->isVisible());
  QVERIFY(!expectItem("historyPanel")->isVisible());
  QCOMPARE(m_commands->count(), 0);

  // Arming Crop fills the frame the reference leaves; the Original page stays
  // open, which is the whole reason for the split. The reference is
  // content-sized, so a different page changes the frame's height — the tool
  // does not.
  selectTool("crop");
  QTRY_VERIFY(expectItem("toolOptionsScroll")->isVisible());
  QVERIFY(expectItem("cropX")->isVisible());
  QVERIFY(expectItem("originalPanel")->isVisible());
  QVERIFY(expectItem("originalThumbnail")->isVisible());
  QQuickItem* reference = expectItem("editorReferenceDock");
  QVERIFY2(qAbs(reference->height()
                - readQml(m_editor, QStringLiteral("referenceDock.contentHeight")).toDouble())
             <= 1.0,
           "the reference dock did not fit the Original page");
  // The same page and the same tool give the same frame as the pointer did.
  selectRightTab("info");
  QTRY_COMPARE(qRound(zone->height()), qRound(frameHeight));

  // The verbs follow the fields they act on, and the rest of the frame is
  // blank under them; the tabs start below the divider, not right under Apply.
  const qreal zoneBottom = zone->mapToScene(QPointF(0, zone->height())).y();
  // The action row is a grid: at this dock width Apply takes a line of its own
  // and Reset/Clear the next, so the row's bottom is the grid's, not Apply's.
  QQuickItem* actions = expectItem("cropActions");
  const qreal actionsBottom =
    actions->mapToScene(QPointF(0, actions->height())).y();
  QVERIFY2(zoneBottom - actionsBottom >= 0.0, "the action row left the tool zone");
  QCOMPARE(m_commands->count(), 0);

  // The zone is anchored at the dock's top whenever it is drawn: the old fold
  // could stretch it and leave the sidebar's title floating mid-column.
  const qreal zoneTop =
    expectItem("editorToolZone")->mapToScene(QPointF(0, 0)).y();
  const qreal dockTop =
    expectItem("editorInspector")->mapToScene(QPointF(0, 0)).y();
  QVERIFY2(zoneTop - dockTop <= 2.0,
           qPrintable(QStringLiteral("the tool zone is %1 px below the dock's top")
                        .arg(zoneTop - dockTop)));

  // A narrow dock folds the labels to their drawings; the icons stay. The
  // pinned action row is the other thing width takes away: Apply, Reset and
  // Clear have to stay whole words, so Crop gives Apply a line of its own.
  selectTool("crop");
  setLayoutValue(QStringLiteral("rightWidth"), 220);
  QTRY_VERIFY(!expectItem("editorTabLabel_history")->isVisible());
  QVERIFY(expectItem("editorTabIcon_history")->isVisible());
  QQuickItem* apply = expectItem("applyCrop");
  QQuickItem* reset = expectItem("resetCropOptions");
  QQuickItem* clear = expectItem("clearCrop");
  for (QQuickItem* button : {apply, reset, clear}) {
    QVERIFY2(button->width() + 0.5 >= button->implicitWidth(),
             qPrintable(QStringLiteral("%1 is %2 px wide but needs %3")
                          .arg(button->objectName())
                          .arg(button->width())
                          .arg(button->implicitWidth())));
  }
  QTRY_VERIFY2_WITH_TIMEOUT(apply->y() + apply->height() <= reset->y() + 0.5,
                            "Apply shares its line with Reset in a 220 px dock",
                            3000);
  setLayoutValue(QStringLiteral("rightWidth"), 340);
  QTRY_VERIFY(expectItem("editorTabLabel_history")->isVisible());
  QTRY_COMPARE(apply->y(), reset->y());
  QCOMPARE(reset->y(), clear->y());
  setLayoutValue(QStringLiteral("rightWidth"), 260);

  QCOMPARE(m_commands->count(), 0);
}

/// The shell's `View > Sidebar` menu is the only way a panel goes away. Each
/// row hides or shows one panel, a hidden page keeps its stack slot, hiding
/// the open page opens the first one left, and hiding every panel hides the
/// whole column — which the next shown panel brings back.
void TestEditor::thePanelChecklistHidesAndRestoresTheSidebar()
{
  setState(documentState());
  selectTool("crop");
  QQuickItem* inspector = expectItem("editorInspector");
  QQuickItem* zone = expectItem("editorToolZone");
  QQuickItem* pages = expectItem("editorReferencePages");
  QQuickItem* strip = expectItem("editorRightTabs");
  QQuickItem* divider = expectItem("editorToolZoneDivider");
  const qreal dockTop = inspector->mapToScene(QPointF(0, 0)).y();
  QVERIFY(inspector->isVisible());
  QVERIFY(pages->isVisible());
  QVERIFY(strip->isVisible());
  QVERIFY(divider->isVisible());

  // The list itself is Settings › Appearance's (asserted in `tst_settings`);
  // this is the view's half: the keys it accepts and what each one hides.
  const QStringList keys = {
    QStringLiteral("options"), QStringLiteral("info"),
    QStringLiteral("history"), QStringLiteral("original")
  };
  for (const QString& key : keys) {
    QVERIFY2(m_editor->property("panels").toMap().value(QStringLiteral("editor.") + key)
               .toBool(),
             qPrintable(QStringLiteral("%1 does not open visible").arg(key)));
  }

  const auto setPanel = [this](const QString& key, bool visible) {
    QVERIFY(QMetaObject::invokeMethod(m_editor, "setPanelVisible",
                                      Q_ARG(QVariant, key),
                                      Q_ARG(QVariant, visible)));
  };

  // Hiding Tool options leaves the whole dock to the pages: the heading goes
  // with the zone and the divider has no second half to divide.
  setPanel(QStringLiteral("options"), false);
  QTRY_VERIFY(!zone->isVisible());
  QVERIFY(pages->isVisible());
  QTRY_VERIFY(!divider->isVisible());
  QVERIFY(inspector->isVisible());
  QCOMPARE(m_commands->count(), 0);

  // Showing it again restores the heading at the dock's top, not floating in
  // the middle of the column.
  setPanel(QStringLiteral("options"), true);
  QTRY_VERIFY(zone->isVisible());
  QTRY_VERIFY(divider->isVisible());
  QVERIFY2(zone->mapToScene(QPointF(0, 0)).y() - dockTop <= 2.0,
           "the restored tool zone did not sit at the dock's top");

  // Hiding the open page opens the first one that is left; the page keeps its
  // stack slot, so the other pages do not change index.
  selectRightTab("history");
  setPanel(QStringLiteral("history"), false);
  QTRY_COMPARE(m_editor->property("rightTab").toString(), QStringLiteral("info"));
  QVERIFY(expectItem("infoPanel")->isVisible());
  QVERIFY(!expectItem("historyPanel")->isVisible());
  // The hidden tab draws no button either; its page keeps its stack slot.
  QVERIFY(expectItem("editorTab_info")->isVisible());
  QVERIFY(!expectItem("editorTab_history")->isVisible());
  QVERIFY(strip->isVisible());
  QCOMPARE(m_editor->property("shownReferenceCount").toInt(), 2);

  // A hidden tab keeps its stack slot but must not be drawn when it is named:
  // the index falls back to the first tab that is visible. Without that
  // fallback the tab strip says Info while History's page is on screen.
  setLayoutValue(QStringLiteral("editorReferenceTab"), QStringLiteral("history"));
  QTRY_COMPARE(m_editor->property("rightTabIndex").toInt(), 0);
  QVERIFY(expectItem("infoPanel")->isVisible());
  QVERIFY(!expectItem("historyPanel")->isVisible());

  // Hiding the rest leaves the tool frame as the only panel: the pages and the
  // strip are gone, the sidebar is still there, and the frame stays pinned to
  // its top rather than centring its heading in the spare height.
  setPanel(QStringLiteral("info"), false);
  setPanel(QStringLiteral("original"), false);
  QTRY_COMPARE(m_editor->property("shownReferenceCount").toInt(), 0);
  QTRY_VERIFY(!pages->isVisible());
  QTRY_VERIFY(!strip->isVisible());
  QVERIFY(inspector->isVisible());
  selectTool("pointer");
  QVERIFY2(zone->mapToScene(QPointF(0, 0)).y() - dockTop <= 2.0,
           "the only remaining panel was centred in the dock");

  // The checklist still offers every panel, so one toggle brings a page back
  // and opens it; the pages were never renumbered underneath.
  setPanel(QStringLiteral("original"), true);
  QTRY_VERIFY(pages->isVisible());
  QVERIFY(expectItem("originalPanel")->isVisible());
  QCOMPARE(m_editor->property("rightTab").toString(), QStringLiteral("original"));
  QCOMPARE(m_commands->count(), 0);

  // The last panel hides the whole column: no dock, no splitter. Showing any
  // panel brings both back — there is no separate "show sidebar" switch.
  setPanel(QStringLiteral("options"), false);
  setPanel(QStringLiteral("original"), false);
  QTRY_COMPARE(m_editor->property("shownReferenceCount").toInt(), 0);
  QVERIFY(!m_editor->property("toolOptionsVisible").toBool());
  QTRY_VERIFY(!m_editor->property("sidebarShown").toBool());
  QTRY_VERIFY(!inspector->isVisible());
  QVERIFY(!expectItem("editorRightSplitter")->isVisible());

  setPanel(QStringLiteral("info"), true);
  QTRY_VERIFY(inspector->isVisible());
  QVERIFY(expectItem("editorRightSplitter")->isVisible());
  QVERIFY(expectItem("infoPanel")->isVisible());
  QCOMPARE(m_commands->count(), 0);
}

/// The split between the tool frame and the reference pages is the user's. The
/// reference is content-sized by default (`0`), the divider writes a height the
/// layout remembers, and a double-click goes back to "only as tall as the page
/// needs". Whatever the reference takes, the tool frame above gives up.
void TestEditor::theDividerRemembersTheReferenceHeight()
{
  setState(documentState());
  selectTool("crop");
  QQuickItem* dock = expectItem("editorReferenceDock");
  QQuickItem* zone = expectItem("editorToolZone");
  QQuickItem* divider = expectItem("editorToolZoneDivider");
  QQuickItem* pages = expectItem("editorReferencePages");
  QTRY_VERIFY(divider->isVisible());

  // Nothing dragged: the answer is the page's own height. Core stores `0`.
  QCOMPARE(m_editor->property("referenceHeight").toInt(), 0);
  const qreal content = readQml(m_editor, "referenceDock.contentHeight").toDouble();
  QVERIFY2(content > 0.0, "the reference dock measured no content");
  QVERIFY2(qAbs(dock->height() - content) <= 1.0,
           qPrintable(QStringLiteral("the dock is %1 px for %2 px of page")
                        .arg(dock->height())
                        .arg(content)));
  const qreal openDockHeight = dock->height();
  const qreal openZoneHeight = zone->height();

  // A height the layout already remembers is what the dock is drawn at, and the
  // frame above yields the difference rather than overlaying the pages.
  setLayoutValue(QStringLiteral("editorReferenceHeight"), 260);
  QTRY_COMPARE(qRound(dock->height()), 260);
  QVERIFY2(zone->height() < openZoneHeight - 20.0,
           "the tool frame did not give the reference its room");

  // A real drag up grows the reference; the splitter reports the value while
  // the button is down and saves it once, on release.
  const QPointF from(divider->mapToScene(QPointF(divider->width() / 2,
                                                 divider->height() / 2)));
  dragScene(from, from - QPointF(0, 60));
  QTRY_VERIFY2(m_editor->property("referenceHeight").toInt() > 260,
               "the divider drag never wrote a taller reference");
  QTRY_VERIFY2(dock->height() > 260.0 + 20.0,
               qPrintable(QStringLiteral("the reference is still %1 px tall")
                            .arg(dock->height())));
  QVERIFY2(pages->height() + 40.0 <= dock->height() + 1.0,
           "the strip took the height the pages were promised");

  // A double-click puts it back to the page's own height.
  const QPointF handle(divider->mapToScene(QPointF(divider->width() / 2,
                                                   divider->height() / 2)));
  QTest::mouseDClick(m_view, Qt::LeftButton, Qt::NoModifier, handle.toPoint());
  QTRY_COMPARE(m_editor->property("referenceHeight").toInt(), 0);
  QTRY_VERIFY2(qAbs(dock->height() - openDockHeight) <= 1.0,
               qPrintable(QStringLiteral("the dock came back at %1 px, not %2")
                            .arg(dock->height())
                            .arg(openDockHeight)));
  QCOMPARE(m_commands->count(), 0);
}

/// Choosing a tool is a request for its options. If the tool panel was put
/// away with `View > Sidebar`, arming a tool brings it back; the pointer is the
/// no-op tool, so it never forces the panel open.
void TestEditor::armingAToolBringsItsPanelBack()
{
  setState(documentState());
  selectTool("crop");
  QTRY_VERIFY(expectItem("toolOptionsScroll")->isVisible());

  QVERIFY(QMetaObject::invokeMethod(m_editor, "setPanelVisible",
                                    Q_ARG(QVariant, QStringLiteral("options")),
                                    Q_ARG(QVariant, false)));
  QTRY_VERIFY(!expectItem("editorToolZone")->isVisible());
  // The reference pages are still on, so the column itself stays.
  QCOMPARE(m_editor->property("shownReferenceCount").toInt(), 3);
  QVERIFY(m_editor->property("sidebarShown").toBool());

  // The pointer does not force the panel open: it has no options to show.
  selectTool("pointer");
  QVERIFY(!m_editor->property("toolOptionsVisible").toBool());

  clickItem(expectItem("toolBrush"));
  QTRY_COMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));
  QTRY_VERIFY(m_editor->property("toolOptionsVisible").toBool());
  QTRY_VERIFY(expectItem("editorToolZone")->isVisible());
  QTRY_VERIFY(expectItem("foregroundColorField")->isVisible());
  QCOMPARE(m_commands->count(), 0);
}

/// The reference dock asks for the height its open page needs and sits at the
/// bottom, so a short Info page does not leave a tall empty column and the tool
/// frame above takes the rest. Switching tools changes the options, not the
/// reference: the same page stays the same height, and a taller History page
/// grows the dock upward while its bottom edge stays put.
void TestEditor::theReferenceDockFitsItsPage()
{
  QVariantMap editor = documentState();
  QVariantList history;
  for (int index = 0; index < 8; ++index) {
    history.append(QVariantMap{{QStringLiteral("code"), QStringLiteral("rotate_right")},
                               {QStringLiteral("args"), QVariantList{}}});
  }
  editor.insert(QStringLiteral("history"), history);
  setState(editor);
  selectTool("crop");
  QTRY_VERIFY(expectItem("toolOptionsScroll")->isVisible());

  QQuickItem* dock = expectItem("editorReferenceDock");
  QQuickItem* zone = expectItem("editorToolZone");
  QQuickItem* pages = expectItem("editorReferencePages");
  QQuickItem* actions = expectItem("cropActions");
  QQuickItem* options = expectItem("toolOptionsScroll");

  const auto contentHeight = [this]() {
    return readQml(m_editor, QStringLiteral("referenceDock.contentHeight")).toDouble();
  };
  const auto dockBottom = [dock]() {
    return dock->mapToScene(QPointF(0, dock->height())).y();
  };

  QVERIFY2(dock->isVisible(), "the reference dock is not on screen");
  QVERIFY2(qAbs(dock->height() - contentHeight()) <= 1.0,
           qPrintable(QStringLiteral("the dock is %1 px for %2 px of page")
                        .arg(dock->height())
                        .arg(contentHeight())));
  const qreal infoHeight = dock->height();
  const qreal bottom = dockBottom();
  // Content-fit, not a fixed column: the page is a few rows, not a side panel.
  QVERIFY2(infoHeight < zone->height(),
           "the reference took more room than the tool frame");

  // Verbs follow the fields they act on.
  const qreal actionsTop = actions->mapToScene(QPointF(0, 0)).y();
  const qreal optionsBottom = options->mapToScene(QPointF(0, options->height())).y();
  QVERIFY2(actionsTop - optionsBottom >= 0.0 && actionsTop - optionsBottom <= 20.0,
           qPrintable(QStringLiteral("the options end %1 px above Apply")
                        .arg(actionsTop - optionsBottom)));

  // A different tool changes the options, not the reference.
  clickItem(expectItem("toolBrush"));
  QTRY_COMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));
  QTRY_VERIFY(expectItem("foregroundColorField")->isVisible());
  QTRY_COMPARE(qRound(dock->height()), qRound(infoHeight));

  // The pointer has no options, and still no tab of its own changes.
  selectTool("pointer");
  QTRY_VERIFY(expectItem("pointerNoOptions")->isVisible());
  QTRY_COMPARE(qRound(dock->height()), qRound(infoHeight));

  // History is the taller page: the dock grows to fit it, upward from the same
  // bottom edge, instead of scrolling in a fixed box.
  selectRightTab("history");
  QTRY_VERIFY2(qAbs(dock->height() - contentHeight()) <= 1.0,
               "the dock did not follow the History page's height");
  QVERIFY2(dock->height() > infoHeight + 20.0,
           qPrintable(QStringLiteral("History is only %1 px against Info's %2")
                        .arg(dock->height())
                        .arg(infoHeight)));
  QCOMPARE(qRound(dockBottom()), qRound(bottom));

  // A taller window is the tool frame's, not the reference's.
  selectRightTab("info");
  QTRY_COMPARE(qRound(dock->height()), qRound(infoHeight));
  const qreal zoneHeight = zone->height();
  m_editor->setHeight(kHostHeight + 250);
  QCoreApplication::processEvents();
  QTRY_VERIFY2(zone->height() > zoneHeight + 200.0,
               "the tool frame did not take the extra height");
  QTRY_VERIFY2(qAbs(dock->height() - infoHeight) <= 1.0,
               "the content-sized reference grew with the window");
  m_editor->setHeight(kHostHeight);
  QCoreApplication::processEvents();
  QCOMPARE(m_commands->count(), 0);
}

/// The pointer is a tool with nothing to configure, and the frame says so
/// instead of drawing an empty column that reads as a panel that failed to
/// load. Its heading still names the column, and the frame is the same height
/// every other tool gets.
void TestEditor::thePointerSaysItHasNoOptions()
{
  setState(documentState());
  selectTool("crop");
  const qreal frameHeight = expectItem("editorToolZone")->height();
  selectTool("pointer");

  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Pointer options"));
  QQuickItem* note = expectItem("pointerNoOptions");
  QVERIFY(note->isVisible());
  QVERIFY(!note->property("text").toString().isEmpty());
  QVERIFY(!expectItem("toolOptionsScroll")->isVisible());
  QVERIFY(!expectItem("applyCrop")->isVisible());
  QTRY_COMPARE(qRound(expectItem("editorToolZone")->height()), qRound(frameHeight));
  // The tabs share the dock with the frame, as they do for every tool.
  QVERIFY(expectItem("infoPanel")->isVisible());
  QCOMPARE(m_commands->count(), 0);
}

/// A short window caps the options instead of pushing the tabs out: the column
/// scrolls, and the reference tabs keep their room. This is the one state where
/// the tool zone does not hug its content.
void TestEditor::theReferenceZoneKeepsRoomWhenTheWindowIsShort()
{
  setState(documentState());
  selectTool("crop");
  QTRY_VERIFY(expectItem("toolOptionsScroll")->isVisible());

  m_editor->setHeight(430);
  // Two 430 px windows' worth of layout: the cap is computed from the dock's
  // height, which the resize moves before the column re-lays.
  QTRY_VERIFY2_WITH_TIMEOUT(expectItem("toolOptionsHost")->height() < 200.0,
                            "the options were not capped by the short window",
                            3000);
  QTRY_VERIFY2(expectItem("editorReferenceDock")->height() >= 140.0,
               "the reference dock dropped below its floor in a short window");
  QTRY_VERIFY2(expectItem("editorReferencePages")->height() >= 40.0,
               "the reference tabs lost their room in a short window");
  const qreal optionsCap =
    readQml(m_editor, QStringLiteral("inspector.optionsCap")).toDouble();
  QVERIFY2(expectItem("toolOptionsScroll")->property("height").toDouble()
             <= optionsCap + 1.0,
           qPrintable(QStringLiteral("the options column is %1 px against a %2 px cap")
                        .arg(expectItem("toolOptionsScroll")->property("height").toDouble())
                        .arg(optionsCap)));
  // The options really are scrollable: their content is taller than the host.
  QVERIFY(expectItem("toolOptionsHost")->height()
          < readQml(m_editor, QStringLiteral("toolOptionsColumn.implicitHeight")).toDouble());
  QVERIFY(expectItem("cropX")->isVisible());

  m_editor->setHeight(kHostHeight);
  QCoreApplication::processEvents();
  QCOMPARE(m_commands->count(), 0);
}

/// Opening the size form puts the tool down: the form is the answer to "how
/// big", not a mode the canvas stays in. Arming Crop first proves the palette
/// really returns to the pointer.
void TestEditor::theResizeFormReturnsToThePointer()
{
  setState(documentState());
  selectTool("crop");
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("crop"));

  clickItem(expectItem("toolResize"));
  QTRY_VERIFY(resizeDialogObject()->property("opened").toBool());
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("pointer"));
  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Pointer options"));
  QVERIFY(!expectItem("applyCrop")->isVisible());
  closeResizeDialog(expectItem("resizeCancel"));
  QCOMPARE(m_commands->count(), 0);
}

/// The third tab is the file on disk, not the working preview: its name, its
/// size and its identity follow a save, so a rewritten JPEG shows the new file
/// rather than a cached picture of the old one.
void TestEditor::theOriginalTabShowsTheSavedFile()
{
  setState(documentState());
  selectRightTab("original");
  QVERIFY(expectItem("originalPanel")->isVisible());

  QQuickItem* thumb = expectItem("originalThumbnail");
  QVERIFY(thumb->isVisible());
  QCOMPARE(thumb->property("path").toString(), QStringLiteral("/pics/photo.png"));
  QCOMPARE(thumb->property("modified").toLongLong(), Q_INT64_C(1700000000002));
  QCOMPARE(thumb->property("fileSize").toLongLong(), Q_INT64_C(123456));
  const QString caption = expectItem("originalCaption")->property("text").toString();
  QVERIFY2(caption.contains(QStringLiteral("photo.png")), qPrintable(caption));
  QVERIFY2(caption.contains(QStringLiteral("KB")), qPrintable(caption));

  // A Save publishes a new save path and a new file identity; the tab follows
  // both without the tool or the open tab changing.
  QVariantMap saved = documentState();
  saved.insert(QStringLiteral("savePath"), QStringLiteral("/pics/exported.png"));
  saved.insert(QStringLiteral("saved"), true);
  saved.insert(QStringLiteral("fileModified"), Q_INT64_C(1700000000999));
  saved.insert(QStringLiteral("fileSize"), Q_INT64_C(654321));
  setState(saved);
  QTRY_COMPARE(expectItem("originalThumbnail")->property("modified").toLongLong(),
               Q_INT64_C(1700000000999));
  QCOMPARE(expectItem("originalThumbnail")->property("path").toString(),
           QStringLiteral("/pics/exported.png"));
  QVERIFY(expectItem("originalCaption")->property("text").toString()
            .contains(QStringLiteral("exported.png")));
  QCOMPARE(m_editor->property("rightTab").toString(), QStringLiteral("original"));
  QCOMPARE(m_commands->count(), 0);
}

/// The left column is a tool rail, not a second toolbar: a drawing with its
/// sentence in a tooltip, two columns wide, and one column for a narrow
/// window. The fold is presentation state — no command leaves the view — and
/// the icons are the repository's own files, because an icon-only rail with a
/// blank button is a memory test.
void TestEditor::theToolRailIsAnIconColumn()
{
  setState(documentState());

  QQuickItem* rail = expectItem("editorTools");
  QQuickItem* grid = expectItem("editorToolGrid");
  QQuickItem* edits = expectItem("editorEditGrid");
  QCOMPARE(grid->property("columns").toInt(), 2);
  QCOMPARE(edits->property("columns").toInt(), 2);
  // 8 px margins either side, two 34 px buttons and the 4 px gap between them.
  QCOMPARE(rail->width(), 88.0);

  const QList<QPair<QString, QString>> expected = {
    { QStringLiteral("toolPointer"), QStringLiteral("icons/pointer.svg") },
    { QStringLiteral("toolResize"), QStringLiteral("icons/resize.svg") },
    { QStringLiteral("toolCrop"), QStringLiteral("icons/crop.svg") },
    { QStringLiteral("toolTransform"), QStringLiteral("icons/transform.svg") },
    { QStringLiteral("toolBrush"), QStringLiteral("icons/brush.svg") },
    { QStringLiteral("toolEraser"), QStringLiteral("icons/eraser.svg") },
    { QStringLiteral("editsRotateLeft"), QStringLiteral("icons/rotate-left.svg") },
    { QStringLiteral("editsRotateRight"), QStringLiteral("icons/rotate-right.svg") },
    { QStringLiteral("editsFlipHorizontal"), QStringLiteral("icons/flip-horizontal.svg") },
    { QStringLiteral("editsFlipVertical"), QStringLiteral("icons/flip-vertical.svg") },
  };
  for (const auto& entry : expected) {
    QQuickItem* button = expectItem(entry.first.toLatin1().constData());
    QVERIFY2(button->isVisible(), qPrintable(entry.first));
    // Icon-only: the drawing carries the meaning and the tooltip carries the
    // words, so there is no label to be elided in a 34 px column.
    QCOMPARE(button->property("text").toString(), QString());
    QCOMPARE(readQml(button, QStringLiteral("icon.source")).toString(), entry.second);
    // The button draws the drawing itself. `icon.source` alone is not enough:
    // Breeze's Button content item only reads `icon.name` and puts a generic
    // document glyph in every square, so a rail that delegated the drawing to
    // the style was a row of identical pages.
    QCOMPARE(readQml(button, QStringLiteral("iconDrawing.source")).toString(), entry.second);
    QCOMPARE(readQml(button, QStringLiteral("iconDrawing.width")).toDouble(), 20.0);
    QCOMPARE(readQml(button, QStringLiteral("iconDrawing.height")).toDouble(), 20.0);
    const QString tooltip = readQml(button, QStringLiteral("ToolTip.text")).toString();
    QVERIFY2(!tooltip.isEmpty(), qPrintable(entry.first + QStringLiteral(" has no tooltip")));
    QCOMPARE(readQml(button, QStringLiteral("Accessible.name")).toString(), tooltip);
  }

  // The rail's own width is its one control. A single column is 38 px narrower
  // (34 px of button and the 4 px gap), the heading no longer fits, and every
  // button is still there — a fold, not a different set of tools.
  QQuickItem* toggle = expectItem("toolRailColumns");
  QCOMPARE(readQml(toggle, QStringLiteral("icon.source")).toString(),
           QStringLiteral("icons/columns-one.svg"));
  clickItem(toggle);
  QCOMPARE(m_editor->property("toolColumns").toInt(), 1);
  QCOMPARE(grid->property("columns").toInt(), 1);
  QCOMPARE(edits->property("columns").toInt(), 1);
  QCOMPARE(rail->width(), 50.0);
  QVERIFY(!expectItem("editsHeading")->isVisible());
  for (const auto& entry : expected) {
    QQuickItem* button = expectItem(entry.first.toLatin1().constData());
    QVERIFY2(button->isVisible(), qPrintable(entry.first));
    QCOMPARE(readQml(button, QStringLiteral("icon.source")).toString(), entry.second);
  }

  clickItem(toggle);
  QCOMPARE(m_editor->property("toolColumns").toInt(), 2);
  QCOMPARE(grid->property("columns").toInt(), 2);
  QCOMPARE(rail->width(), 88.0);
  QCOMPARE(readQml(toggle, QStringLiteral("icon.source")).toString(),
           QStringLiteral("icons/columns-one.svg"));
  QCOMPARE(m_commands->count(), 0);
}

/// A unit is a way of writing the same pixel quantity. The document, the
/// protocol and Core stay in whole pixels, the panel re-displays the rectangle
/// it already has, and a unit change is not an edit: it must not re-link the
/// two sides or count as a typed value.
void TestEditor::theUnitsAreAnotherSpellingOfTheSamePixels()
{
  setState(documentState());  // 4000 × 3000
  selectTool("crop");

  QQuickItem* width = expectItem("cropWidth");
  QQuickItem* height = expectItem("cropHeight");
  QQuickItem* x = expectItem("cropX");
  QQuickItem* y = expectItem("cropY");

  typeInto(width, QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));
  QCOMPARE(x->property("text").toString(), QStringLiteral("1600"));
  QCOMPARE(y->property("text").toString(), QStringLiteral("1200"));

  // A place is a pixel coordinate, so X and Y carry no unit selector at all.
  QVERIFY(!expectItem("cropXUnit")->isVisible());
  QVERIFY(!expectItem("cropYUnit")->isVisible());

  // A percentage is taken of the side the field describes: Width of the
  // document's width, Height of its height.
  chooseUnit("cropWidth", QStringLiteral("%"));
  chooseUnit("cropHeight", QStringLiteral("%"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("20"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("20"));
  QCOMPARE(m_commands->count(), 0);

  // Back to pixels: the same numbers, because the unit switch redraws the
  // quantity it already holds instead of re-deriving it.
  chooseUnit("cropWidth", QStringLiteral("px"));
  chooseUnit("cropHeight", QStringLiteral("px"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("600"));

  // The same 50 % on the other axis is 1500 px, not 2000: a percentage is of
  // the document side the field belongs to.
  typeInto(height, QStringLiteral("1500"));
  chooseUnit("cropHeight", QStringLiteral("%"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("50"));
  chooseUnit("cropHeight", QStringLiteral("px"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("1500"));

  // A percentage is written with two decimals, so a one-pixel quantity of a
  // 4000 px document survives a trip through `%`: 1 px → 0.03 % → 1 px. A
  // whole-number percentage would lose it (0 % → 0 px).
  typeInto(width, QStringLiteral("1"));
  chooseUnit("cropWidth", QStringLiteral("%"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("0.03"));
  chooseUnit("cropWidth", QStringLiteral("px"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("1"));

  // Typing a percentage is the same typed value as typing pixels: the command
  // still carries whole pixels, and the fields keep their own units.
  typeInto(width, QStringLiteral("800"));
  typeInto(height, QStringLiteral("600"));
  typeInto(x, QStringLiteral("1000"));
  typeInto(y, QStringLiteral("1200"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("800"));

  clickItem(expectItem("applyCrop"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap crop = m_commands->takeFirst().at(0).toMap();
  QCOMPARE(crop.value(QStringLiteral("type")).toString(), QStringLiteral("editor_crop"));
  QCOMPARE(crop.value(QStringLiteral("x")).toInt(), 1000);
  QCOMPARE(crop.value(QStringLiteral("y")).toInt(), 1200);
  QCOMPARE(crop.value(QStringLiteral("width")).toInt(), 800);
  QCOMPARE(crop.value(QStringLiteral("height")).toInt(), 600);
}

/// The size form shares the same field: a scale can be described as a
/// percentage of the document, and Apply still sends pixels.
void TestEditor::theResizeFormTakesPercentagesToo()
{
  setState(documentState());  // 4000 × 3000
  openResizeDialog();

  QQuickItem* width = expectItem("resizeWidth");
  QQuickItem* height = expectItem("resizeHeight");
  // A form opens in pixels whatever the previous visit chose.
  QCOMPARE(width->property("text").toString(), QStringLiteral("4000"));
  QCOMPARE(m_editor->property("cropRatio").toString(), QStringLiteral("free"));

  chooseUnit("resizeWidth", QStringLiteral("%"));
  QCOMPARE(width->property("text").toString(), QStringLiteral("100"));

  typeInto(width, QStringLiteral("50"));
  // The chain keeps the document's shape, so 50 % of 3000 is 1500 — written in
  // the unit the height field already has.
  QCOMPARE(height->property("text").toString(), QStringLiteral("1500"));
  chooseUnit("resizeHeight", QStringLiteral("%"));
  QCOMPARE(height->property("text").toString(), QStringLiteral("50"));

  clickItem(expectItem("resizeApply"));
  QCOMPARE(m_commands->count(), 1);
  const QVariantMap resize = m_commands->takeFirst().at(0).toMap();
  QCOMPARE(resize.value(QStringLiteral("type")).toString(), QStringLiteral("editor_resize"));
  QCOMPARE(resize.value(QStringLiteral("width")).toInt(), 2000);
  QCOMPARE(resize.value(QStringLiteral("height")).toInt(), 1500);
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
  // Editor allows Krita-style panMargin freedom when panning with Hand or Space,
  // while still clamping so the picture stays reachable inside the viewport.
  const double margin = canvasHost->property("panMargin").toDouble();
  QVERIFY(margin >= 64.0);
  const double maxX = qMax(0.0, (scaledWidth - canvasHost->width()) / 2.0) + margin;
  const double maxY = qMax(0.0, (scaledHeight - canvasHost->height()) / 2.0) + margin;
  QVERIFY2(qAbs(m_editor->property("offsetX").toDouble()) <= maxX + 0.001,
           "offsetX left the picture's own bounds");
  QVERIFY2(qAbs(m_editor->property("offsetY").toDouble()) <= maxY + 0.001,
           "offsetY left the picture's own bounds");
  if (scaledHeight <= canvasHost->height()) {
    QVERIFY(qAbs(m_editor->property("offsetY").toDouble()) <= margin + 0.001);
  }

  QVERIFY(findObject(QStringLiteral("editorWheelHandler")) != nullptr);
  QVERIFY(findObject(QStringLiteral("editorPanHandler")) != nullptr);
}

/// Tight canvas bounds: a fitted picture stays centred (no drift), and once
/// zoomed past the viewport the Hand tool (H) pans strictly up to the edges.
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

  // Switch to the Hand tool via its Krita/Photoshop shortcut `H`.
  QTest::keyClick(m_view, Qt::Key_H);
  QCoreApplication::processEvents();
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("hand"));

  // Zoom in so both axes exceed the viewport, then drag with the Hand tool.
  QMetaObject::invokeMethod(m_editor, "actualSize");
  QTest::qWait(20);
  QQuickItem* canvas = expectItem("canvas");
  const QPointF start = canvas->mapToScene(QPointF(canvas->width() / 2.0, canvas->height() / 2.0));
  const QPoint target = start.toPoint();
  QTest::mouseMove(m_view, target);
  QTest::qWait(30);
  QVERIFY2(m_editor->property("panHover").toBool(), "the canvas hover never armed the pan handler");

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
           qPrintable(QStringLiteral("a vertical drag did not pan a zoomed picture: offsetY %1")
                        .arg(offsetY)));
  QVERIFY2(offsetX > 1.0,
           qPrintable(QStringLiteral("a horizontal drag did not pan: offsetX %1").arg(offsetX)));
  QCOMPARE(m_commands->count(), 0);
}

/// Touchpad + middle-click + Space priority: Pointer/Crop/Transform/Paint only
/// accept middle-click pan, while Hand (H) or holding Space enables left-click
/// pan and suspends active overlays (including Crop's create area).
void TestEditor::thePanHandlerTakesTouchpadsAndMiddleClicks()
{
  setState(documentState());
  QObject* pan = findObject(QStringLiteral("editorPanHandler"));
  QVERIFY(pan != nullptr);

  const auto devices = pan->property("acceptedDevices").value<QPointingDevice::DeviceTypes>();
  QVERIFY2(devices.testFlag(QPointingDevice::DeviceType::TouchPad),
           "the pan handler ignores touchpads");
  QVERIFY(devices.testFlag(QPointingDevice::DeviceType::Mouse));

  // Pointer tool does not pan with LeftButton (only MiddleButton).
  const auto pointerButtons = pan->property("acceptedButtons").value<Qt::MouseButtons>();
  QVERIFY2(!pointerButtons.testFlag(Qt::LeftButton) && pointerButtons.testFlag(Qt::MiddleButton),
           "pointer tool should only pan with middle-button");

  // Hand tool enables both LeftButton and MiddleButton.
  m_editor->setProperty("tool", QStringLiteral("hand"));
  QCoreApplication::processEvents();
  const auto handButtons = pan->property("acceptedButtons").value<Qt::MouseButtons>();
  QVERIFY2(handButtons.testFlag(Qt::LeftButton) && handButtons.testFlag(Qt::MiddleButton),
           "hand tool must pan with left and middle buttons");

  // Crop and Transform reserve LeftButton for their overlays, unless Space is held.
  for (const char* name : {"crop", "transform"}) {
    selectTool(name);
    QCOMPARE(m_editor->property("tool").toString(), QString::fromLatin1(name));
    const auto armed = pan->property("acceptedButtons").value<Qt::MouseButtons>();
    QVERIFY2(!armed.testFlag(Qt::LeftButton) && armed.testFlag(Qt::MiddleButton),
             qPrintable(QStringLiteral("%1 still pans with the left button")
                          .arg(QString::fromLatin1(name))));
    // Holding Space suspends the overlay and hands LeftButton back to pan.
    m_editor->setProperty("spacePanning", true);
    QCoreApplication::processEvents();
    const auto spaceButtons = pan->property("acceptedButtons").value<Qt::MouseButtons>();
    QVERIFY2(spaceButtons.testFlag(Qt::LeftButton),
             qPrintable(QStringLiteral("Space did not enable left-pan in %1").arg(name)));
    QObject* overlay = findObject(QString::fromLatin1(
        std::strcmp(name, "crop") == 0 ? "cropOverlay" : "transformOverlay"));
    QVERIFY(overlay != nullptr);
    QVERIFY2(!overlay->property("enabled").toBool(),
             qPrintable(QStringLiteral("Space did not suspend %1 overlay").arg(name)));
    m_editor->setProperty("spacePanning", false);
    QCoreApplication::processEvents();
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
           QStringLiteral("Brush options"));
  QVERIFY(expectItem("foregroundColorField")->isVisible());
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
  m_editor->setProperty("foregroundColor", QStringLiteral("#ff0000"));
  m_editor->setProperty("paintSize", 80.0);
  m_editor->setProperty("paintOpacity", 50);

  clickItem(expectItem("toolEraser"));
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("paint"));
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("eraser"));
  QCOMPARE(expectItem("toolOptionsHeading")->property("text").toString(),
           QStringLiteral("Eraser options"));

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
/// X swaps the colours and D resets them.
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

  QCOMPARE(m_editor->property("foregroundColor").toString(), QStringLiteral("#000000"));
  QTest::keyClick(m_view, Qt::Key_X);
  QCOMPARE(m_editor->property("foregroundColor").toString(), QStringLiteral("#ffffff"));
  QCOMPARE(m_editor->property("backgroundColor").toString(),
           QStringLiteral("#000000"));
  QTest::keyClick(m_view, Qt::Key_D);
  QCOMPARE(m_editor->property("foregroundColor").toString(), QStringLiteral("#000000"));
  QCOMPARE(m_editor->property("backgroundColor").toString(),
           QStringLiteral("#ffffff"));

  // Typing into a field keeps its own keys: B/E/[/] must not fire from the
  // field's keystrokes, which is why the handlers live on the view and not on
  // a window-wide Shortcut.
  QQuickItem* field = expectItem("foregroundColorField");
  field->forceActiveFocus();
  QTest::qWait(10);
  QTest::keyClick(m_view, Qt::Key_B);
  QCOMPARE(m_editor->property("paintMode").toString(), QStringLiteral("eraser"));
  m_editor->forceActiveFocus();

  QCOMPARE(m_commands->count(), 0);
}

/// A JPEG has no alpha and Core's encoder composites it over white, so a
/// transparent background is still allowed — the picture on screen really is
/// clear, and an Export to PNG keeps it — but the list says what the document's
/// own save will do with it, at the only moment the answer can still change.
void TestEditor::theJpegWarningSitsInTheBackgroundList()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("format"), QStringLiteral(".png"));
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/photo.png"));
  setState(editor);
  selectTool("crop");

  QObject* popup = findObject(QStringLiteral("backgroundPopup"));
  QVERIFY(popup != nullptr);
  QVERIFY(QMetaObject::invokeMethod(popup, "open"));
  QTRY_VERIFY(popup->property("opened").toBool());
  QVERIFY(!expectItem("backgroundPopupWarning")->isVisible());
  QVERIFY(QMetaObject::invokeMethod(popup, "close"));
  QTRY_VERIFY(!popup->property("opened").toBool());

  // The same picture saved as a JPEG: the list says what the encoder does, and
  // Transparent is still offered.
  editor.insert(QStringLiteral("format"), QStringLiteral(".jpg"));
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/photo.jpg"));
  setState(editor);
  QVERIFY(QMetaObject::invokeMethod(popup, "open"));
  QTRY_VERIFY(popup->property("opened").toBool());
  QVERIFY(expectItem("backgroundPopupWarning")->isVisible());
  QVERIFY(expectItem("backgroundPopupChoice_transparent")->isVisible());
  QVERIFY(QMetaObject::invokeMethod(popup, "close"));
  QTRY_VERIFY(!popup->property("opened").toBool());

  m_view->requestActivate();
  m_editor->forceActiveFocus();
  QTest::qWait(50);
  QCOMPARE(m_commands->count(), 0);
}

/// The Editor's one foreground/background pair, as Photoshop draws it: the
/// foreground box raised over the background one, the swap arrow (X) and the
/// reset square (D) inside the same 34 x 34. The pair is the Editor's, not the
/// brush's: it lives in the tool rail, it is there for every tool, and its
/// background box is where "the colour of new canvas" is chosen.
void TestEditor::theColourPairIsTheEditorsOnePair()
{
  setState(documentState());

  // The pair is view state, not a paint option: it is on screen with a document
  // open and a tool that places no marks, because the background answers for
  // Crop's grow border and for a padded resize too.
  clickItem(expectItem("toolCrop"));
  QTRY_VERIFY(expectItem("colourPair")->isVisible());
  QCOMPARE(m_editor->property("tool").toString(), QStringLiteral("crop"));

  QQuickItem* pair = expectItem("colourPair");
  QQuickItem* foreground = expectItem("colourPairForegroundSwatch");
  QQuickItem* background = expectItem("colourPairBackgroundSwatch");
  QVERIFY(foreground->parentItem() == pair);
  QVERIFY(background->parentItem() == pair);

  // Two targets, not one picture: the background sits offset behind the
  // foreground, and both fit inside the pair's own box — which is what makes
  // each corner of the pair a clickable colour rather than dead space.
  QVERIFY(background->x() > foreground->x());
  QVERIFY(background->y() > foreground->y());
  QVERIFY(pair->width() >= background->x() + background->width());
  QVERIFY(pair->height() >= background->y() + background->height());
  QVERIFY(expectItem("colourPairSwap")->isVisible());
  QVERIFY(expectItem("colourPairReset")->isVisible());
  // The pair starts black over white, with nothing transparent.
  QCOMPARE(foreground->property("color").value<QColor>(), QColor(0, 0, 0));
  QCOMPARE(background->property("color").value<QColor>(), QColor(255, 255, 255));
  QVERIFY(!expectItem("colourPairBackgroundSwatchCheckerboard")->isVisible());

  // The foreground's box opens the foreground's chooser, and the background's
  // box opens the background list — not a chooser, because a chooser cannot say
  // "no colour" and transparency is a real background.
  QObject* foregroundChooser = findObject(QStringLiteral("foregroundColorDialog"));
  QVERIFY(foregroundChooser != nullptr);
  QCOMPARE(foregroundChooser->property("title").toString(),
           QStringLiteral("Foreground color"));
  QCOMPARE(foregroundChooser->property("selectedColor").value<QColor>(), QColor(0, 0, 0));

  clickItem(foreground);
  QTRY_VERIFY_WITH_TIMEOUT(foregroundChooser->property("visible").toBool(), 2000);
  QVERIFY(QMetaObject::invokeMethod(foregroundChooser, "close"));
  QTRY_VERIFY_WITH_TIMEOUT(!foregroundChooser->property("visible").toBool(), 2000);

  // A popup takes the keyboard while it is open; hand it back, or every later
  // test that types into the view fails on a focus it did not lose.
  m_view->requestActivate();
  m_editor->forceActiveFocus();
  QTest::qWait(50);

  QObject* popup = findObject(QStringLiteral("backgroundPopup"));
  QVERIFY(popup != nullptr);
  clickItem(background);
  QTRY_VERIFY_WITH_TIMEOUT(popup->property("opened").toBool(), 2000);

  // The list is the one background list: transparent, three named colours, and
  // the chooser behind the last row.
  QVERIFY(expectItem("backgroundPopupChoice_transparent")->isVisible());
  QVERIFY(expectItem("backgroundPopupChoice_white")->isVisible());
  QVERIFY(expectItem("backgroundPopupChoice_black")->isVisible());
  QVERIFY(expectItem("backgroundPopupChoice_gray")->isVisible());
  QVERIFY(expectItem("backgroundPopupChoice_custom")->isVisible());

  clickItem(expectItem("backgroundPopupChoice_black"));
  QTRY_VERIFY_WITH_TIMEOUT(!popup->property("opened").toBool(), 2000);
  QCOMPARE(m_editor->property("backgroundColor").toString(), QStringLiteral("#000000"));
  QVERIFY(!m_editor->property("backgroundTransparent").toBool());
  QCOMPARE(background->property("color").value<QColor>(), QColor(0, 0, 0));

  // Transparent is a state, not a colour: the box draws the checkerboard and
  // the colour it remembered is still there for the way back.
  QMetaObject::invokeMethod(popup, "open");
  QTRY_VERIFY_WITH_TIMEOUT(popup->property("opened").toBool(), 2000);
  clickItem(expectItem("backgroundPopupChoice_transparent"));
  QTRY_VERIFY_WITH_TIMEOUT(!popup->property("opened").toBool(), 2000);
  QVERIFY(m_editor->property("backgroundTransparent").toBool());
  QVERIFY(expectItem("colourPairBackgroundSwatchCheckerboard")->isVisible());
  QCOMPARE(m_editor->property("backgroundColor").toString(), QStringLiteral("#000000"));

  // A swap trades the two colours and leaves transparency where it is: it
  // belongs to the background role, so X can never make the foreground clear.
  QTest::keyClick(m_view, Qt::Key_X);
  QCOMPARE(m_editor->property("foregroundColor").toString(), QStringLiteral("#000000"));
  QCOMPARE(m_editor->property("backgroundColor").toString(), QStringLiteral("#000000"));
  QVERIFY(m_editor->property("backgroundTransparent").toBool());
  QTest::keyClick(m_view, Qt::Key_D);
  QVERIFY(!m_editor->property("backgroundTransparent").toBool());
  QVERIFY(!expectItem("colourPairBackgroundSwatchCheckerboard")->isVisible());

  m_view->requestActivate();
  m_editor->forceActiveFocus();
  QTest::qWait(50);

  // The hex field is the foreground's exact value, which a chooser cannot say,
  // and an unreadable one is refused rather than shown as a different colour.
  QVERIFY(QMetaObject::invokeMethod(m_editor, "setForegroundColor",
                                    Q_ARG(QVariant, QStringLiteral("123456"))));
  QCOMPARE(foreground->property("color").value<QColor>(), QColor(0x12, 0x34, 0x56));
  QCOMPARE(m_editor->property("foregroundColor").toString(), QStringLiteral("#123456"));
  QMetaObject::invokeMethod(m_editor, "setForegroundColor",
                            Q_ARG(QVariant, QStringLiteral("#12345")));
  QMetaObject::invokeMethod(m_editor, "setForegroundColor",
                            Q_ARG(QVariant, QStringLiteral("no")));
  QCOMPARE(foreground->property("color").value<QColor>(), QColor(0x12, 0x34, 0x56));

  // The chooser is seeded on the click, so a colour that changed since — a
  // typed hex, X or D — is the colour it opens on. A `ColorDialog` writes
  // `selectedColor` itself while it is open, so it cannot be a plain binding.
  clickItem(foreground);
  QTRY_VERIFY_WITH_TIMEOUT(foregroundChooser->property("visible").toBool(), 2000);
  QCOMPARE(foregroundChooser->property("selectedColor").value<QColor>(),
           QColor(0x12, 0x34, 0x56));
  QVERIFY(QMetaObject::invokeMethod(foregroundChooser, "close"));
  QTRY_VERIFY_WITH_TIMEOUT(!foregroundChooser->property("visible").toBool(), 2000);
  m_view->requestActivate();
  m_editor->forceActiveFocus();
  QTest::qWait(50);

  // With the rail hidden (Settings > Appearance can put it away) the same pair
  // is drawn in the paint options, from the same component and the same two
  // properties, so the colours are never unreachable.
  clickItem(expectItem("toolBrush"));
  QTRY_VERIFY(expectItem("foregroundColorField")->isVisible());
  QVERIFY(!expectItem("optionsColourPair")->isVisible());
  QVariantMap panels;
  panels.insert(QStringLiteral("editor.tools"), false);
  QVariantMap patch;
  patch.insert(QStringLiteral("panels"), panels);
  layoutPatched(patch);
  QTRY_VERIFY(!expectItem("colourPair")->isVisible());
  QTRY_VERIFY(expectItem("optionsColourPair")->isVisible());
  QCOMPARE(expectItem("optionsColourPairForegroundSwatch")->property("color").value<QColor>(),
           QColor(0x12, 0x34, 0x56));
  QCOMPARE(expectItem("optionsColourPairBackgroundSwatch")->property("color").value<QColor>(),
           QColor(255, 255, 255));
  resetLayout();
  QTRY_VERIFY(expectItem("colourPair")->isVisible());

  // An answer from a chooser carries an alpha byte (`#ff1e2d3c`); the pair, and
  // so the three bytes a command carries, drops it.
  QVariant colourText;
  QVERIFY(QMetaObject::invokeMethod(
    m_editor, "colorText", Q_RETURN_ARG(QVariant, colourText),
    Q_ARG(QVariant, QColor(30, 45, 60, 128))));
  QCOMPARE(colourText.toString(), QStringLiteral("#1e2d3c"));

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
