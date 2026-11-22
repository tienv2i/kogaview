import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Browser's batch page.
//
// This pass adds the surface and the honest empty state, not a batch engine:
// the buttons are here so the shape of the answer is visible, and they stay
// disabled until Core owns a batch command. The selection count is already
// real — it reads the Browser's own selection — so the page is not a mock.
ColumnLayout {
    id: root

    property Theme theme: Theme {}
    /// How many entries the Browser currently has selected.
    property int selectionCount: 0

    spacing: 10

    Label {
        objectName: "batchHeading"
        Layout.fillWidth: true
        text: qsTr("Batch action")
        color: root.theme.text
        font.bold: true
        font.pixelSize: 13
    }

    Label {
        objectName: "batchSelection"
        Layout.fillWidth: true
        text: root.selectionCount === 0
              ? qsTr("No images selected")
              : qsTr("%1 selected").arg(root.selectionCount)
        color: root.selectionCount === 0 ? root.theme.textMuted : root.theme.text
        wrapMode: Text.WordWrap
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 1
        rowSpacing: 6

        Button {
            objectName: "batchResize"
            Layout.fillWidth: true
            text: qsTr("Resize…")
            enabled: false
            focusPolicy: Qt.NoFocus
        }
        Button {
            objectName: "batchConvert"
            Layout.fillWidth: true
            text: qsTr("Convert…")
            enabled: false
            focusPolicy: Qt.NoFocus
        }
        Button {
            objectName: "batchExport"
            Layout.fillWidth: true
            text: qsTr("Export…")
            enabled: false
            focusPolicy: Qt.NoFocus
        }
    }

    Label {
        objectName: "batchNote"
        Layout.fillWidth: true
        text: qsTr("Batch actions are not available yet.")
        color: root.theme.textMuted
        font.pixelSize: 11
        wrapMode: Text.WordWrap
    }

    Item { Layout.fillHeight: true }
}
