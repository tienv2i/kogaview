#pragma once

#include <QObject>
#include <QSet>
#include <QString>

/// On-disk (and, through Qt's pixmap cache, in-memory) thumbnail cache.
///
/// Drawing a 200 px tile from a 12 MP JPEG is what makes a photo grid feel slow,
/// and a plain `Image { source: file }` does exactly that for every visible cell,
/// again after every scroll, every folder revisit and every refresh. This turns
/// it into: decode once into a small file, then let the view draw that file.
///
/// Entries are keyed by (path, size, mtime, requested edge), so a modified image
/// simply misses and is regenerated — there is no invalidation logic and no way
/// to show stale pixels. Generation runs on the thread pool and never blocks the
/// GUI: `thumbnailReady` carries the key back so the view can swap the source in,
/// `thumbnailFailed` lets it fall back to the original file.
///
/// Eviction is least-recently-*used*: a hit moves the entry's modification time,
/// so the folder the user keeps coming back to stays while a one-off folder is
/// dropped. The disk cache is the source of truth; the RAM side is the url book
/// in QML plus Qt's own pixmap cache for the decoded tiles.
///
/// A decode that fails is remembered too (the source may be corrupt, or a format
/// the build cannot read), so scrolling past it does not retry it every frame.
class ThumbnailCache : public QObject
{
  Q_OBJECT

public:
  /// `directory` is created on demand; `parent` follows the usual Qt ownership.
  explicit ThumbnailCache(const QString& directory, QObject* parent = nullptr);

  /// Stable key for one (image, size, mtime, edge) combination. Pure: no I/O and
  /// no side effects, so QML may call it from a property binding.
  Q_INVOKABLE QString keyFor(const QString& path, int edge, qint64 modified, qint64 size) const;

  /// Queue the thumbnail for that combination. Idempotent: a cached entry
  /// answers immediately, a queued or running one is not started twice.
  Q_INVOKABLE void request(const QString& path, int edge, qint64 modified, qint64 size);

  /// Delete every cached file (used by the dev harness and by tests).
  Q_INVOKABLE void clear();

  Q_INVOKABLE qint64 bytesUsed() const { return m_bytes; }
  Q_INVOKABLE int entryCount();
  /// Diagnostics for the dev harness: how many requests were answered from the
  /// cache and how many thumbnails had to be produced.
  Q_INVOKABLE int hits() const { return m_hits; }
  Q_INVOKABLE int generated() const { return m_generated; }

  QString directory() const { return m_directory; }
  qint64 budgetBytes() const { return m_budget; }
  void setBudgetBytes(qint64 bytes);

signals:
  void thumbnailReady(const QString& key, const QString& url);
  void thumbnailFailed(const QString& key);

private:
  struct Job
  {
    QString key;
    QString path;
    int edge = 0;
  };

  /// Path of an already generated file for `key`, empty when there is none.
  QString cachedFile(const QString& key) const;
  /// Move `file` to the front of the eviction order (it was just used).
  void touch(const QString& file);
  /// Generate one thumbnail. Runs on a worker thread; reports back through a
  /// queued call so every cache field stays owned by the GUI thread.
  void generate(const Job& job);
  void finish(const QString& key, const QString& file, const QString& error);
  void remember(qint64 bytes);
  void evictIfNeeded();
  void scanExisting();

  QString m_directory;
  qint64 m_budget = 256ll * 1024 * 1024;
  qint64 m_bytes = 0;
  int m_hits = 0;
  int m_generated = 0;
  QSet<QString> m_inflight;
};
