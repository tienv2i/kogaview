import QtQuick

/// Live Liquify warp overlay for `EditorView`.
Item {
    id: liquifyOverlay
    objectName: "liquifyOverlay"

    required property var view
    anchors.fill: parent
    visible: view.tool === "liquify" && view.documentReady
    enabled: visible && !view.spacePanning

    property var pendingPts: []
    property var lastDocPt: null
    property bool dragging: false
    property real cursorX: -1000
    property real cursorY: -1000
    property bool cursorInside: false

    Timer {
        id: liquifyFlushTimer
        interval: 24
        repeat: true
        onTriggered: {
            if (!liquifyOverlay.dragging) return
            if (liquifyOverlay.pendingPts.length > 0) {
                var batch = liquifyOverlay.pendingPts.slice()
                liquifyOverlay.pendingPts = []
                liquifyOverlay.view.command({ type: "editor_live_stroke_step", points: batch })
            } else if (liquifyOverlay.view.liquifyMode !== "push" && liquifyOverlay.lastDocPt) {
                // Continuous Bloat / Pucker / Twirl while holding mouse stationary
                liquifyOverlay.view.command({ type: "editor_live_stroke_step", points: [liquifyOverlay.lastDocPt] })
            }
        }
    }

    // Circular Liquify brush cursor
    Rectangle {
        visible: liquifyOverlay.cursorInside
        readonly property real d: Math.max(8, liquifyOverlay.view.liquifyRadius * 2 * liquifyOverlay.view.zoom)
        width: d
        height: d
        radius: d / 2
        x: liquifyOverlay.cursorX - d / 2
        y: liquifyOverlay.cursorY - d / 2
        color: "transparent"
        border.width: 1.5
        border.color: "#ffffff"
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(0, 0, 0, 0.65)
        }
        Rectangle {
            anchors.centerIn: parent
            width: 4; height: 4; radius: 2
            color: liquifyOverlay.view.theme.accent
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.BlankCursor
        onEntered: liquifyOverlay.cursorInside = true
        onExited: liquifyOverlay.cursorInside = false
        onPressed: function(mouse) {
            liquifyOverlay.view.forceActiveFocus()
            liquifyOverlay.cursorX = mouse.x
            liquifyOverlay.cursorY = mouse.y
            var dx = liquifyOverlay.view.hostToDocX(mouse.x)
            var dy = liquifyOverlay.view.hostToDocY(mouse.y)
            liquifyOverlay.lastDocPt = [dx, dy]
            liquifyOverlay.pendingPts = []
            liquifyOverlay.dragging = true
            liquifyOverlay.view.command({
                type: "editor_live_stroke_begin",
                kind: "liquify",
                mode: liquifyOverlay.view.liquifyMode,
                radius: liquifyOverlay.view.liquifyRadius,
                strength: liquifyOverlay.view.liquifyStrength / 100.0,
                x: dx,
                y: dy
            })
            liquifyFlushTimer.start()
        }
        onPositionChanged: function(mouse) {
            liquifyOverlay.cursorX = mouse.x
            liquifyOverlay.cursorY = mouse.y
            liquifyOverlay.cursorInside = true
            if (!liquifyOverlay.dragging) return
            var dx = liquifyOverlay.view.hostToDocX(mouse.x)
            var dy = liquifyOverlay.view.hostToDocY(mouse.y)
            var last = liquifyOverlay.lastDocPt
            if (!last || Math.hypot(dx - last[0], dy - last[1]) >= 2.0) {
                liquifyOverlay.lastDocPt = [dx, dy]
                liquifyOverlay.pendingPts.push([dx, dy])
            }
        }
        onReleased: {
            if (!liquifyOverlay.dragging) return
            liquifyFlushTimer.stop()
            liquifyOverlay.dragging = false
            if (liquifyOverlay.pendingPts.length > 0) {
                var batch = liquifyOverlay.pendingPts.slice()
                liquifyOverlay.pendingPts = []
                liquifyOverlay.view.command({ type: "editor_live_stroke_step", points: batch })
            }
            liquifyOverlay.lastDocPt = null
            liquifyOverlay.view.command({ type: "editor_live_stroke_end", commit: true })
        }
        onCanceled: {
            if (!liquifyOverlay.dragging) return
            liquifyFlushTimer.stop()
            liquifyOverlay.dragging = false
            liquifyOverlay.pendingPts = []
            liquifyOverlay.lastDocPt = null
            liquifyOverlay.view.command({ type: "editor_live_stroke_end", commit: false })
        }
    }
}
