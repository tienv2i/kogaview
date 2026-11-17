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

  /// The floor is the compact toolbar, and the label threshold sits above it:
  /// a window at the floor shows every control with labels dropped, and a
  /// window past the threshold can afford every label.
  void theFloorIsTheCompactToolbar()
  {
    const qreal compact = real(m_metrics, "compactToolbarWidth");
    const qreal labelled = real(m_metrics, "labelledToolbarWidth");
    const qreal floor = real(m_metrics, "minimumWindowWidth");
    const qreal threshold = real(m_metrics, "labelThreshold");

    QVERIFY2(compact > 0, "the compact toolbar has no width");
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
    QVERIFY2(floor >= compact,
             qPrintable(QStringLiteral("no window may be narrower than the toolbar (%1 vs %2)")
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
  }

  /// `compactToolbarWidth` is what the header row really needs with the labels
  /// off, not an approximation of it.
  ///
  /// The real window is the authority here: the `RowLayout` in `Main.qml` wraps
  /// its children with 4 px gaps and 8 px side margins, and a workspace toolbar
  /// carries text readouts (the Viewer's counter, the Editor's zoom) that a
  /// plain button count misses. This lays out the same six children with the
  /// same spacing and margins and asserts the two agree to within the slack;
  /// it caught the arithmetic being 84 px short, which let a window exist that
  /// squeezed the toolbar.
  void theCompactWidthMatchesTheRealHeaderRow()
  {
    // The header row reproduced with the metrics' own numbers: same children,
    // spacing and side margins.
    QmlViewFixture fixture(&m_engine, headerRowFixture(), QSize(2000, 60));
    QVERIFY2(fixture.root() != nullptr, qPrintable(fixture.error()));
    QQuickItem* row = fixture.root();
    QVERIFY2(row != nullptr, "the fixture has no row layout");

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
    const qreal measured = real(metrics, "compactToolbarWidth");
    QVERIFY2(live > 0, "the header row has no implicit width");
    // The elastic spacer contributes 0, the rest are the metrics' own numbers:
    // a mismatch means a child, a gap or a margin is missing from the
    // arithmetic, and a window at the floor would squeeze a control.
    QVERIFY2(qAbs(live - measured) < 2.0,
             qPrintable(QStringLiteral("the header row needs %1 px (%2 controls + %3 gaps) "
                                       "but the metrics say %4")
                          .arg(live)
                          .arg(controls)
                          .arg(gaps)
                          .arg(measured)));

    // And the floor can show it: every control at its intrinsic width.
    QVERIFY2(real(metrics, "minimumWindowWidth") >= live,
             qPrintable(QStringLiteral("the window floor is below the row's own width (%1 < %2)")
                          .arg(real(metrics, "minimumWindowWidth"))
                          .arg(live)));
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

    const int actualButtons = count(QStringLiteral("ToolbarButton {"));
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

  /// The floor is the widest workspace, not whichever one happens to be open.
  ///
  /// Every workspace can be the current one, so a floor that fits only the
  /// Browser squeezes the Viewer's counter or the Editor's zoom the moment the
  /// user switches. This caught the floor being computed from the Browser's
  /// six buttons alone.
  void theFloorIsTheWidestWorkspace()
  {
    const qreal browser = real(m_metrics, "browserToolbarWidth");
    const qreal viewer = real(m_metrics, "viewerToolbarWidth");
    const qreal editor = real(m_metrics, "editorToolbarWidth");
    const qreal widest = real(m_metrics, "widestToolbarWidth");
    QCOMPARE(widest, qMax(browser, qMax(viewer, editor)));
    // And the floor is built on it: the switcher, a separator, the widest
    // toolbar and the row's fixed parts.
    QVERIFY2(real(m_metrics, "minimumWindowWidth")
               >= real(m_metrics, "switcherIconsWidth") + real(m_metrics, "separatorWidth")
                    + widest + real(m_metrics, "busyIndicatorWidth")
                    + real(m_metrics, "menuButtonWidth"),
             "the window floor is narrower than the widest workspace's toolbar");
    // A workspace really is the widest one; if all three were equal the
    // assertion above would pass without proving the max.
    QVERIFY2(widest > browser, "the Browser is the widest toolbar: the test proves nothing");
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

    const qreal threshold = real(metrics, "labelThreshold");

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
};

QTEST_MAIN(TestToolbar)
#include "tst_toolbar.moc"
