// Thumbnail cache regression tests.
//
// The cache is the difference between drawing a tile from a 200 px thumbnail and
// decoding a 12 MP JPEG again for every visible cell, so the tests pin the parts
// that make it correct: one file per (image, size, mtime, edge), a hit that does
// not re-decode, a changed image that misses, an undecodable source that is not
// retried, transparency that survives, and a budget that is enforced.
//
// They drive `ThumbnailCache` directly (no QML scene) with real image files in a
// temporary directory.

#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QImage>
#include <QImageReader>

#include "thumbnailcache.h"

namespace {

/// Paint `size` with a gradient and one dark corner, so a scaled copy is not
/// uniform and a wrong crop is visible.
QImage painted(const QSize& size, bool alpha = false)
{
  QImage image(size, QImage::Format_ARGB32);
  const QColor transparent = alpha ? Qt::transparent : QColor(Qt::white);
  image.fill(transparent);
  for (int y = 0; y < size.height(); ++y) {
    for (int x = 0; x < size.width(); ++x) {
      image.setPixelColor(x, y, QColor(x * 255 / qMax(1, size.width()),
                                       y * 255 / qMax(1, size.height()),
                                       128,
                                       alpha ? 255 : 255));
    }
  }
  image.setPixelColor(0, 0, Qt::black);
  return image;
}

bool writeImage(const QString& path, const QSize& size, bool alpha = false)
{
  return painted(size, alpha).save(path, alpha ? "PNG" : "JPG", 92);
}

/// Insert an EXIF `APP1` segment carrying nothing but an orientation tag, the
/// way a phone writes it. Qt's JPEG handler applies it only when asked to
/// auto-transform, which is the behaviour the cache relies on.
bool addExifOrientation(const QString& path, quint16 orientation)
{
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) {
    return false;
  }
  const QByteArray source = file.readAll();
  file.close();
  if (!source.startsWith("\xFF\xD8")) {
    return false;
  }

  QByteArray payload = QByteArray::fromHex("457869660000");       // "Exif\0\0"
  payload += QByteArray::fromHex("49492A0008000000");             // little endian, IFD0 at 8
  payload += QByteArray::fromHex("0100");                         // one entry
  payload += QByteArray::fromHex("1201");                         // tag 0x0112 = orientation
  payload += QByteArray::fromHex("0300");                         // SHORT
  payload += QByteArray::fromHex("01000000");                     // count 1
  payload += QByteArray::fromHex("0100");                         // value (padded below)
  payload[payload.size() - 2] = static_cast<char>(orientation & 0xFF);
  payload[payload.size() - 1] = static_cast<char>((orientation >> 8) & 0xFF);
  payload += QByteArray::fromHex("0000");                         // rest of the value slot
  payload += QByteArray::fromHex("00000000");                     // no next IFD

  QByteArray segment;
  segment += static_cast<char>(0xFF);
  segment += static_cast<char>(0xE1);
  const int length = payload.size() + 2;
  segment += static_cast<char>((length >> 8) & 0xFF);
  segment += static_cast<char>(length & 0xFF);
  segment += payload;

  QFile out(path);
  if (!out.open(QIODevice::WriteOnly)) {
    return false;
  }
  out.write(source.left(2) + segment + source.mid(2));
  return true;
}

/// Decode failures the cache reports. "A known-bad source is not decoded again"
/// is invisible in the emitted signals — both paths end in `thumbnailFailed` —
/// but not in the warnings, so the test counts them.
int g_decodeFailures = 0;
QtMessageHandler g_previousHandler = nullptr;

void countDecodeFailures(QtMsgType type, const QMessageLogContext& context, const QString& message)
{
  if (message.contains(QLatin1String("cannot decode"))) {
    ++g_decodeFailures;
  }
  if (g_previousHandler != nullptr) {
    g_previousHandler(type, context, message);
  }
}

} // namespace

/// Stands in for one QML tile: the cache answers by calling `setThumbnail` on the
/// object that asked, so a test needs a requester per tile to see who was told
/// and what they were told.
class Requester : public QObject
{
  Q_OBJECT

public:
  QString lastKey;
  QString lastUrl;
  int answers = 0;

  Q_INVOKABLE void setThumbnail(const QVariant& key, const QVariant& url)
  {
    lastKey = key.toString();
    lastUrl = url.toString();
    ++answers;
    emit answered();
  }

signals:
  void answered();
};

class TestThumbnails : public QObject
{
  Q_OBJECT

private:
  QTemporaryDir m_root;
  QTemporaryDir m_cacheDir;
  ThumbnailCache* m_cache = nullptr;
  Requester m_tile;

  QString sourcePath(const QString& name) const { return m_root.filePath(name); }

  /// One request, waited for; returns the answered url (empty when it failed).
  QString requestAndWait(const QString& path, int edge, qint64 modified = 1, qint64 size = 0)
  {
    const int before = m_tile.answers;
    m_cache->request(&m_tile, path, edge, modified, size);
    return waitForAnswer(before) ? m_tile.lastUrl : QString();
  }

  /// Block until the cache has answered `forCount + 1` times in total.
  bool waitForAnswer(int forCount, int timeout = 10000)
  {
    if (m_tile.answers != forCount) {
      return true;
    }
    QSignalSpy answered(&m_tile, &Requester::answered);
    return answered.wait(timeout) || m_tile.answers != forCount;
  }

private slots:
  void initTestCase()
  {
    QVERIFY(m_root.isValid());
    QVERIFY(m_cacheDir.isValid());
  }

  void init()
  {
    m_tile.lastKey.clear();
    m_tile.lastUrl.clear();
    m_tile.answers = 0;
    g_decodeFailures = 0;
    g_previousHandler = qInstallMessageHandler(countDecodeFailures);
    m_cache = new ThumbnailCache(m_cacheDir.filePath(QStringLiteral("thumbs")));
  }
  void cleanup()
  {
    qInstallMessageHandler(g_previousHandler);
    g_previousHandler = nullptr;
    delete m_cache;
    m_cache = nullptr;
    QDir(m_cacheDir.filePath(QStringLiteral("thumbs"))).removeRecursively();
  }

  /// One file per (image, edge), downscaled to fit while keeping the aspect.
  void generatesOneFilePerImageAndEdge()
  {
    const QString wide = sourcePath(QStringLiteral("wide.jpg"));
    QVERIFY(writeImage(wide, QSize(1600, 1000)));

    const QString first = requestAndWait(wide, 256);
    QVERIFY2(!first.isEmpty(), "no thumbnail for a valid image");
    QVERIFY2(QFileInfo(QUrl(first).toLocalFile()).isFile(), "the ready url is not a file");
    QCOMPARE(m_cache->entryCount(), 1);

    QImageReader reader(QUrl(first).toLocalFile());
    const QSize thumb = reader.size();
    QCOMPARE(thumb.width(), 256);
    QCOMPARE(thumb.height(), 160); // 1600x1000 scaled to 256 wide

    // A second edge is a second entry: the grid and the filmstrip ask for
    // different sizes and must not overwrite each other.
    const QString second = requestAndWait(wide, 128);
    QVERIFY(!second.isEmpty());
    QVERIFY(second != first);
    QCOMPARE(m_cache->entryCount(), 2);
    QCOMPARE(QImageReader(QUrl(second).toLocalFile()).size(), QSize(128, 80));

    // The original is never touched.
    QCOMPARE(QImageReader(wide).size(), QSize(1600, 1000));
  }

  /// A cached entry answers without decoding again and without rewriting the
  /// file: that is what makes scrolling a folder cheap. Deleting the source
  /// makes it unambiguous — a regenerating cache would have nothing to read.
  void aCachedEntryIsAnsweredWithoutReEncoding()
  {
    const QString source = sourcePath(QStringLiteral("again.jpg"));
    QVERIFY(writeImage(source, QSize(900, 600)));

    const QString first = requestAndWait(source, 192);
    QVERIFY(!first.isEmpty());
    const qint64 bytes = m_cache->bytesUsed();
    QVERIFY(bytes > 0);

    QVERIFY(QFile::remove(source));
    const int before = m_tile.answers;
    m_cache->request(&m_tile, source, 192, 1, 0);
    QVERIFY(waitForAnswer(before, 5000));
    QCOMPARE(m_tile.lastUrl, first);
    QCOMPARE(m_cache->entryCount(), 1);
    QCOMPARE(m_cache->bytesUsed(), bytes);
    // Not one decode was attempted for the hit.
    QCOMPARE(g_decodeFailures, 0);
  }

  /// The key carries both mtime and size, so an edited image is a miss — no
  /// invalidation logic needed and no way to show stale pixels.
  void aChangedImageGetsANewEntry()
  {
    const QString source = sourcePath(QStringLiteral("changed.jpg"));
    QVERIFY(writeImage(source, QSize(800, 800)));

    const QString first = requestAndWait(source, 128, 1000, 100);
    QVERIFY(!first.isEmpty());

    // Same size, newer mtime: an edit in place.
    const QString second = requestAndWait(source, 128, 2000, 100);
    QVERIFY(!second.isEmpty());
    QVERIFY2(second != first, "a newer modification time reused the old thumbnail");

    // Same mtime, different size: replaced by another file that kept its date.
    const QString third = requestAndWait(source, 128, 2000, 200);
    QVERIFY(!third.isEmpty());
    QVERIFY2(third != second, "a different file size reused the old thumbnail");

    QCOMPARE(m_cache->entryCount(), 3);
  }

  /// An undecodable source is remembered, so scrolling past it does not try
  /// again on every frame; the failed key never yields a url.
  void anUndecodableImageIsRememberedAsFailed()
  {
    const QString broken = sourcePath(QStringLiteral("broken.png"));
    QFile file(broken);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("this is not a png");
    file.close();

    const QString url = requestAndWait(broken, 128);
    QCOMPARE(url, QString());
    QVERIFY(QFile::exists(QString::fromLatin1("%1/%2.fail")
                            .arg(m_cache->directory(), m_cache->keyFor(broken, 128, 1, 0))));

    QCOMPARE(g_decodeFailures, 1);

    // Second request: answered from the marker. Still no url, nothing new
    // generated, and — the part that matters while scrolling — not decoded
    // again.
    const int before = m_tile.answers;
    m_tile.lastUrl = QStringLiteral("sentinel");
    m_cache->request(&m_tile, broken, 128, 1, 0);
    QVERIFY(waitForAnswer(before, 5000));
    QCOMPARE(m_tile.lastUrl, QString());
    QCOMPARE(m_cache->entryCount(), 0);
    QCOMPARE(g_decodeFailures, 1);
  }

  /// Transparency survives: an image with alpha is stored as PNG, without as
  /// JPEG (a JPEG would flatten the transparency to black).
  void transparencyDecidesTheEncoding()
  {
    const QString opaque = sourcePath(QStringLiteral("opaque.jpg"));
    const QString transparent = sourcePath(QStringLiteral("alpha.png"));
    QVERIFY(writeImage(opaque, QSize(400, 400), false));
    QVERIFY(writeImage(transparent, QSize(400, 400), true));

    const QString opaqueThumb = requestAndWait(opaque, 128);
    const QString alphaThumb = requestAndWait(transparent, 128);
    QVERIFY(opaqueThumb.endsWith(QLatin1String(".jpg")));
    QVERIFY(alphaThumb.endsWith(QLatin1String(".png")));
    QVERIFY(QImage(QUrl(alphaThumb).toLocalFile()).hasAlphaChannel());

    // The PNG entry is found again by a later lookup, not just by the call that
    // created it: both extensions have to be searched. Removing the source makes
    // that unambiguous — a regenerating cache would fail to decode it.
    QVERIFY(QFile::remove(transparent));
    QCOMPARE(requestAndWait(transparent, 128), alphaThumb);
  }

  /// A phone photo carries its orientation outside the pixels; the thumbnail
  /// must be upright, exactly like the un-cached `Image` was.
  void orientationFromExifIsHonoured()
  {
    const QString source = sourcePath(QStringLiteral("rotated.jpg"));
    QVERIFY(writeImage(source, QSize(400, 200)));
    QVERIFY(addExifOrientation(source, 6)); // 6 = rotate 90 degrees clockwise

    const QString url = requestAndWait(source, 256, 2, 0);
    QVERIFY2(!url.isEmpty(), "no thumbnail for an EXIF-rotated image");
    // 400x200 turned upright is 200x400, scaled to fit 256: 128x256.
    QCOMPARE(QImageReader(QUrl(url).toLocalFile()).size(), QSize(128, 256));
  }

  /// A restart finds what is already on disk: the files are counted against the
  /// budget and answered from without decoding anything again.
  void aRestartFindsTheExistingEntries()
  {
    const QString source = sourcePath(QStringLiteral("kept.jpg"));
    QVERIFY(writeImage(source, QSize(640, 480)));
    const QString first = requestAndWait(source, 192);
    QVERIFY(!first.isEmpty());
    const qint64 bytes = m_cache->bytesUsed();
    QVERIFY(bytes > 0);

    // "Restart": a new cache object over the same directory.
    delete m_cache;
    m_cache = new ThumbnailCache(m_cacheDir.filePath(QStringLiteral("thumbs")));
    QCOMPARE(m_cache->bytesUsed(), bytes);
    QCOMPARE(m_cache->entryCount(), 1);
    QCOMPARE(requestAndWait(source, 192), first);
  }

  /// The cache keeps itself under the budget, oldest files first.
  void evictionKeepsTheCacheUnderBudget()
  {
    m_cache->setBudgetBytes(40 * 1024);
    QCOMPARE(m_cache->budgetBytes(), qint64(40 * 1024));

    QList<QString> generated;
    for (int index = 0; index < 8; ++index) {
      const QString path = sourcePath(QStringLiteral("bulk-%1.jpg").arg(index));
      // Different sizes so each entry has a different key and a different size
      // on disk.
      QVERIFY(writeImage(path, QSize(1000 + index * 40, 700 + index * 30)));
      const QString url = requestAndWait(path, 384, index, 0);
      QVERIFY(!url.isEmpty());
      generated.append(QUrl(url).toLocalFile());
      QTest::qWait(20); // let the modification times differ
    }

    QVERIFY2(m_cache->bytesUsed() <= 40 * 1024, "the cache grew past its budget");
    QVERIFY2(m_cache->entryCount() < generated.size(), "nothing was evicted");

    // Eviction removes files, it does not leave dangling entries behind.
    int present = 0;
    for (const QString& file : generated) {
      present += QFileInfo::exists(file) ? 1 : 0;
    }
    QCOMPARE(present, m_cache->entryCount());
  }

  /// Eviction drops the entry nobody has looked at for longest. A hit has to
  /// move the entry back to the front, or a folder the user revisits daily would
  /// age out like a one-off.
  void evictionIsLeastRecentlyUsed()
  {
    const QString a = sourcePath(QStringLiteral("lru-a.jpg"));
    const QString b = sourcePath(QStringLiteral("lru-b.jpg"));
    const QString c = sourcePath(QStringLiteral("lru-c.jpg"));
    for (const QString& path : { a, b, c }) {
      QVERIFY(writeImage(path, QSize(1600, 1200)));
    }

    const QString thumbA = requestAndWait(a, 384);
    QVERIFY(!thumbA.isEmpty());
    QTest::qWait(20);
    const QString thumbB = requestAndWait(b, 384);
    QVERIFY(!thumbB.isEmpty());
    QTest::qWait(20);
    // Room for two and a half entries, so exactly one is dropped on the next
    // insert and which one it is cannot be a coincidence.
    m_cache->setBudgetBytes(m_cache->bytesUsed() * 5 / 4);

    // A is used again, so B is now the least recently used entry.
    QCOMPARE(requestAndWait(a, 384), thumbA);
    QTest::qWait(20);

    const QString thumbC = requestAndWait(c, 384);
    QVERIFY(!thumbC.isEmpty());

    const QString pathA = QUrl(thumbA).toLocalFile();
    const QString pathB = QUrl(thumbB).toLocalFile();
    const QString pathC = QUrl(thumbC).toLocalFile();
    QVERIFY2(QFileInfo::exists(pathA), "the entry that was just used was evicted");
    QVERIFY2(QFileInfo::exists(pathC), "the entry that was just created was evicted");
    QVERIFY2(!QFileInfo::exists(pathB), "the least recently used entry survived");
    QCOMPARE(m_cache->entryCount(), 2);
  }

  /// Decoding never takes every core: the thread that draws the window has to
  /// keep running at the same time, or the whole application stutters while a
  /// folder fills in.
  void decodingNeverUsesTheWholeMachine()
  {
    const int cores = QThread::idealThreadCount();
    QVERIFY2(m_cache->decodeThreads() >= 1, "nothing would ever be decoded");
    QVERIFY2(m_cache->decodeThreads() <= 3, "more decoders than the cap");
    if (cores > 1) {
      QVERIFY2(m_cache->decodeThreads() < cores,
               "decoding took every core, leaving the GUI thread without one");
    }
  }

  /// The answer goes to the objects that asked for that key, and to nobody else.
  /// "Only to them" is what keeps one finished thumbnail from re-evaluating every
  /// tile on screen.
  void answersOnlyTheObjectsThatAsked()
  {
    const QString shared = sourcePath(QStringLiteral("shared.jpg"));
    QVERIFY(writeImage(shared, QSize(900, 700)));

    Requester first;
    Requester second;
    Requester bystander;
    const QString url = requestAndWait(shared, 192);
    QVERIFY(!url.isEmpty());

    // A hit: both tiles that ask are answered, the one that never asked is not.
    m_cache->request(&first, shared, 192, 1, 0);
    m_cache->request(&second, shared, 192, 1, 0);
    QTRY_COMPARE_WITH_TIMEOUT(first.answers, 1, 5000);
    QTRY_COMPARE_WITH_TIMEOUT(second.answers, 1, 5000);
    QCOMPARE(first.lastUrl, url);
    QCOMPARE(second.lastUrl, url);
    QTest::qWait(50);
    QCOMPARE(bystander.answers, 0);
  }

  /// A tile that scrolls past must not keep the entry's file being rewritten:
  /// a hit is a hash lookup, not a filesystem update. The first use of a session
  /// is written back, because that is what makes the LRU order survive a restart.
  void aHitDoesNotRewriteTheEntry()
  {
    const QString source = sourcePath(QStringLiteral("touch.jpg"));
    QVERIFY(writeImage(source, QSize(1200, 900)));
    const QString url = requestAndWait(source, 256);
    QVERIFY(!url.isEmpty());

    const QString file = QUrl(url).toLocalFile();
    const QDateTime generated = QFileInfo(file).lastModified();
    QTest::qWait(50);
    for (int index = 0; index < 5; ++index) {
      QCOMPARE(requestAndWait(source, 256), url);
    }
    QCOMPARE(QFileInfo(file).lastModified(), generated);
  }

  /// Clearing the cache removes both thumbnails and failure markers.
  void clearRemovesEverything()
  {
    const QString source = sourcePath(QStringLiteral("cleared.jpg"));
    QVERIFY(writeImage(source, QSize(600, 400)));
    QVERIFY(!requestAndWait(source, 128).isEmpty());
    QCOMPARE(m_cache->entryCount(), 1);

    m_cache->clear();
    QCOMPARE(m_cache->entryCount(), 0);
    QCOMPARE(m_cache->bytesUsed(), qint64(0));

    // And it can be rebuilt afterwards.
    QVERIFY(!requestAndWait(source, 128).isEmpty());
    QCOMPARE(m_cache->entryCount(), 1);
  }
};

QTEST_MAIN(TestThumbnails)
#include "tst_thumbnails.moc"
