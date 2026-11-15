import QtQuick

/// One thumbnail that the cache owns and the cache updates.
///
/// The cache answers by calling `setThumbnail(key, url)` on the very object that
/// asked (see `ThumbnailCache::request`). That is why this is a component rather
/// than a binding over a shared "all thumbnails" map: a targeted callback costs
/// one property write, while a shared map re-evaluates every tile on screen each
/// time a single thumbnail finishes — on a folder with a thousand images that is
/// tens of thousands of needless lookups per scroll.
///
/// `source` is empty until the thumbnail exists, so the view shows its
/// placeholder instead of decoding the original a second time.
Image {
    id: thumb

    /// The `ThumbnailBook` that owns the size buckets and the cache object.
    property var book: null
    property string path: ""
    /// Key components; `real` because a file's mtime is far past 32 bits.
    property real modified: 0
    property real fileSize: 0
    /// False for folders and for entries that are not images at all.
    property bool thumbnailable: true

    /// The url the cache answered with; empty while it is being produced.
    property string resolved: ""

    readonly property bool cached: book !== null && book.cache !== null
    readonly property string fallbackSource: path !== "" ? "file://" + path : ""
    /// Drawn size in device-independent pixels, so the bucket is right on a 2x
    /// screen. Zero until the tile is laid out: asking before that would mint a
    /// thumbnail for a size nothing will ever draw.
    readonly property int edge: book !== null ? book.edgeFor(Math.max(width, height)) : 0
    readonly property string cacheKey: (cached && thumbnailable && path !== ""
                                        && width > 0 && height > 0)
                                       ? book.keyFor(path, edge, modified, fileSize) : ""

    /// Called by the cache, for exactly this tile.
    function setThumbnail(key, url) {
        if (key !== thumb.cacheKey) {
            return;  // recycled onto another entry while this one was queued
        }
        // An empty url means the source could not be decoded into a thumbnail;
        // drawing the original is still better than drawing nothing.
        thumb.resolved = url !== "" ? url : thumb.fallbackSource;
    }

    onCacheKeyChanged: {
        thumb.resolved = "";
        if (thumb.cacheKey !== "") {
            settle.restart();
        }
    }

    /// The key settles over several property assignments — the caller sets the
    /// path, then the version and size it came with, and the tile only gets its
    /// drawn size once it is laid out. Asking on the first change would ask once
    /// per step and mint a thumbnail for a key nothing will ever draw, so ask
    /// once, after the dust settles.
    Timer {
        id: settle
        interval: 0
        onTriggered: {
            if (thumb.cacheKey !== "") {
                book.request(thumb, path, edge, modified, fileSize);
            }
        }
    }

    asynchronous: true
    cache: false
    fillMode: Image.PreserveAspectFit
    source: thumb.cached ? thumb.resolved : thumb.fallbackSource
}
