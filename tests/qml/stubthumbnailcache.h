#pragma once

#include <QList>
#include <QObject>
#include <QString>

/// Stand-in for the C++ `ThumbnailCache` context object the views receive from
/// `main.cpp`.
///
/// It has exactly the shape the QML side uses — `keyFor` and `request` as
/// invokables plus the two signals — so a test can assert what a view asked for
/// and decide when (and with which url) a thumbnail "finishes", without decoding
/// anything or waiting on a thread pool.
class StubThumbnailCache : public QObject
{
  Q_OBJECT

public:
  struct Call
  {
    QString path;
    int edge = 0;
    qint64 modified = 0;
    qint64 size = 0;
  };

  QList<Call> calls;

  Q_INVOKABLE QString keyFor(const QString& path, int edge, qint64 modified, qint64 size) const
  {
    return QStringLiteral("%1|%2|%3|%4").arg(path).arg(edge).arg(modified).arg(size);
  }

  Q_INVOKABLE void request(const QString& path, int edge, qint64 modified, qint64 size)
  {
    calls.append(Call{ path, edge, modified, size });
  }

  /// Every request made for `path` (one per size bucket a view asked for).
  QList<Call> callsFor(const QString& path) const
  {
    QList<Call> result;
    for (const Call& call : calls) {
      if (call.path == path) {
        result.append(call);
      }
    }
    return result;
  }

  /// The last request made for `path`, if any.
  Call lastCallFor(const QString& path) const
  {
    for (int index = calls.size() - 1; index >= 0; --index) {
      if (calls.at(index).path == path) {
        return calls.at(index);
      }
    }
    return Call{};
  }

  /// Report a generated thumbnail the way the real cache does.
  void deliver(const Call& call, const QString& url)
  {
    emit thumbnailReady(keyFor(call.path, call.edge, call.modified, call.size), url);
  }

  /// Answer every size the views asked for, like the real cache does per request.
  void deliverAllFor(const QString& path, const QString& url)
  {
    for (const Call& call : callsFor(path)) {
      deliver(call, url);
    }
  }

  /// Report an undecodable source.
  void fail(const Call& call)
  {
    emit thumbnailFailed(keyFor(call.path, call.edge, call.modified, call.size));
  }

signals:
  void thumbnailReady(const QString& key, const QString& url);
  void thumbnailFailed(const QString& key);
};
