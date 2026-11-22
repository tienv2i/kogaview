import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The operations applied to the document, oldest first.
//
// Core owns the list and the undo/redo state; this panel only draws it. Each
// row is a `{ code, args }` line, so the words come from `UiLines` in the
// interface language rather than from Core.
Item {
    id: panel

    property Theme theme: Theme {}
    property var history: []
    property bool hasDocument: false
    /// The interface language, so a row is re-worded when Settings changes it.
    property string language: ""
    property string listObjectName: "historyList"

    /// The height the list needs to show every row. The Editor's reference dock
    /// is content-sized, so its History page asks for this instead of the
    /// viewport it happens to get; the dock clamps it to what the window can
    /// give.
    implicitHeight: historyList.contentHeight + 6
                    + (historyEmpty.visible ? historyEmpty.implicitHeight : 0)

    UiLines {
        id: uiLines
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        ListView {
            id: historyList
            objectName: panel.listObjectName
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: 220
            Layout.minimumHeight: 80
            clip: true
            model: panel.history
            spacing: 2
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: 26
                radius: panel.theme.radius
                color: "transparent"

                Label {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    objectName: "historyLine" + index
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    color: panel.theme.text
                    font.pixelSize: 12
                    text: (index + 1) + ". " + uiLines.text(modelData, panel.language)
                }
            }
        }

        Label {
            id: historyEmpty
            Layout.fillWidth: true
            visible: panel.history.length === 0
            text: panel.hasDocument ? qsTr("No edits yet") : qsTr("No image open")
            color: panel.theme.textMuted
            font.pixelSize: 11
        }
    }
}
