#include "platform.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDebug>
#include <QDesktopServices>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QTimer>
#include <QUrl>
#include <QtConcurrent/QtConcurrentRun>

namespace {
constexpr auto kPortalService = "org.freedesktop.portal.Desktop";
constexpr auto kPortalPath = "/org/freedesktop/portal/desktop";
constexpr auto kFileChooserInterface = "org.freedesktop.portal.FileChooser";
constexpr auto kRequestInterface = "org.freedesktop.portal.Request";
constexpr int kDialogTimeoutMs = 5 * 60 * 1000;

QString nextToken()
{
  static quint64 counter = 0;
  // Portal tokens must only contain [A-Za-z0-9_].
  return QStringLiteral("kogaview_%1_%2").arg(QCoreApplication::applicationPid()).arg(++counter);
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
    finishWithError(tr("The file dialog did not receive an answer in time."));
  });

  qInfo() << "KogaView platform: XDG portal" << (m_portalAvailable ? "available" : "unavailable");
}

PlatformHelper::~PlatformHelper()
{
  resetRequest();
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
  QVariantMap options;
  options.insert(QStringLiteral("multiple"), false);
  m_folderMode = true;
  return request(QStringLiteral("OpenFolder"), title, options);
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

  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QString::fromLatin1(kFileChooserInterface),
    method);
  // An empty parent identifier is legal; the dialog is then simply not modal.
  message << QString() << title << portalOptions;

  const QDBusMessage reply = QDBusConnection::sessionBus().call(message, QDBus::Block, 5000);
  if (reply.type() == QDBusMessage::ErrorMessage) {
    qWarning() << "KogaView portal:" << method << "failed:" << reply.errorMessage();
    // Do not emit dialogError: the caller falls back to the Qt dialog.
    return false;
  }

  const QString requestPath = reply.arguments().value(0).toString();
  if (requestPath.isEmpty()) {
    qWarning() << "KogaView portal: empty request path for" << method;
    return false;
  }

  const bool connected = QDBusConnection::sessionBus().connect(
    QString::fromLatin1(kPortalService),
    requestPath,
    QString::fromLatin1(kRequestInterface),
    QStringLiteral("Response"),
    this,
    SLOT(onPortalResponse(uint, QVariantMap)));
  if (!connected) {
    qWarning() << "KogaView portal: cannot subscribe to" << requestPath;
    return false;
  }

  m_requestPath = requestPath;
  m_connectionService = QString::fromLatin1(kPortalService);
  m_requestActive = true;
  m_timeout->start();

  qInfo() << "KogaView portal:" << method << "requested at" << requestPath;
  return true;
}

void PlatformHelper::onPortalResponse(uint response, const QVariantMap& results)
{
  if (!m_requestActive) {
    return;
  }

  const bool folderMode = m_folderMode;
  resetRequest();

  if (response == 1) {
    // User cancelled: not an error.
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
  if (m_requestActive && !m_requestPath.isEmpty()) {
    QDBusConnection::sessionBus().disconnect(
      m_connectionService,
      m_requestPath,
      QString::fromLatin1(kRequestInterface),
      QStringLiteral("Response"),
      this,
      SLOT(onPortalResponse(uint, QVariantMap)));
  }
  m_requestActive = false;
  m_requestPath.clear();
  m_connectionService.clear();
}

void PlatformHelper::finishWithError(const QString& message)
{
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

void PlatformHelper::openExternally(const QString& path)
{
  const QUrl url = QUrl::fromLocalFile(path);
  if (!QDesktopServices::openUrl(url)) {
    emit dialogError(tr("No application is registered to open this file."));
  }
}

void PlatformHelper::revealInFolder(const QString& path)
{
  const QFileInfo info(path);
  const QUrl url = QUrl::fromLocalFile(info.isDir() ? info.absoluteFilePath() : info.absolutePath());
  if (!QDesktopServices::openUrl(url)) {
    emit dialogError(tr("Cannot open the containing folder."));
  }
}
