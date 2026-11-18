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
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QVariantMap>
#include <QWheelEvent>

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
  void emptyStateOffersToOpenAnImage();
  void theViewFollowsThePublishedDocument();
  void rotateAndFlipEmitTypedCommands();
  void undoRedoResetAndCloseEmitCommands();
  void resizeApplyEmitsTheTypedSize();
  void cropApplyEmitsTheTypedRectangle();
  void anInvalidOrEmptySizeKeepsApplyDisabled();
  void theLeftSidebarHoldsTheEditsAndTheRightTheCommands();
  void saveAndSaveAsEmitTheirCommands();
  void toolbarTooltipsNameTheirShortcuts();
  void saveAsSuggestsTheCurrentLocation();
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

void TestEditor::clickItem(QQuickItem* item)
{
  QVERIFY(item != nullptr);
  QVERIFY2(item->isVisible(), qPrintable(item->objectName()));
  const QPoint centre =
    item->mapToScene(QPointF(item->width() / 2.0, item->height() / 2.0)).toPoint();
  QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre);
  QTest::qWait(20);
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
  editor.insert(QStringLiteral("rendering"), false);
  editor.insert(QStringLiteral("savePath"), QStringLiteral("/pics/photo.png"));
  editor.insert(QStringLiteral("saved"), true);
  editor.insert(QStringLiteral("format"), QStringLiteral(".png"));
  editor.insert(QStringLiteral("saving"), false);
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

void TestEditor::emptyStateOffersToOpenAnImage()
{
  setState(QVariantMap{});  // no document
  QVERIFY(!m_editor->property("hasDocument").toBool());

  QQuickItem* open = expectItem("editorOpenButton");
  QQuickItem* rotate = expectItem("editsRotateLeft");
  QVERIFY(!rotate->property("enabled").toBool());

  clickItem(open);
  QCOMPARE(m_requestOpen->count(), 1);
  QCOMPARE(m_commands->count(), 0);
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

  // After an edit Core publishes canUndo/modified and history labels.
  editor.insert(QStringLiteral("canUndo"), true);
  editor.insert(QStringLiteral("canRedo"), true);
  editor.insert(QStringLiteral("modified"), true);
  editor.insert(QStringLiteral("history"),
                QVariantList{QStringLiteral("Rotate right 90°"),
                             QStringLiteral("Crop 10 × 8 at 4,2")});
  editor.insert(QStringLiteral("redoCount"), 3);
  setState(editor);

  QVERIFY(undo->property("enabled").toBool());
  QVERIFY(redo->property("enabled").toBool());
  QVERIFY(reset->property("enabled").toBool());

  QQuickItem* history = expectItem("historyList");
  QCOMPARE(history->property("count").toInt(), 2);
}

void TestEditor::rotateAndFlipEmitTypedCommands()
{
  setState(documentState());
  // The left sidebar lists every edit, and the toolbar repeats the two most
  // used ones; each must send the same typed command.
  clickItem(expectItem("editsRotateLeft"));
  clickItem(expectItem("editsRotateRight"));
  clickItem(expectItem("editorRotateRight"));
  clickItem(expectItem("editsFlipHorizontal"));
  clickItem(expectItem("editsFlipVertical"));

  QCOMPARE(m_commands->count(), 5);
  QVariantMap first = m_commands->at(0).at(0).toMap();
  QCOMPARE(first.value("type").toString(), QStringLiteral("editor_rotate"));
  QCOMPARE(first.value("degrees").toInt(), -90);
  QVariantMap second = m_commands->at(1).at(0).toMap();
  QCOMPARE(second.value("type").toString(), QStringLiteral("editor_rotate"));
  QCOMPARE(second.value("degrees").toInt(), 90);
  QVariantMap third = m_commands->at(2).at(0).toMap();
  QCOMPARE(third.value("type").toString(), QStringLiteral("editor_rotate"));
  QCOMPARE(third.value("degrees").toInt(), 90);
  QVariantMap fourth = m_commands->at(3).at(0).toMap();
  QCOMPARE(fourth.value("type").toString(), QStringLiteral("editor_flip"));
  QCOMPARE(fourth.value("axis").toString(), QStringLiteral("horizontal"));
  QVariantMap fifth = m_commands->at(4).at(0).toMap();
  QCOMPARE(fifth.value("type").toString(), QStringLiteral("editor_flip"));
  QCOMPARE(fifth.value("axis").toString(), QStringLiteral("vertical"));
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

  QQuickItem* width = expectItem("widthField");
  QQuickItem* height = expectItem("heightField");
  QQuickItem* apply = expectItem("applyResize");
  width->setProperty("text", QStringLiteral("800"));
  height->setProperty("text", QStringLiteral("600"));
  QTest::qWait(20);
  QVERIFY(apply->property("enabled").toBool());

  clickItem(apply);
  QCOMPARE(m_commands->count(), 1);
  QVariantMap command = m_commands->at(0).at(0).toMap();
  QCOMPARE(command.value("type").toString(), QStringLiteral("editor_resize"));
  QCOMPARE(command.value("width").toInt(), 800);
  QCOMPARE(command.value("height").toInt(), 600);
}

void TestEditor::cropApplyEmitsTheTypedRectangle()
{
  setState(documentState());

  QQuickItem* cropX = expectItem("cropX");
  QQuickItem* cropY = expectItem("cropY");
  QQuickItem* width = expectItem("widthField");
  QQuickItem* height = expectItem("heightField");
  QQuickItem* apply = expectItem("applyCrop");

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

void TestEditor::anInvalidOrEmptySizeKeepsApplyDisabled()
{
  setState(documentState());

  QQuickItem* width = expectItem("widthField");
  QQuickItem* height = expectItem("heightField");
  QQuickItem* apply = expectItem("applyResize");
  width->setProperty("text", QString());
  height->setProperty("text", QStringLiteral("300"));
  QTest::qWait(20);
  QVERIFY(!apply->property("enabled").toBool());
  clickItem(apply);
  QCOMPARE(m_commands->count(), 0);
}

/// The Editor's two sidebars have one job each: the left lists the operations
/// that change pixels, the right holds the inputs and the save target. Moving a
/// button back across would make a user look for an edit in a place that only
/// describes one.
void TestEditor::theLeftSidebarHoldsTheEditsAndTheRightTheCommands()
{
  QVariantMap editor = documentState();
  editor.insert(QStringLiteral("history"), QVariantList{QStringLiteral("Rotate right 90°")});
  editor.insert(QStringLiteral("modified"), true);
  setState(editor);

  QQuickItem* left = expectItem("editorHistory");
  QQuickItem* right = expectItem("editorInspector");
  QVERIFY(left->x() < right->x());

  auto inside = [](QQuickItem* container, QQuickItem* item) {
    const QPointF corner = item->mapToScene(QPointF(0, 0));
    const QPointF other = container->mapToScene(QPointF(0, 0));
    return corner.x() >= other.x() - 0.5 && corner.y() >= other.y() - 0.5 &&
           corner.x() + item->width() <= other.x() + container->width() + 0.5;
  };

  for (const char* edit : {"editsRotateLeft", "editsRotateRight", "editsFlipHorizontal",
                          "editsFlipVertical", "undoButton", "redoButton", "resetButton"}) {
    QQuickItem* item = expectItem(edit);
    QVERIFY2(inside(left, item), qPrintable(QStringLiteral("%1 is not in the edits sidebar")
                                                .arg(QString::fromLatin1(edit))));
  }
  for (const char* command :
       {"saveHeading", "saveTarget", "editorSaveButton", "editorSaveAsButton"}) {
    QQuickItem* item = expectItem(command);
    QVERIFY2(inside(right, item), qPrintable(QStringLiteral("%1 is not in the commands sidebar")
                                                 .arg(QString::fromLatin1(command))));
  }
  // Crop and resize interaction stay on the right, next to the save target.
  QVERIFY(inside(right, expectItem("applyResize")));
  QVERIFY(inside(right, expectItem("applyCrop")));
}

/// Save is offered only when there is something to write, and both buttons send
/// the command the user asked for rather than touching the file themselves.
void TestEditor::saveAndSaveAsEmitTheirCommands()
{
  QVariantMap editor = documentState();
  setState(editor);

  QQuickItem* save = expectItem("editorSaveButton");
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
  QQuickItem* saveAs = expectItem("editorSaveAsButton");
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

/// Tooltips name the key that reaches the same command, and only that key: an
/// action without a shortcut (`Undo` has none) must not claim one.
void TestEditor::toolbarTooltipsNameTheirShortcuts()
{
  const QList<QPair<QString, QString>> expected = {
    { QStringLiteral("editorToolbarSave"), QStringLiteral("Save (Ctrl+S)") },
    { QStringLiteral("editorToolbarSaveAs"), QStringLiteral("Save as… (Ctrl+Shift+S)") },
    { QStringLiteral("editorSaveButton"),
      QStringLiteral("Overwrite the file, keeping a .bak copy of the previous one (Ctrl+S)") },
    { QStringLiteral("editorSaveAsButton"),
      QStringLiteral("Write a copy and continue editing it (Ctrl+Shift+S)") },
    { QStringLiteral("editorUndo"), QStringLiteral("Undo") },
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

QTEST_MAIN(TestEditor)
#include "tst_editor.moc"
