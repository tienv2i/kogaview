import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Browser's batch page: the three actions, and the job they started.
//
// The page does no work itself. It asks the view for a form (a size, a
// rectangle or a format is a question with a beginning and an end), and while
// Core's worker runs it draws the one count Core publishes: how many files are
// done, which one is being written, and a Cancel that stops the *job* rather
// than whichever file happens to be next.
ColumnLayout {
    id: root

    property Theme theme: Theme {}
    /// How many entries the Browser currently has selected. The page counts
    /// what it could act on, so a selected folder is not an image.
    property int selectionCount: 0
    /// Core's published job (`UiState.batch`), or null before the first one.
    /// `operation`, `total`, `done`, `failed`, `running`, `cancelled` and
    /// `current` are the worker's own fields.
    property var batch: null

    signal requestResize()
    signal requestCrop()
    signal requestConvert()
    signal requestCancel()

    readonly property var job: root.batch || null
    readonly property bool running: !!(root.job && root.job.running)
    readonly property bool finished: !!(root.job && !root.job.running)
    readonly property int total: root.job ? (root.job.total || 0) : 0
    readonly property int done: root.job ? (root.job.done || 0) : 0
    readonly property int failed: root.job ? (root.job.failed || 0) : 0

    /// The action's name as the progress line says it. Core publishes the
    /// stable key, never a sentence, so the page words it in the interface's
    /// own language.
    function operationLabel(name) {
        switch (name) {
        case "resize": return qsTr("Resize")
        case "crop": return qsTr("Crop")
        case "convert": return qsTr("Convert")
        default: return ""
        }
    }

    /// "12 of 40" while the job runs, and the outcome once it stops.
    function progressText() {
        if (!root.job) return ""
        var action = root.operationLabel(root.job.operation)
        if (root.running) {
            return qsTr("%1 · %2 of %3").arg(action).arg(root.done).arg(root.total)
        }
        if (root.job.cancelled) {
            return qsTr("%1 cancelled after %2 of %3").arg(action).arg(root.done).arg(root.total)
        }
        if (root.failed > 0) {
            return qsTr("%1 finished: %2 of %3, %4 failed")
                    .arg(action).arg(root.done).arg(root.total).arg(root.failed)
        }
        return qsTr("%1 finished: %2 of %3").arg(action).arg(root.done).arg(root.total)
    }

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

        // A running job owns the worker, so the buttons that would start a
        // second one wait. The selection is not frozen: a user may pick the
        // next folder while this job finishes.
        PanelAction {
            objectName: "batchResize"
            theme: root.theme
            Layout.fillWidth: true
            text: qsTr("Resize…")
            enabled: !root.running
            onClicked: root.requestResize()
        }
        PanelAction {
            objectName: "batchCrop"
            theme: root.theme
            Layout.fillWidth: true
            text: qsTr("Crop…")
            enabled: !root.running
            onClicked: root.requestCrop()
        }
        PanelAction {
            objectName: "batchConvert"
            theme: root.theme
            Layout.fillWidth: true
            text: qsTr("Convert…")
            enabled: !root.running
            onClicked: root.requestConvert()
        }
    }

    // ------------------------------------------------------------- progress
    ColumnLayout {
        objectName: "batchProgressArea"
        Layout.fillWidth: true
        visible: !!root.job
        spacing: 4

        Label {
            objectName: "batchProgressLabel"
            Layout.fillWidth: true
            text: root.progressText()
            color: root.running ? root.theme.text : root.theme.textMuted
            font.bold: root.running
            wrapMode: Text.WordWrap
        }

        // Drawn, not a stock `ProgressBar`: the style's light track is a pale
        // band on this dark page. `value`/`to` stay readable for the suite.
        Item {
            objectName: "batchProgress"
            Layout.fillWidth: true
            Layout.preferredHeight: 4
            visible: root.total > 0
            readonly property real to: Math.max(1, root.total)
            readonly property real value: root.done

            Rectangle {
                anchors.fill: parent
                radius: 2
                color: root.theme.border
            }
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * Math.min(1, parent.value / parent.to)
                radius: 2
                color: root.theme.accent
            }
        }

        Label {
            objectName: "batchCurrent"
            Layout.fillWidth: true
            visible: root.running && (root.job.current || "").length > 0
            text: root.job && root.job.current ? qsTr("Writing %1").arg(root.job.current) : ""
            color: root.theme.textMuted
            font.pixelSize: 11
            elide: Text.ElideMiddle
        }

        PanelAction {
            objectName: "batchCancel"
            theme: root.theme
            Layout.fillWidth: true
            visible: root.running
            text: qsTr("Cancel")
            onClicked: root.requestCancel()
        }
    }

    Label {
        objectName: "batchNote"
        Layout.fillWidth: true
        visible: !root.job
        text: root.selectionCount === 0
              ? qsTr("Select images first, or batch every image in the open folder from the form.")
              : qsTr("The source files are kept unless the form asks to replace them.")
        color: root.theme.textMuted
        font.pixelSize: 11
        wrapMode: Text.WordWrap
    }

    Item { Layout.fillHeight: true }
}
