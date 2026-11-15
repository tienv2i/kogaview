// Browser/workspace regression tests: the toolbar mode switcher renders
// `<icon> <text>`, and the explorer keeps its root unless the user explicitly
// opens a folder.
//
// The tests load the real `crates/desktop/qml/WorkspaceSwitcher.qml` and
// `crates/desktop/qml/BrowserView.qml` and drive them with real mouse events
// (`QTest::mouseClick`/`mouseDClick` reach the same `TapHandler`s a physical
// click reaches), then assert on the commands the views emit. The views only
// talk to Core through those commands, so the emitted command *is* the visible
// behaviour contract: a tree click must emit `navigate` (debug: it re-rooted
// the tree) and only quick access may emit `open_folder`.

#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickView>
#include <QSignalSpy>
#include <QTest>

namespace {

constexpr int kSwitcherWidth = 420;
constexpr int kSwitcherHeight = 48;
constexpr int kBrowserWidth = 1100;
constexpr int kBrowserHeight = 720;

// QQuickAbstractButton::Display: IconOnly = 0, TextOnly, TextBesideIcon.
constexpr int kDisplayIconOnly = 0;
constexpr int kDisplayTextBesideIcon = 2;

QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}

QVariantMap entry(const QString& name, const QString& path, bool isDir, bool isImage)
{
  QVariantMap map;
  map.insert(QStringLiteral("name"), name);
  map.insert(QStringLiteral("path"), path);
  map.insert(QStringLiteral("isDir"), isDir);
  map.insert(QStringLiteral("isImage"), isImage);
  map.insert(QStringLiteral("size"), isDir ? 0 : 4096);
  map.insert(QStringLiteral("modified"), 1731000000);
  return map;
}

QVariantMap crumb(const QString& name, const QString& path)
{
  QVariantMap map;
  map.insert(QStringLiteral("name"), name);
  map.insert(QStringLiteral("path"), path);
  return map;
}

} // namespace

class TestBrowser : public QObject
{
  Q_OBJECT

private:
  QQmlEngine m_engine;
  QQuickView* m_switcher = nullptr;
  QQuickView* m_browser = nullptr;

  /// Recursively collect every item that carries `objectName: name`.
  static void collect(QQuickItem* root, const QString& name, QList<QQuickItem*>* out)
  {
    if (root->objectName() == name) {
      out->append(root);
    }
    for (QQuickItem* child : root->childItems()) {
      collect(child, name, out);
    }
  }

  static QList<QQuickItem*> items(QQuickItem* root, const QString& name)
  {
    QList<QQuickItem*> found;
    collect(root, name, &found);
    return found;
  }

  static void descend(QQuickItem* root, QList<QQuickItem*>* out)
  {
    for (QQuickItem* child : root->childItems()) {
      out->append(child);
      descend(child, out);
    }
  }

  static QList<QQuickItem*> allDescendants(QQuickItem* root)
  {
    QList<QQuickItem*> found;
    descend(root, &found);
    return found;
  }

  /// Click the centre of `item` with the left button, in window coordinates.
  void click(QQuickView* view, QQuickItem* item, bool doubleClick = false)
  {
    const QPointF centre = item->mapToScene(QPointF(item->width() / 2.0, item->height() / 2.0));
    if (doubleClick) {
      QTest::mouseDClick(view, Qt::LeftButton, Qt::NoModifier, centre.toPoint());
    } else {
      QTest::mouseClick(view, Qt::LeftButton, Qt::NoModifier, centre.toPoint());
    }
    QCoreApplication::processEvents();
  }

  QObject* browserRoot() const
  {
    return m_browser->rootObject();
  }

  QQuickItem* browserItem() const
  {
    return m_browser->rootObject();
  }

  /// All commands the BrowserView emitted so far, as `{type, path}` maps.
  /// Read a property at the QML level, which is how grouped properties such as
  /// `icon.name` are reachable.
  static QVariant readQml(QObject* object, const QString& expression)
  {
    QQmlExpression reader(QQmlEngine::contextForObject(object), object, expression);
    return reader.evaluate();
  }

  /// The delegate of a tree node is a `Loader`; the node itself is `item`.
  static QQuickItem* nodeBehind(QQuickItem* item)
  {
    if (item->property("nodePath").isValid()) {
      return item;
    }
    QQuickItem* loaded = item->property("item").value<QQuickItem*>();
    return (loaded != nullptr && loaded->property("nodePath").isValid()) ? loaded : nullptr;
  }

  /// Every node item (self and descendants) of the tree, in tree order.
  static void collectNodes(QQuickItem* node, QList<QQuickItem*>* out)
  {
    for (QQuickItem* child : node->childItems()) {
      QQuickItem* candidate = nodeBehind(child);
      if (candidate != nullptr) {
        out->append(candidate);
        collectNodes(candidate, out);
      }
    }
  }

  static QList<QPair<QString, QString>> commands(const QSignalSpy& spy)
  {
    QList<QPair<QString, QString>> result;
    for (const QList<QVariant>& call : spy) {
      const QVariantMap map = call.at(0).toMap();
      result.append({ map.value(QStringLiteral("type")).toString(),
                      map.value(QStringLiteral("path")).toString() });
    }
    return result;
  }

  static QString describe(const QList<QPair<QString, QString>>& list)
  {
    QStringList parts;
    for (const auto& entry : list) {
      parts.append(entry.first + QLatin1Char(':') + entry.second);
    }
    return parts.join(QStringLiteral(", "));
  }

  QVariantMap baseState() const
  {
    QVariantList entries;
    entries.append(entry(QStringLiteral("dirA"), QStringLiteral("/root/dirA"), true, false));
    entries.append(entry(QStringLiteral("img.png"), QStringLiteral("/root/img.png"), false, true));

    QVariantList crumbs;
    crumbs.append(crumb(QStringLiteral("/"), QStringLiteral("/")));
    crumbs.append(crumb(QStringLiteral("root"), QStringLiteral("/root")));
    crumbs.append(crumb(QStringLiteral("sub"), QStringLiteral("/root/sub")));

    QVariantMap state;
    state.insert(QStringLiteral("rootFolder"), QStringLiteral("/root"));
    state.insert(QStringLiteral("currentFolder"), QStringLiteral("/root/sub"));
    state.insert(QStringLiteral("favorites"), QStringList{ QStringLiteral("/fav") });
    state.insert(QStringLiteral("entries"), entries);
    state.insert(QStringLiteral("breadcrumbs"), crumbs);
    state.insert(QStringLiteral("selection"), QStringList{});
    state.insert(QStringLiteral("leftPanel"), true);
    state.insert(QStringLiteral("rightPanel"), false);
    state.insert(QStringLiteral("home"), QStringLiteral("/home/tester"));
    state.insert(QStringLiteral("theme"), QStringLiteral("dark"));
    state.insert(QStringLiteral("busy"), false);
    state.insert(QStringLiteral("workspace"), QStringLiteral("browser"));
    return state;
  }

private slots:
  void initTestCase()
  {
    m_switcher = new QQuickView(&m_engine, nullptr);
    m_switcher->setResizeMode(QQuickView::SizeRootObjectToView);
    m_switcher->resize(kSwitcherWidth, kSwitcherHeight);
    m_switcher->setSource(QUrl::fromLocalFile(qmlDir() + QStringLiteral("/WorkspaceSwitcher.qml")));
    QCOMPARE(m_switcher->status(), QQuickView::Ready);
    m_switcher->show();
    QVERIFY(QTest::qWaitForWindowExposed(m_switcher));

    m_browser = new QQuickView(&m_engine, nullptr);
    m_browser->setResizeMode(QQuickView::SizeRootObjectToView);
    m_browser->resize(kBrowserWidth, kBrowserHeight);
    m_browser->setSource(QUrl::fromLocalFile(qmlDir() + QStringLiteral("/BrowserView.qml")));
    QCOMPARE(m_browser->status(), QQuickView::Ready);
    m_browser->show();
    QVERIFY(QTest::qWaitForWindowExposed(m_browser));
  }

  void init()
  {
    // Fresh BrowserView state for every test, with a stub folder lister so the
    // tree can populate without touching the filesystem.
    QQmlExpression expression(
      m_engine.rootContext(), nullptr,
      QStringLiteral("(function(path) {\n"
                     "  if (path === '/root') {\n"
                     "    return { ok: true, folders: ["
                     "      { name: 'dirA', path: '/root/dirA' },"
                     "      { name: 'sub', path: '/root/sub' } ] };\n"
                     "  }\n"
                     "  return { ok: true, folders: [] };\n"
                     "})"));
    m_browser->rootObject()->setProperty("listFolders", expression.evaluate());
    m_browser->rootObject()->setProperty("state", baseState());
    QCoreApplication::processEvents();
  }

  // ---------------------------------------------------------------- switcher

  /// The mode buttons must read `<icon> <text>`; icon-only was the bug.
  void switcherShowsIconAndText()
  {
    QQuickItem* switcher = m_switcher->rootObject();
    QVERIFY(switcher != nullptr);

    const QStringList names = { QStringLiteral("browser"), QStringLiteral("viewer"),
                                QStringLiteral("editor") };
    const QStringList labels = { QStringLiteral("Browser"), QStringLiteral("Viewer"),
                                 QStringLiteral("Editor") };

    for (int index = 0; index < names.size(); ++index) {
      const QList<QQuickItem*> found =
        items(switcher, QStringLiteral("workspaceButton-") + names.at(index));
      QCOMPARE(found.size(), 1);
      QQuickItem* button = found.first();

      QCOMPARE(button->property("text").toString(), labels.at(index));
      QCOMPARE(button->property("display").toInt(), kDisplayTextBesideIcon);
      QVERIFY2(button->property("display").toInt() != kDisplayIconOnly,
               "the mode buttons must not be icon-only");

      const QString iconName = readQml(button, QStringLiteral("icon.name")).toString();
      QVERIFY2(!iconName.isEmpty(),
               qPrintable(QStringLiteral("%1 button has no icon (icon.name is empty)")
                            .arg(labels.at(index))));

      // The label must contribute to the layout: an icon-only button has a
      // content width of the icon alone, so a wider content item proves the
      // text is measured in, and a button at least as wide as its content
      // proves the layout did not squeeze the label away.
      const qreal iconWidth =
        readQml(button, QStringLiteral("icon.width")).toReal();
      const qreal contentWidth =
        readQml(button, QStringLiteral("contentItem ? contentItem.implicitWidth : 0")).toReal();
      QVERIFY2(contentWidth > iconWidth + 2.0,
               qPrintable(QStringLiteral("%1 content is icon-only (%2 px, icon %3 px)")
                            .arg(labels.at(index))
                            .arg(contentWidth)
                            .arg(iconWidth)));
      QVERIFY2(button->width() + 0.5 >= button->implicitWidth(),
               qPrintable(QStringLiteral("%1 button is squeezed to %2 px, needs %3 px")
                            .arg(labels.at(index))
                            .arg(button->width())
                            .arg(button->implicitWidth())));
      QVERIFY2(button->implicitWidth() > 34.0,
               "implicitWidth still forces the icon-only square size");
    }
  }

  void switcherReportsTheClickedWorkspace()
  {
    QQuickItem* switcher = m_switcher->rootObject();
    QSignalSpy spy(switcher, SIGNAL(selected(QString)));
    QCOMPARE(spy.count(), 0);

    switcher->setProperty("workspace", QStringLiteral("browser"));
    QCoreApplication::processEvents();

    QList<QQuickItem*> viewer = items(switcher, QStringLiteral("workspaceButton-viewer"));
    QCOMPARE(viewer.size(), 1);
    click(m_switcher, viewer.first());

    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toString(), QStringLiteral("viewer"));

    // The checked state follows the workspace the shell reports back.
    switcher->setProperty("workspace", QStringLiteral("viewer"));
    QCoreApplication::processEvents();
    QCOMPARE(viewer.first()->property("checked").toBool(), true);
    QList<QQuickItem*> browser = items(switcher, QStringLiteral("workspaceButton-browser"));
    QCOMPARE(browser.first()->property("checked").toBool(), false);
  }

  // ----------------------------------------------------------------- browser

  /// The tree must stay rooted where the user opened it, even when a different
  /// folder is being shown.
  void treeIsRootedAtTheOpenedFolder()
  {
    QQuickItem* root = browserItem();
    QList<QQuickItem*> loader = items(root, QStringLiteral("folderTreeRoot"));
    QCOMPARE(loader.size(), 1);
    QCOMPARE(loader.first()->property("folderPath").toString(), QStringLiteral("/root"));

    QQuickItem* node = loader.first()->property("item").value<QQuickItem*>();
    QVERIFY(node != nullptr);
    QCOMPARE(node->property("nodePath").toString(), QStringLiteral("/root"));
    QCOMPARE(node->property("nodeName").toString(), QStringLiteral("root"));
    QCOMPARE(node->property("expanded").toBool(), true);
  }

  /// A click on a tree node expands it and navigates; it must not emit
  /// `open_folder`, which is what re-rooted the tree before.
  void treeClickNavigatesWithoutRerooting()
  {
    QQuickItem* root = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QQuickItem* node = items(root, QStringLiteral("folderTreeRoot")).first()
                         ->property("item").value<QQuickItem*>();
    QVERIFY(node != nullptr);

    // Children of the root node: one node per subfolder.
    QList<QQuickItem*> nodes;
    collectNodes(node, &nodes);
    QQuickItem* child = nullptr;
    for (QQuickItem* candidate : nodes) {
      if (candidate->property("nodePath").toString() == QStringLiteral("/root/dirA")) {
        child = candidate;
        break;
      }
    }
    QVERIFY2(child != nullptr, "the tree did not expand into its subfolders");
    QCOMPARE(child->property("expanded").toBool(), false);

    QList<QQuickItem*> rows = items(child, QStringLiteral("folderTreeRow"));
    QCOMPARE(rows.size(), 1);
    click(m_browser, rows.first());

    const auto emitted = commands(spy);
    QCOMPARE(describe(emitted), QStringLiteral("navigate:/root/dirA"));
    QCOMPARE(child->property("expanded").toBool(), true);

    // The tree root is untouched: no re-rooting on navigation.
    QCOMPARE(items(browserItem(), QStringLiteral("folderTreeRoot")).first()
               ->property("folderPath").toString(),
             QStringLiteral("/root"));
  }

  /// The disclosure arrow expands and collapses; it never navigates.
  void treeChevronOnlyTogglesTheNode()
  {
    QQuickItem* root = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QQuickItem* node = items(root, QStringLiteral("folderTreeRoot")).first()
                         ->property("item").value<QQuickItem*>();
    QVERIFY(node != nullptr);

    QQuickItem* chevron = nullptr;
    const QList<QQuickItem*> rowChildren =
      allDescendants(items(node, QStringLiteral("folderTreeRow")).first());
    for (QQuickItem* candidate : rowChildren) {
      const QString text = candidate->property("text").toString();
      if (text == QStringLiteral("\u25be") || text == QStringLiteral("\u25b8")) {
        chevron = candidate;
        break;
      }
    }
    QVERIFY2(chevron != nullptr, "no disclosure arrow found in the tree row");

    click(m_browser, chevron);
    QCOMPARE(node->property("expanded").toBool(), false);
    click(m_browser, chevron);
    QCOMPARE(node->property("expanded").toBool(), true);
    QCOMPARE(spy.count(), 0);

    // A deliberate collapse must survive navigation: auto-reveal expands
    // towards the current folder, but never undoes the user's collapse.
    click(m_browser, chevron);
    QCOMPARE(node->property("expanded").toBool(), false);
    QVariantMap state = baseState();
    state.insert(QStringLiteral("currentFolder"), QStringLiteral("/root/sub/deeper"));
    m_browser->rootObject()->setProperty("state", state);
    QCoreApplication::processEvents();
    QCOMPARE(node->property("expanded").toBool(), false);

    // Expanding it again still shows the subfolders.
    click(m_browser, chevron);
    QCOMPARE(node->property("expanded").toBool(), true);
    bool sawSub = false;
    QList<QQuickItem*> nodes;
    collectNodes(node, &nodes);
    for (QQuickItem* candidate : nodes) {
      sawSub = sawSub || candidate->property("nodePath").toString() == QStringLiteral("/root/sub");
    }
    QVERIFY2(sawSub, "expanding the root node again did not bring back its subfolders");
  }

  /// Quick access is an explicit open: it re-roots the tree.
  void quickAccessOpensTheFolder()
  {
    QQuickItem* root = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QList<QQuickItem*> quick = items(root, QStringLiteral("quickAccessItem"));
    QCOMPARE(quick.size(), 1);
    click(m_browser, quick.first());

    QCOMPARE(describe(commands(spy)), QStringLiteral("open_folder:/fav"));
  }

  /// Double-clicking a folder in the grid browses into it; the tree keeps its
  /// root, so this is a navigation, not an open.
  void gridDoubleClickOnFolderNavigates()
  {
    QQuickItem* root = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QQuickItem* cell = nullptr;
    for (QQuickItem* candidate : items(root, QStringLiteral("fileCell"))) {
      const QVariantMap entry = candidate->property("entry").toMap();
      if (entry.value(QStringLiteral("isDir")).toBool()) {
        cell = candidate;
        break;
      }
    }
    QVERIFY2(cell != nullptr, "no folder cell in the grid");
    click(m_browser, cell, true);

    const auto emitted = commands(spy);
    for (const auto& command : emitted) {
      QVERIFY2(command.first != QStringLiteral("open_folder"),
               qPrintable(QStringLiteral("double-clicking a folder re-rooted the tree: %1")
                            .arg(describe(emitted))));
    }
    QVERIFY2(emitted.contains({ QStringLiteral("navigate"), QStringLiteral("/root/dirA") }),
             qPrintable(QStringLiteral("no navigate command, got: %1").arg(describe(emitted))));
  }

  /// Double-clicking an image still opens the Viewer.
  void gridDoubleClickOnImageOpensTheViewer()
  {
    QQuickItem* root = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QQuickItem* cell = nullptr;
    for (QQuickItem* candidate : items(root, QStringLiteral("fileCell"))) {
      const QVariantMap entry = candidate->property("entry").toMap();
      if (entry.value(QStringLiteral("isImage")).toBool()) {
        cell = candidate;
        break;
      }
    }
    QVERIFY2(cell != nullptr, "no image cell in the grid");
    click(m_browser, cell, true);

    bool opened = false;
    for (const QList<QVariant>& call : spy) {
      const QVariantMap map = call.at(0).toMap();
      if (map.value(QStringLiteral("type")).toString() == QStringLiteral("open_file")) {
        opened = map.value(QStringLiteral("paths")).toStringList()
                   .contains(QStringLiteral("/root/img.png"));
      }
    }
    QVERIFY2(opened, qPrintable(QStringLiteral("no open_file for the image, got: %1")
                                  .arg(describe(commands(spy)))));
  }

  /// Breadcrumbs navigate like the tree: they do not re-root anything.
  void breadcrumbNavigatesWithoutRerooting()
  {
    QQuickItem* root = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QQuickItem* crumbLabel = nullptr;
    QList<QQuickItem*> labels = items(root, QStringLiteral("crumbLabel"));
    for (QQuickItem* candidate : labels) {
      if (candidate->property("text").toString() == QStringLiteral("root")) {
        crumbLabel = candidate;
        break;
      }
    }
    QVERIFY2(crumbLabel != nullptr, "no breadcrumb label rendered");
    click(m_browser, crumbLabel);

    QCOMPARE(describe(commands(spy)), QStringLiteral("navigate:/root"));
  }
};

QTEST_MAIN(TestBrowser)
#include "tst_browser.moc"
