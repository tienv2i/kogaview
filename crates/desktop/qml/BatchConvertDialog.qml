import QtQuick

/// Batch convert: one encoder for a whole set of images.
///
/// Its own dialog, with its own title. The format is the only option, the
/// quality appears only where an encoder reads one, and the suffix starts empty
/// because changing the extension is what keeps the copy from being the source.
BatchJobDialog {
    operation: "convert"
    title: qsTr("Batch convert")
}
