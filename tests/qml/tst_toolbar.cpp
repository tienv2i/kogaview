// Toolbar regression tests: the measured widths the window floor is built from,
// the label that appears only when the button has room for it, and the counts
// `ToolbarMetrics` keeps in step with the real workspace toolbars.
//
// These load the real `ToolbarMetrics.qml`, `CompactToolbarButton.qml` and
// `WorkspaceSwitcher.qml` from `crates/desktop/qml/`, so a change to any of the
// arithmetic is measured by Qt Quick itself rather than by a copy of the rule
// in the test. The real window (fonts, icon theme, title bar) still has the last
// word; see the report row.

#include <QGuiApplication>
#include <QQuickItem>
#include <QQuickView>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QTest>
#include <QVariant>

#include "language.h"

namespace {
QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}
} // namespace

/// A QML component from `crates/desktop/qml/` in a real window, so a
/// `RowLayout` really lays its children out instead of leaving them at width 0.
///
/// The fixture has to live in the application's QML directory: that is where
/// its local types (`ToolbarMetrics`, `WorkspaceSwitcher`) resolve as siblings,
/// and where Qt accepts the file name as a type name. Test-only fixtures are
/// therefore either tracked there or written there for one test and removed
/// again; `crates/desktop/build.rs` lists the files the shipped module packages,
/// so neither reaches the application.
class QmlViewFixture
{
public:
  QmlViewFixture(QQmlEngine* engine, const QString& file, const QSize& size)
    : m_view(engine, nullptr)
  {
    m_view.setResizeMode(QQuickView::SizeRootObjectToView);
    m_view.resize(size);
    m_view.setSource(QUrl::fromLocalFile(qmlDir() + QLatin1Char('/') + file));
    if (m_view.status() != QQuickView::Ready) {
      m_error = m_view.errors().isEmpty() ? QStringLiteral("the fixture did not load")
                                          : m_view.errors().first().toString();
      return;
    }
    m_view.show();
    QTest::qWaitForWindowExposed(&m_view);
  }

  QQuickItem* item(const QString& name) const
  {
    return m_view.rootObject() ? m_view.rootObject()->findChild<QQuickItem*>(name) : nullptr;
  }

  QQuickItem* root() const { return m_view.rootObject(); }

  QString error() const { return m_error; }

private:
  Q_DISABLE_COPY(QmlViewFixture)
  QQuickView m_view;
  QString m_error;
};

class TestToolbar : public QObject
{
  Q_OBJECT

private:
  QQmlEngine m_engine;
  QObject* m_metrics = nullptr;
  /// A plain `Item` the single components are parented to. Components that
  /// are not windows need a parent that is an `Item` for `anchors` to resolve.
  QQuickItem* m_host = nullptr;

  /// Create one component from the app's QML directory, parented to `parent`.
  QObject* create(const QString& file, QObject* parent)
  {
    QQmlComponent component(&m_engine, QUrl::fromLocalFile(qmlDir() + QLatin1Char('/') + file));
    if (!component.isReady()) {
      qWarning("cannot load %s: %s", qPrintable(file), qPrintable(component.errorString()));
      return nullptr;
    }
    QObject* created = component.create();
    if (created != nullptr) {
      created->setParent(parent);
    }
    return created;
  }

  /// The two tracked test components, by file name. They live beside the
  /// views because Qt resolves local types as siblings and needs the file name
  /// to be a type name, and they are kept out of the shipped module
  /// (`crates/desktop/build.rs` lists the files it packages).
  static QString switcherFixture() { return QStringLiteral("tst_ToolbarFixture.qml"); }
  static QString headerRowFixture() { return QStringLiteral("tst_ToolbarRow.qml"); }

  static qreal real(QObject* object, const char* name)
  {
    return object->property(name).toReal();
  }

private slots:
  void initTestCase()
  {
    QQmlComponent hostComponent(&m_engine);
    hostComponent.setData("import QtQuick\nItem { width: 800; height: 600 }", QUrl());
    m_host = qobject_cast<QQuickItem*>(hostComponent.create());
    QVERIFY2(m_host != nullptr, qPrintable(hostComponent.errorString()));

    m_metrics = create(QStringLiteral("ToolbarMetrics.qml"), nullptr);
    QVERIFY2(m_metrics != nullptr, "cannot load ToolbarMetrics.qml");
  }

  /// The floor is the mini toolbar, and the two fold points sit above it: at
  /// the floor the row shows every workspace's primary buttons plus one
  /// overflow menu, above `compactToolbarWidth` it can draw every icon, and
  /// past the threshold it can afford every label.
  void theFloorIsTheMiniToolbar()
  {
    const qreal mini = real(m_metrics, "miniToolbarWidth");
    const qreal compact = real(m_metrics, "compactToolbarWidth");
    const qreal labelled = real(m_metrics, "labelledToolbarWidth");
    const qreal floor = real(m_metrics, "minimumWindowWidth");
    const qreal threshold = real(m_metrics, "labelThreshold");

    QVERIFY2(mini > 0, "the mini toolbar has no width");
    QVERIFY2(compact > mini,
             qPrintable(QStringLiteral("folding the buttons saves nothing: mini %1, compact %2")
                          .arg(mini)
                          .arg(compact)));
    QVERIFY2(labelled > compact,
             qPrintable(QStringLiteral("labels add nothing: compact %1, labelled %2")
                          .arg(compact)
                          .arg(labelled)));
    // Dropping the labels must actually buy room, or there would be no point
    // in a threshold at all.
    QVERIFY2(threshold >= labelled,
             qPrintable(QStringLiteral("labels are allowed at %1 but need %2")
                          .arg(threshold)
                          .arg(labelled)));
    QVERIFY2(floor >= mini,
             qPrintable(QStringLiteral("no window may be narrower than the mini toolbar (%1 vs %2)")
                          .arg(floor)
                          .arg(mini)));
    // The floor is no longer the full icon row: the overflow menu is what makes
    // a narrower window possible.
    QVERIFY2(floor < compact,
             qPrintable(QStringLiteral("the floor %1 is not below the compact row %2, so the "
                                       "overflow menu would never be used")
                          .arg(floor)
                          .arg(compact)));
    QVERIFY2(floor < threshold,
             qPrintable(QStringLiteral("the floor %1 is not below the label threshold %2, so "
                                       "labels would never be dropped")
                          .arg(floor)
                          .arg(threshold)));
    // A floor that is not a usable desktop window width is a bug either way.
    QVERIFY2(floor > 400 && floor < 1200,
             qPrintable(QStringLiteral("the window floor is %1").arg(floor)));

    // Each workspace folds into a narrower row, and each has its own label
    // point above its icon row. The floor may sit above the Browser's icon row
    // (the side panels decide 580), which is why the Browser simply never needs
    // its overflow menu — the row fits.
    const QStringList workspaces = { QStringLiteral("browser"),
                                     QStringLiteral("viewer"),
                                     QStringLiteral("editor") };
    for (const QString& workspace : workspaces) {
      const qreal miniRow = real(m_metrics, qPrintable(workspace + QStringLiteral("MiniRowWidth")));
      const qreal compactRow = real(m_metrics, qPrintable(workspace + QStringLiteral("CompactRowWidth")));
      QVERIFY2(compactRow > miniRow,
               qPrintable(QStringLiteral("%1: folding saves nothing (%2 vs %3)")
                            .arg(workspace)
                            .arg(miniRow)
                            .arg(compactRow)));
    }
  }

  /// One workspace's row in each mode. The fold and label points are per
  /// workspace now, so the fixture is measured three times with its workspace
  /// slot at that view's width — a global "widest workspace" number would hide
  /// the Browser being folded at the Editor's width, which is the defect this
  /// change fixes.
  void theWidthsMatchTheRealHeaderRow_data()
  {
    QTest::addColumn<QString>("workspace");
    QTest::addColumn<bool>("mini");
    QTest::addColumn<QString>("measured");
    QTest::newRow("browser-compact")
      << QStringLiteral("browser") << false << "browserCompactRowWidth";
    QTest::newRow("viewer-compact")
      << QStringLiteral("viewer") << false << "viewerCompactRowWidth";
    QTest::newRow("editor-compact")
      << QStringLiteral("editor") << false << "editorCompactRowWidth";
    QTest::newRow("browser-mini")
      << QStringLiteral("browser") << true << "browserMiniRowWidth";
    QTest::newRow("viewer-mini")
      << QStringLiteral("viewer") << true << "viewerMiniRowWidth";
    QTest::newRow("editor-mini")
      << QStringLiteral("editor") << true << "editorMiniRowWidth";
  }

  void theWidthsMatchTheRealHeaderRow()
  {
    QFETCH(QString, workspace);
    QFETCH(bool, mini);
    QFETCH(QString, measured);

    // The header row reproduced with the metrics' own numbers: same children,
    // spacing and side margins.
    QmlViewFixture fixture(&m_engine, headerRowFixture(), QSize(2000, 60));
    QVERIFY2(fixture.root() != nullptr, qPrintable(fixture.error()));
    QQuickItem* row = fixture.root();
    QVERIFY2(row != nullptr, "the fixture has no row layout");
    row->setProperty("workspace", workspace);
    row->setProperty("mini", mini);
    QCoreApplication::processEvents();

    QObject* metrics = fixture.root()->property("metrics").value<QObject*>();
    QVERIFY(metrics != nullptr);
    // Sum the children's own intrinsic widths and add the gaps the metrics
    // account for: that is exactly the arithmetic `compactToolbarWidth` does,
    // so a child, a gap or a margin missing from the metrics shows up as a
    // difference. `implicitWidth` on the layout itself would apply its own
    // rounding and hide a pixel or two of drift.
    int children = 0;
    qreal controls = 0;
    for (QQuickItem* child : row->childItems()) {
      // `RowLayout` keeps one invisible item of its own between the children;
      // it has no width of its own and must not be counted as a control.
      if (child->implicitWidth() == 0 && child->implicitHeight() == 0) {
        continue;
      }
      controls += child->implicitWidth();
      ++children;
    }
    QCOMPARE(children, 6);

    // The gaps come from what the fixture declares for itself — its own
    // spacing, read from the layout, and the header's side margins, which QML
    // cannot expose on the root item and are therefore fixed here. Reading
    // `rowGaps` on both sides would cancel a mistake in it, which is exactly
    // the mistake this test exists to catch: a missing term once made the
    // arithmetic 84 px short of the live row.
    const qreal sideMargins = 2 * 8;
    const qreal gaps = row->property("spacing").toReal() * (children - 1) + sideMargins;
    const qreal live = controls + gaps;
    const qreal expected = real(metrics, measured.toLatin1().constData());
    QVERIFY2(live > 0, "the header row has no implicit width");
    // The elastic spacer contributes 0, the rest are the metrics' own numbers:
    // a mismatch means a child, a gap or a margin is missing from the
    // arithmetic, and a window at the floor would squeeze a control.
    QVERIFY2(qAbs(live - expected) < 2.0,
             qPrintable(QStringLiteral("the header row needs %1 px (%2 controls + %3 gaps) "
                                       "but %4 is %5")
                          .arg(live)
                          .arg(controls)
                          .arg(gaps)
                          .arg(measured)
                          .arg(expected)));

    // The floor has to fit every workspace's mini row: at the narrowest window,
    // every control that row keeps is still at its intrinsic width. The compact
    // rows are deliberately allowed to be wider than the floor — that is what
    // the overflow menu is for — but the widest one is the compact ceiling.
    if (mini) {
      QVERIFY2(real(metrics, "minimumWindowWidth") >= live,
               qPrintable(QStringLiteral("the window floor is below the %1 mini row (%2 < %3)")
                            .arg(workspace)
                            .arg(real(metrics, "minimumWindowWidth"))
                            .arg(live)));
    } else {
      QVERIFY2(real(metrics, "compactToolbarWidth") >= live,
               qPrintable(QStringLiteral("compactToolbarWidth is below the %1 compact row "
                                         "(%2 < %3)")
                            .arg(workspace)
                            .arg(real(metrics, "compactToolbarWidth"))
                            .arg(live)));
    }
  }

  /// The tier is chosen for the workspace on screen, not for the widest one.
  ///
  /// Before this, `toolbarMini` compared the window against the Editor's
  /// thirteen-button row whatever view was open, so the Browser — six buttons,
  /// a row about 440 px wide — was folded into the overflow menu at any width
  /// under ~780 px while three hundred pixels sat unused. Two windows of the
  /// same width now get two answers, because each workspace has its own fold
  /// and label point and the switcher's three buttons are counted in both.
  void theTierFollowsTheOpenWorkspace()
  {
    const auto number = [this](const QString& name) {
      return m_metrics->property(name.toLatin1().constData()).toReal();
    };
    const auto mode = [this](const QString& workspace, qreal width) {
      QVariant result;
      const bool ok = QMetaObject::invokeMethod(
        m_metrics, "modeFor", Q_RETURN_ARG(QVariant, result),
        Q_ARG(QVariant, workspace), Q_ARG(QVariant, width));
      if (!ok) {
        qWarning() << "ToolbarMetrics.modeFor" << workspace << width << "is not invokable";
      }
      return result.toString();
    };

    const QStringList workspaces = { QStringLiteral("browser"),
                                     QStringLiteral("viewer"),
                                     QStringLiteral("editor") };
    for (const QString& workspace : workspaces) {
      const qreal compact = number(workspace + QStringLiteral("CompactRowWidth"));
      const qreal labelled = number(workspace + QStringLiteral("LabelThreshold"));
      QVERIFY2(compact > 0, qPrintable(workspace + QStringLiteral(" has no compact width")));
      QVERIFY2(labelled > compact,
               qPrintable(QStringLiteral("%1: labels are allowed at %2 but the icon row needs %3")
                            .arg(workspace)
                            .arg(labelled)
                            .arg(compact)));
      // All three modes are reachable, at that workspace's own points.
      QCOMPARE(mode(workspace, labelled), QStringLiteral("full"));
      QCOMPARE(mode(workspace, labelled - 1), QStringLiteral("compact"));
      QCOMPARE(mode(workspace, compact), QStringLiteral("compact"));
      QCOMPARE(mode(workspace, compact - 1), QStringLiteral("mini"));
    }

    // The same window width, two workspaces, two answers. The Browser's row
    // fits its six buttons with room to spare at a width where the Editor still
    // has to fold — the surplus the old global switch ignored.
    const qreal narrow = number(QStringLiteral("browserCompactRowWidth")) + 10;
    QVERIFY2(narrow < number(QStringLiteral("editorCompactRowWidth")) - 50,
             "the Browser and Editor rows are too close for this test to prove anything");
    QCOMPARE(mode(QStringLiteral("editor"), narrow), QStringLiteral("mini"));
    QVERIFY2(mode(QStringLiteral("browser"), narrow) != QStringLiteral("mini"),
             qPrintable(QStringLiteral("the Browser folded at %1 px although its own row needs %2")
                          .arg(narrow)
                          .arg(number(QStringLiteral("browserCompactRowWidth")))));

    // And the Browser earns its labels before the Editor does, for the same
    // reason: its row is shorter.
    QVERIFY2(number(QStringLiteral("browserLabelThreshold"))
               < number(QStringLiteral("editorLabelThreshold")),
             "the Browser and Editor label thresholds are not per workspace");
  }

  /// The counted buttons in `ToolbarMetrics` must match the real toolbars. A
  /// workspace that adds a control and forgets the count would let a window be
  /// too narrow for its own toolbar, which is exactly the bug the floor exists
  /// to prevent.
  void theCountedButtonsMatchTheRealToolbars_data()
  {
    QTest::addColumn<QString>("file");
    QTest::addColumn<QString>("buttons");
    QTest::addColumn<QString>("separators");
    QTest::addColumn<QString>("total");
    QTest::addColumn<int>("readout");
    QTest::newRow("browser") << QStringLiteral("BrowserView.qml") << "browserButtons"
                             << "browserSeparators" << "browserToolbarWidth" << 0;
    // The Viewer's counter (`"3 / 12"`) and the Editor's zoom (`"100 %"`) are
    // not buttons: they are measured text, and a count that ignores them makes
    // the floor too narrow for the row.
    QTest::newRow("viewer") << QStringLiteral("Viewer.qml") << "viewerButtons"
                            << "viewerSeparators" << "viewerToolbarWidth" << 1;
    QTest::newRow("editor") << QStringLiteral("EditorView.qml") << "editorButtons"
                            << "editorSeparators" << "editorToolbarWidth" << 1;
  }

  void theCountedButtonsMatchTheRealToolbars()
  {
    QFETCH(QString, file);
    QFETCH(QString, buttons);
    QFETCH(QString, separators);
    QFETCH(QString, total);
    QFETCH(int, readout);

    QFile source(qmlDir() + QLatin1Char('/') + file);
    QVERIFY2(source.open(QIODevice::ReadOnly | QIODevice::Text),
             qPrintable(QStringLiteral("cannot read %1").arg(file)));
    const QString text = QString::fromUtf8(source.readAll());

    // Only the `toolbar` component matters: the rest of the view also draws
    // buttons (the editor's operation list, the browser's grid header).
    const int start = text.indexOf(QStringLiteral("property Component toolbar: Component"));
    QVERIFY2(start >= 0, qPrintable(QStringLiteral("%1 has no toolbar component").arg(file)));
    const QString toolbar = text.mid(start);

    const auto count = [&toolbar](const QString& pattern) {
      int found = 0;
      int at = toolbar.indexOf(pattern);
      while (at >= 0) {
        ++found;
        at = toolbar.indexOf(pattern, at + pattern.size());
      }
      return found;
    };

    // The overflow button takes the place of the folded ones, so it is not part
    // of the count the compact row is budgeted from — the mini width counts it
    // instead (`*MiniButtons`). It is found by its object name, which is what
    // the mini-visibility case in the view's own suite clicks.
    const int overflow = count(QStringLiteral("OverflowButton"));
    QCOMPARE(overflow, 1);
    const int actualButtons = count(QStringLiteral("ToolbarButton {")) - overflow;
    const int actualSeparators = count(QStringLiteral("ToolbarSeparator {"));
    QCOMPARE(int(real(m_metrics, buttons.toLatin1().constData())), actualButtons);
    QCOMPARE(int(real(m_metrics, separators.toLatin1().constData())), actualSeparators);

    // `total` is what the window floor is built from, so it must be the
    // buttons and separators *plus* whatever text the view lays between them.
    const qreal buttonsOnly = real(m_metrics, total.toLatin1().constData());
    const qreal slack = 1.0;
    if (readout == 0) {
      QVERIFY2(qAbs(buttonsOnly
                    - (actualButtons * real(m_metrics, "buttonWidth")
                       + actualSeparators * real(m_metrics, "separatorWidth")
                       + (actualButtons + actualSeparators - 1) * real(m_metrics, "buttonSpacing")))
                   < slack,
               qPrintable(QStringLiteral("%1: the browser toolbar width carries something "
                                         "that is not a button: %2 px")
                            .arg(file)
                            .arg(buttonsOnly)));
    } else {
      // There is a text readout in this toolbar: the measured width must exceed
      // the buttons alone, or the floor leaves it nowhere to go.
      QVERIFY2(buttonsOnly
                 - (actualButtons * real(m_metrics, "buttonWidth")
                    + actualSeparators * real(m_metrics, "separatorWidth")
                    + (actualButtons + actualSeparators - 1) * real(m_metrics, "buttonSpacing"))
                 > 10.0,
               qPrintable(QStringLiteral("%1: the toolbar has a text readout but its width "
                                         "budgets nothing for it (%2 px)")
                            .arg(file)
                            .arg(buttonsOnly)));
    }
  }

  /// The way out of a picture workspace sits in the same place in both of them:
  /// first, before the separator that starts the workspace's own actions.
  ///
  /// The Viewer always had it there and the Editor had it at the far end, after
  /// a document-dependent number of buttons, so the one control every picture
  /// workspace shares moved between them.
  void theBackButtonLeadsEveryWorkspaceToolbar()
  {
    const QStringList files = {QStringLiteral("Viewer.qml"),
                               QStringLiteral("EditorView.qml")};
    for (const QString& file : files) {
      QFile source(qmlDir() + QLatin1Char('/') + file);
      QVERIFY2(source.open(QIODevice::ReadOnly | QIODevice::Text),
               qPrintable(QStringLiteral("cannot read %1").arg(file)));
      const QString text = QString::fromUtf8(source.readAll());
      const int start = text.indexOf(QStringLiteral("property Component toolbar: Component"));
      QVERIFY2(start >= 0, qPrintable(QStringLiteral("%1 has no toolbar component").arg(file)));
      const QString toolbar = text.mid(start);

      const int first = toolbar.indexOf(QStringLiteral("ToolbarButton {"));
      QVERIFY2(first >= 0, qPrintable(QStringLiteral("%1's toolbar has no button").arg(file)));
      const int next = toolbar.indexOf(QStringLiteral("ToolbarButton {"), first + 1);
      QVERIFY2(next > first, qPrintable(QStringLiteral("%1's toolbar has one button").arg(file)));
      const QString block = toolbar.mid(first, next - first);

      QVERIFY2(block.contains(QStringLiteral("go-previous-symbolic")),
               qPrintable(QStringLiteral("%1's first toolbar button is not the back button")
                            .arg(file)));
      QVERIFY2(block.contains(QStringLiteral("set_workspace")),
               qPrintable(QStringLiteral("%1's back button does not leave the workspace").arg(file)));
    }
  }

  /// A button is the icon square with no label, and exactly its labelled width
  /// with one. The layout is what gives it that width, so the number the shell
  /// budgets must be the number the button asks for.
  void aButtonGrowsExactlyAsWideAsItsLabel()
  {
    auto* button = create(QStringLiteral("CompactToolbarButton.qml"), m_host);
    QVERIFY2(button != nullptr, "cannot load CompactToolbarButton.qml");
    button->setProperty("text", QStringLiteral("Viewer"));

    const qreal iconOnly = real(button, "iconOnlyWidth");
    const qreal labelled = real(button, "labelledWidth");
    QCOMPARE(iconOnly, 34.0);
    QVERIFY2(labelled > iconOnly,
             qPrintable(QStringLiteral("the label adds no width: %1 vs %2")
                          .arg(labelled)
                          .arg(iconOnly)));

    // No label until the shell says there is room.
    QVERIFY(!button->property("useText").toBool());
    QCOMPARE(real(button, "implicitWidth"), iconOnly);
    QCOMPARE(button->property("display").toInt(), int(Qt::ToolButtonIconOnly));

    // With room, the button asks the row for exactly the width that
    // `ToolbarMetrics` budgeted for a labelled button.
    button->setProperty("showLabel", true);
    QVERIFY2(button->property("useText").toBool(), "a labelled button hid its label");
    QVERIFY2(qAbs(real(button, "implicitWidth") - labelled) < 0.5,
             qPrintable(QStringLiteral("the button asks for %1 but its label needs %2")
                          .arg(real(button, "implicitWidth"))
                          .arg(labelled)));
    QCOMPARE(button->property("display").toInt(), int(Qt::ToolButtonTextBesideIcon));

    // A button with no text is still a square, whatever the shell allows.
    button->setProperty("text", QString());
    QVERIFY(!button->property("useText").toBool());
    QCOMPARE(real(button, "implicitWidth"), iconOnly);
  }

  /// The threshold follows the interface language.
  ///
  /// The labels are measured translated (`qsTranslate` into the context the
  /// switcher and the menu translate in), so a language with longer words needs
  /// a wider window before the labels appear. It did not: the measurements were
  /// the English literals, the threshold stayed at 1131 px, and Vietnamese — 94 px
  /// wider on this machine — fitted only because the arithmetic happens to budget
  /// the widest workspace. A slightly longer language would have clipped.
  void theLabelThresholdFollowsTheInterfaceLanguage()
  {
    QmlViewFixture fixture(&m_engine, switcherFixture(), QSize(1400, 60));
    QVERIFY2(fixture.root() != nullptr, qPrintable(fixture.error()));
    QObject* metrics = fixture.root()->findChild<QObject*>(QStringLiteral("toolbarMetrics"));
    QVERIFY(metrics != nullptr);

    const qreal english = real(metrics, "labelThreshold");
    const qreal englishLabels = real(metrics, "switcherLabelsWidth");
    QVERIFY2(english > 0, "the English threshold is not a number");

    // The same translator switch the settings dialog performs.
    InterfaceLanguage language(&m_engine, fixture.root(), QString());
    language.apply(QStringLiteral("vi"));

    const qreal vietnamese = real(metrics, "labelThreshold");
    const qreal vietnameseLabels = real(metrics, "switcherLabelsWidth");

    // "Trình chỉnh sửa" is wider than "Editor": the measured label total must
    // grow, and the threshold with it.
    QVERIFY2(vietnameseLabels > englishLabels,
             qPrintable(QStringLiteral("the Vietnamese labels measured no wider "
                                       "(%1 vs %2): the metrics are still using "
                                       "the English literals")
                          .arg(vietnameseLabels)
                          .arg(englishLabels)));
    QVERIFY2(vietnamese > english,
             qPrintable(QStringLiteral("the Vietnamese threshold is %1, not wider "
                                       "than the English %2")
                          .arg(vietnamese)
                          .arg(english)));
    // And the growth is the label growth, not some unrelated constant.
    QVERIFY2(qAbs((vietnamese - english) - (vietnameseLabels - englishLabels)) < 2.0,
             qPrintable(QStringLiteral("the threshold grew by %1 but the labels by %2")
                          .arg(vietnamese - english)
                          .arg(vietnameseLabels - englishLabels)));

    // Back to English: the numbers must return, so neither state passes by
    // never changing.
    language.apply(QString());
    QVERIFY2(qAbs(real(metrics, "labelThreshold") - english) < 1.0,
             "the threshold did not return to its English value");
  }

  /// The floor is built on the widest workspace, not whichever one happens to
  /// be open.
  ///
  /// Every workspace can be the current one, so a floor that fits only the
  /// Browser squeezes the Viewer's counter or the Editor's zoom the moment the
  /// user switches. This caught the floor being computed from the Browser's
  /// six buttons alone. It now measures the folded row, because that is what a
  /// window at the floor draws.
  void theFloorIsTheWidestWorkspace()
  {
    const qreal browser = real(m_metrics, "browserMiniToolbarWidth");
    const qreal viewer = real(m_metrics, "viewerMiniToolbarWidth");
    const qreal editor = real(m_metrics, "editorMiniToolbarWidth");
    const qreal widest = real(m_metrics, "widestMiniToolbarWidth");
    QCOMPARE(widest, qMax(browser, qMax(viewer, editor)));
    // And the floor is built on it: the switcher, a separator, the widest
    // folded toolbar and the row's fixed parts. The side-panel rule may make
    // the floor wider still, so this is a lower bound, not an equality.
    QVERIFY2(real(m_metrics, "minimumWindowWidth")
               >= real(m_metrics, "switcherIconsWidth") + real(m_metrics, "separatorWidth")
                    + widest + real(m_metrics, "busyIndicatorWidth")
                    + real(m_metrics, "menuButtonWidth"),
             "the window floor is narrower than the widest workspace's mini toolbar");
    // A workspace really is the widest one; if all three were equal the
    // assertion above would pass without proving the max. The Viewer keeps its
    // counter, so its folded row is still the one to fit.
    QVERIFY2(widest > browser, "the Browser is the widest mini toolbar: the test proves nothing");
  }

  /// The switcher is three icons while the window is narrow and three labelled
  /// buttons once the window passes the threshold — driven here by the width,
  /// the way `Main.qml` decides it, rather than by setting the flag directly.
  ///
  /// It runs inside a real window: a `RowLayout` only lays its children out
  /// once it is in one, and an unparented delegate stays at width 0 — which
  /// would make "the labels did not appear" true for the wrong reason.
  void theSwitcherDropsItsLabelsWhenTheWindowIsNarrow()
  {
    QmlViewFixture fixture(&m_engine, switcherFixture(), QSize(700, 60));
    QVERIFY2(fixture.root() != nullptr, qPrintable(fixture.error()));
    QQuickItem* switcher = fixture.item(QStringLiteral("toolbarSwitcher"));
    QVERIFY2(switcher != nullptr, "the fixture has no switcher");
    QObject* metrics = fixture.root()->findChild<QObject*>(QStringLiteral("toolbarMetrics"));
    QVERIFY(metrics != nullptr);

    const qreal iconsWidth = real(switcher, "iconsWidth");
    const qreal labelsWidth = real(switcher, "labelsWidth");
    QVERIFY2(labelsWidth > iconsWidth,
             qPrintable(QStringLiteral("the labels add no width: %1 vs %2")
                          .arg(labelsWidth)
                          .arg(iconsWidth)));

    // The delegates are QObject children of the layout's content item, not of
    // the switcher, so they are counted by walking the visual tree.
    const auto labelsShown = [switcher]() {
      int shown = 0;
      QList<QQuickItem*> pending(switcher->childItems());
      while (!pending.isEmpty()) {
        QQuickItem* candidate = pending.takeFirst();
        if (candidate->objectName().startsWith(QStringLiteral("workspaceButton-"))
            && candidate->property("useText").toBool()) {
          ++shown;
        }
        pending.append(candidate->childItems());
      }
      return shown;
    };

    const qreal threshold = real(metrics, "browserLabelThreshold");

    // Narrow: at the floor, labels are off.
    fixture.root()->setWidth(real(metrics, "minimumWindowWidth"));
    QTRY_COMPARE(labelsShown(), 0);

    // Wide: past the threshold, every label is drawn and the switcher is as
    // wide as its three labelled buttons.
    fixture.root()->setWidth(threshold + 100);
    QTRY_COMPARE(labelsShown(), 3);
    // `Layout.fillWidth` (the fixture stretches the switcher to the window) —
    // what matters is that the delegates are wider than their icon squares,
    // which `labelsShown()` already proves above.

    // And back again, so neither state can pass by never changing.
    fixture.root()->setWidth(threshold - 1);
    QTRY_COMPARE(labelsShown(), 0);
  }

  /// Toolbar buttons update `palette.buttonText` and `palette.windowText` when
  /// `theme.dark` flips, so light mode never inherits dark-theme white text on
  /// a white toolbar surface.
  void toolbarButtonsApplyThemeTextPalette()
  {
    for (const QString& file :
         { QStringLiteral("CompactToolbarButton.qml"), QStringLiteral("ToolbarButton.qml") }) {
      QObject* button = create(file, m_host);
      QVERIFY2(button != nullptr, qPrintable(file));
      QObject* theme = button->property("theme").value<QObject*>();
      QVERIFY2(theme != nullptr, qPrintable(file));

      for (const bool dark : { true, false }) {
        theme->setProperty("dark", dark);
        QTest::qWait(10);
        const QColor expected = theme->property("text").value<QColor>();
        QQmlExpression btnText(QQmlEngine::contextForObject(button), button,
                               QStringLiteral("String(palette.buttonText)"));
        QQmlExpression winText(QQmlEngine::contextForObject(button), button,
                               QStringLiteral("String(palette.windowText)"));
        QCOMPARE(QColor(btnText.evaluate().toString()), expected);
        QCOMPARE(QColor(winText.evaluate().toString()), expected);
      }
      delete button;
    }
  }
};

QTEST_MAIN(TestToolbar)
#include "tst_toolbar.moc"
