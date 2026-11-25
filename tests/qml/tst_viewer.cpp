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
#include <QKeyEvent>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickView>
#include <QScopedPointer>
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

  /// Read a property at the QML level, which is how grouped properties such as
  /// `icon.name` and an attached `ToolTip.text` are reachable.
  static QVariant readQml(QObject* object, const QString& expression)
  {
    QQmlExpression reader(QQmlEngine::contextForObject(object), object, expression);
    return reader.evaluate();
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

  static void collectAll(QQuickItem* root, QList<QQuickItem*>* out)
  {
    out->append(root);
    for (QQuickItem* child : root->childItems()) {
      collectAll(child, out);
    }
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
    const QPointF scenePos = m_viewport->mapToScene(cursor);
    const qreal before = zoom();
    if (midGesture) {
      dispatchWheel(device, scenePos, QPoint(0, 15), QPoint(0, 0), Qt::ScrollBegin);
      dispatchWheel(device, scenePos, QPoint(0, 15), QPoint(0, 0), Qt::ScrollUpdate);
      dispatchWheel(device, scenePos, QPoint(0, 15), QPoint(0, 0), Qt::ScrollUpdate);
      dispatchWheel(device, scenePos, QPoint(0, 0), QPoint(0, 0), Qt::ScrollEnd);
    } else {
      injectWheel(device, scenePos, QPoint(0, 15), QPoint(0, 0));
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
    // Most cases below measure the picture in the whole viewport and name a
    // cursor in viewport coordinates. Both docks are real columns now, so put
    // them away here; their own cases (`theLeftPanelsSitBesideThePicture`,
    // `theSidebarIsOneInformationPage`) show them again and assert where the
    // picture starts. Hiding the panels is layout state, the same answer
    // Settings › Appearance writes.
    m_viewer->setProperty("layout", QVariantMap{
        {QStringLiteral("leftWidth"), 260},
        {QStringLiteral("panels"), QVariantMap{
             {QStringLiteral("viewer.quickAccess"), false},
             {QStringLiteral("viewer.explorer"), false},
             {QStringLiteral("viewer.info"), false}}}});
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
    const QPointF scenePos = m_viewport->mapToScene(cursor);
    injectWheel(mouse, scenePos, QPoint(0, 0), QPoint(0, 120));
    QVERIFY2(zoom() > 0.6, "mouse angleDelta did not zoom in");
    const QPointF after = m_canvas->mapToItem(m_viewport, probe);
    QVERIFY2(qAbs(after.x() - cursor.x()) <= 0.5, "cursor anchor drifted horizontally");
    QVERIFY2(qAbs(after.y() - cursor.y()) <= 0.5, "cursor anchor drifted vertically");

    const qreal zoomedIn = zoom();
    injectWheel(mouse, scenePos, QPoint(0, 0), QPoint(0, -120));
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

    // A strip needs something to strip: a folder with two images lets the
    // toggle take effect at all (a single image hides it, see
    // `aSingleImageFolderHasNoFilmstrip`).
    m_viewer->setProperty("viewerImages", QStringList{ m_landscape, m_portrait });

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
    const qreal expected = std::min(1.0, std::min(m_viewport->width() / 1200.0,
                                                  m_viewport->height() / 800.0) * 0.98);
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

  /// A picture smaller than the window is not blown up to fill it: fit stops at
  /// 100 %, so a 300×200 photo stays sharp and the viewer says why it is
  /// surrounded by space.
  ///
  /// The assertion is on a real state change: the zoom is exactly 1.0 and
  /// *below* the zoom the old fit-the-viewport rule would have produced, so a
  /// regression that removes the cap fails on a number, not on a flag.
  void aSmallPictureFitsAtOneHundredPercent()
  {
    const QString small = m_fixtures.path() + QStringLiteral("/small-300x200.png");
    QImage image(300, 200, QImage::Format_RGB32);
    image.fill(QColor(200, 60, 60));
    QVERIFY(image.save(small));

    loadImage(small);
    m_viewer->setProperty("viewerImages", QStringList{ small });
    QMetaObject::invokeMethod(m_viewer, "fit");
    QCoreApplication::processEvents();

    QVERIFY2(m_viewer->property("autoFit").toBool(), "fit left auto fit off");
    const qreal fitted = zoom();
    QVERIFY2(qAbs(fitted - 1.0) < 0.001,
             qPrintable(QStringLiteral("a small picture fitted at %1, expected 1.0").arg(fitted)));

    // What the uncapped rule would have said: the picture filling the viewport.
    const qreal withoutCap =
      std::min(m_viewport->width() / 300.0, m_viewport->height() / 200.0) * 0.98;
    QVERIFY2(withoutCap > 1.5,
             qPrintable(QStringLiteral("the fixture is not small enough to prove anything: "
                                       "uncapped fit would be %1")
                          .arg(withoutCap)));

    // And the viewer offers a way forward instead of leaving the user puzzled.
    QTRY_VERIFY2(m_viewer->property("imageSmallerThanViewport").toBool(),
                 "the small-image hint never became visible");

    // It is guidance, not a lock: zooming out of the fitted size is still
    // allowed, and the hint goes away with it.
    QMetaObject::invokeMethod(m_viewer, "setZoom", Q_ARG(QVariant, 2.0));
    QCoreApplication::processEvents();
    QVERIFY2(!m_viewer->property("imageSmallerThanViewport").toBool()
               || !m_viewer->property("autoFit").toBool(),
             "the hint stayed after a deliberate zoom");
    QVERIFY(qAbs(zoom() - 2.0) < 0.001);
  }

  /// A folder with one image has nothing to strip, so the filmstrip stays out
  /// of the way even though the stored preference is on — and the preference
  /// itself is untouched, so a two-image folder still shows it.
  void aSingleImageFolderHasNoFilmstrip()
  {
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    state.insert(QStringLiteral("filmstrip"), true);
    m_viewer->setProperty("viewerImages", QStringList{ m_landscape });
    m_viewer->setProperty("state", state);
    QCoreApplication::processEvents();

    QVERIFY2(!m_viewer->property("filmstripShown").toBool(),
             "a one-image folder still showed the filmstrip");
    const qreal singleImageViewport = m_viewport->height();

    // Two images: the same preference now means a real strip.
    m_viewer->setProperty("viewerImages", QStringList{ m_landscape, m_portrait });
    QTRY_VERIFY_WITH_TIMEOUT(m_viewer->property("filmstripShown").toBool(), 2000);
    QTRY_VERIFY_WITH_TIMEOUT(m_viewport->height() < singleImageViewport - 100, 2000);
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

  /// The window draws the bytes Core published, not just the path.
  ///
  /// A QML `Image` whose `source` string does not change never re-reads the
  /// file, so opening the same picture again after another program rewrote it
  /// kept the old pixels on screen. Core publishes the bytes' mtime and size;
  /// the query string is what turns "same path, new bytes" into a new source.
  void theSourceCarriesTheStampSoARewrittenFileIsReadAgain()
  {
    QQuickItem* image = item("viewerImage");
    QVERIFY(image != nullptr);

    QVariantMap state = m_viewer->property("state").toMap();
    state.insert(QStringLiteral("viewerModified"), 11);
    state.insert(QStringLiteral("viewerSize"), 22);
    m_viewer->setProperty("state", state);
    QTRY_COMPARE(image->property("source").toUrl().query(), QStringLiteral("v=11-22"));
    // The stamp is only a query: the window still names the one file.
    QCOMPARE(image->property("source").toUrl().toLocalFile(), m_landscape);

    // New bytes on disk, the same path: another stamp, another source.
    state.insert(QStringLiteral("viewerModified"), 33);
    state.insert(QStringLiteral("viewerSize"), 44);
    m_viewer->setProperty("state", state);
    QTRY_COMPARE(image->property("source").toUrl().query(), QStringLiteral("v=33-44"));
    QCOMPARE(image->property("source").toUrl().toLocalFile(), m_landscape);

    // The same bytes asked for again are the same source, so a redundant open
    // does not make Qt decode the file a second time.
    m_viewer->setProperty("state", state);
    QTest::qWait(20);
    QCOMPARE(image->property("source").toUrl().query(), QStringLiteral("v=33-44"));
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
    QMetaObject::invokeMethod(menu, "open");
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
    QVERIFY2(qAbs(menu->property("x").toReal() - corner.x()) <= 2.0 &&
               qAbs(menu->property("y").toReal() - corner.y()) <= 2.0,
             qPrintable(QStringLiteral("the menu opened at %1,%2 instead of the click at %3,%4")
                          .arg(menu->property("x").toReal())
                          .arg(menu->property("y").toReal())
                          .arg(corner.x())
                          .arg(corner.y())));
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

  // ---------------------------------------------------------------- toolbar

  /// Every control whose action has a key names that key in its tooltip. Read
  /// the attached property rather than opening the popup: the text the popup
  /// would draw is the same string, without waiting for the hover delay.
  void toolbarTooltipsNameTheirShortcuts()
  {
    QQuickItem* viewItem = m_view->rootObject();
    auto* component = qobject_cast<QQmlComponent*>(viewItem->property("toolbar").value<QObject*>());
    QVERIFY2(component != nullptr, "the viewer has no toolbar component");
    QScopedPointer<QObject> created(component->create(component->creationContext()));
    QVERIFY2(created != nullptr, qPrintable(component->errorString()));
    auto* row = qobject_cast<QQuickItem*>(created.data());
    QVERIFY(row != nullptr);
    row->setParentItem(viewItem);
    row->setWidth(1000);
    row->setHeight(44);
    QCoreApplication::processEvents();

    const QList<QPair<QString, QString>> expected = {
      { QStringLiteral("media-skip-backward-symbolic"),
        QStringLiteral("Previous image (Left)") },
      { QStringLiteral("media-skip-forward-symbolic"),
        QStringLiteral("Next image (Right)") },
      { QStringLiteral("zoom-in-symbolic"), QStringLiteral("Zoom in (+ or scroll wheel)") },
      { QStringLiteral("zoom-out-symbolic"), QStringLiteral("Zoom out (- or scroll wheel)") },
      { QStringLiteral("zoom-fit-best-symbolic"), QStringLiteral("Fit to window (F)") },
      { QStringLiteral("zoom-original-symbolic"),
        QStringLiteral("Actual size at 100% (0/1)") },
      { QStringLiteral("viewerRotateLeftButton"),
        QStringLiteral("Rotate left (Shift+R)") },
      { QStringLiteral("viewerRotateRightButton"),
        QStringLiteral("Rotate right (R)") },
      { QStringLiteral("viewerFlipHButton"),
        QStringLiteral("Flip horizontal (H)") },
      { QStringLiteral("viewerFlipVButton"),
        QStringLiteral("Flip vertical (V)") },
      { QStringLiteral("viewerResetViewButton"),
        QStringLiteral("Reset view") },
      { QStringLiteral("viewerFullscreenButton"),
        QStringLiteral("Fullscreen (F11)") },
      { QStringLiteral("viewerFilmstripToggle"),
        QStringLiteral("Toggle thumbnail filmstrip (T)") },
      { QStringLiteral("viewerColorAdjustButton"),
        QStringLiteral("Info & color") },
      { QStringLiteral("viewerUiModeButton"),
        QStringLiteral("Viewer mode & layout (M)") },
    };
    QList<QQuickItem*> all;
    collectAll(row, &all);
    for (const auto& entry : expected) {
      QQuickItem* button = nullptr;
      for (QQuickItem* candidate : all) {
        if (candidate->objectName() == entry.first
            || readQml(candidate, QStringLiteral("icon.name")).toString() == entry.first) {
          button = candidate;
          break;
        }
      }
      QVERIFY2(button != nullptr,
               qPrintable(QStringLiteral("no %1 button").arg(entry.first)));
      QCOMPARE(readQml(button, QStringLiteral("ToolTip.text")).toString(), entry.second);
    }
  }

  /// The two copy entries name the keys that run them, and the hints are drawn
  /// inside the entries rather than appended to their text: `MenuItem` has no
  /// shortcut column, so the label is the only place a key can be shown. A hint
  /// whose key does not match the shell's `Shortcut` would teach a dead key, so
  /// the strings are compared, not just counted.
  void theCopyEntriesNameTheirKeys()
  {
    openCanvasMenu();
    const auto hintOf = [this](const QString& label) {
      QQuickItem* entry = canvasEntry(label);
      return entry ? entry->findChild<QQuickItem*>(QStringLiteral("shortcutHint")) : nullptr;
    };

    QQuickItem* copyImage = hintOf(QStringLiteral("Copy image content"));
    QVERIFY2(copyImage != nullptr, "the copy-image entry draws no key");
    QCOMPARE(copyImage->property("text").toString(), QStringLiteral("Ctrl+Shift+C"));
    QVERIFY2(copyImage->property("visible").toBool(), "the copy-image key is hidden");

    QQuickItem* copyPath = hintOf(QStringLiteral("Copy file path"));
    QVERIFY2(copyPath != nullptr, "the copy-path entry draws no key");
    QCOMPARE(copyPath->property("text").toString(), QStringLiteral("Ctrl+Alt+C"));

    // The hint is the right edge's column: it must sit to the right of the
    // label's own text, or it would be drawn over the words it belongs to.
    QVERIFY2(copyImage->x() > 0, "the key column is not on the right");
    // No entry without a key may sprout one.
    QQuickItem* rotate = canvasEntry(QStringLiteral("Rotate right"));
    QVERIFY(rotate != nullptr);
    QQuickItem* rotateHint = rotate->findChild<QQuickItem*>(QStringLiteral("shortcutHint"));
    QVERIFY2(rotateHint != nullptr, "the rotate entry lost its key");
    QCOMPARE(rotateHint->property("text").toString(), QStringLiteral("R"));
    QMetaObject::invokeMethod(canvasMenu(), "close");
  }

  /// Below the full icon row the Viewer keeps navigation and folds zoom,
  /// rotation, flip and the filmstrip into one overflow button. The count is
  /// `ToolbarMetrics.viewerMiniButtons`, so the window floor and the row that
  /// is drawn cannot disagree.
  void theMiniToolbarFoldsTheSecondaryActions_data()
  {
    QTest::addColumn<bool>("mini");
    QTest::newRow("compact") << false;
    QTest::newRow("mini") << true;
  }

  void theMiniToolbarFoldsTheSecondaryActions()
  {
    QFETCH(bool, mini);
    QQuickItem* viewItem = m_view->rootObject();
    auto* component = qobject_cast<QQmlComponent*>(viewItem->property("toolbar").value<QObject*>());
    QVERIFY2(component != nullptr, "the viewer has no toolbar component");
    QScopedPointer<QObject> created(component->create(component->creationContext()));
    QVERIFY2(created != nullptr, qPrintable(component->errorString()));
    auto* row = qobject_cast<QQuickItem*>(created.data());
    QVERIFY(row != nullptr);
    row->setParentItem(viewItem);
    row->setWidth(1000);
    row->setHeight(44);
    m_viewer->setProperty("miniToolbar", mini);
    QCoreApplication::processEvents();

    QList<QQuickItem*> all;
    collectAll(row, &all);
    int buttons = 0;
    QQuickItem* overflow = nullptr;
    for (QQuickItem* candidate : all) {
      // A `ToolbarButton`, not a layout spacer, a readout or the `QQuickIconLabel`
      // inside a button (which answers `icon`/`display` from the button's
      // scope). The composite type's generated class name is what identifies
      // it.
      if (!QString::fromLatin1(candidate->metaObject()->className())
             .contains(QStringLiteral("ToolbarButton"))) {
        continue;
      }
      if (candidate->objectName() == QStringLiteral("viewerOverflowButton")) {
        overflow = candidate;
      }
      if (candidate->isVisible()) {
        ++buttons;
      }
    }
    QVERIFY2(overflow != nullptr, "the toolbar has no overflow button");
    QCOMPARE(overflow->isVisible(), mini);
    QCOMPARE(buttons, mini ? 4 : 15);

    if (mini) {
      // The folded actions are still reachable, from one menu.
      QVERIFY(QMetaObject::invokeMethod(overflow, "click"));
      QObject* menu = object("viewerOverflowMenu");
      QVERIFY2(menu != nullptr, "the viewer has no overflow menu");
      QTRY_VERIFY2(menu->property("visible").toBool(), "the overflow menu did not open");
      const int rows = menu->property("count").toInt();
      QMetaObject::invokeMethod(menu, "close");
      QTRY_VERIFY(!menu->property("visible").toBool());
      // Zoom in/out, actual size, rotate left/right, flip horizontal/vertical,
      // reset view, fullscreen, filmstrip, info & color, viewer mode & layout,
      // and canvas background, with two separators.
      QCOMPARE(rows, 15);
    } else {
      // Progressive 1-by-1 folding hides Canvas bg, Viewer mode, then Info & color.
      QQuickItem* bgSwatch = row->findChild<QQuickItem*>(QStringLiteral("viewerBgSwatch"));
      QQuickItem* modeBtn = row->findChild<QQuickItem*>(QStringLiteral("viewerUiModeButton"));
      QQuickItem* infoBtn = row->findChild<QQuickItem*>(QStringLiteral("viewerColorAdjustButton"));
      QVERIFY(bgSwatch != nullptr && modeBtn != nullptr && infoBtn != nullptr);

      m_viewer->setProperty("toolbarFoldCount", 1);
      QCoreApplication::processEvents();
      QVERIFY(!bgSwatch->isVisible());
      QVERIFY(modeBtn->isVisible());
      QVERIFY(infoBtn->isVisible());
      QVERIFY(overflow->isVisible());

      m_viewer->setProperty("toolbarFoldCount", 2);
      QCoreApplication::processEvents();
      QVERIFY(!bgSwatch->isVisible());
      QVERIFY(!modeBtn->isVisible());
      QVERIFY(infoBtn->isVisible());

      m_viewer->setProperty("toolbarFoldCount", 3);
      QCoreApplication::processEvents();
      QVERIFY(!bgSwatch->isVisible());
      QVERIFY(!modeBtn->isVisible());
      QVERIFY(!infoBtn->isVisible());

      m_viewer->setProperty("toolbarFoldCount", 0);
      QCoreApplication::processEvents();
      QVERIFY(bgSwatch->isVisible());
      QVERIFY(!overflow->isVisible());
    }
    m_viewer->setProperty("miniToolbar", false);
  }

  /// The Viewer's right column is one page: the file on screen has details, and
  /// a tab over a single page would only add a click. The row is read from the
  /// same `InfoPanel` the Browser uses, and the workspace switch hides the
  /// splitter with it.
  void theSidebarIsOneInformationPage()
  {
    QVariantMap entry;
    entry.insert(QStringLiteral("path"), m_landscape);
    entry.insert(QStringLiteral("name"), QStringLiteral("landscape-1200x800.png"));
    entry.insert(QStringLiteral("kind"), QStringLiteral(".png"));
    entry.insert(QStringLiteral("isImage"), true);
    entry.insert(QStringLiteral("size"), qint64(234567));
    entry.insert(QStringLiteral("modified"), qint64(1731000000));
    m_viewer->setProperty("entries", QVariantList{entry});

    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_landscape);
    state.insert(QStringLiteral("viewerIndex"), 0);
    m_viewer->setProperty("state", state);
    QVariantMap panels;
    panels.insert(QStringLiteral("viewer.quickAccess"), true);
    panels.insert(QStringLiteral("viewer.explorer"), true);
    panels.insert(QStringLiteral("viewer.info"), true);
    QVariantMap layout;
    layout.insert(QStringLiteral("panels"), panels);
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();

    QQuickItem* panel = item("viewerRightPanel");
    QVERIFY2(panel != nullptr, "the viewer has no right dock");
    QTRY_VERIFY(panel->isVisible());
    QVERIFY2(panel->property("stripShown").toBool(),
             "the two-page viewer dock did not draw a tab strip");
    QCOMPARE(panel->property("tabs").toList().size(), 2);

    QQuickItem* name = item("infoName");
    QVERIFY2(name != nullptr, "the viewer's dock has no information page");
    QVERIFY(name->isVisible());
    QCOMPARE(name->property("text").toString(),
             QStringLiteral("landscape-1200x800.png"));
    QCOMPARE(item("infoKind")->property("text").toString(),
             QStringLiteral(".png"));
    QVERIFY2(item("infoSize")->property("text").toString() != QStringLiteral("—"),
             "the file size is not drawn");
    QCOMPARE(item("infoDimensions")->property("text").toString(),
             QStringLiteral("1200 × 800"));
    QCOMPARE(item("infoPath")->property("text").toString(), m_landscape);

    // Settings › Appearance hides the only page through the same
    // `setPanelVisible` every workspace exposes. With no panel left, the whole
    // column and its splitter go; showing Info brings both back.
    QVERIFY(m_viewer->property("infoPanelVisible").toBool());
    QSignalSpy layouts(m_viewer, SIGNAL(layoutRequested(QVariant)));
    QVERIFY(QMetaObject::invokeMethod(m_viewer, "setPanelVisible",
                                      Q_ARG(QVariant, QStringLiteral("info")),
                                      Q_ARG(QVariant, false)));
    QCoreApplication::processEvents();
    // The harness has no shell; the view reports the patch instead of writing
    // its own layout, so apply it the way `Main.qml` would.
    QVERIFY(layouts.count() >= 1);
    panels.insert(QStringLiteral("viewer.info"), false);
    layout.insert(QStringLiteral("panels"), panels);
    m_viewer->setProperty("layout", layout);
    QTRY_VERIFY(!name->isVisible());
    QVERIFY(!m_viewer->property("sidebarShown").toBool());
    QVERIFY(!panel->isVisible());
    QVERIFY(!item("viewerRightSplitter")->isVisible());
    m_viewer->setProperty("layout", QVariantMap{{QStringLiteral("panels"),
        QVariantMap{{QStringLiteral("viewer.quickAccess"), true},
                    {QStringLiteral("viewer.explorer"), true},
                    {QStringLiteral("viewer.info"), true}}}});
    QTRY_VERIFY(name->isVisible());

    QQuickItem* splitter = item("viewerRightSplitter");
    QVERIFY2(splitter != nullptr, "the viewer has no dock splitter");
    QVERIFY(splitter->isVisible());

    // A state flag no longer drives the sidebar: the layout's panels do.
    state.insert(QStringLiteral("rightPanelViewer"), false);
    m_viewer->setProperty("state", state);
    QTRY_VERIFY(panel->isVisible());
    QVERIFY2(splitter->isVisible(), "a stale state flag hid the splitter");
  }

  /// The Viewer's left panels are a column of their own, not a layer under the
  /// picture: the viewport starts where the dock ends.
  ///
  /// This is the real-window defect the first layout grab showed — the dock
  /// reported `visible: true` with a 260 px width while the centre column's
  /// The Viewer is focused on viewing: it has no left Quick Access / Explorer
  /// dock, and its toolbar Color & light button toggles the right panel onto
  /// the Color tab.
  void theLeftPanelsSitBesideThePicture()
  {
    QVERIFY2(item("viewerLeftPanel") == nullptr, "the viewer should not have a left dock");
    QVERIFY2(item("viewerLeftRail") == nullptr, "the viewer should not have a left rail");
    QVERIFY2(item("viewerRightRail") == nullptr, "the viewer should not have a right rail");

    QSignalSpy layoutSpy(m_viewer, SIGNAL(layoutRequested(QVariant)));
    QVariantMap panels;
    panels.insert(QStringLiteral("viewer.info"), false);
    m_viewer->setProperty("layout", QVariantMap{{QStringLiteral("panels"), panels}});
    QCoreApplication::processEvents();

    QVERIFY(QMetaObject::invokeMethod(m_viewer, "toggleColorAdjustPanel", Q_ARG(QVariant, QVariant())));
    QCOMPARE(layoutSpy.count(), 1);
    const QVariantMap patch = layoutSpy.at(0).at(0).toMap();
    QCOMPARE(patch.value(QStringLiteral("panels")).toMap().value(QStringLiteral("viewer.info")).toBool(),
             true);
  }

  /// "Show in folder" is the shell's job: the view only asks, and both the file
  /// menu and the canvas menu name the same request. A file manager is the
  /// desktop's, not the app's.
  void theCanvasMenuAsksTheShellToRevealTheFile()
  {
    QSignalSpy reveal(m_viewer, SIGNAL(revealPath(QString)));
    openCanvasMenu();
    QQuickItem* entry = canvasEntry(QStringLiteral("Show in folder"));
    QVERIFY2(entry != nullptr, "the canvas menu has no \"Show in folder\" entry");
    QVERIFY(entry->isEnabled());
    QVERIFY(QMetaObject::invokeMethod(entry, "click"));
    QTRY_COMPARE(reveal.count(), 1);
    QCOMPARE(reveal.at(0).at(0).toString(), m_viewer->property("currentPath").toString());
    QMetaObject::invokeMethod(canvasMenu(), "close");
  }

  // ---------------------------------------------------------------- keyboard

private:
  /// The Viewer holds keyboard focus while its workspace is up; a dead focus
  /// would make every test below look like a dead shortcut.
  void giveKeyboardFocus()
  {
    m_view->rootObject()->forceActiveFocus();
    QCoreApplication::processEvents();
    QVERIFY2(m_viewer->property("activeFocus").toBool(),
             "the Viewer never took keyboard focus");
  }

  /// Publish a folder of images without waiting for a decode.
  void showImages(const QStringList& images, int index)
  {
    m_viewer->setProperty("viewerImages", images);
    m_viewer->setProperty("entries", QVariantList());
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), images.value(index));
    state.insert(QStringLiteral("viewerIndex"), index);
    m_viewer->setProperty("state", state);
    QCoreApplication::processEvents();
  }

  static QStringList commandTypes(const QSignalSpy& spy)
  {
    QStringList types;
    for (const QList<QVariant>& call : spy) {
      types.append(call.at(0).toMap().value(QStringLiteral("type")).toString());
    }
    return types;
  }

private slots:
  /// Arrows, Page keys and Space walk the folder through Core's own
  /// `viewer_previous`/`viewer_next`, not through QML-side index arithmetic.
  void navigationKeysAskCoreForTheNeighbour()
  {
    showImages({ m_landscape, m_portrait }, 0);
    giveKeyboardFocus();
    QSignalSpy spy(m_viewer, SIGNAL(command(QVariant)));

    QTest::keyClick(m_view, Qt::Key_Right);
    QTest::keyClick(m_view, Qt::Key_PageDown);
    QTest::keyClick(m_view, Qt::Key_Space);
    QTest::keyClick(m_view, Qt::Key_Left);
    QTest::keyClick(m_view, Qt::Key_PageUp);
    QTest::keyClick(m_view, Qt::Key_Space, Qt::ShiftModifier);
    QCoreApplication::processEvents();

    QCOMPARE(commandTypes(spy),
             (QStringList{ QStringLiteral("viewer_next"), QStringLiteral("viewer_next"),
                           QStringLiteral("viewer_next"), QStringLiteral("viewer_previous"),
                           QStringLiteral("viewer_previous"),
                           QStringLiteral("viewer_previous") }));
  }

  /// Home/End jump without stepping, which is a `viewer_open` on that path.
  void homeAndEndOpenTheFolderEnds()
  {
    showImages({ m_landscape, m_portrait }, 0);
    giveKeyboardFocus();
    QSignalSpy spy(m_viewer, SIGNAL(command(QVariant)));

    QTest::keyClick(m_view, Qt::Key_End);
    QTest::keyClick(m_view, Qt::Key_Home);
    QCoreApplication::processEvents();

    QCOMPARE(spy.count(), 2);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("viewer_open"));
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("path")).toString(), m_portrait);
    QCOMPARE(spy.at(1).at(0).toMap().value(QStringLiteral("path")).toString(), m_landscape);
  }

  /// Zoom/fit keys own presentation state only: no command reaches Core, and
  /// `autoFit` follows the same rule the toolbar buttons use.
  void zoomKeysChangeTheViewNotTheState()
  {
    giveKeyboardFocus();
    QSignalSpy spy(m_viewer, SIGNAL(command(QVariant)));
    const qreal fitted = zoom();

    QTest::keyClick(m_view, Qt::Key_Plus);
    QCoreApplication::processEvents();
    QVERIFY2(zoom() > fitted, qPrintable(QStringLiteral("+ did not zoom in: %1").arg(zoom())));
    QCOMPARE(m_viewer->property("autoFit").toBool(), false);

    const qreal afterFirst = zoom();
    QTest::keyClick(m_view, Qt::Key_Plus);
    QCoreApplication::processEvents();
    QTest::keyClick(m_view, Qt::Key_Minus);
    QCoreApplication::processEvents();
    QVERIFY2(qAbs(zoom() - afterFirst) < 0.001,
             qPrintable(QStringLiteral("+ then − did not return to %1, it is %2")
                          .arg(afterFirst)
                          .arg(zoom())));

    QTest::keyClick(m_view, Qt::Key_0);
    QCoreApplication::processEvents();
    QCOMPARE(zoom(), 1.0);

    QTest::keyClick(m_view, Qt::Key_F);
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("autoFit").toBool(), true);
    QVERIFY2(qAbs(zoom() - fitted) < 0.001,
             qPrintable(QStringLiteral("F left the zoom at %1, expected the fit %2")
                          .arg(zoom())
                          .arg(fitted)));
    QCOMPARE(spy.count(), 0);
  }

  /// R/Shift+R and H/V are the canvas menu's rotate and flip, reached from the
  /// keyboard; T asks the shell to toggle the filmstrip.
  void presentationKeysTurnAndFlipThePicture()
  {
    giveKeyboardFocus();
    QSignalSpy spy(m_viewer, SIGNAL(command(QVariant)));

    QTest::keyClick(m_view, Qt::Key_R);
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("rotationAngle").toInt(), 90);
    QTest::keyClick(m_view, Qt::Key_R, Qt::ShiftModifier);
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("rotationAngle").toInt(), 0);

    QTest::keyClick(m_view, Qt::Key_H);
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("flipH").toBool(), true);
    QTest::keyClick(m_view, Qt::Key_V);
    QCoreApplication::processEvents();
    QCOMPARE(m_viewer->property("flipV").toBool(), true);

    QTest::keyClick(m_view, Qt::Key_T);
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("toggle_filmstrip"));
  }

  /// Up/Down nudge a zoomed picture through the same offsets a drag writes.
  void upAndDownPanTheZoomedPicture()
  {
    giveKeyboardFocus();
    zoomTo(2.0);
    const qreal startY = m_viewer->property("offsetY").toReal();

    QTest::keyClick(m_view, Qt::Key_Up);
    QCoreApplication::processEvents();
    const qreal afterUp = m_viewer->property("offsetY").toReal();
    QVERIFY2(afterUp > startY,
             qPrintable(QStringLiteral("Up did not move the picture: %1 -> %2")
                          .arg(startY)
                          .arg(afterUp)));

    QTest::keyClick(m_view, Qt::Key_Down);
    QCoreApplication::processEvents();
    QVERIFY2(m_viewer->property("offsetY").toReal() < afterUp,
             "Down did not move the picture back");
  }

  /// Delete trashes the image on screen once per press; Escape goes back to the
  /// Browser. Ctrl combinations belong to the shell and must not leak in.
  void deleteTrashesOnceAndEscapeReturnsToTheBrowser()
  {
    const QString path = m_landscape;
    showImages({ path, m_portrait }, 0);
    giveKeyboardFocus();
    QSignalSpy spy(m_viewer, SIGNAL(command(QVariant)));

    QTest::keyClick(m_view, Qt::Key_R, Qt::ControlModifier);
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 0);

    QTest::keyClick(m_view, Qt::Key_Delete);
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("type")).toString(),
             QStringLiteral("trash"));
    QCOMPARE(spy.at(0).at(0).toMap().value(QStringLiteral("paths")).toStringList(),
             QStringList{ path });

    // A held key arrives as the same key with `isAutoRepeat` set; it must not
    // trash again (the folder would empty one repeat at a time).
    QKeyEvent repeat(QEvent::KeyPress, Qt::Key_Delete, Qt::NoModifier, QString(), true);
    QCoreApplication::sendEvent(m_view, &repeat);
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 1);

    QTest::keyClick(m_view, Qt::Key_Escape);
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 2);
    const QVariantMap back = spy.at(1).at(0).toMap();
    QCOMPARE(back.value(QStringLiteral("type")).toString(), QStringLiteral("set_workspace"));
    QCOMPARE(back.value(QStringLiteral("workspace")).toString(), QStringLiteral("browser"));
  }

  /// A modal dialog owns the pointer. Qt still delivers pointer-handler events
  /// to the items *under* a popup, so a drag on the Settings header used to
  /// reach the Viewer's pan handler: the dialog stood still while the picture
  /// slid behind it. `Main.qml` disables the workspace loader while a modal
  /// dialog is visible; this pairs the real Viewer with the real dialog and
  /// asserts both halves of the contract — the dialog moves, the picture does
  /// not — and that the view takes the keyboard again once it is gone.
  void aModalDialogOwnsThePointer()
  {
    zoomTo(2.0);
    m_viewer->setProperty("offsetX", 0.0);
    m_viewer->setProperty("offsetY", 0.0);
    m_viewer->setProperty("rotationAngle", 0);
    QCoreApplication::processEvents();

    QQmlComponent component(&m_engine,
                            QUrl::fromLocalFile(qmlDir() + QStringLiteral("/SettingsDialog.qml")));
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));
    QScopedPointer<QObject> dialog(component.create());
    QVERIFY(dialog != nullptr);
    dialog->setParent(m_view);
    dialog->setProperty("parent", QVariant::fromValue(m_view->contentItem()));
    QMetaObject::invokeMethod(dialog.data(), "open");
    QTest::qWait(50);
    QVERIFY2(dialog->property("visible").toBool(), "the Settings dialog did not open");

    // The shell's side of the contract: the workspace loader goes disabled
    // while a modal dialog is open.
    m_viewer->setProperty("enabled", false);
    const qreal startX = dialog->property("x").toReal();
    const qreal startY = dialog->property("y").toReal();

    const QList<QQuickItem*> headers =
      visualItems(m_view->contentItem(), QStringLiteral("settingsHeader"));
    QVERIFY2(headers.size() == 1, "the dialog header is not in the window overlay");
    QQuickItem* header = headers.first();
    const QPoint from = header->mapToScene(QPointF(120, header->height() / 2.0)).toPoint();
    const QPoint to = from + QPoint(-80, 40);
    QTest::mousePress(m_view, Qt::LeftButton, Qt::NoModifier, from);
    for (int step = 1; step <= 4; ++step) {
      QTest::mouseMove(m_view, from + QPoint(-20 * step, 10 * step));
    }
    QTest::mouseRelease(m_view, Qt::LeftButton, Qt::NoModifier, to);
    QTest::qWait(50);

    QCOMPARE(dialog->property("x").toReal(), startX - 80.0);
    QCOMPARE(dialog->property("y").toReal(), startY + 40.0);
    QVERIFY2(qAbs(m_viewer->property("offsetX").toReal()) < 0.5,
             "the drag panned the picture under the modal dialog");
    QVERIFY2(qAbs(m_viewer->property("offsetY").toReal()) < 0.5,
             "the drag panned the picture under the modal dialog");

    // Closing the dialog brings the workspace back; the view must be the
    // keyboard target again, not a disabled item that quietly swallowed keys.
    QTest::keyClick(m_view, Qt::Key_Escape);
    m_viewer->setProperty("enabled", true);
    QTest::qWait(50);
    QVERIFY2(!dialog->property("visible").toBool(), "Escape did not close the dialog");
    QVERIFY2(m_viewer->property("activeFocus").toBool(),
             "the Viewer did not take focus back after the dialog closed");
    QTest::keyClick(m_view, Qt::Key_R);
    QTest::qWait(50);
    QCOMPARE(m_viewer->property("rotationAngle").toInt(), 90);
  }

  /// Switching between standard, simple, and compact hides the right dock
  /// and filmstrip in non-standard modes without mutating saved panel
  /// visibility, and activates the floating HUD only in compact mode.
  void viewerUiModesToggleChromeAndHud()
  {
    QQuickItem* rightPanel = item("viewerRightPanel");
    QVERIFY(rightPanel != nullptr);

    // Standard mode (default): right panel visible, compact HUD not active.
    QVariantMap layout;
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("standard"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(rightPanel->isVisible());
    {
      QQuickItem* compactHud = item("viewerCompactHud");
      QVERIFY(compactHud == nullptr || !compactHud->isVisible());
    }

    // Simple mode: right panel hidden by default, compact HUD off, and
    // toggling Info & Color opens/closes the right sidebar on demand.
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("simple"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(!rightPanel->isVisible());
    {
      QQuickItem* compactHud = item("viewerCompactHud");
      QVERIFY(compactHud == nullptr || !compactHud->isVisible());
    }

    QVERIFY(QMetaObject::invokeMethod(m_viewer, "toggleColorAdjustPanel", Q_ARG(QVariant, QVariant())));
    QCoreApplication::processEvents();
    QVERIFY2(rightPanel->isVisible(), "Simple mode should allow opening the right sidebar on button click");
    QVERIFY(QMetaObject::invokeMethod(m_viewer, "toggleColorAdjustPanel", Q_ARG(QVariant, QVariant())));
    QCoreApplication::processEvents();
    QVERIFY2(!rightPanel->isVisible(), "Second toggle should close the right sidebar in Simple mode");

    // Simple mode also allows toggling the filmstrip on demand (hidden by default).
    m_viewer->setProperty("viewerImages", QStringList{ m_landscape, m_portrait });
    QCoreApplication::processEvents();
    QVERIFY2(!m_viewer->property("filmstripShown").toBool(), "Filmstrip should be hidden by default in Simple mode");
    QVERIFY(QMetaObject::invokeMethod(m_viewer, "toggleFilmstrip"));
    QCoreApplication::processEvents();
    QVERIFY2(m_viewer->property("filmstripShown").toBool(), "Simple mode should allow toggling the filmstrip on");
    QVERIFY(QMetaObject::invokeMethod(m_viewer, "toggleFilmstrip"));
    QCoreApplication::processEvents();
    QVERIFY2(!m_viewer->property("filmstripShown").toBool(), "Second toggle should hide the filmstrip in Simple mode");

    // Compact mode: right panel hidden, compact HUD active.
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("compact"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(!rightPanel->isVisible());
    {
      QQuickItem* compactHud = item("viewerCompactHud");
      QVERIFY(compactHud != nullptr && compactHud->isVisible());
    }

    // Restore standard mode: previous panel visibility returns intact.
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("standard"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(rightPanel->isVisible());
    {
      QQuickItem* compactHud = item("viewerCompactHud");
      QVERIFY(compactHud == nullptr || !compactHud->isVisible());
    }
  }

  /// Switching between single, dual, and webtoon activates the matching
  /// display surface and auto-hides the bottom filmstrip in webtoon mode.
  void viewerDisplayModesSwitchSingleDualAndWebtoon()
  {
    QQuickItem* singleImg = item("viewerImage");
    QVERIFY(singleImg != nullptr);

    QVariantMap layout;
    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("single"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(singleImg->isVisible());
    QVERIFY(item("viewerDualSpread") == nullptr || !item("viewerDualSpread")->isVisible());
    QVERIFY(item("viewerWebtoonView") == nullptr || !item("viewerWebtoonView")->isVisible());

    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("dual"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(!singleImg->isVisible());
    QVERIFY(item("viewerDualSpread") != nullptr && item("viewerDualSpread")->isVisible());
    QVERIFY(item("viewerWebtoonView") == nullptr || !item("viewerWebtoonView")->isVisible());

    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("webtoon"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(!singleImg->isVisible());
    QVERIFY(item("viewerDualSpread") == nullptr || !item("viewerDualSpread")->isVisible());
    QVERIFY(item("viewerWebtoonView") != nullptr && item("viewerWebtoonView")->isVisible());

    // Restore single mode.
    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("single"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    QVERIFY(singleImg->isVisible());
  }

  /// Regression test: scrolling up at the first page in Webtoon mode must
  /// clamp to `ListView.originY` rather than `0`, so a non-zero `originY`
  /// after `positionViewAtIndex` never scrolls into blank black space above page 0.
  void webtoonScrollUpAtFirstPageRespectsOriginY()
  {
    QVariantMap layout;
    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("webtoon"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();

    QQuickItem* webtoon = item("viewerWebtoonView");
    QQuickItem* list = item("viewerWebtoonList");
    QVERIFY(webtoon != nullptr && list != nullptr);
    QTRY_VERIFY(webtoon->isVisible());

    QVERIFY(QMetaObject::invokeMethod(webtoon, "jumpToPage", Q_ARG(QVariant, 0)));
    QCoreApplication::processEvents();
    const qreal originY = list->property("originY").toReal();

    // Scroll up repeatedly past the top of page 0.
    for (int i = 0; i < 5; ++i) {
      QVERIFY(QMetaObject::invokeMethod(webtoon, "scrollBy", Q_ARG(QVariant, -300.0)));
    }
    QTest::qWait(200);
    const qreal contentY = list->property("contentY").toReal();
    QVERIFY2(contentY >= originY - 0.5,
             qPrintable(QStringLiteral("contentY (%1) scrolled above originY (%2)")
                          .arg(contentY).arg(originY)));

    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("single"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
  }

  /// Toggling Dual mode options (`mangaCoverSeparate`, `mangaPageGap`, `mangaRtl`)
  /// immediately updates the spread pairing and refits the two-page canvas.
  void dualModeUpdatesAndRefitsWhenOptionsChange()
  {
    QStringList portraitPair{ m_portrait, m_portrait };
    m_viewer->setProperty("viewerImages", portraitPair);
    QVariantMap state;
    state.insert(QStringLiteral("viewerPath"), m_portrait);
    state.insert(QStringLiteral("viewerIndex"), 0);
    m_viewer->setProperty("state", state);

    QVariantMap layout;
    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("dual"));
    layout.insert(QStringLiteral("mangaCoverSeparate"), true);
    layout.insert(QStringLiteral("mangaPageGap"), 8);
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();

    QQuickItem* dual = item("viewerDualSpread");
    QVERIFY(dual != nullptr);
    QTRY_VERIFY(dual->property("ready").toBool());
    QVERIFY2(!dual->property("hasRight").toBool(),
             "with separateCover=true, page 0 should be a solo cover spread");
    const qreal soloWidth = dual->property("contentWidth").toReal();

    // Turning off separateCover pairs pages (0, 1) and refits to the wider spread.
    layout.insert(QStringLiteral("mangaCoverSeparate"), false);
    m_viewer->setProperty("layout", layout);
    QTRY_VERIFY(dual->property("hasRight").toBool());
    QTRY_VERIFY(dual->property("ready").toBool());
    const qreal pairWidth8 = dual->property("contentWidth").toReal();
    QVERIFY2(pairWidth8 > soloWidth * 1.8, "pair spread should be roughly twice the solo width");

    // Increasing pageGap updates contentWidth immediately and keeps both pages fitted.
    layout.insert(QStringLiteral("mangaPageGap"), 16);
    m_viewer->setProperty("layout", layout);
    QTRY_COMPARE(dual->property("contentWidth").toReal(), pairWidth8 + 8.0);
    QTest::qWait(40);
    QVERIFY2(m_viewer->property("zoom").toReal() * dual->property("contentWidth").toReal()
               <= m_viewport->width() + 1.0,
             "two-page spread overflowed the viewport width after refit");

    // Turning separateCover back on returns to solo cover and refits.
    layout.insert(QStringLiteral("mangaCoverSeparate"), true);
    m_viewer->setProperty("layout", layout);
    QTRY_VERIFY(!dual->property("hasRight").toBool());
    QTRY_COMPARE(dual->property("contentWidth").toReal(), soloWidth);

    layout.insert(QStringLiteral("viewerDisplayMode"), QStringLiteral("single"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
  }

  /// Compact HUD supports docking to all 4 edges (`top`/`bottom`/`left`/`right`),
  /// switches orientation between horizontal and vertical, and shares Color & Light
  /// adjustments with Viewer's main color panel.
  void compactHudDocksFourEdgesAndSyncsColorPopover()
  {
    QVariantMap layout;
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("compact"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();

    QQuickItem* hud = item("viewerCompactHud");
    QQuickItem* pill = item("viewerCompactHudPill");
    QObject* colorPopover = object("viewerColorPopover");
    QObject* dockAdjust = object("viewerColorAdjustPanel");
    QVERIFY(hud != nullptr && pill != nullptr && colorPopover != nullptr && dockAdjust != nullptr);

    // Top (horizontal): wider than tall.
    hud->setProperty("edge", QStringLiteral("top"));
    QCoreApplication::processEvents();
    QVERIFY(!hud->property("vertical").toBool());
    QVERIFY(pill->width() > pill->height());

    // Left (vertical): taller than wide.
    hud->setProperty("edge", QStringLiteral("left"));
    QCoreApplication::processEvents();
    QVERIFY(hud->property("vertical").toBool());
    QVERIFY(pill->height() > pill->width());

    // Right (vertical) & Bottom (horizontal).
    hud->setProperty("edge", QStringLiteral("right"));
    QCoreApplication::processEvents();
    QVERIFY(hud->property("vertical").toBool());
    hud->setProperty("edge", QStringLiteral("bottom"));
    QCoreApplication::processEvents();
    QVERIFY(!hud->property("vertical").toBool());

    // Color & Light popover syncs bidirectionally with RightDock's ColorAdjustPanel.
    colorPopover->setProperty("brightness", 0.25);
    QCoreApplication::processEvents();
    QVERIFY(qAbs(dockAdjust->property("brightness").toReal() - 0.25) < 0.001);
    dockAdjust->setProperty("brightness", 0.0);
    QCoreApplication::processEvents();
    QVERIFY(qAbs(colorPopover->property("brightness").toReal()) < 0.001);

    // Restore standard mode & top edge.
    hud->setProperty("edge", QStringLiteral("top"));
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("standard"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
  }

  /// Regression test: dragging the Compact HUD's grip handle snaps the HUD to
  /// another edge without panning the zoomed image underneath.
  void draggingCompactHudDoesNotPanImage()
  {
    QVariantMap layout;
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("compact"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
    zoomTo(2.0);

    QQuickItem* hud = item("viewerCompactHud");
    QQuickItem* grip = item("compactHudDragGrip");
    QVERIFY(hud != nullptr && grip != nullptr);
    hud->setProperty("edge", QStringLiteral("top"));
    hud->setProperty("pinned", true);
    QTRY_VERIFY(grip->isVisible());

    QSignalSpy layoutSpy(m_viewer, SIGNAL(layoutRequested(QVariant)));
    const QPoint start = grip->mapToScene(QPointF(grip->width() / 2.0, grip->height() / 2.0)).toPoint();
    const QPoint target(24, m_view->height() / 2);
    QTest::mousePress(m_view, Qt::LeftButton, Qt::NoModifier, start);
    for (int step = 1; step <= 5; ++step) {
      const QPoint pt = start + (target - start) * step / 5;
      QTest::mouseMove(m_view, pt);
    }
    QTest::mouseRelease(m_view, Qt::LeftButton, Qt::NoModifier, target);
    QTest::qWait(50);

    QCOMPARE(hud->property("edge").toString(), QStringLiteral("left"));
    QCOMPARE(layoutSpy.count(), 1);
    QCOMPARE(layoutSpy.at(0).at(0).toMap().value(QStringLiteral("compactHudEdge")).toString(),
             QStringLiteral("left"));
    QVERIFY2(qAbs(m_viewer->property("offsetX").toReal()) < 0.5,
             "dragging the Compact HUD panned the image horizontally");
    QVERIFY2(qAbs(m_viewer->property("offsetY").toReal()) < 0.5,
             "dragging the Compact HUD panned the image vertically");

    hud->setProperty("pinned", false);
    hud->setProperty("edge", QStringLiteral("top"));
    layout.insert(QStringLiteral("viewerUiMode"), QStringLiteral("standard"));
    m_viewer->setProperty("layout", layout);
    QCoreApplication::processEvents();
  }
};

QTEST_MAIN(TestViewer)
#include "tst_viewer.moc"
