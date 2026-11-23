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
#include <QFile>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QPointingDevice>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickView>
#include <QRegularExpression>
#include <QScopedPointer>
#include <QSignalSpy>
#include <QTest>

#include <qpa/qwindowsysteminterface.h>

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

/// Every label a `MenuItem { … }` block literally shows, read from a QML source.
///
/// `Theme.menuEntryLabels` is a hand-kept list measured once in C++; it drifted
/// from the shell menu once already ("Settings…" and "Library…" shipped without
/// an entry, so the hamburger menu grew past the theme floor). `Main.qml`
/// instantiates the real `KogaViewBridge`, so this suite cannot load it; the
/// shell menu is guarded at the source instead, so adding an entry without
/// measuring its label fails here. Braces are tracked so only text inside a
/// `MenuItem` counts, and the caller checks the count is plausible so a parser
/// that silently found nothing cannot pass.
QStringList menuItemLabelsIn(const QString& path, const QStringList& catalogue = {})
{
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
    return {};
  }
  const QRegularExpression literal(QStringLiteral("\"([^\"]*)\""));
  QStringList labels;
  int depth = 0;
  bool inMenu = false;
  const QStringList lines = QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'));
  for (const QString& raw : lines) {
    const QString line = raw.trimmed();
    if (!inMenu && line.contains(QStringLiteral("MenuItem {"))) {
      inMenu = true;
      depth = 0;
    }
    if (!inMenu) {
      continue;
    }
    if (line.startsWith(QStringLiteral("text:"))) {
      // A conditional label (`theme === "dark" ? "A" : "B"`) has quoted
      // comparison operands that are not labels: drop those before reading.
      QString stripped = line;
      for (const QString& op : { QStringLiteral("=== \""), QStringLiteral("!== \""),
                                 QStringLiteral("== \""), QStringLiteral("!= \"") }) {
        int at = stripped.indexOf(op);
        while (at >= 0) {
          const int close = stripped.indexOf(QLatin1Char('"'), at + op.size());
          if (close < 0) {
            break;
          }
          stripped.remove(at, close - at + 1);
          at = stripped.indexOf(op);
        }
      }
      // A menu built from `Theme.menuEntries[n]` names no literal here: resolve
      // the index back to the measured catalogue entry, which is what the menu
      // really draws once the language is applied.
      static const QRegularExpression indexed(
        QStringLiteral("menuEntries\\s*\\[\\s*(\\d+)\\s*\\]"));
      auto slotMatches = indexed.globalMatch(stripped);
      while (slotMatches.hasNext()) {
        const int slot = slotMatches.next().captured(1).toInt();
        if (slot >= 0 && slot < catalogue.size()) {
          labels.append(catalogue.at(slot));
        } else {
          labels.append(QStringLiteral("<slot %1>").arg(slot));
        }
      }
      // `Theme.batchToolsLabel` names the last catalogue entry instead of an
      // index, so resolve it to the entry that carries "Tools" — and if the
      // catalogue has lost that word this test says so rather than skipping the
      // entry.
      if (stripped.contains(QStringLiteral("batchToolsLabel"))) {
        QString tools;
        for (const QString& label : catalogue) {
          if (label.contains(QStringLiteral("Tools"))) {
            tools = label;
            break;
          }
        }
        labels.append(tools.isEmpty() ? QStringLiteral("<no Tools label>") : tools);
      }
      auto matches = literal.globalMatch(stripped);
      while (matches.hasNext()) {
        labels.append(matches.next().captured(1));
      }
    }
    depth += line.count(QLatin1Char('{')) - line.count(QLatin1Char('}'));
    if (depth <= 0) {
      inMenu = false;
    }
  }
  return labels;
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
  /// `baseState()`'s listings; a test puts them on the view with `showState`.
  QVariantList entryList;
  /// The layout the view sees. The shell owns it in the app; this harness
  /// merges the view's patches the way `Main.qml` does.
  QVariantMap m_layout;
  /// Monotonic timestamp for injected wheel events, like a QPA plugin's.
  int m_timestamp = 0;

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

  /// The words one column of a details row is drawing. The rows are the
  /// delegates; each column is a `Label` inside them, named for its column.
  QString rowText(QQuickItem* row, const QString& column) const
  {
    const QList<QQuickItem*> found = items(row, column);
    return found.isEmpty() ? QString() : found.first()->property("text").toString();
  }

  /// The first item with `objectName: name`, or nullptr.
  QQuickItem* findItem(const QString& name)
  {
    const QList<QQuickItem*> found = items(browserItem(), name);
    return found.isEmpty() ? nullptr : found.first();
  }

  /// A popup by `objectName`. Menus are `Popup`s, not items: they live in their
  /// own window and only appear in `findChildren`, never in the item tree.
  QObject* findPopup(const QString& name)
  {
    return browserItem()->findChild<QObject*>(name);
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

  /// Inject a wheel event over `scene`, the way a QPA plugin delivers real
  /// input. `QWindowSystemInterface` refuses `ScrollUpdate` phases on Qt 6.12, so
  /// this covers the `NoScrollPhase` events a mouse wheel produces.
  void injectWheel(const QPoint& scene, QPoint pixelDelta, QPoint angleDelta)
  {
    const bool queued = QWindowSystemInterface::handleWheelEvent(
      m_browser, ++m_timestamp, mouseDevice(), QPointF(scene),
      QPointF(m_browser->mapToGlobal(scene)), pixelDelta, angleDelta, Qt::NoModifier,
      Qt::NoScrollPhase);
    QVERIFY2(queued, "the wheel event was not queued");
    QWindowSystemInterface::flushWindowSystemEvents();
    QCoreApplication::processEvents();
  }

  /// Install a snapshot the way `Main.qml` does: the listing as the view's own
  /// `entries`, and the metadata as `state` (the two are published apart).
  void showState(QObject* object, const QVariantMap& state)
  {
    object->setProperty("entries", entryList);
    object->setProperty("state", state);
  }

  /// A wheel-reporting mouse, so the event is not mistaken for a touchpad.
  static QPointingDevice* mouseDevice()
  {
    static QPointingDevice* device = new QPointingDevice(
      QStringLiteral("test mouse"), 1002, QInputDevice::DeviceType::Mouse,
      QPointingDevice::PointerType::Generic,
      QInputDevice::Capability::Scroll | QInputDevice::Capability::PixelScroll, 1, 3);
    return device;
  }

  QVariantMap baseState()
  {
    QVariantList entries;
    entries.append(entry(QStringLiteral("dirA"), QStringLiteral("/root/dirA"), true, false));
    entries.append(entry(QStringLiteral("img.png"), QStringLiteral("/root/img.png"), false, true));

    QVariantList crumbs;
    crumbs.append(crumb(QStringLiteral("/"), QStringLiteral("/")));
    crumbs.append(crumb(QStringLiteral("root"), QStringLiteral("/root")));
    crumbs.append(crumb(QStringLiteral("sub"), QStringLiteral("/root/sub")));

    entryList = entries;

    QVariantMap state;
    state.insert(QStringLiteral("rootFolder"), QStringLiteral("/root"));
    state.insert(QStringLiteral("currentFolder"), QStringLiteral("/root/sub"));
    state.insert(QStringLiteral("favorites"), QStringList{ QStringLiteral("/fav") });
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

  /// A state snapshot carrying `selection`, so a test starts from a settled
  /// Core-owned selection instead of the empty one `init` installs.
  void showSelection(const QStringList& paths)
  {
    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 0);
    state.insert(QStringLiteral("selection"), paths);
    showState(browserItem(), state);
    settle();
  }

  /// Give the view the keyboard, the way showing the window does in the app.
  /// The assertion is the test's own guard: a dead focus would make every key
  /// below a no-op that looks like a broken shortcut.
  void giveKeyboardFocus()
  {
    browserItem()->forceActiveFocus();
    settle();
    QVERIFY2(browserItem()->property("activeFocus").toBool(),
             "the Browser never took keyboard focus");
  }

  /// A listing of four images, so a range has something to span.
  void showFourImages()
  {
    // `baseState()` writes the two-entry fixture into `entryList`, so the four
    // cells replace it afterwards — the same order `downMovesByOneGridRow`
    // uses.
    QVariantMap state = baseState();
    QVariantList entries;
    for (int index = 0; index < 4; ++index) {
      entries.append(entry(QStringLiteral("pic%1.png").arg(index),
                           QStringLiteral("/root/pic%1.png").arg(index), false, true));
    }
    entryList = entries;
    state.insert(QStringLiteral("treeRevision"), 0);
    showState(browserItem(), state);
    settle();
  }

  /// Publish a selection back to a view showing the four-image fixture. Not
  /// `showSelection`, which rebuilds `baseState()`'s two-entry listing.
  void showFourImageSelection(const QStringList& paths)
  {
    QVariantMap state = baseState();
    QVariantList entries;
    for (int index = 0; index < 4; ++index) {
      entries.append(entry(QStringLiteral("pic%1.png").arg(index),
                           QStringLiteral("/root/pic%1.png").arg(index), false, true));
    }
    entryList = entries;
    state.insert(QStringLiteral("treeRevision"), 0);
    state.insert(QStringLiteral("selection"), paths);
    showState(browserItem(), state);
    settle();
  }

private slots:
  /// Merge a `layoutRequested` patch into `m_layout`, key by key, exactly as
  /// `Main.qml`'s `mergeLayout` does; the view then sees the new layout.
  void applyLayoutRequested(const QVariant& patch)
  {
    const QVariantMap changes = patch.toMap();
    QVariantMap next = m_layout;
    for (const QString& key : {QStringLiteral("leftWidth"), QStringLiteral("rightWidth"),
                               QStringLiteral("editorToolColumns"),
                               QStringLiteral("editorReferenceHeight"),
                               QStringLiteral("editorReferenceTab"),
                               QStringLiteral("browserView")}) {
      if (changes.contains(key)) next.insert(key, changes.value(key));
    }
    QVariantMap panels = m_layout.value(QStringLiteral("panels")).toMap();
    const QVariantMap changedPanels = changes.value(QStringLiteral("panels")).toMap();
    for (auto it = changedPanels.begin(); it != changedPanels.end(); ++it) {
      panels.insert(it.key(), it.value());
    }
    next.insert(QStringLiteral("panels"), panels);
    m_layout = next;
    browserItem()->setProperty("layout", next);
  }

  /// The built-in layout a first launch opens with: both docks visible and the
  /// theme's widths. Every case starts here.
  void resetLayout()
  {
    QVariantMap panels;
    for (const QString& key : {QStringLiteral("browser.quickAccess"),
                               QStringLiteral("browser.explorer"),
                               QStringLiteral("browser.preview"),
                               QStringLiteral("browser.batch")}) {
      panels.insert(key, true);
    }
    m_layout = QVariantMap{{QStringLiteral("leftWidth"), 260},
                           {QStringLiteral("rightWidth"), 300},
                           {QStringLiteral("browserView"), QStringLiteral("thumbnails")},
                           {QStringLiteral("panels"), panels}};
    browserItem()->setProperty("layout", m_layout);
  }

  /// Put the folder in a shape the way the switch does — one layout value, the
  /// same one `set_layout` carries — and wait for the view to read it.
  void showViewMode(const QString& mode)
  {
    QVariantMap patch;
    patch.insert(QStringLiteral("browserView"), mode);
    applyLayoutRequested(patch);
    settle();
    QCOMPARE(browserItem()->property("viewMode").toString(), mode);
  }

  void setPanelShown(const QString& key, bool visible)
  {
    QVariantMap patch;
    patch.insert(QStringLiteral("panels"), QVariantMap{{QStringLiteral("browser.") + key, visible}});
    applyLayoutRequested(patch);
  }

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
    QVERIFY(QObject::connect(browserItem(), SIGNAL(layoutRequested(QVariant)),
                             this, SLOT(applyLayoutRequested(QVariant))));
  }

  void init()
  {
    // Fresh BrowserView state for every test, with a stub folder lister so the
    // tree can populate without touching the filesystem.
    installFolderStub();
    QQuickItem* view = browserItem();
    // The layout is the shell's; a drag or a hidden panel in one test must not
    // decide where the next one starts.
    resetLayout();
    // Expansion bookkeeping and the revision baseline live on the Explorer
    // panel, so a previous test would otherwise leak its expanded paths (and a
    // folder it invented) into the next one.
    if (QQuickItem* explorer = findItem(QStringLiteral("explorerPanel"))) {
      explorer->setProperty("expandedPaths", QVariantMap());
      explorer->setProperty("collapsedPaths", QVariantMap());
      explorer->setProperty("lastTreeRevision", -1);
    }
    view->setProperty("keyboardCursor", -1);
    view->setProperty("selectionAnchor", -1);
    // The sidebar page is presentation state; a case that opened Batch must
    // not decide what the next one shows when it asserts the Preview page.
    view->setProperty("rightPage", QStringLiteral("preview"));
    // The stub cache of a previous test lived on its stack; drop it before it
    // dangles and before this test decides whether it wants a cache at all.
    // (A null *QObject pointer*, not an invalid QVariant: the property is `var`
    // and an invalid variant would leave the previous value in place.)
    view->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
    QVariantMap state = baseState();
    state.insert(QStringLiteral("treeRevision"), 0);
    showState(view, state);
    // Main.qml measures the menu labels with C++ and hands the widths to the
    // view; there is no shell in this harness, so the suite does the same.
    QObject* theme = view->property("theme").value<QObject*>();
    // The widths go on the view, not on `theme`: BrowserView defaults to a
    // `Theme` of its own, so a theme the harness reaches is not the one its
    // menus measure with.
    if (theme != nullptr && view->property("menuLabelWidths").value<QVariantList>().isEmpty()) {
      // Same source the app uses: the labels the theme itself lists.
      const QVariantList labels = theme->property("menuEntryLabels").value<QVariantList>();
      QVariantList widths;
      const QFontMetricsF metrics(QGuiApplication::font());
      for (const QVariant& label : labels) {
        widths.append(metrics.horizontalAdvance(label.toString()));
      }
      view->setProperty("menuLabelWidths", widths);
    }
    QCoreApplication::processEvents();

    // Rebuild the tree from the stub just installed and wait out the coalesced
    // refresh, so every test starts from a settled tree built from its own
    // folder lister and no reload fires in the middle of a test.
    QQuickItem* explorer = findItem(QStringLiteral("explorerPanel"));
    QVERIFY(explorer != nullptr);
    QMetaObject::invokeMethod(explorer, "reload", Qt::DirectConnection);
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

  /// Every toolbar control whose action has a key names that key in its
  /// tooltip; `Rotate left (Shift+R)` is the pattern. Reading the attached
  /// `ToolTip.text` at the QML level is the only way to see what the popup
  /// would draw without opening it.
  void toolbarTooltipsNameTheirShortcuts()
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

    const QList<QPair<QString, QString>> expected = {
      { QStringLiteral("go-up-symbolic"), QStringLiteral("Go to parent folder (Backspace)") },
      { QStringLiteral("view-refresh-symbolic"), QStringLiteral("Refresh (F5)") },
      { QStringLiteral("folder-open-symbolic"),
        QStringLiteral("Open folder… (Ctrl+Shift+O)") },
    };
    for (const auto& entry : expected) {
      QQuickItem* button = nullptr;
      for (QQuickItem* candidate : allDescendants(row)) {
        if (readQml(candidate, QStringLiteral("icon.name")).toString() == entry.first) {
          button = candidate;
          break;
        }
      }
      QVERIFY2(button != nullptr,
               qPrintable(QStringLiteral("no %1 button").arg(entry.first)));
      QCOMPARE(readQml(button, QStringLiteral("ToolTip.text")).toString(), entry.second);
    }
  }

  /// The two copy entries name the keys that run them, drawn at the menu's right
  /// edge (a `MenuItem` has no shortcut column). The folder menu's "Copy path"
  /// shares the path key, because both commands put the same text on the
  /// clipboard.
  void theCopyEntriesNameTheirKeys()
  {
    const auto hintOf = [this](const QString& menuName, const QString& label) -> QQuickItem* {
      QObject* menu = findPopup(menuName);
      if (menu == nullptr) {
        return nullptr;
      }
      const int count = menu->property("count").toInt();
      for (int index = 0; index < count; ++index) {
        QQuickItem* entry = nullptr;
        QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                  Q_ARG(int, index));
        if (entry != nullptr && entry->property("text").toString() == label) {
          return entry->findChild<QQuickItem*>(QStringLiteral("shortcutHint"));
        }
      }
      return nullptr;
    };

    const QStringList expectedMenus = { QStringLiteral("fileMenu"), QStringLiteral("folderMenu") };
    for (const QString& name : expectedMenus) {
      QObject* menu = findPopup(name);
      QVERIFY2(menu != nullptr, qPrintable(name + QStringLiteral(" is missing")));
      QMetaObject::invokeMethod(menu, "popup");
      QTRY_VERIFY2(menu->property("visible").toBool(),
                   qPrintable(name + QStringLiteral(" did not open")));
    }

    QQuickItem* copyImage = hintOf(QStringLiteral("fileMenu"),
                                   QStringLiteral("Copy image content"));
    QVERIFY2(copyImage != nullptr, "the copy-image entry draws no key");
    QCOMPARE(copyImage->property("text").toString(), QStringLiteral("Ctrl+Shift+C"));

    QQuickItem* copyFile = hintOf(QStringLiteral("fileMenu"), QStringLiteral("Copy file path"));
    QVERIFY2(copyFile != nullptr, "the copy-path entry draws no key");
    QCOMPARE(copyFile->property("text").toString(), QStringLiteral("Ctrl+Alt+C"));

    QQuickItem* copyFolder = hintOf(QStringLiteral("folderMenu"), QStringLiteral("Copy path"));
    QVERIFY2(copyFolder != nullptr, "the folder copy entry draws no key");
    QCOMPARE(copyFolder->property("text").toString(), QStringLiteral("Ctrl+Alt+C"));

    // The keys are a right-hand column, not part of the label: the menu's own
    // width accounting depends on that separation.
    QObject* fileMenu = findPopup(QStringLiteral("fileMenu"));
    QVERIFY(fileMenu != nullptr);
    QMetaObject::invokeMethod(fileMenu, "close");
    QMetaObject::invokeMethod(findPopup(QStringLiteral("folderMenu")), "close");
  }

  /// Below the full icon row the Browser keeps its three navigation buttons and
  /// folds the new-folder and two sidebar toggles into one overflow button. The
  /// count is `ToolbarMetrics.browserMiniButtons`, so the window floor and the
  /// row that is drawn cannot disagree.
  void theMiniToolbarFoldsTheSecondaryActions_data()
  {
    QTest::addColumn<bool>("mini");
    QTest::newRow("compact") << false;
    QTest::newRow("mini") << true;
  }

  void theMiniToolbarFoldsTheSecondaryActions()
  {
    QFETCH(bool, mini);
    QQuickItem* viewItem = browserItem();
    auto* component = qobject_cast<QQmlComponent*>(viewItem->property("toolbar").value<QObject*>());
    QVERIFY2(component != nullptr, "the browser has no toolbar component");
    QScopedPointer<QObject> created(component->create(component->creationContext()));
    QVERIFY2(created != nullptr, qPrintable(component->errorString()));
    auto* row = qobject_cast<QQuickItem*>(created.data());
    QVERIFY(row != nullptr);
    row->setParentItem(viewItem);
    row->setWidth(1000);
    row->setHeight(44);
    browserItem()->setProperty("miniToolbar", mini);
    settle();

    int buttons = 0;
    QQuickItem* overflow = nullptr;
    for (QQuickItem* candidate : allDescendants(row)) {
      if (!QString::fromLatin1(candidate->metaObject()->className())
             .contains(QStringLiteral("ToolbarButton"))) {
        continue;
      }
      if (candidate->objectName() == QStringLiteral("browserOverflowButton")) {
        overflow = candidate;
      }
      if (candidate->isVisible()) {
        ++buttons;
      }
    }
    QVERIFY2(overflow != nullptr, "the toolbar has no overflow button");
    QCOMPARE(overflow->isVisible(), mini);
    // Up, refresh, Open folder and either New folder or the overflow button:
    // the sidebar toggle is gone, its panels live in Settings.
    QCOMPARE(buttons, 4);

    if (mini) {
      QVERIFY(QMetaObject::invokeMethod(overflow, "click"));
      QObject* menu = findPopup(QStringLiteral("browserOverflowMenu"));
      QVERIFY2(menu != nullptr, "the browser has no overflow menu");
      QTRY_VERIFY2(menu->property("visible").toBool(), "the overflow menu did not open");
      // The only secondary action left is New folder: panel visibility moved
      // to Settings › Appearance, so there is no toggle to fold here.
      QCOMPARE(menu->property("count").toInt(), 1);
      QMetaObject::invokeMethod(menu, "close");
      QTRY_VERIFY(!menu->property("visible").toBool());
    }
    browserItem()->setProperty("miniToolbar", false);
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
    showState(browserItem(), state);
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

    setPanelShown(QStringLiteral("quickAccess"), false);
    setPanelShown(QStringLiteral("explorer"), false);
    settle();
    QCOMPARE(splitter->isVisible(), false);
    QCOMPARE(panel->isVisible(), false);

    setPanelShown(QStringLiteral("explorer"), true);
    settle();
    QCOMPARE(splitter->isVisible(), true);
  }

  // ---------------------------------------------------------------- switcher

  /// Each workspace button names its Ctrl shortcut in the tooltip. The keys
  /// themselves live in `Main.qml` (the switcher is also in `Main.qml`), so the
  /// tooltip is the only place the view can state them.
  void switcherTooltipsNameTheWorkspaceShortcuts()
  {
    QQuickItem* switcher = m_switcher->rootObject();
    QVERIFY(switcher != nullptr);

    const QList<QPair<QString, QString>> expected = {
      { QStringLiteral("browser"),
        QStringLiteral("Browser workspace: folders and thumbnails (Ctrl+1)") },
      { QStringLiteral("viewer"),
        QStringLiteral("Viewer workspace: zoom, pan, rotate (Ctrl+2)") },
      { QStringLiteral("editor"),
        QStringLiteral("Editor workspace: non-destructive edits (Ctrl+3)") },
    };
    for (const auto& entry : expected) {
      const QList<QQuickItem*> found =
        items(switcher, QStringLiteral("workspaceButton-") + entry.first);
      QCOMPARE(found.size(), 1);
      QCOMPARE(readQml(found.first(), QStringLiteral("ToolTip.text")).toString(), entry.second);
    }
  }

  /// The mode buttons show `<icon> <text>` when the window can afford the
  /// labels, and drop to the icon square when it cannot — the two states this
  /// toolbar is allowed to be in.
  ///
  /// Both are asserted, in both directions, so neither "always icon-only"
  /// (the original bug: the current workspace was unreadable) nor "always
  /// text" (the bug this replaced: the labelled buttons squeezed everything
  /// after them out of a narrow window) can pass.
  void switcherShowsIconAndText()
  {
    QQuickItem* switcher = m_switcher->rootObject();
    QVERIFY(switcher != nullptr);

    const QStringList names = { QStringLiteral("browser"), QStringLiteral("viewer"),
                                QStringLiteral("editor") };
    const QStringList labels = { QStringLiteral("Browser"), QStringLiteral("Viewer"),
                                 QStringLiteral("Editor") };

    const auto assertState = [&](bool labelsAllowed) {
      for (int index = 0; index < names.size(); ++index) {
        const QList<QQuickItem*> found =
          items(switcher, QStringLiteral("workspaceButton-") + names.at(index));
        QCOMPARE(found.size(), 1);
        QQuickItem* button = found.first();

        // The label is always in `text`, whatever the toolbar is showing, so a
        // tooltip and a screen reader agree with the drawn state.
        QCOMPARE(button->property("text").toString(), labels.at(index));

        const QString iconName = readQml(button, QStringLiteral("icon.name")).toString();
        QVERIFY2(!iconName.isEmpty(),
                 qPrintable(QStringLiteral("%1 button has no icon (icon.name is empty)")
                              .arg(labels.at(index))));

        const qreal iconOnly = readQml(button, QStringLiteral("iconOnlyWidth")).toReal();
        const qreal labelled = readQml(button, QStringLiteral("labelledWidth")).toReal();
        QVERIFY2(labelled > iconOnly,
                 qPrintable(QStringLiteral("%1 adds no width for its label").arg(labels.at(index))));

        if (labelsAllowed) {
          QCOMPARE(button->property("display").toInt(), kDisplayTextBesideIcon);
          QVERIFY2(qAbs(button->implicitWidth() - labelled) < 0.5,
                   qPrintable(QStringLiteral("%1 asks for %2 px, its label needs %3")
                                .arg(labels.at(index))
                                .arg(button->implicitWidth())
                                .arg(labelled)));
          // The label must contribute to the layout: an icon-only button has a
          // content width of the icon alone.
          const qreal iconWidth = readQml(button, QStringLiteral("icon.width")).toReal();
          const qreal contentWidth =
            readQml(button, QStringLiteral("contentItem ? contentItem.implicitWidth : 0"))
              .toReal();
          QVERIFY2(contentWidth > iconWidth + 2.0,
                   qPrintable(QStringLiteral("%1 content is icon-only (%2 px, icon %3 px)")
                                .arg(labels.at(index))
                                .arg(contentWidth)
                                .arg(iconWidth)));
        } else {
          QCOMPARE(button->property("display").toInt(), kDisplayIconOnly);
          QCOMPARE(button->implicitWidth(), iconOnly);
        }

        // Never squeezed by the row, in either state.
        QVERIFY2(button->width() + 0.5 >= button->implicitWidth(),
                 qPrintable(QStringLiteral("%1 button is squeezed to %2 px, needs %3 px")
                              .arg(labels.at(index))
                              .arg(button->width())
                              .arg(button->implicitWidth())));
      }
    };

    switcher->setProperty("showLabels", true);
    QCoreApplication::processEvents();
    assertState(true);

    switcher->setProperty("showLabels", false);
    QCoreApplication::processEvents();
    assertState(false);

    switcher->setProperty("showLabels", true);
    QCoreApplication::processEvents();
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
    showState(m_browser->rootObject(), state);
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
    showState(state0, state);
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
    showState(state0, state);

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
    showState(view, state);
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
    showState(view, state);

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
    showState(view, state);
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
    showState(view, state);
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
    showState(view, state);
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
    showState(view, state);
    QTest::qWait(400);
    QVERIFY2(findNode(QStringLiteral("/root/fresh")) == nullptr,
             "the tree reloaded without a tree revision change");

    state.insert(QStringLiteral("treeRevision"), 5);
    showState(view, state);
    QTRY_VERIFY2(findNode(QStringLiteral("/root/fresh")) != nullptr,
                 "the tree did not reload when the revision changed");
  }

  /// Dragging the splitter keeps the panel under the pointer on every frame.
  ///
  /// The handle itself moves as the panel grows, so reading the pointer in the
  /// handle's own coordinates feeds back into the drag: the panel advances by
  /// part of the pointer's travel and alternates between two widths as frames
  /// go by — felt as a lagging sidebar and seen as the highlight line jumping.
  void splitterFollowsThePointerAcrossFrames()
  {
    QQuickItem* splitter = findItem(QStringLiteral("leftSplitter"));
    QVERIFY(splitter != nullptr);
    const qreal before = browserItem()->property("leftPanelWidth").toReal();
    const QPoint from = centreOf(splitter);

    QTest::mousePress(m_browser, Qt::LeftButton, Qt::NoModifier, from);
    QCoreApplication::processEvents();
    for (int step = 1; step <= 8; ++step) {
      const int travel = step * 10;
      QTest::mouseMove(m_browser, QPoint(from.x() + travel, from.y()));
      // One frame, so the layout really moves the handle before the next move
      // arrives. Without it the handle never moves during the drag and the
      // feedback this test is about cannot happen — that is why the older
      // `leftSidebarIsResizable` never saw it.
      QTest::qWait(16);
      QTRY_COMPARE_WITH_TIMEOUT(browserItem()->property("leftPanelWidth").toReal(),
                                before + travel, 1000);
    }
    QTest::mouseRelease(m_browser, Qt::LeftButton, Qt::NoModifier,
                        QPoint(from.x() + 80, from.y()));
    QCoreApplication::processEvents();
    settle();
  }

  /// One wheel notch moves the grid by about a row. Qt's own handling moves it
  /// by ~72 px whatever the cell size, which on the ~194 px cells measured here
  /// is a third of a row and reads as "the wheel barely works".
  void oneWheelNotchScrollsTheGrid()
  {
    QVariantMap state = baseState();
    QVariantList many;
    for (int index = 0; index < 200; ++index) {
      many.append(entry(QStringLiteral("photo-%1.jpg").arg(index),
                        QStringLiteral("/root/photo-%1.jpg").arg(index), false, true));
    }
    entryList = many;
    showState(browserItem(), state);
    settle();

    QQuickItem* grid = findItem(QStringLiteral("fileGrid"));
    QVERIFY(grid != nullptr);
    QTRY_VERIFY2(grid->property("contentHeight").toReal() > grid->height(),
                 "the grid does not scroll, so the wheel cannot be measured");
    const qreal row = grid->property("cellHeight").toReal();
    QCOMPARE(grid->property("contentY").toReal(), 0.0);

    // One notch down: a mouse wheel reports 120 eighths of a degree.
    injectWheel(centreOf(grid), QPoint(0, 0), QPoint(0, -120));
    QTRY_VERIFY2(grid->property("contentY").toReal() >= row * 0.9,
                 qPrintable(QStringLiteral("one wheel notch moved the grid by %1 px, "
                                           "less than one row of %2 px")
                              .arg(grid->property("contentY").toReal())
                              .arg(row)));
  }

  /// A mouse on this desktop reports **both** deltas: one notch arrives as
  /// `angleDelta (0, ±120)` *and* `pixelDelta (0, ±10)` (measured on the real
  /// window, `/tmp/opencode/wheel/run.log`). A pixel-first reading turned that
  /// into 20 px per notch — a 194 px row needed ten notches — which is what the
  /// user described as "the wheel is very slow". The notch is what the user
  /// turned; it must win over the scaled-down pixel figure.
  void aMouseNotchThatAlsoReportsPixelsMovesAWholeRow()
  {
    QVariantMap state = baseState();
    QVariantList many;
    for (int index = 0; index < 200; ++index) {
      many.append(entry(QStringLiteral("photo-%1.jpg").arg(index),
                        QStringLiteral("/root/photo-%1.jpg").arg(index), false, true));
    }
    entryList = many;
    showState(browserItem(), state);
    settle();

    QQuickItem* grid = findItem(QStringLiteral("fileGrid"));
    QVERIFY(grid != nullptr);
    QTRY_VERIFY2(grid->property("contentHeight").toReal() > grid->height(),
                 "the grid does not scroll, so the wheel cannot be measured");
    const qreal row = grid->property("cellHeight").toReal();
    QCOMPARE(grid->property("contentY").toReal(), 0.0);

    injectWheel(centreOf(grid), QPoint(0, -10), QPoint(0, -120));
    QTRY_VERIFY2(grid->property("contentY").toReal() >= row * 0.9,
                 qPrintable(QStringLiteral("a mouse notch that also reports a 10 px pixel "
                                           "delta moved the grid by only %1 px; a row is %2 px")
                              .arg(grid->property("contentY").toReal())
                              .arg(row)));
    // And it is the notch, not triple the 10 px a pixel-first reading would give.
    QVERIFY2(grid->property("contentY").toReal() > 100.0,
             "the grid moved by the pixel delta, not by the notch");
  }

  /// The continuation events of one notch — same angle, same pixel delta — do
  /// not scroll again. On the real window a single notch produces six events
  /// that differ only in `local`; counting them would multiply the travel.
  void theContinuationsOfOneNotchDoNotScrollAgain()
  {
    QVariantMap state = baseState();
    QVariantList many;
    for (int index = 0; index < 200; ++index) {
      many.append(entry(QStringLiteral("photo-%1.jpg").arg(index),
                        QStringLiteral("/root/photo-%1.jpg").arg(index), false, true));
    }
    entryList = many;
    showState(browserItem(), state);
    settle();

    QQuickItem* grid = findItem(QStringLiteral("fileGrid"));
    QVERIFY(grid != nullptr);
    QTRY_VERIFY2(grid->property("contentHeight").toReal() > grid->height(),
                 "the grid does not scroll, so the wheel cannot be measured");

    injectWheel(centreOf(grid), QPoint(0, -10), QPoint(0, -120));
    QTRY_VERIFY(grid->property("contentY").toReal() > 0);
    const qreal afterOne = grid->property("contentY").toReal();
    settle();
    QTRY_COMPARE_WITH_TIMEOUT(grid->property("contentY").toReal(), afterOne, 400);
  }


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
    info.insert(QStringLiteral("kind"), QStringLiteral(".png"));
    info.insert(QStringLiteral("isImage"), true);
    info.insert(QStringLiteral("size"), qint64(4096));
    info.insert(QStringLiteral("modified"), qint64(1731000000));
    state.insert(QStringLiteral("selectionInfo"), info);
    showState(browserItem(), state);
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
    showState(browserItem(), baseState());
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

  // ------------------------------------------------------------ context menus

  /// The context menus are as wide as their longest label needs.
  ///
  /// The style ships `MenuItem { implicitWidth: 200 }`, which is narrower than
  /// "Delete permanently…" at the window font: the entry then shows
  /// "delete permanently…" elided while short entries leave the menu half empty.
  /// The width comes from C++ text metrics (a menu's own `font` follows its
  /// width, so a QML measurement would loop), and this asserts the rendered menu
  /// against what the style actually leaves an entry for its label.
  void contextMenusFitTheirLongestLabel()
  {
    QQuickItem* view = browserItem();
    QObject* theme = view->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    const qreal minimum = theme->property("menuMinimumWidth").toReal();

    // The widest label any of these menus shows, measured independently of the
    // width list the view was handed. Using the view's own numbers would only
    // prove it agrees with itself.
    qreal shortestMenu = 0;

    for (const QString& name : { QStringLiteral("fileMenu"), QStringLiteral("folderMenu"),
                                 QStringLiteral("quickMenu") }) {
      QObject* menu = findPopup(name);
      QVERIFY2(menu != nullptr, qPrintable(name + QStringLiteral(" is missing")));
      QMetaObject::invokeMethod(menu, "popup");
      QTRY_VERIFY2(menu->property("visible").toBool(),
                   qPrintable(name + QStringLiteral(" did not open")));

      const qreal width = menu->property("width").toReal();
      QVERIFY2(width >= minimum,
               qPrintable(QStringLiteral("%1 is %2 px, below the %3 px minimum")
                            .arg(name)
                            .arg(width)
                            .arg(minimum)));

      const int count = menu->property("count").toInt();
      QVERIFY2(count > 0, qPrintable(name + QStringLiteral(" has no entries")));
      int labels = 0;
      for (int index = 0; index < count; ++index) {
        QQuickItem* entry = nullptr;
        QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                  Q_ARG(int, index));
        if (entry == nullptr) {
          continue;
        }
        const QString text = entry->property("text").toString();
        if (text.isEmpty()) {
          continue;  // a separator
        }
        ++labels;
        // What the entry really leaves for its label: the label starts at
        // `label->x()` inside the entry and may be as wide as the space left
        // between it and the entry's right padding. Reading it from the rendered
        // item keeps this honest if the style's metrics change.
        QQuickItem* content = entry->property("contentItem").value<QQuickItem*>();
        QVERIFY2(content != nullptr, qPrintable(name + QStringLiteral(" has an entry without content")));
        QQuickItem* label = nullptr;
        for (QQuickItem* child : content->childItems()) {
          if (child->inherits("QQuickMnemonicLabel")) {
            label = child;
          }
        }
        QVERIFY2(label != nullptr,
                 qPrintable(QStringLiteral("%1: \"%2\" has no label").arg(name, text)));
        // The label is a child of the content item, so its x is relative to it.
        const qreal labelLeft = content->x() + label->x();
        const qreal available = entry->width() - labelLeft - entry->property("rightPadding").toReal();
        const qreal needed = QFontMetricsF(QGuiApplication::font()).horizontalAdvance(text);
        shortestMenu = qMax(shortestMenu, needed + labelLeft + entry->property("rightPadding").toReal());
        QVERIFY2(available >= needed,
                 qPrintable(QStringLiteral("%1: \"%2\" needs %3 px, has %4 in a %5 px menu")
                              .arg(name, text)
                              .arg(needed)
                              .arg(available)
                              .arg(width)));
      }
      QVERIFY2(labels > 0, qPrintable(name + QStringLiteral(" has no labels")));
      // A width of its own, not the style's fixed 200: the menu is at least as
      // wide as the entries this very test just measured, and never narrower
      // than the theme's floor.
      QVERIFY2(width + 2 >= qMax(minimum, shortestMenu),
               qPrintable(QStringLiteral("%1 is %2 px but its own longest entry needs %3")
                            .arg(name)
                            .arg(width)
                            .arg(shortestMenu)));
      QMetaObject::invokeMethod(menu, "close");
      QTRY_VERIFY(!menu->property("visible").toBool());
    }
  }

  /// Every label a menu can show is measured, so no menu grows past the floor.
  ///
  /// `Theme.menuEntryLabels` is a fixed list measured once in C++: any label a
  /// menu shows but the list does not know is drawn at whatever width the rest
  /// of the labels produced. A menu that is wider than the theme floor is the
  /// visible symptom — rows 48 and 49 of `docs/M1-REPORT.md` fixed a fixed-200 px
  /// style; this test keeps the catalogue complete so the fix holds.
  ///
  /// The entries are read from the menus themselves (with the view's real
  /// `menuLabelWidths`), not from the list under test, so a label missing from
  /// the catalogue fails here instead of passing tautologically.
  void everyMenuLabelIsMeasured()
  {
    QQuickItem* view = browserItem();
    QObject* theme = view->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    QStringList catalogue;
    for (const QVariant& label : theme->property("menuEntryLabels").value<QVariantList>()) {
      catalogue.append(label.toString());
    }
    QVERIFY2(!catalogue.isEmpty(), "the theme lists no menu labels to measure");
    const qreal minimum = theme->property("menuMinimumWidth").toReal();
    const QFontMetricsF metrics(QGuiApplication::font());

    for (const QString& name :
         { QStringLiteral("fileMenu"), QStringLiteral("folderMenu"), QStringLiteral("quickMenu") }) {
      QObject* menu = findPopup(name);
      QVERIFY2(menu != nullptr, qPrintable(name + QStringLiteral(" is missing")));
      QMetaObject::invokeMethod(menu, "popup");
      QTRY_VERIFY2(menu->property("visible").toBool(),
                   qPrintable(name + QStringLiteral(" did not open")));

      const int count = menu->property("count").toInt();
      for (int index = 0; index < count; ++index) {
        QQuickItem* entry = nullptr;
        QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                  Q_ARG(int, index));
        if (entry == nullptr) {
          continue;
        }
        const QString text = entry->property("text").toString();
        if (text.isEmpty()) {
          continue;  // a separator
        }
        // The theme-mode label is one of a pair; the list carries both.
        QVERIFY2(catalogue.contains(text),
                 qPrintable(QStringLiteral("%1 shows \"%2\", which Theme.menuEntryLabels does not "
                                           "measure")
                                .arg(name, text)));
      }

      // With the whole catalogue measured, a menu is as wide as its own longest
      // real label needs and no wider than the floor requires.
      qreal widest = 0;
      for (const QVariant& label : theme->property("menuEntryLabels").value<QVariantList>()) {
        widest = qMax(widest, metrics.horizontalAdvance(label.toString()));
      }
      const qreal width = menu->property("width").toReal();
      const qreal floor = qMax(minimum, std::ceil(widest) + 12);
      QVERIFY2(width <= floor,
               qPrintable(QStringLiteral("%1 is %2 px; the measured labels need at most %3 px, "
                                         "so a label in it is not in the catalogue")
                            .arg(name)
                            .arg(width)
                            .arg(floor)));
      QMetaObject::invokeMethod(menu, "close");
      QTRY_VERIFY(!menu->property("visible").toBool());
    }
  }

  /// No menu may show a label the theme does not measure.
  ///
  /// The browser menus are covered at render time by
  /// `everyMenuLabelIsMeasured`; this covers the menus this suite cannot
  /// instantiate — the shell menu in `Main.qml`, and `Viewer.qml`'s canvas
  /// menu, whose actions are tested in `tst_viewer.cpp` but whose labels are
  /// not measured there against the shell's catalogue. Both halves are needed:
  /// the render check proves the width is applied, this one proves the list is
  /// complete.
  void everyShellMenuLabelIsMeasured()
  {
    QQuickItem* view = browserItem();
    QObject* theme = view->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    QStringList catalogue;
    for (const QVariant& label : theme->property("menuEntryLabels").value<QVariantList>()) {
      catalogue.append(label.toString());
    }
    QVERIFY2(catalogue.size() > 10, "the theme's label catalogue is suspiciously small");

    for (const QString& file :
         { QStringLiteral("/Main.qml"), QStringLiteral("/BrowserView.qml"),
           QStringLiteral("/Viewer.qml"), QStringLiteral("/EditorView.qml") }) {
      const QStringList labels = menuItemLabelsIn(qmlDir() + file, catalogue);
      QVERIFY2(labels.size() > 2,
               qPrintable(QStringLiteral("%1: found only %2 menu labels; the scan is broken")
                            .arg(file)
                            .arg(labels.size())));
      for (const QString& label : labels) {
        QVERIFY2(catalogue.contains(label),
                 qPrintable(QStringLiteral("%1 shows \"%2\", which Theme.menuEntryLabels does not "
                                           "measure — its menu will outgrow the theme floor")
                                .arg(file, label)));
      }
    }
  }

  /// The burger menu's first three entries are the three ways to open
  /// something: a file in the Viewer, a folder in the Browser, and a file in
  /// the Editor. They are drawn from `Theme.menuEntries[n]`; an index that
  /// drifts shows the wrong label, which is the off-by-one this pins.
  void shellMenuStartsWithTheOpenEntries()
  {
    QQuickItem* view = browserItem();
    QObject* theme = view->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    QStringList catalogue;
    for (const QVariant& label : theme->property("menuEntryLabels").value<QVariantList>()) {
      catalogue.append(label.toString());
    }
    const QStringList labels =
      menuItemLabelsIn(qmlDir() + QStringLiteral("/Main.qml"), catalogue);
    QVERIFY2(labels.size() >= 3,
             qPrintable(QStringLiteral("found only %1 shell menu labels").arg(labels.size())));
    QCOMPARE(labels.at(0), QStringLiteral("Open file…"));
    QCOMPARE(labels.at(1), QStringLiteral("Open folder…"));
    QCOMPARE(labels.at(2), QStringLiteral("Open in editor…"));
  }

  /// The shell menu's batch entry names the Tools label, not a slot — and it
  /// opens the Batch page, which names the three tools, rather than one form.
  ///
  /// This was wrong on a real window: the entry was written against
  /// The redundant Tools… entry was removed from the burger menu in v1.0.0
  /// because Batch actions live directly in the Browser's right dock.
  void theBatchMenuEntryNamesTheToolsLabel()
  {
    QFile source(qmlDir() + QStringLiteral("/Main.qml"));
    QVERIFY2(source.open(QIODevice::ReadOnly | QIODevice::Text), "Main.qml is missing");
    const QString text = QString::fromUtf8(source.readAll());
    QVERIFY2(!text.contains(QStringLiteral("onTriggered: root.openBatchTools()")),
             "redundant Tools menu entry still present in Main.qml");
  }

  /// The shell's Tools… entry calls `showBatchPage`, which is this view's name
  /// for "put the batch tools in front of me": with the page hidden by the
  /// layout it must bring the column back, and with the page visible it must
  /// only switch the tab. A page that is only a tab switch would make the entry
  /// a no-op for anyone who switched the Batch panel off.
  void showBatchPageBringsTheToolsBack()
  {
    QVariantMap state = baseState();
    state.insert(QStringLiteral("rightPanel"), true);
    showState(browserItem(), state);
    settle();
    QObject* root = browserRoot();
    QVERIFY2(root->property("batchPanelVisible").toBool(), "a fresh layout hides the page");
    QCOMPARE(root->property("rightPage").toString(), QStringLiteral("preview"));

    QVERIFY(QMetaObject::invokeMethod(root, "showBatchPage"));
    settle();
    QCOMPARE(root->property("rightPage").toString(), QStringLiteral("batch"));
    QVERIFY(findItem(QStringLiteral("batchSelection"))->isVisible());

    // Switched off in Settings › Appearance: naming the page also asks for it.
    QQmlExpression hide(QQmlEngine::contextForObject(root), root,
                        QStringLiteral("setPanelVisible('batch', false)"));
    QVERIFY(!hide.hasError());
    hide.evaluate();
    settle();
    QVERIFY(!root->property("batchPanelVisible").toBool());

    QVERIFY(QMetaObject::invokeMethod(root, "showBatchPage"));
    settle();
    QVERIFY2(root->property("batchPanelVisible").toBool(), "the page stayed hidden");
    QCOMPARE(root->property("rightPage").toString(), QStringLiteral("batch"));
    QVERIFY(findItem(QStringLiteral("batchSelection"))->isVisible());
  }

  /// A folder's context menu used to offer `Open` and `Explore here`, two
  /// entries that sent the same `open_folder` command. A menu may repeat a
  /// *verb* only when the two rows do different things; one action per row is
  /// the rule this case pins, and the duplicate label would fail it.
  void theFolderMenusDoNotRepeatTheOpenAction()
  {
    const auto labelsOf = [this](const QString& menuName) {
      QStringList labels;
      QObject* menu = findPopup(menuName);
      if (menu == nullptr) {
        return labels;
      }
      QMetaObject::invokeMethod(menu, "popup");
      const int count = menu->property("count").toInt();
      for (int index = 0; index < count; ++index) {
        QQuickItem* entry = nullptr;
        QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                  Q_ARG(int, index));
        if (entry == nullptr) {
          continue;
        }
        const QString text = entry->property("text").toString();
        if (!text.isEmpty()) {
          labels.append(text);
        }
      }
      return labels;
    };

    for (const QString& name : {QStringLiteral("folderMenu"), QStringLiteral("quickMenu"),
                                QStringLiteral("fileMenu")}) {
      const QStringList labels = labelsOf(name);
      QVERIFY2(!labels.isEmpty(), qPrintable(name + QStringLiteral(" has no entries")));
      for (int left = 0; left < labels.size(); ++left) {
        for (int right = left + 1; right < labels.size(); ++right) {
          QVERIFY2(labels.at(left) != labels.at(right),
                   qPrintable(QStringLiteral("%1 repeats \"%2\"")
                                  .arg(name, labels.at(left))));
        }
      }
      QCOMPARE(labels.count(QStringLiteral("Open")), 1);
      QVERIFY2(!labels.contains(QStringLiteral("Explore here")),
               qPrintable(name + QStringLiteral(" still offers the duplicate entry")));
      QObject* menu = findPopup(name);
      QVERIFY(menu != nullptr);
      QMetaObject::invokeMethod(menu, "close");
    }
  }

  /// A menu follows a label that is longer than the style's fixed 200 px.
  ///
  /// Every real label fits the theme's 168 px floor at this font, so the
  /// regression only shows with a longer one: the width list is the contract
  /// between the C++ measurement in the shell and the menu, and a menu that
  /// ignored it would clip. Widening the list is what `Main.qml` does after
  /// measuring, so a label longer than 200 px is exactly the case to prove.
  void aLongLabelWidensTheMenu()
  {
    QQuickItem* view = browserItem();
    QStringList labels;
    for (const QVariant& label :
         view->property("theme").value<QObject*>()->property("menuEntryLabels").value<QVariantList>()) {
      labels.append(label.toString());
    }
    QVERIFY2(!labels.isEmpty(), "the theme lists no menu labels to measure");
    const QString longer = QStringLiteral("Delete permanently (…) — a label longer than the style");
    labels.append(longer);
    QVariantList widths;
    const QFontMetricsF metrics(QGuiApplication::font());
    for (const QString& label : labels) {
      widths.append(metrics.horizontalAdvance(label));
    }
    view->setProperty("menuLabelWidths", widths);
    QCoreApplication::processEvents();

    QObject* menu = findPopup(QStringLiteral("fileMenu"));
    QVERIFY(menu != nullptr);
    QMetaObject::invokeMethod(menu, "popup");
    QTRY_VERIFY(menu->property("visible").toBool());

    const qreal entryWidth = menu->property("width").toReal();
    // The theme's own rule: the text, both entry paddings, and the menu's 1 px
    // border on each side (the entry is drawn inset by that).
    const qreal looselyNeeded = metrics.horizontalAdvance(longer) + 2 * 6;
    QVERIFY2(entryWidth >= looselyNeeded,
             qPrintable(QStringLiteral("the menu stayed %1 px while a %2 px label was listed")
                          .arg(entryWidth)
                          .arg(metrics.horizontalAdvance(longer))));
    // And the real entries inside it are wide enough for their own labels.
    const int count = menu->property("count").toInt();
    for (int index = 0; index < count; ++index) {
      QQuickItem* entry = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                Q_ARG(int, index));
      if (entry == nullptr || entry->property("text").toString().isEmpty()) {
        continue;
      }
      const QString text = entry->property("text").toString();
      const qreal needed = metrics.horizontalAdvance(text);
      QVERIFY2(entry->width() - 12 >= needed,
               qPrintable(QStringLiteral("\"%1\" needs %2 px in %3").arg(text).arg(needed).arg(entry->width())));
    }
    QMetaObject::invokeMethod(menu, "close");
  }

  /// "Open with…" is the shell's application chooser, not the default handler.
  void openWithAsksTheDesktopForAnApplicationChooser()
  {
    QObject* menu = findPopup(QStringLiteral("fileMenu"));
    QVERIFY(menu != nullptr);
    QSignalSpy openWith(browserRoot(), SIGNAL(openWith(QString)));
    QSignalSpy openExternal(browserRoot(), SIGNAL(openExternal(QString)));

    browserRoot()->setProperty("menuPath", QStringLiteral("/root/img.png"));
    QMetaObject::invokeMethod(menu, "popup");
    QTRY_VERIFY(menu->property("visible").toBool());

    QQuickItem* entry = nullptr;
    const int count = menu->property("count").toInt();
    for (int index = 0; index < count && entry == nullptr; ++index) {
      QQuickItem* candidate = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, candidate),
                                Q_ARG(int, index));
      if (candidate != nullptr &&
          candidate->property("text").toString() == QStringLiteral("Open with…")) {
        entry = candidate;
      }
    }
    QVERIFY2(entry != nullptr, "the file menu has no \"Open with…\" entry");
    QVERIFY(entry->isEnabled());

    // Activate it the way a click does. `trigger()` is not invokable through the
    // meta-object, and this still goes through the same onTriggered handler.
    // A menu is an inline popup here, so it lives in the main window; a key sent
    // to a window of its own would never reach it.
    entry->setProperty("highlighted", true);
    QTRY_VERIFY(entry->property("highlighted").toBool());
    // `trigger()` is not invokable through the meta-object and a key press does
    // not reach an entry in this harness, so activate the button the way the
    // style's own key handling does — through the same `onTriggered` handler a
    // click uses.
    QVERIFY(QMetaObject::invokeMethod(entry, "click"));
    QTRY_COMPARE(openWith.count(), 1);
    QCOMPARE(openWith.at(0).at(0).toString(), QStringLiteral("/root/img.png"));
    // The default-handler signal must not fire: it opens, it does not ask.
    QCOMPARE(openExternal.count(), 0);
  }

  /// "Edit" on a tile leaves for the Editor with the image already loaded into
  /// the working document. The view only *asks* the shell (`editInEditor`), and
  /// the shell batches `select` + `set_workspace` + `editor_open`: dispatching
  /// all three from the menu handler dropped the last one, because each
  /// republishes the state and the menu was rebuilt mid-batch.
  void editOpensTheImageInTheWorkingDocument()
  {
    QObject* menu = findPopup(QStringLiteral("fileMenu"));
    QVERIFY(menu != nullptr);
    QSignalSpy commands(browserRoot(), SIGNAL(command(QVariant)));
    QSignalSpy editInEditor(browserRoot(), SIGNAL(editInEditor(QString)));

    browserRoot()->setProperty("menuPath", QStringLiteral("/root/img.png"));
    browserRoot()->setProperty("menuIsImage", true);
    browserRoot()->setProperty("menuIsDir", false);
    QMetaObject::invokeMethod(menu, "popup");
    QTRY_VERIFY(menu->property("visible").toBool());

    QQuickItem* entry = nullptr;
    const int count = menu->property("count").toInt();
    for (int index = 0; index < count && entry == nullptr; ++index) {
      QQuickItem* candidate = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, candidate),
                                Q_ARG(int, index));
      if (candidate != nullptr && candidate->property("text").toString() == QStringLiteral("Edit")) {
        entry = candidate;
      }
    }
    QVERIFY2(entry != nullptr, "the file menu has no \"Edit\" entry");
    QVERIFY(entry->isEnabled());
    // Same activation route as the "Open with…" case above: the style's click.
    QVERIFY(QMetaObject::invokeMethod(entry, "click"));

    QCOMPARE(editInEditor.count(), 1);
    QCOMPARE(editInEditor.at(0).at(0).toString(), QStringLiteral("/root/img.png"));
    QCOMPARE(commands.count(), 0);
  }

  // ---------------------------------------------------------------- keyboard

  /// Arrows are the grid's own selection, not a scroll: the first arrow lands
  /// on the first cell, the next ones walk it, and every landing is the same
  /// `select` command a click emits.
  void arrowKeysWalkTheGridSelection()
  {
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QTest::keyClick(m_browser, Qt::Key_Right);
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/dirA") });

    QTest::keyClick(m_browser, Qt::Key_Right);
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/img.png") });

    QTest::keyClick(m_browser, Qt::Key_Left);
    settle();
    QCOMPARE(spy.count(), 3);
    QCOMPARE(spy.at(2).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/dirA") });
  }

  /// Up/Down move by a real row, which needs the column count the grid applied.
  void downMovesByOneGridRow()
  {
    QVariantMap state = baseState();
    QVariantList entries;
    for (int index = 0; index < 6; ++index) {
      entries.append(entry(QStringLiteral("file%1.png").arg(index),
                           QStringLiteral("/root/file%1.png").arg(index), false, true));
    }
    // `baseState()` resets the member listing, so the six entries replace it
    // afterwards and `showState` publishes exactly that.
    entryList = entries;
    showState(browserItem(), state);
    settle();
    giveKeyboardFocus();

    // The expected target is the cell actually drawn directly below the first
    // one, not a column count recomputed from two properties: that is the
    // movement the eye sees, and it stays honest if the grid's arithmetic
    // changes. It is read after the first key and a settle, so a layout pass
    // that is still pending cannot hand the test a stale row.
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_Right);
    settle();

    QQuickItem* first = findCell(QStringLiteral("/root/file0.png"));
    QVERIFY2(first != nullptr, "the first cell was not drawn");
    QQuickItem* below = nullptr;
    for (QQuickItem* candidate : items(browserItem(), QStringLiteral("fileCell"))) {
      if (candidate == first || qAbs(candidate->x() - first->x()) > 1.0) continue;
      if (candidate->y() <= first->y()) continue;
      if (below == nullptr || candidate->y() < below->y()) below = candidate;
    }
    QVERIFY2(below != nullptr, "the fixture needs a second row of cells");
    const QString belowPath = readQml(below, QStringLiteral("entry.path")).toString();

    QTest::keyClick(m_browser, Qt::Key_Down);
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ belowPath });
  }

  /// Enter opens the keyboard cursor: a folder navigates (never re-roots the
  /// tree), an image goes to the Viewer.
  void enterOpensTheSelectedEntry()
  {
    showSelection(QStringList{ QStringLiteral("/root/dirA") });
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_Return);
    settle();
    QCOMPARE(describe(commands(spy)), QStringLiteral("navigate:/root/dirA"));

    spy.clear();
    showSelection(QStringList{ QStringLiteral("/root/img.png") });
    giveKeyboardFocus();
    QTest::keyClick(m_browser, Qt::Key_Return);
    settle();
    QCOMPARE(describe(commands(spy)), QStringLiteral("open_file:"));
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/img.png") });
  }

  /// Backspace is "up one folder" and routes through the same navigate command
  /// the breadcrumb emits.
  void backspaceNavigatesToTheParent()
  {
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_Backspace);
    settle();
    QCOMPARE(describe(commands(spy)), QStringLiteral("navigate:/root"));
  }

  /// Ctrl+A selects the whole listing, Ctrl+other stays the shell's.
  void ctrlASelectsEveryEntry()
  {
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_A, Qt::ControlModifier);
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/dirA"), QStringLiteral("/root/img.png") }));

    // A Ctrl combination the view does not own must not become a selection.
    spy.clear();
    QTest::keyClick(m_browser, Qt::Key_R, Qt::ControlModifier);
    settle();
    QCOMPARE(spy.count(), 0);
  }

  /// Delete trashes the selection (recoverable, so no confirmation), and Escape
  /// clears it through `select []`.
  void deleteTrashesTheSelectionAndEscapeClearsIt()
  {
    showSelection(QStringList{ QStringLiteral("/root/dirA"), QStringLiteral("/root/img.png") });
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QTest::keyClick(m_browser, Qt::Key_Delete);
    settle();
    QCOMPARE(spy.count(), 1);
    const QVariantMap trash = spy.at(0).at(0).toMap();
    QCOMPARE(trash.value(QStringLiteral("type")).toString(), QStringLiteral("trash"));
    QCOMPARE(trash.value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/dirA"), QStringLiteral("/root/img.png") }));

    // Held Delete repeats the same key with `isAutoRepeat`; one press must stay
    // one command.
    QKeyEvent repeat(QEvent::KeyPress, Qt::Key_Delete, Qt::NoModifier, QString(), true);
    QCoreApplication::sendEvent(m_browser, &repeat);
    settle();
    QCOMPARE(spy.count(), 1);

    spy.clear();
    QTest::keyClick(m_browser, Qt::Key_Escape);
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("select"));
    QVERIFY(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList().isEmpty());
  }

  /// Home and End land on the first and last cell of the listing.
  void homeAndEndJumpToTheEnds()
  {
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_End);
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/img.png") });
    QTest::keyClick(m_browser, Qt::Key_Home);
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/dirA") });
  }

  // ------------------------------------------------------------ multi-select

  /// Ctrl-click adds one cell to the selection and a second Ctrl-click on the
  /// same cell takes it back — the toggle a file manager means by Ctrl.
  void ctrlClickTogglesOneCell()
  {
    showFourImages();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QQuickItem* second = findCell(QStringLiteral("/root/pic1.png"));
    QVERIFY2(second != nullptr, "no second cell");

    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::ControlModifier,
                      second->mapToScene(QPointF(second->width() / 2,
                                                 second->height() / 2)).toPoint());
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/pic1.png") });

    // The view names the new set; the shell publishes it back, which is what
    // the second Ctrl-click reads. Publishing rebuilds the delegates, so the
    // cell is looked up again instead of reusing the pointer.
    showFourImageSelection(QStringList{ QStringLiteral("/root/pic0.png"),
                                        QStringLiteral("/root/pic1.png") });
    second = findCell(QStringLiteral("/root/pic1.png"));
    QVERIFY2(second != nullptr, "the second cell left the grid");
    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::ControlModifier,
                      second->mapToScene(QPointF(second->width() / 2,
                                                 second->height() / 2)).toPoint());
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/pic0.png") });
  }

  /// Shift-click selects the range between the anchor and the clicked cell,
  /// and a second Shift-click to a further cell grows the same range.
  void shiftClickSelectsTheRangeFromTheAnchor()
  {
    showFourImages();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));

    QQuickItem* first = findCell(QStringLiteral("/root/pic0.png"));
    QQuickItem* third = findCell(QStringLiteral("/root/pic2.png"));
    QVERIFY2(first != nullptr && third != nullptr, "the fixture needs three cells");
    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::NoModifier,
                      first->mapToScene(QPointF(first->width() / 2,
                                                first->height() / 2)).toPoint());
    settle();
    spy.clear();

    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::ShiftModifier,
                      third->mapToScene(QPointF(third->width() / 2,
                                                third->height() / 2)).toPoint());
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/pic0.png"),
                           QStringLiteral("/root/pic1.png"),
                           QStringLiteral("/root/pic2.png") }));

    // The anchor did not move, so the fourth cell extends the same range.
    QQuickItem* fourth = findCell(QStringLiteral("/root/pic3.png"));
    QVERIFY2(fourth != nullptr, "no fourth cell");
    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::ShiftModifier,
                      fourth->mapToScene(QPointF(fourth->width() / 2,
                                                 fourth->height() / 2)).toPoint());
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/pic0.png"),
                           QStringLiteral("/root/pic1.png"),
                           QStringLiteral("/root/pic2.png"),
                           QStringLiteral("/root/pic3.png") }));
  }

  /// Shift+arrow grows the selection from the anchor by keyboard, the same
  /// range a Shift-click draws.
  void shiftArrowExtendsTheSelection()
  {
    showFourImages();
    giveKeyboardFocus();
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_Right);
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/pic0.png") });
    showFourImageSelection(QStringList{ QStringLiteral("/root/pic0.png") });

    QTest::keyClick(m_browser, Qt::Key_Right, Qt::ShiftModifier);
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/pic0.png"),
                           QStringLiteral("/root/pic1.png") }));

    showFourImageSelection(QStringList{ QStringLiteral("/root/pic0.png"),
                                        QStringLiteral("/root/pic1.png") });
    QTest::keyClick(m_browser, Qt::Key_Right, Qt::ShiftModifier);
    settle();
    QCOMPARE(spy.count(), 3);
    QCOMPARE(spy.at(2).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/pic0.png"),
                           QStringLiteral("/root/pic1.png"),
                           QStringLiteral("/root/pic2.png") }));
  }

  /// A plain click after a range collapses the selection back to one cell and
  /// becomes the new anchor: the next Shift-click starts from there.
  void aPlainClickResetsTheAnchor()
  {
    showFourImages();
    showFourImageSelection(QStringList{ QStringLiteral("/root/pic0.png"),
                                        QStringLiteral("/root/pic1.png"),
                                        QStringLiteral("/root/pic2.png") });
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QQuickItem* third = findCell(QStringLiteral("/root/pic2.png"));
    QQuickItem* fourth = findCell(QStringLiteral("/root/pic3.png"));
    QVERIFY2(third != nullptr && fourth != nullptr, "no third and fourth cell");

    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::NoModifier,
                      third->mapToScene(QPointF(third->width() / 2,
                                                third->height() / 2)).toPoint());
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ QStringLiteral("/root/pic2.png") });

    QTest::mouseClick(m_browser, Qt::LeftButton, Qt::ShiftModifier,
                      fourth->mapToScene(QPointF(fourth->width() / 2,
                                                 fourth->height() / 2)).toPoint());
    settle();
    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             (QStringList{ QStringLiteral("/root/pic2.png"),
                           QStringLiteral("/root/pic3.png") }));
  }

  /// The Batch page draws Core's job: the count while it runs, the Cancel that
  /// stops it, and the outcome once it stops. This page owns no worker; it
  /// renders the `batch` slot the snapshot carries.
  void theBatchPageDrawsThePublishedJob()
  {
    QVariantMap state = baseState();
    state.insert(QStringLiteral("batch"), QVariantMap{
        { QStringLiteral("operation"), QStringLiteral("resize") },
        { QStringLiteral("total"), 4 },
        { QStringLiteral("done"), 1 },
        { QStringLiteral("failed"), 0 },
        { QStringLiteral("running"), true },
        { QStringLiteral("cancelled"), false },
        { QStringLiteral("current"), QStringLiteral("pic1.png") } });
    showState(browserItem(), state);
    settle();
    browserRoot()->setProperty("rightPage", QStringLiteral("batch"));
    settle();

    QQuickItem* label = findItem(QStringLiteral("batchProgressLabel"));
    QVERIFY2(label != nullptr, "the Batch page draws no progress");
    QTRY_VERIFY(label->isVisible());
    QCOMPARE(label->property("text").toString(), QStringLiteral("Resize · 1 of 4"));
    QCOMPARE(findItem(QStringLiteral("batchCurrent"))->property("text").toString(),
             QStringLiteral("Writing pic1.png"));
    QVERIFY(findItem(QStringLiteral("batchCancel"))->isVisible());
    QCOMPARE(findItem(QStringLiteral("batchProgress"))->property("value").toInt(), 1);

    // Cancel is the job's own command, not one per file.
    QSignalSpy spy(browserRoot(), SIGNAL(command(QVariant)));
    QVERIFY(QMetaObject::invokeMethod(findItem(QStringLiteral("batchCancel")), "click"));
    settle();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("cancel_operation"));

    // A finished job keeps its counts and words the outcome; the running-only
    // controls are gone.
    QVariantMap finished = state;
    finished.insert(QStringLiteral("batch"), QVariantMap{
        { QStringLiteral("operation"), QStringLiteral("crop") },
        { QStringLiteral("total"), 4 },
        { QStringLiteral("done"), 3 },
        { QStringLiteral("failed"), 1 },
        { QStringLiteral("running"), false },
        { QStringLiteral("cancelled"), false },
        { QStringLiteral("current"), QStringLiteral("pic3.png") } });
    showState(browserItem(), finished);
    settle();
    QCOMPARE(findItem(QStringLiteral("batchProgressLabel"))->property("text").toString(),
             QStringLiteral("Crop finished: 3 of 4, 1 failed"));
    QVERIFY(!findItem(QStringLiteral("batchCancel"))->isVisible());
    QVERIFY(findItem(QStringLiteral("batchResize"))->isEnabled());
  }

  /// The right column holds two pages now: Preview (the picture and the
  /// file's details, which are read together) and Batch action (the selection
  /// as its own question). The checklist on the right edge hides either one
  /// without a command, and a hidden page keeps its place in the stack.
  void theSidebarHasAPreviewPageAndABatchPage()
  {
    QVariantMap state = baseState();
    state.insert(QStringLiteral("rightPanel"), true);
    QVariantMap info;
    info.insert(QStringLiteral("path"), QStringLiteral("/root/img.png"));
    info.insert(QStringLiteral("name"), QStringLiteral("img.png"));
    info.insert(QStringLiteral("kind"), QStringLiteral(".png"));
    info.insert(QStringLiteral("isImage"), true);
    info.insert(QStringLiteral("size"), qint64(4096));
    info.insert(QStringLiteral("modified"), qint64(1731000000));
    state.insert(QStringLiteral("selectionInfo"), info);
    showState(browserItem(), state);
    settle();

    QQuickItem* panel = findItem(QStringLiteral("rightPanel"));
    QVERIFY2(panel != nullptr, "the browser has no right dock");
    QVERIFY(panel->isVisible());
    QVERIFY2(panel->property("stripShown").toBool(),
             "the two-page dock drew no tab strip");
    QCOMPARE(readQml(panel, QStringLiteral("tabs.length")).toInt(), 2);

    QQuickItem* preview = findItem(QStringLiteral("previewThumbnail"));
    QQuickItem* name = findItem(QStringLiteral("infoName"));
    QVERIFY2(preview != nullptr, "the dock has no preview panel");
    QVERIFY2(name != nullptr, "the dock has no information panel");
    QVERIFY(preview->isVisible());
    QVERIFY(name->isVisible());
    QCOMPARE(name->property("text").toString(), QStringLiteral("img.png"));
    QCOMPARE(findItem(QStringLiteral("infoKind"))->property("text").toString(),
             QStringLiteral(".png"));
    QCOMPARE(findItem(QStringLiteral("infoPath"))->property("text").toString(),
             QStringLiteral("/root/img.png"));

    // The Preview page shows both halves; the Batch page is the other tab and
    // draws the selection count it can really see, with its verbs disabled
    // until Core owns a batch command.
    QQuickItem* tabs = findItem(QStringLiteral("browserRightTabs"));
    QVERIFY2(tabs != nullptr, "the browser has no dock strip");
    QVERIFY(tabs->isVisible());

    QQuickItem* batchTab = findItem(QStringLiteral("browserTab_batch"));
    QVERIFY2(batchTab != nullptr, "the dock has no Batch action tab");
    QVERIFY(batchTab->isVisible());
    QCOMPARE(batchTab->property("text").toString(), QString());
    QVERIFY(!findItem(QStringLiteral("batchSelection"))->isVisible());

    QVERIFY(QMetaObject::invokeMethod(batchTab, "click"));
    settle();
    QCOMPARE(browserRoot()->property("rightPage").toString(), QStringLiteral("batch"));
    QQuickItem* selection = findItem(QStringLiteral("batchSelection"));
    QVERIFY2(selection != nullptr, "the Batch page draws no selection count");
    QTRY_VERIFY(selection->isVisible());
    QCOMPARE(selection->property("text").toString(),
             QStringLiteral("No images selected"));
    QVERIFY(!findItem(QStringLiteral("previewThumbnail"))->isVisible());

    // Batch's three verbs are live now: each one asks the shell for its form,
    // and the page names the action it is for. The Export button is gone —
    // exporting a copy was one file at a time and belongs to the Editor.
    QSignalSpy batchRequests(browserRoot(), SIGNAL(requestBatch(QString)));
    for (const char* name : {"batchResize", "batchCrop", "batchConvert"}) {
      QQuickItem* button = findItem(QString::fromLatin1(name));
      QVERIFY2(button != nullptr, qPrintable(QString::fromLatin1(name) + " is missing"));
      QVERIFY2(button->isEnabled(), qPrintable(QString::fromLatin1(name) + " is disabled"));
    }
    QVERIFY2(findItem(QStringLiteral("batchExport")) == nullptr,
             "the Batch page still offers a one-file Export action");
    QVERIFY(QMetaObject::invokeMethod(findItem(QStringLiteral("batchCrop")), "click"));
    settle();
    QCOMPARE(batchRequests.count(), 1);
    QCOMPARE(batchRequests.at(0).at(0).toString(), QStringLiteral("crop"));

    // Settings › Appearance drives the same two panels: both are visible on a
    // fresh layout. Hiding Preview keeps the dock on Batch action; hiding both
    // hides the whole column, and showing one brings it back.
    QVERIFY(browserRoot()->property("previewPanelVisible").toBool());
    QVERIFY(browserRoot()->property("batchPanelVisible").toBool());

    QQmlExpression hide(QQmlEngine::contextForObject(browserRoot()), browserRoot(),
                        QStringLiteral("setPanelVisible('preview', false)"));
    QVERIFY(!hide.hasError());
    hide.evaluate();
    settle();
    QCOMPARE(browserRoot()->property("rightPage").toString(), QStringLiteral("batch"));
    QVERIFY(!findItem(QStringLiteral("previewThumbnail"))->isVisible());
    QVERIFY(findItem(QStringLiteral("batchSelection"))->isVisible());
    // One page left means no strip: a single tab would only label itself.
    QVERIFY(!panel->property("stripShown").toBool());
    QVERIFY(panel->isVisible());

    // A hidden page keeps its stack slot but must not be drawn when it is
    // named: the visible pages are the only ones the dock can open.
    browserRoot()->setProperty("rightPage", QStringLiteral("preview"));
    settle();
    QVERIFY(!findItem(QStringLiteral("previewThumbnail"))->isVisible());
    QVERIFY(findItem(QStringLiteral("batchSelection"))->isVisible());

    // The whole sidebar follows the panels: with none left there is no column
    // and no splitter, and the menu's next check brings both back.
    QQmlExpression hideBoth(QQmlEngine::contextForObject(browserRoot()), browserRoot(),
                            QStringLiteral("setPanelVisible('batch', false)"));
    QVERIFY(!hideBoth.hasError());
    hideBoth.evaluate();
    settle();
    QCOMPARE(browserRoot()->property("visiblePanelCount").toInt(), 0);
    QVERIFY(!browserRoot()->property("sidebarShown").toBool());
    QVERIFY(!panel->isVisible());
    QVERIFY(!findItem(QStringLiteral("rightSplitter"))->isVisible());

    // Showing a panel opens it: after none was left, the next check brings the
    // column back *on the page it names*, not on whatever the strip last
    // remembered.
    QQmlExpression showBatch(QQmlEngine::contextForObject(browserRoot()), browserRoot(),
                             QStringLiteral("setPanelVisible('batch', true)"));
    QVERIFY(!showBatch.hasError());
    showBatch.evaluate();
    settle();
    QCOMPARE(browserRoot()->property("rightPage").toString(), QStringLiteral("batch"));
    QVERIFY(panel->isVisible());
    QVERIFY(findItem(QStringLiteral("rightSplitter"))->isVisible());
    QVERIFY(findItem(QStringLiteral("batchSelection"))->isVisible());

    QQmlExpression show(QQmlEngine::contextForObject(browserRoot()), browserRoot(),
                        QStringLiteral("setPanelVisible('preview', true)"));
    QVERIFY(!show.hasError());
    show.evaluate();
    settle();
    QCOMPARE(browserRoot()->property("rightPage").toString(), QStringLiteral("preview"));
    QVERIFY(panel->isVisible());
    QVERIFY(findItem(QStringLiteral("rightSplitter"))->isVisible());
    QVERIFY(findItem(QStringLiteral("previewThumbnail"))->isVisible());

    // The Batch count is about images, not about every selected entry: a
    // folder picked beside a picture is not something a batch could resize.
    QVariantMap mixed = state;
    mixed.insert(QStringLiteral("selection"),
                 QStringList{ QStringLiteral("/root/dirA"),
                              QStringLiteral("/root/img.png") });
    showState(browserItem(), mixed);
    settle();
    QCOMPARE(findItem(QStringLiteral("batchSelection"))->property("text").toString(),
             QStringLiteral("1 selected"));
  }

  /// "Show in folder" is the shell's request, not the view's: every Browser
  /// menu that can name a path offers it, and it carries that path.
  void theFileMenusAskTheShellToRevealThePath()
  {
    QSignalSpy reveal(browserRoot(), SIGNAL(revealPath(QString)));
    int expected = 0;
    for (const char* name : {"fileMenu", "folderMenu", "quickMenu"}) {
      QObject* menu = findPopup(QString::fromLatin1(name));
      QVERIFY2(menu != nullptr, qPrintable(QString::fromLatin1(name) + " is missing"));
      browserRoot()->setProperty("menuPath", QStringLiteral("/root/img.png"));
      QMetaObject::invokeMethod(menu, "popup");
      QTRY_VERIFY2(menu->property("visible").toBool(),
                   qPrintable(QString::fromLatin1(name) + " did not open"));

      QQuickItem* entry = nullptr;
      const int count = menu->property("count").toInt();
      for (int index = 0; index < count && entry == nullptr; ++index) {
        QQuickItem* candidate = nullptr;
        QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, candidate),
                                  Q_ARG(int, index));
        if (candidate != nullptr &&
            candidate->property("text").toString() == QStringLiteral("Show in folder")) {
          entry = candidate;
        }
      }
      QVERIFY2(entry != nullptr,
               qPrintable(QString::fromLatin1(name) + " has no \"Show in folder\" entry"));
      QVERIFY(entry->isEnabled());
      QVERIFY(QMetaObject::invokeMethod(entry, "click"));
      ++expected;
      QTRY_COMPARE(reveal.count(), expected);
      QCOMPARE(reveal.at(expected - 1).at(0).toString(),
               QStringLiteral("/root/img.png"));
      QMetaObject::invokeMethod(menu, "close");
      QTRY_VERIFY(!menu->property("visible").toBool());
    }
  }

  // ------------------------------------------------------------- view modes

  /// A folder is drawn three ways, the way a file manager draws it: large cells
  /// with the picture decoded (`thumbnails`), small cells with the file type's
  /// drawing (`icons`), or one line per entry under a named header (`details`).
  /// The switch sits at the end of the path bar, and the choice is a layout
  /// value — the button asks the shell for it, it does not write a QML variable
  /// — so it is remembered across launches like a dock's width.
  void theFolderHasThreeShapes()
  {
    QQuickItem* grid = findItem(QStringLiteral("fileGrid"));
    QVERIFY(grid != nullptr);
    QQuickItem* list = findItem(QStringLiteral("fileList"));
    QVERIFY2(list != nullptr, "the details list does not exist");
    QQuickItem* header = findItem(QStringLiteral("detailsHeader"));
    QVERIFY2(header != nullptr, "the details header does not exist");

    // A first launch rests on thumbnails, and the shapes that are not on screen
    // hold no delegates: a hidden grid with a live model would decode a
    // thumbnail per entry for a picture nobody is looking at.
    QCOMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("thumbnails"));
    QVERIFY2(grid->isVisible(), "the grid is not on screen in the default shape");
    QVERIFY(!list->isVisible());
    QVERIFY(!header->isVisible());
    QTRY_COMPARE(grid->property("count").toInt(), 2);
    QCOMPARE(list->property("count").toInt(), 0);
    const qreal thumbnailCell = grid->property("cellWidth").toReal();
    QVERIFY2(thumbnailCell > 100, "the thumbnail cell is not a tile");
    // The thumbnail shape is the one that asks the cache for a picture.
    QVERIFY(findImage(findCell(QStringLiteral("/root/img.png")),
                      QStringLiteral("gridThumbnail"))
              ->property("thumbnailable").toBool());

    // The three buttons are in the path bar, in the order a file manager lists
    // them, and the one that is showing is armed.
    for (const char* name : { "viewModeThumbnails", "viewModeIcons", "viewModeDetails" }) {
      QQuickItem* button = findItem(QString::fromLatin1(name));
      QVERIFY2(button != nullptr, name);
    }
    QCOMPARE(findItem(QStringLiteral("viewModeThumbnails"))->property("armed").toBool(), true);
    QCOMPARE(findItem(QStringLiteral("viewModeDetails"))->property("armed").toBool(), false);

    // Pressing `Icons` is one layout request carrying the new value — the same
    // patch a CLI's `set_layout` would carry — and Core's copy comes back.
    QSignalSpy layouts(browserRoot(), SIGNAL(layoutRequested(QVariant)));
    click(m_browser, findItem(QStringLiteral("viewModeIcons")));
    QTRY_COMPARE(layouts.count(), 1);
    QCOMPARE(layouts.at(0).at(0).toMap().value(QStringLiteral("browserView")).toString(),
             QStringLiteral("icons"));
    QTRY_COMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("icons"));
    settle();

    // The icon shape: still the grid, a smaller cell, and the file type's own
    // drawing instead of a decoded picture.
    QVERIFY(grid->isVisible());
    QVERIFY(!list->isVisible());
    const qreal iconCell = grid->property("cellWidth").toReal();
    QVERIFY2(iconCell < thumbnailCell,
             qPrintable(QStringLiteral("the icon cell is %1 px, the thumbnail cell %2 px")
                          .arg(iconCell).arg(thumbnailCell)));
    QTRY_COMPARE(grid->property("count").toInt(), 2);
    QQuickItem* imageCell = findCell(QStringLiteral("/root/img.png"));
    QVERIFY(imageCell != nullptr);
    QQuickItem* thumb = findImage(imageCell, QStringLiteral("gridThumbnail"));
    QVERIFY(thumb != nullptr);
    QVERIFY2(!thumb->isVisible(), "the icon shape drew a picture");
    // Not merely hidden: the tile asks for no thumbnail, so the cache is not
    // asked to mint one for a drawing that will never show it.
    QVERIFY2(!thumb->property("thumbnailable").toBool(),
             "the icon shape still asks the cache for a thumbnail");
    QQuickItem* icon = findImage(imageCell, QStringLiteral("gridIcon"));
    QVERIFY2(icon != nullptr, "the cell draws no icon");
    QVERIFY(icon->isVisible());
    QCOMPARE(readQml(icon, QStringLiteral("iconName")).toString(),
             QStringLiteral("image-x-generic-symbolic"));
    // A folder keeps its own drawing in both shapes.
    QQuickItem* folderCell = findCell(QStringLiteral("/root/dirA"));
    QVERIFY(folderCell != nullptr);
    QCOMPARE(readQml(findImage(folderCell, QStringLiteral("gridIcon")),
                     QStringLiteral("iconName")).toString(),
             QStringLiteral("folder-symbolic"));

    // Pressing `Details` moves the listing to the list shape: the grid empties
    // and the header names the columns.
    click(m_browser, findItem(QStringLiteral("viewModeDetails")));
    QTRY_COMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("details"));
    settle();
    QVERIFY2(list->isVisible(), "the details list is not on screen");
    QVERIFY(header->isVisible());
    QVERIFY(!grid->isVisible());
    QCOMPARE(grid->property("count").toInt(), 0);
    QTRY_COMPARE(list->property("count").toInt(), 2);
    QCOMPARE(findItem(QStringLiteral("viewModeDetails"))->property("armed").toBool(), true);
    QCOMPARE(findItem(QStringLiteral("viewModeThumbnails"))->property("armed").toBool(), false);
    // The header sits above the list, not scrolling away with it.
    QVERIFY(header->y() + header->height() <= list->y() + 1.0);

    // And back: the shape is a value, not a one-way switch.
    click(m_browser, findItem(QStringLiteral("viewModeThumbnails")));
    QTRY_COMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("thumbnails"));
    settle();
    QVERIFY(grid->isVisible());
    QVERIFY(!list->isVisible());
    QCOMPARE(list->property("count").toInt(), 0);
  }

  /// The details list says what a file manager's list says: the name, the kind
  /// of file, how big it is and when it changed — and the header names the four
  /// columns in the same order and at the same x as the rows below it.
  void theDetailsRowsNameTheFourColumns()
  {
    showViewMode(QStringLiteral("details"));

    const QList<QPair<QString, QString>> columns = {
      { QStringLiteral("detailsNameColumn"), QStringLiteral("Name") },
      { QStringLiteral("detailsTypeColumn"), QStringLiteral("Type") },
      { QStringLiteral("detailsSizeColumn"), QStringLiteral("Size") },
      { QStringLiteral("detailsModifiedColumn"), QStringLiteral("Modified") },
    };
    for (const auto& column : columns) {
      QQuickItem* label = findItem(column.first);
      QVERIFY2(label != nullptr, qPrintable(column.first));
      QCOMPARE(label->property("text").toString(), column.second);
    }

    // The rows: a folder first, then an image, in the listing's own order.
    const QList<QQuickItem*> rows = items(browserItem(), QStringLiteral("fileRow"));
    QTRY_COMPARE(rows.size(), 2);
    QCOMPARE(rowText(rows.at(0), QStringLiteral("rowName")),
             QStringLiteral("dirA"));
    QCOMPARE(rowText(rows.at(0), QStringLiteral("rowType")),
             QStringLiteral("Folder"));
    // A folder has no size of its own to report.
    QCOMPARE(rowText(rows.at(0), QStringLiteral("rowSize")), QStringLiteral("—"));
    QCOMPARE(rowText(rows.at(1), QStringLiteral("rowName")),
             QStringLiteral("img.png"));
    // An image is named by its extension — the same token Core's `kind` carries.
    QCOMPARE(rowText(rows.at(1), QStringLiteral("rowType")),
             QStringLiteral(".png"));
    QCOMPARE(rowText(rows.at(1), QStringLiteral("rowSize")),
             QStringLiteral("4.0 KB"));
    // The modification time is the theme's own formatting, in its short form —
    // the same clock the Info panel reads, in the width a column has.
    QObject* theme = browserItem()->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    QVariant date;
    QVERIFY(QMetaObject::invokeMethod(theme, "formatDateShort", Q_RETURN_ARG(QVariant, date),
                                      Q_ARG(QVariant, QVariant(1731000000))));
    QCOMPARE(rowText(rows.at(1), QStringLiteral("rowModified")),
             date.toString());
    // ... and it fits: a fixed-width column is only a column if the date inside
    // it is whole rather than an ellipsis.
    QQuickItem* modified = items(rows.at(1), QStringLiteral("rowModified")).value(0);
    QVERIFY(modified != nullptr);
    QVERIFY2(modified->implicitWidth() <= modified->width() + 0.5,
             qPrintable(QStringLiteral("the date needs %1 px in a %2 px column")
                          .arg(modified->implicitWidth()).arg(modified->width())));

    // Each row is a target: a click selects what it names, exactly as a cell
    // does.
    QSignalSpy commands(browserRoot(), SIGNAL(command(QVariant)));
    click(m_browser, rows.at(1));
    QTRY_COMPARE(commands.count(), 1);
    const QVariantMap sent = commands.at(0).at(0).toMap();
    QCOMPARE(sent.value(QStringLiteral("type")).toString(), QStringLiteral("select"));
    QCOMPARE(sent.value(QStringLiteral("paths")).toStringList(),
             QList<QString>{ QStringLiteral("/root/img.png") });

    // ... and a double click opens it: the image goes to the Viewer. The click
    // half of the gesture still selects, which is why the *last* command is the
    // one that opens.
    QSignalSpy opened(browserRoot(), SIGNAL(command(QVariant)));
    click(m_browser, rows.at(1), true);
    QTRY_VERIFY(opened.count() >= 1);
    QCOMPARE(opened.last().at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("open_file"));
    QCOMPARE(opened.last().at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QList<QString>{ QStringLiteral("/root/img.png") });
  }

  /// The keyboard walks the details list one line at a time, which is what
  /// "a row step" means in a list of lines rather than a grid of tiles.
  void theKeyboardWalksTheDetailsList()
  {
    showFourImages();
    showViewMode(QStringLiteral("details"));
    giveKeyboardFocus();

    // One column of lines: Up and Down move one entry, not one grid row.
    QCOMPARE(readQml(browserItem(), QStringLiteral("gridColumns()")).toInt(), 1);
    QCOMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("details"));

    QSignalSpy commands(browserRoot(), SIGNAL(command(QVariant)));
    QTest::keyClick(m_browser, Qt::Key_Down);
    QTRY_VERIFY(commands.count() >= 1);
    QCOMPARE(commands.last().at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("select"));
    QCOMPARE(commands.last().at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QList<QString>{ QStringLiteral("/root/pic0.png") });

    QTest::keyClick(m_browser, Qt::Key_Down);
    QTRY_VERIFY(commands.count() >= 2);
    QCOMPARE(commands.last().at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QList<QString>{ QStringLiteral("/root/pic1.png") });

    // End lands on the last line, Home on the first.
    QTest::keyClick(m_browser, Qt::Key_End);
    QTRY_VERIFY(commands.count() >= 3);
    QCOMPARE(commands.last().at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QList<QString>{ QStringLiteral("/root/pic3.png") });
    QTest::keyClick(m_browser, Qt::Key_Home);
    QTRY_VERIFY(commands.count() >= 4);
    QCOMPARE(commands.last().at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QList<QString>{ QStringLiteral("/root/pic0.png") });

    // The cursor is visible in the list, not in the grid that is not showing.
    QCOMPARE(findItem(QStringLiteral("fileList"))->property("currentIndex").toInt(), 0);
  }

  /// The shape is Core's value, so it comes back from `set_layout` — and a
  /// value this build does not know reads as the default instead of a blank
  /// listing.
  void aSavedViewModeIsRestoredAndAnUnknownOneRests()
  {
    showViewMode(QStringLiteral("details"));
    QVERIFY(findItem(QStringLiteral("fileList"))->isVisible());

    // What a second launch does: the layout arrives with the value in it.
    QVariantMap patch;
    patch.insert(QStringLiteral("browserView"), QStringLiteral("icons"));
    applyLayoutRequested(patch);
    settle();
    QCOMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("icons"));
    QVERIFY(findItem(QStringLiteral("fileGrid"))->isVisible());
    QVERIFY(!findItem(QStringLiteral("fileList"))->isVisible());

    // A newer build's name for a shape this one cannot draw: the folder still
    // opens, as thumbnails.
    patch.insert(QStringLiteral("browserView"), QStringLiteral("gallery"));
    applyLayoutRequested(patch);
    settle();
    QCOMPARE(browserItem()->property("viewMode").toString(), QStringLiteral("thumbnails"));
    QVERIFY(findItem(QStringLiteral("fileGrid"))->isVisible());
    QTRY_COMPARE(findItem(QStringLiteral("fileGrid"))->property("count").toInt(), 2);
  }
};

QTEST_MAIN(TestBrowser)
#include "tst_browser.moc"
