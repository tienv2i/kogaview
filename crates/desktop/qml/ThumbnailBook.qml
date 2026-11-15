import QtQuick

// Thumbnail bookkeeping shared by the grid, the preview panel and the filmstrip.
//
// The decoding and the files on disk belong to C++ (`ThumbnailCache`): it turns
// a 12 MP JPEG into one small file once. This object only answers "which url
// should this tile draw with, for this size and this version of the file", and
// remembers which keys failed so a broken image falls back to the original
// instead of being retried on every scroll.
//
// `cache` is null in the QML test harness and wherever the context object is
// missing; the views then decode the original as before.
QtObject {
    id: book

    property var cache: null
    /// key -> file url, filled by `thumbnailReady`.
    property var urls: ({})
    /// key -> true, filled by `thumbnailFailed`.
    property var failures: ({})
    /// A folder with thousands of images must not grow these maps without end.
    property int limit: 4000

    // Urls and failure marks belong to *one* cache object; a new one starts
    // from an empty book, which also re-asks it for everything on screen.
    onCacheChanged: book.reset()

    /// Bucketed so resizing the window does not mint a cache entry per pixel
    /// width; two cells of neighbouring sizes share one thumbnail. The argument
    /// is the drawn size in device-independent pixels, so the result is the
    /// edge to keep for a 2x screen.
    function edgeFor(width) {
        var wanted = Math.max(160, Math.ceil(width * 2));
        var buckets = [160, 256, 384, 512, 768];
        for (var index = 0; index < buckets.length; ++index) {
            if (wanted <= buckets[index]) return buckets[index];
        }
        return 768;
    }

    function keyFor(path, edge, modified, size) {
        if (!book.cache || !path) return "";
        return book.cache.keyFor(path, edge, modified || 0, size || 0);
    }

    /// The url to draw for this image, and the request for it.
    ///
    /// Views bind `Image.source` to this, which is what keeps them free of
    /// per-cell bookkeeping: a delegate recycled with another entry, a tile
    /// whose size bucket changed, or a cache object that only appears later all
    /// ask for exactly the thumbnail they are about to draw. Asking from a
    /// binding is safe because `ThumbnailCache::request` is idempotent and
    /// answers through a queued signal — an in-flight key is not started twice
    /// and nothing recurses.
    ///
    /// Empty while the thumbnail is being generated, so the tile shows its
    /// placeholder instead of decoding the original a second time.
    function url(path, edge, modified, size) {
        if (!path) return "";
        if (!book.cache) return "file://" + path;
        var key = book.keyFor(path, edge, modified, size);
        if (book.urls[key]) return book.urls[key];
        if (book.failures[key]) return "file://" + path;
        book.cache.request(path, edge, modified || 0, size || 0);
        return "";
    }

    function reset() {
        book.urls = ({});
        book.failures = ({});
    }

    function note(key, url) {
        var next = {};
        var kept = 0;
        for (var existing in book.urls) {
            if (kept >= book.limit) break;
            next[existing] = book.urls[existing];
            ++kept;
        }
        next[key] = url;
        book.urls = next;
    }

    function noteFailure(key) {
        var next = {};
        for (var existing in book.failures) next[existing] = true;
        next[key] = true;
        book.failures = next;
    }

    // Held as a property: `QtObject` has no default child list, and `Connections`
    // is not an Item so it cannot be dropped into a layout.
    property Connections cacheSignals: Connections {
        target: book.cache
        ignoreUnknownSignals: true
        function onThumbnailReady(key, url) { book.note(key, url) }
        function onThumbnailFailed(key) { book.noteFailure(key) }
    }
}
