import QtQuick

/// The one authoritative state snapshot the window renders.
///
/// The bridge publishes it as two strings because they change at wildly
/// different rates:
///
/// - `metaJson` — everything a Browser or Viewer paints: workspace, folders,
///   selection, counts, status. Around a kilobyte, and it has **no** listing
///   fields at all.
/// - `listingJson` — the folder listing alone: the entries the grid draws and
///   the image paths the filmstrip draws. ~200 bytes per item, so a thousand
///   photos is a 200 KB string, and it changes only when the folder does.
///
/// Parsing the listing once per `epoch` and keeping the resulting array means a
/// `select` — every click and every arrow key in the grid — costs one small
/// parse instead of a 200 KB one, and the views keep the *same* array object, so
/// a change that did not touch the listing cannot rebuild a delegate. Rebuilding
/// the whole snapshot on every command is what made a big folder feel heavy.
QtObject {
    id: snapshot
    objectName: "snapshot"

    /// Metadata snapshot JSON, without the folder listing.
    property string metaJson: ""
    /// Folder listing JSON: `{ "entries": [...], "viewerImages": [...] }`.
    property string listingJson: "{\"entries\":[],\"viewerImages\":[]}"
    /// Moves when `listingJson` does. Anything else means "keep what you have".
    property int epoch: -1

    /// The parsed metadata: everything the window paints except the listing.
    /// Replaced only when the metadata changes, so its bindings re-evaluate on a
    /// command and its listing bindings do not.
    property var state: ({})
    /// The parsed listing, as plain arrays. Replaced only when the epoch (or the
    /// listing string itself) moves.
    property var entries: []
    property var viewerImages: []

    /// Epoch of the listing currently held in `entries`/`viewerImages`.
    property int loadedEpoch: -1
    /// The `listingJson` the listing was parsed from. The epoch alone is not
    /// enough: it can land before the listing string does, and a listing that
    /// arrives second must still be spliced in.
    property string loadedListing: ""

    // The two halves arrive in whichever order the bridge emits them, so each of
    // them may be the one that completes the snapshot. `apply()` itself refuses
    // anything it cannot parse.
    onMetaJsonChanged: snapshot.apply()
    onListingJsonChanged: snapshot.apply()
    onEpochChanged: snapshot.apply()

    /// Re-assemble the snapshot from the current strings.
    ///
    /// Returns false — and leaves everything as it was — when either string does
    /// not parse or does not carry the shape the bridge promises, so a broken
    /// snapshot can never blank the window. The two halves are refused apart: a
    /// metadata string that is broken does not throw away a good listing, and a
    /// broken listing does not hold back a good metadata.
    function apply(): bool {
        if (!snapshot.metaJson) return false;
        var meta = null;
        try {
            meta = JSON.parse(snapshot.metaJson);
        } catch (error) {
            console.warn("KogaView: cannot parse state snapshot:", error);
            return false;
        }
        if (!meta || typeof meta !== "object") {
            return false;
        }
        var listing = null;
        var replace = snapshot.loadedEpoch !== snapshot.epoch
                || snapshot.loadedListing !== snapshot.listingJson;
        if (replace) {
            try {
                listing = JSON.parse(snapshot.listingJson);
            } catch (error) {
                console.warn("KogaView: cannot parse the folder listing:", error);
                return false;
            }
            if (!listing || !Array.isArray(listing.entries)
                    || !Array.isArray(listing.viewerImages)) {
                return false;
            }
        }
        // Both halves parsed: publish them. Assigning the arrays, not copying
        // them, is what lets an unchanged listing keep its identity.
        if (replace) {
            snapshot.entries = listing.entries;
            snapshot.viewerImages = listing.viewerImages;
            snapshot.loadedEpoch = snapshot.epoch;
            snapshot.loadedListing = snapshot.listingJson;
        }
        snapshot.state = meta;
        return true;
    }
}
