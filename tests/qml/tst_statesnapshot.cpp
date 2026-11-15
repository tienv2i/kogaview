// State-snapshot regression tests: the window renders one snapshot, built from
// the bridge's metadata string plus the folder listing that travels under its
// own epoch.
//
// The split exists because the listing is the only part of the snapshot that
// grows with the folder: a thousand photos is a 200 KB string, and re-parsing it
// on every snapshot made every click in a big folder pay for the whole grid. The
// tests below load the real `crates/desktop/qml/StateSnapshot.qml` and assert
// that a metadata-only change keeps the listing array *identical* (so no
// delegate is rebuilt and no listing is re-parsed), that a new epoch replaces
// it, and that a broken half never blanks the window.

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QScopedPointer>
#include <QTest>

namespace {

constexpr int kEntries = 400;

/// Path to the real QML sources, the same way the other suites find them.
QString qmlDir()
{
  return QStringLiteral(KOGAVIEW_QML_SOURCE_DIR);
}

class TestStateSnapshot : public QObject
{
  Q_OBJECT

private:
  /// The bridge's `metaJson`: everything the window paints except the listing.
  /// It carries no `entries`/`viewerImages` field at all — they are published
  /// apart, and serialising them twice is what the split removes.
  static QString metaJson(int revision, const QString& workspace)
  {
    QJsonObject meta;
    meta.insert(QStringLiteral("revision"), revision);
    meta.insert(QStringLiteral("workspace"), workspace);
    meta.insert(QStringLiteral("currentFolder"), QStringLiteral("/photos"));
    meta.insert(QStringLiteral("busy"), false);
    meta.insert(QStringLiteral("status"), QStringLiteral("Ready"));
    // Counted in the listing, not carried by the metadata.
    meta.insert(QStringLiteral("itemCount"), kEntries);
    return QString::fromUtf8(QJsonDocument(meta).toJson(QJsonDocument::Compact));
  }

  /// The bridge's `listingJson`: entries plus the filmstrip's image paths.
  static QString listingJson(const QString& prefix)
  {
    QJsonArray entries;
    QJsonArray images;
    for (int index = 0; index < kEntries; ++index) {
      const QString path = QStringLiteral("/photos/%1-%2.jpg").arg(prefix).arg(index);
      QJsonObject entry;
      entry.insert(QStringLiteral("name"), QStringLiteral("%1-%2.jpg").arg(prefix).arg(index));
      entry.insert(QStringLiteral("path"), path);
      entry.insert(QStringLiteral("isDir"), false);
      entry.insert(QStringLiteral("isImage"), true);
      entry.insert(QStringLiteral("size"), 1000);
      entry.insert(QStringLiteral("modified"), 1700000000);
      entries.append(entry);
      images.append(path);
    }
    QJsonObject listing;
    listing.insert(QStringLiteral("entries"), entries);
    listing.insert(QStringLiteral("viewerImages"), images);
    return QString::fromUtf8(QJsonDocument(listing).toJson(QJsonDocument::Compact));
  }

  /// Evaluate a JS expression in the object's own context: a QVariantList on its
  /// way out to C++ is already a copy, so array identity has to be asked about
  /// there.
  static QJSValue evaluate(QObject* object, const QString& expression)
  {
    QQmlEngine* engine = qmlEngine(object);
    if (engine == nullptr) {
      return QJSValue();
    }
    QQmlExpression reader(qmlContext(object), object, expression);
    return engine->toScriptValue(reader.evaluate());
  }

  QVariantList shownEntries() const
  {
    return m_snapshot->property("entries").toList();
  }

  QQmlEngine m_engine;
  QScopedPointer<QObject> m_snapshot;

private slots:
  void initTestCase()
  {
    QQmlComponent component(&m_engine, QUrl::fromLocalFile(
                                        qmlDir() + QStringLiteral("/StateSnapshot.qml")));
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));
    m_snapshot.reset(component.create());
    QVERIFY(m_snapshot != nullptr);
  }

  void init()
  {
    // Fresh per test: the previous test's listing must not be borrowed by this
    // one through a snapshot whose epoch happens to match.
    m_snapshot->setProperty("listingJson", QStringLiteral(R"({"entries":[],"viewerImages":[]})"));
    m_snapshot->setProperty("metaJson", QString());
    m_snapshot->setProperty("epoch", -1);
  }

  /// The window renders the metadata and the listing side by side, each field
  /// where the views look for it.
  void theListingTravelsBesideTheMetadata()
  {
    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("a")));
    m_snapshot->setProperty("epoch", 1);
    m_snapshot->setProperty("metaJson", metaJson(4, QStringLiteral("browser")));

    const QVariantMap state = m_snapshot->property("state").toMap();
    QCOMPARE(state.value(QStringLiteral("revision")).toInt(), 4);
    QCOMPARE(state.value(QStringLiteral("workspace")).toString(), QStringLiteral("browser"));
    QCOMPARE(state.value(QStringLiteral("itemCount")).toInt(), kEntries);
    // The metadata has no listing in it; the listing is its own published set.
    QVERIFY2(!state.contains(QStringLiteral("entries")),
             "the metadata still carried an entries field");
    QVERIFY2(!state.contains(QStringLiteral("viewerImages")),
             "the metadata still carried a viewerImages field");
    const QVariantList entries = shownEntries();
    QCOMPARE(entries.size(), kEntries);
    QCOMPARE(entries.first().toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("a-0.jpg"));
    QCOMPARE(m_snapshot->property("viewerImages").toStringList().size(), kEntries);
  }

  /// A snapshot that only changes the metadata keeps the *same* listing arrays —
  /// nothing re-parsed, nothing for a view to rebuild.
  void aMetadataOnlyChangeKeepsTheSameListing()
  {
    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("a")));
    m_snapshot->setProperty("epoch", 1);
    m_snapshot->setProperty("metaJson", metaJson(4, QStringLiteral("browser")));
    QJSValue savedEntries = evaluate(m_snapshot.data(), QStringLiteral("entries"));
    QJSValue savedImages = evaluate(m_snapshot.data(), QStringLiteral("viewerImages"));
    QVERIFY(savedEntries.isArray());
    QVERIFY(savedImages.isArray());
    m_snapshot->setProperty("metaJson", metaJson(5, QStringLiteral("viewer")));

    const QVariantMap state = m_snapshot->property("state").toMap();
    QCOMPARE(state.value(QStringLiteral("revision")).toInt(), 5);
    QCOMPARE(state.value(QStringLiteral("workspace")).toString(), QStringLiteral("viewer"));
    QCOMPARE(shownEntries().size(), kEntries);
    QCOMPARE(m_snapshot->property("viewerImages").toStringList().size(), kEntries);
    // `===` compares object identity for arrays: a re-parsed (or copied) listing
    // fails here, which is exactly the cost the split removes.
    QVERIFY2(evaluate(m_snapshot.data(), QStringLiteral("entries")).strictlyEquals(savedEntries),
             "a metadata-only snapshot replaced the listing array");
    QVERIFY2(evaluate(m_snapshot.data(), QStringLiteral("viewerImages"))
               .strictlyEquals(savedImages),
             "a metadata-only snapshot replaced the image list");
  }

  /// Moving the epoch does replace the listing, and the new one is spliced in.
  void aNewEpochReplacesTheListing()
  {
    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("a")));
    m_snapshot->setProperty("epoch", 1);
    m_snapshot->setProperty("metaJson", metaJson(4, QStringLiteral("browser")));
    const QJSValue first = evaluate(m_snapshot.data(), QStringLiteral("entries"));
    QCOMPARE(shownEntries().first().toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("a-0.jpg"));

    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("b")));
    m_snapshot->setProperty("epoch", 2);

    QCOMPARE(m_snapshot->property("state").toMap().value(QStringLiteral("revision")).toInt(), 4);
    QCOMPARE(shownEntries().first().toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("b-0.jpg"));
    QCOMPARE(m_snapshot->property("viewerImages").toStringList().first(),
             QStringLiteral("/photos/b-0.jpg"));
    QVERIFY2(!evaluate(m_snapshot.data(), QStringLiteral("entries")).strictlyEquals(first),
             "the new listing was not spliced in");
  }

  /// A listing that arrives after the metadata is still spliced in: the epoch
  /// can move before the string reaches QML, and dropping it would show an
  /// empty grid.
  void aListingThatArrivesAfterTheMetadataIsSplicedIn()
  {
    m_snapshot->setProperty("epoch", 3);
    m_snapshot->setProperty("metaJson", metaJson(7, QStringLiteral("browser")));
    QCOMPARE(shownEntries().size(), 0);

    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("late")));

    QCOMPARE(m_snapshot->property("state").toMap().value(QStringLiteral("revision")).toInt(), 7);
    QCOMPARE(shownEntries().size(), kEntries);
    QCOMPARE(shownEntries().first().toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("late-0.jpg"));
  }

  /// A snapshot that does not parse leaves the previous state on screen instead
  /// of blanking the window, and the next good one still lands.
  ///
  /// The two halves are refused independently: a metadata string the bridge
  /// should never send must not take the listing down with it, and a listing that
  /// is not the object the bridge promises must not replace a good one.
  void aBrokenSnapshotKeepsTheLastGoodState()
  {
    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("a")));
    m_snapshot->setProperty("epoch", 1);
    m_snapshot->setProperty("metaJson", metaJson(4, QStringLiteral("browser")));
    QCOMPARE(shownEntries().size(), kEntries);

    // Metadata that does not parse: the state stays exactly as it was.
    m_snapshot->setProperty("metaJson", QStringLiteral("{not json"));
    QCOMPARE(m_snapshot->property("state").toMap().value(QStringLiteral("revision")).toInt(), 4);
    QCOMPARE(shownEntries().size(), kEntries);

    // A listing that is not an object with two arrays is refused, and the good
    // listing — and the metadata that came with it — stay.
    m_snapshot->setProperty("metaJson", metaJson(5, QStringLiteral("viewer")));
    m_snapshot->setProperty("listingJson", QStringLiteral("[1,2,3]"));
    m_snapshot->setProperty("epoch", 2);
    QCOMPARE(m_snapshot->property("state").toMap().value(QStringLiteral("revision")).toInt(), 5);
    QCOMPARE(shownEntries().size(), kEntries);

    // The next good listing lands, with the metadata that was waiting for it.
    m_snapshot->setProperty("listingJson", listingJson(QStringLiteral("c")));
    m_snapshot->setProperty("epoch", 3);
    QCOMPARE(m_snapshot->property("state").toMap().value(QStringLiteral("revision")).toInt(), 5);
    QCOMPARE(shownEntries().first().toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("c-0.jpg"));
  }
};

} // namespace

QTEST_MAIN(TestStateSnapshot)
#include "tst_statesnapshot.moc"
