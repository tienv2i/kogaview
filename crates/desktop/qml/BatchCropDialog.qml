import QtQuick

/// Batch crop: one proportional rectangle, trimmed from every image.
///
/// Its own dialog, with its own title. The rectangle is a percentage of each
/// image's own sides — a folder of mixed sizes has no single pixel rectangle —
/// so the fields read `%` and the sentence under them says so.
BatchJobDialog {
    operation: "crop"
    title: qsTr("Batch crop")
}
