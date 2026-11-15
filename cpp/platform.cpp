#include "platform.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QDebug>
#include <QDesktopServices>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QTimer>
#include <QUrl>
#include <QWindow>
#include <QtConcurrent/QtConcurrentRun>

namespace {
constexpr auto kPortalService = "org.freedesktop.portal.Desktop";
constexpr auto kPortalPath = "/org/freedesktop/portal/desktop";
constexpr auto kFileChooserInterface = "org.freedesktop.portal.FileChooser";
constexpr auto kOpenUriInterface = "org.freedesktop.portal.OpenURI";
constexpr auto kRequestInterface = "org.freedesktop.portal.Request";
constexpr int kDialogTimeoutMs = 5 * 60 * 1000;
/// How long to wait for the portal to confirm a request we closed ourselves.
constexpr int kDismissGraceMs = 5000;

QString nextToken()
{
  static quint64 counter = 0;
  // Portal tokens must only contain [A-Za-z0-9_].
  return QStringLiteral("kogaview_%1_%2").arg(QCoreApplication::applicationPid()).arg(++counter);
}

/// D-Bus replies carry object paths as `QDBusObjectPath`; `QVariant::toString`
/// answers an empty string for that type, so a request handle must be read with
/// its own accessor or every portal call looks like it failed.
QString objectPathOf(const QVariant& value)
{
  if (value.metaType() == QMetaType::fromType<QDBusObjectPath>()) {
    return value.value<QDBusObjectPath>().path();
  }
  return value.toString();
}

/// `:1.42` -> `1_42`, the escaping the portal applies to a unique bus name when
/// it builds a request object path.
QString senderToken(const QString& busName)
{
  QString token = busName;
  if (token.startsWith(QLatin1Char(':'))) {
    token.remove(0, 1);
  }
  token.replace(QLatin1Char('.'), QLatin1Char('_'));
  return token;
}
} // namespace

PlatformHelper::PlatformHelper(QObject* parent)
  : QObject(parent)
{
  m_portalAvailable =
    QDBusConnection::sessionBus().interface() != nullptr &&
    QDBusConnection::sessionBus().interface()->isServiceRegistered(kPortalService);

  m_timeout = new QTimer(this);
  m_timeout->setSingleShot(true);
  m_timeout->setInterval(kDialogTimeoutMs);
  connect(m_timeout, &QTimer::timeout, this, [this]() {
    if (m_dismissing) {
      // The dialog was closed on purpose; a missing answer is not a failure,
      // but the request must not stay "active" forever.
      qInfo() << "KogaView portal: no answer after dismissal, request dropped";
      resetRequest();
      return;
    }
    finishWithError(tr("The file dialog did not receive an answer in time."));
  });

  qInfo() << "KogaView platform: XDG portal" << (m_portalAvailable ? "available" : "unavailable");
}

PlatformHelper::~PlatformHelper()
{
  // Quitting with a dialog open would leave a request (and a window) behind.
  dismissActiveDialog();
  resetRequest();
}

void PlatformHelper::dismissActiveDialog()
{
  if (!m_requestActive) {
    return;
  }
  closeOpenRequest();
  // The dialog is gone, so a late or missing answer must not be reported as a
  // failure. Keep listening for the portal's own `Response` (which carries
  // response 1) and re-arm the watchdog with a short grace period, so a portal
  // that never answers cannot leave the helper stuck "dialog open".
  m_dismissing = true;
  m_timeout->start(kDismissGraceMs);
}

QString PlatformHelper::parentWindowIdentifier()
{
  // Only X11 can be expressed as `x11:<window id>` without extra plumbing;
  // Wayland needs an xdg-foreign export, so those dialogs are non-modal.
  if (!QGuiApplication::platformName().startsWith(QLatin1String("xcb"))) {
    return QString();
  }
  const QWindow* window = QGuiApplication::focusWindow();
  if (window == nullptr && !QGuiApplication::topLevelWindows().isEmpty()) {
    window = QGuiApplication::topLevelWindows().constFirst();
  }
  if (window == nullptr || window->winId() == 0) {
    return QString();
  }
  return QStringLiteral("x11:%1").arg(static_cast<qulonglong>(window->winId()), 0, 16);
}

QString PlatformHelper::predictedRequestPath(const QString& token)
{
  const QString sender = senderToken(QDBusConnection::sessionBus().baseService());
  if (sender.isEmpty()) {
    return QString();
  }
  return QStringLiteral("%1/request/%2/%3").arg(QString::fromLatin1(kPortalPath), sender, token);
}

bool PlatformHelper::listenTo(const QString& handle)
{
  const bool connected = QDBusConnection::sessionBus().connect(
    QString::fromLatin1(kPortalService),
    handle,
    QString::fromLatin1(kRequestInterface),
    QStringLiteral("Response"),
    this,
    SLOT(onPortalResponse(uint, QVariantMap)));
  if (!connected) {
    return false;
  }
  m_requestPath = handle;
  m_connectionService = QString::fromLatin1(kPortalService);
  return true;
}

void PlatformHelper::stopListening()
{
  if (!m_requestPath.isEmpty()) {
    QDBusConnection::sessionBus().disconnect(
      m_connectionService,
      m_requestPath,
      QString::fromLatin1(kRequestInterface),
      QStringLiteral("Response"),
      this,
      SLOT(onPortalResponse(uint, QVariantMap)));
  }
}

void PlatformHelper::closeOpenRequest()
{
  if (!m_requestActive || m_requestPath.isEmpty()) {
    return;
  }
  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    m_requestPath,
    QString::fromLatin1(kRequestInterface),
    QStringLiteral("Close"));
  QDBusConnection::sessionBus().call(message, QDBus::NoBlock);
  qInfo() << "KogaView portal: closed" << m_requestPath;
}

uint PlatformHelper::fileChooserVersion() const
{
  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QStringLiteral("org.freedesktop.DBus.Properties"),
    QStringLiteral("Get"));
  message << QString::fromLatin1(kFileChooserInterface) << QStringLiteral("version");
  const QDBusMessage reply = QDBusConnection::sessionBus().call(message, QDBus::Block, 2000);
  if (reply.type() == QDBusMessage::ErrorMessage || reply.arguments().isEmpty()) {
    return 0;
  }
  // The property arrives as a QDBusVariant wrapping the uint version.
  const QVariant value = reply.arguments().first();
  if (value.canConvert<QDBusVariant>()) {
    return value.value<QDBusVariant>().variant().toUInt();
  }
  return value.toUInt();
}

bool PlatformHelper::requestOpenFile(const QString& title)
{
  QVariantMap options;
  options.insert(QStringLiteral("multiple"), true);
  m_folderMode = false;
  return request(QStringLiteral("OpenFile"), title, options);
}

bool PlatformHelper::requestOpenFolder(const QString& title)
{
  // The FileChooser interface has no `OpenFolder` method: a folder dialog is
  // `OpenFile` with `directory` set. Asking for the missing method made every
  // "Open folder" request fail and fall back to the Qt dialog.
  if (fileChooserVersion() < 3) {
    qWarning() << "KogaView portal: FileChooser version" << fileChooserVersion()
               << "cannot pick folders; using the Qt dialog";
    return false;
  }
  QVariantMap options;
  options.insert(QStringLiteral("multiple"), false);
  options.insert(QStringLiteral("directory"), true);
  m_folderMode = true;
  return request(QStringLiteral("OpenFile"), title, options);
}

bool PlatformHelper::request(const QString& method, const QString& title, const QVariantMap& options)
{
  if (!m_portalAvailable) {
    return false;
  }
  if (m_requestActive) {
    emit dialogError(tr("Another file dialog is already open."));
    return true;
  }

  const QString token = nextToken();
  QVariantMap portalOptions = options;
  portalOptions.insert(QStringLiteral("handle_token"), token);

  // Subscribe *before* the call: a portal is allowed to emit `Response` as soon
  // as it handles the request (a fast cancel, a policy denial, or a backend
  // that answers synchronously), and a subscription made after the reply would
  // miss it and hang until the dialog timeout.
  const QString predicted = predictedRequestPath(token);
  if (predicted.isEmpty() || !listenTo(predicted)) {
    qWarning() << "KogaView portal: cannot subscribe to the predicted request" << predicted;
    return false;
  }
  m_requestActive = true;

  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QString::fromLatin1(kFileChooserInterface),
    method);
  message << parentWindowIdentifier() << title << portalOptions;

  const QDBusMessage reply = QDBusConnection::sessionBus().call(message, QDBus::Block, 5000);
  if (reply.type() == QDBusMessage::ErrorMessage) {
    qWarning() << "KogaView portal:" << method << "failed:" << reply.errorMessage();
    // Do not emit dialogError: the caller falls back to the Qt dialog. There is
    // no request object to close either, so just drop the subscription.
    resetRequest();
    return false;
  }

  const QString requestPath = objectPathOf(reply.arguments().value(0));
  if (requestPath.isEmpty()) {
    qWarning() << "KogaView portal: empty request path for" << method;
    abandonRequest();
    return false;
  }
  if (requestPath != predicted) {
    // The portal chose its own path: move the subscription over to it.
    stopListening();
    if (!listenTo(requestPath)) {
      qWarning() << "KogaView portal: cannot subscribe to" << requestPath;
      abandonRequest();
      return false;
    }
  }

  m_timeout->start();
  qInfo() << "KogaView portal:" << method << "requested at" << m_requestPath
          << "parent" << (parentWindowIdentifier().isEmpty() ? QStringLiteral("<none>")
                                                            : parentWindowIdentifier());
  return true;
}

void PlatformHelper::onPortalResponse(uint response, const QVariantMap& results)
{
  if (!m_requestActive) {
    return;
  }

  const bool folderMode = m_folderMode;
  const bool dismissing = m_dismissing;
  qInfo() << "KogaView portal: response" << response << "on" << m_requestPath;
  m_dismissing = false;
  resetRequest();

  if (dismissing) {
    // We closed this request ourselves; the answer carries no selection.
    qInfo() << "KogaView portal: request dismissed, response" << response;
    return;
  }
  if (response == 1) {
    // The user cancelled: not an error.
    qInfo() << "KogaView portal: request cancelled";
    return;
  }
  if (response != 0) {
    emit dialogError(tr("The portal dialog failed (response %1).").arg(response));
    return;
  }

  QStringList uris = results.value(QStringLiteral("uris")).toStringList();
  if (uris.isEmpty()) {
    const QString single = results.value(QStringLiteral("uri")).toString();
    if (!single.isEmpty()) {
      uris.append(single);
    }
  }

  QStringList paths;
  for (const QString& uri : uris) {
    const QString path = QUrl(uri).toLocalFile();
    if (!path.isEmpty()) {
      paths.append(path);
    }
  }

  if (paths.isEmpty()) {
    emit dialogError(tr("The portal dialog returned no usable file path."));
    return;
  }

  if (folderMode) {
    emit folderSelected(paths.first());
  } else {
    emit filesSelected(paths);
  }
}

void PlatformHelper::resetRequest()
{
  m_timeout->stop();
  if (m_requestActive) {
    stopListening();
  }
  m_requestActive = false;
  m_dismissing = false;
  m_requestPath.clear();
  m_connectionService.clear();
}

/// Give up on a request: dismiss the portal dialog and stop listening, without
/// reporting an error (the caller falls back to the Qt dialog instead).
void PlatformHelper::abandonRequest()
{
  closeOpenRequest();
  resetRequest();
}

void PlatformHelper::finishWithError(const QString& message)
{
  // Dismiss the portal dialog first: leaving it open would let the user pick a
  // file for a request nobody is listening to any more.
  closeOpenRequest();
  resetRequest();
  emit dialogError(message);
}

void PlatformHelper::copyImage(const QString& path)
{
  const QString absolute = QFileInfo(path).absoluteFilePath();
  auto* watcher = new QFutureWatcher<QImage>(this);
  connect(watcher, &QFutureWatcher<QImage>::finished, this, [this, watcher, absolute]() {
    const QImage image = watcher->result();
    watcher->deleteLater();
    if (image.isNull()) {
      emit copyResult(false, tr("Could not decode %1.").arg(QFileInfo(absolute).fileName()));
      return;
    }
    QGuiApplication::clipboard()->setImage(image);
    emit copyResult(
      true,
      tr("Copied %1 × %2 image content to the clipboard.")
        .arg(image.width())
        .arg(image.height()));
    qInfo() << "KogaView clipboard: image copied" << image.size();
  });

  watcher->setFuture(QtConcurrent::run([absolute]() {
    QImageReader reader(absolute);
    reader.setAutoTransform(true);
    return reader.read();
  }));
}

void PlatformHelper::copyText(const QString& text)
{
  QGuiApplication::clipboard()->setText(text);
  emit info(tr("Copied to the clipboard."));
}

bool PlatformHelper::openUriWithPortal(const QUrl& url, bool directory)
{
  if (!m_portalAvailable || !url.isLocalFile()) {
    return false;
  }

  const QString token = nextToken();
  QVariantMap options;
  options.insert(QStringLiteral("handle_token"), token);
  // No `ask`: the user already chose "open with the system application". The
  // portal still applies the desktop's own policy for unknown handlers.

  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QString::fromLatin1(kOpenUriInterface),
    QStringLiteral("OpenURI"));
  message << parentWindowIdentifier() << url.toString() << options;

  const QDBusMessage reply = QDBusConnection::sessionBus().call(message, QDBus::Block, 5000);
  if (reply.type() == QDBusMessage::ErrorMessage) {
    qWarning() << "KogaView portal: OpenURI" << url.toString()
               << "failed:" << reply.errorMessage();
    return false;
  }
  const QString handle = objectPathOf(reply.arguments().value(0));
  qInfo() << "KogaView portal: OpenURI" << url.toString() << (directory ? "(directory)" : "")
          << "handle" << handle;
  return true;
}

void PlatformHelper::openExternally(const QString& path)
{
  const QUrl url = QUrl::fromLocalFile(path);
  // The portal is the only route that works inside a sandbox; QDesktopServices
  // is the fallback on desktops without one.
  if (openUriWithPortal(url, QFileInfo(path).isDir())) {
    return;
  }
  if (!QDesktopServices::openUrl(url)) {
    emit dialogError(tr("No application is registered to open this file."));
  }
}

void PlatformHelper::revealInFolder(const QString& path)
{
  const QFileInfo info(path);
  const QUrl url = QUrl::fromLocalFile(info.isDir() ? info.absoluteFilePath() : info.absolutePath());
  if (openUriWithPortal(url, true)) {
    return;
  }
  if (!QDesktopServices::openUrl(url)) {
    emit dialogError(tr("Cannot open the containing folder."));
  }
}
