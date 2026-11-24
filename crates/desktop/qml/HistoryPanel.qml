import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Interactive Undo/Redo history list.
//
// Shows Original (step 0), all applied undo steps (1..N), and dimmed redo
// steps (N+1..M). Clicking any row jumps directly to that exact step via
// `jumpRequested(targetIndex)`.
Item {
    id: panel

    property Theme theme: Theme {}
    property var history: []
    property var redoHistory: []
    property bool hasDocument: false
    property bool historyTrimmed: false
    /// The interface language, so a row is re-worded when Settings changes it.
    property string language: ""
    property string listObjectName: "historyList"

    signal jumpRequested(int targetIndex)
    signal resetRequested()

    readonly property var combinedRows: {
        var rows = []
        if (!panel.hasDocument) return rows
        var applied = panel.history || []
        var redo = panel.redoHistory || []
        if (applied.length === 0 && redo.length === 0) return rows
        rows.push({
            targetIndex: 0,
            label: panel.historyTrimmed ? qsTr("History start (trimmed)") : qsTr("Original"),
            isCurrent: applied.length === 0,
            isRedo: false,
            rawLine: null
        })
        for (var i = 0; i < applied.length; ++i) {
            rows.push({
                targetIndex: i + 1,
                label: "",
                isCurrent: i === applied.length - 1,
                isRedo: false,
                rawLine: applied[i]
            })
        }
        for (var j = 0; j < redo.length; ++j) {
            rows.push({
                targetIndex: applied.length + j + 1,
                label: "",
                isCurrent: false,
                isRedo: true,
                rawLine: redo[j]
            })
        }
        return rows
    }

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
            Layout.minimumHeight: 40
            clip: true
            model: panel.combinedRows
            spacing: 2
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Rectangle {
                id: hRow
                required property var modelData
                required property int index
                width: ListView.view ? ListView.view.width : 200
                height: 26
                radius: panel.theme.radius
                color: modelData.isCurrent ? panel.theme.selection
                     : hMouse.containsMouse ? panel.theme.hover
                     : "transparent"
                border.width: modelData.isCurrent ? 1 : 0
                border.color: panel.theme.accent

                MouseArea {
                    id: hMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!hRow.modelData.isCurrent) {
                            panel.jumpRequested(hRow.modelData.targetIndex)
                        }
                    }
                }

                Label {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    objectName: "historyLine" + index
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    color: hRow.modelData.isRedo ? panel.theme.textMuted : panel.theme.text
                    opacity: hRow.modelData.isRedo ? 0.65 : 1.0
                    font.pixelSize: 12
                    font.bold: hRow.modelData.isCurrent
                    font.italic: hRow.modelData.isRedo
                    text: hRow.modelData.rawLine
                        ? (hRow.modelData.targetIndex + ". " + uiLines.text(hRow.modelData.rawLine, panel.language))
                        : ("0. " + hRow.modelData.label)
                }
            }
        }

        Label {
            id: historyEmpty
            Layout.fillWidth: true
            visible: panel.combinedRows.length === 0
            text: panel.hasDocument ? qsTr("No edits yet") : qsTr("No image open")
            color: panel.theme.textMuted
            font.pixelSize: 11
        }

        PanelAction {
            objectName: "historyResetOriginalBtn"
            Layout.fillWidth: true
            visible: panel.hasDocument && (panel.combinedRows.length > 0 || panel.historyTrimmed)
            theme: panel.theme
            text: qsTr("Reset to original")
            ToolTip.visible: hovered
            ToolTip.text: qsTr("Discard all edits and restore the original opened image")
            onClicked: panel.resetRequested()
        }
    }
}
