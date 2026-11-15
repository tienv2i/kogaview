#include "thumbnailcache.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QSaveFile>
#include <QThreadPool>
#include <QUrl>

#include <algorithm>
#include <QtConcurrent/QtConcurrentRun>

namespace {
/// Name suffix of the marker that records an undecodable source.
constexpr auto kFailureSuffix = ".fail";
constexpr auto kJpegSuffix = ".jpg";
constexpr auto kPngSuffix = ".png";

/// 64-bit FNV-1a, hex encoded.
///
/// `std::hash`/`QHash` are salted per process and would change the key between
/// runs, which would make every cached file unreachable after a restart. This is
/// stable, has no dependency and is fast enough for one call per visible tile.
QString stableHash(const QByteArray& bytes)
{
  quint64 hash = 1469598103934665603ull;
  for (const char byte : bytes) {
    hash ^= static_cast<quint8>(byte);
    hash *= 1099511628211ull;
  }
  return QString::number(hash, 16).rightJustified(16, QLatin1Char('0'));
}
} // namespace

ThumbnailCache::ThumbnailCache(const QString& directory, QObject* parent)
  : QObject(parent)
  , m_directory(directory)
{
  QDir().mkpath(m_directory);
  scanExisting();
}

QString ThumbnailCache::keyFor(const QString& path, int edge, qint64 modified, qint64 size) const
{
  // `v3` pins the pipeline: changing how thumbnails are produced must make old
  // files unreachable instead of mixing two kinds of image in one cache.
  const QByteArray spec = QStringLiteral("v3|%1|%2|%3|%4")
                            .arg(path)
                            .arg(edge)
                            .arg(modified)
                            .arg(size)
                            .toUtf8();
  return stableHash(spec);
}

QString ThumbnailCache::cachedFile(const QString& key) const
{
  // The extension records whether the source had transparency, so both are
  // checked; the first hit wins and only one of them ever exists.
  for (const auto* suffix : {kJpegSuffix, kPngSuffix}) {
    const QString candidate = m_directory + QLatin1Char('/') + key + QLatin1String(suffix);
    if (QFileInfo::exists(candidate)) {
      return candidate;
    }
  }
  return QString();
}

void ThumbnailCache::touch(const QString& file)
{
  QFile handle(file);
  if (handle.open(QIODevice::ReadWrite)) {
    handle.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
  }
}

int ThumbnailCache::entryCount()
{
  QDir dir(m_directory);
  return dir.entryList(QStringList{QLatin1String("*.jpg"), QLatin1String("*.png")}, QDir::Files).size();
}

void ThumbnailCache::setBudgetBytes(qint64 bytes)
{
  m_budget = qMax<qint64>(0, bytes);
  evictIfNeeded();
}

void ThumbnailCache::request(const QString& path, int edge, qint64 modified, qint64 size)
{
  if (path.isEmpty() || edge <= 0) {
    return;
  }
  const QString key = keyFor(path, edge, modified, size);

  const QString file = cachedFile(key);
  if (!file.isEmpty()) {
    // Already generated. Touching it is what makes eviction least-recently-*
    // used*: without it a folder revisited every day would age like a one-off.
    touch(file);
    ++m_hits;
    // Answer on the next event loop turn, so a caller that is still binding its
    // source does not get the answer first.
    const QString url = QUrl::fromLocalFile(file).toString();
    QMetaObject::invokeMethod(
      this, [this, key, url]() { emit thumbnailReady(key, url); }, Qt::QueuedConnection);
    return;
  }
  const QString marker = m_directory + QLatin1Char('/') + key + QLatin1String(kFailureSuffix);
  if (QFileInfo::exists(marker)) {
    // Known bad (corrupt file or unsupported format): do not decode it again,
    // and do not let it be evicted while it is still being asked for.
    touch(marker);
    ++m_hits;
    QMetaObject::invokeMethod(
      this, [this, key]() { emit thumbnailFailed(key); }, Qt::QueuedConnection);
    return;
  }
  if (m_inflight.contains(key)) {
    return;
  }
  m_inflight.insert(key);
  generate(Job{key, path, edge});
}

void ThumbnailCache::generate(const Job& job)
{
  QtConcurrent::run(QThreadPool::globalInstance(), [this, job]() {
    QImageReader reader(job.path);
    // Honour the EXIF orientation, exactly like the un-cached `Image` did, or
    // phone photos come out sideways.
    reader.setAutoTransform(true);
    const QSize original = reader.size();
    if (!original.isValid()) {
      finish(job.key, QString(), reader.errorString());
      return;
    }
    if (original.width() > job.edge || original.height() > job.edge) {
      // Ask the decoder for a small image instead of decoding 12 MP and
      // scaling afterwards.
      reader.setScaledSize(original.scaled(job.edge, job.edge, Qt::KeepAspectRatio));
    }
    const QImage image = reader.read();
    if (image.isNull()) {
      finish(job.key, QString(), reader.errorString());
      return;
    }

    const bool keepAlpha = image.hasAlphaChannel();
    const QString target = m_directory + QLatin1Char('/') + job.key +
                           (keepAlpha ? QLatin1String(kPngSuffix) : QLatin1String(kJpegSuffix));
    QSaveFile file(target);
    if (!file.open(QIODevice::WriteOnly)) {
      finish(job.key, QString(), file.errorString());
      return;
    }
    // Atomic rename on commit, so a half-written file can never be picked up by
    // the next lookup.
    const bool written = keepAlpha ? image.save(&file, "PNG") : image.save(&file, "JPG", 85);
    if (!written || !file.commit()) {
      finish(job.key, QString(), QStringLiteral("cannot encode thumbnail"));
      return;
    }
    finish(job.key, target, QString());
  });
}

void ThumbnailCache::finish(const QString& key, const QString& file, const QString& error)
{
  // Called from a worker thread: hop to the owning thread before touching any
  // field or emitting, so the cache needs no locking.
  QMetaObject::invokeMethod(
    this,
    [this, key, file, error]() {
      m_inflight.remove(key);
      if (!error.isEmpty()) {
        qWarning() << "KogaView thumbnails: cannot decode" << key << error;
        QSaveFile marker(m_directory + QLatin1Char('/') + key + QLatin1String(kFailureSuffix));
        if (marker.open(QIODevice::WriteOnly)) {
          marker.commit();
        }
        emit thumbnailFailed(key);
        return;
      }
      ++m_generated;
      remember(QFileInfo(file).size());
      emit thumbnailReady(key, QUrl::fromLocalFile(file).toString());
    },
    Qt::QueuedConnection);
}

void ThumbnailCache::remember(qint64 bytes)
{
  m_bytes += bytes;
  evictIfNeeded();
}

void ThumbnailCache::evictIfNeeded()
{
  if (m_bytes <= m_budget) {
    return;
  }
  QDir dir(m_directory);
  QList<QFileInfo> entries = dir.entryInfoList(
    QStringList{QLatin1String("*.jpg"), QLatin1String("*.png"), QLatin1String("*.fail")},
    QDir::Files);
  // Least recently used first: `touch` keeps the modification time equal to the
  // last use, and the order is spelled out here instead of relying on how
  // `QDir::Time` happens to sort.
  std::sort(entries.begin(), entries.end(), [](const QFileInfo& left, const QFileInfo& right) {
    return left.lastModified() < right.lastModified();
  });
  // Aim well below the budget so eviction does not run after every insert.
  const qint64 target = m_budget * 9 / 10;
  for (const QFileInfo& entry : entries) {
    if (m_bytes <= target) {
      break;
    }
    const qint64 size = entry.size();
    if (!QFile::remove(entry.absoluteFilePath())) {
      continue;
    }
    m_bytes -= (entry.suffix() == QLatin1String("fail")) ? 0 : size;
  }
  if (m_bytes < 0) {
    m_bytes = 0;
  }
}

void ThumbnailCache::scanExisting()
{
  QDir dir(m_directory);
  m_bytes = 0;
  const auto entries =
    dir.entryInfoList(QStringList{QLatin1String("*.jpg"), QLatin1String("*.png")}, QDir::Files);
  for (const QFileInfo& entry : entries) {
    m_bytes += entry.size();
  }
  evictIfNeeded();
}

void ThumbnailCache::clear()
{
  QDir dir(m_directory);
  const auto entries = dir.entryInfoList(
    QStringList{QLatin1String("*.jpg"), QLatin1String("*.png"), QLatin1String("*.fail")},
    QDir::Files);
  for (const QFileInfo& entry : entries) {
    QFile::remove(entry.absoluteFilePath());
  }
  m_bytes = 0;
}
