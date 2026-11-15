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
#include <QScopedPointer>
#include <QSignalSpy>
#include <QTest>

#include "stubthumbnailcache.h"

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

  /// Let Qt Quick finish the pending layout pass before measuring an item.
  static void settle() { QTest::qWait(20); }

  /// Click the centre of `item` with the left button, in window coordinates.
  void click(QQuickView* view, QQuickItem* item, bool doubleClick = false)
  {
    settle();
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

  /// Install the stub folder lister. `extraRoot` adds a folder that only
  /// appears after the "file operation", which is how a tree refresh is
  /// observed; `extraSub` instead adds one inside `/root/sub` so the root
  /// listing stays identical and the refresh has to reach a grandchild.
  void installFolderStub(bool extraRoot = false, bool extraSub = false)
  {
    const QString rootBody =
      extraRoot ? QStringLiteral("[ { name: 'dirA', path: '/root/dirA' },"
                                 "  { name: 'sub', path: '/root/sub' },"
                                 "  { name: 'fresh', path: '/root/fresh' } ]")
                : QStringLiteral("[ { name: 'dirA', path: '/root/dirA' },"
                                 "  { name: 'sub', path: '/root/sub' } ]");
    const QString subBody =
      extraSub ? QStringLiteral("[ { name: 'deep', path: '/root/sub/deep' },"
                                "  { name: 'born', path: '/root/sub/born' } ]")
               : QStringLiteral("[ { name: 'deep', path: '/root/sub/deep' } ]");
    QQmlExpression expression(
      m_engine.rootContext(), nullptr,
      QStringLiteral("(function(path) {\n"
                     "  if (path === '/root') return { ok: true, folders: %1 };\n"
                     "  if (path === '/root/sub') return { ok: true, folders: %2 };\n"
                     "  return { ok: true, folders: [] };\n"
                     "})")
        .arg(rootBody, subBody));
    m_browser->rootObject()->setProperty("listFolders", expression.evaluate());
  }

  /// The tree node for `path`, or nullptr when the tree does not show it.
  QQuickItem* findNode(const QString& path)
  {
    QQuickItem* root =
      items(browserItem(), QStringLiteral("folderTreeRoot")).first()->property("item").value<QQuickItem*>();
    if (root == nullptr) {
      return nullptr;
    }
    QList<QQuickItem*> nodes;
    collectNodes(root, &nodes);
    for (QQuickItem* candidate : nodes) {
      if (candidate->property("nodePath").toString() == path) {
        return candidate;
      }
    }
    return nullptr;
  }

  /// The first item with `objectName: name`, or nullptr.
  QQuickItem* findItem(const QString& name)
  {
    const QList<QQuickItem*> found = items(browserItem(), name);
    return found.isEmpty() ? nullptr : found.first();
  }

  /// The grid cell showing the entry at `path`, or nullptr.
  QQuickItem* findCell(const QString& path)
  {
    for (QQuickItem* candidate : items(browserItem(), QStringLiteral("fileCell"))) {
      if (readQml(candidate, QStringLiteral("entry.path")).toString() == path) {
        return candidate;
      }
    }
    return nullptr;
  }

  /// The thumbnail image inside a cell (or the preview panel) for `name`.
  QQuickItem* findImage(QQuickItem* root, const QString& name)
  {
    const QList<QQuickItem*> found = items(root, name);
    return found.isEmpty() ? nullptr : found.first();
  }

  /// Hand the view a stub cache the way `Main.qml` hands it the real one.
  void installThumbnailCache(StubThumbnailCache* cache)
  {
    browserItem()->setProperty("thumbnails",
                               QVariant::fromValue(static_cast<QObject*>(cache)));
    settle();
  }

  static QPoint centreOf(QQuickItem* item)
  {
    return item->mapToScene(QPointF(item->width() / 2.0, item->height() / 2.0)).toPoint();
  }

  /// Drag the pointer `dx` pixels horizontally with the left button held down.
  ///
  /// The moves arrive as a drag (Qt Quick keeps the implicit grab the press
  /// took), which is what makes the splitter follow the pointer; several small
  /// steps keep it realistic instead of teleporting the cursor.
  void dragBy(QQuickView* view, QQuickItem* handle, int dx, int steps = 6)
  {
    settle();
    const QPoint from = centreOf(handle);
    QTest::mousePress(view, Qt::LeftButton, Qt::NoModifier, from);
    QCoreApplication::processEvents();
    for (int step = 1; step <= steps; ++step) {
      QTest::mouseMove(view, QPoint(from.x() + dx * step / steps, from.y()));
      QCoreApplication::processEvents();
    }
    QTest::mouseRelease(view, Qt::LeftButton, Qt::NoModifier, QPoint(from.x() + dx, from.y()));
    QCoreApplication::processEvents();
    settle();
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
    installFolderStub();
    QQuickItem* view = browserItem();
    // Expansion bookkeeping and the revision baseline live on the view, so a
    // previous test would otherwise leak its expanded paths (and a folder it
    // invented) into the next one.
    view->setProperty("expandedPaths", QVariantMap());
    view->setProperty("collapsedPaths", QVariantMap());
    view->setProperty("lastTreeRevision", -1);
    // The stub cache of a previous test lived on its stack; drop it before it
    // dangles and before this test decides whether it wants a cache at all.
    // (A null *QObject pointer*, not an invalid QVariant: the property is `var`
    // and an invalid variant would leave the previous value in place.)
    view->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 0);
    view->setProperty("state", state);
    QCoreApplication::processEvents();

    // Rebuild the tree from the stub just installed and wait out the coalesced
    // refresh, so every test starts from a settled tree built from its own
    // folder lister and no reload fires in the middle of a test.
    // Sidebar widths live as long as the view does, so a drag in one test would
    // otherwise decide where the next test starts.
    if (QQuickItem* left = findItem(QStringLiteral("leftSplitter"))) {
      view->setProperty("leftPanelWidth", left->property("defaultValue"));
    }
    if (QQuickItem* right = findItem(QStringLiteral("rightSplitter"))) {
      view->setProperty("rightPanelWidth", right->property("defaultValue"));
    }

    QMetaObject::invokeMethod(view, "reloadTree", Qt::DirectConnection);
    QTest::qWait(200);
    QVERIFY(findNode(QStringLiteral("/root/fresh")) == nullptr);
    QVERIFY(findNode(QStringLiteral("/root/dirA")) != nullptr);
  }

  // ------------------------------------------------------------ toolbar/sidebars

  /// The browser toolbar must offer an icon-only "open folder" button. It only
  /// asks the shell for a dialog; the folder that comes back re-roots the tree
  /// through `open_folder`, which is the shell's job, not the view's.
  void toolbarOffersAnOpenFolderButton()
  {
    QQuickItem* viewItem = browserItem();
    auto* component = qobject_cast<QQmlComponent*>(viewItem->property("toolbar").value<QObject*>());
    QVERIFY2(component != nullptr, "the browser has no toolbar component");
    QScopedPointer<QObject> created(component->create(component->creationContext()));
    QVERIFY2(created != nullptr, qPrintable(component->errorString()));
    auto* row = qobject_cast<QQuickItem*>(created.data());
    QVERIFY(row != nullptr);
    row->setParentItem(viewItem);
    row->setWidth(560);
    row->setHeight(44);
    settle();

    QQuickItem* button = nullptr;
    for (QQuickItem* candidate : items(row, QStringLiteral("openFolderButton"))) {
      button = candidate;
    }
    QVERIFY2(button != nullptr, "no open-folder button in the toolbar");
    QCOMPARE(readQml(button, QStringLiteral("icon.name")).toString(),
             QStringLiteral("folder-open-symbolic"));
    QCOMPARE(readQml(button, QStringLiteral("display")).toInt(), kDisplayIconOnly);

    QSignalSpy requested(browserRoot(), SIGNAL(requestOpenFolder()));
    QSignalSpy commands(browserRoot(), SIGNAL(command(QVariant)));
    click(m_browser, button);
    QCOMPARE(requested.count(), 1);
    // Opening a folder dialog is not a navigation: the view sends no command.
    QCOMPARE(commands.count(), 0);
  }

  /// The quick-access/tree sidebar is resized by dragging its splitter, and the
  /// panel really gets wider — not just a stored number.
  void leftSidebarIsResizable()
  {
    QQuickItem* panel = findItem(QStringLiteral("leftPanel"));
    QQuickItem* splitter = findItem(QStringLiteral("leftSplitter"));
    QVERIFY(panel != nullptr && splitter != nullptr);
    const qreal before = browserItem()->property("leftPanelWidth").toReal();
    QVERIFY(before > 0);

    dragBy(m_browser, splitter, 80);
    QTRY_COMPARE_WITH_TIMEOUT(browserItem()->property("leftPanelWidth").toReal(), before + 80, 2000);
    QTRY_COMPARE_WITH_TIMEOUT(panel->width(), before + 80, 2000);
  }

  /// A drag cannot shrink a panel into nothing or push it over the centre.
  void sidebarResizeIsClamped()
  {
    QQuickItem* splitter = findItem(QStringLiteral("leftSplitter"));
    QVERIFY(splitter != nullptr);

    dragBy(m_browser, splitter, -600);
    QTRY_COMPARE_WITH_TIMEOUT(browserItem()->property("leftPanelWidth").toReal(),
                              splitter->property("minimum").toReal(), 2000);

    dragBy(m_browser, splitter, 4000);
    QTRY_COMPARE_WITH_TIMEOUT(browserItem()->property("leftPanelWidth").toReal(),
                              splitter->property("maximum").toReal(), 2000);
  }

  /// The preview sidebar sits on the other side, so dragging left widens it.
  void rightSidebarResizesInward()
  {
    QVariantMap state = baseState();
    state.insert(QStringLiteral("rightPanel"), true);
    browserItem()->setProperty("state", state);
    settle();

    QQuickItem* panel = findItem(QStringLiteral("rightPanel"));
    QQuickItem* splitter = findItem(QStringLiteral("rightSplitter"));
    QVERIFY(panel != nullptr && splitter != nullptr);
    const qreal before = browserItem()->property("rightPanelWidth").toReal();

    dragBy(m_browser, splitter, -90);
    QTRY_COMPARE_WITH_TIMEOUT(browserItem()->property("rightPanelWidth").toReal(), before + 90, 2000);
    QTRY_COMPARE_WITH_TIMEOUT(panel->width(), before + 90, 2000);
  }

  /// Double-clicking a splitter restores the width the theme suggests.
  void splitterDoubleClickRestoresTheDefault()
  {
    QQuickItem* splitter = findItem(QStringLiteral("leftSplitter"));
    QVERIFY(splitter != nullptr);
    const qreal initial = splitter->property("defaultValue").toReal();
    QCOMPARE(browserItem()->property("leftPanelWidth").toReal(), initial);

    dragBy(m_browser, splitter, -60);
    QTRY_VERIFY_WITH_TIMEOUT(browserItem()->property("leftPanelWidth").toReal() != initial, 2000);

    QTest::mouseDClick(m_browser, Qt::LeftButton, Qt::NoModifier, centreOf(splitter));
    QCoreApplication::processEvents();
    settle();
    // The handle restores the width it was first given, which is the theme's.
    QTRY_COMPARE_WITH_TIMEOUT(browserItem()->property("leftPanelWidth").toReal(), initial, 2000);
  }

  /// A hidden sidebar takes its splitter with it, so no handle is left floating
  /// against the window edge.
  void splitterFollowsPanelVisibility()
  {
    QQuickItem* splitter = findItem(QStringLiteral("leftSplitter"));
    QQuickItem* panel = findItem(QStringLiteral("leftPanel"));
    QVERIFY(splitter != nullptr && panel != nullptr);
    QCOMPARE(splitter->isVisible(), true);

    QVariantMap state = baseState();
    state.insert(QStringLiteral("leftPanel"), false);
    browserItem()->setProperty("state", state);
    settle();
    QCOMPARE(splitter->isVisible(), false);
    QCOMPARE(panel->isVisible(), false);

    state.insert(QStringLiteral("leftPanel"), true);
    browserItem()->setProperty("state", state);
    settle();
    QCOMPARE(splitter->isVisible(), true);
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

  /// A file operation (copy, move, trash, delete, new folder) bumps
  /// `treeRevision`; the tree then rebuilds itself from the filesystem but keeps
  /// the expansion and the folder that is currently open.
  void treeRefreshRebuildsNodesAndKeepsPosition()
  {
    QQuickItem* state0 = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    // Baseline revision: recording it must not reload anything by itself.
    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 7);
    state0->setProperty("state", state);
    QTest::qWait(250); // let the refresh this baseline change scheduled land

    // Expand a node that the current folder does not sit in, so only the
    // restore logic can keep it open.
    QQuickItem* dirA = findNode(QStringLiteral("/root/dirA"));
    QVERIFY(dirA != nullptr);
    click(m_browser, items(dirA, QStringLiteral("folderTreeRow")).first());
    QCOMPARE(dirA->property("expanded").toBool(), true);
    QCOMPARE(spy.count(), 1);

    // The filesystem gains a folder, and Core announces the change.
    installFolderStub(true);
    state.insert(QStringLiteral("treeRevision"), 8);
    state0->setProperty("state", state);

    QTRY_VERIFY2(findNode(QStringLiteral("/root/fresh")) != nullptr,
                 "the tree did not refresh after the tree revision changed");
    QQuickItem* dirAfter = findNode(QStringLiteral("/root/dirA"));
    QVERIFY(dirAfter != nullptr);
    QCOMPARE(dirAfter->property("expanded").toBool(), true);
    QVERIFY2(findNode(QStringLiteral("/root/sub")) != nullptr, "the sub folder disappeared");

    // The root and the folder on screen are untouched, and the refresh itself
    // must not send any command.
    QCOMPARE(items(state0, QStringLiteral("folderTreeRoot")).first()
               ->property("folderPath").toString(),
             QStringLiteral("/root"));
    QCOMPARE(state0->property("state").toMap().value(QStringLiteral("currentFolder")).toString(),
             QStringLiteral("/root/sub"));
    QCOMPARE(spy.count(), 1);
  }

  /// A change two levels down must reach the tree too. The root listing is
  /// unchanged, so no root delegate is recreated: the refresh has to walk into
  /// the already-expanded child nodes. Before that recursion existed the tree
  /// kept showing the stale grandchild rows while the grid was already fresh.
  void treeRefreshReachesAnUnchangedParent()
  {
    QQuickItem* view = browserItem();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 11);
    view->setProperty("state", state);
    QTest::qWait(250); // let the refresh this baseline change scheduled land

    // `/root/sub` is the current folder, so auto-reveal opened it.
    QQuickItem* sub = findNode(QStringLiteral("/root/sub"));
    QVERIFY(sub != nullptr);
    QCOMPARE(sub->property("expanded").toBool(), true);
    QVERIFY2(findNode(QStringLiteral("/root/sub/deep")) != nullptr, "sub is not expanded");
    QVERIFY(findNode(QStringLiteral("/root/sub/born")) == nullptr);

    // A folder is created inside the open sub folder; `/root` itself is
    // unchanged, which is exactly the case delegate re-creation cannot cover.
    installFolderStub(false, true);
    state.insert(QStringLiteral("treeRevision"), 12);
    view->setProperty("state", state);

    QTRY_VERIFY2(findNode(QStringLiteral("/root/sub/born")) != nullptr,
                 "the refresh did not reach the expanded child node");
    QVERIFY2(findNode(QStringLiteral("/root/sub/deep")) != nullptr, "a sibling row disappeared");

    QQuickItem* subAfter = findNode(QStringLiteral("/root/sub"));
    QVERIFY(subAfter != nullptr);
    QCOMPARE(subAfter->property("expanded").toBool(), true);
    QCOMPARE(items(view, QStringLiteral("folderTreeRoot")).first()->property("folderPath").toString(),
             QStringLiteral("/root"));
    QCOMPARE(view->property("state").toMap().value(QStringLiteral("currentFolder")).toString(),
             QStringLiteral("/root/sub"));
    QCOMPARE(spy.count(), 0);
  }

  /// A node the user collapsed stays collapsed across a refresh.
  void treeRefreshRespectsUserCollapse()
  {
    QQuickItem* view = browserItem();
    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 2);
    view->setProperty("state", state);
    QCoreApplication::processEvents();

    // `followCurrent` opened /root/sub because it is the current folder.
    QQuickItem* sub = findNode(QStringLiteral("/root/sub"));
    QVERIFY(sub != nullptr);
    QCOMPARE(sub->property("expanded").toBool(), true);

    QQuickItem* row = items(sub, QStringLiteral("folderTreeRow")).first();
    click(m_browser, row); // navigate, still expanded
    QCOMPARE(sub->property("expanded").toBool(), true);

    QQuickItem* chevron = nullptr;
    for (QQuickItem* candidate : allDescendants(row)) {
      const QString text = candidate->property("text").toString();
      if (text == QStringLiteral("\u25be") || text == QStringLiteral("\u25b8")) {
        chevron = candidate;
        break;
      }
    }
    QVERIFY(chevron != nullptr);
    click(m_browser, chevron);
    QCOMPARE(sub->property("expanded").toBool(), false);

    installFolderStub(true);
    state.insert(QStringLiteral("treeRevision"), 3);
    view->setProperty("state", state);
    QTRY_VERIFY2(findNode(QStringLiteral("/root/fresh")) != nullptr,
                 "the tree did not refresh after the tree revision changed");

    QQuickItem* subAfter = findNode(QStringLiteral("/root/sub"));
    QVERIFY(subAfter != nullptr);
    QCOMPARE(subAfter->property("expanded").toBool(), false);
  }

  /// Without a revision bump nothing is reloaded, so ordinary state updates
  /// (selection, workspace, status) do not rebuild the tree.
  void treeIsNotReloadedWithoutATreeRevision()
  {
    QQuickItem* view = browserItem();
    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 4);
    view->setProperty("state", state);
    QCoreApplication::processEvents();
    QVERIFY(findNode(QStringLiteral("/root/fresh")) == nullptr);

    // Recording the baseline revision schedules one refresh (coalesced by a
    // timer); let it land before the "filesystem" changes, otherwise that
    // already-pending reload would pick up the new folder and this control
    // would no longer be about the revision bump below.
    QTest::qWait(250);
    QVERIFY(findNode(QStringLiteral("/root/fresh")) == nullptr);

    installFolderStub(true);
    state.insert(QStringLiteral("selection"), QStringList{ QStringLiteral("/root/img.png") });
    view->setProperty("state", state);
    QTest::qWait(400);
    QVERIFY2(findNode(QStringLiteral("/root/fresh")) == nullptr,
             "the tree reloaded without a tree revision change");

    state.insert(QStringLiteral("treeRevision"), 5);
    view->setProperty("state", state);
    QTRY_VERIFY2(findNode(QStringLiteral("/root/fresh")) != nullptr,
                 "the tree did not reload when the revision changed");
  }

  // --------------------------------------------------------- thumbnails

  /// The grid tile draws the cached thumbnail instead of the original file, and
  /// asks for it with the entry's size and mtime, so an edited image misses.
  void gridDrawsTheCachedThumbnail()
  {
    StubThumbnailCache cache;
    installThumbnailCache(&cache);

    QQuickItem* cell = findCell(QStringLiteral("/root/img.png"));
    QVERIFY2(cell != nullptr, "no grid cell for the image");
    QQuickItem* image = findImage(cell, QStringLiteral("gridThumbnail"));
    QVERIFY2(image != nullptr, "the grid cell has no thumbnail image");

    QTRY_VERIFY2(!cache.calls.isEmpty(), "the grid never asked for a thumbnail");
    const StubThumbnailCache::Call call = cache.lastCallFor(QStringLiteral("/root/img.png"));
    QCOMPARE(call.modified, qint64(1731000000));
    QCOMPARE(call.size, qint64(4096));
    QVERIFY2(call.edge >= 160, "the requested edge is below the smallest bucket");

    // Nothing is drawn before the thumbnail exists: the tile keeps its
    // placeholder instead of decoding the original a second time.
    QCOMPARE(image->property("source").toString(), QString());

    cache.deliver(call, QStringLiteral("file:///cache/thumb-grid.jpg"));
    QTRY_COMPARE(image->property("source").toString(),
                 QStringLiteral("file:///cache/thumb-grid.jpg"));

    // The folder in the same grid asked for nothing: it is not an image.
    QVERIFY2(cache.lastCallFor(QStringLiteral("/root/dirA")).path.isEmpty(),
             "the folder entry was sent to the thumbnail cache");
  }

  /// A recycled tile must only accept the answer for the entry it is showing
  /// now. Without that check a cell that scrolled onto another image would draw
  /// the previous image's thumbnail.
  void aRecycledTileIgnoresTheAnswerForAnotherEntry()
  {
    StubThumbnailCache cache;
    installThumbnailCache(&cache);

    QQuickItem* cell = findCell(QStringLiteral("/root/img.png"));
    QVERIFY2(cell != nullptr, "no grid cell for the image");
    QQuickItem* image = findImage(cell, QStringLiteral("gridThumbnail"));
    QVERIFY2(image != nullptr, "the grid cell has no thumbnail image");
    QTRY_VERIFY2(!cache.calls.isEmpty(), "the grid never asked for a thumbnail");

    // The answer to a key this tile is not showing must be dropped.
    QVERIFY(QMetaObject::invokeMethod(image, "setThumbnail",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("someone-else"))),
                                      Q_ARG(QVariant,
                                            QVariant(QStringLiteral("file:///cache/wrong.jpg")))));
    settle();
    QCOMPARE(image->property("source").toString(), QString());

    // And its own answer still lands.
    cache.deliverAllFor(QStringLiteral("/root/img.png"),
                        QStringLiteral("file:///cache/right.jpg"));
    QTRY_COMPARE(image->property("source").toString(), QStringLiteral("file:///cache/right.jpg"));
  }

  /// The preview panel is thumbnailed too, and dropping the cache object puts
  /// the views back on the original file.
  void previewDrawsTheCachedThumbnail()
  {
    StubThumbnailCache cache;
    installThumbnailCache(&cache);

    QVariantMap state = baseState();
    state.insert(QStringLiteral("rightPanel"), true);
    QVariantMap info;
    info.insert(QStringLiteral("path"), QStringLiteral("/root/img.png"));
    info.insert(QStringLiteral("name"), QStringLiteral("img.png"));
    info.insert(QStringLiteral("kind"), QStringLiteral("JPEG image"));
    info.insert(QStringLiteral("isImage"), true);
    info.insert(QStringLiteral("size"), qint64(4096));
    info.insert(QStringLiteral("modified"), qint64(1731000000));
    state.insert(QStringLiteral("selectionInfo"), info);
    browserItem()->setProperty("state", state);
    settle();

    QQuickItem* preview = findItem(QStringLiteral("previewThumbnail"));
    QVERIFY2(preview != nullptr, "no preview image in the right sidebar");

    QTRY_VERIFY2(!cache.callsFor(QStringLiteral("/root/img.png")).isEmpty(),
                 "the preview panel never asked for a thumbnail");
    // Every ask carries the file's version, whatever size bucket it is for.
    const QList<StubThumbnailCache::Call> asks = cache.callsFor(QStringLiteral("/root/img.png"));
    for (const StubThumbnailCache::Call& ask : asks) {
      QCOMPARE(ask.modified, qint64(1731000000));
      QCOMPARE(ask.size, qint64(4096));
      QVERIFY2(ask.edge >= 160, "the requested edge is below the smallest bucket");
    }

    cache.deliverAllFor(QStringLiteral("/root/img.png"),
                        QStringLiteral("file:///cache/thumb-preview.jpg"));
    QTRY_COMPARE(preview->property("source").toString(),
                 QStringLiteral("file:///cache/thumb-preview.jpg"));

    // No cache object (`ThumbnailBook.cache` is null): the original is drawn.
    browserItem()->setProperty("thumbnails",
                               QVariant::fromValue(static_cast<QObject*>(nullptr)));
    QTRY_VERIFY2(preview->property("source").toString() == QStringLiteral("file:///root/img.png"),
                 "without a cache object the preview stopped drawing the original");
  }

  /// An undecodable image falls back to the original instead of staying blank,
  /// and is not asked for again — the cache remembers the failure.
  void AFailedThumbnailFallsBackToTheOriginal()
  {
    StubThumbnailCache cache;
    installThumbnailCache(&cache);

    QQuickItem* cell = findCell(QStringLiteral("/root/img.png"));
    QVERIFY(cell != nullptr);
    QQuickItem* image = findImage(cell, QStringLiteral("gridThumbnail"));
    QVERIFY(image != nullptr);

    QTRY_VERIFY(!cache.lastCallFor(QStringLiteral("/root/img.png")).path.isEmpty());
    const StubThumbnailCache::Call call = cache.lastCallFor(QStringLiteral("/root/img.png"));
    cache.fail(call);

    QTRY_COMPARE(image->property("source").toString(), QStringLiteral("file:///root/img.png"));
    // Every later evaluation takes the remembered failure: no new request.
    const int requests = cache.calls.size();
    browserItem()->setProperty("state", baseState());
    settle();
    QCOMPARE(cache.calls.size(), requests);
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
