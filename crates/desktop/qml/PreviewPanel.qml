import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A picture in the frame the grid uses, shared by the Browser's sidebar and the
// Editor's Original tab.
//
// The image comes from the thumbnail cache (`ThumbnailBook` + `CachedThumbnail`),
// so the panel asks for the size it draws and the cache decides whether to
// decode; the path alone is not an identity, which is why `modified` and
// `fileSize` travel with it.
ColumnLayout {
    id: panel

    property Theme theme: Theme {}
    /// The `ThumbnailBook` the grid shares; null in the QML harness, where the
    /// original file is drawn instead.
    property var book: null
    property string path: ""
    property bool thumbnailable: true
    /// Identity of the file behind `path`: a path repeats after a save or on
    /// the next run, these two numbers do not.
    property real modified: 0
    property real fileSize: 0
    /// A section title above the frame; empty means none.
    property string heading: ""
    property string caption: ""
    property string captionObjectName: "previewCaption"
    property string thumbnailObjectName: "previewThumbnail"
    property string placeholder: qsTr("No image preview")

    spacing: 8

    Label {
        Layout.fillWidth: true
        visible: panel.heading !== ""
        text: panel.heading
        color: panel.theme.textMuted
        font.bold: true
        font.pixelSize: 12
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(230, width * 0.72)
        radius: panel.theme.radius
        color: panel.theme.thumb
        clip: true

        CachedThumbnail {
            objectName: panel.thumbnailObjectName
            anchors.fill: parent
            anchors.margins: 4
            book: panel.book
            path: panel.path
            thumbnailable: panel.thumbnailable
            modified: panel.modified
            fileSize: panel.fileSize
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.ceil(width * 2)
            sourceSize.height: Math.ceil(height * 2)
        }

        Label {
            anchors.centerIn: parent
            visible: !panel.thumbnailable || panel.path === ""
            text: panel.placeholder
            color: panel.theme.textMuted
        }
    }

    Label {
        Layout.fillWidth: true
        objectName: panel.captionObjectName
        visible: panel.caption !== ""
        text: panel.caption
        color: panel.theme.textMuted
        font.pixelSize: 11
        elide: Text.ElideMiddle
    }
}
