import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The file's details, shared by the three workspaces.
//
// The Browser and the Viewer describe the selection (`SelectionInfo`): a name,
// a kind, a size, the pixel dimensions when it is an image, the modification
// time and the path. The Editor describes its working document instead, where
// the interesting rows are the size it is now, whether the pixels are on disk
// and where a save would write. Both shapes live here so the three views draw
// the same words, and so the Browser and the Viewer agree on what a file's
// details look like.
ColumnLayout {
    id: panel

    property Theme theme: Theme {}

    /// A `SelectionInfo` (Browser, Viewer). The block below is shown while
    /// `editor` is null.
    property var info: null
    /// An `EditorState` (Editor). When set, this block wins.
    property var editor: null
    /// A section title above the rows; empty means none. The Editor draws the
    /// name under its own "Image" heading, the Viewer names the panel.
    property string heading: ""
    /// True while the Editor has pixels to edit; a document that is still
    /// opening publishes a zero size and no name worth showing.
    property bool hasDocument: false
    /// The Editor's own size line: a resize changes the working document
    /// while the file on disk still has its old dimensions.
    property string sizeText: ""
    property bool saving: false

    spacing: 8

    Label {
        Layout.fillWidth: true
        visible: panel.heading !== ""
        text: panel.heading
        color: panel.theme.text
        font.bold: true
    }

    // ------------------------------------------------------------ document
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: panel.editor !== null

        Label {
            objectName: "imageHeading"
            text: qsTr("Image")
            color: panel.theme.text
            font.bold: true
        }

        Label {
            Layout.fillWidth: true
            objectName: "imageName"
            text: {
                if (panel.editor === null) return "—"
                var name = panel.editor.name || ""
                return panel.hasDocument && panel.editor.modified
                        ? name + " · " + qsTr("edited") : name
            }
            color: panel.theme.text
            elide: Text.ElideMiddle
        }

        Label {
            Layout.fillWidth: true
            objectName: "imageSize"
            text: panel.hasDocument && panel.sizeText !== "" ? panel.sizeText : "—"
            color: panel.theme.textMuted
        }

        Label {
            Layout.fillWidth: true
            objectName: "saveTarget"
            text: {
                if (panel.editor === null || !panel.hasDocument) return "—"
                var where = panel.editor.savePath || panel.editor.path || ""
                var name = where.split("/").pop()
                var style = panel.editor.format ? " (" + panel.editor.format + ")" : ""
                var state = panel.editor.saved ? qsTr("saved") : qsTr("unsaved changes")
                return name + style + " · " + state
            }
            color: panel.editor !== null && panel.editor.saved
                   ? panel.theme.textMuted : panel.theme.accent
            font.pixelSize: 11
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            BusyIndicator {
                Layout.preferredWidth: 18
                Layout.preferredHeight: 18
                running: panel.saving
                visible: running
            }
            Label {
                Layout.fillWidth: true
                text: qsTr("Saving…")
                visible: panel.saving
                color: panel.theme.textMuted
                font.pixelSize: 11
            }
        }
    }

    // ----------------------------------------------------------- selection
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: panel.editor === null

        Label {
            Layout.fillWidth: true
            objectName: "infoName"
            text: panel.info ? panel.info.name : "—"
            color: panel.theme.text
            font.bold: true
            elide: Text.ElideMiddle
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 10
            rowSpacing: 4

            Label { text: qsTr("Type"); color: panel.theme.textMuted; font.pixelSize: 12 }
            Label {
                objectName: "infoKind"
                text: panel.info ? panel.info.kind : "—"
                color: panel.theme.text
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Label { text: qsTr("Size"); color: panel.theme.textMuted; font.pixelSize: 12 }
            Label {
                objectName: "infoSize"
                text: panel.info ? panel.theme.formatBytes(panel.info.size) : "—"
                color: panel.theme.text
            }

            Label { text: qsTr("Dimensions"); color: panel.theme.textMuted; font.pixelSize: 12 }
            Label {
                objectName: "infoDimensions"
                text: (panel.info && panel.info.width)
                      ? (panel.info.width + " × " + panel.info.height) : "—"
                color: panel.theme.text
            }

            Label { text: qsTr("Modified"); color: panel.theme.textMuted; font.pixelSize: 12 }
            Label {
                objectName: "infoModified"
                text: panel.info ? panel.theme.formatDate(panel.info.modified) : "—"
                color: panel.theme.text
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        Label {
            text: qsTr("Path")
            color: panel.theme.textMuted
            font.pixelSize: 12
        }
        Label {
            Layout.fillWidth: true
            objectName: "infoPath"
            text: panel.info ? panel.info.path : "—"
            color: panel.theme.text
            font.pixelSize: 11
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 4
            elide: Text.ElideRight
        }
    }
}
