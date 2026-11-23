import QtQuick

// The host the batch forms are tested in. Each batch dialog is a popup, so it
// needs a visual parent with a real size the way the window gives it one; this
// item is that parent. The suite loads `BatchResizeDialog.qml`,
// `BatchCropDialog.qml` and `BatchConvertDialog.qml` itself and reparents them
// here, so the host stays a plain item and knows nothing about the forms.
Item {
    objectName: "batchHost"
}
