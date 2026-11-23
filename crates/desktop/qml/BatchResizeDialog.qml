import QtQuick

/// Batch resize: one size for a whole set of images.
///
/// Its own dialog, with its own title, so the form a user opens is the action
/// they picked: the size fields at the top and nothing about formats or
/// rectangles. Where the images come from and where the results go is the part
/// the three batch dialogs share (`BatchJobDialog.qml`).
BatchJobDialog {
    operation: "resize"
    title: qsTr("Batch resize")
}
