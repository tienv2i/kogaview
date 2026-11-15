import QtQuick

// Thumbnail bookkeeping shared by the grid, the preview panel and the filmstrip.
//
// The decoding, the files on disk and the answer to each tile belong to C++
// (`ThumbnailCache`). This object only owns the policy the views share: which
// size bucket a drawn size maps to, and the key that pins a tile to one entry.
//
// There is deliberately no "key -> url" map here. Such a map has to be a
// property to be observable, and reassigning it invalidates every binding that
// read it — so one finished thumbnail re-evaluated every tile on screen, and a
// folder of a thousand images turned a scroll into tens of thousands of
// lookups. Instead each tile is answered directly through `CachedThumbnail`.
QtObject {
    id: book

    property var cache: null

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

    /// Ask for the thumbnail on behalf of `requester`, which the cache calls back
    /// through its own `setThumbnail(key, url)`.
    function request(requester, path, edge, modified, size) {
        if (!book.cache || !requester || !path || edge <= 0) return;
        book.cache.request(requester, path, edge, modified || 0, size || 0);
    }
}
