// Viewer regression tests: canvas centring, pan, rotation, flip, cursor
// anchored zoom and the pointer-device gating of the wheel handler.
//
// The tests load the real `crates/desktop/qml/Viewer.qml` and assert on the
// transforms Qt Quick actually applies (`QQuickItem::mapToItem`), so a binding
// evaluated with the wrong zoom cannot slip through. Wheel events are injected
// through `QWindowSystemInterface`, the entry point the QPA plugins use for real
// input, with explicit device types: a touchpad that reports `pixelDelta` (what
// libinput/Wayland send for two-finger scrolling) and a mouse that reports
// `angleDelta`.

#include <QCoreApplication>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QPointingDevice>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickView>
#include <QTemporaryDir>
#include <QTest>

#include "stubthumbnailcache.h"

#include <qpa/qwindowsysteminterface.h>

namespace {
/// `Image.Ready`; spelled out so the wait below reads as what it is.
constexpr int KogaImageReady = 1;

constexpr int kViewWidth = 1280;
constexpr int kViewHeight = 820;
constexpr int kAllDevices = 0x7FFFFFFF;
constexpr int kMouseOnly = 0x0001;

QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}

} // namespace

class TestViewer : public QObject
{
  Q_OBJECT

private:
  QQmlEngine m_engine;
  QQuickView* m_view = nullptr;
  QObject* m_viewer = nullptr;
  QQuickItem* m_viewport = nullptr;
  QQuickItem* m_canvas = nullptr;
  QObject* m_wheelHandler = nullptr;
  QTemporaryDir m_fixtures;
  QString m_landscape;
  QString m_portrait;
  ulong m_timestamp = 1;

  QQuickItem* item(const char* name) const
  {
    return m_view->rootObject()->findChild<QQuickItem*>(QString::fromLatin1(name));
  }

  QObject* object(const char* name) const
  {
    return m_view->rootObject()->findChild<QObject*>(QString::fromLatin1(name));
  }

  /// Every item called `name`, walking the visual tree: ListView delegates are
  /// `childItems` of the view's content item, not `QObject` children of the
  /// view root, so `findChildren` would not see them.
  static void collect(QQuickItem* root, const QString& name, QList<QQuickItem*>* out)
  {
    if (root->objectName() == name) {
      out->append(root);
    }
    for (QQuickItem* child : root->childItems()) {
      collect(child, name, out);
    }
  }

  static QList<QQuickItem*> visualItems(QQuickItem* root, const QString& name)
  {
    QList<QQuickItem*> found;
    collect(root, name, &found);
    return found;
  }

  /// The filmstrip tile drawing `path`, or nullptr when it is not on screen.
  QQuickItem* stripTile(const QString& path) const
  {
    const QList<QQuickItem*> found =
      visualItems(m_view->rootObject(), QStringLiteral("stripThumbnail"));
    for (QQuickItem* candidate : found) {
      QQmlExpression reader(QQmlEngine::contextForObject(candidate), candidate,
                            QStringLiteral("modelData"));
      if (reader.evaluate().toString() == path) {
        return candidate;
      }
    }
    return nullptr;
  }

  /// Bounding box of the canvas in viewport coordinates, from the four mapped
  /// corners, so `scale`, `rotation` and the flip transform are all included.
  QRectF canvasRectInViewport() const
  {
    const QPointF corners[] = {
      m_canvas->mapToItem(m_viewport, QPointF(0, 0)),
      m_canvas->mapToItem(m_viewport, QPointF(m_canvas->width(), 0)),
      m_canvas->mapToItem(m_viewport, QPointF(0, m_canvas->height())),
      m_canvas->mapToItem(m_viewport, QPointF(m_canvas->width(), m_canvas->height())),
    };
    qreal left = corners[0].x();
    qreal right = corners[0].x();
    qreal top = corners[0].y();
    qreal bottom = corners[0].y();
    for (const QPointF& corner : corners) {
      left = qMin(left, corner.x());
      right = qMax(right, corner.x());
      top = qMin(top, corner.y());
      bottom = qMax(bottom, corner.y());
    }
    return QRectF(QPointF(left, top), QPointF(right, bottom));
  }

  void verifyCentred(const QString& label)
  {
    const QRectF rect = canvasRectInViewport();
    const QPointF centre = rect.center();
    const qreal wantX = m_viewport->width() / 2.0;
    const qreal wantY = m_viewport->height() / 2.0;
    qInfo().noquote() << QStringLiteral(
                           "%1: bbox %2,%3..%4,%5 centre %6,%7 want %8,%9")
                           .arg(label)
                           .arg(rect.left(), 0, 'f', 1)
                           .arg(rect.top(), 0, 'f', 1)
                           .arg(rect.right(), 0, 'f', 1)
                           .arg(rect.bottom(), 0, 'f', 1)
                           .arg(centre.x(), 0, 'f', 1)
                           .arg(centre.y(), 0, 'f', 1)
                           .arg(wantX, 0, 'f', 0)
                           .arg(wantY, 0, 'f', 0);
    QVERIFY2(qAbs(centre.x() - wantX) <= 1.0,
             qPrintable(QStringLiteral("%1: horizontal centre %2, want %3")
                          .arg(label)
                          .arg(centre.x())
                          .arg(wantX)));
    QVERIFY2(qAbs(centre.y() - wantY) <= 1.0,
             qPrintable(QStringLiteral("%1: vertical centre %2, want %3")
                          .arg(label)
                          .arg(centre.y())
                          .arg(wantY)));
  }

  qreal zoom() const
  {
    return m_viewer->property("zoom").toReal();
  }

  void zoomTo(qreal value)
  {
    m_viewer->setProperty("autoFit", false);
    m_viewer->setProperty("offsetX", 0.0);
    m_viewer->setProperty("offsetY", 0.0);
    m_viewer->setProperty("zoom", value);
    QCoreApplication::processEvents();
  }

  /// Inject a wheel event the way a QPA plugin delivers real input.
  ///
  /// `QWindowSystemInterface` refuses to queue wheel events whose phase is
  /// `ScrollUpdate` on Qt 6.12 (it returns false for pixel-delta and angle-delta
  /// events alike), so this helper only covers `NoScrollPhase` events; the
  /// mid-gesture phase is exercised through `dispatchWheel`.
  void injectWheel(const QPointingDevice* device, const QPointF& local, QPoint pixelDelta,
                   QPoint angleDelta)
  {
    const bool queued = QWindowSystemInterface::handleWheelEvent(
      m_view, ++m_timestamp, device, local,
      QPointF(m_view->mapToGlobal(local.toPoint())), pixelDelta, angleDelta, Qt::NoModifier,
      Qt::NoScrollPhase);
    QVERIFY2(queued, "the wheel event was not queued");
    QWindowSystemInterface::flushWindowSystemEvents();
    QCoreApplication::processEvents();
  }

  /// Deliver a wheel event straight to the window, which is the only way to
  /// test mid-gesture phases (`ScrollBegin`/`ScrollUpdate`/`ScrollEnd`). Qt does
  /// not report these as accepted, so the assertions live on the effect.
  void dispatchWheel(const QPointingDevice* device, const QPointF& local, QPoint pixelDelta,
                     QPoint angleDelta, Qt::ScrollPhase phase)
  {
    QWheelEvent event(local, QPointF(m_view->mapToGlobal(local.toPoint())), pixelDelta,
                      angleDelta, Qt::NoButton, Qt::NoModifier, phase, false,
                      Qt::MouseEventNotSynthesized, device);
    QCoreApplication::sendEvent(m_view, &event);
    QCoreApplication::processEvents();
  }

  static QPointingDevice* touchpadDevice()
  {
    return new QPointingDevice(QStringLiteral("test touchpad"), 1001,
                               QInputDevice::DeviceType::TouchPad,
                               QPointingDevice::PointerType::Finger,
                               QInputDevice::Capability::Scroll
                                 | QInputDevice::Capability::PixelScroll,
                               1, 3);
  }

  static QPointingDevice* mouseDevice()
  {
    return new QPointingDevice(QStringLiteral("test mouse"), 1002,
                               QInputDevice::DeviceType::Mouse,
                               QPointingDevice::PointerType::Generic,
                               QInputDevice::Capability::Scroll
                                 | QInputDevice::Capability::PixelScroll,
                               1, 3);
  }

  /// Scrolls a touchpad-style wheel event and checks that the image zooms and
  /// that the image point under the cursor does not move.
  void scrollAndVerifyAnchor(const QPointingDevice* device, const QPointF& cursor,
                             bool midGesture)
  {
    zoomTo(0.6);
    const QPointF probe = m_canvas->mapFromItem(m_viewport, cursor);
    const qreal before = zoom();
    if (midGesture) {
      dispatchWheel(device, cursor, QPoint(0, 15), QPoint(0, 0), Qt::ScrollBegin);
      dispatchWheel(device, cursor, QPoint(0, 15), QPoint(0, 0), Qt::ScrollUpdate);
      dispatchWheel(device, cursor, QPoint(0, 15), QPoint(0, 0), Qt::ScrollUpdate);
      dispatchWheel(device, cursor, QPoint(0, 0), QPoint(0, 0), Qt::ScrollEnd);
    } else {
      injectWheel(device, cursor, QPoint(0, 15), QPoint(0, 0));
    }
    QVERIFY2(zoom() > before, "the touchpad scroll did not zoom in");
    const QPointF after = m_canvas->mapToItem(m_viewport, probe);
    QVERIFY2(qAbs(after.x() - cursor.x()) <= 0.5,
             qPrintable(QStringLiteral("cursor anchor drifted x by %1 at %2,%3")
                          .arg(after.x() - cursor.x())
                          .arg(cursor.x())
                          .arg(cursor.y())));
    QVERIFY2(qAbs(after.y() - cursor.y()) <= 0.5,
             qPrintable(QStringLiteral("cursor anchor drifted y by %1 at %2,%3")
                          .arg(after.y() - cursor.y())
                          .arg(cursor.x())
                          .arg(cursor.y())));
  }

  void loadImage(const QString& path)
  {
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), path);
    state.insert(QStringLiteral("viewerImages"), QStringList{ path });
    state.insert(QStringLiteral("viewerIndex"), 0);
    m_viewer->setProperty("state", state);
    // Wait for *this* image. A bare "the canvas has a size" check is satisfied by
    // whatever was loaded before it — the decode is asynchronous, so the canvas
    // keeps the previous image's size until the new one is ready, and the test
    // would then measure the old canvas.
    QQuickItem* image = m_canvas->findChild<QQuickItem*>(QStringLiteral("viewerImage"));
    QVERIFY2(image != nullptr, "the viewer canvas has no image");
    QTRY_COMPARE(image->property("source").toUrl().toLocalFile(), path);
    QTRY_COMPARE_WITH_TIMEOUT(image->property("status").toInt(), int(KogaImageReady), 5000);
    QTRY_VERIFY2(m_canvas->width() > 1 && m_canvas->height() > 1,
                 "the image never reported an implicit size");
  }

  void fitAndReset()
  {
    m_viewer->setProperty("rotationAngle", 0);
    m_viewer->setProperty("flipH", false);
    m_viewer->setProperty("flipV", false);
    m_wheelHandler->setProperty("acceptedDevices", kAllDevices);
    QMetaObject::invokeMethod(m_viewer, "fit");
    QCoreApplication::processEvents();
  }

private slots:
  void initTestCase()
  {
    QVERIFY(m_fixtures.isValid());
    const auto writeImage = [this](const QString& name, int width, int height) {
      QImage image(width, height, QImage::Format_RGB32);
      image.fill(QColor(30, 90, 160));
      image.save(m_fixtures.path() + QLatin1Char('/') + name);
      return m_fixtures.path() + QLatin1Char('/') + name;
    };
    m_landscape = writeImage(QStringLiteral("landscape-1200x800.png"), 1200, 800);
    m_portrait = writeImage(QStringLiteral("portrait-600x900.png"), 600, 900);

    m_view = new QQuickView(&m_engine, nullptr);
    m_view->setResizeMode(QQuickView::SizeRootObjectToView);
    m_view->resize(kViewWidth, kViewHeight);
    m_view->setSource(QUrl::fromLocalFile(qmlDir() + QStringLiteral("/Viewer.qml")));
    QCOMPARE(m_view->status(), QQuickView::Ready);
    QVERIFY(m_view->rootObject() != nullptr);
    m_view->show();
    QVERIFY(QTest::qWaitForWindowExposed(m_view));

    m_viewer = m_view->rootObject();
    m_viewport = item("viewerViewport");
    m_canvas = item("viewerCanvas");
    m_wheelHandler = object("viewerWheelHandler");
    QVERIFY(m_viewport != nullptr);
    QVERIFY(m_canvas != nullptr);
    QVERIFY(m_wheelHandler != nullptr);
  }

  void init()
  {
    // A stub cache from a previous test lived on its stack: drop the pointer
    // before it dangles and before this test decides whether it wants one.
    m_viewer->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
    loadImage(m_landscape);
    fitAndReset();
  }

  /// A vertical wheel over the horizontal filmstrip must scroll it.
  ///
  /// The strip is a horizontal `ListView`, and Qt only moves the axis the wheel
  /// reports: a mouse wheel scrolling up/down does nothing at all to a
  /// horizontal list, which is why the filmstrip looked frozen.
  void theFilmstripScrollsWithTheWheel()
  {
    QStringList images;
    QVariantList entries;
    for (int index = 0; index < 40; ++index) {
      const QString path =
        m_fixtures.path() + QStringLiteral("/strip-%1.png").arg(index);
      images.append(path);
      QVariantMap entry;
      entry.insert(QStringLiteral("name"), QFileInfo(path).fileName());
      entry.insert(QStringLiteral("path"), path);
      entry.insert(QStringLiteral("isDir"), false);
      entry.insert(QStringLiteral("isImage"), true);
      entry.insert(QStringLiteral("size"), qint64(4242));
      entry.insert(QStringLiteral("modified"), qint64(1731000001));
      entries.append(entry);
    }

    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerImages"), images);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    state.insert(QStringLiteral("entries"), entries);
    m_viewer->setProperty("state", state);

    QQuickItem* strip = item("viewerFilmstrip");
    QVERIFY2(strip != nullptr, "the viewer has no filmstrip");
    QTRY_VERIFY2(strip->width() > 0 && strip->height() > 0,
                 "the filmstrip was never laid out");
    QTRY_VERIFY2(strip->property("contentWidth").toReal() > strip->width(),
                 "the filmstrip does not overflow, so the wheel cannot be measured");
    QCOMPARE(strip->property("contentX").toReal(), 0.0);

    const qreal zoomBefore = zoom();
    const QPointF over = strip->mapToScene(QPointF(strip->width() / 2.0,
                                                   strip->height() / 2.0));
    injectWheel(mouseDevice(), over, QPoint(0, 0), QPoint(0, -120));

    QTRY_VERIFY2(strip->property("contentX").toReal() > 0,
                 "a vertical wheel over the filmstrip did not scroll it");
    // And the strip scrolls instead of zooming the canvas underneath.
    QCOMPARE(zoom(), zoomBefore);
  }

  /// The filmstrip draws cached tiles instead of the originals. `viewerImages`
  /// carries paths only, so the size and mtime the cache keys on come from the
  /// folder listing — and a tile only draws once its thumbnail is there.
  void filmstripDrawsCachedThumbnails()
  {
    StubThumbnailCache cache;
    m_viewer->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(&cache)));

    const QString first = m_fixtures.path() + QStringLiteral("/strip-a.png");
    const QString second = m_fixtures.path() + QStringLiteral("/strip-b.png");
    for (const QString& path : { first, second }) {
      QImage image(64, 64, QImage::Format_RGB32);
      image.fill(QColor(120, 40, 60));
      QVERIFY(image.save(path));
    }

    QVariantList entries;
    for (const QString& path : { first, second }) {
      QVariantMap entry;
      entry.insert(QStringLiteral("name"), QFileInfo(path).fileName());
      entry.insert(QStringLiteral("path"), path);
      entry.insert(QStringLiteral("isDir"), false);
      entry.insert(QStringLiteral("isImage"), true);
      entry.insert(QStringLiteral("size"), qint64(4242));
      entry.insert(QStringLiteral("modified"), qint64(1731000001));
      entries.append(entry);
    }

    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), first);
    state.insert(QStringLiteral("viewerImages"), QStringList{ first, second });
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    state.insert(QStringLiteral("entries"), entries);
    m_viewer->setProperty("state", state);

    QQuickItem* tile = nullptr;
    QTRY_VERIFY2((tile = stripTile(first)) != nullptr, "no filmstrip tile for the first image");

    QTRY_VERIFY2(!cache.callsFor(first).isEmpty(), "the filmstrip never asked for a thumbnail");
    for (const StubThumbnailCache::Call& call : cache.callsFor(first)) {
      QCOMPARE(call.modified, qint64(1731000001));
      QCOMPARE(call.size, qint64(4242));
      QVERIFY2(call.edge >= 160, "the filmstrip asked for a below-minimum edge");
    }
    // Nothing is drawn before the thumbnail exists: the tile keeps its
    // placeholder background rather than decoding the original.
    QCOMPARE(tile->property("source").toString(), QString());

    cache.deliverAllFor(first, QStringLiteral("file:///cache/thumb-strip.png"));
    QTRY_COMPARE(tile->property("source").toString(),
                 QStringLiteral("file:///cache/thumb-strip.png"));

    // Without a cache object the strip falls back to the original file.
    m_viewer->setProperty("thumbnails", QVariant::fromValue(static_cast<QObject*>(nullptr)));
    QTRY_COMPARE(tile->property("source").toString(), QStringLiteral("file://") + first);

    // The other tests measure the canvas against a filmstrip-less layout, so
    // leave the viewer the way they expect to find it.
    loadImage(m_landscape);
  }

  /// The bug this suite was written for: the canvas position multiplied `width`
  /// by `scale` even though `scale` pivots on the item centre, so the image was
  /// drawn down and to the right and clipped at the bottom.
  void centredWhenFitted()
  {
    verifyCentred(QStringLiteral("fit 1200x800"));
    const QRectF rect = canvasRectInViewport();
    QVERIFY2(rect.left() >= -1.0 && rect.top() >= -1.0
               && rect.right() <= m_viewport->width() + 1.0
               && rect.bottom() <= m_viewport->height() + 1.0,
             "the fitted image is clipped by the viewport");
  }

  void centredForPortraitImage()
  {
    loadImage(m_portrait);
    fitAndReset();
    verifyCentred(QStringLiteral("fit 600x900"));
    zoomTo(1.0);
    verifyCentred(QStringLiteral("100% 600x900"));
  }

  void centredAtActualSize()
  {
    QMetaObject::invokeMethod(m_viewer, "actualSize");
    QCOMPARE(zoom(), 1.0);
    verifyCentred(QStringLiteral("100%"));
  }

  void centredWhenZoomedBeyondViewport()
  {
    zoomTo(3.0);
    verifyCentred(QStringLiteral("zoom 3x"));
    const QRectF rect = canvasRectInViewport();
    QVERIFY2(rect.left() < 0 && rect.top() < 0 && rect.right() > m_viewport->width()
               && rect.bottom() > m_viewport->height(),
             "a 3x image should overflow the viewport on all four sides");
  }

  void centredWhenRotated()
  {
    for (int angle : { 90, 180, 270 }) {
      m_viewer->setProperty("rotationAngle", angle);
      QCoreApplication::processEvents();
      verifyCentred(QStringLiteral("rotated %1").arg(angle));
    }
  }

  void centredWhenFlipped()
  {
    // the flip transform used to pivot on the item's top-left corner and pushed
    // the whole image outside the viewport
    m_viewer->setProperty("flipH", true);
    QCoreApplication::processEvents();
    verifyCentred(QStringLiteral("flipped H"));
    m_viewer->setProperty("flipH", false);

    m_viewer->setProperty("flipV", true);
    QCoreApplication::processEvents();
    verifyCentred(QStringLiteral("flipped V"));
    m_viewer->setProperty("flipV", false);
  }

  void panMovesImageByOffset()
  {
    zoomTo(0.5);
    const QRectF before = canvasRectInViewport();
    m_viewer->setProperty("offsetX", 40.0);
    m_viewer->setProperty("offsetY", -25.0);
    QCoreApplication::processEvents();
    const QRectF after = canvasRectInViewport();
    QVERIFY2(qAbs((after.left() - before.left()) - 40.0) <= 0.5, "offsetX not honoured");
    QVERIFY2(qAbs((after.top() - before.top()) + 25.0) <= 0.5, "offsetY not honoured");
  }

  void zoomButtonsKeepImageCentred()
  {
    const qreal fitted = zoom();
    QMetaObject::invokeMethod(m_viewer, "zoomIn");
    QVERIFY2(zoom() > fitted, "zoomIn did not increase the zoom");
    verifyCentred(QStringLiteral("zoomIn from fit"));
    QMetaObject::invokeMethod(m_viewer, "zoomOut");
    QMetaObject::invokeMethod(m_viewer, "zoomOut");
    QVERIFY2(zoom() < fitted, "zoomOut did not decrease the zoom");
    verifyCentred(QStringLiteral("zoomOut"));
  }

  /// Two-finger scrolling on Wayland/libinput arrives with a touchpad pointing
  /// device and a `pixelDelta`, with `angleDelta` zero.
  void touchpadWheelZoomsAtCursor()
  {
    const QPointingDevice* touchpad = touchpadDevice();
    const QPointF cursors[] = { QPointF(640, 315), QPointF(320, 130), QPointF(980, 520) };
    for (const QPointF& cursor : cursors) {
      scrollAndVerifyAnchor(touchpad, cursor, false);
    }
    delete touchpad;
  }

  /// The same event with an explicit scroll phase, which is what a real
  /// compositor sends for a two-finger gesture.
  void touchpadGestureWheelZoomsAtCursor()
  {
    const QPointingDevice* touchpad = touchpadDevice();
    const QPointF cursors[] = { QPointF(640, 315), QPointF(320, 130), QPointF(980, 520) };
    for (const QPointF& cursor : cursors) {
      scrollAndVerifyAnchor(touchpad, cursor, true);
    }
    delete touchpad;
  }

  void mouseWheelZoomsAtCursor()
  {
    const QPointingDevice* mouse = mouseDevice();
    const QPointF cursor(700, 400);
    zoomTo(0.6);
    const QPointF probe = m_canvas->mapFromItem(m_viewport, cursor);
    injectWheel(mouse, cursor, QPoint(0, 0), QPoint(0, 120));
    QVERIFY2(zoom() > 0.6, "mouse angleDelta did not zoom in");
    const QPointF after = m_canvas->mapToItem(m_viewport, probe);
    QVERIFY2(qAbs(after.x() - cursor.x()) <= 0.5, "cursor anchor drifted horizontally");
    QVERIFY2(qAbs(after.y() - cursor.y()) <= 0.5, "cursor anchor drifted vertically");

    const qreal zoomedIn = zoom();
    injectWheel(mouse, cursor, QPoint(0, 0), QPoint(0, -120));
    QVERIFY2(zoom() < zoomedIn, "mouse angleDelta did not zoom out");
    delete mouse;
  }

  /// Negative control for the `acceptedDevices: PointerDevice.AllDevices` fix:
  /// with the handler restricted to mouse devices, touchpad wheel events are
  /// filtered out and the zoom must not change. If this ever stops filtering,
  /// `acceptedDevices` is not what makes touchpad zoom work and the notes in
  /// `docs/VIEWER_WHEEL_CANVAS_BUG.md` need revisiting.
  void touchpadWheelIgnoredWhenHandlerAcceptsMouseOnly()
  {
    const QPointingDevice* touchpad = touchpadDevice();
    const QPointF cursor(640, 315);

    m_wheelHandler->setProperty("acceptedDevices", kMouseOnly);
    zoomTo(0.6);
    injectWheel(touchpad, cursor, QPoint(0, 15), QPoint(0, 0));
    QCOMPARE(zoom(), 0.6);
    dispatchWheel(touchpad, cursor, QPoint(0, 15), QPoint(0, 0), Qt::ScrollUpdate);
    QCOMPARE(zoom(), 0.6);

    m_wheelHandler->setProperty("acceptedDevices", kAllDevices);
    injectWheel(touchpad, cursor, QPoint(0, 15), QPoint(0, 0));
    QVERIFY2(zoom() > 0.6, "accepting all devices did not let the touchpad zoom");

    // a mouse device is accepted either way
    const QPointingDevice* mouse = mouseDevice();
    m_wheelHandler->setProperty("acceptedDevices", kMouseOnly);
    zoomTo(0.6);
    injectWheel(mouse, cursor, QPoint(0, 0), QPoint(0, 120));
    QVERIFY2(zoom() > 0.6, "a mouse wheel must work with acceptedDevices=Mouse");
    delete mouse;
    delete touchpad;
  }
};

QTEST_MAIN(TestViewer)
#include "tst_viewer.moc"
