#include "platform.h"
#include "language.h"
#include "thumbnailcache.h"

#include <QColor>
#include <QClipboard>
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
#include <QPainter>
#include <QPointingDevice>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickImageProvider>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QShortcutEvent>
#include <QStandardPaths>
#include <QSurfaceFormat>
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
#include <functional>
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

/// Open the burger menu for a photograph. A menu is its own top-level window,
/// so a grab of the main window leaves it out; `KOGAVIEW_DEV_GRAB_POPUPS` paints
/// every visible popup into the picture.
///
/// The menu is flat: the panel checklist lives in Settings › Appearance, not in
/// a `View > Sidebar` submenu, so there is nothing nested to draw. The hook
/// opens the menu and logs how many panels the saved layout switches, which is
/// the same list the form draws.
void openMainMenu(QObject* rootObject)
{
  QObject* mainMenu = rootObject->findChild<QObject*>(QStringLiteral("mainMenu"));
  bool mainOpened = false;
  if (mainMenu != nullptr) {
    mainOpened = QMetaObject::invokeMethod(mainMenu, "popup");
    // `popup()` applies its own placement policy; move it under the burger
    // afterwards so the grab shows the menu where a click would put it.
    const int width = rootObject->property("width").toInt();
    const int menuWidth = mainMenu->property("width").toInt();
    if (width > 0 && menuWidth > 0) {
      mainMenu->setProperty("x", width - menuWidth - 24);
      mainMenu->setProperty("y", 56);
    }
  }
  const QVariantMap layout = rootObject->property("state").toMap().value("layout").toMap();
  qInfo() << "KogaView dev ui request main menu"
          << "main" << mainOpened
          << "visible" << (mainMenu != nullptr && mainMenu->property("visible").toBool())
          << "panels" << layout.value("panels").toMap().size();
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

  // QA hook: deliver a key sequence to the window's registered `Shortcut`s, so
  // a key bound in `Main.qml` can be exercised without a hand on the keyboard.
  // A `QTest` key press does not reach a `Shortcut` (Qt resolves shortcuts in
  // the platform's shortcut path, which synthetic key events bypass), so the
  // hook finds the `Shortcut` whose `sequence` is the requested one and sends it
  // the `QShortcutEvent` that shortcut's own handler consumes — the map's last
  // step, after the key has been matched. A sequence no `Shortcut` declares
  // fires nothing and is logged as `declared 0` — which is how a hint naming the
  // wrong key is detected. What this proves is the binding, the `enabled` gate
  // and the handler; what it does not prove is that the compositor delivered
  // the key to the window. `;` separates sequences.
  const QString devKeys = qEnvironmentVariable("KOGAVIEW_DEV_KEY");
  if (!devKeys.isEmpty()) {
    const int delay = qEnvironmentVariableIntValue("KOGAVIEW_DEV_KEY_DELAY_MS");
    const QStringList sequences = devKeys.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    QTimer::singleShot(delay > 0 ? delay : 2500, &app, [rootObject, sequences]() {
      auto* window = qobject_cast<QQuickWindow*>(rootObject);
      if (window == nullptr) {
        qWarning() << "KogaView dev key: root object is not a QQuickWindow";
        return;
      }
      for (int index = 0; index < sequences.size(); ++index) {
        const QString sequence = sequences.at(index).trimmed();
        if (sequence.isEmpty()) {
          continue;
        }
        QTimer::singleShot(index * 1500, window, [window, sequence]() {
          const QKeySequence keys(sequence);
          QList<QObject*> matching;
          const QList<QObject*> objects = window->findChildren<QObject*>();
          for (QObject* candidate : objects) {
            if (!candidate->inherits("QQuickShortcut")) {
              continue;
            }
            // `sequence` is a `QVariant` property, so a QML literal arrives as
            // a string, not as a `QKeySequence`.
            if (QKeySequence(candidate->property("sequence").toString()) == keys) {
              matching.append(candidate);
            }
          }
          // A `Shortcut` only accepts the `QShortcutEvent` carrying the id the
          // application's shortcut map gave it, and that id is not a property.
          // `QShortcutMap` counts down from -1 in registration order, so trying
          // those ids in order finds each shortcut's own one — the same pairing
          // the map makes before it dispatches the event.
          int fired = 0;
          for (QObject* shortcut : matching) {
            bool activated = false;
            for (int id = -1; id >= -512 && !activated; --id) {
              QShortcutEvent event(keys, id, false);
              activated = QCoreApplication::sendEvent(shortcut, &event);
            }
            if (activated) {
              ++fired;
            }
          }
          QTimer::singleShot(900, window, [window, sequence, fired, matching]() {
            const QImage copied = QGuiApplication::clipboard()->image();
            qInfo().noquote()
              << "KogaView dev key" << sequence << "declared" << matching.size() << "allowed"
              << fired << "active" << window->isActive() << "window" << window->size()
              << "toast"
              << window->property("toastText").toString() << "clipboardText"
              << QGuiApplication::clipboard()->text().left(160).replace(QLatin1Char('\n'),
                                                                       QLatin1Char(' '))
              << "clipboardImage"
              << (copied.isNull()
                    ? QStringLiteral("none")
                    : QStringLiteral("%1x%2").arg(copied.width()).arg(copied.height()));
          });
        });
      }
    });
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

      QImage image = window->grabWindow();
      // A menu is its own top-level window, so a grab of the main window leaves
      // it out. With `KOGAVIEW_DEV_GRAB_POPUPS` set, paint every visible popup
      // where the compositor put it relative to this window; that is how the
      // burger menu can be photographed on a session where no screen capture
      // works. A closed menu, and a submenu of one, has no window to paint. It
      // is evidence of the widget, not of the compositor's own drawing.
      if (qEnvironmentVariableIsSet("KOGAVIEW_DEV_GRAB_POPUPS")) {
        const QPoint origin = window->position();
        for (QWindow* top : QGuiApplication::topLevelWindows()) {
          auto* popup = qobject_cast<QQuickWindow*>(top);
          if (popup == nullptr || popup == window || !popup->isVisible()) {
            continue;
          }
          const QImage layer = popup->grabWindow();
          if (layer.isNull()) {
            continue;
          }
          QPainter painter(&image);
          painter.drawImage(popup->position() - origin, layer);
        }
      }
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
  //   KOGAVIEW_DEV_UI_REQUEST=editor-resize     -> open the Resize dialog from
  //     the palette button, fill its fields from a preset (or a typed pair),
  //     unlock the chain, choose how an aspect change is handled, a background
  //     and a filter, then optionally press Apply
  //   KOGAVIEW_DEV_UI_REQUEST=editor-crop       -> the same for Crop, including
  //     one of the nine anchor buttons; `_ARG` is a preset size, `unframed` to
  //     stop with no frame, `full` for the click-made whole-image frame, or
  //     `clear` to build a preset frame and press Clear; `_ARG3` names the
  //     locks (`width`, `height`, `ratio`,
  //     `width+height`, `width+ratio`, `height+ratio`); `_ARG4=reset` presses
  //     Reset options; `_ARG5=apply` presses Apply crop; `_ARG6=center|grow`
  //     picks the mode; `_ARG7` names the grow fill (`transparent`, `black`,
  //     `white`, `gray` or `#rrggbb`); `_ARG8` types a ratio such as `3:2`)
  //   KOGAVIEW_DEV_UI_REQUEST=editor-transform  -> click the Transform tool and
  //     move one corner (`_ARG` = `X,Y` in document pixels, `_ARG2` = the corner
  //     index or `e0`–`e3` for an edge), optionally arming Live preview and
  //     pressing Apply
  //   KOGAVIEW_DEV_UI_REQUEST=editor-paint      -> pick Brush or Eraser and
  //     draw one stroke through the canvas helpers (`_ARG` = `x1,y1;x2,y2;…`
  //     in document pixels, `_ARG2` = `eraser`, `_ARG3` = `#rrggbb`, `_ARG4` =
  //     the brush size in px, `_ARG5` = the opacity 1–100)
  //   KOGAVIEW_DEV_UI_REQUEST=editor-save-as   -> the Editor's Save as…,
  //     through the shell's own `chooseEditorSaveAs`. It opens the desktop's
  //     save dialog, so a run with `KOGAVIEW_DEV_PORTAL_DISMISS_MS` shows
  //     whether the request reached the portal at all.
  //   KOGAVIEW_DEV_UI_REQUEST=editor-export     -> click the toolbar's Export
  //     button, write the dialog's path/quality/size, and optionally press
  //     Export (`_ARG4` is a long-edge preset in pixels, `0` for the original)
  //   KOGAVIEW_DEV_UI_REQUEST=editor-dock       -> choose a reference tab
  //     (`_ARG` = `info`, `history`, `original`), hide panels through the
  //     sidebar checklist (`_ARG2` = `tools,info,history,original`), show them
  //     again with `_ARG5`, set the dock width (`_ARG3`), arm a tool (`_ARG4` =
  //     `crop`, `brush`, `eraser`, `transform`) by clicking its rail button,
  //     or drag the divider to a height with `_ARG6` — the tab, the checklist,
  //     the width and the split are view state and send no command. `_ARG7=menu`
  //     clicks the checklist button so its rows can be photographed.
  //   KOGAVIEW_DEV_UI_REQUEST=editor-colour     -> the Editor's one colour
  //     pair, through the handlers the controls call: `_ARG` is the action
  //     (`swap` for Krita's X, `reset` for D, `list` opens the background list
  //     under the rail's box, `foreground` opens the foreground chooser,
  //     `pick:<key>` chooses a row of the list, or `#rrggbb` types a
  //     foreground), `_ARG2` writes the background first (`transparent` or
  //     `#rrggbb`), `_ARG3=brush` arms the brush so the rail pair and the
  //     paint options can be compared, and `_ARG4=notools` hides the rail so
  //     the fallback pair is the one on screen. It logs the two boxes'
  //     geometry, so the 34 x 34 layout is checkable from a log.
  //   KOGAVIEW_DEV_UI_REQUEST=batch           -> open the Browser's batch form
  //     through the shell's own `openBatchDialog` (the function the Tools…
  //     menu entry calls), write its fields, and optionally press Run. `_ARG`
  //     is the action (`resize`, `crop`, `convert`), `_ARG2` its answer
  //     (`640x480` for resize, `10,5,80,90` for crop's percentages, the encoder
  //     key for convert), `_ARG3=overwrite` ticks Replace the originals, `_ARG8`
  //     is an output folder (ticking "Another folder" first), `_ARG6=free`
  //     unlocks the aspect chain (typing both sides of a locked pair is a
  //     contradiction the form resolves) and `_ARG9=page` opens it from the
  //     Batch page's own button (the panel emits `requestBatch(mode)`) instead
  //     of calling the shell's function. `_ARG4` is `fill` to stop with the form
  //     open, `cancel` to press the page's Cancel while the job runs, or empty
  //     for Run; `_ARG5` is the delay before Run and `_ARG7` how long the job
  //     runs before that Cancel, both in milliseconds, so a grab can catch the
  //     progress bar. `_ARG10` clicks the grid's cells first (`0:plain`,
  //     `1:ctrl`, `2:shift` — `BrowserView.clickIndex`, the handler the cell's
  //     own `MouseArea` runs) and logs the selection after each one, so a job
  //     can be started on a multi-selection. It logs the command the form
  //     produced and the `batch` slot Core published, which is what the page
  //     draws.
  //   KOGAVIEW_DEV_UI_REQUEST=browser-view      -> `_ARG` names how the folder
  //     is drawn (`thumbnails`, `icons` or `details`) and the switch's own
  //     button is `click()`ed, so the layout request the shell sends is the one
  //     a press sends; without `_ARG` the request only reports the shape on
  //     screen
  //   KOGAVIEW_DEV_UI_REQUEST=sidebar-dock     -> the Browser's or the Viewer's
  //     sidebar without a pointer: `_ARG` names a page (`preview`, `batch`,
  //     `info`), `_ARG2`/`_ARG5` are comma-separated lists of panels to
  //     hide/show through the checklist, and `_ARG4=menu` clicks the checklist
  //     button so its rows can be photographed. Like the other requests it
  //     calls the handler the real control calls and sends no command.
  //   The editor and sidebar requests exist because this session's compositor
  //   does not deliver synthetic pointer moves to the window; each one calls
  //   the handler the real control calls, and none invents a command of its own.
  //   `KOGAVIEW_DEV_UI_REQUEST_REPEAT_MS` fires it repeatedly, which is how the
  //   "a dismissed dialog does not block the next one" path is observed.
  const QString uiRequest = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST");
  if (!uiRequest.isEmpty()) {
    const int requestDelay = qEnvironmentVariableIntValue("KOGAVIEW_DEV_UI_REQUEST_DELAY_MS");
    const QString requestArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG");
    auto fire = [rootObject, uiRequest, requestArg, requestDelay, &app]() {
      if (uiRequest == QLatin1String("settings")) {
        // The shell's own function, so the dialog receives the stored theme and
        // checkbox values exactly as the menu entry hands them over. `_ARG`
        // names the section strip's page to draw (`general` by default), which
        // is what a click on the strip writes.
        const bool opened = QMetaObject::invokeMethod(rootObject, "openSettings");
        QObject* dialog = rootObject->findChild<QObject*>(QStringLiteral("settingsDialog"));
        QString section = QStringLiteral("general");
        if (!requestArg.isEmpty()) {
          section = requestArg;
        }
        const bool chosen = dialog != nullptr
                            && dialog->setProperty("section", section);
        qInfo().noquote() << "KogaView dev ui request settings"
                          << (opened ? "emitted" : "not supported")
                          << "section" << (chosen ? section : QStringLiteral("not set"));
        return;
      }
      if (uiRequest == QLatin1String("browser-view")) {
        // The switch, not a property write: the buttons are what a person
        // presses, and the click runs the same handler that emits the layout
        // request. The Browser is the shell's `browser` object (`BrowserView` is
        // named for the workspace it draws, as the Viewer and the Editor are),
        // and its `viewMode` is the shape on screen, so the log line reports what
        // Core's layout says the folder is drawn as.
        QObject* view = rootObject->findChild<QObject*>(QStringLiteral("browser"));
        const QString mode = requestArg;
        if (!mode.isEmpty() && view != nullptr) {
          const QString button = QStringLiteral("viewMode") + mode.at(0).toUpper()
                                 + mode.mid(1);
          // The buttons are delegates of a `Repeater`: they are drawn as children
          // of the row but carry no QObject parent, so `findChild` cannot see
          // them and the item tree is walked instead.
          std::function<QQuickItem*(QQuickItem*, const QString&)> locate =
            [&locate](QQuickItem* from, const QString& name) -> QQuickItem* {
              if (from == nullptr) {
                return nullptr;
              }
              if (from->objectName() == name) {
                return from;
              }
              for (QQuickItem* child : from->childItems()) {
                if (QQuickItem* hit = locate(child, name)) {
                  return hit;
                }
              }
              return nullptr;
            };
          QQuickItem* target = locate(qobject_cast<QQuickItem*>(view), button);
          const bool clicked = target != nullptr
                               && QMetaObject::invokeMethod(target, "click");
          qInfo().noquote() << "KogaView dev ui request browser-view clicked" << button
                            << (clicked ? "ok" : "not clickable");
        }
        const QString shown = view != nullptr
                              ? view->property("viewMode").toString() : QString();
        qInfo().noquote() << "KogaView dev ui request browser-view"
                          << (view != nullptr ? "found" : "not found")
                          << "mode" << shown;
        return;
      }
      bool emitted = false;
      QObject* browser = rootObject->findChild<QObject*>(QStringLiteral("browser"));
      // The menu requests act on a `Menu` of the shell or of whichever
      // workspace is open, so they do not need the Browser to exist: with the
      // Viewer up there is no Browser view at all.
      const bool menuRequest =
        uiRequest == QLatin1String("context-menu")
        || (uiRequest == QLatin1String("context-menu-trigger")
            && qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_MENU")
                 == QLatin1String("viewerMenu"));
      if (browser == nullptr && !uiRequest.startsWith(QLatin1String("editor-")) &&
          uiRequest != QLatin1String("leave-guard")
          && uiRequest != QLatin1String("sidebar-dock") && !menuRequest) {
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
        // needs a favourite, which this harness does not know. `_ARG2` opens a
        // menu by name instead (the mini toolbars' overflow menus), which needs
        // no path because the shell menu of the workspace is always there.
        const QString named = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const QString name = !named.isEmpty()
                               ? named
                               : (requestArg.isEmpty() ? QStringLiteral("folderMenu")
                                                       : QStringLiteral("fileMenu"));
        QObject* menu = rootObject->findChild<QObject*>(name);
        if (menu != nullptr && named.isEmpty() && !requestArg.isEmpty()) {
          browser->setProperty("menuPath", requestArg);
          browser->setProperty("menuIsDir", true);
          browser->setProperty("menuIsImage", true);
        }
        emitted = menu != nullptr && QMetaObject::invokeMethod(menu, "popup");
        if (emitted) {
          qInfo() << "KogaView dev ui request context-menu" << name << "opened"
                  << menu->property("visible").toBool() << "width"
                  << menu->property("width").toDouble() << "height"
                  << menu->property("height").toDouble();
        }
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
        // The replay exists for `fileMenu`'s entry: its three commands are the
        // behaviour that test is about. Any other menu is clicked for its own
        // effect only — replaying `set_workspace editor` after the burger menu's
        // Tools entry dragged the window into the Editor before a grab could
        // show what the entry had done.
        if (emitted && which == QLatin1String("fileMenu")) {
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
        // The Resize dialog without a pointer: the palette button is
        // `click()`ed (the same handler a press runs), and the size dropdown is
        // written the way its own selection writes it. `_ARG` is WIDTHxHEIGHT
        // of a preset (default 1024x1024), or a custom pair when no preset
        // matches; `_ARG2=free` unlocks the chain; `_ARG3` names a background
        // (`transparent`, `black`, `white`, `gray`) or is `#rrggbb`, written on
        // the Editor's own background; `_ARG4` names a filter (`auto`, `nearest`, `bilinear`, `bicubic`,
        // `bspline`, `lanczos3`); `_ARG6` is the fit (`stretch`, `cover`,
        // `pad`) — the question the form now asks before any background.
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const QString size = requestArg.isEmpty() ? QStringLiteral("1024x1024") : requestArg;
        const QString constraintArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const QString backgroundArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        const QString filterArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4");
        const QStringList parts = size.split(QLatin1Char('x'));
        const int wantedWidth = parts.value(0).toInt();
        const int wantedHeight = parts.value(1).toInt();
        QObject* tool = editor->findChild<QObject*>(QStringLiteral("toolResize"));
        if (tool == nullptr) {
          qWarning() << "KogaView dev ui request: Resize tool button missing";
          return;
        }
        // Resize is a modal form: the palette button opens it and `opened`
        // lands on the next frame, so the hook waits for the state a hand
        // would see before writing the form. Clicking again would only close
        // it again, which is why this is not a toggle any more.
        QMetaObject::invokeMethod(tool, "click");
        QObject* dialog = editor->findChild<QObject*>(QStringLiteral("resizeDialog"));
        if (dialog == nullptr) {
          dialog = rootObject->findChild<QObject*>(QStringLiteral("resizeDialog"));
        }
        if (dialog == nullptr) {
          qWarning() << "KogaView dev ui request: Resize dialog missing";
          return;
        }
        for (int wait = 0; wait < 100 && !dialog->property("opened").toBool(); ++wait) {
          QCoreApplication::processEvents();
          QTest::qWait(10);
        }
        if (!dialog->property("opened").toBool()) {
          qWarning() << "KogaView dev ui request: Resize dialog did not open";
          return;
        }
        const QVariantList presets = dialog->property("presets").toList();
        int index = -1;
        for (int i = 0; i < presets.size(); ++i) {
          const QVariantMap entry = presets.at(i).toMap();
          if (entry.value(QStringLiteral("width")).toInt() == wantedWidth &&
              entry.value(QStringLiteral("height")).toInt() == wantedHeight) {
            index = i;
            break;
          }
        }
        if (index >= 0) {
          // The combo applies a preset from `onActivated`, which a programmatic
          // `currentIndex` write does not emit; call the same helper the user's
          // selection calls.
          QMetaObject::invokeMethod(dialog, "choosePreset",
                                    Q_ARG(QVariant, QVariant(index)));
        } else {
          // A custom pair: write the fields the way a typed pair lands. The
          // chain is not stepped here, so `_ARG2=free` still decides the lock.
          auto setField = [dialog](const char* name, int value) {
            QObject* field = dialog->findChild<QObject*>(QString::fromLatin1(name));
            if (field != nullptr) {
              field->setProperty("text", QString::number(value));
            }
          };
          setField("resizeWidth", wantedWidth);
          setField("resizeHeight", wantedHeight);
          qInfo() << "KogaView dev ui request: custom size" << size << "(no preset)";
        }
        if (constraintArg == QLatin1String("free")) {
          QMetaObject::invokeMethod(dialog, "setConstraint", Q_ARG(QVariant, false));
        }
        if (!backgroundArg.isEmpty()) {
          // The form owns no colour any more: `_ARG3` sets the Editor's one
          // background through the same functions the pair and the list call,
          // so the row the form draws, a grown crop border and the next resize
          // all read the value this line wrote.
          if (backgroundArg == QLatin1String("transparent")) {
            QMetaObject::invokeMethod(editor, "setBackgroundTransparent",
                                      Q_ARG(QVariant, QVariant(true)));
          } else if (backgroundArg == QLatin1String("black")) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("#000000"))));
          } else if (backgroundArg == QLatin1String("white")) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("#ffffff"))));
          } else if (backgroundArg == QLatin1String("gray")) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("#808080"))));
          } else if (backgroundArg.startsWith(QLatin1Char('#'))) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(backgroundArg)));
          } else {
            qWarning() << "KogaView dev ui request: no resize background" << backgroundArg;
          }
          qInfo() << "KogaView dev ui request: background" << backgroundArg
                  << editor->property("backgroundColor")
                  << editor->property("backgroundTransparent");
        }
        const QString fitArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG6");
        if (!fitArg.isEmpty()) {
          const QVariantList fits = dialog->property("fits").toList();
          for (int i = 0; i < fits.size(); ++i) {
            if (fits.at(i).toMap().value(QStringLiteral("key")).toString() == fitArg) {
              QMetaObject::invokeMethod(dialog, "chooseFit", Q_ARG(QVariant, QVariant(i)));
              break;
            }
          }
        }
        if (!filterArg.isEmpty()) {
          dialog->setProperty("filter", filterArg);
          const QVariantList filters = dialog->property("filters").toList();
          for (int i = 0; i < filters.size(); ++i) {
            if (filters.at(i).toMap().value(QStringLiteral("key")).toString() == filterArg) {
              if (QObject* filter = dialog->findChild<QObject*>(QStringLiteral("resizeFilter"))) {
                filter->setProperty("currentIndex", i);
              }
              break;
            }
          }
        }
        qInfo().noquote() << "KogaView dev ui request editor-resize" << size
                          << "preset" << index << "constraint"
                          << dialog->property("constraint") << "fit"
                          << dialog->property("fitMode") << "background"
                          << editor->property("backgroundColor") << "transparent"
                          << editor->property("backgroundTransparent") << "filter"
                          << dialog->property("filter") << "tool"
                          << editor->property("tool");
        // `_ARG5=apply` presses the dialog's own Apply after the form is filled,
        // so the real `editor_resize` reaches Core and the document changes.
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG5") == QLatin1String("apply")) {
          QObject* apply = dialog->findChild<QObject*>(QStringLiteral("resizeApply"));
          const bool armed = apply != nullptr && apply->property("enabled").toBool();
          if (armed) {
            QMetaObject::invokeMethod(apply, "click");
          }
          qInfo() << "KogaView dev ui request editor-resize apply" << (armed ? "pressed" : "disabled")
                  << "dialog open" << dialog->property("opened");
        }
        emitted = true;
      } else if (uiRequest == QLatin1String("editor-crop")) {
        // The Crop panel without a pointer. `_ARG` is the request itself:
        //   `WIDTHxHEIGHT`  choose a fitting preset (default `1024x1024`), which
        //                   also builds the frame when Crop opens unframed;
        //   `unframed`      arm Crop and stop, showing the state the tool
        //                   opens in: no frame, empty Width/Height;
        //   `full`          arm Crop and click the picture once, the whole-image
        //                   frame a click without travel asks for;
        //   `clear`         arm Crop, choose the preset given by `_ARG9`
        //                   (default 512x384) so a frame exists, then press
        //                   Clear, so the shot shows the state it leaves.
        // `_ARG2` names the anchor (default `center`), `_ARG3` the locks to
        // engage (`width`, `height`, `ratio`, `width+height`, `width+ratio`,
        // `height+ratio`), `_ARG4` is `reset` to press Reset options, `_ARG5`
        // is `apply` to press Apply, `_ARG6` is `center` or `grow`, `_ARG7` the
        // grow border colour (a key such as `black`, or `#rrggbb`) and `_ARG8`
        // a ratio typed into the ratio field (`3:2`, `free`).
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const QString size = requestArg.isEmpty() ? QStringLiteral("1024x1024") : requestArg;
        // `unframed` (the old `seed` spelling still works) arms Crop and stops
        // before a frame exists, which is the state the tool opens in.
        const bool unframed = size == QLatin1String("unframed")
                              || size == QLatin1String("seed");
        const bool fullFrame = size == QLatin1String("full");
        const bool clearAfter = size == QLatin1String("clear");
        const QString anchor = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const QString anchorKey = anchor.isEmpty() ? QStringLiteral("center") : anchor;
        QObject* tool = editor->findChild<QObject*>(QStringLiteral("toolCrop"));
        if (tool == nullptr) {
          qWarning() << "KogaView dev ui request: Crop tool button missing";
          return;
        }
        // Selecting a tool is a toggle: click only while Crop is not selected.
        if (!tool->property("highlighted").toBool()) {
          QMetaObject::invokeMethod(tool, "click");
        }
        // The mode decides which preset list is legal (a growing crop may hold
        // a size the picture cannot), so it is chosen before the preset.
        const QString modeArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG6");
        if (modeArg == QLatin1String("grow") || modeArg == QLatin1String("center")) {
          QMetaObject::invokeMethod(editor, "setCropMode",
                                    Q_ARG(QVariant, QVariant(modeArg)));
        }
        // A preset builds the frame at the current anchor; `unframed` and
        // `full` are the two states the panel must not build one for. `clear`
        // wants one first, so the Clear button has something to put down.
        const QVariantList presets = (unframed || fullFrame)
          ? QVariantList() : editor->property("cropPresets").toList();
        // `clear` is a verb, not a size: the frame it clears is built from
        // `_ARG9` (default 512x384), which must fit on the open picture.
        const QString presetSize = clearAfter
          ? (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG9").isEmpty()
               ? QStringLiteral("512x384")
               : qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG9"))
          : size;
        const QStringList parts = presetSize.split(QLatin1Char('x'));
        const int wantedWidth = parts.value(0).toInt();
        const int wantedHeight = parts.value(1).toInt();
        int index = -1;
        for (int i = 0; i < presets.size(); ++i) {
          const QVariantMap entry = presets.at(i).toMap();
          if (entry.value(QStringLiteral("width")).toInt() == wantedWidth &&
              entry.value(QStringLiteral("height")).toInt() == wantedHeight) {
            index = i;
            break;
          }
        }
        if (unframed || fullFrame) {
          // No preset: the frame is the state under test.
        } else if (index >= 0) {
          QMetaObject::invokeMethod(editor, "chooseCropPreset",
                                    Q_ARG(QVariant, QVariant(index)));
        } else {
          qWarning() << "KogaView dev ui request: no fitting crop preset" << size;
        }
        // The ratio is typed after the preset, so a run that says both keeps
        // the ratio it asked for instead of the preset's own shape. The text
        // goes into the field first: `applyCropRatioText()` reads what is on
        // screen, exactly as `onTextEdited`/`onEditingFinished` do.
        const QString ratioArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG8");
        if (!ratioArg.isEmpty()) {
          QObject* ratioField = editor->findChild<QObject*>(QStringLiteral("cropRatio"));
          if (ratioField != nullptr) {
            ratioField->setProperty("text", ratioArg);
          } else {
            qWarning() << "KogaView dev ui request: no crop ratio field";
          }
          QMetaObject::invokeMethod(editor, "applyCropRatioText");
        }
        // Repeater delegates are visual children, not QObject children of the
        // view, so `findChild` cannot see the anchor buttons. Walk the item
        // tree the way the QML test harness does.
        QObject* anchorButton = nullptr;
        const QString anchorName = QStringLiteral("cropAnchor_") + anchorKey;
        if (unframed || fullFrame) {
          // Nothing to place yet.
        } else {
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
        }
        // `_ARG7` names the border colour of a growing crop. A named entry goes
        // through the dropdown's own chooser; a `#rrggbb` writes the custom
        // swatch, because the real chooser is a portal dialog a harness run
        // cannot answer.
        // `_ARG7` names the Editor's background — the colour a grown border is
        // painted with. `transparent` is a state of its own; the three named
        // colours and a `#rrggbb` go through `setBackgroundColor`, the same
        // function the background list and the colour chooser call, so a hook
        // run cannot describe a background the UI could not.
        const QString fillArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG7");
        if (!fillArg.isEmpty()) {
          if (fillArg == QLatin1String("transparent")) {
            QMetaObject::invokeMethod(editor, "setBackgroundTransparent",
                                      Q_ARG(QVariant, QVariant(true)));
          } else if (fillArg == QLatin1String("black")) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("#000000"))));
          } else if (fillArg == QLatin1String("white")) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("#ffffff"))));
          } else if (fillArg == QLatin1String("gray")) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(QStringLiteral("#808080"))));
          } else if (fillArg.startsWith(QLatin1Char('#'))) {
            QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                      Q_ARG(QVariant, QVariant(fillArg)));
          } else {
            qWarning() << "KogaView dev ui request: no crop background" << fillArg;
          }
        }
        // A click with no travel asks for the whole picture, through the same
        // helper the canvas `MouseArea` calls when the pointer did not move.
        if (fullFrame) {
          QMetaObject::invokeMethod(editor, "createFullCropFrame");
        }
        // Locks are pressed through their own buttons, so a refused third lock
        // snaps back exactly as it does under a hand.
        const QString lockArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        if (!lockArg.isEmpty()) {
          const QStringList wanted = lockArg.split(QLatin1Char('+'));
          for (const QString& which : wanted) {
            const QString name = QStringLiteral("cropLock")
              + which.left(1).toUpper() + which.mid(1);
            QObject* button = editor->findChild<QObject*>(name);
            if (button != nullptr) {
              QMetaObject::invokeMethod(button, "click");
            } else {
              qWarning() << "KogaView dev ui request: no crop lock" << which;
            }
          }
        }
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4") == QLatin1String("reset")) {
          QObject* reset = editor->findChild<QObject*>(QStringLiteral("resetCropOptions"));
          if (reset != nullptr) {
            QMetaObject::invokeMethod(reset, "click");
          }
        }
        auto fieldText = [editor](const char* name) {
          QObject* field = editor->findChild<QObject*>(QString::fromLatin1(name));
          return field != nullptr ? field->property("text") : QVariant();
        };
        if (clearAfter) {
          // Log what Clear is about to put down: the shot alone cannot say
          // whether the frame, the fields and the locks were there first.
          qInfo().noquote() << "KogaView dev ui request editor-crop before clear"
                            << "locks" << editor->property("cropLockWidth")
                            << editor->property("cropLockHeight")
                            << editor->property("cropLockRatio") << "frame"
                            << editor->property("cropFrameShown") << "rect"
                            << fieldText("cropX") << fieldText("cropY")
                            << fieldText("cropWidth") << fieldText("cropHeight");
          QObject* clear = editor->findChild<QObject*>(QStringLiteral("clearCrop"));
          if (clear != nullptr) {
            QMetaObject::invokeMethod(clear, "click");
          }
        }
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG5") == QLatin1String("apply")) {
          QObject* applyButton = editor->findChild<QObject*>(QStringLiteral("applyCrop"));
          if (applyButton != nullptr) {
            QMetaObject::invokeMethod(applyButton, "click");
          } else {
            qWarning() << "KogaView dev ui request: no Apply crop button";
          }
        }
        qInfo().noquote() << "KogaView dev ui request editor-crop" << size << "preset"
                          << index << "anchor" << editor->property("cropAnchor")
                          << "mode" << editor->property("cropMode") << "background"
                          << editor->property("backgroundColor") << "transparent"
                          << editor->property("backgroundTransparent") << "ratio"
                          << editor->property("cropRatio") << "locks"
                          << editor->property("cropLockWidth")
                          << editor->property("cropLockHeight")
                          << editor->property("cropLockRatio") << "tool"
                          << editor->property("tool") << "frame"
                          << editor->property("cropFrameShown") << "document"
                          << editor->property("documentWidth")
                          << editor->property("documentHeight") << "rect"
                          << fieldText("cropX") << fieldText("cropY")
                          << fieldText("cropWidth") << fieldText("cropHeight");
        emitted = unframed || fullFrame || clearAfter
          || (index >= 0 && anchorButton != nullptr);
      } else if (uiRequest == QLatin1String("editor-transform")) {
        // The Transform frame without a pointer: the tool button is clicked and
        // a corner or an edge is dragged through `dragTransformCorner`/
        // `dragTransformEdge`, the same two functions the canvas handles call.
        // `_ARG` is `X,Y` in document pixels (default 120,80), `_ARG2` is the
        // corner index 0–3 or `e0`–`e3` for an edge, `_ARG3` is `quad` to put
        // the tool in `perspective` (which no control can arm) and `_ARG4` is
        // `apply` to press Apply after logging.
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        QObject* tool = editor->findChild<QObject*>(QStringLiteral("toolTransform"));
        if (tool == nullptr) {
          qWarning() << "KogaView dev ui request: Transform tool button missing";
          return;
        }
        if (!tool->property("highlighted").toBool()) {
          QMetaObject::invokeMethod(tool, "click");
        }
        const double zoom = editor->property("zoom").toDouble();
        const double originX = editor->property("canvasOriginX").toDouble();
        const double originY = editor->property("canvasOriginY").toDouble();
        const QString pointArg = requestArg.isEmpty() ? QStringLiteral("120,80") : requestArg;
        const QStringList point = pointArg.split(QLatin1Char(','));
        const double docX = point.value(0).toDouble();
        const double docY = point.value(1).toDouble();
        const double hostX = originX + docX * zoom;
        const double hostY = originY + docY * zoom;
        const QString modeArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        if (modeArg == QLatin1String("scale") || modeArg == QLatin1String("free")) {
          QMetaObject::invokeMethod(editor, "setTransformMode",
                                    Q_ARG(QVariant, QVariant(modeArg)));
        }
        const QString target = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const bool edge = target.startsWith(QLatin1Char('e'));
        const int index = (edge ? target.mid(1) : target).isEmpty()
                            ? 0
                            : (edge ? target.mid(1) : target).toInt();
        int modifiers = 0;
        const QString modArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG5");
        if (modArg.contains(QLatin1String("shift"))) {
          modifiers |= Qt::ShiftModifier;
        }
        if (modArg.contains(QLatin1String("alt"))) {
          modifiers |= Qt::AltModifier;
        }
        if (modArg.contains(QLatin1String("ctrl"))) {
          modifiers |= Qt::ControlModifier;
        }
        if (edge) {
          QMetaObject::invokeMethod(editor, "dragTransformEdge",
                                    Q_ARG(QVariant, QVariant(index)),
                                    Q_ARG(QVariant, QVariant(hostX)),
                                    Q_ARG(QVariant, QVariant(hostY)),
                                    Q_ARG(QVariant, QVariant(modifiers)),
                                    Q_ARG(QVariant, QVariant()));
        } else {
          QMetaObject::invokeMethod(editor, "dragTransformCorner",
                                    Q_ARG(QVariant, QVariant(index)),
                                    Q_ARG(QVariant, QVariant(hostX)),
                                    Q_ARG(QVariant, QVariant(hostY)),
                                    Q_ARG(QVariant, QVariant(modifiers)),
                                    Q_ARG(QVariant, QVariant()));
        }
        QQmlExpression corners(QQmlEngine::contextForObject(editor), editor,
                               QStringLiteral("JSON.stringify(transformCorners)"));
        qInfo().noquote() << "KogaView dev ui request editor-transform"
                          << pointArg << (edge ? "edge" : "corner") << index
                          << "mode" << editor->property("transformMode")
                          << "corners" << corners.evaluate().toString()
                          << "zoom" << editor->property("zoom").toDouble()
                          << "tool" << editor->property("tool");
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4") == QLatin1String("apply")) {
          QObject* apply = editor->findChild<QObject*>(QStringLiteral("applyTransform"));
          if (apply != nullptr) {
            qInfo().noquote() << "KogaView dev ui request editor-transform before apply"
                              << "enabled" << apply->property("enabled");
            QMetaObject::invokeMethod(apply, "click");
            qInfo().noquote() << "KogaView dev ui request editor-transform after apply"
                              << "tool" << editor->property("tool");
          }
        }
        emitted = true;
      } else if (uiRequest == QLatin1String("editor-paint")) {
        // A stroke without a pointer: the palette's Brush/Eraser button is
        // clicked and the points go through `beginPaintStroke` /
        // `extendPaintStroke` / `finishPaintStroke`, the same functions the
        // canvas MouseArea calls. The points arrive in document pixels and are
        // mapped to the canvas host the way `docToHost` does, so the command
        // Core receives describes the same line the screenshot shows.
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const bool erasing =
          qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2") == QLatin1String("eraser");
        QObject* tool = editor->findChild<QObject*>(
          erasing ? QStringLiteral("toolEraser") : QStringLiteral("toolBrush"));
        if (tool == nullptr) {
          qWarning() << "KogaView dev ui request: paint tool button missing";
          return;
        }
        QMetaObject::invokeMethod(tool, "click");
        const QString colour = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        if (!colour.isEmpty()) {
          editor->setProperty("foregroundColor", colour);
        }
        const QString size = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4");
        if (!size.isEmpty()) {
          editor->setProperty("paintSize", size.toDouble());
        }
        const QString opacity = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG5");
        if (!opacity.isEmpty()) {
          editor->setProperty("paintOpacity", opacity.toInt());
        }
        const double zoom = editor->property("zoom").toDouble();
        const double originX = editor->property("canvasOriginX").toDouble();
        const double originY = editor->property("canvasOriginY").toDouble();
        const QString strokeArg =
          requestArg.isEmpty() ? QStringLiteral("120,80;240,160") : requestArg;
        const QStringList points = strokeArg.split(QLatin1Char(';'), Qt::SkipEmptyParts);
        bool began = false;
        int mapped = 0;
        for (const QString& point : points) {
          const QStringList pair = point.split(QLatin1Char(','));
          if (pair.size() != 2) {
            continue;
          }
          const double hostX = originX + pair.at(0).toDouble() * zoom;
          const double hostY = originY + pair.at(1).toDouble() * zoom;
          const QByteArray method = began ? "extendPaintStroke" : "beginPaintStroke";
          QMetaObject::invokeMethod(editor, method.constData(),
                                    Q_ARG(QVariant, QVariant(hostX)),
                                    Q_ARG(QVariant, QVariant(hostY)));
          began = true;
          ++mapped;
        }
        qInfo().noquote() << "KogaView dev ui request editor-paint" << strokeArg
                          << (erasing ? "eraser" : "brush") << "points" << mapped
                          << "brush" << editor->property("paintSize")
                          << editor->property("paintOpacity")
                          << editor->property("foregroundColor")
                          << "stroking" << editor->property("paintStroking");
        QMetaObject::invokeMethod(editor, "finishPaintStroke");
        qInfo().noquote() << "KogaView dev ui request editor-paint sent"
                          << "stroking" << editor->property("paintStroking");
        emitted = mapped > 0;
      } else if (uiRequest == QLatin1String("editor-dock")) {
        // The right dock without a pointer: `_ARG` is the reference tab
        // (`info`, `history` or `original`), `_ARG2` a comma-separated list of
        // panels to hide (`tools`, `options`, `info`, `history`, `original`,
        // `quickAccess`, `explorer`), `_ARG5` the same list to show, `_ARG3` the
        // dock's width in pixels, `_ARG8` the left dock's width, `_ARG4` a tool
        // to arm (`crop`, `brush`, `eraser`, `transform`) by clicking its real
        // rail button, and `_ARG6` a reference height in pixels sent through
        // the divider's own `moved`/`released`. Panels and widths travel as
        // `layoutRequested` patches, the same call the form and the splitters
        // make, so the shell merges them and Core saves them.
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const QString wantedTool = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4");
        if (!wantedTool.isEmpty()) {
          const QString name = QStringLiteral("tool") + wantedTool.left(1).toUpper()
                               + wantedTool.mid(1);
          QObject* button = editor->findChild<QObject*>(name);
          if (button == nullptr) {
            qWarning() << "KogaView dev ui request: no tool button" << name;
            return;
          }
          // A tool button is a toggle: click only while it is not selected.
          if (!button->property("highlighted").toBool()) {
            QMetaObject::invokeMethod(button, "click");
          }
        }
        const QString tab = requestArg.isEmpty() ? QStringLiteral("info") : requestArg;
        // The tab is layout state now, so it travels through the same function
        // a tab click calls; the shell merges the patch into `set_layout`. An
        // empty `_ARG` leaves the saved tab alone, which is how a persistence
        // run reads back what the last launch saved instead of overwriting it.
        if (!requestArg.isEmpty()) {
          QMetaObject::invokeMethod(editor, "showRightTab", Q_ARG(QVariant, tab));
        }
        // The checklist handler is `setPanelVisible`, the same function the
        // menu's `toggled` signal calls.
        auto setPanels = [editor](const QString& list, bool visible) {
          const QStringList keys = list.split(QLatin1Char(','), Qt::SkipEmptyParts);
          for (const QString& key : keys) {
            QMetaObject::invokeMethod(editor, "setPanelVisible",
                                      Q_ARG(QVariant, key.trimmed()),
                                      Q_ARG(QVariant, visible));
          }
        };
        setPanels(qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2"), false);
        setPanels(qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG5"), true);
        const QString width = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        if (!width.isEmpty()) {
          QVariantMap patch;
          patch.insert(QStringLiteral("rightWidth"), width.toInt());
          QMetaObject::invokeMethod(editor, "layoutRequested", Q_ARG(QVariant, patch));
        }
        const QString leftWidth = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG8");
        if (!leftWidth.isEmpty()) {
          QVariantMap patch;
          patch.insert(QStringLiteral("leftWidth"), leftWidth.toInt());
          QMetaObject::invokeMethod(editor, "layoutRequested", Q_ARG(QVariant, patch));
        }
        const QString dividerArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG6");
        if (!dividerArg.isEmpty()) {
          // The handle is a `PanelSplitter`: emitting its `moved` runs the same
          // handler a drag does, and the argument is the height it reports.
          QObject* divider = editor->findChild<QObject*>(QStringLiteral("editorToolZoneDivider"));
          if (divider == nullptr) {
            qWarning() << "KogaView dev ui request: dock divider missing";
            return;
          }
          QMetaObject::invokeMethod(divider, "moved",
                                    Q_ARG(qreal, dividerArg.toDouble()));
          // The drag itself is only saved on release; the hook ends the drag the
          // way a pointer coming up does, so the layout remembers the height.
          QMetaObject::invokeMethod(divider, "released",
                                    Q_ARG(qreal, dividerArg.toDouble()));
        }
        if (QObject* zone = editor->findChild<QObject*>(QStringLiteral("editorToolZone"))) {
          // The layout settles a frame after the tab, the panels and the
          // widths have been written, so measure what the window actually
          // drew, not the pre-layout zero. This runs for every dock request,
          // not only a dragged divider, so a saved layout and a content-fit
          // dock both report a number next to their grab.
          QObject* dividerProbe =
            editor->findChild<QObject*>(QStringLiteral("editorToolZoneDivider"));
          QObject* stripProbe = editor->findChild<QObject*>(QStringLiteral("editorRightTabs"));
          QObject* referenceProbe =
            editor->findChild<QObject*>(QStringLiteral("editorReferenceDock"));
          QObject* inspectorProbe = editor->findChild<QObject*>(QStringLiteral("editorInspector"));
          QTimer::singleShot(1200, editor, [zone, dividerProbe, stripProbe,
                                            referenceProbe, inspectorProbe]() {
            auto sceneTop = [](QObject* item) {
              QQmlExpression expression(QQmlEngine::contextForObject(item), item,
                                        QStringLiteral("mapToItem(null, 0, 0).y"));
              return expression.evaluate().toDouble();
            };
            qInfo() << "KogaView dev ui request: tool zone height"
                    << zone->property("height") << "implicit"
                    << zone->property("implicitHeight") << "top" << sceneTop(zone)
                    << "bottom" << sceneTop(zone) + zone->property("height").toDouble()
                    << "divider" << (dividerProbe ? sceneTop(dividerProbe) : -1.0)
                    << "strip" << (stripProbe ? sceneTop(stripProbe) : -1.0)
                    << "reference dock"
                    << (referenceProbe ? referenceProbe->property("height").toDouble() : -1.0)
                    << "needs"
                    << (referenceProbe ? referenceProbe->property("contentHeight").toDouble() : -1.0)
                    << "page"
                    << (referenceProbe ? referenceProbe->property("pageContentHeight").toDouble()
                                       : -1.0)
                    << "inspector"
                    << (inspectorProbe ? inspectorProbe->property("height").toDouble() : -1.0);
          });
        }
        qInfo().noquote() << "KogaView dev ui request editor-dock" << "tab"
                          << editor->property("rightTab") << "panels"
                          << editor->property("toolOptionsVisible")
                          << editor->property("infoVisible")
                          << editor->property("historyVisible")
                          << editor->property("originalVisible") << "reference"
                          << editor->property("referenceHeight") << "content"
                          << editor->property("referencePageHeight") << "left"
                          << editor->property("leftPanelWidth") << "width"
                          << editor->property("rightPanelWidth") << "columns"
                          << editor->property("toolColumns") << "tool"
                          << editor->property("tool") << "index"
                          << editor->property("rightTabIndex");
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG7") == QLatin1String("menu")) {
          // The window's menu is where the workspace entries live; the panel
          // checklist itself is Settings › Appearance. Photograph what exists.
          openMainMenu(rootObject);
        }
        emitted = true;
      } else if (uiRequest == QLatin1String("editor-colour")) {
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        if (editor == nullptr) {
          qWarning() << "KogaView dev ui request: editor view not found";
          return;
        }
        const QString action = requestArg;
        const QString backgroundArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        // The background first: it is a state (`transparent`) or a colour, and
        // the two functions below are the ones the list and the chooser call.
        if (backgroundArg == QLatin1String("transparent")) {
          QMetaObject::invokeMethod(editor, "setBackgroundTransparent",
                                    Q_ARG(QVariant, QVariant(true)));
        } else if (!backgroundArg.isEmpty() && backgroundArg.startsWith(QLatin1Char('#'))) {
          QMetaObject::invokeMethod(editor, "setBackgroundColor",
                                    Q_ARG(QVariant, QVariant(backgroundArg)));
        }
        // The rail's own pair and its two boxes: a dev hook that finds them by
        // name is also the check that the component really is in the rail.
        QObject* pair = editor->findChild<QObject*>(QStringLiteral("colourPair"));
        QObject* foregroundBox =
          pair != nullptr ? pair->findChild<QObject*>(QStringLiteral("colourPairForegroundSwatch"))
                          : nullptr;
        QObject* backgroundBox =
          pair != nullptr ? pair->findChild<QObject*>(QStringLiteral("colourPairBackgroundSwatch"))
                          : nullptr;
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4") == QLatin1String("notools")) {
          // The same key the sidebar checklist uses: `setPanelVisible` adds the
          // `editor.` prefix itself.
          QMetaObject::invokeMethod(editor, "setPanelVisible",
                                    Q_ARG(QVariant, QStringLiteral("tools")),
                                    Q_ARG(QVariant, false));
        }
        QObject* brush = editor->findChild<QObject*>(QStringLiteral("toolBrush"));
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3") == QLatin1String("brush")
            && brush != nullptr && !brush->property("highlighted").toBool()) {
          QMetaObject::invokeMethod(brush, "click");
        }
        if (action == QLatin1String("swap")) {
          QMetaObject::invokeMethod(editor, "swapColours");
        } else if (action == QLatin1String("reset")) {
          QMetaObject::invokeMethod(editor, "resetColours");
        } else if (action == QLatin1String("list")) {
          // The click the box's `MouseArea` makes, with the box as the anchor.
          if (backgroundBox == nullptr) {
            qWarning() << "KogaView dev ui request: no background box to open under";
          } else {
            QMetaObject::invokeMethod(editor, "openBackgroundPopup",
                                      Q_ARG(QVariant, QVariant::fromValue(backgroundBox)));
          }
        } else if (action == QLatin1String("foreground")) {
          QMetaObject::invokeMethod(editor, "openForegroundChooser");
        } else if (action.startsWith(QLatin1String("pick:"))) {
          // A row of the list, chosen the way its `MouseArea` chooses it.
          QObject* popup = editor->findChild<QObject*>(QStringLiteral("backgroundPopup"));
          const QString key = action.mid(5);
          if (popup == nullptr) {
            qWarning() << "KogaView dev ui request: no background list";
          } else {
            QMetaObject::invokeMethod(popup, "choose", Q_ARG(QVariant, QVariant(key)));
          }
        } else if (action.startsWith(QLatin1Char('#'))) {
          QMetaObject::invokeMethod(editor, "setForegroundColor",
                                    Q_ARG(QVariant, QVariant(action)));
        }
        // Geometry after the layout settles, so a grab and a log agree about
        // where the pair put its boxes.
        QTimer::singleShot(900, editor, [editor, pair, foregroundBox, backgroundBox]() {
          QObject* popup = editor->findChild<QObject*>(QStringLiteral("backgroundPopup"));
          auto rectOf = [](QObject* item) {
            if (item == nullptr) {
              return QStringLiteral("none");
            }
            return QStringLiteral("%1,%2 %3x%4")
              .arg(item->property("x").toDouble())
              .arg(item->property("y").toDouble())
              .arg(item->property("width").toDouble())
              .arg(item->property("height").toDouble());
          };
          qInfo().noquote()
            << "KogaView dev ui request editor-colour"
            << "pair" << (pair != nullptr ? rectOf(pair) : QStringLiteral("missing"))
            << "visible" << (pair != nullptr && pair->property("visible").toBool())
            << "foreground" << rectOf(foregroundBox) << "background"
            << rectOf(backgroundBox) << "colour"
            << editor->property("foregroundColor") << editor->property("backgroundColor")
            << "transparent" << editor->property("backgroundTransparent") << "list"
            << (popup != nullptr && popup->property("opened").toBool());
        });
        emitted = true;
      } else if (uiRequest == QLatin1String("batch")) {
        // The batch form without a pointer: the shell's `openBatchDialog` is
        // called (the function the Tools… menu entry and the page's three
        // buttons call), the fields are written the way the form's own controls
        // write them, and Run is pressed through `run()` — the same handler the
        // button's `onClicked` runs, so the form's validation still decides.
        // The selection first, made the way a Ctrl click and a Shift click make
        // it: `_ARG10` is a list of `index:how` (`0:plain`, `1:ctrl`,
        // `2:shift`) and each step calls the grid's own `clickIndex` — the
        // handler the cell's `MouseArea` calls with its event's modifiers. The
        // selection is Core's, so each step waits for it before the next one
        // extends from it.
        const QString clicks = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG10");
        for (const QString& step : clicks.split(QLatin1Char(','), Qt::SkipEmptyParts)) {
          const QStringList pair = step.split(QLatin1Char(':'));
          const int index = pair.value(0).toInt();
          const QString how = pair.value(1);
          int modifiers = Qt::NoModifier;
          if (how == QLatin1String("ctrl")) {
            modifiers = Qt::ControlModifier;
          } else if (how == QLatin1String("shift")) {
            modifiers = Qt::ShiftModifier;
          }
          QMetaObject::invokeMethod(browser, "clickIndex", Q_ARG(QVariant, index),
                                    Q_ARG(QVariant, modifiers));
          QTest::qWait(150);
          const QVariantList chosen =
            rootObject->property("state").toMap().value(QStringLiteral("selection")).toList();
          QStringList names;
          for (const QVariant& path : chosen) {
            names << QFileInfo(path.toString()).fileName();
          }
          qInfo().noquote() << "KogaView dev ui request batch selection"
                            << QString::number(chosen.size()) << names.join(QLatin1Char(' '));
        }
        const QString mode = requestArg.isEmpty() ? QStringLiteral("resize") : requestArg;
        bool opened = false;
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG9") == QLatin1String("page")) {
          // The page's own button: `BatchPanel` emits `requestBatch(mode)` and
          // the shell opens the form, which is the path a user's click takes.
          const QString button = QStringLiteral("batch")
                                 + mode.at(0).toUpper() + mode.mid(1);
          QObject* pageButton = rootObject->findChild<QObject*>(button);
          if (pageButton == nullptr) {
            qWarning() << "KogaView dev ui request: no batch page button" << button;
            return;
          }
          opened = QMetaObject::invokeMethod(pageButton, "click");
          qInfo().noquote() << "KogaView dev ui request batch page button" << button
                            << (opened ? "clicked" : "not clickable");
        } else {
          opened = QMetaObject::invokeMethod(rootObject, "openBatchDialog",
                                             Q_ARG(QVariant, QVariant(mode)));
        }
        // Each action is its own dialog (`BatchResizeDialog`, `BatchCropDialog`,
        // `BatchConvertDialog`), so the hook looks up the one that action owns —
        // the same object `openBatchDialog` picked.
        const QString dialogName = QStringLiteral("batch") + mode.at(0).toUpper() + mode.mid(1)
                                   + QStringLiteral("Dialog");
        QObject* dialog = rootObject->findChild<QObject*>(dialogName);
        if (!opened || dialog == nullptr) {
          qWarning() << "KogaView dev ui request: no batch dialog" << dialogName;
          qWarning() << "KogaView dev ui request: batch dialog not opened";
          return;
        }
        for (int wait = 0; wait < 100 && !dialog->property("visible").toBool(); ++wait) {
          QCoreApplication::processEvents();
          QTest::qWait(10);
        }
        if (!dialog->property("visible").toBool()) {
          qWarning() << "KogaView dev ui request: batch dialog did not open";
          return;
        }
        const QString answer = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        // `_ARG2` writes the field the action asks about: a size for resize, the
        // percentages for crop, the encoder for convert.
        auto writeField = [dialog](const char* name, const QString& text) {
          QObject* field = dialog->findChild<QObject*>(QString::fromLatin1(name));
          if (field == nullptr) {
            qWarning() << "KogaView dev ui request: no batch field" << name;
            return;
          }
          // `UnitField` holds the number in its own input, and its `textEdited`
          // is what links the other side; writing `text` alone would leave the
          // fields describing different sizes.
          QObject* input = field->property("inputField").value<QObject*>();
          if (input != nullptr) {
            input->setProperty("text", text);
            QMetaObject::invokeMethod(field, "textEdited");
          } else {
            field->setProperty("text", text);
          }
        };
        if (qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG6") == QLatin1String("free")) {
          // Before the fields: with the chain on, typing the first side rewrites
          // the second, and the pair the hook asked for would not survive.
          QMetaObject::invokeMethod(dialog, "setConstraint", Q_ARG(QVariant, false));
        }
        if (mode == QLatin1String("resize")) {
          const QStringList parts = answer.split(QLatin1Char('x'));
          writeField("batchResizeWidth", parts.value(0));
          writeField("batchResizeHeight", parts.value(1));
        } else if (mode == QLatin1String("crop")) {
          const QStringList parts = answer.split(QLatin1Char(','));
          writeField("batchCropX", parts.value(0));
          writeField("batchCropY", parts.value(1));
          writeField("batchCropWidth", parts.value(2));
          writeField("batchCropHeight", parts.value(3));
        } else if (!answer.isEmpty()) {
          // The format combo applies its choice from `onActivated`, which a
          // `currentIndex` write does not emit; go through the same handler.
          QObject* box = dialog->findChild<QObject*>(QStringLiteral("batchConvertFormat"));
          const QVariantList formats = dialog->property("formats").toList();
          int index = -1;
          for (int i = 0; i < formats.size(); ++i) {
            if (formats.at(i).toMap().value(QStringLiteral("key")).toString() == answer) {
              index = i;
              break;
            }
          }
          if (box == nullptr || index < 0) {
            qWarning() << "KogaView dev ui request: no convert format" << answer;
            return;
          }
          box->setProperty("currentIndex", index);
          QMetaObject::invokeMethod(box, "activated", Q_ARG(int, index));
        }
        // Another folder is the third destination and it is a radio, so the
        // write has to go through the control's own handler as well.
        const QString folderArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG8");
        if (!folderArg.isEmpty()) {
          QObject* radio = dialog->findChild<QObject*>(QStringLiteral("batchOutputFolder"));
          if (radio == nullptr) {
            qWarning() << "KogaView dev ui request: no output folder radio";
            return;
          }
          QMetaObject::invokeMethod(radio, "click");
          dialog->setProperty("outputFolder", folderArg);
          if (dialog->property("outputKind").toString() != QLatin1String("folder")) {
            qWarning() << "KogaView dev ui request: the folder radio did not take";
            return;
          }
        }
        const QString overwriteArg = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        if (overwriteArg == QLatin1String("overwrite")) {
          QObject* box = dialog->findChild<QObject*>(QStringLiteral("batchOverwrite"));
          if (box != nullptr) {
            box->setProperty("checked", true);
          }
        }
        // What the form would send, before it sends it: the payload is the one
        // contract a batch has with Core.
        QVariant command;
        const bool computed =
          QMetaObject::invokeMethod(dialog, "command", Q_RETURN_ARG(QVariant, command));
        qInfo().noquote() << "KogaView dev ui request batch command"
                          << (computed ? command.typeName() : "not invokable")
                          << QString::fromUtf8(QJsonDocument::fromVariant(command.toMap())
                                                 .toJson(QJsonDocument::Compact));
        QVariant refusalValue;
        QMetaObject::invokeMethod(dialog, "validationError",
                                  Q_RETURN_ARG(QVariant, refusalValue));
        const QString refusal = refusalValue.toString();
        qInfo().noquote() << "KogaView dev ui request batch validation"
                          << (refusal.isEmpty() ? QStringLiteral("ready") : refusal);
        emitted = true;
        const QString action = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4");
        if (!refusal.isEmpty()) {
          return;
        }
        if (action == QLatin1String("fill")) {
          return;
        }
        const int delay = qEnvironmentVariableIntValue("KOGAVIEW_DEV_UI_REQUEST_ARG5");
        QTimer::singleShot(delay > 0 ? delay : 300, rootObject, [rootObject, dialog, action]() {
          QMetaObject::invokeMethod(dialog, "run");
          qInfo().noquote() << "KogaView dev ui request batch run pressed";
          if (action == QLatin1String("cancel")) {
            // The page's own Cancel, mid-run: the button `click()` is the same
            // handler a press runs, and it emits `cancel_operation` like any
            // other Cancel. `_ARG7` is how long the job runs first.
            const int runFor = qEnvironmentVariableIntValue("KOGAVIEW_DEV_UI_REQUEST_ARG7");
            QTimer::singleShot(runFor > 0 ? runFor : 600, rootObject, [rootObject]() {
              QObject* cancel = rootObject->findChild<QObject*>(QStringLiteral("batchCancel"));
              if (cancel == nullptr) {
                qWarning() << "KogaView dev ui request: no batch Cancel";
                return;
              }
              QMetaObject::invokeMethod(cancel, "click");
              qInfo().noquote() << "KogaView dev ui request batch cancel pressed";
            });
          }
          // What Core published afterwards, sampled once the job has had time
          // to move: the page draws this and nothing else.
          QTimer::singleShot(1200, rootObject, [rootObject]() {
            const QVariantMap state =
              rootObject->property("state").toMap().value(QStringLiteral("batch")).toMap();
            if (state.isEmpty()) {
              qInfo().noquote() << "KogaView dev ui request batch state none";
              return;
            }
            qInfo().noquote() << "KogaView dev ui request batch state"
                              << state.value(QStringLiteral("operation")).toString()
                              << "done" << state.value(QStringLiteral("done")).toInt()
                              << "of" << state.value(QStringLiteral("total")).toInt()
                              << "failed" << state.value(QStringLiteral("failed")).toInt()
                              << "running" << state.value(QStringLiteral("running")).toBool()
                              << "cancelled"
                              << state.value(QStringLiteral("cancelled")).toBool()
                              << "current" << state.value(QStringLiteral("current")).toString();
          });
        });
      } else if (uiRequest == QLatin1String("sidebar-dock")) {
        // The Browser's and the Viewer's sidebar without a pointer. Both views
        // expose the same `setPanelVisible` function Settings › Appearance
        // calls, so this request drives it instead of naming a view.
        QObject* view = rootObject->findChild<QObject*>(QStringLiteral("browser"));
        QString keyProperty = QStringLiteral("rightPage");
        if (view == nullptr) {
          view = rootObject->findChild<QObject*>(QStringLiteral("viewer"));
          keyProperty.clear(); // the Viewer has one page and no tab strip
        }
        if (view == nullptr) {
          qWarning() << "KogaView dev ui request: no browser or viewer view";
          return;
        }
        auto setSidebarPanels = [view](const QString& list, bool visible) {
          const QStringList keys = list.split(QLatin1Char(','), Qt::SkipEmptyParts);
          for (const QString& key : keys) {
            QMetaObject::invokeMethod(view, "setPanelVisible",
                                      Q_ARG(QVariant, key.trimmed()),
                                      Q_ARG(QVariant, visible));
          }
        };
        setSidebarPanels(qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2"), false);
        setSidebarPanels(qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG5"), true);
        if (!keyProperty.isEmpty() && !requestArg.isEmpty()) {
          view->setProperty(keyProperty.toLatin1().constData(), requestArg);
        }
        const bool openList = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4")
                              == QLatin1String("menu");
        if (openList) {
          openMainMenu(rootObject);
        }
        QObject* dock = view->findChild<QObject*>(QStringLiteral("rightPanel"))
                        ?: view->findChild<QObject*>(QStringLiteral("viewerRightPanel"));
        qInfo().noquote() << "KogaView dev ui request sidebar-dock"
                          << (view->objectName()) << "page"
                          << (keyProperty.isEmpty() ? QStringLiteral("-")
                                                    : view->property(keyProperty.toLatin1().constData()).toString())
                          << "left" << view->property("quickAccessShown").toBool()
                          << view->property("explorerShown").toBool()
                          << "panels"
                          << (view->property("previewPanelVisible").isValid()
                                ? view->property("previewPanelVisible").toBool()
                                : view->property("infoPanelVisible").toBool())
                          << (view->property("batchPanelVisible").isValid()
                                ? view->property("batchPanelVisible").toBool()
                                : false)
                          << "widths" << view->property("leftPanelWidth").toInt()
                          << view->property("rightPanelWidth").toInt()
                          << "pages" << (dock ? dock->property("shownTabCount").toInt() : 0)
                          << "strip" << (dock ? dock->property("stripShown").toBool() : false);
        emitted = true;
      } else if (uiRequest == QLatin1String("editor-save-as")) {
        // The Editor's Save as… without a pointer: `chooseEditorSaveAs` is what
        // the toolbar button's signal runs. It asks the desktop's own save
        // dialog (`FileChooser.SaveFile`), so the log line that matters is the
        // portal's; nothing is written until the dialog answers. `_ARG2=export`
        // takes the other save chooser — the Export dialog's Browse — which is
        // the same request with a different answer to write.
        const bool exportAsk =
          qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2") == QLatin1String("export");
        emitted = QMetaObject::invokeMethod(rootObject, exportAsk ? "chooseEditorExportPath"
                                                                  : "chooseEditorSaveAs");
        qInfo().noquote() << "KogaView dev ui request editor-save-as"
                          << (exportAsk ? "export browse" : "save as")
                          << (emitted ? "asked" : "not invokable");
        // `_ARG` answers the chooser with a path, through `handleSaveFileChosen`
        // — the one handler the portal's `saveFileSelected` signal and the Qt
        // fallback's `onAccepted` both call. The run shows the request reaching
        // the desktop; this shows what its answer writes.
        if (!requestArg.isEmpty()) {
          const QString answer = requestArg;
          QTimer::singleShot(1500, rootObject, [rootObject, answer, exportAsk]() {
            QMetaObject::invokeMethod(rootObject, "handleSaveFileChosen",
                                      Q_ARG(QVariant, QVariant(answer)));
            QTest::qWait(900);
            const QVariantMap editor =
              rootObject->property("state").toMap().value(QStringLiteral("editor")).toMap();
            qInfo().noquote() << "KogaView dev ui request editor-save-as wrote"
                              << QFileInfo::exists(answer) << "saved"
                              << editor.value(QStringLiteral("saved")).toBool()
                              << "modified"
                              << editor.value(QStringLiteral("modified")).toBool();
            if (exportAsk) {
              // The Export dialog's field is where its Browse answer lands, and
              // nothing is written until Export is pressed: the path arriving
              // there is the whole contract of this route.
              QQmlExpression field(QQmlEngine::contextForObject(rootObject), rootObject,
                                   QStringLiteral("workspaceLoader.item.exportPath"));
              qInfo().noquote() << "KogaView dev ui request editor-save-as export path"
                                << field.evaluate().toString();
            }
          });
        }
      } else if (uiRequest == QLatin1String("editor-export")) {
        // The toolbar's Export button is `click()`ed, which is the same handler
        // a press runs, and the dialog's fields are written the way the dialog's
        // own controls write them. `_ARG` is the destination path, `_ARG2` the
        // quality, `_ARG3` the literal `confirm` to press Export, `_ARG4` the
        // long edge the Size list offers (`0` keeps the document's size).
        QObject* editor = rootObject->findChild<QObject*>(QStringLiteral("editor"));
        QObject* button = rootObject->findChild<QObject*>(QStringLiteral("editorToolbarExport"));
        if (editor == nullptr || button == nullptr) {
          qWarning() << "KogaView dev ui request: export button or editor missing";
          return;
        }
        QMetaObject::invokeMethod(button, "click");
        QCoreApplication::processEvents();
        const QString destination = requestArg;
        const QString quality = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG2");
        const QString confirm = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG3");
        if (!destination.isEmpty()) {
          editor->setProperty("exportPath", destination);
        }
        if (!quality.isEmpty()) {
          editor->setProperty("exportQuality", quality.toInt());
        }
        const QString edge = qEnvironmentVariable("KOGAVIEW_DEV_UI_REQUEST_ARG4");
        if (!edge.isEmpty()) {
          // Go through the same function the combo box's `onActivated` calls, so
          // the request picks a row the dialog really offers; a limit that is not
          // in the list is reported rather than written as an unknown size.
          const QVariantList sizes = editor->property("exportEdges").toList();
          const int index = sizes.indexOf(edge.toInt());
          const bool chosen = index >= 0 &&
                              QMetaObject::invokeMethod(editor, "chooseExportSize",
                                                        Q_ARG(QVariant, QVariant(index)));
          qInfo().noquote() << "KogaView dev ui request editor-export size" << edge
                            << "index" << index << (chosen ? "chosen" : "not offered");
        }
        QCoreApplication::processEvents();
        QObject* dialog = rootObject->findChild<QObject*>(QStringLiteral("exportDialog"));
        qInfo().noquote() << "KogaView dev ui request editor-export"
                          << "open" << (dialog != nullptr && dialog->property("visible").toBool())
                          << "path" << editor->property("exportPath")
                          << "quality" << editor->property("exportQuality")
                          << "longEdge" << editor->property("exportLongEdge")
                          << "tool" << editor->property("tool")
                          << "metadata" << editor->property("exportMetadata")
                          << "lossy" << editor->property("exportTargetIsLossy")
                          << "valid" << editor->property("exportPathValid");
        if (confirm == QLatin1String("confirm")) {
          QObject* accept = rootObject->findChild<QObject*>(QStringLiteral("exportConfirm"));
          if (accept != nullptr) {
            QMetaObject::invokeMethod(accept, "click");
            QCoreApplication::processEvents();
            // The dialog is modal and the request clicked a control inside it;
            // the tool the editor is left on belongs in the log, because a
            // closed dialog must not change it.
            qInfo().noquote() << "KogaView dev ui request editor-export after confirm"
                              << "tool" << editor->property("tool")
                              << "open" << (dialog != nullptr && dialog->property("visible").toBool());
          }
        }
        emitted = dialog != nullptr && dialog->property("visible").toBool();
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

extern "C" {
bool kogaview_extract_archive_preview(const char* path, uint8_t** out_ptr, size_t* out_len);
bool kogaview_copy_editor_frame(const char* kind, uint8_t** out_ptr, uint32_t* out_w, uint32_t* out_h);
void kogaview_free_buffer(uint8_t* ptr, size_t len);
}

class EditorImageProvider final : public QQuickImageProvider
{
public:
  EditorImageProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
  {}

  QImage requestImage(const QString& id, QSize* size, const QSize& requestedSize) override
  {
    QString kind = id;
    const qsizetype q = kind.indexOf(QLatin1Char('?'));
    if (q >= 0) {
      kind = kind.left(q);
    }
    uint8_t* raw = nullptr;
    uint32_t w = 0;
    uint32_t h = 0;
    const QByteArray utf8 = kind.toUtf8();
    if (!kogaview_copy_editor_frame(utf8.constData(), &raw, &w, &h) || raw == nullptr || w == 0 || h == 0) {
      return {};
    }
    const size_t byteLen = static_cast<size_t>(w) * static_cast<size_t>(h) * 4u;
    QImage image = QImage(raw, static_cast<int>(w), static_cast<int>(h),
                          static_cast<qsizetype>(w) * 4, QImage::Format_RGBA8888)
                     .copy();
    kogaview_free_buffer(raw, byteLen);
    if (image.isNull()) {
      return {};
    }
    if (size != nullptr) {
      *size = image.size();
    }
    if (requestedSize.isValid() && !requestedSize.isEmpty()) {
      return image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    return image;
  }
};

class ArchiveImageProvider final : public QQuickImageProvider
{
public:
  ArchiveImageProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
  {}

  QImage requestImage(const QString& id, QSize* size, const QSize& requestedSize) override
  {
    QString path = id;
    const qsizetype q = path.indexOf(QLatin1Char('?'));
    if (q >= 0) {
      path = path.left(q);
    }
    path = QUrl::fromPercentEncoding(path.toUtf8());
    uint8_t* raw = nullptr;
    size_t len = 0;
    const QByteArray utf8 = path.toUtf8();
    if (!kogaview_extract_archive_preview(utf8.constData(), &raw, &len) || raw == nullptr || len == 0) {
      return {};
    }
    QImage image = QImage::fromData(raw, static_cast<int>(len));
    kogaview_free_buffer(raw, len);
    if (image.isNull()) {
      return {};
    }
    if (size != nullptr) {
      *size = image.size();
    }
    if (requestedSize.isValid() && !requestedSize.isEmpty()) {
      return image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    return image;
  }
};

/// Load the QML entry point, reporting compile and instantiation errors.
/// A missing root object must fail loudly instead of starting a blank session.
QObject* loadUserInterface(QQmlEngine& engine, const QStringList& launchArguments,
                           PlatformHelper& platform, ThumbnailCache& thumbnails)
{
  engine.addImageProvider(QStringLiteral("archive"), new ArchiveImageProvider());
  engine.addImageProvider(QStringLiteral("editor"), new EditorImageProvider());
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

namespace {
class InputFocusDismissFilter : public QObject
{
public:
  explicit InputFocusDismissFilter(QObject* parent = nullptr)
    : QObject(parent)
  {
  }

  bool eventFilter(QObject* watched, QEvent* event) override
  {
    if (event->type() != QEvent::MouseButtonPress) {
      return false;
    }
    auto* window = qobject_cast<QQuickWindow*>(watched);
    if (window == nullptr) {
      return false;
    }
    QQuickItem* focused = window->activeFocusItem();
    if (focused == nullptr) {
      return false;
    }
    const bool isTextInput =
      focused->inherits("QQuickTextInput") || focused->inherits("QQuickTextEdit");
    if (!isTextInput) {
      return false;
    }
    // Keep focus while clicking inside the input itself or its enclosing
    // SpinBox/ComboBox (so SpinBox +/- buttons stay responsive).
    QQuickItem* control = focused;
    for (QQuickItem* p = focused->parentItem(); p != nullptr; p = p->parentItem()) {
      if (p->inherits("QQuickSpinBox") || p->inherits("QQuickComboBox")) {
        control = p;
        break;
      }
    }
    auto* mouse = static_cast<QMouseEvent*>(event);
    const QPointF local = control->mapFromScene(mouse->scenePosition());
    if (QRectF(0, 0, control->width(), control->height()).contains(local)) {
      return false;
    }
    // Clicked outside the input: blur it and hand focus back to the active
    // workspace so keyboard shortcuts (Space pan/next, tool keys) work right away.
    focused->setFocus(false);
    if (control != focused) {
      control->setFocus(false);
    }
    for (QQuickItem* p = control->parentItem(); p != nullptr; p = p->parentItem()) {
      const QString name = p->objectName();
      if (p->isVisible() && p->isEnabled() &&
          (name == QLatin1String("editor") || name == QLatin1String("viewer") ||
           name == QLatin1String("browser"))) {
        p->forceActiveFocus();
        break;
      }
    }
    return false;
  }
};
struct StartupGraphicsConfig
{
  bool hardwareAcceleration = true;
  bool antiAliasing = true;
  QString language;
};

StartupGraphicsConfig readStartupGraphicsConfig()
{
  StartupGraphicsConfig cfg;
  const QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
  const QString base =
    xdg.isEmpty() ? (QDir::homePath() + QStringLiteral("/.config")) : xdg;
  const QString profileEnv = qEnvironmentVariable("KOGAVIEW_PROFILE").trimmed().toLower();
#ifdef KOGAVIEW_DEV_HARNESS
  const bool devProfile = (profileEnv != QLatin1String("prod"));
#else
  const bool devProfile = (profileEnv == QLatin1String("dev"));
#endif
  const QString dirName =
    devProfile ? QStringLiteral("kogaview-dev") : QStringLiteral("kogaview");
  QFile file(base + QLatin1Char('/') + dirName + QStringLiteral("/config.json"));
  if (!file.open(QIODevice::ReadOnly)) {
    return cfg;
  }
  const QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
  if (!doc.isObject()) {
    return cfg;
  }
  const QJsonObject obj = doc.object();
  if (obj.contains(QStringLiteral("hardware_acceleration"))) {
    cfg.hardwareAcceleration = obj.value(QStringLiteral("hardware_acceleration")).toBool(true);
  }
  if (obj.contains(QStringLiteral("anti_aliasing"))) {
    cfg.antiAliasing = obj.value(QStringLiteral("anti_aliasing")).toBool(true);
  }
  if (obj.contains(QStringLiteral("language"))) {
    cfg.language = obj.value(QStringLiteral("language")).toString();
  }
  return cfg;
}
} // namespace

int main(int argc, char* argv[])
{
  bool cliSafeMode = qEnvironmentVariableIntValue("KOGAVIEW_SAFE_MODE") != 0;
  bool cliResetConfig = qEnvironmentVariableIntValue("KOGAVIEW_RESET_CONFIG") != 0;
  bool cliResetLayout = qEnvironmentVariableIntValue("KOGAVIEW_RESET_LAYOUT") != 0;
  for (int i = 1; i < argc; ++i) {
    const QString arg = QString::fromLocal8Bit(argv[i]);
    if (arg == QLatin1String("--safe-mode")) {
      cliSafeMode = true;
      qputenv("KOGAVIEW_SAFE_MODE", "1");
    } else if (arg == QLatin1String("--reset-config")) {
      cliResetConfig = true;
      qputenv("KOGAVIEW_RESET_CONFIG", "1");
    } else if (arg == QLatin1String("--reset-layout")) {
      cliResetLayout = true;
      qputenv("KOGAVIEW_RESET_LAYOUT", "1");
    }
  }
  Q_UNUSED(cliResetLayout);

  const StartupGraphicsConfig graphicsCfg =
    (cliSafeMode || cliResetConfig) ? StartupGraphicsConfig{} : readStartupGraphicsConfig();
  if (cliSafeMode || !graphicsCfg.hardwareAcceleration) {
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
  } else {
    QSurfaceFormat format = QSurfaceFormat::defaultFormat();
    format.setSwapInterval(1);
    QSurfaceFormat::setDefaultFormat(format);
  }

  QGuiApplication app(argc, argv);

  // On KDE Plasma 6, KDEPlasmaPlatformTheme6 forces `org.kde.breeze`, whose
  // controls read Kirigami.Theme (`kdeglobals`) and ignore QQuickItem and
  // QGuiApplication palettes — leaving menus, combo boxes, fields and button
  // labels stuck in the desktop's dark theme when KogaView switches to Light
  // mode (and vice versa). Qt's built-in `Fusion` style honours the palette
  // across KDE, GNOME, Windows and Flatpak while still respecting an explicit
  // `QT_QUICK_CONTROLS_STYLE` override.
  if (!qEnvironmentVariableIsSet("QT_QUICK_CONTROLS_STYLE")) {
    QQuickStyle::setStyle(QStringLiteral("Fusion"));
  }

  QGuiApplication::setApplicationName(kogaview_display_name());
  QGuiApplication::setApplicationVersion(kogaview_app_version());
  QGuiApplication::setApplicationDisplayName(kogaview_display_name());
  QGuiApplication::setOrganizationName(QStringLiteral("KogaView"));
  QGuiApplication::setDesktopFileName(kogaview_app_id());

  QStringList launchArguments = QCoreApplication::arguments().mid(1);
  launchArguments.removeAll(QStringLiteral("--safe-mode"));
  launchArguments.removeAll(QStringLiteral("--reset-config"));
  launchArguments.removeAll(QStringLiteral("--reset-layout"));
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
                "  kogaview edit FILE          open an image directly in the editor\n"
                "  kogaview open-folder DIR    open a folder in the browser\n"
                "  kogaview --safe-mode        start with factory defaults in memory (no plugins, software GPU)\n"
                "  kogaview --reset-layout     reset panel layout to defaults (backs up config.json)\n"
                "  kogaview --reset-config     reset all settings to factory defaults (backs up config.json)\n"
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

  // Pre-install the translator before loading QML so every `qsTr()` binding
  // evaluates in the target language on the first pass without a full
  // `engine.retranslate()` sweep right after startup.
  const QString envLang = qEnvironmentVariable("KOGAVIEW_UI_LANG");
  const QString initialLang = !envLang.isEmpty() ? envLang : graphicsCfg.language;
  auto* language = new InterfaceLanguage(&engine, nullptr, initialLang, &app);
  engine.rootContext()->setContextProperty(QStringLiteral("LanguageInstaller"), language);

  QObject* rootObject = loadUserInterface(engine, launchArguments, platform, thumbnails);
  if (rootObject == nullptr) {
    kogaview_shutdown();
    return 1;
  }

  language->setRootObject(rootObject);
  if (envLang.isEmpty()) {
    language->reapply();
  }

  QObject::connect(&engine, &QQmlEngine::quit, &app, &QGuiApplication::quit);
  QObject::connect(&engine, &QQmlEngine::exit, &app, &QCoreApplication::exit);
  auto* inputFocusFilter = new InputFocusDismissFilter(&app);
  app.installEventFilter(inputFocusFilter);

#ifdef KOGAVIEW_DEV_HARNESS
  installDevHarness(rootObject, app, platform, thumbnails);
  dispatchDevCommands(rootObject, app, thumbnails);
#endif

  const int result = app.exec();
  delete rootObject;
  kogaview_shutdown();
  return result;
}
