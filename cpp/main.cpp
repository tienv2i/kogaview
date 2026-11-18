#include "platform.h"
#include "language.h"
#include "thumbnailcache.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLibraryInfo>
#include <QJsonObject>
#include <QMouseEvent>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>

// Only the evidence harness drives real pointer sequences; the header is absent
// from a release build, where Qt6::Test is not linked (`CMakeLists.txt` guards
// both on the Debug build type). Including it unconditionally is what made the
// first `just install` fail to compile.
#ifdef KOGAVIEW_DEV_HARNESS
#include <QTest>
#endif

#include <algorithm>
#include <cstdio>

#include <kogaview_desktop/src/bridge.cxxqt.h>

namespace {

constexpr auto kMainQml = "qrc:/qt/qml/io/github/tienv2i/KogaView/qml/Main.qml";

#ifdef KOGAVIEW_DEV_HARNESS
/// Print the two folders that decide where the explorer is rooted, so
/// "the tree root is not the open folder" is checkable from a log, plus what the
/// thumbnail cache holds on disk.
void logDevState(QObject* rootObject, QObject* bridge, ThumbnailCache* thumbnails)
{
  if (!qEnvironmentVariableIsSet("KOGAVIEW_DEV_STATE") || bridge == nullptr) {
    return;
  }
  const QString snapshot = bridge->property("stateJson").toString();
  const QJsonObject state = QJsonDocument::fromJson(snapshot.toUtf8()).object();
  qInfo().noquote() << "KogaView dev state: rootFolder"
                    << state.value(QStringLiteral("rootFolder")).toString() << "currentFolder"
                    << state.value(QStringLiteral("currentFolder")).toString() << "workspace"
                    << state.value(QStringLiteral("workspace")).toString() << "treeRevision"
                    << static_cast<qint64>(state.value(QStringLiteral("treeRevision")).toDouble());
  if (thumbnails != nullptr) {
    qInfo().noquote() << "KogaView dev thumbnails: entries" << thumbnails->entryCount() << "bytes"
                      << thumbnails->bytesUsed() << "hits" << thumbnails->hits() << "generated"
                      << thumbnails->generated() << "queued" << thumbnails->queued() << "dir"
                      << thumbnails->directory();
  }
  // The tree keeps its own expansion (it outlives the nodes), so read it from
  // the view: a refresh after a file operation must keep both these paths and
  // the current folder above.
  if (QObject* browser = rootObject->findChild<QObject*>(QStringLiteral("browser"))) {
    QQmlExpression expression(QQmlEngine::contextForObject(browser), browser,
                              QStringLiteral("Object.keys(expandedPaths).sort().join(' ')"));
    qInfo().noquote() << "KogaView dev tree: expanded" << expression.evaluate().toString();
  }
}

// Debug-only QA hook: dispatch protocol commands through the same gateway the
// UI uses so workspaces and panels can be exercised for screenshots without
// synthetic input events. `KOGAVIEW_DEV_COMMANDS` holds `;`-separated command
// objects, for example `{"type":"set_workspace","workspace":"editor"}`.
void dispatchDevCommands(QObject* rootObject, QGuiApplication& app, ThumbnailCache& thumbnails)
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
  // A fresh debug build spends seconds loading QML and the first paint, and
  // async commands (editor_open decodes on a worker) need the poll loop up
  // before the edits arrive. Both are why the batch can be postponed.
  bool startOk = false;
  const int startMs = qEnvironmentVariableIntValue("KOGAVIEW_DEV_COMMANDS_START_MS", &startOk);
  const int baseDelay = startOk && startMs > 0 ? startMs : 600;
  // The spacing between commands; a decode lands after the command that started
  // it, so a batch that edits the document needs more than the 900 ms a
  // screenshot-only batch needs.
  const int stagger = qEnvironmentVariableIntValue("KOGAVIEW_DEV_COMMANDS_STAGGER_MS") > 0
                        ? qEnvironmentVariableIntValue("KOGAVIEW_DEV_COMMANDS_STAGGER_MS")
                        : 900;
  int index = 0;
  for (const QString& command : commands) {
    const int delay = baseDelay + index * stagger;
    ++index;
    // Background file operations take time; stagger so each command is not
    // rejected with `busy` by the previous one.
    QTimer::singleShot(delay, &app, [bridge, rootObject, command, index, &thumbnails]() {
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
      logDevState(rootObject, bridge, &thumbnails);
    });
  }
}

// Debug-only evidence harness: grab the app window after it is exposed.
// The permission-checked `debug.screenshot` command replaces this later.
void installDevHarness(QObject* rootObject, QGuiApplication& app, PlatformHelper& platform,
                       ThumbnailCache& thumbnails)
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

  // QA hook: a right click in the viewer's viewing area, delivered through the
  // window like a real one, so the canvas menu can be photographed with the
  // desktop's own font and icon theme. It goes through the same `TapHandler` a
  // physical right click reaches; only the pointer is synthetic.
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_VIEWER_MENU")) {
    QTimer::singleShot(2500, &app, [rootObject]() {
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      auto* viewport = rootObject->findChild<QQuickItem*>(QStringLiteral("viewerViewport"));
      QObject* menu = rootObject->findChild<QObject*>(QStringLiteral("viewerMenu"));
      if (window == nullptr || viewport == nullptr || menu == nullptr) {
        qWarning() << "KogaView dev viewer menu: window, viewport or menu not found";
        return;
      }
      const QPointF local =
        viewport->mapToScene(QPointF(viewport->width() / 2.0, viewport->height() / 2.0));
      const QPointF global = window->mapToGlobal(local.toPoint());
      QMouseEvent press(QEvent::MouseButtonPress, local, global, Qt::RightButton,
                        Qt::RightButton, Qt::NoModifier);
      QCoreApplication::sendEvent(window, &press);
      QMouseEvent release(QEvent::MouseButtonRelease, local, global, Qt::RightButton,
                          Qt::NoButton, Qt::NoModifier);
      QCoreApplication::sendEvent(window, &release);
      // `menu.x`/`menu.y` are relative to the popup's parent (which `popup()`
      // re-parents to the item it is given), so the window position is the
      // picture's business; the click point below is in window coordinates.
      qInfo() << "KogaView dev viewer menu: open" << menu->property("visible").toBool()
              << "click(window)" << local << "menu x,y(parent)" << menu->property("x").toDouble()
              << menu->property("y").toDouble() << "size"
              << menu->property("width").toDouble() << menu->property("height").toDouble();
    });
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

  // Record what the shell can offer a file dialog, so the format list is read
  // from the running app rather than restated in a report.
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_FORMATS")) {
    QTimer::singleShot(1200, &platform, [&platform]() {
      qInfo().noquote() << "KogaView dev formats filter" << platform.imageNameFilter();
      qInfo().noquote() << "KogaView dev formats save" << platform.saveNameFilters().join(";");
      QVariantList languages = platform.languages();
      QStringList codes;
      for (const QVariant& language : languages) {
        codes << language.toMap().value(QStringLiteral("code")).toString();
      }
      qInfo().noquote() << "KogaView dev formats languages" << codes.join(",");
    });
  }

  // Exercise the platform image clipboard without synthetic input events.
  const QString copyImage = qEnvironmentVariable("KOGAVIEW_DEV_COPY_IMAGE");
  if (!copyImage.isEmpty()) {
    QTimer::singleShot(1200, &platform, [&platform, copyImage]() { platform.copyImage(copyImage); });
  }

  const QString path = qEnvironmentVariable("KOGAVIEW_DEV_SCREENSHOT");
  if (!path.isEmpty()) {
    // The grab has to come from an exposed window. A covered window on this
    // Wayland session stops receiving frame callbacks and reports itself
    // unexposed, and `grabWindow()` then returns the last *committed* frame —
    // which, right after the launch resize, is the pre-fit one. That produced a
    // screenshot of a picture at the wrong zoom with no hint, while the window's
    // own properties said `zoom 1`. So the hook asks to be raised and activated
    // (a client may do that while it has focus), waits for exposure, and fails
    // the run instead of saving a frame it cannot vouch for.
    auto* clock = new QElapsedTimer;
    clock->start();
    auto* retry = new QTimer(&app);
    retry->setInterval(250);
    QObject::connect(retry, &QTimer::timeout, &app, [rootObject, &app, path, retry, clock]() {
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      if (window == nullptr) {
        qCritical() << "KogaView dev screenshot: root object is not a QQuickWindow";
        app.exit(3);
        return;
      }
      if (!window->isExposed()) {
        if (clock->elapsed() < 20000) {
          qInfo() << "KogaView dev screenshot: waiting for an exposed window"
                  << clock->elapsed() << "ms";
          return;
        }
        qCritical() << "KogaView dev screenshot: window never became exposed";
        app.exit(4);
        return;
      }
      retry->stop();

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
    });

    const int delay = qEnvironmentVariableIntValue("KOGAVIEW_DEV_SCREENSHOT_DELAY_MS");
    QTimer::singleShot(delay > 0 ? delay : 1500, &app, [retry, rootObject]() {
      // An occluded window is not exposed, and its last frame is not the
      // current one. Ask the compositor to bring it forward before waiting.
      if (auto* window = qobject_cast<QQuickWindow*>(rootObject)) {
        window->raise();
        window->requestActivate();
      }
      retry->start();
    });
  }

  // QA hook: drive a real interface path that normally needs a click. Only the
  // two shell requests are supported, and they are invoked through the same
  // signals the toolbar button and the menu emit.
  //   KOGAVIEW_DEV_UI_REQUEST=open-folder       -> browser `requestOpenFolder`
  //   KOGAVIEW_DEV_UI_REQUEST=open-external     -> browser `openExternal`
  //   KOGAVIEW_DEV_UI_REQUEST=open-with         -> browser `openWith`
  //   KOGAVIEW_DEV_UI_REQUEST=context-menu-trigger -> click one entry of a menu
  //     of this window, so its `onTriggered` really runs: `_MENU` names the menu
  //     object (`fileMenu` default, `viewerMenu` or `editorMenu`), `_ARG` is the
  //     path for `fileMenu`, `_ARG2` the entry's text (default "Edit")
  //   KOGAVIEW_DEV_UI_REQUEST=context-menu      -> `fileMenu` on the entry at
  //     `KOGAVIEW_DEV_UI_REQUEST_ARG`, or `folderMenu` without one, for a
  //     screenshot of the menu a right click would open
  //     (`KOGAVIEW_DEV_UI_REQUEST_ARG` is the path to hand over)
  //   KOGAVIEW_DEV_UI_REQUEST=settings          -> `openSettings()` on the shell,
  //     the same function the "Settings…" menu entry calls, for a screenshot of
  //     the dialog
  //   `KOGAVIEW_DEV_UI_REQUEST_REPEAT_MS` fires it repeatedly, which is how the
  //   "a dismissed dialog does not block the next one" path is observed.
  const QString uiRequest = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST");
  if (!uiRequest.isEmpty()) {
    const int requestDelay = qEnvironmentVariableIntValue("KOGAVIEW_DEV_UI_REQUEST_DELAY_MS");
    const QString requestArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG");
    auto fire = [rootObject, uiRequest, requestArg, requestDelay, &app]() {
      if (uiRequest == QLatin1String("settings")) {
        // The shell's own function, so the dialog receives the stored theme and
        // checkbox values exactly as the menu entry hands them over.
        const bool opened = QMetaObject::invokeMethod(rootObject, "openSettings");
        qInfo().noquote() << "KogaView dev ui request settings"
                          << (opened ? "emitted" : "not supported");
        return;
      }
      bool emitted = false;
      QObject* browser = rootObject->findChild<QObject*>(QStringLiteral("browser"));
      if (browser == nullptr && !uiRequest.startsWith(QLatin1String("editor-")) &&
          uiRequest != QLatin1String("leave-guard") &&
          !(uiRequest == QLatin1String("context-menu-trigger") &&
            qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_MENU") == QLatin1String("viewerMenu"))) {
        qWarning() << "KogaView dev ui request: browser view not found";
        return;
      }
      if (uiRequest == QLatin1String("open-folder")) {
        emitted = QMetaObject::invokeMethod(browser, "requestOpenFolder");
      } else if (uiRequest == QLatin1String("open-external")) {
        emitted = !requestArg.isEmpty() &&
                  QMetaObject::invokeMethod(browser, "openExternal",
                                            Q_ARG(QString, requestArg));
      } else if (uiRequest == QLatin1String("open-with")) {
        emitted = !requestArg.isEmpty() &&
                  QMetaObject::invokeMethod(browser, "openWith", Q_ARG(QString, requestArg));
      } else if (uiRequest == QLatin1String("context-menu")) {
        // The menu a right click would open, so its width can be photographed.
        // Only the menus an entry opens are named here; the quick-access menu
        // needs a favourite, which this harness does not know.
        const QString name = requestArg.isEmpty() ? QStringLiteral("folderMenu")
                                                  : QStringLiteral("fileMenu");
        QObject* menu = rootObject->findChild<QObject*>(name);
        if (menu != nullptr && !requestArg.isEmpty()) {
          browser->setProperty("menuPath", requestArg);
          browser->setProperty("menuIsDir", true);
          browser->setProperty("menuIsImage", true);
        }
        emitted = menu != nullptr && QMetaObject::invokeMethod(menu, "popup");
      } else if (uiRequest == QLatin1String("context-menu-trigger")) {
        // Activate one entry of `fileMenu` the way a click does, so the commands
        // the entry emits (`select`, `set_workspace`, `editor_open`) really run.
        // `KOGAVIEW_DEV_UI_REQUEST_ARG` is the path; `_ARG2` names the entry
        // whose `text` matches (default "Edit").
        const QString entryText = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const QString menuName = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_MENU");
        const QString which = menuName.isEmpty() ? QStringLiteral("fileMenu") : menuName;
        QObject* menu = rootObject->findChild<QObject*>(which);
        if (menu == nullptr) {
          qWarning() << "KogaView dev ui request:" << which << "missing";
          return;
        }
        if (which == QLatin1String("fileMenu")) {
          if (requestArg.isEmpty()) {
            qWarning() << "KogaView dev ui request: fileMenu needs a path";
            return;
          }
          browser->setProperty("menuPath", requestArg);
          browser->setProperty("menuIsDir", false);
          browser->setProperty("menuIsImage", true);
        }
        const QString wanted = entryText.isEmpty() ? QStringLiteral("Edit") : entryText;
        // The items are QObject children of the Menu, declared in QML; a
        // declared `MenuItem` is not in the `contentData` list.
        // The items are QObject children of the Menu, declared in QML; a
        // declared `MenuItem` is not in the `contentData` list. `click()` is
        // what a press-and-release on the entry does, so `onTriggered` runs.
        QObject* entry = nullptr;
        for (QObject* candidate : menu->children()) {
          if (candidate->property("text").toString() == wanted) {
            entry = candidate;
            break;
          }
        }
        emitted = entry != nullptr && QMetaObject::invokeMethod(entry, "click");
        // The three commands the entry sends in one turn, replayed for the log:
        // if the entry's own `editor_open` is dropped, this shows whether the
        // same three calls survive when made from outside the menu.
        if (emitted) {
          QJsonArray results;
          const QJsonArray commands{QJsonObject{{"type", "select"},
                                                {"paths", QJsonArray{requestArg}}},
                                    QJsonObject{{"type", "set_workspace"},
                                                {"workspace", "editor"}},
                                    QJsonObject{{"type", "editor_open"}, {"path", requestArg}}};
          for (const QJsonValue& value : commands) {
            const QJsonObject command = value.toObject();
            QVariant returned;
            QMetaObject::invokeMethod(rootObject, "send", Q_RETURN_ARG(QVariant, returned),
                                      Q_ARG(QVariant, QVariant(command.toVariantMap())));
            results.append(QJsonValue::fromVariant(returned));
          }
          qInfo().noquote() << "KogaView dev ui request replay" << results;
        }
        qInfo().noquote() << "KogaView dev ui request context-menu-trigger" << wanted
                          << (emitted ? "triggered" : "not found");
      } else if (uiRequest == QLatin1String("leave-guard")) {
        // The switcher's own path: `guardEditorLeave` is what a workspace click
        // and the window close go through, so an unsaved document opens the
        // three-answer dialog exactly as it would for a hand.
        QVariantMap target;
        target.insert(QStringLiteral("workspace"),
                      requestArg.isEmpty() ? QStringLiteral("browser") : requestArg);
        emitted = QMetaObject::invokeMethod(rootObject, "guardEditorLeave",
                                            Q_ARG(QVariant, QVariant(target)));
        // `_ARG2` answers the dialog the way its own buttons do, so a click that
        // only exists in QML can be driven: `discard`, `cancel` or `save`.
        const QString answer = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        if (!answer.isEmpty()) {
          QTimer::singleShot(1500, rootObject, [rootObject, answer]() {
            QObject* dialog = rootObject->findChild<QObject*>(QStringLiteral("unsavedDialog"));
            QObject* button = rootObject->findChild<QObject*>(
              QStringLiteral("unsaved") + answer.at(0).toUpper() + answer.mid(1));
            if (button == nullptr || dialog == nullptr) {
              qWarning() << "KogaView dev ui request: no unsaved dialog button" << answer;
              return;
            }
            // The dialog's button `click()` runs the same handler a press does.
            QMetaObject::invokeMethod(button, "click");
            qInfo().noquote() << "KogaView dev ui request unsaved answer" << answer;
          });
        }
        qInfo().noquote() << "KogaView dev ui request leave-guard"
                          << (emitted ? "handled" : "not found");
      } else if (uiRequest == QLatin1String("editor-resize")) {
        // The Resize panel without a pointer: the tool button and the live
        // preview toggle are `click()`ed (the same handler a press runs), and
        // the size dropdown is written the way its own selection writes it.
        // `_ARG` is WIDTHxHEIGHT of a preset, default 1024x1024.
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const QString size = requestArg.isEmpty() ? QStringLiteral("1024x1024") : requestArg;
        const QStringList parts = size.split(QLatin1Char('x'));
        const int wantedWidth = parts.value(0).toInt();
        const int wantedHeight = parts.value(1).toInt();
        QObject* tool = editor->findChild<QObject*>(QStringLiteral("toolResize"));
        if (tool == nullptr) {
          qWarning() << "KogaView dev ui request: Resize tool button missing";
          return;
        }
        QMetaObject::invokeMethod(tool, "click");
        QObject* preset = editor->findChild<QObject*>(QStringLiteral("sizePreset"));
        const QVariantList presets = editor->property("sizePresets").toList();
        int index = -1;
        for (int i = 0; i < presets.size(); ++i) {
          const QVariantMap entry = presets.at(i).toMap();
          if (entry.value(QStringLiteral("width")).toInt() == wantedWidth &&
              entry.value(QStringLiteral("height")).toInt() == wantedHeight) {
            index = i;
            break;
          }
        }
        if (preset != nullptr && index >= 0) {
          preset->setProperty("currentIndex", index);
        } else {
          qWarning() << "KogaView dev ui request: no preset" << size;
        }
        QObject* live = editor->findChild<QObject*>(QStringLiteral("livePreviewButton"));
        if (live != nullptr) {
          QMetaObject::invokeMethod(live, "click");
        }
        qInfo().noquote() << "KogaView dev ui request editor-resize" << size
                          << "preset" << index << "ratio"
                          << editor->property("resizeRatio") << "tool"
                          << editor->property("tool") << "live"
                          << editor->property("resizeLivePreview");
        emitted = live != nullptr && index >= 0;
      } else if (uiRequest == QLatin1String("editor-crop")) {
        // The Crop panel without a pointer: the tool button, an anchor button
        // and the live toggle are `click()`ed, and the preset dropdown is
        // written the way its own selection writes it. `_ARG` is
        // WIDTHxHEIGHT of a preset (default 1024x1024); `_ARG2` names the
        // anchor (default center).
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const QString size = requestArg.isEmpty() ? QStringLiteral("1024x1024") : requestArg;
        const QString anchor = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const QString anchorKey = anchor.isEmpty() ? QStringLiteral("center") : anchor;
        const QStringList parts = size.split(QLatin1Char('x'));
        const int wantedWidth = parts.value(0).toInt();
        const int wantedHeight = parts.value(1).toInt();
        QObject* tool = editor->findChild<QObject*>(QStringLiteral("toolCrop"));
        if (tool == nullptr) {
          qWarning() << "KogaView dev ui request: Crop tool button missing";
          return;
        }
        QMetaObject::invokeMethod(tool, "click");
        QObject* preset = editor->findChild<QObject*>(QStringLiteral("cropPreset"));
        const QVariantList presets = editor->property("cropPresets").toList();
        int index = -1;
        for (int i = 0; i < presets.size(); ++i) {
          const QVariantMap entry = presets.at(i).toMap();
          if (entry.value(QStringLiteral("width")).toInt() == wantedWidth &&
              entry.value(QStringLiteral("height")).toInt() == wantedHeight) {
            index = i;
            break;
          }
        }
        if (preset != nullptr && index >= 0) {
          preset->setProperty("currentIndex", index);
        } else {
          qWarning() << "KogaView dev ui request: no fitting crop preset" << size;
        }
        // Repeater delegates are visual children, not QObject children of the
        // view, so `findChild` cannot see the anchor buttons. Walk the item
        // tree the way the QML test harness does.
        QObject* anchorButton = nullptr;
        const QString anchorName = QStringLiteral("cropAnchor_") + anchorKey;
        if (auto* window = qobject_cast<QQuickWindow*>(rootObject)) {
          QList<QQuickItem*> pending{window->contentItem()};
          while (!pending.isEmpty()) {
            QQuickItem* item = pending.takeFirst();
            if (item->objectName() == anchorName) {
              anchorButton = item;
              break;
            }
            pending.append(item->childItems());
          }
        }
        if (anchorButton != nullptr) {
          QMetaObject::invokeMethod(anchorButton, "click");
        } else {
          qWarning() << "KogaView dev ui request: no crop anchor" << anchorKey;
        }
        QObject* live = editor->findChild<QObject*>(QStringLiteral("cropLivePreviewButton"));
        if (live != nullptr) {
          QMetaObject::invokeMethod(live, "click");
        }
        auto fieldText = [editor](const char* name) {
          QObject* field = editor->findChild<QObject*>(QString::fromLatin1(name));
          return field != nullptr ? field->property("text") : QVariant();
        };
        qInfo().noquote() << "KogaView dev ui request editor-crop" << size << "preset"
                          << index << "anchor" << editor->property("cropAnchor")
                          << "ratio" << editor->property("cropRatio") << "tool"
                          << editor->property("tool") << "live"
                          << editor->property("cropLivePreview") << "rect"
                          << fieldText("cropX") << fieldText("cropY")
                          << fieldText("widthField") << fieldText("heightField");
        emitted = live != nullptr && index >= 0 && anchorButton != nullptr;
      } else if (uiRequest == QLatin1String("editor-fit") ||
                 uiRequest == QLatin1String("editor-zoom") ||
                 uiRequest == QLatin1String("editor-pan") ||
                 uiRequest == QLatin1String("editor-pan-as")) {
        // The Editor's presentation transforms, driven through the same view
        // functions its toolbar and input handlers call. Logged before and
        // after, because a zoom is invisible in the journal: it emits no
        // command at all.
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const char* names[] = {"zoom", "offsetX", "offsetY", "autoFit"};
        auto log = [editor, &names](const char* when) {
          qInfo().noquote() << "KogaView dev editor" << when << "zoom"
                            << editor->property(names[0]) << "offsetX"
                            << editor->property(names[1]) << "offsetY"
                            << editor->property(names[2]) << "autoFit"
                            << editor->property(names[3]);
        };
        log("before");
        if (uiRequest == QLatin1String("editor-fit")) {
          QMetaObject::invokeMethod(editor, "fit");
        } else if (uiRequest == QLatin1String("editor-zoom")) {
          QMetaObject::invokeMethod(editor, "zoomIn");
          QMetaObject::invokeMethod(editor, "zoomIn");
        } else if (uiRequest == QLatin1String("editor-pan") ||
                   uiRequest == QLatin1String("editor-pan-as")) {
          // `editor-pan` zooms until both axes overflow (the historical proof
          // that a drag moves a big picture). `editor-pan-as` drags at the
          // current zoom, which is how a picture *shorter* than the host is
          // proven to move: it is clamped to the centre without a pan margin.
          const bool zoomFirst = uiRequest == QLatin1String("editor-pan");
          const double documentWidth = editor->property("documentWidth").toDouble();
          const double documentHeight = editor->property("documentHeight").toDouble();
          QObject* host = rootObject->findChild<QObject*>(QStringLiteral("editorCanvasHost"));
          auto* item = qobject_cast<QQuickItem*>(host);
          auto* window = qobject_cast<QQuickWindow*>(rootObject);
          if (item == nullptr || window == nullptr || documentWidth <= 0 || documentHeight <= 0) {
            qWarning() << "KogaView dev ui request: editor canvas host not found";
            return;
          }
          if (zoomFirst) {
            const double need = 1.4 * std::max(item->width() / documentWidth,
                                               item->height() / documentHeight);
            const double current = editor->property("zoom").toDouble();
            if (current > 0 && need > current) {
              QMetaObject::invokeMethod(editor, "zoomAt", Q_ARG(QVariant, QVariant(need / current)),
                                        Q_ARG(QVariant, QVariant(item->width() / 2.0)),
                                        Q_ARG(QVariant, QVariant(item->height() / 2.0)));
            }
          }
          QCoreApplication::processEvents();
          const QPointF local(item->width() / 2.0, item->height() / 2.0);
          const QPointF release = local + QPointF(120, 90);
          const QPoint pressScene = item->mapToScene(local).toPoint();
          const QPoint releaseScene = item->mapToScene(release).toPoint();
          auto logPan = [editor, &log](const char* when) {
            log(when);
            qInfo().noquote() << "KogaView dev editor pan" << when << "offsetX"
                              << editor->property("offsetX") << "offsetY"
                              << editor->property("offsetY");
          };
          logPan("before drag");
          // `DragHandler` activates from the pointer sequence `QTest` produces;
          // a hand-rolled `QMouseEvent` reaches it but never satisfies its grab,
          // which is why the offsets used to stay at 0.
          QTest::mousePress(window, Qt::LeftButton, Qt::NoModifier, pressScene);
          QTest::mouseMove(window, (pressScene + releaseScene) / 2);
          QTest::mouseMove(window, releaseScene);
          QTest::mouseRelease(window, Qt::LeftButton, Qt::NoModifier, releaseScene);
          QTest::qWait(50);
          logPan("after drag");
        }
        QCoreApplication::processEvents();
        log("after");
        emitted = true;
      }
      qInfo().noquote() << "KogaView dev ui request" << uiRequest
                        << (emitted ? "emitted" : "not supported");
    };
    QTimer::singleShot(requestDelay > 0 ? requestDelay : 1500, &app, fire);

    const int repeat = qEnvironmentVariableIntValue("KOGAVIEW_DEV_UI_REQUEST_REPEAT_MS");
    if (repeat > 0) {
      auto* timer = new QTimer(&app);
      timer->setInterval(repeat);
      QObject::connect(timer, &QTimer::timeout, &app, fire);
      timer->start();
    }
  }

  // QA hook: close a portal dialog that a `KOGAVIEW_DEV_UI_REQUEST` opened, so
  // the response path can be observed in a log without touching the desktop.
  const int dismissAfter = qEnvironmentVariableIntValue("KOGAVIEW_DEV_PORTAL_DISMISS_MS");
  if (dismissAfter > 0) {
    QTimer::singleShot(dismissAfter, &app, [&platform]() {
      QMetaObject::invokeMethod(&platform, "dismissActiveDialog");
      qInfo() << "KogaView dev portal dismiss: requested";
    });
  }

  // QA hook: wheel notches over the filmstrip, logged with the strip's `contentX`
  // before and after each one. The filmstrip is horizontal, so a mouse wheel has
  // to scroll it sideways in both directions without also zooming the canvas
  // (its handler takes the event before the canvas sees it).
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_FILMSTRIP_WHEEL")) {
    // Poll until the strip exists and overflows: layout settles after the
    // filmstrip is toggled and the thumbnails arrive, and a wheel sent into a
    // zero-width strip would measure nothing.
    auto* wait = new QTimer(&app);
    wait->setInterval(200);
    QObject::connect(wait, &QTimer::timeout, &app, [rootObject, wait, &app]() {
      QObject* strip = rootObject->findChild<QObject*>(QStringLiteral("viewerFilmstrip"));
      auto* flick = qobject_cast<QQuickItem*>(strip);
      if (flick == nullptr || flick->width() <= 0 ||
          strip->property("contentWidth").toReal() <= flick->width()) {
        return;
      }
      wait->stop();
      wait->deleteLater();
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      if (window == nullptr) {
        qWarning() << "KogaView dev filmstrip: window not found";
        return;
      }
      const QPointF local(flick->width() / 2.0, flick->height() / 2.0);
      const QPointF scene = flick->mapToScene(local);
      static auto* mouse = new QPointingDevice(
        QStringLiteral("kogaview qa mouse"), 9101, QInputDevice::DeviceType::Mouse,
        QPointingDevice::PointerType::Generic, QInputDevice::Capability::Scroll, 1, 3);
      QObject* viewer = rootObject->findChild<QObject*>(QStringLiteral("viewer"));
      const double zoomBefore = viewer ? viewer->property("zoom").toDouble() : -1;
      auto notch = [&](int degrees) {
        const double before = strip->property("contentX").toDouble();
        QWheelEvent event(scene, QPointF(window->mapToGlobal(scene.toPoint())),
                          QPoint(0, 0), QPoint(0, degrees), Qt::NoButton, Qt::NoModifier,
                          Qt::NoScrollPhase, false, Qt::MouseEventNotSynthesized, mouse);
        QCoreApplication::sendEvent(window, &event);
        QCoreApplication::processEvents();
        qInfo() << "KogaView dev filmstrip: notch" << degrees << "contentX" << before << "->"
                << strip->property("contentX").toDouble();
      };
      qInfo() << "KogaView dev filmstrip: width" << flick->width() << "content"
              << strip->property("contentWidth").toDouble();
      notch(-120);
      notch(-120);
      notch(120);
      // The strip glides, so the reads above are taken mid-animation. Log where
      // it comes to rest, which is the distance the notches really moved.
      QTimer::singleShot(400, &app, [strip]() {
        qInfo() << "KogaView dev filmstrip: settled contentX"
                << strip->property("contentX").toDouble();
      });
      QObject* filmHandler = rootObject->findChild<QObject*>(QStringLiteral("filmstripWheelHandler"));
      qInfo() << "KogaView dev filmstrip: handler found" << (filmHandler != nullptr)
              << "zoom" << zoomBefore << "->" << (viewer ? viewer->property("zoom").toDouble() : -1);
    });
    wait->start();
  }

  // QA hook: wheel over the Editor canvas. It goes through the view's own
  // `editorWheelHandler` (the same handler the real wheel reaches), so the
  // logged zoom is what a hand would have produced, at a cursor point that
  // intentionally is not the centre: the anchor being kept is what proves the
  // zoom-at-cursor math.
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_EDITOR_WHEEL")) {
    QTimer::singleShot(qEnvironmentVariableIntValue("KOGAVIEW_DEV_EDITOR_WHEEL_DELAY_MS") > 0
                         ? qEnvironmentVariableIntValue("KOGAVIEW_DEV_EDITOR_WHEEL_DELAY_MS")
                         : 1500,
                       &app, [rootObject]() {
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
      auto* host =
        qobject_cast<QQuickItem*>(rootObject->findChild<QObject*>(QStringLiteral("editorCanvasHost")));
      if (window == nullptr || editor == nullptr || host == nullptr) {
        qWarning() << "KogaView dev editor wheel: window, editor or canvas host not found";
        return;
      }
      static auto* touchpad =
        new QPointingDevice(QStringLiteral("kogaview qa touchpad"), 9003,
                            QInputDevice::DeviceType::TouchPad,
                            QPointingDevice::PointerType::Finger,
                            QInputDevice::Capability::Scroll
                              | QInputDevice::Capability::PixelScroll,
                            1, 3);
      const QPointF local(host->width() * 0.75, host->height() * 0.30);
      const QPointF scene = host->mapToScene(local);
      auto log = [editor](const char* when) {
        qInfo().noquote() << "KogaView dev editor wheel" << when << "zoom"
                          << editor->property("zoom") << "offsetX" << editor->property("offsetX")
                          << "offsetY" << editor->property("offsetY") << "autoFit"
                          << editor->property("autoFit");
      };
      log("before");
      // The anchor is what proves the zoom-at-cursor math. It uses the same
      // corner-mapping technique `tst_viewer` uses: the document pixel under
      // the cursor is taken with `mapFromItem` on the unscaled document item,
      // then mapped back after the wheel and compared with the cursor. Qt
      // applies the item's `scale` in both directions, so the comparison is
      // like-for-like.
      auto* canvas = qobject_cast<QQuickItem*>(
        rootObject->findChild<QObject*>(QStringLiteral("canvas")));
      if (canvas == nullptr) {
        qWarning() << "KogaView dev editor wheel: canvas not found";
        return;
      }
      QCoreApplication::processEvents();
      const QPointF sceneBefore = host->mapToScene(local);
      const QPointF documentPoint = canvas->mapFromScene(sceneBefore);
      bool eventAccepted = false;
      // Four notches: a single one only widens the picture past the host on
      // the horizontal axis, and `clampOffsets` correctly pins the vertical
      // offset to 0 while the picture is still shorter than the viewport.
      for (int notch = 0; notch < 4; ++notch) {
        QWheelEvent event(sceneBefore, QPointF(window->mapToGlobal(sceneBefore.toPoint())),
                          QPoint(0, 0), QPoint(0, 120), Qt::NoButton, Qt::NoModifier,
                          Qt::ScrollUpdate, false, Qt::MouseEventNotSynthesized, touchpad);
        QCoreApplication::sendEvent(window, &event);
        QCoreApplication::processEvents();
        eventAccepted = eventAccepted || event.isAccepted();
      }
      // Let the `canvas.x/y` and `scale` bindings settle before re-projecting,
      // otherwise the anchor is compared against a half-applied layout.
      QCoreApplication::processEvents();
      const QPointF anchored = canvas->mapToScene(documentPoint);
      log("after");
      qInfo().noquote() << "KogaView dev editor wheel: handler saw"
                        << editor->property("lastWheelX") << editor->property("lastWheelY")
                        << "cursor at" << sceneBefore << "drift" << (anchored - sceneBefore)
                        << "document" << documentPoint << "accepted" << eventAccepted;
    });
  }

  // What did the app restore? Logged before any command runs, so "the sidebar
  // root and the open folder came back as two separate values" is visible.
  if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_STATE")) {
    QTimer::singleShot(0, &app, [rootObject, &thumbnails]() {
      logDevState(rootObject, rootObject->findChild<QObject*>(QStringLiteral("bridge")),
                  &thumbnails);
    });
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
                           PlatformHelper& platform, ThumbnailCache& thumbnails)
{
  engine.rootContext()->setContextProperty(QStringLiteral("Platform"), &platform);
  engine.rootContext()->setContextProperty(QStringLiteral("Thumbnails"), &thumbnails);
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

  // Translations live inside the binary: the `.ts` sources are compiled to
  // `.qm` at build time and registered as `:/i18n/`, so a Flatpak sandbox needs
  // no files from the host. Which one is installed is `InterfaceLanguage`'s job
  // (`cpp/language.cpp`), including a change made while the window is open.

  PlatformHelper platform;
  // Thumbnails live under the profile's cache root. Core owns that path, so the
  // naming rule is not duplicated here.
  ThumbnailCache thumbnails(kogaview_cache_dir() + QStringLiteral("/thumbnails"));
  QQmlEngine engine;

  QObject* rootObject = loadUserInterface(engine, launchArguments, platform, thumbnails);
  if (rootObject == nullptr) {
    kogaview_shutdown();
    return 1;
  }

  QObject::connect(&engine, &QQmlEngine::quit, &app, &QGuiApplication::quit);
  QObject::connect(&engine, &QQmlEngine::exit, &app, &QCoreApplication::exit);

  // The language is persisted state like the theme: the first snapshot carries
  // it, and `Main.qml` applies every later change (a `set_settings` from the
  // dialog). `KOGAVIEW_UI_LANG` overrides both for a harness run.
  auto* language = new InterfaceLanguage(&engine, rootObject,
                                         qEnvironmentVariable("KOGAVIEW_UI_LANG"), rootObject);
  language->reapply();
  engine.rootContext()->setContextProperty(QStringLiteral("LanguageInstaller"), language);

#ifdef KOGAVIEW_DEV_HARNESS
  installDevHarness(rootObject, app, platform, thumbnails);
  dispatchDevCommands(rootObject, app, thumbnails);
#endif

  const int result = app.exec();
  delete rootObject;
  kogaview_shutdown();
  return result;
}
