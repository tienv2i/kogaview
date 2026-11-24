import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Interactive Read & Translate / Region OCR overlay for Viewer (`L` shortcut or menu).
///
/// Follows `docs/UI-DESIGN-SYSTEM.md`:
/// - `12 px` outer panel inset, `8–10 px` section spacing, `6 px` row spacing
/// - Zero hardcoded colors (all bound to `overlay.theme.*`)
/// - `focusPolicy: Qt.NoFocus` on buttons/combos so Viewer keyboard shortcuts stay intact
/// - Supports 2 modes: `translate` (OCR + Google Translate) and `ocr` (100% offline OCR)
/// - Supports 5 languages: English, Japanese (horizontal + vertical manga), Vietnamese,
///   Chinese, and Korean with explicit Input / Output ComboBoxes and quick swap (`⇄`).
Item {
    id: overlay
    objectName: "viewerTranslateOverlay"

    property Theme theme: Theme {}
    property bool active: false
    property string overlayMode: "translate" // "translate" | "ocr"
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
    property bool translucentBubbles: false
    property var bubblesByPath: ({})
    property var currentBubbles: []
    property var latestResult: null
    property var lastRegion: null
    property bool cardVisible: false
    property string _lastResultKey: ""

    readonly property bool isOcrMode: overlay.overlayMode === "ocr"
    readonly property bool busy: !!(overlay.aiTask && overlay.aiTask.running && overlay.aiTask.kind === "translate")

    // Language tables (5 languages: EN, JA + JA Vertical Manga, VI, ZH, KO)
    readonly property var sourceLangCodes: ["eng", "jpn", "jpn_vert", "vie", "chi_sim", "kor"]
    readonly property var targetLangCodes: ["vi", "en", "ja", "zh-CN", "ko"]

    function sourceCode() {
        return overlay.sourceLangCodes[sourceLangCombo.currentIndex] || "eng"
    }
    function targetCode() {
        return overlay.isOcrMode ? "" : (overlay.targetLangCodes[targetLangCombo.currentIndex] || "vi")
    }
    function swapLanguages() {
        var srcToTgt = { "eng": 1, "jpn": 2, "jpn_vert": 2, "vie": 0, "chi_sim": 3, "kor": 4 }
        var tgtToSrc = { "vi": 3, "en": 0, "ja": 1, "zh-CN": 4, "ko": 5 }
        var curSrc = overlay.sourceCode()
        var curTgt = overlay.targetLangCodes[targetLangCombo.currentIndex] || "vi"
        var nextSrcIdx = tgtToSrc[curTgt]
        var nextTgtIdx = srcToTgt[curSrc]
        if (nextSrcIdx !== undefined) sourceLangCombo.currentIndex = nextSrcIdx
        if (nextTgtIdx !== undefined) targetLangCombo.currentIndex = nextTgtIdx
    }

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
        overlay.lastRegion = null
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

    function moveBubble(idx, newImgX, newImgY) {
        var list = overlay.currentBubbles.slice()
        if (idx < 0 || idx >= list.length) return
        var old = list[idx]
        list[idx] = {
            x: Math.round(newImgX),
            y: Math.round(newImgY),
            w: old.w,
            h: old.h,
            original: old.original,
            translated: old.translated
        }
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
        var key = tr.path + "|" + (tr.originalText || "") + "|" + (tr.translatedText || "") + "|" + (tr.blocks ? tr.blocks.length : 0)
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
            overlay.lastRegion = [x, y, w, h]
            overlay.translateRequested(overlay.sourceCode(), overlay.targetCode(), overlay.lastRegion)
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
        color: Qt.rgba(overlay.theme.accent.r, overlay.theme.accent.g, overlay.theme.accent.b, 0.16)
        border.width: 2
        border.color: overlay.theme.accent
        radius: 6
    }

    // --------------------------------------------------- In-place draggable translated / OCR bubbles
    Repeater {
        model: overlay.showOverlayBoxes ? overlay.currentBubbles : []

        delegate: Rectangle {
            id: bubbleRect
            required property var modelData
            required property int index

            property real dragDx: 0
            property real dragDy: 0
            property bool moving: false

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
                    w: Math.max(96, Math.abs(br.x - tl.x)),
                    h: Math.max(48, Math.abs(br.y - tl.y))
                }
            }

            x: mapped.x + dragDx
            y: mapped.y + dragDy
            width: mapped.w
            height: Math.max(mapped.h, bubbleText.implicitHeight + 44)
            z: moving ? 4 : 2
            radius: 8
            color: Qt.rgba(overlay.theme.surface.r, overlay.theme.surface.g, overlay.theme.surface.b,
                           overlay.translucentBubbles ? 0.80 : 0.95)
            border.width: moving ? 2 : 1
            border.color: overlay.theme.accent
            clip: true

            // Top drag-handle bar: drag here to move bubble without blocking text selection below
            Rectangle {
                id: bubbleHeader
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 24
                color: Qt.rgba(overlay.theme.surfaceAlt.r, overlay.theme.surfaceAlt.g, overlay.theme.surfaceAlt.b, 0.9)

                MouseArea {
                    id: bubbleDragArea
                    anchors.fill: parent
                    anchors.rightMargin: 28
                    acceptedButtons: Qt.LeftButton
                    preventStealing: true
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                    property real startScreenX: 0
                    property real startScreenY: 0

                    onPressed: function(mouse) {
                        var pt = bubbleHeader.mapToItem(overlay, mouse.x, mouse.y)
                        startScreenX = pt.x
                        startScreenY = pt.y
                        bubbleRect.dragDx = 0
                        bubbleRect.dragDy = 0
                        bubbleRect.moving = true
                    }
                    onPositionChanged: function(mouse) {
                        if (!bubbleRect.moving) return
                        var pt = bubbleHeader.mapToItem(overlay, mouse.x, mouse.y)
                        bubbleRect.dragDx = pt.x - startScreenX
                        bubbleRect.dragDy = pt.y - startScreenY
                    }
                    onReleased: {
                        if (!bubbleRect.moving) return
                        bubbleRect.moving = false
                        var dx = bubbleRect.dragDx
                        var dy = bubbleRect.dragDy
                        bubbleRect.dragDx = 0
                        bubbleRect.dragDy = 0
                        if ((Math.abs(dx) > 1 || Math.abs(dy) > 1) && overlay.canvasItem) {
                            var newTopLeft = overlay.canvasItem.mapFromItem(
                                overlay,
                                bubbleRect.mapped.x + dx,
                                bubbleRect.mapped.y + dy
                            )
                            overlay.moveBubble(index, newTopLeft.x, newTopLeft.y)
                        }
                    }
                    onCanceled: {
                        bubbleRect.moving = false
                        bubbleRect.dragDx = 0
                        bubbleRect.dragDy = 0
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    text: "⋮⋮"
                    color: overlay.theme.textMuted
                    font.pixelSize: 10
                    opacity: 0.8
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    width: 18
                    height: 18
                    radius: 9
                    z: 2
                    color: removeHover.hovered ? overlay.theme.danger : "transparent"
                    HoverHandler { id: removeHover }
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: removeHover.hovered ? overlay.theme.surface : overlay.theme.textMuted
                        font.pixelSize: 12
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        onClicked: overlay.removeBubble(index)
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: overlay.theme.border
                }
            }

            // Selectable read-only text inside the bubble (Ctrl+C copies selection)
            TextEdit {
                id: bubbleText
                anchors.top: bubbleHeader.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.topMargin: 8
                anchors.bottomMargin: 10
                readOnly: true
                selectByMouse: true
                text: modelData.translated || modelData.original || ""
                color: overlay.theme.text
                selectionColor: overlay.theme.accent
                selectedTextColor: overlay.theme.accentText
                font.pixelSize: Math.max(11, Math.min(15, Math.round(mapped.h * 0.22)))
                wrapMode: TextEdit.WordWrap
                horizontalAlignment: TextEdit.AlignHCenter
                verticalAlignment: TextEdit.AlignVCenter
                Keys.onEscapePressed: focus = false
            }
        }
    }

    // --------------------------------------------------- Top floating bar (14 px inset, responsive Flow)
    Rectangle {
        id: topBar
        anchors.top: parent.top
        anchors.topMargin: 14
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 28, barFlow.implicitWidth + 28)
        height: barFlow.implicitHeight + 20
        radius: 10
        color: Qt.rgba(overlay.theme.surface.r, overlay.theme.surface.g, overlay.theme.surface.b, 0.96)
        border.width: 1
        border.color: overlay.theme.border
        z: 5

        MouseArea { anchors.fill: parent; preventStealing: true; z: -1 }

        Flow {
            id: barFlow
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            anchors.topMargin: 10
            anchors.bottomMargin: 10
            spacing: 10

            // Group 1: Mode switcher (Translate vs Offline OCR)
            Row {
                spacing: 4
                height: 30
                PanelAction {
                    objectName: "translateModeBtn"
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: qsTr("Translate")
                    primary: !overlay.isOcrMode
                    onClicked: overlay.overlayMode = "translate"
                }
                PanelAction {
                    objectName: "ocrModeBtn"
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: qsTr("OCR only")
                    primary: overlay.isOcrMode
                    onClicked: overlay.overlayMode = "ocr"
                }
            }

            Rectangle {
                width: 1
                height: 24
                color: overlay.theme.border
            }

            // Group 2: Explicit Input & Output language ComboBoxes + Swap
            Row {
                spacing: 6
                height: 30

                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("From:")
                    color: overlay.theme.textMuted
                    font.pixelSize: 12
                }

                ComboBox {
                    id: sourceLangCombo
                    objectName: "translateSourceLang"
                    anchors.verticalCenter: parent.verticalCenter
                    focusPolicy: Qt.NoFocus
                    implicitWidth: 136
                    model: [
                        qsTr("English"),
                        qsTr("Japanese"),
                        qsTr("Japanese (Vertical)"),
                        qsTr("Vietnamese"),
                        qsTr("Chinese"),
                        qsTr("Korean")
                    ]
                    currentIndex: 0
                }

                PanelAction {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !overlay.isOcrMode
                    theme: overlay.theme
                    text: "⇄"
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Swap languages")
                    onClicked: overlay.swapLanguages()
                }

                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !overlay.isOcrMode
                    text: qsTr("To:")
                    color: overlay.theme.textMuted
                    font.pixelSize: 12
                }

                ComboBox {
                    id: targetLangCombo
                    objectName: "translateTargetLang"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !overlay.isOcrMode
                    focusPolicy: Qt.NoFocus
                    implicitWidth: 112
                    model: [
                        qsTr("Vietnamese"),
                        qsTr("English"),
                        qsTr("Japanese"),
                        qsTr("Chinese"),
                        qsTr("Korean")
                    ]
                    currentIndex: 0
                }
            }

            Rectangle {
                width: 1
                height: 24
                color: overlay.theme.border
            }

            // Group 3: Page action, overlay controls, and Close
            Row {
                spacing: 6
                height: 30

                PanelAction {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: overlay.isOcrMode ? qsTr("Scan page") : qsTr("Translate page")
                    enabled: !overlay.busy && !!overlay.imagePath
                    onClicked: {
                        overlay.lastRegion = null
                        overlay.translateRequested(overlay.sourceCode(), overlay.targetCode(), null)
                    }
                }

                PanelAction {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: overlay.showOverlayBoxes ? qsTr("Hide overlay") : qsTr("Show overlay")
                    visible: overlay.currentBubbles.length > 0
                    onClicked: overlay.showOverlayBoxes = !overlay.showOverlayBoxes
                }

                PanelAction {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: overlay.translucentBubbles ? qsTr("Solid") : qsTr("Frosted")
                    visible: overlay.currentBubbles.length > 0 && overlay.showOverlayBoxes
                    onClicked: overlay.translucentBubbles = !overlay.translucentBubbles
                }

                PanelAction {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: qsTr("Clear")
                    visible: overlay.currentBubbles.length > 0
                    onClicked: overlay.clearPageBubbles()
                }

                PanelAction {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: qsTr("Cancel")
                    visible: overlay.busy
                    onClicked: overlay.cancelRequested()
                }

                PanelAction {
                    objectName: "translateCloseButton"
                    anchors.verticalCenter: parent.verticalCenter
                    theme: overlay.theme
                    text: qsTr("Close")
                    onClicked: overlay.closeRequested()
                }
            }
        }
    }

    // --------------------------------------------------- Bottom floating result card (14 px padding)
    Rectangle {
        id: resultCard
        visible: overlay.cardVisible || overlay.busy
                 || !!(overlay.aiTask && overlay.aiTask.kind === "translate" && overlay.aiTask.error)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 28, 600)
        implicitHeight: cardCol.implicitHeight + 28
        radius: 10
        color: Qt.rgba(overlay.theme.surface.r, overlay.theme.surface.g, overlay.theme.surface.b, 0.97)
        border.width: 1
        border.color: overlay.theme.border
        z: 5

        MouseArea { anchors.fill: parent; preventStealing: true; z: -1 }

        ColumnLayout {
            id: cardCol
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            // Busy progress row
            RowLayout {
                Layout.fillWidth: true
                visible: overlay.busy
                spacing: 10
                Label {
                    text: overlay.aiTask ? overlay.aiTask.stage : qsTr("Translating…")
                    color: overlay.theme.text
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                ProgressBar {
                    implicitWidth: 140
                    from: 0
                    to: 100
                    value: overlay.aiTask ? overlay.aiTask.percent : 0
                }
            }

            // Error banner
            Rectangle {
                visible: !!(overlay.aiTask && !overlay.busy && overlay.aiTask.kind === "translate" && overlay.aiTask.error)
                Layout.fillWidth: true
                implicitHeight: errLbl.implicitHeight + 16
                radius: 6
                color: Qt.rgba(overlay.theme.danger.r, overlay.theme.danger.g, overlay.theme.danger.b, 0.12)
                border.width: 1
                border.color: overlay.theme.danger
                Label {
                    id: errLbl
                    anchors.fill: parent
                    anchors.margins: 8
                    text: overlay.aiTask && overlay.aiTask.error ? overlay.aiTask.error : ""
                    color: overlay.theme.danger
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }
            }

            // Original / OCR text box
            Rectangle {
                visible: !overlay.busy && !!(overlay.latestResult && overlay.latestResult.originalText)
                Layout.fillWidth: true
                implicitHeight: Math.min(96, origText.implicitHeight + 16)
                radius: 6
                color: overlay.theme.surfaceAlt
                border.width: 1
                border.color: overlay.theme.border
                clip: true

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 10
                    contentWidth: width
                    contentHeight: origText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    TextEdit {
                        id: origText
                        width: parent.width
                        readOnly: true
                        selectByMouse: true
                        text: overlay.latestResult ? overlay.latestResult.originalText : ""
                        color: (overlay.latestResult && overlay.latestResult.translatedText)
                               ? overlay.theme.textMuted : overlay.theme.text
                        selectionColor: overlay.theme.accent
                        selectedTextColor: overlay.theme.accentText
                        font.pixelSize: (overlay.latestResult && overlay.latestResult.translatedText) ? 12 : 14
                        wrapMode: TextEdit.WordWrap
                        Keys.onEscapePressed: focus = false
                    }
                }
            }

            // Translated text box
            Rectangle {
                visible: !overlay.busy && !!(overlay.latestResult && overlay.latestResult.translatedText)
                Layout.fillWidth: true
                implicitHeight: Math.min(140, transText.implicitHeight + 24)
                radius: 6
                color: overlay.theme.surfaceAlt
                border.width: 1
                border.color: overlay.theme.accent
                clip: true

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 12
                    contentWidth: width
                    contentHeight: transText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    TextEdit {
                        id: transText
                        width: parent.width
                        readOnly: true
                        selectByMouse: true
                        text: overlay.latestResult ? overlay.latestResult.translatedText : ""
                        color: overlay.theme.text
                        selectionColor: overlay.theme.accent
                        selectedTextColor: overlay.theme.accentText
                        font.pixelSize: 14
                        wrapMode: TextEdit.WordWrap
                        Keys.onEscapePressed: focus = false
                    }
                }
            }

            // Divider before actions
            Rectangle {
                visible: !overlay.busy && !!overlay.latestResult
                Layout.fillWidth: true
                height: 1
                color: overlay.theme.border
            }

            // Action row
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: !overlay.busy && !!overlay.latestResult

                PanelAction {
                    theme: overlay.theme
                    text: qsTr("Copy")
                    onClicked: {
                        if (!overlay.latestResult) return
                        var txt = overlay.latestResult.translatedText || overlay.latestResult.originalText || ""
                        if (txt) overlay.copyTextRequested(txt)
                    }
                }

                // In OCR-only mode, allow 1-click forwarding of the scanned region to Google Translate
                PanelAction {
                    theme: overlay.theme
                    visible: !(overlay.latestResult && overlay.latestResult.translatedText)
                    text: qsTr("Translate this")
                    onClicked: {
                        overlay.overlayMode = "translate"
                        overlay.translateRequested(overlay.sourceCode(), overlay.targetCode(), overlay.lastRegion)
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
