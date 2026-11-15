#include "thumbnailcache.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QSaveFile>
#include <QUrl>

#include <algorithm>
#include <climits>

namespace {
/// Name suffix of the marker that records an undecodable source.
constexpr auto kFailureSuffix = ".fail";
constexpr auto kJpegSuffix = ".jpg";
constexpr auto kPngSuffix = ".png";

/// How many thumbnails are decoded at once.
///
/// Decoding a photo is CPU work that competes with the thread that draws the
/// window. A pool sized for the whole machine made the grid *faster* to fill and
/// the application much worse to use: with every core busy, the GUI thread waited
/// for a slice and the window stuttered while scrolling. Half the cores (capped)
/// keeps a burst of decoding invisible to the UI, which is what matters.
int decodeWorkerCount()
{
  return qBound(1, QThread::idealThreadCount() / 2, 3);
}

/// 64-bit FNV-1a, hex encoded.
///
/// `std::hash`/`QHash` are salted per process and would change the key between
/// runs, which would make every cached file unreachable after a restart. This is
/// stable, has no dependency and is fast enough for one call per tile.
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
  , m_usedClock(QDateTime::currentMSecsSinceEpoch())
{
  QDir().mkpath(m_directory);
  scanExisting();

  const int workers = decodeWorkerCount();
  m_workers.reserve(workers);
  for (int index = 0; index < workers; ++index) {
    QThread* worker = QThread::create([this]() { workerLoop(); });
    worker->setObjectName(QStringLiteral("kogaview-thumbnail-%1").arg(index));
    m_workers.append(worker);
    worker->start();
  }
}

ThumbnailCache::~ThumbnailCache()
{
  {
    QMutexLocker locker(&m_mutex);
    m_stopping = true;
  }
  m_wake.wakeAll();
  for (QThread* worker : m_workers) {
    worker->wait();
    delete worker;
  }
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

int ThumbnailCache::entryCount()
{
  return m_entries.size();
}

int ThumbnailCache::queued() const
{
  QMutexLocker locker(&m_mutex);
  return m_pending.size();
}

void ThumbnailCache::setBudgetBytes(qint64 bytes)
{
  m_budget = qMax<qint64>(0, bytes);
  evictIfNeeded();
}

void ThumbnailCache::request(QObject* requester, const QString& path, int edge, qint64 modified,
                             qint64 size)
{
  if (path.isEmpty() || edge <= 0) {
    return;
  }
  const QString key = keyFor(path, edge, modified, size);
  registerRequester(requester, key);

  const auto entry = m_entries.constFind(key);
  if (entry != m_entries.constEnd()) {
    // Already generated: a hash lookup and a queue-free answer, with no stat and
    // no rewrite of the entry just because the tile scrolled past again.
    ++m_hits;
    noteUse(key);
    // Only the caller: answering every tile that has ever shown this key would
    // make a hit cost as much as the number of tiles on screen.
    answer(requester, key, QUrl::fromLocalFile(entry->file).toString());
    return;
  }
  if (m_failed.contains(key)) {
    // Known bad (corrupt file or unsupported format): do not decode it again.
    ++m_hits;
    answer(requester, key, QString());
    return;
  }
  {
    QMutexLocker locker(&m_mutex);
    if (m_running.contains(key)) {
      return;
    }
    // Re-requesting a queued key is not a second job, it is the same job asking
    // to be considered fresh: that is what keeps the tile in view ahead of the
    // ones that scrolled away.
    Job& job = m_pending[key];
    job.key = key;
    job.path = path;
    job.edge = edge;
    job.sequence = ++m_sequence;
  }
  m_wake.wakeOne();
}

void ThumbnailCache::workerLoop()
{
  QMutexLocker locker(&m_mutex);
  for (;;) {
    while (!m_stopping && m_pending.isEmpty()) {
      m_wake.wait(&m_mutex);
    }
    if (m_stopping) {
      return;
    }
    // Newest request first. Scrolling a large folder queues far more work than
    // the view can use; serving it in arrival order would answer the tiles the
    // user has already left behind while the visible ones wait.
    auto newest = m_pending.begin();
    for (auto candidate = m_pending.begin(); candidate != m_pending.end(); ++candidate) {
      if (candidate->sequence > newest->sequence) {
        newest = candidate;
      }
    }
    const Job job = *newest;
    m_pending.erase(newest);
    m_running.insert(job.key);
    locker.unlock();

    produce(job);

    locker.relock();
    m_running.remove(job.key);
  }
}

void ThumbnailCache::produce(const Job& job)
{
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
    // Ask the decoder for a small image instead of decoding 12 MP and scaling
    // afterwards.
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
}

void ThumbnailCache::finish(const QString& key, const QString& file, const QString& error)
{
  // Called from a worker thread: hop to the owning thread before touching any
  // field or calling back, so the cache needs no locking around its state.
  QMetaObject::invokeMethod(
    this,
    [this, key, file, error]() {
      if (!error.isEmpty()) {
        qWarning() << "KogaView thumbnails: cannot decode" << key << error;
        m_failed.insert(key);
        QSaveFile marker(m_directory + QLatin1Char('/') + key + QLatin1String(kFailureSuffix));
        if (marker.open(QIODevice::WriteOnly)) {
          marker.commit();
        }
        deliver(key, QString());
        return;
      }
      ++m_generated;
      remember(key, file);
      deliver(key, QUrl::fromLocalFile(file).toString());
    },
    Qt::QueuedConnection);
}

void ThumbnailCache::remember(const QString& key, const QString& file)
{
  Entry entry;
  entry.file = file;
  entry.bytes = QFileInfo(file).size();
  entry.used = ++m_usedClock;
  entry.persisted = false;
  m_bytes += entry.bytes;
  m_entries.insert(key, entry);
  noteUse(key);
  evictIfNeeded();
}

void ThumbnailCache::noteUse(const QString& key)
{
  auto entry = m_entries.find(key);
  if (entry == m_entries.end()) {
    return;
  }
  entry->used = ++m_usedClock;
  if (entry->persisted) {
    return;
  }
  // Write the use back to the file's mtime once per entry per session: that is
  // what makes the least-recently-used order survive a restart, and doing it on
  // every hit meant a file rewrite per tile per scroll.
  entry->persisted = true;
  QFile handle(entry->file);
  if (handle.open(QIODevice::ReadWrite)) {
    handle.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
  }
}

void ThumbnailCache::evictIfNeeded()
{
  if (m_bytes <= m_budget) {
    return;
  }
  // Least recently used first, from the in-memory clock; the order is spelled
  // out here instead of depending on how a directory listing happens to sort.
  QList<QString> keys = m_entries.keys();
  std::sort(keys.begin(), keys.end(), [this](const QString& left, const QString& right) {
    return m_entries.value(left).used < m_entries.value(right).used;
  });
  // Aim well below the budget so eviction does not run after every insert.
  const qint64 target = m_budget * 9 / 10;
  for (const QString& key : keys) {
    if (m_bytes <= target) {
      break;
    }
    const Entry entry = m_entries.value(key);
    if (!QFile::remove(entry.file)) {
      continue;
    }
    m_bytes -= entry.bytes;
    m_entries.remove(key);
    m_requesters.remove(key);
  }
  if (m_bytes < 0) {
    m_bytes = 0;
  }
}

void ThumbnailCache::registerRequester(QObject* requester, const QString& key)
{
  if (requester == nullptr) {
    return;
  }
  auto previous = m_registrations.find(requester);
  if (previous != m_registrations.end()) {
    if (previous->key != key) {
      QVector<QPointer<QObject>>& stale = m_requesters[previous->key];
      for (int index = stale.size() - 1; index >= 0; --index) {
        if (stale.at(index).data() == requester) {
          stale.remove(index);
        }
      }
      if (stale.isEmpty()) {
        m_requesters.remove(previous->key);
      }
    }
    previous->ref = requester;
    previous->key = key;
  } else {
    m_registrations.insert(requester, Registration{ requester, key });
  }

  QVector<QPointer<QObject>>& waiting = m_requesters[key];
  for (const QPointer<QObject>& existing : waiting) {
    if (existing.data() == requester) {
      return;
    }
  }
  waiting.append(QPointer<QObject>(requester));

  if (m_registrations.size() > m_pruneAt) {
    pruneRegistrations();
  }
}

void ThumbnailCache::pruneRegistrations()
{
  // Tiles come and go as the grid scrolls; drop the ones that are gone so the
  // maps do not grow with the length of the session.
  for (auto entry = m_registrations.begin(); entry != m_registrations.end();) {
    if (entry->ref.isNull()) {
      entry = m_registrations.erase(entry);
    } else {
      ++entry;
    }
  }
  m_pruneAt = qMax(64, m_registrations.size() * 2);
}

void ThumbnailCache::answer(QObject* requester, const QString& key, const QString& url)
{
  if (requester == nullptr) {
    return;
  }
  // Targeted: exactly the tile that asked is called back, so one thumbnail
  // finishing cannot invalidate every other tile's binding.
  QMetaObject::invokeMethod(requester, "setThumbnail", Qt::QueuedConnection,
                            Q_ARG(QVariant, QVariant(key)), Q_ARG(QVariant, QVariant(url)));
}

void ThumbnailCache::deliver(const QString& key, const QString& url)
{
  const QVector<QPointer<QObject>> waiting = m_requesters.value(key);
  for (const QPointer<QObject>& ref : waiting) {
    answer(ref.data(), key, url);
  }
}

void ThumbnailCache::scanExisting()
{
  QDir dir(m_directory);
  m_bytes = 0;
  const auto entries = dir.entryInfoList(
    QStringList{QLatin1String("*.jpg"), QLatin1String("*.png"), QLatin1String("*.fail")},
    QDir::Files);
  for (const QFileInfo& info : entries) {
    const QString key = info.completeBaseName();
    if (info.suffix() == QLatin1String("fail")) {
      m_failed.insert(key);
      continue;
    }
    Entry entry;
    entry.file = info.absoluteFilePath();
    entry.bytes = info.size();
    // The mtime is the use order written by a previous session.
    entry.used = info.lastModified().toMSecsSinceEpoch();
    entry.persisted = true;
    m_entries.insert(key, entry);
    m_bytes += entry.bytes;
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
  m_entries.clear();
  m_failed.clear();
  m_requesters.clear();
  m_registrations.clear();
  m_bytes = 0;
}
