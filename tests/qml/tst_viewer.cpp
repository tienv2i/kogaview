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
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFileInfo>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QImage>
#include <QPointingDevice>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickView>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>

#include <algorithm>
#include <cmath>

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
    m_viewer->setProperty("viewerImages", QStringList{ path });
    m_viewer->setProperty("entries", QVariantList());
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), path);
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

    m_viewer->setProperty("viewerImages", images);
    m_viewer->setProperty("entries", entries);
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
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
    // A notch *down* is "towards the user": the strip advances to the next
    // images, the direction the grid scrolls.
    injectWheel(mouseDevice(), over, QPoint(0, 0), QPoint(0, -120));
    // Step the animation frame by frame and sample `contentX` from inside the
    // frame, where the `NumberAnimation` really drives it: a busy loop that only
    // spins `processEvents` renders no animation frames. A jump reports the
    // destination on the first frame; a glide is short of it and then settles.
    struct Sample { qreal first; qreal last; };
    auto sampleGlide = [strip]() {
      Sample out { -1.0, -1.0 };
      QEventLoop loop;
      QElapsedTimer clock;
      clock.start();
      QTimer tick;
      tick.setInterval(8);
      QObject::connect(&tick, &QTimer::timeout, &loop, [&]() {
        const qreal now = strip->property("contentX").toReal();
        if (out.first < 0 && now > 0) {
          out.first = now;
        }
        out.last = now;
        if (clock.elapsed() > 250) {
          loop.quit();
        }
      });
      tick.start();
      loop.exec();
      return out;
    };
    const Sample down = sampleGlide();
    QVERIFY2(down.first >= 0, "a vertical wheel over the filmstrip did not move it");
    QTRY_VERIFY2(strip->property("contentX").toReal() > 0,
                 "a vertical wheel over the filmstrip did not scroll it");
    const qreal afterOneNotch = strip->property("contentX").toReal();
    QVERIFY2(afterOneNotch >= 78,
             qPrintable(QStringLiteral("one notch moved only %1 px").arg(afterOneNotch)));
    // The first frame of the movement was short of the destination: the strip
    // glided (a jump would report the destination on the first frame) and the
    // animation then settled instead of running away.
    QVERIFY2(down.first < afterOneNotch,
             qPrintable(QStringLiteral("the strip jumped to %1 px on the first frame instead of "
                                       "gliding from %2")
                          .arg(afterOneNotch)
                          .arg(down.first)));
    QTRY_COMPARE(strip->property("contentX").toReal(), afterOneNotch);

    // A notch *up* goes back towards the first images. Without this half, a
    // handler that ignores the sign would still pass while scrolling the wrong
    // way from an offset other than zero.
    injectWheel(mouseDevice(), over, QPoint(0, 0), QPoint(0, 120));
    QTRY_VERIFY2(strip->property("contentX").toReal() < afterOneNotch,
                 "a wheel notch the other way did not scroll back");

    // And the strip scrolls instead of zooming the canvas underneath.
    QCOMPARE(zoom(), zoomBefore);
  }

  /// Two notches in quick succession must move the strip by two steps.
  ///
  /// The strip glides, so the second notch usually arrives while the first
  /// animation is still running. If each notch measured from the *animated*
  /// position instead of the pending target, the travel still owed by the first
  /// notch would be dropped and a fast wheel spin would crawl.
  void twoQuickNotchesAddUp()
  {
    QStringList images;
    for (int index = 0; index < 40; ++index) {
      images.append(m_fixtures.path() + QStringLiteral("/strip-%1.png").arg(index));
    }
    m_viewer->setProperty("viewerImages", images);
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    m_viewer->setProperty("state", state);

    QQuickItem* strip = item("viewerFilmstrip");
    QVERIFY2(strip != nullptr, "the viewer has no filmstrip");
    QTRY_VERIFY2(strip->property("contentWidth").toReal() > strip->width(),
                 "the filmstrip does not overflow, so the wheel cannot be measured");
    QCOMPARE(strip->property("contentX").toReal(), 0.0);

    const QPointF over = strip->mapToScene(QPointF(strip->width() / 2.0,
                                                   strip->height() / 2.0));
    injectWheel(mouseDevice(), over, QPoint(0, 0), QPoint(0, -120));
    // Deliberately no waiting: the second notch lands mid-glide.
    injectWheel(mouseDevice(), over, QPoint(0, 0), QPoint(0, -120));

    // One notch is 504 px (two tile groups); two of them are 1008.
    QTRY_COMPARE_WITH_TIMEOUT(strip->property("contentX").toReal(), 1008.0, 2000);
  }

  /// A touchpad reports `pixelDelta` rather than `angleDelta`, and the strip
  /// must follow it 1:1 instead of ignoring the gesture.
  void theFilmstripFollowsATouchpad()
  {
    QStringList images;
    for (int index = 0; index < 40; ++index) {
      images.append(m_fixtures.path() + QStringLiteral("/strip-%1.png").arg(index));
    }
    m_viewer->setProperty("viewerImages", images);
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    m_viewer->setProperty("state", state);

    QQuickItem* strip = item("viewerFilmstrip");
    QVERIFY(strip != nullptr);
    QTRY_VERIFY2(strip->property("contentWidth").toReal() > strip->width(),
                 "the filmstrip does not overflow");
    // Showing the strip shrinks the viewport, which re-fits a fitted picture
    // (`Viewer.qml`, viewport `onHeightChanged`). Fit again once the layout has
    // settled so `zoomBefore` is the zoom of *this* viewport: the assertion at
    // the end is that the *gesture* does not zoom the canvas, not that the
    // layout never moved.
    QTRY_VERIFY(m_viewport->height() < 720);
    QMetaObject::invokeMethod(m_viewer, "fit");
    QCoreApplication::processEvents();
    const QPointF over = strip->mapToScene(QPointF(strip->width() / 2.0,
                                                   strip->height() / 2.0));

    static auto* touchpad = new QPointingDevice(
      QStringLiteral("test touchpad"), 1003, QInputDevice::DeviceType::TouchPad,
      QPointingDevice::PointerType::Finger,
      QInputDevice::Capability::Scroll | QInputDevice::Capability::PixelScroll, 1, 3);
    const qreal zoomBefore = zoom();
    // A finger moving down the pad reports a negative `y`: the strip advances,
    // exactly as it does for a notch down.
    injectWheel(touchpad, over, QPoint(0, -40), QPoint(0, 0));
    QTRY_COMPARE_WITH_TIMEOUT(strip->property("contentX").toReal(), 80.0, 2000);
    // And a finger moving up reports a positive `y`, which goes back.
    injectWheel(touchpad, over, QPoint(0, 15), QPoint(0, 0));
    QTRY_COMPARE_WITH_TIMEOUT(strip->property("contentX").toReal(), 50.0, 2000);
    QCOMPARE(zoom(), zoomBefore);
  }

  /// A mouse notch on the real window reports `angleDelta` ±120 **and**
  /// `pixelDelta` ±10. Preferring the pixel delta moved the strip by 20 px
  /// instead of 504 — the "very slow" the user saw. And the touchpad path must
  /// stay: an event with no notch still glides by its pixels.
  void aMouseNotchWithAPixelDeltaStillMovesAFilmstripGroup()
  {
    QStringList images;
    for (int index = 0; index < 40; ++index) {
      images.append(m_fixtures.path() + QStringLiteral("/strip-%1.png").arg(index));
    }
    m_viewer->setProperty("viewerImages", images);
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    m_viewer->setProperty("state", state);

    QQuickItem* strip = item("viewerFilmstrip");
    QVERIFY2(strip != nullptr, "the viewer has no filmstrip");
    QTRY_VERIFY2(strip->property("contentWidth").toReal() > strip->width(),
                 "the filmstrip does not overflow");
    QCOMPARE(strip->property("contentX").toReal(), 0.0);

    const QPointF over = strip->mapToScene(QPointF(strip->width() / 2.0,
                                                   strip->height() / 2.0));
    injectWheel(mouseDevice(), over, QPoint(0, -10), QPoint(0, -120));
    QTRY_VERIFY2(strip->property("contentX").toReal() >= 78,
                 qPrintable(QStringLiteral("one mouse notch (with a 10 px pixel delta) moved "
                                           "only %1 px")
                              .arg(strip->property("contentX").toReal())));
    // The whole group, not the 20 px a pixel-first reading gives.
    QTRY_COMPARE_WITH_TIMEOUT(strip->property("contentX").toReal(), 504.0, 2000);

    // A touchpad event has no notch at all, so the pixel path still applies.
    const qreal afterNotch = strip->property("contentX").toReal();
    injectWheel(touchpadDevice(), over, QPoint(0, -10), QPoint(0, 0));
    QTRY_COMPARE_WITH_TIMEOUT(strip->property("contentX").toReal(), afterNotch + 20.0, 2000);
  }

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

    m_viewer->setProperty("viewerImages", QStringList{ first, second });
    m_viewer->setProperty("entries", entries);
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), first);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
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

  // ------------------------------------------------------------ auto fit mode
  /// Fit is a *mode*, not a one-shot: resizing the window while the picture is
  /// fitted must re-fit it to the new viewport. Before this, `fit()` cleared
  /// its own flag, so the picture kept the old scale — too small when the window
  /// grew, overflowing when it shrank.
  void aFittedImageFollowsTheWindowResize()
  {
    // `init()` loaded the 1200x800 fixture and fitted it to 1280x820.
    QVERIFY2(m_viewer->property("autoFit").toBool(), "the fixture was not fitted");
    const qreal before = zoom();
    const qreal fittedFor = [&]() {
      return std::min(m_viewport->width() / 1200.0, m_viewport->height() / 800.0) * 0.98;
    }();
    QVERIFY2(qAbs(before - fittedFor) < 0.01,
             qPrintable(QStringLiteral("the initial fit is %1, expected %2")
                          .arg(before)
                          .arg(fittedFor)));

    // The window really shrinks: the viewport follows the root item.
    m_view->resize(760, 520);
    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->width() < 1100, 2000);
    const qreal after = zoom();
    const qreal expected = std::min(m_viewport->width() / 1200.0,
                                    m_viewport->height() / 800.0) * 0.98;
    QVERIFY2(qAbs(after - expected) < 0.01,
             qPrintable(QStringLiteral("after the resize the zoom is %1, but the picture fills "
                                       "%2 of the smaller viewport %3x%4")
                          .arg(after)
                          .arg(expected)
                          .arg(m_viewport->width())
                          .arg(m_viewport->height())));
    // A state delta, not stability: the scale really moved.
    QVERIFY2(qAbs(after - before) > 0.05,
             qPrintable(QStringLiteral("zoom did not change on resize: %1 -> %2")
                          .arg(before)
                          .arg(after)));

    // And the whole picture still fits inside the viewport.
    const QRectF shown(m_canvas->mapToItem(m_viewport, QPointF(0, 0)),
                       QSizeF(m_canvas->width() * zoom(), m_canvas->height() * zoom()));
    QVERIFY2(QRectF(0, 0, m_viewport->width(), m_viewport->height()).contains(shown),
             "the resized window cropped the fitted picture");

    m_view->resize(kViewWidth, kViewHeight);
    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->width() > 1100, 2000);
  }

  /// The window is not the only thing that resizes the viewing area: showing
  /// the filmstrip takes 106 px off the bottom with the window unchanged. A
  /// fitted picture must shrink to fit there too.
  void showingTheFilmstripRefitsThePicture()
  {
    QVERIFY(m_viewer->property("autoFit").toBool());
    const qreal zoomWithFullViewport = zoom();
    const qreal tall = m_viewport->height();

    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    m_viewer->setProperty("state", state);

    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->height() < tall - 100, 2000);
    const qreal afterFilmstrip = zoom();
    QVERIFY2(afterFilmstrip < zoomWithFullViewport - 0.01,
             qPrintable(QStringLiteral("the filmstrip did not refit a fitted picture "
                                       "(%1 -> %2)")
                          .arg(zoomWithFullViewport)
                          .arg(afterFilmstrip)));
    const qreal expected = std::min(m_viewport->width() / 1200.0,
                                    m_viewport->height() / 800.0) * 0.98;
    QVERIFY2(qAbs(afterFilmstrip - expected) < 0.01,
             qPrintable(QStringLiteral("filmstrip fit is %1, expected %2")
                          .arg(afterFilmstrip).arg(expected)));

    // Hiding it again restores the fuller fit.
    state.insert(QStringLiteral("filmstrip"), false);
    m_viewer->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->height() > tall - 2, 2000);
    QTRY_VERIFY2(qAbs(zoom() - zoomWithFullViewport) < 0.01,
                 "hiding the filmstrip did not give the picture back its size");
  }

  /// A hand-chosen zoom is not auto fit, so a resize leaves it alone. Without
  /// this the resize handler could refit everything and quietly destroy a zoom
  /// the user set.
  void aManualZoomSurvivesTheWindowResize()
  {
    zoomTo(2.5);
    QVERIFY2(!m_viewer->property("autoFit").toBool(), "zoomTo left auto fit on");

    m_view->resize(760, 520);
    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->width() < 1100, 2000);
    QCOMPARE(zoom(), 2.5);

    m_view->resize(kViewWidth, kViewHeight);
    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->width() > 1100, 2000);
    QCOMPARE(zoom(), 2.5);
    QVERIFY(!m_viewer->property("autoFit").toBool());
  }

  /// Turning a picture swaps the side that must fit: a fitted landscape photo
  /// is 1200 wide, and a quarter turn makes it 1200 *tall*, which no longer
  /// fits the viewport height. The fitted mode refits after the rotation.
  void aFittedImageRefitsAfterAQuarterTurn()
  {
    QVERIFY(m_viewer->property("autoFit").toBool());
    const qreal before = zoom();
    QMetaObject::invokeMethod(m_viewer, "rotateRight");
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("rotationAngle").toInt(), 90);
    const qreal after = zoom();
    QVERIFY2(qAbs(after - before) > 0.01,
             qPrintable(QStringLiteral("zoom did not change after a quarter turn: %1 -> %2")
                          .arg(before)
                          .arg(after)));
    // A quarter-turned 1200x800 fits the viewport's h/w swapped direction.
    const qreal expected = std::min(m_viewport->width() / 800.0,
                                    m_viewport->height() / 1200.0) * 0.98;
    QVERIFY2(qAbs(after - expected) < 0.01,
             qPrintable(QStringLiteral("turned fit is %1, expected %2").arg(after).arg(expected)));
    m_viewer->setProperty("rotationAngle", 0);
    QCoreApplication::processEvents();
  }

  // -------------------------------------------------------------- canvas menu
  // Helpers, not test slots: the class's test methods all live under
  // `private slots:`, so the section is closed and reopened around them.
private:
  /// The menu declared in the viewer, which is a `QObject` child of the root
  /// item even though it draws in a window of its own.
  QObject* canvasMenu() const { return object("viewerMenu"); }

  /// The canvas menu's entry showing `text`, or nullptr.
  QQuickItem* canvasEntry(const QString& text) const
  {
    QObject* menu = canvasMenu();
    if (menu == nullptr) {
      return nullptr;
    }
    const int count = menu->property("count").toInt();
    for (int index = 0; index < count; ++index) {
      QQuickItem* entry = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                Q_ARG(int, index));
      if (entry != nullptr && entry->property("text").toString() == text) {
        return entry;
      }
    }
    return nullptr;
  }

  QStringList canvasLabels() const
  {
    QStringList labels;
    QObject* menu = canvasMenu();
    const int count = menu->property("count").toInt();
    for (int index = 0; index < count; ++index) {
      QQuickItem* entry = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry),
                                Q_ARG(int, index));
      if (entry != nullptr && !entry->property("text").toString().isEmpty()) {
        labels.append(entry->property("text").toString());
      }
    }
    return labels;
  }

  void openCanvasMenu()
  {
    QObject* menu = canvasMenu();
    QVERIFY2(menu != nullptr, "the viewer has no canvas menu");
    QMetaObject::invokeMethod(menu, "popup");
    QTRY_VERIFY2(menu->property("visible").toBool(), "the canvas menu did not open");
  }

private slots:
  /// A right click in the viewing area opens the canvas menu.
  ///
  /// The event goes through the window like a real click, so it exercises the
  /// `TapHandler` and not just the `Menu`: the handler is the part that can be
  /// mis-wired (wrong button, attached to the wrong item, shadowed by the pan
  /// handler).
  void rightClickOnTheCanvasOpensTheMenu()
  {
    QObject* menu = canvasMenu();
    QVERIFY2(menu != nullptr, "the viewer has no canvas menu");
    QVERIFY2(!menu->property("visible").toBool(), "the canvas menu was open before the click");

    const QPoint inWindow =
      m_viewport->mapToScene(QPointF(m_viewport->width() / 2.0, m_viewport->height() / 2.0)).toPoint();
    QTest::mouseClick(m_view, Qt::RightButton, Qt::NoModifier, inWindow);
    QTRY_VERIFY2(menu->property("visible").toBool(),
                 "a right click on the image did not open the canvas menu");
    QMetaObject::invokeMethod(menu, "close");
    QTRY_VERIFY(!menu->property("visible").toBool());

    // The menu opens *at the click*, not wherever the pointer happens to be:
    // `popup()` without arguments asks for the global cursor position, which a
    // synthetic click (and some Wayland compositors) do not update. Clicked near
    // the top-left so the menu fits on screen and Qt has no reason to flip it.
    const QPointF corner = m_viewport->mapToScene(QPointF(80, 60));
    QTest::mouseClick(m_view, Qt::RightButton, Qt::NoModifier, corner.toPoint());
    QTRY_VERIFY2(menu->property("visible").toBool(),
                 "the second right click did not reopen the canvas menu");
    QVERIFY2(qAbs(menu->property("x").toReal() - 80) <= 2.0 &&
               qAbs(menu->property("y").toReal() - 60) <= 2.0,
             qPrintable(QStringLiteral("the menu opened at %1,%2 instead of the click at 80,60")
                          .arg(menu->property("x").toReal())
                          .arg(menu->property("y").toReal())));
    QMetaObject::invokeMethod(menu, "close");
    QTRY_VERIFY(!menu->property("visible").toBool());
  }

  /// With nothing on screen there is no image to act on, so the menu stays shut
  /// instead of offering a list of disabled entries.
  void rightClickDoesNothingWithoutAnImage()
  {
    m_viewer->setProperty("state", QVariantMap());
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("currentPath").toString(), QString());

    const QPoint inWindow =
      m_viewport->mapToScene(QPointF(m_viewport->width() / 2.0, m_viewport->height() / 2.0)).toPoint();
    QTest::mouseClick(m_view, Qt::RightButton, Qt::NoModifier, inWindow);
    QTest::qWait(200);
    QVERIFY2(!canvasMenu()->property("visible").toBool(),
             "the canvas menu opened although no image is shown");
  }

  /// The menu offers the file actions the browser's file menu offers, plus the
  /// viewer's own zoom/rotation, and every label it shows is one the theme
  /// measures — otherwise the shell's width calculation is sized from an
  /// incomplete list and the entry is clipped.
  void theCanvasMenuOffersTheImagesActions()
  {
    openCanvasMenu();
    const QStringList labels = canvasLabels();
    for (const QString& expected :
         { QStringLiteral("Edit"), QStringLiteral("Open with…"),
           QStringLiteral("Copy image content"), QStringLiteral("Copy file path"),
           QStringLiteral("Copy to…"), QStringLiteral("Move to…"),
           QStringLiteral("Move to trash"), QStringLiteral("Delete permanently…"),
           QStringLiteral("Fit to window"), QStringLiteral("Actual size"),
           QStringLiteral("Rotate left"), QStringLiteral("Rotate right") }) {
      QVERIFY2(labels.contains(expected),
               qPrintable(QStringLiteral("the canvas menu has no \"%1\" entry").arg(expected)));
    }

    QObject* theme = m_viewer->property("theme").value<QObject*>();
    QVERIFY(theme != nullptr);
    QStringList catalogue;
    for (const QVariant& label : theme->property("menuEntryLabels").value<QVariantList>()) {
      catalogue.append(label.toString());
    }
    for (const QString& label : labels) {
      QVERIFY2(catalogue.contains(label),
               qPrintable(QStringLiteral("the canvas menu shows \"%1\", which "
                                         "Theme.menuEntryLabels does not measure")
                            .arg(label)));
    }

    // The widths `Main.qml` measures are what the menu is sized from: with them
    // applied it is no wider than the widest catalogue label needs.
    const qreal minimum = theme->property("menuMinimumWidth").toReal();
    const QFontMetricsF metrics(QGuiApplication::font());
    qreal widest = 0;
    for (const QVariant& label : theme->property("menuEntryLabels").value<QVariantList>()) {
      widest = qMax(widest, metrics.horizontalAdvance(label.toString()));
    }
    const qreal floor = qMax(minimum, std::ceil(widest) + 12);
    QVERIFY2(canvasMenu()->property("width").toReal() <= floor,
             qPrintable(QStringLiteral("the canvas menu is %1 px; the measured labels need at "
                                       "most %2 px")
                          .arg(canvasMenu()->property("width").toReal())
                          .arg(floor)));
    QMetaObject::invokeMethod(canvasMenu(), "close");
  }

  /// Each entry does what its label says: the file actions emit the command or
  /// shell request for *this* image, and the presentation entries move the
  /// viewer's own state.
  void theCanvasMenuEntriesActOnTheImage()
  {
    const QString path = m_viewer->property("currentPath").toString();
    QCOMPARE(path, m_landscape);

    QSignalSpy commands(m_viewer, SIGNAL(command(QVariant)));
    QSignalSpy copyImage(m_viewer, SIGNAL(copyImage(QString)));
    QSignalSpy copyText(m_viewer, SIGNAL(copyText(QString)));
    QSignalSpy openWith(m_viewer, SIGNAL(openWith(QString)));
    QSignalSpy editInEditor(m_viewer, SIGNAL(editInEditor(QString)));
    QSignalSpy destinations(m_viewer, SIGNAL(requestDestination(QString, QVariant)));
    QSignalSpy deletes(m_viewer, SIGNAL(requestDelete(QVariant)));

    const auto activate = [this](const QString& label) {
      QQuickItem* entry = canvasEntry(label);
      QVERIFY2(entry != nullptr, qPrintable(QStringLiteral("no \"%1\" entry").arg(label)));
      QVERIFY2(entry->isEnabled(), qPrintable(QStringLiteral("\"%1\" is disabled").arg(label)));
      // `trigger()` is not invokable through the meta-object; `click()` is, and
      // it goes through the same `onTriggered` handler a real click uses.
      QVERIFY(QMetaObject::invokeMethod(entry, "click"));
    };

    openCanvasMenu();
    activate(QStringLiteral("Edit"));
    // The view asks the shell to edit this image; the shell batches select +
    // set_workspace + editor_open (`Main.qml`'s `onEditInEditor`). Emitting the
    // three commands from the menu handler itself dropped one of them, and the
    // batching is what that fixed — so the view is asserted on the request.
    QCOMPARE(editInEditor.count(), 1);
    QCOMPARE(editInEditor.at(0).at(0).toString(), path);
    QCOMPARE(commands.count(), 0);
    commands.clear();

    activate(QStringLiteral("Move to trash"));
    QCOMPARE(commands.count(), 1);
    QCOMPARE(commands.at(0).at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("trash"));
    QCOMPARE(commands.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ path });
    commands.clear();

    activate(QStringLiteral("Copy image content"));
    QCOMPARE(copyImage.count(), 1);
    QCOMPARE(copyImage.at(0).at(0).toString(), path);

    activate(QStringLiteral("Copy file path"));
    QCOMPARE(copyText.count(), 1);
    QCOMPARE(copyText.at(0).at(0).toString(), path);

    activate(QStringLiteral("Open with…"));
    QCOMPARE(openWith.count(), 1);
    QCOMPARE(openWith.at(0).at(0).toString(), path);

    activate(QStringLiteral("Copy to…"));
    QCOMPARE(destinations.count(), 1);
    QCOMPARE(destinations.at(0).at(0).toString(), QStringLiteral("copy_to"));
    QCOMPARE(destinations.at(0).at(1).toStringList(), QStringList{ path });

    activate(QStringLiteral("Move to…"));
    QCOMPARE(destinations.count(), 2);
    QCOMPARE(destinations.at(1).at(0).toString(), QStringLiteral("move_to"));

    activate(QStringLiteral("Delete permanently…"));
    QCOMPARE(deletes.count(), 1);
    QCOMPARE(deletes.at(0).at(0).toStringList(), QStringList{ path });

    // The presentation entries are Qt-owned state, so they change the viewer
    // directly rather than sending a command.
    activate(QStringLiteral("Rotate right"));
    QCOMPARE(m_viewer->property("rotationAngle").toInt(), 90);
    activate(QStringLiteral("Rotate left"));
    QCOMPARE(m_viewer->property("rotationAngle").toInt(), 0);

    m_viewer->setProperty("zoom", 2.0);
    QCoreApplication::processEvents();
    activate(QStringLiteral("Fit to window"));
    const qreal expected = qMin(m_viewport->width() / m_canvas->width(),
                                m_viewport->height() / m_canvas->height()) * 0.98;
    QVERIFY2(qAbs(zoom() - expected) < 0.01,
             qPrintable(QStringLiteral("fit left the zoom at %1, expected %2")
                          .arg(zoom())
                          .arg(expected)));
    activate(QStringLiteral("Actual size"));
    QCOMPARE(zoom(), 1.0);
    QCOMPARE(commands.count(), 0);
  }
};

QTEST_MAIN(TestViewer)
#include "tst_viewer.moc"
