#include "platform.h"
#include "translations.h"

#include <QBuffer>
#include <QClipboard>
#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusUnixFileDescriptor>
#include <QDBusVariant>
#include <QDebug>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFontMetricsF>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QPalette>
#include <QProcess>
#include <QStandardPaths>
#include <QStyleHints>
#include <QTimer>
#include <QUrl>
#include <QWindow>
#include <QtConcurrent/QtConcurrentRun>

#include <cstddef>
#include <cstdint>
#include <fcntl.h>
#include <unistd.h>

extern "C" {
__attribute__((weak)) bool kogaview_extract_archive_preview(const char* path, uint8_t** out_ptr, size_t* out_len);
__attribute__((weak)) void kogaview_free_buffer(uint8_t* ptr, size_t len);
}

namespace {
constexpr auto kPortalService = "org.freedesktop.portal.Desktop";
constexpr auto kPortalPath = "/org/freedesktop/portal/desktop";
constexpr auto kFileChooserInterface = "org.freedesktop.portal.FileChooser";
constexpr auto kOpenUriInterface = "org.freedesktop.portal.OpenURI";
constexpr auto kScreenshotInterface = "org.freedesktop.portal.Screenshot";
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

/// The save chooser's formats: a label and the globs it accepts.
///
/// One table feeds both the Qt fallback's `"Name (*.png)"` strings and the
/// portal's structured `a(ssa(ss))` filters, so the two dialogs can never offer
/// different formats. Spelled out for the same reason `imageNameFilter` is: no
/// extension list should travel through CXX-Qt, and the packaging check reads
/// these names.
struct SaveFilter
{
  const char* name;
  const char* patterns;
};

constexpr SaveFilter kSaveFilters[] = {{"PNG image", "*.png"},
                                       {"JPEG image", "*.jpg *.jpeg"},
                                       {"WebP image", "*.webp"},
                                       {"OpenRaster image", "*.ora"},
                                       {"TIFF image", "*.tiff"},
                                       {"GIF image", "*.gif"},
                                       {"BMP image", "*.bmp"},
                                       {"TGA image", "*.tga"},
                                       {"QOI image", "*.qoi"}};

/// The globs of one filter, split.
QStringList filterPatterns(const SaveFilter& filter)
{
  return QString::fromLatin1(filter.patterns).split(QLatin1Char(' '), Qt::SkipEmptyParts);
}

/// One portal filter pattern: `(u type, s pattern)`. Type 0 is the only kind
/// the file chooser accepts — a glob — so every pattern carries it. The type
/// comes first: `SaveFile` reads `a(sa(us))` and rejects the pair the other way
/// round.
struct PortalPattern
{
  uint type = 0;
  QString glob;
};

/// One portal filter: `(s name, a(us) patterns)`.
struct PortalFilter
{
  QString name;
  QList<PortalPattern> patterns;
};
} // namespace

Q_DECLARE_METATYPE(PortalPattern)
Q_DECLARE_METATYPE(QList<PortalPattern>)
Q_DECLARE_METATYPE(PortalFilter)
Q_DECLARE_METATYPE(QList<PortalFilter>)

QDBusArgument& operator<<(QDBusArgument& argument, const PortalPattern& pattern)
{
  argument.beginStructure();
  argument << pattern.type << pattern.glob;
  argument.endStructure();
  return argument;
}

const QDBusArgument& operator>>(const QDBusArgument& argument, PortalPattern& pattern)
{
  argument.beginStructure();
  argument >> pattern.type >> pattern.glob;
  argument.endStructure();
  return argument;
}

QDBusArgument& operator<<(QDBusArgument& argument, const PortalFilter& filter)
{
  argument.beginStructure();
  argument << filter.name << filter.patterns;
  argument.endStructure();
  return argument;
}

const QDBusArgument& operator>>(const QDBusArgument& argument, PortalFilter& filter)
{
  argument.beginStructure();
  argument >> filter.name >> filter.patterns;
  argument.endStructure();
  return argument;
}

namespace {
/// Register the filter structures with QDBus once, before the first request.
void registerPortalFilters()
{
  static const bool registered = [] {
    qDBusRegisterMetaType<PortalPattern>();
    qDBusRegisterMetaType<QList<PortalPattern>>();
    qDBusRegisterMetaType<PortalFilter>();
    qDBusRegisterMetaType<QList<PortalFilter>>();
    return true;
  }();
  (void)registered;
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

uint PlatformHelper::portalInterfaceVersion(const QString& interface) const
{
  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QStringLiteral("org.freedesktop.DBus.Properties"),
    QStringLiteral("Get"));
  message << interface << QStringLiteral("version");
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

uint PlatformHelper::fileChooserVersion() const
{
  return portalInterfaceVersion(QString::fromLatin1(kFileChooserInterface));
}

bool PlatformHelper::requestOpenFile(const QString& title)
{
  QVariantMap options;
  options.insert(QStringLiteral("multiple"), true);
  m_folderMode = false;
  m_saveMode = false;
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
  m_saveMode = false;
  return request(QStringLiteral("OpenFile"), title, options);
}

bool PlatformHelper::requestSaveFile(const QString& title, const QString& currentName)
{
  registerPortalFilters();

  const QString locale = interfaceLocale();
  QList<PortalFilter> filters;
  for (const SaveFilter& filter : kSaveFilters) {
    PortalFilter entry;
    entry.name = kogaview::i18n::translate(locale, filter.name);
    for (const QString& glob : filterPatterns(filter)) {
      entry.patterns.append(PortalPattern{0, glob});
    }
    filters.append(entry);
  }

  QVariantMap options;
  // `SaveFile` has no `multiple`: one name, one file.
  options.insert(QStringLiteral("filters"), QVariant::fromValue(filters));
  if (!currentName.isEmpty()) {
    const QFileInfo info(currentName);
    options.insert(QStringLiteral("current_name"), info.fileName());
    // `current_folder` is a byte array (the path is a plain path, NUL
    // terminated), not a string: the portal reads it as `ay`.
    const QString folder = info.absolutePath();
    if (!folder.isEmpty()) {
      QByteArray bytes = folder.toUtf8();
      bytes.append('\0');
      options.insert(QStringLiteral("current_folder"), bytes);
    }
  }
  m_folderMode = false;
  m_saveMode = true;
  m_colorMode = false;
  const bool started = request(QStringLiteral("SaveFile"), title, options);
  if (!started) {
    m_saveMode = false;
  }
  return started;
}

bool PlatformHelper::requestPickColor()
{
  if (!m_portalAvailable) {
    return false;
  }
  if (m_requestActive) {
    emit dialogError(tr("Another file dialog is already open."));
    return true;
  }

  const QString token = nextToken();
  QVariantMap portalOptions;
  portalOptions.insert(QStringLiteral("handle_token"), token);

  const QString predicted = predictedRequestPath(token);
  if (predicted.isEmpty() || !listenTo(predicted)) {
    qWarning() << "KogaView portal: cannot subscribe to predicted PickColor request" << predicted;
    return false;
  }
  m_requestActive = true;
  m_folderMode = false;
  m_saveMode = false;
  m_colorMode = true;

  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QString::fromLatin1(kScreenshotInterface),
    QStringLiteral("PickColor"));
  message << parentWindowIdentifier() << portalOptions;

  const QDBusMessage reply = QDBusConnection::sessionBus().call(message, QDBus::Block, 5000);
  if (reply.type() == QDBusMessage::ErrorMessage) {
    qWarning() << "KogaView portal: PickColor failed:" << reply.errorMessage();
    resetRequest();
    return false;
  }

  const QString requestPath = objectPathOf(reply.arguments().value(0));
  if (requestPath.isEmpty()) {
    qWarning() << "KogaView portal: empty request path for PickColor";
    abandonRequest();
    return false;
  }
  if (requestPath != predicted) {
    stopListening();
    if (!listenTo(requestPath)) {
      qWarning() << "KogaView portal: cannot subscribe to" << requestPath;
      abandonRequest();
      return false;
    }
  }

  m_timeout->start();
  qInfo() << "KogaView portal: PickColor requested at" << m_requestPath;
  return true;
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
  const bool saveMode = m_saveMode;
  const bool colorMode = m_colorMode;
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

  if (colorMode) {
    const QVariant colorVar = results.value(QStringLiteral("color"));
    if (colorVar.canConvert<QDBusArgument>()) {
      double r = 0.0;
      double g = 0.0;
      double b = 0.0;
      const QDBusArgument arg = colorVar.value<QDBusArgument>();
      arg.beginStructure();
      arg >> r >> g >> b;
      arg.endStructure();
      const int ri = qBound(0, qRound(r * 255.0), 255);
      const int gi = qBound(0, qRound(g * 255.0), 255);
      const int bi = qBound(0, qRound(b * 255.0), 255);
      const QString hex = QStringLiteral("#%1%2%3")
        .arg(ri, 2, 16, QLatin1Char('0'))
        .arg(gi, 2, 16, QLatin1Char('0'))
        .arg(bi, 2, 16, QLatin1Char('0'));
      emit colorPicked(hex);
      return;
    }
    emit dialogError(tr("The portal color picker returned no usable color."));
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

  if (saveMode) {
    // A save answer is one path: the file the user named, whether or not it
    // exists yet. The overwrite question is the desktop dialog's own.
    emit saveFileSelected(paths.first());
  } else if (folderMode) {
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
  m_folderMode = false;
  m_saveMode = false;
  m_colorMode = false;
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

QSize PlatformHelper::clipboardImageSize() const
{
  const QImage image = QGuiApplication::clipboard()->image();
  return image.isNull() ? QSize() : image.size();
}

QString PlatformHelper::saveClipboardImageToTemp() const
{
  const QImage image = QGuiApplication::clipboard()->image();
  if (image.isNull()) {
    return QString();
  }
  static quint64 counter = 0;
  const QString tempDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
  QDir().mkpath(tempDir);
  const QString path = tempDir + QStringLiteral("/kogaview-clipboard-%1-%2.png")
                                   .arg(QCoreApplication::applicationPid())
                                   .arg(++counter);
  if (!image.save(path, "PNG")) {
    return QString();
  }
  return path;
}

extern "C" {
__attribute__((weak)) bool kogaview_sample_editor_canvas(double norm_x, double norm_y,
                                                         uint8_t* out_r, uint8_t* out_g,
                                                         uint8_t* out_b);
}

QString PlatformHelper::sampleImageColor(const QString& path, double normX, double normY) const
{
  if (path.isEmpty()) {
    return QString();
  }
  if (path == QStringLiteral("ram://canvas") && kogaview_sample_editor_canvas != nullptr) {
    uint8_t r = 0, g = 0, b = 0;
    if (kogaview_sample_editor_canvas(normX, normY, &r, &g, &b)) {
      return QColor(r, g, b).name(QColor::HexRgb);
    }
    return QString();
  }
  const QFileInfo info(path);
  if (!info.isFile()) {
    return QString();
  }
  static QString cachedPath;
  static qint64 cachedMsec = -1;
  static qint64 cachedSize = -1;
  static QImage cachedImage;

  const qint64 msec = info.lastModified().toMSecsSinceEpoch();
  const qint64 sz = info.size();
  if (cachedPath != path || cachedMsec != msec || cachedSize != sz || cachedImage.isNull()) {
    QImage loaded(path);
    if (loaded.isNull()) {
      return QString();
    }
    cachedPath = path;
    cachedMsec = msec;
    cachedSize = sz;
    cachedImage = loaded.convertToFormat(QImage::Format_RGBA8888);
  }
  if (cachedImage.width() <= 0 || cachedImage.height() <= 0) {
    return QString();
  }
  const int px = qBound(0, static_cast<int>(qRound(normX * (cachedImage.width() - 1))),
                        cachedImage.width() - 1);
  const int py = qBound(0, static_cast<int>(qRound(normY * (cachedImage.height() - 1))),
                        cachedImage.height() - 1);
  const QColor c = cachedImage.pixelColor(px, py);
  return c.name(QColor::HexRgb);
}

QVariantList PlatformHelper::textWidths(const QStringList& labels, const QFont& font)
{
  const QFontMetricsF metrics(font);
  QVariantList widths;
  widths.reserve(labels.size());
  for (const QString& label : labels) {
    // The exact advance, not a rounded one: the caller adds its own padding and
    // rounds once, so the width cannot be a pixel short of the text.
    widths.append(metrics.horizontalAdvance(label));
  }
  return widths;
}

QSize PlatformHelper::imageSize(const QString& path) const
{
  // `size()` reads the header, not the pixels: a 60 MP JPEG costs one small
  // read here. `autoTransform` asks for the EXIF orientation so a photo shot
  // in portrait reports the shape it is actually displayed in.
  if (path.isEmpty()) {
    return {};
  }
  if (path.endsWith(QLatin1String(".ora"), Qt::CaseInsensitive)
      || path.endsWith(QLatin1String(".kra"), Qt::CaseInsensitive)) {
    if (kogaview_extract_archive_preview == nullptr || kogaview_free_buffer == nullptr) {
      return {};
    }
    uint8_t* raw = nullptr;
    size_t len = 0;
    const QByteArray utf8 = path.toUtf8();
    if (!kogaview_extract_archive_preview(utf8.constData(), &raw, &len) || raw == nullptr || len == 0) {
      return {};
    }
    QByteArray data(reinterpret_cast<const char*>(raw), static_cast<qsizetype>(len));
    kogaview_free_buffer(raw, len);
    QBuffer buffer(&data);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    const QSize size = reader.size();
    return size.isValid() && !size.isEmpty() ? size : QSize();
  }
  QImageReader reader(path);
  reader.setAutoTransform(true);
  const QSize size = reader.size();
  if (!size.isValid() || size.isEmpty()) {
    return {};
  }
  return size;
}

QString PlatformHelper::imageNameFilter() const
{
  // Spelled out so no extension travels through CXX-Qt, but the browser and
  // this chooser must agree: `scripts/check_packaging.py` reads both lists and
  // fails when they differ, which is how `.jpe` was missing here while the
  // Browser already listed it.
  static const char* const extensions[] = {
    "jpg", "jpeg", "jpe", "jfif", "png", "webp", "gif", "bmp", "tif", "tiff", "avif",
    "heic", "heif", "dds", "exr", "hdr", "ico", "pnm", "pbm", "pgm", "ppm",
    "qoi", "tga", "ff", "ora", "kra", nullptr,
  };
  QStringList patterns;
  for (const char* const* extension = extensions; *extension != nullptr; ++extension) {
    patterns << QStringLiteral("*.") + QString::fromLatin1(*extension);
  }
  return kogaview::i18n::translate(interfaceLocale(), "Images") + QStringLiteral(" (")
    + patterns.join(QLatin1Char(' ')) + QLatin1Char(')');
}

QStringList PlatformHelper::saveNameFilters() const
{
  const QString locale = interfaceLocale();
  QStringList filters;
  for (const SaveFilter& filter : kSaveFilters) {
    filters << kogaview::i18n::translate(locale, filter.name) + QStringLiteral(" (")
                 + filterPatterns(filter).join(QLatin1Char(' ')) + QLatin1Char(')');
  }
  return filters;
}

QString PlatformHelper::interfaceLocale() const
{
  // `KOGAVIEW_UI_LANG` is the harness override, exactly as `main.cpp` reads it;
  // otherwise the translator that is installed names the locale.
  const QString override = qEnvironmentVariable("KOGAVIEW_UI_LANG");
  if (!override.isEmpty()) {
    return override == QLatin1String("system") ? QString() : override;
  }
  for (QObject* child : QCoreApplication::instance()->children()) {
    if (child->property("kogaviewLocale").isValid()) {
      return child->property("kogaviewLocale").toString();
    }
  }
  return QString();
}

QVariantList PlatformHelper::languages() const
{
  QVariantList out;
  auto add = [&out](const QString& code, const QString& english, const QString& vietnamese) {
    QVariantMap entry;
    entry.insert(QStringLiteral("code"), code);
    entry.insert(QStringLiteral("english"), english);
    entry.insert(QStringLiteral("vietnamese"), vietnamese);
    out.append(entry);
  };
  add(QStringLiteral("system"), QStringLiteral("System language"), QStringLiteral("Theo hệ thống"));
  add(QStringLiteral("en"), QStringLiteral("English"), QStringLiteral("Tiếng Anh"));
  add(QStringLiteral("vi"), QStringLiteral("Vietnamese"), QStringLiteral("Tiếng Việt"));
  return out;
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

bool PlatformHelper::openFileWithChooser(const QUrl& url)
{
  if (!m_portalAvailable || !url.isLocalFile()) {
    return false;
  }
  // `ask` is the portal's own "which application?" switch. It only exists from
  // OpenURI version 2; older front ends ignore unknown options, which would open
  // the default handler and look like a chooser that never appeared.
  if (portalInterfaceVersion(QString::fromLatin1(kOpenUriInterface)) < 2) {
    qWarning() << "KogaView portal: OpenURI has no `ask`; cannot show the application chooser";
    return false;
  }

  const QString token = nextToken();
  QVariantMap options;
  options.insert(QStringLiteral("handle_token"), token);
  options.insert(QStringLiteral("ask"), true);
  // The method is OpenFile, not OpenURI: only the `OpenFile`/`OpenDirectory`
  // pair carries `ask`, so asking through OpenURI would simply open the file.
  // `OpenFile` takes an open file descriptor (`h`), not a URI. A local run can
  // hand over the file itself; Flatpak's document portal will lend its own fd for
  // `app/<id>/<file>` paths, which this does not do yet (see docs/FLATPAK.md).
  const QFileInfo info(url.toLocalFile());
  if (!info.isFile() || !info.isReadable()) {
    qWarning() << "KogaView portal: cannot hand" << url.toString()
               << "to OpenFile; falling back";
    return false;
  }
  const int fileDescriptor = ::open(QFile::encodeName(info.absoluteFilePath()).constData(), O_RDONLY);
  if (fileDescriptor < 0) {
    qWarning() << "KogaView portal: cannot open" << info.absoluteFilePath() << "for OpenFile";
    return false;
  }
  QDBusMessage message = QDBusMessage::createMethodCall(
    QString::fromLatin1(kPortalService),
    QString::fromLatin1(kPortalPath),
    QString::fromLatin1(kOpenUriInterface),
    QStringLiteral("OpenFile"));
  // `fileDescriptor` is written as a `QDBusUnixFileDescriptor` handle; the fd
  // itself stays ours to close once the call returns.
  message << parentWindowIdentifier()
          << QVariant::fromValue(QDBusUnixFileDescriptor(fileDescriptor)) << options;

  const QDBusMessage reply = QDBusConnection::sessionBus().call(message, QDBus::Block, 5000);
  ::close(fileDescriptor);
  if (reply.type() == QDBusMessage::ErrorMessage) {
    qWarning() << "KogaView portal: OpenFile" << url.toString()
               << "failed:" << reply.errorMessage();
    return false;
  }
  const QString handle = objectPathOf(reply.arguments().value(0));
  qInfo() << "KogaView portal: OpenFile (ask)" << url.toString() << "handle" << handle;
  // No `Response` wait: the portal answers once the user picked an application
  // (or cancelled), and the chooser itself is the whole point of the request.
  return true;
}

bool PlatformHelper::openWithSystemChooser(const QString& path)
{
#ifdef Q_OS_WIN
  // Explorer's own "Open with" dialog; it waits for the user to dismiss it, so
  // it runs detached instead of blocking the GUI thread.
  const QString native = QDir::toNativeSeparators(QFileInfo(path).absoluteFilePath());
  const bool started = QProcess::startDetached(QStringLiteral("rundll32.exe"),
                                               { QStringLiteral("shell32.dll,OpenAs_RunDLL"),
                                                 native });
  qInfo() << "KogaView open with: rundll32 OpenAs_RunDLL" << native
          << (started ? "started" : "failed");
  return started;
#else
  // Outside a portal there is no portable chooser. `gio open` is deliberately
  // not tried: upstream `gio` has no "choose an application" option (checked on
  // this machine: `gio: Unknown option --ask`), so it would only ever open the
  // default handler and look like a chooser that never appeared.
  Q_UNUSED(path);
  return false;
#endif
}

void PlatformHelper::openWith(const QString& path)
{
  const QUrl url = QUrl::fromLocalFile(path);
  if (openFileWithChooser(url)) {
    return;
  }
  // No desktop chooser was available. Opening the file with its default handler
  // still does something useful, which is better than a menu entry that only
  // reports an error.
  openWithSystemChooser(path);
  qWarning() << "KogaView open with: no chooser for" << path << "- opening the default handler";
  if (QFileInfo(path).isDir()) {
    openExternally(path);
    return;
  }
  if (!QDesktopServices::openUrl(url)) {
    emit dialogError(tr("No application is registered to open this file."));
  }
}

void PlatformHelper::revealInFolder(const QString& path)
{
  const QFileInfo info(path);
  // A path that is gone has nothing to select: the folder that held it is the
  // most useful destination left. A path whose folder is gone too is the one
  // case where "show in folder" cannot do anything, so it says so instead of
  // handing the desktop a URI that opens onto nothing.
  const QString target = info.absoluteFilePath();
  const QFileInfo folderInfo = info.isDir() ? info : QFileInfo(info.absolutePath());
  if (target.isEmpty() || (!info.exists() && !folderInfo.exists())) {
    qWarning() << "KogaView reveal: nothing to reveal for" << path;
    emit dialogError(tr("That file is no longer there."));
    return;
  }
  const QUrl url = QUrl::fromLocalFile(target);

  // The desktop's own "show in folder" is a *selection*, not a new window: a
  // file manager that implements org.freedesktop.FileManager1 selects the file
  // in the window it is already showing. The call must not be gated on
  // `isServiceRegistered`: that only answers "is it running right now", so a
  // desktop that had not started its file manager yet (KDE, where Dolphin is
  // D-Bus-activatable, is the common case) made the request look unavailable
  // and fell through to a plain folder open. `call` activates the service by
  // itself and reports a refusal if there is nothing to activate, which is the
  // answer this needs. A sandbox cannot reach the host's service directly, so
  // the direct call is skipped there and the portal is the only path there.
  const bool sandboxed = QFileInfo::exists(QStringLiteral("/.flatpak-info"));
  if (!sandboxed) {
    const QString service = QStringLiteral("org.freedesktop.FileManager1");
    QDBusConnection bus = QDBusConnection::sessionBus();
    const QStringList uris{url.toString()};
    const QString method = info.isDir() ? QStringLiteral("ShowFolders")
                                        : QStringLiteral("ShowItems");
    QDBusMessage message = QDBusMessage::createMethodCall(
        service, QStringLiteral("/org/freedesktop/FileManager1"), service, method);
    message << uris << QString();
    const QDBusMessage reply = bus.call(message, QDBus::Block, 5000);
    if (reply.type() == QDBusMessage::ReplyMessage) {
      qInfo() << "KogaView reveal:" << method << target << "via org.freedesktop.FileManager1";
      return;
    }
    qWarning() << "KogaView reveal: FileManager1 unavailable for" << path << "-"
               << reply.errorMessage();
  } else {
    qInfo() << "KogaView reveal: sandboxed, skipping org.freedesktop.FileManager1";
  }

  // The portal opens the containing folder, not a selection: it is the best a
  // sandbox can ask for, and the second choice outside one.
  const QUrl folder = QUrl::fromLocalFile(folderInfo.absoluteFilePath());
  if (openUriWithPortal(folder, true)) {
    qInfo() << "KogaView reveal: opened" << folder.toString() << "via the portal";
    return;
  }
  if (QDesktopServices::openUrl(folder)) {
    qInfo() << "KogaView reveal: opened" << folder.toString() << "with the default handler";
    return;
  }
  emit dialogError(tr("Cannot open the containing folder."));
}

void PlatformHelper::applyThemePalette(const QVariantMap& colors, bool dark)
{
  const auto pick = [&colors](const char* key, const QColor& fallback) {
    const QColor value = colors.value(QString::fromLatin1(key)).value<QColor>();
    return value.isValid() ? value : fallback;
  };

  const QColor background = pick("background", dark ? QColor("#101216") : QColor("#f3f4f6"));
  const QColor surface = pick("surface", dark ? QColor("#181b21") : QColor("#ffffff"));
  const QColor surfaceAlt = pick("surfaceAlt", dark ? QColor("#21252d") : QColor("#eceef2"));
  const QColor text = pick("text", dark ? QColor("#e8eaed") : QColor("#1c1f24"));
  const QColor textMuted = pick("textMuted", dark ? QColor("#9aa1ac") : QColor("#5b6370"));
  const QColor accent = pick("accent", dark ? QColor("#4a9eff") : QColor("#0a66c2"));
  const QColor accentText = pick("accentText", dark ? QColor("#0b1a2b") : QColor("#ffffff"));
  const QColor border = pick("border", dark ? QColor("#2b3039") : QColor("#d7dbe2"));

  QPalette palette;
  const auto setGroup = [&](QPalette::ColorGroup group) {
    palette.setColor(group, QPalette::Window, background);
    palette.setColor(group, QPalette::WindowText, text);
    palette.setColor(group, QPalette::Base, surface);
    palette.setColor(group, QPalette::AlternateBase, surfaceAlt);
    palette.setColor(group, QPalette::Text, text);
    palette.setColor(group, QPalette::Button, surface);
    palette.setColor(group, QPalette::ButtonText, text);
    palette.setColor(group, QPalette::BrightText, QColor("#ffffff"));
    palette.setColor(group, QPalette::Highlight, accent);
    palette.setColor(group, QPalette::HighlightedText, accentText);
    palette.setColor(group, QPalette::ToolTipBase, surfaceAlt);
    palette.setColor(group, QPalette::ToolTipText, text);
    palette.setColor(group, QPalette::PlaceholderText, textMuted);
    palette.setColor(group, QPalette::Mid, border);
    palette.setColor(group, QPalette::Dark, border);
    palette.setColor(group, QPalette::Light, surfaceAlt);
    palette.setColor(group, QPalette::Shadow, border);
  };
  setGroup(QPalette::Active);
  setGroup(QPalette::Inactive);
  setGroup(QPalette::Disabled);

  QColor disabledText = textMuted;
  disabledText.setAlphaF(0.6);
  palette.setColor(QPalette::Disabled, QPalette::WindowText, disabledText);
  palette.setColor(QPalette::Disabled, QPalette::Text, disabledText);
  palette.setColor(QPalette::Disabled, QPalette::ButtonText, disabledText);

  QGuiApplication::setPalette(palette);
  if (QStyleHints* hints = QGuiApplication::styleHints()) {
    hints->setColorScheme(dark ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);
  }
}
