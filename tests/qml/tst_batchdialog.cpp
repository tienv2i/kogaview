// Batch regression tests: the Browser's three batch forms and the command each
// one formats.
//
// Every batch action is its own dialog — `BatchResizeDialog`,
// `BatchCropDialog`, `BatchConvertDialog` — and all three are built on
// `BatchJobDialog`, the half that decides which images and where the results
// go. The suite loads the three real files the way `Main.qml` keeps them: three
// instances, parented to a host item, each asking for its own action. Nothing
// here knows about Core, so the suite publishes the same properties `Main.qml`
// does (the selection, the folder, a sample image's shape) and asserts on the
// single `runRequested` command. What Core does with that command — the
// destinations, the proportional crop, the refusals — is pinned in
// `crates/app-core/src/batch.rs` and `core.rs`; what QML must get right is the
// shape of the payload, the three inputs, the two destinations, and the rule
// that a source is never a destination unless the user says so.

#include <QGuiApplication>
#include <QHash>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QSignalSpy>
#include <QTest>

namespace {

constexpr int kHostWidth = 900;
constexpr int kHostHeight = 760;

/// The dialog file each action's form lives in, as `Main.qml` instantiates it.
QString dialogFile(const QString& operation)
{
  if (operation == QLatin1String("crop")) {
    return QStringLiteral("/BatchCropDialog.qml");
  }
  if (operation == QLatin1String("convert")) {
    return QStringLiteral("/BatchConvertDialog.qml");
  }
  return QStringLiteral("/BatchResizeDialog.qml");
}

} // namespace

class TestBatchDialog : public QObject
{
  Q_OBJECT

private:
  QQmlEngine m_engine;
  QQuickView* m_view = nullptr;
  /// One dialog per action, all alive at once, exactly like `Main.qml`.
  QHash<QString, QObject*> m_dialogs;
  /// The dialog the case at hand opened.
  QObject* m_dialog = nullptr;

  QObject* dialogFor(const QString& operation) const
  {
    return m_dialogs.value(operation);
  }

  /// A named control inside the open form. The form is a `Popup`, so its
  /// children are QObjects first and items second.
  QQuickItem* expectItem(const char* name)
  {
    QQuickItem* found = m_dialog->findChild<QQuickItem*>(QString::fromLatin1(name));
    if (found == nullptr) {
      for (QObject* object : m_dialog->findChildren<QObject*>()) {
        if (object->objectName() == QString::fromLatin1(name)) {
          found = qobject_cast<QQuickItem*>(object);
          break;
        }
      }
    }
    return found;
  }

  /// Open the form for `operation` with the properties `Main.qml` hands it.
  void open(const QString& operation, const QStringList& selection,
            const QString& folder = QStringLiteral("/pics"),
            int sampleWidth = 1200, int sampleHeight = 800)
  {
    m_dialog = dialogFor(operation);
    QVERIFY2(m_dialog != nullptr, qPrintable(operation));
    m_dialog->setProperty("selectionPaths", selection);
    m_dialog->setProperty("currentFolder", folder);
    m_dialog->setProperty("sampleWidth", sampleWidth);
    m_dialog->setProperty("sampleHeight", sampleHeight);
    QVERIFY(QMetaObject::invokeMethod(m_dialog, "open"));
    QTRY_VERIFY(m_dialog->property("visible").toBool());
    // `open()` sets Visible and `onAboutToShow` seeds the fields a beat later;
    // a case that reads a field must see the seeded form, not the last job's.
    const QString where = selection.isEmpty()
                            ? (folder.isEmpty() ? QStringLiteral("otherFolder")
                                                : QStringLiteral("currentFolder"))
                            : QStringLiteral("selection");
    QTRY_COMPARE(m_dialog->property("inputKind").toString(), where);
  }

  void close()
  {
    QVERIFY(QMetaObject::invokeMethod(m_dialog, "close"));
    QTRY_VERIFY(!m_dialog->property("visible").toBool());
  }

  /// The refusal the form would show, or "". A QML method is not a property,
  /// so `property("validationError")` reads nothing; invoke it.
  QString validationError() const
  {
    // A QML method returns a QVariant, so the Q_RETURN_ARG must be one too.
    QVariant message;
    if (!QMetaObject::invokeMethod(m_dialog, "validationError",
                                   Q_RETURN_ARG(QVariant, message))) {
      return QStringLiteral("<no validationError>");
    }
    return message.toString();
  }

  /// A real click at the centre of an item, the way the editor suite drives its
  /// buttons: the user's path, not `toggle()` or `setProperty`.
  void clickItem(QQuickItem* item)
  {
    QVERIFY(item != nullptr);
    const QPointF centre = item->mapToScene(QPointF(item->width() / 2, item->height() / 2));
    QTest::mouseClick(m_view, Qt::LeftButton, Qt::NoModifier, centre.toPoint());
  }

private slots:
  void initTestCase()
  {
    QQuickView* host = new QQuickView(&m_engine, nullptr);
    host->setResizeMode(QQuickView::SizeRootObjectToView);
    host->resize(kHostWidth, kHostHeight);
    host->setSource(QUrl::fromLocalFile(
      QStringLiteral(KOGAVIEW_QML_TEST_SOURCE_DIR) + QStringLiteral("/batchhost.qml")));
    QVERIFY2(host->status() == QQuickView::Ready,
             qPrintable(host->errors().isEmpty() ? QString()
                                                 : host->errors().first().toString()));
    host->show();
    QVERIFY(QTest::qWaitForWindowExposed(host));
    m_view = host;

    // The three real forms, loaded the way `Main.qml` instantiates them: one
    // dialog per action, each parented to the host so it has a visual parent
    // with a real size.
    for (const char* operation : { "resize", "crop", "convert" }) {
      QQmlComponent component(
        &m_engine,
        QUrl::fromLocalFile(QStringLiteral(KOGAVIEW_QML_SOURCE_DIR)
                            + dialogFile(QString::fromLatin1(operation))));
      QVERIFY2(component.isReady(), qPrintable(component.errorString()));
      // A Popup is a QObject, not a QQuickItem: give it the host as its parent
      // item and drive it through its meta-object, the way `Main.qml` names it.
      QObject* popup = component.create();
      QVERIFY2(popup != nullptr, qPrintable(component.errorString()));
      if (QQuickItem* item = qobject_cast<QQuickItem*>(popup)) {
        item->setParentItem(m_view->rootObject());
      } else {
        popup->setProperty("parent", QVariant::fromValue<QObject*>(m_view->rootObject()));
      }
      popup->setObjectName(QStringLiteral("batch%1Dialog")
                             .arg(QString::fromLatin1(operation).replace(0, 1,
                                 QString::fromLatin1(operation).at(0).toUpper())));
      m_dialogs.insert(QString::fromLatin1(operation), popup);
    }
  }

  void init()
  {
    for (QObject* dialog : std::as_const(m_dialogs)) {
      if (dialog->property("visible").toBool()) {
        QMetaObject::invokeMethod(dialog, "close");
        QTRY_VERIFY(!dialog->property("visible").toBool());
      }
    }
    m_dialog = nullptr;
  }

  void cleanupTestCase() { delete m_view; }

  /// The three actions are three dialogs, each with its own title, and each
  /// drawing only the options it asks for. One form with a mode strip made a
  /// half-filled resize become a crop without saying so; a dialog per action
  /// cannot.
  void eachActionIsItsOwnDialogWithItsOwnTitle()
  {
    QCOMPARE(dialogFor(QStringLiteral("resize"))->property("title").toString(),
             QStringLiteral("Batch resize"));
    QCOMPARE(dialogFor(QStringLiteral("crop"))->property("title").toString(),
             QStringLiteral("Batch crop"));
    QCOMPARE(dialogFor(QStringLiteral("convert"))->property("title").toString(),
             QStringLiteral("Batch convert"));
    for (const char* operation : { "resize", "crop", "convert" }) {
      QCOMPARE(dialogFor(QString::fromLatin1(operation))->property("operation").toString(),
               QString::fromLatin1(operation));
    }

    // Only the options of the action that was asked for are drawn.
    open(QStringLiteral("resize"), { QStringLiteral("/pics/a.png") });
    QVERIFY(expectItem("batchResizeWidth")->property("visible").toBool());
    QVERIFY(!expectItem("batchCropX")->property("visible").toBool());
    QVERIFY(!expectItem("batchConvertFormat")->property("visible").toBool());
    close();

    open(QStringLiteral("crop"), { QStringLiteral("/pics/a.png") });
    QVERIFY(expectItem("batchCropWidth")->property("visible").toBool());
    QVERIFY(expectItem("batchCropAnchorGrid")->property("visible").toBool());
    QVERIFY(!expectItem("batchResizeWidth")->property("visible").toBool());
    close();

    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.png") });
    QVERIFY(expectItem("batchConvertFormat")->property("visible").toBool());
    QVERIFY(!expectItem("batchResizeWidth")->property("visible").toBool());
  }

  /// A resize sends one `batch_run`: the size, the fit and the filter, with a
  /// suffixed copy beside each source by default.
  void aResizeSendsOneBatchRun()
  {
    open(QStringLiteral("resize"),
         { QStringLiteral("/pics/a.png"), QStringLiteral("/pics/b.png") });
    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));

    QQuickItem* width = expectItem("batchResizeWidth");
    QVERIFY(width != nullptr);
    QQuickItem* input = width->property("inputField").value<QQuickItem*>();
    QVERIFY(input != nullptr);
    input->setProperty("text", QStringLiteral("640"));
    QQuickItem* height = expectItem("batchResizeHeight");
    height->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("480"));

    QQuickItem* runButton = expectItem("batchDialogRun");
    QVERIFY(runButton != nullptr);
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));
    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);

    const QVariantMap command = spy.at(0).at(0).toMap();
    QCOMPARE(command.value(QStringLiteral("type")).toString(), QStringLiteral("batch_run"));
    const QVariantMap operation = command.value(QStringLiteral("operation")).toMap();
    QCOMPARE(operation.value(QStringLiteral("operation")).toString(), QStringLiteral("resize"));
    QCOMPARE(operation.value(QStringLiteral("width")).toInt(), 640);
    QCOMPARE(operation.value(QStringLiteral("height")).toInt(), 480);
    QCOMPARE(operation.value(QStringLiteral("mode")).toString(), QStringLiteral("stretch"));
    QCOMPARE(operation.value(QStringLiteral("filter")).toString(), QStringLiteral("auto"));

    const QVariantMap source = command.value(QStringLiteral("source")).toMap();
    QCOMPARE(source.value(QStringLiteral("source")).toString(), QStringLiteral("selection"));
    QCOMPARE(source.value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/pics/a.png"), QStringLiteral("/pics/b.png") }));

    const QVariantMap output = command.value(QStringLiteral("output")).toMap();
    QVERIFY(output.value(QStringLiteral("folder")).isNull());
    QCOMPARE(output.value(QStringLiteral("suffix")).toString(), QStringLiteral("_resized"));
    QCOMPARE(output.value(QStringLiteral("overwrite")).toBool(), false);

    // Run closes the form; the Batch page draws Core's progress.
    QTRY_VERIFY(!m_dialog->property("visible").toBool());
  }

  /// Crop sends percentages of each image's own sides — not pixels of the
  /// sample — because that is the only rectangle one job can describe.
  void aCropSendsPercentages()
  {
    open(QStringLiteral("crop"),
         { QStringLiteral("/pics/a.png"), QStringLiteral("/pics/b.png") });
    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));

    // The whole image is a no-op and Run is off until it trims something.
    QQuickItem* runButton = expectItem("batchDialogRun");
    QVERIFY(!runButton->isEnabled());

    expectItem("batchCropX")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("10"));
    expectItem("batchCropY")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("5"));
    expectItem("batchCropWidth")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("80"));
    expectItem("batchCropHeight")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("90"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));

    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap operation = spy.at(0).at(0).toMap()
                                    .value(QStringLiteral("operation")).toMap();
    QCOMPARE(operation.value(QStringLiteral("operation")).toString(), QStringLiteral("crop"));
    QCOMPARE(operation.value(QStringLiteral("x")).toDouble(), 10.0);
    QCOMPARE(operation.value(QStringLiteral("y")).toDouble(), 5.0);
    QCOMPARE(operation.value(QStringLiteral("width")).toDouble(), 80.0);
    QCOMPARE(operation.value(QStringLiteral("height")).toDouble(), 90.0);
  }

  /// Batch crop also supports 9-point anchor placement, pixel units, and
  /// optional aspect ratios (`1:1`, `16:9`, etc.).
  void aCropSupportsAnchorPixelsAndRatio()
  {
    open(QStringLiteral("crop"), { QStringLiteral("/pics/a.png") });
    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));
    QQuickItem* runButton = expectItem("batchDialogRun");

    // Typing a ratio like "1:1" makes the default 100%x100% centered crop valid.
    expectItem("batchCropRatio")->setProperty("text", QStringLiteral("1:1"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));
    QQuickItem* topRight = nullptr;
    for (QQuickItem* child : expectItem("batchCropAnchorGrid")->childItems()) {
      if (child->objectName() == QStringLiteral("batchCropAnchor_top_right")) {
        topRight = child;
        break;
      }
    }
    clickItem(topRight);
    QVERIFY(QMetaObject::invokeMethod(expectItem("batchCropUnitPixels"), "click"));
    expectItem("batchCropWidth")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("800"));
    expectItem("batchCropHeight")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("0"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));

    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap op = spy.at(0).at(0).toMap()
                             .value(QStringLiteral("operation")).toMap();
    QCOMPARE(op.value(QStringLiteral("operation")).toString(), QStringLiteral("crop"));
    QCOMPARE(op.value(QStringLiteral("unit")).toString(), QStringLiteral("pixels"));
    QCOMPARE(op.value(QStringLiteral("anchor")).toString(), QStringLiteral("top_right"));
    QCOMPARE(op.value(QStringLiteral("ratio")).toDouble(), 1.0);
    QCOMPARE(op.value(QStringLiteral("width")).toDouble(), 800.0);
    QCOMPARE(op.value(QStringLiteral("height")).toDouble(), 0.0);
  }

  /// Convert names the format; a JPEG carries its quality and a lossless one
  /// carries none. The suffix stays empty because the extension changes.
  void aConvertNamesTheFormat()
  {
    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.png") },
         QStringLiteral("/pics"), 1200, 800);
    QCOMPARE(expectItem("batchOutputSuffix")->property("text").toString(), QString());

    // `png` is the default and the sample is already one: writing beside the
    // source would be the source, so Run is off and says why.
    QQuickItem* runButton = expectItem("batchDialogRun");
    QVERIFY(!runButton->isEnabled());
    QVERIFY2(validationError().contains(QStringLiteral("already")),
             qPrintable(validationError()));

    QVERIFY(QMetaObject::invokeMethod(expectItem("batchConvertFormat"), "activated",
                                     Q_ARG(int, 1)));
    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));
    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap operation = spy.at(0).at(0).toMap()
                                    .value(QStringLiteral("operation")).toMap();
    QCOMPARE(operation.value(QStringLiteral("format")).toString(), QStringLiteral("jpeg"));
    QCOMPARE(operation.value(QStringLiteral("quality")).toInt(), 90);

    close();
    // A lossless encoder has no quality to name.
    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.png") });
    spy.clear();
    QVERIFY(QMetaObject::invokeMethod(expectItem("batchConvertFormat"), "activated",
                                     Q_ARG(int, 2)));
    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap webp = spy.at(0).at(0).toMap()
                               .value(QStringLiteral("operation")).toMap();
    QCOMPARE(webp.value(QStringLiteral("format")).toString(), QStringLiteral("webp"));
    QVERIFY(webp.value(QStringLiteral("quality")).isNull());
  }

  /// A convert that would write over its own source is refused by the form,
  /// with the file named — including the extensions the encoder writes but does
  /// not spell: `jpeg` writes `.jpg`, so a `.jpg` source is the same rule as a
  /// `.png` one and must not reach Core as a surprise refusal.
  void aConvertRefusesItsOwnExtension()
  {
    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.jpg"),
                                      QStringLiteral("/pics/b.PNG") });
    QVERIFY(QMetaObject::invokeMethod(expectItem("batchConvertFormat"), "activated",
                                     Q_ARG(int, 1)));
    QVERIFY2(!expectItem("batchDialogRun")->isEnabled(), "a .jpg source is its own output");
    QVERIFY2(validationError().contains(QStringLiteral("a.jpg"))
               && validationError().contains(QStringLiteral(".jpg")),
             qPrintable(validationError()));

    // The png copy is refused too, and the extension is compared whole: a name
    // that merely ends in the letters is not already that format.
    close();
    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.png") });
    QVERIFY(!expectItem("batchDialogRun")->isEnabled());
    close();
    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.pngx") });
    QVERIFY2(expectItem("batchDialogRun")->isEnabled(), qPrintable(validationError()));
  }

  /// The form opens on the selection when it has images, and on the open folder
  /// when it does not: it says which instead of sending nothing.
  void theInputOpensOnTheSelectionOrTheOpenFolder()
  {
    open(QStringLiteral("resize"), {}, QStringLiteral("/pics"));
    QCOMPARE(m_dialog->property("inputKind").toString(), QStringLiteral("currentFolder"));
    QVERIFY(expectItem("batchInputSelection")->property("enabled").toBool() == false);
    QVERIFY(expectItem("batchInputFolder")->property("enabled").toBool() == true);

    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));
    QVERIFY(QMetaObject::invokeMethod(expectItem("batchDialogRun"), "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap source = spy.at(0).at(0).toMap()
                                 .value(QStringLiteral("source")).toMap();
    QCOMPARE(source.value(QStringLiteral("source")).toString(), QStringLiteral("folder"));
    QCOMPARE(source.value(QStringLiteral("path")).toString(), QStringLiteral("/pics"));
  }

  /// The third input is a folder picked in the form, and it is the same folder
  /// command Core already reads — one folder either way.
  void anotherFolderIsAnInputToo()
  {
    open(QStringLiteral("resize"), { QStringLiteral("/pics/a.png") });
    QQuickItem* runButton = expectItem("batchDialogRun");
    QVERIFY(runButton->isEnabled());

    // Choosing the third answer with no folder yet is not a job: the form says
    // what is missing instead of sending a folder-less command.
    QVERIFY(QMetaObject::invokeMethod(expectItem("batchInputOtherFolder"), "click"));
    QCOMPARE(m_dialog->property("inputKind").toString(), QStringLiteral("otherFolder"));
    QVERIFY2(!runButton->isEnabled(), qPrintable(validationError()));
    QCOMPARE(validationError(), QStringLiteral("Choose the folder to process."));

    // The chooser's answer lands on the same property the radio reads.
    m_dialog->setProperty("inputFolder", QStringLiteral("/elsewhere"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));
    QCOMPARE(expectItem("batchInputFolderPath")->property("text").toString(),
             QStringLiteral("/elsewhere"));

    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));
    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap source = spy.at(0).at(0).toMap()
                                 .value(QStringLiteral("source")).toMap();
    QCOMPARE(source.value(QStringLiteral("source")).toString(), QStringLiteral("folder"));
    QCOMPARE(source.value(QStringLiteral("path")).toString(), QStringLiteral("/elsewhere"));
  }

  /// Another folder is the second destination, and replacing the originals is
  /// the only way a job may write over its input. The first destination names
  /// the folder the images actually come from.
  void anotherFolderAndOverwriteAreSeparateAnswers()
  {
    open(QStringLiteral("crop"), { QStringLiteral("/pics/a.png") });
    QQuickItem* runButton = expectItem("batchDialogRun");
    expectItem("batchCropWidth")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("50"));
    QVERIFY(runButton->isEnabled());

    // The images' own folder is named, not guessed at.
    QVERIFY2(expectItem("batchOutputBeside")->property("text").toString()
               .contains(QStringLiteral("pics")),
             qPrintable(expectItem("batchOutputBeside")->property("text").toString()));

    // Beside the source an empty suffix is the source itself, so the form
    // refuses it — that is the rule that keeps a job from eating its inputs.
    expectItem("batchOutputSuffix")->setProperty("text", QString());
    QVERIFY2(!runButton->isEnabled(), qPrintable(validationError()));
    QVERIFY(validationError().contains(QStringLiteral("replace it")));

    // Another folder is a different destination, so the same empty suffix is
    // fine there: `/out/a.png` is not `/pics/a.png`.
    QVERIFY(QMetaObject::invokeMethod(expectItem("batchOutputFolder"), "click"));
    QCOMPARE(m_dialog->property("outputKind").toString(), QStringLiteral("folder"));
    m_dialog->setProperty("outputFolder", QStringLiteral("/out"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));

    QSignalSpy spy(m_dialog, SIGNAL(runRequested(QVariant)));
    expectItem("batchOutputSuffix")->setProperty("text", QStringLiteral("_half"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));
    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap output = spy.at(0).at(0).toMap()
                                 .value(QStringLiteral("output")).toMap();
    QCOMPARE(output.value(QStringLiteral("folder")).toString(), QStringLiteral("/out"));
    QCOMPARE(output.value(QStringLiteral("suffix")).toString(), QStringLiteral("_half"));
    QCOMPARE(output.value(QStringLiteral("overwrite")).toBool(), false);

    // Replacing the originals: no folder, no suffix — the flag is the whole
    // answer, and the two destination radios are off.
    close();
    open(QStringLiteral("crop"), { QStringLiteral("/pics/a.png") });
    spy.clear();
    expectItem("batchCropWidth")->property("inputField").value<QQuickItem*>()
      ->setProperty("text", QStringLiteral("50"));
    QVERIFY2(runButton->isEnabled(), qPrintable(validationError()));
    clickItem(expectItem("batchOverwrite"));
    QCOMPARE(m_dialog->property("overwrite").toBool(), true);
    QVERIFY(!expectItem("batchOutputBeside")->property("enabled").toBool());
    QVERIFY(!expectItem("batchOutputFolder")->property("enabled").toBool());
    QVERIFY(QMetaObject::invokeMethod(runButton, "click"));
    QCOMPARE(spy.count(), 1);
    const QVariantMap overwrite = spy.at(0).at(0).toMap()
                                    .value(QStringLiteral("output")).toMap();
    QVERIFY(overwrite.value(QStringLiteral("folder")).isNull());
    QCOMPARE(overwrite.value(QStringLiteral("suffix")).toString(), QString());
    QCOMPARE(overwrite.value(QStringLiteral("overwrite")).toBool(), true);
  }

  /// "Constrain proportions" is the editor's lock: typing a width retypes the
  /// height, and unchecking it lets the two drift apart.
  void theConstraintLockFollowsTheEditor()
  {
    open(QStringLiteral("resize"), { QStringLiteral("/pics/a.png") }, QStringLiteral("/pics"),
         1200, 800);
    QQuickItem* width = expectItem("batchResizeWidth")->property("inputField").value<QQuickItem*>();
    QQuickItem* height = expectItem("batchResizeHeight")->property("inputField").value<QQuickItem*>();
    // The sample is 1200x800, so the form opens on its shape.
    QCOMPARE(width->property("text").toString(), QStringLiteral("1200"));
    QCOMPARE(height->property("text").toString(), QStringLiteral("800"));

    QQuickItem* lock = expectItem("batchResizeConstraint");
    QVERIFY(lock->property("checked").toBool());
    width->setProperty("text", QStringLiteral("600"));
    QVERIFY(QMetaObject::invokeMethod(width, "textEdited"));
    QCOMPARE(height->property("text").toString(), QStringLiteral("400"));

    clickItem(lock);
    QTRY_COMPARE(m_dialog->property("constraint").toBool(), false);
    width->setProperty("text", QStringLiteral("300"));
    QVERIFY(QMetaObject::invokeMethod(width, "textEdited"));
    QCOMPARE(height->property("text").toString(), QStringLiteral("400"));
  }

  /// Each action's form starts on its own suffix: a copy of a resize is
  /// `_resized`, a copy of a crop is `_cropped`, and a convert needs none
  /// because the extension is what keeps the copy from being the source.
  void eachActionStartsOnItsOwnSuffix()
  {
    open(QStringLiteral("resize"), { QStringLiteral("/pics/a.png") });
    QCOMPARE(expectItem("batchOutputSuffix")->property("text").toString(),
             QStringLiteral("_resized"));
    close();

    open(QStringLiteral("crop"), { QStringLiteral("/pics/a.png") });
    QCOMPARE(expectItem("batchOutputSuffix")->property("text").toString(),
             QStringLiteral("_cropped"));
    close();

    open(QStringLiteral("convert"), { QStringLiteral("/pics/a.png") });
    QCOMPARE(expectItem("batchOutputSuffix")->property("text").toString(), QString());
  }

  /// Every choice in the form is readable on the dark form.
  ///
  /// A control inside a `Popup` resolves the *platform* palette, not the
  /// window's: on the real window the stock radio and checkbox labels drew
  /// `#26292e` text on `#181b21`, a list nobody can read (the same finding the
  /// Settings rows and the resize dialog's switches fixed). The words are drawn
  /// here, so the colour is the theme's and can be asserted without a grab.
  void everyChoiceIsDrawnInTheThemeColour()
  {
    open(QStringLiteral("resize"), { QStringLiteral("/pics/a.png") });
    QObject* theme = m_dialog->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    const QColor ink = theme->property("text").value<QColor>();
    const QColor muted = theme->property("textMuted").value<QColor>();
    QVERIFY(ink.isValid() && muted.isValid());

    for (const char* name : { "batchInputSelection", "batchInputFolder",
                              "batchInputOtherFolder", "batchOutputBeside",
                              "batchOutputFolder", "batchOverwrite" }) {
      QQuickItem* control = expectItem(name);
      QVERIFY2(control != nullptr, name);
      QQuickItem* label = control->property("contentItem").value<QQuickItem*>();
      QVERIFY2(label != nullptr, qPrintable(QStringLiteral("%1 draws the style's own label")
                                              .arg(QString::fromLatin1(name))));
      // The chosen (or unusable) row says which; both colours are the theme's.
      const QColor drawn = label->property("color").value<QColor>();
      const bool enabled = control->property("enabled").toBool();
      QCOMPARE(drawn, enabled ? ink : muted);
      QVERIFY2(drawn != QColor(QStringLiteral("#26292e")),
               "the platform palette's near-black text is back");
    }
  }

  /// The form's own buttons are theme-drawn too.
  ///
  /// A stock `Button` inside this window painted a white slab with near-black
  /// text on the dark form. Cancel and Run — the two the user presses — are
  /// `PanelAction`s, and Run is the accent, so the answer is the only bright
  /// thing in the footer.
  void theFormButtonsAreDrawnInTheTheme()
  {
    open(QStringLiteral("resize"), { QStringLiteral("/pics/a.png") });
    QQuickItem* run = expectItem("batchDialogRun");
    QQuickItem* cancel = expectItem("batchDialogCancel");
    QVERIFY(run != nullptr && cancel != nullptr);
    QVERIFY2(!run->inherits("QQuickButton"),
             "Run is a stock Button, whose fill ignores the theme");
    QVERIFY(run->property("primary").toBool());
    QVERIFY(!cancel->property("primary").toBool());
  }
};

QTEST_MAIN(TestBatchDialog)
#include "tst_batchdialog.moc"
