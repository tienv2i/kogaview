#include "platform.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>

#include <cstdio>

#include <kogaview_desktop/src/bridge.cxxqt.h>

namespace {

constexpr auto kMainQml = "qrc:/qt/qml/io/github/tienv2i/KogaView/qml/Main.qml";

#ifdef KOGAVIEW_DEV_HARNESS
// Debug-only QA hook: dispatch protocol commands through the same gateway the
// UI uses so workspaces and panels can be exercised for screenshots without
// synthetic input events. `KOGAVIEW_DEV_COMMANDS` holds `;`-separated command
// objects, for example `{"type":"set_workspace","workspace":"editor"}`.
void dispatchDevCommands(QObject* rootObject, QGuiApplication& app)
{
  const QString raw = qEnvironmentVariable("KOGAVIEW_DEV_COMMANDS");
  if (raw.isEmpty()) {
    return;
  }

  QObject* bridge = rootObject->findChild<QObject*>(QStringLiteral("bridge"));
  if (bridge == nullptr) {
    qCritical() << "KogaView dev commands: bridge object not found";
    return;
  }

  const QStringList commands = raw.split(QLatin1Char(';'), Qt::SkipEmptyParts);
  int index = 0;
  for (const QString& command : commands) {
    const int delay = 600 + index * 900;
    ++index;
    // Background file operations take time; stagger so each command is not
    // rejected with `busy` by the previous one.
    QTimer::singleShot(delay, &app, [bridge, command, index]() {
      const QString envelope =
        QStringLiteral(R"({"id":"dev-%1","protocol":1,"command":%2})")
          .arg(index)
          .arg(command);
      QString result;
      const bool invoked = QMetaObject::invokeMethod(
        bridge, "dispatch", Q_RETURN_ARG(QString, result), Q_ARG(QString, envelope));
      qInfo().noquote() << "KogaView dev command" << command << "->" << result;
      if (!invoked) {
        qCritical() << "KogaView dev commands: dispatch failed";
      }
    });
  }
}

// Debug-only evidence harness: grab the app window after it is exposed.
// The permission-checked `debug.screenshot` command replaces this later.
void installDevHarness(QObject* rootObject, QGuiApplication& app, PlatformHelper& platform)
{
  // QA hook: print the Viewer canvas geometry so layout and centring
  // regressions can be caught without pixel measurements. Geometry only; it
  // never injects input events.
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_GEOM")) {
    auto* timer = new QTimer(&app);
    timer->setInterval(400);
    QObject::connect(timer, &QTimer::timeout, &app, [rootObject]() {
      QObject* viewer = rootObject->findChild<QObject*>(QStringLiteral("viewer"));
      QObject* viewport = rootObject->findChild<QObject*>(QStringLiteral("viewerViewport"));
      QObject* canvas = rootObject->findChild<QObject*>(QStringLiteral("viewerCanvas"));
      if (viewer == nullptr || viewport == nullptr || canvas == nullptr) {
        return;
      }
      qInfo() << "KogaView dev geom: viewport" << viewport->property("width").toDouble()
              << viewport->property("height").toDouble() << "canvas"
              << canvas->property("x").toDouble() << canvas->property("y").toDouble()
              << canvas->property("width").toDouble()
              << canvas->property("height").toDouble() << "scale"
              << canvas->property("scale").toDouble() << "rotation"
              << canvas->property("rotation").toDouble() << "offset"
              << viewer->property("offsetX").toDouble()
              << viewer->property("offsetY").toDouble() << "zoom"
              << viewer->property("zoom").toDouble();
    });
    timer->start();
  }

  // QA hook: inject one touchpad-typed wheel event into the running window so
  // the scroll-to-zoom path can be observed on the real shell (toolbars,
  // filmstrip, bridge-owned state) without physical input. The event is
  // constructed exactly like a Wayland touchpad scroll: a touchpad pointing
  // device carrying `pixelDelta` and no `angleDelta`.
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_WHEEL")) {
    QTimer::singleShot(2500, &app, [rootObject]() {
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      QObject* viewer = rootObject->findChild<QObject*>(QStringLiteral("viewer"));
      if (window == nullptr || viewer == nullptr) {
        qWarning() << "KogaView dev wheel: window or viewer not found";
        return;
      }
      const QPointF local(window->width() / 2.0, window->height() / 2.0);
      static auto* touchpad =
        new QPointingDevice(QStringLiteral("kogaview qa touchpad"), 9001,
                            QInputDevice::DeviceType::TouchPad,
                            QPointingDevice::PointerType::Finger,
                            QInputDevice::Capability::Scroll
                              | QInputDevice::Capability::PixelScroll,
                            1, 3);
      const double before = viewer->property("zoom").toDouble();
      const double offsetBefore = viewer->property("offsetY").toDouble();
      QWheelEvent event(local, QPointF(window->mapToGlobal(local.toPoint())), QPoint(0, 15),
                        QPoint(0, 0), Qt::NoButton, Qt::NoModifier, Qt::ScrollUpdate, false,
                        Qt::MouseEventNotSynthesized, touchpad);
      QCoreApplication::sendEvent(window, &event);
      qInfo() << "KogaView dev wheel: zoom" << before << "->"
              << viewer->property("zoom").toDouble() << "offsetY" << offsetBefore << "->"
              << viewer->property("offsetY").toDouble();
    });
  }

  // Exercise the platform image clipboard without synthetic input events.
  const QString copyImage = qEnvironmentVariable("KOGAVIEW_DEV_COPY_IMAGE");
  if (!copyImage.isEmpty()) {
    QTimer::singleShot(1200, &platform, [&platform, copyImage]() { platform.copyImage(copyImage); });
  }

  const QString path = qEnvironmentVariable("KOGAVIEW_DEV_SCREENSHOT");
  if (!path.isEmpty()) {
    auto grab = [rootObject, &app, path]() {
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      if (window == nullptr) {
        qCritical() << "KogaView dev screenshot: root object is not a QQuickWindow";
        app.exit(3);
        return;
      }
      if (!window->isExposed()) {
        qCritical() << "KogaView dev screenshot: window is not exposed";
        app.exit(4);
        return;
      }

      const QImage image = window->grabWindow();
      const QFileInfo info(path);
      if (!QDir().mkpath(info.absolutePath()) || image.isNull() ||
          !image.save(path, "PNG")) {
        qCritical() << "KogaView dev screenshot: failed to save" << path;
        app.exit(5);
        return;
      }

      qInfo() << "KogaView dev screenshot" << path << image.width() << "x"
              << image.height();
      if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_EXIT_AFTER_SCREENSHOT")) {
        app.exit(0);
      }
    };

    const int delay = qEnvironmentVariableIntValue("KOGAVIEW_DEV_SCREENSHOT_DELAY_MS");
    QTimer::singleShot(delay > 0 ? delay : 1500, &app, grab);
  }

  const int exitAfter = qEnvironmentVariableIntValue("KOGAVIEW_DEV_EXIT_AFTER_MS");
  if (exitAfter > 0) {
    QTimer::singleShot(exitAfter, &app, [&app]() { app.exit(0); });
  }
}
#endif

/// Load the QML entry point, reporting compile and instantiation errors.
/// A missing root object must fail loudly instead of starting a blank session.
QObject* loadUserInterface(QQmlEngine& engine, const QStringList& launchArguments,
                           PlatformHelper& platform)
{
  engine.rootContext()->setContextProperty(QStringLiteral("Platform"), &platform);
  engine.rootContext()->setContextProperty(QStringLiteral("launchArgs"), launchArguments);

  const QUrl url(QString::fromLatin1(kMainQml));
  QQmlComponent component(&engine, url);
  if (component.isError()) {
    qCritical().noquote() << "KogaView: cannot load" << url.toString() << "\n"
                          << component.errorString();
    return nullptr;
  }

  QObject* rootObject = component.create();
  if (rootObject == nullptr) {
    qCritical().noquote() << "KogaView: cannot instantiate" << url.toString() << "\n"
                          << component.errorString();
  }
  return rootObject;
}

} // namespace

int main(int argc, char* argv[])
{
  QGuiApplication app(argc, argv);

  QGuiApplication::setApplicationName(kogaview_display_name());
  QGuiApplication::setApplicationVersion(kogaview_app_version());
  QGuiApplication::setApplicationDisplayName(kogaview_display_name());
  QGuiApplication::setOrganizationName(QStringLiteral("KogaView"));
  QGuiApplication::setDesktopFileName(kogaview_app_id());

  QStringList launchArguments = QCoreApplication::arguments().mid(1);
  if (launchArguments.contains(QStringLiteral("--version"))) {
    std::printf("%s %s (%s)\n", qPrintable(kogaview_display_name()),
                qPrintable(kogaview_app_version()), qPrintable(kogaview_app_id()));
    return 0;
  }
  if (launchArguments.contains(QStringLiteral("--help")) ||
      launchArguments.contains(QStringLiteral("-h"))) {
    std::printf("KogaView — browse, view and edit photos\n\n"
                "Usage:\n"
                "  kogaview                    open the browser workspace\n"
                "  kogaview open FILE...       open images in the viewer\n"
                "  kogaview open-folder DIR    open a folder in the browser\n"
                "  kogaview --version          print version and app id\n");
    return 0;
  }

  if (!kogaview_initialize()) {
    qWarning() << "KogaView: structured logging is unavailable; continuing with stderr only";
  }

  PlatformHelper platform;
  QQmlEngine engine;

  QObject* rootObject = loadUserInterface(engine, launchArguments, platform);
  if (rootObject == nullptr) {
    kogaview_shutdown();
    return 1;
  }

  QObject::connect(&engine, &QQmlEngine::quit, &app, &QGuiApplication::quit);
  QObject::connect(&engine, &QQmlEngine::exit, &app, &QCoreApplication::exit);

#ifdef KOGAVIEW_DEV_HARNESS
  installDevHarness(rootObject, app, platform);
  dispatchDevCommands(rootObject, app);
#endif

  const int result = app.exec();
  delete rootObject;
  kogaview_shutdown();
  return result;
}
