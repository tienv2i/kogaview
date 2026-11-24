import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Interactive Read & Translate overlay for Viewer (`L` shortcut or menu).
///
/// Designed for manga / comics / documents with multiple text bubbles per page:
/// - Drag anywhere on the image to crop & translate a single speech bubble,
///   then immediately click "Next bubble" (or drag again) for the next frame.
/// - Click "Translate page" to scan & translate all text blocks on the page.
/// - Every translated bubble is kept in `bubbles` (cached per `imagePath`) and
///   drawn in-place over the canvas, with individual remove (`×`), Clear all,
///   Copy, Next bubble (`+`), and Close (`✕`) buttons.
Item {
    id: overlay
    objectName: "viewerTranslateOverlay"

    property Theme theme: Theme {}
    property bool active: false
    property string imagePath: ""
    property Item canvasItem: null
    property real zoom: 1.0
    property real offsetX: 0
    property real offsetY: 0
    property var aiTask: null

    signal translateRequested(string sourceLang, string targetLang, var region)
    signal copyTextRequested(string text)
    signal cancelRequested()
    signal closeRequested()

    visible: overlay.active
    anchors.fill: parent
    z: 18

    property bool showOverlayBoxes: true
    property var bubblesByPath: ({})
    property var currentBubbles: []
    property var latestResult: null
    property bool cardVisible: false
    property string _lastResultKey: ""

    readonly property bool busy: !!(overlay.aiTask && overlay.aiTask.running && overlay.aiTask.kind === "translate")

    function syncBubblesForPath() {
        var list = overlay.bubblesByPath[overlay.imagePath]
        overlay.currentBubbles = list ? list.slice() : []
        overlay.cardVisible = false
    }

    function clearPageBubbles() {
        var map = overlay.bubblesByPath
        map[overlay.imagePath] = []
        overlay.bubblesByPath = map
        overlay.currentBubbles = []
        overlay.latestResult = null
        overlay.cardVisible = false
    }

    function removeBubble(idx) {
        var list = overlay.currentBubbles.slice()
        if (idx < 0 || idx >= list.length) return
        list.splice(idx, 1)
        var map = overlay.bubblesByPath
        map[overlay.imagePath] = list
        overlay.bubblesByPath = map
        overlay.currentBubbles = list
    }

    onImagePathChanged: overlay.syncBubblesForPath()

    onAiTaskChanged: {
        var task = overlay.aiTask
        if (!task || task.running || !task.translation) return
        var tr = task.translation
        if (tr.path !== overlay.imagePath) return
        var key = tr.path + "|" + tr.translatedText + "|" + (tr.blocks ? tr.blocks.length : 0)
        if (key === overlay._lastResultKey) return
        overlay._lastResultKey = key

        var existing = overlay.currentBubbles.slice()
        var incoming = tr.blocks || []
        for (var i = 0; i < incoming.length; ++i) {
            existing.push(incoming[i])
        }
        var map = overlay.bubblesByPath
        map[overlay.imagePath] = existing
        overlay.bubblesByPath = map
        overlay.currentBubbles = existing
        overlay.latestResult = tr
        overlay.cardVisible = true
    }

    // --------------------------------------------------- Drag-to-select region
    property bool dragging: false
    property real dragStartX: 0
    property real dragStartY: 0
    property real dragEndX: 0
    property real dragEndY: 0

    readonly property real selX: Math.min(dragStartX, dragEndX)
    readonly property real selY: Math.min(dragStartY, dragEndY)
    readonly property real selW: Math.abs(dragEndX - dragStartX)
    readonly property real selH: Math.abs(dragEndY - dragStartY)

    MouseArea {
        id: dragArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.CrossCursor
        preventStealing: true
        enabled: overlay.active && !overlay.busy

        onPressed: function(mouse) {
            overlay.dragging = true
            overlay.dragStartX = mouse.x
            overlay.dragStartY = mouse.y
            overlay.dragEndX = mouse.x
            overlay.dragEndY = mouse.y
        }
        onPositionChanged: function(mouse) {
            if (!overlay.dragging) return
            overlay.dragEndX = Math.max(0, Math.min(overlay.width, mouse.x))
            overlay.dragEndY = Math.max(0, Math.min(overlay.height, mouse.y))
        }
        onReleased: {
            if (!overlay.dragging) return
            overlay.dragging = false
            if (overlay.selW < 8 || overlay.selH < 8 || !overlay.canvasItem) return
            var p1 = overlay.canvasItem.mapFromItem(overlay, overlay.selX, overlay.selY)
            var p2 = overlay.canvasItem.mapFromItem(overlay, overlay.selX + overlay.selW, overlay.selY + overlay.selH)
            var x = Math.round(Math.min(p1.x, p2.x))
            var y = Math.round(Math.min(p1.y, p2.y))
            var w = Math.round(Math.abs(p2.x - p1.x))
            var h = Math.round(Math.abs(p2.y - p1.y))
            if (w < 4 || h < 4) return
            overlay.translateRequested(sourceLangCombo.currentCode(), targetLangCombo.currentCode(), [x, y, w, h])
        }
        onCanceled: overlay.dragging = false
    }

    // Active drag selection rectangle
    Rectangle {
        visible: overlay.dragging && overlay.selW > 2 && overlay.selH > 2
        x: overlay.selX
        y: overlay.selY
        width: overlay.selW
        height: overlay.selH
        color: Qt.rgba(overlay.theme.accent.r, overlay.theme.accent.g, overlay.theme.accent.b, 0.18)
        border.width: 2
        border.color: overlay.theme.accent
        radius: 4
    }

    // --------------------------------------------------- In-place translated bubbles
    Repeater {
        model: overlay.showOverlayBoxes ? overlay.currentBubbles : []

        delegate: Rectangle {
            required property var modelData
            required property int index

            // Depend on zoom & offsetX/offsetY so boxes track pan/zoom live.
            readonly property var mapped: {
                var _z = overlay.zoom
                var _ox = overlay.offsetX
                var _oy = overlay.offsetY
                if (!overlay.canvasItem) return { x: 0, y: 0, w: 0, h: 0 }
                var tl = overlay.canvasItem.mapToItem(overlay, modelData.x, modelData.y)
                var br = overlay.canvasItem.mapToItem(overlay, modelData.x + modelData.w, modelData.y + modelData.h)
                return {
                    x: Math.min(tl.x, br.x),
                    y: Math.min(tl.y, br.y),
                    w: Math.max(48, Math.abs(br.x - tl.x)),
                    h: Math.max(24, Math.abs(br.y - tl.y))
                }
            }

            x: mapped.x
            y: mapped.y
            width: mapped.w
            height: Math.max(mapped.h, bubbleText.implicitHeight + 10)
            radius: 6
            color: Qt.rgba(overlay.theme.surface.r, overlay.theme.surface.g, overlay.theme.surface.b, 0.94)
            border.width: 1
            border.color: overlay.theme.accent

            Label {
                id: bubbleText
                anchors.fill: parent
                anchors.margins: 5
                anchors.rightMargin: 18
                text: modelData.translated || modelData.original || ""
                color: overlay.theme.text
                font.pixelSize: Math.max(10, Math.min(15, Math.round(mapped.h * 0.22)))
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            // Individual remove button for this bubble
            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 2
                width: 16
                height: 16
                radius: 8
                color: removeHover.hovered ? overlay.theme.danger : overlay.theme.surfaceAlt
                HoverHandler { id: removeHover }
                Text {
                    anchors.centerIn: parent
                    text: "×"
                    color: removeHover.hovered ? "#ffffff" : overlay.theme.textMuted
                    font.pixelSize: 11
                    font.bold: true
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: overlay.removeBubble(index)
                }
            }
        }
    }

    // --------------------------------------------------- Top floating translate bar
    Rectangle {
        id: topBar
        anchors.top: parent.top
        anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 24, barRow.implicitWidth + 20)
        height: 44
        radius: 10
        color: Qt.rgba(overlay.theme.surface.r, overlay.theme.surface.g, overlay.theme.surface.b, 0.95)
        border.width: 1
        border.color: overlay.theme.border
        z: 5

        MouseArea { anchors.fill: parent; preventStealing: true; z: -1 }

        RowLayout {
            id: barRow
            anchors.centerIn: parent
            spacing: 6

            ComboBox {
                id: sourceLangCombo
                implicitWidth: 92
                readonly property var codes: ["eng", "jpn", "chi_sim", "vie"]
                model: ["EN", "JA (Manga)", "ZH", "VI"]
                currentIndex: 0
                function currentCode() { return codes[currentIndex] || "eng" }
            }

            Label {
                text: "→"
                color: overlay.theme.textMuted
            }

            ComboBox {
                id: targetLangCombo
                implicitWidth: 74
                readonly property var codes: ["vi", "en", "ja"]
                model: ["VI", "EN", "JA"]
                currentIndex: 0
                function currentCode() { return codes[currentIndex] || "vi" }
            }

            PanelAction {
                theme: overlay.theme
                text: qsTr("Translate page")
                enabled: !overlay.busy && !!overlay.imagePath
                onClicked: overlay.translateRequested(sourceLangCombo.currentCode(), targetLangCombo.currentCode(), null)
            }

            PanelAction {
                theme: overlay.theme
                text: overlay.showOverlayBoxes ? qsTr("Hide overlay") : qsTr("Show overlay")
                visible: overlay.currentBubbles.length > 0
                onClicked: overlay.showOverlayBoxes = !overlay.showOverlayBoxes
            }

            PanelAction {
                theme: overlay.theme
                text: qsTr("Clear")
                visible: overlay.currentBubbles.length > 0
                onClicked: overlay.clearPageBubbles()
            }

            PanelAction {
                theme: overlay.theme
                text: qsTr("Cancel")
                visible: overlay.busy
                onClicked: overlay.cancelRequested()
            }

            PanelAction {
                objectName: "translateCloseButton"
                theme: overlay.theme
                text: qsTr("Close")
                onClicked: overlay.closeRequested()
            }
        }
    }

    // --------------------------------------------------- Bottom floating result card
    Rectangle {
        id: resultCard
        visible: overlay.cardVisible || overlay.busy
                 || !!(overlay.aiTask && overlay.aiTask.kind === "translate" && overlay.aiTask.error)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 32, 540)
        implicitHeight: cardCol.implicitHeight + 20
        radius: 10
        color: Qt.rgba(overlay.theme.surface.r, overlay.theme.surface.g, overlay.theme.surface.b, 0.96)
        border.width: 1
        border.color: overlay.theme.border
        z: 5

        MouseArea { anchors.fill: parent; preventStealing: true; z: -1 }

        ColumnLayout {
            id: cardCol
            anchors.fill: parent
            anchors.margins: 10
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                visible: overlay.busy
                spacing: 8
                Label {
                    text: overlay.aiTask ? overlay.aiTask.stage : qsTr("Translating…")
                    color: overlay.theme.text
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                ProgressBar {
                    implicitWidth: 120
                    from: 0
                    to: 100
                    value: overlay.aiTask ? overlay.aiTask.percent : 0
                }
            }

            Label {
                visible: !!(overlay.aiTask && !overlay.busy && overlay.aiTask.kind === "translate" && overlay.aiTask.error)
                text: overlay.aiTask && overlay.aiTask.error ? overlay.aiTask.error : ""
                color: overlay.theme.danger
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            Label {
                visible: !overlay.busy && !!(overlay.latestResult && overlay.latestResult.originalText)
                text: overlay.latestResult ? overlay.latestResult.originalText : ""
                color: overlay.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Label {
                visible: !overlay.busy && !!(overlay.latestResult && overlay.latestResult.translatedText)
                text: overlay.latestResult ? overlay.latestResult.translatedText : ""
                color: overlay.theme.text
                font.pixelSize: 14
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: !overlay.busy && !!overlay.latestResult

                PanelAction {
                    theme: overlay.theme
                    text: qsTr("Copy")
                    onClicked: {
                        if (overlay.latestResult && overlay.latestResult.translatedText) {
                            overlay.copyTextRequested(overlay.latestResult.translatedText)
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                PanelAction {
                    objectName: "translateNextBubbleButton"
                    theme: overlay.theme
                    primary: true
                    text: qsTr("Next bubble (+)")
                    onClicked: overlay.cardVisible = false
                }

                PanelAction {
                    theme: overlay.theme
                    text: qsTr("Close")
                    onClicked: overlay.closeRequested()
                }
            }
        }
    }
}
