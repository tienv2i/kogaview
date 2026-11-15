#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#include <kogaview_desktop/src/bridge.cxxqt.h>

#ifdef KOGAVIEW_DEV_HARNESS
// M0-only evidence harness: grab the app window after it is exposed. M1 replaces
// this with the permission-checked `debug.screenshot` command/query path.
static void installDevScreenshotHarness(QQmlApplicationEngine& engine,
                                        QGuiApplication& app)
{
  const QString path = qEnvironmentVariable("KOGAVIEW_DEV_SCREENSHOT");
  if (path.isEmpty()) {
    return;
  }

  auto grab = [&engine, &app, path]() {
    auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().value(0));
    if (window == nullptr) {
      qCritical() << "KogaView dev screenshot: no QQuickWindow root object";
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

  QTimer::singleShot(
    qEnvironmentVariableIntValue("KOGAVIEW_DEV_SCREENSHOT_DELAY_MS") > 0
      ? qEnvironmentVariableIntValue("KOGAVIEW_DEV_SCREENSHOT_DELAY_MS")
      : 1500,
    &app,
    grab);
}
#endif

int main(int argc, char* argv[])
{
  QGuiApplication app(argc, argv);

  QGuiApplication::setApplicationName(kogaview_display_name());
  QGuiApplication::setApplicationVersion(kogaview_app_version());
  QGuiApplication::setOrganizationName(QStringLiteral("KogaView"));
  QGuiApplication::setDesktopFileName(kogaview_app_id());

  if (!kogaview_initialize()) {
    qWarning() << "KogaView: structured logging is unavailable; continuing with stderr only";
  }

  QQmlApplicationEngine engine;
  const QUrl url(QStringLiteral(
    "qrc:/qt/qml/io/github/huynhat/KogaView/qml/Main.qml"));

  QObject::connect(
    &engine,
    &QQmlApplicationEngine::objectCreated,
    &app,
    [url](QObject* object, const QUrl& objectUrl) {
      if (!object && objectUrl == url) {
        qCritical() << "KogaView: failed to load QML root object" << objectUrl;
        QCoreApplication::exit(-1);
      }
    },
    Qt::QueuedConnection);

  engine.load(url);
  if (engine.rootObjects().isEmpty()) {
    qCritical() << "KogaView: no QML root objects after load";
    return -1;
  }

#ifdef KOGAVIEW_DEV_HARNESS
  installDevScreenshotHarness(engine, app);
#endif

  const int result = app.exec();
  kogaview_shutdown();
  return result;
}
