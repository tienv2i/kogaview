#pragma once

#include <QHash>
#include <QMutex>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QString>
#include <QThread>
#include <QVector>
#include <QWaitCondition>

/// On-disk thumbnail cache with a bounded, most-recent-first decode queue.
///
/// Drawing a 200 px tile from a 12 MP JPEG is what makes a photo grid feel slow,
/// and a plain `Image { source: file }` does exactly that for every visible cell,
/// again after every scroll, every folder revisit and every refresh. This turns
/// it into: decode once into a small file, then let the view draw that file.
///
/// Entries are keyed by (path, size, mtime, requested edge), so a modified image
/// simply misses and is regenerated — there is no invalidation logic and no way
/// to show stale pixels.
///
/// Three rules keep it off the GUI thread, which is the whole point:
///
/// 1. **Answers are targeted.** `request()` names the object that wants the
///    thumbnail; when it is ready only that object is told, through its own
///    `setThumbnail(key, url)` function. There is no global "these are all the
///    thumbnails" property, so one thumbnail finishing cannot invalidate every
///    tile on screen — that turned a 1 200-image folder into 100 k+ binding
///    re-evaluations per scroll.
/// 2. **Decoding is rate-limited.** A fixed, small pool decodes; it never takes
///    every core, because the GUI thread has to keep drawing at the same time.
///    The queue hands out the *newest* request first, so a tile scrolling into
///    view is not stuck behind tiles that already left it.
/// 3. **A hit costs nothing but a hash lookup.** Known entries are remembered in
///    memory, so a hit neither stats the filesystem nor rewrites the entry's
///    timestamp on every single scroll.
///
/// Eviction is least-recently-*used*: use is tracked in memory and only the
/// first use of an entry in a session is written back to the file's mtime, which
/// is what makes the order survive a restart.
///
/// A decode that fails is remembered too (the source may be corrupt, or a format
/// the build cannot read), so scrolling past it does not retry it every frame.
class ThumbnailCache : public QObject
{
  Q_OBJECT

public:
  /// `directory` is created on demand; `parent` follows the usual Qt ownership.
  explicit ThumbnailCache(const QString& directory, QObject* parent = nullptr);
  ~ThumbnailCache() override;

  /// Stable key for one (image, size, mtime, edge) combination. Pure: no I/O and
  /// no side effects, so QML may call it from a property binding.
  Q_INVOKABLE QString keyFor(const QString& path, int edge, qint64 modified, qint64 size) const;

  /// Synchronous cache hit lookup (GUI thread, pure in-memory hash table).
  /// Returns the cached `file://` URL immediately on hit, or an empty string
  /// on miss so the caller can fall back to the async `request()` queue.
  Q_INVOKABLE QString lookup(const QString& path, int edge, qint64 modified, qint64 size);

  /// Ask for the thumbnail for that combination on behalf of `requester`, which
  /// is called back through `setThumbnail(key, url)` on its own thread — url is
  /// empty when the source cannot be decoded. Idempotent: a cached entry answers
  /// immediately, a queued or running one is not decoded twice.
  Q_INVOKABLE void request(QObject* requester, const QString& path, int edge, qint64 modified,
                           qint64 size);

  /// Delete every cached file (used by the dev harness and by tests).
  Q_INVOKABLE void clear();

  Q_INVOKABLE qint64 bytesUsed() const { return m_bytes; }
  Q_INVOKABLE int entryCount();
  /// Diagnostics for the dev harness: how many requests were answered from the
  /// cache and how many thumbnails had to be produced.
  Q_INVOKABLE int hits() const { return m_hits; }
  Q_INVOKABLE int generated() const { return m_generated; }
  /// Thumbnails waiting for a worker right now.
  Q_INVOKABLE int queued() const;
  /// How many thumbnails are decoded at once; never the whole machine.
  int decodeThreads() const { return m_workers.size(); }

  QString directory() const { return m_directory; }
  qint64 budgetBytes() const { return m_budget; }
  void setBudgetBytes(qint64 bytes);

private:
  struct Job
  {
    QString key;
    QString path;
    int edge = 0;
    quint64 sequence = 0;
  };

  /// One object that asked for one key; `ref` guards against it being destroyed.
  struct Registration
  {
    QPointer<QObject> ref;
    QString key;
  };

  /// Where an entry lives and when it was last used, kept in memory so a hit is
  /// a hash lookup instead of a filesystem round trip.
  struct Entry
  {
    QString file;
    qint64 bytes = 0;
    qint64 used = 0;
    bool persisted = false;
  };

  void scanExisting();
  void workerLoop();
  /// Decode + encode one thumbnail. Runs on a worker thread and touches no
  /// member state; the result is reported through the queued `finish()`.
  void produce(const Job& job);
  /// Record the outcome of one job and answer its requesters. GUI thread only.
  void finish(const QString& key, const QString& file, const QString& error);
  void remember(const QString& key, const QString& file);
  void evictIfNeeded();
  void noteUse(const QString& key);
  void registerRequester(QObject* requester, const QString& key);
  /// Answer the one object that just asked.
  void answer(QObject* requester, const QString& key, const QString& url);
  /// Answer everyone still waiting for that key (a thumbnail that was produced).
  void deliver(const QString& key, const QString& url);
  void pruneRegistrations();

  QString m_directory;
  qint64 m_budget = 256ll * 1024 * 1024;
  qint64 m_bytes = 0;
  int m_hits = 0;
  int m_generated = 0;
  qint64 m_usedClock = 0;

  /// GUI-thread only.
  QHash<QString, Entry> m_entries;
  QSet<QString> m_failed;
  QHash<QString, QVector<QPointer<QObject>>> m_requesters;
  QHash<QObject*, Registration> m_registrations;
  /// How many requesters were swept last, so pruning stays amortised.
  int m_pruneAt = 0;

  /// Shared with the workers; every access takes `m_mutex`.
  mutable QMutex m_mutex;
  QWaitCondition m_wake;
  QHash<QString, Job> m_pending;
  QSet<QString> m_running;
  quint64 m_sequence = 0;
  bool m_stopping = false;
  QVector<QThread*> m_workers;
};
