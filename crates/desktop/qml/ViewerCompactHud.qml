import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Translucent floating HUD overlay shared by Viewer's `compact` mode and
/// `fullscreen` mode.
///
/// Supports 4-edge docking (`top` | `bottom` | `left` | `right`) via either:
/// - Dragging the grip handle (with live magnetic edge-snap preview), or
/// - Right-clicking the HUD pill to choose an edge or pin the HUD visible.
Item {
    id: hud

    property Theme theme: Theme {}
    property bool active: false
    property bool fullscreen: false
    property bool hasImage: false
    property int imageCount: 0
    property int imageIndex: -1
    property string imageName: ""
    /// True while view-only Color & Light adjustments are active (non-zero).
    property bool colorAdjustActive: false
    /// True while an anchored popover (Mode or Color) is open; pauses auto-hide.
    property bool keepOpen: false
    /// Docked edge: `"top"` | `"bottom"` | `"left"` | `"right"`.
    property string edge: "top"
    /// Keep the HUD permanently visible instead of auto-hiding after idle.
    property bool pinned: false

    readonly property bool vertical: hud.edge === "left" || hud.edge === "right"

    signal previousRequested()
    signal nextRequested()
    signal zoomOutRequested()
    signal fitRequested()
    signal zoomInRequested()
    signal colorToggleRequested(Item anchor, string edge)
    signal modeToggleRequested(Item anchor, string edge)
    signal fullscreenToggleRequested()
    signal browserRequested()
    signal editorRequested()

    property bool revealed: false
    property bool dragging: false
    property string snapPreviewEdge: ""

    visible: hud.active
    anchors.fill: parent
    z: 20

    function showBriefly() {
        if (!hud.active) return
        hud.revealed = true
        if (!hud.pinned && !hud.keepOpen) hideTimer.restart()
    }

    function nearestEdge(sceneX, sceneY) {
        var dTop = Math.max(0, sceneY)
        var dBottom = Math.max(0, hud.height - sceneY)
        var dLeft = Math.max(0, sceneX)
        var dRight = Math.max(0, hud.width - sceneX)
        var minD = Math.min(dTop, dBottom, dLeft, dRight)
        if (minD === dBottom) return "bottom"
        if (minD === dLeft) return "left"
        if (minD === dRight) return "right"
        return "top"
    }

    onActiveChanged: {
        if (hud.active) {
            hud.showBriefly()
        } else {
            hideTimer.stop()
            hud.revealed = false
            hud.dragging = false
            hud.snapPreviewEdge = ""
        }
    }

    onKeepOpenChanged: {
        if (hud.keepOpen) {
            hud.revealed = true
            hideTimer.stop()
        } else if (hud.active && !hud.pinned) {
            hideTimer.restart()
        }
    }

    onPinnedChanged: {
        if (hud.pinned) {
            hud.revealed = true
            hideTimer.stop()
        } else if (hud.active && !hud.keepOpen) {
            hideTimer.restart()
        }
    }

    Timer {
        id: hideTimer
        interval: 2000
        repeat: false
        onTriggered: {
            if (!hud.pinned && !hud.keepOpen && !hud.dragging
                    && !pillHover.hovered && !edgeHover.hovered) {
                hud.revealed = false
            }
        }
    }

    // Invisible 56 px hover trigger zone following the docked edge.
    Item {
        id: triggerZone
        anchors.top: hud.edge === "bottom" ? undefined : parent.top
        anchors.bottom: hud.edge === "top" ? undefined : parent.bottom
        anchors.left: hud.edge === "right" ? undefined : parent.left
        anchors.right: hud.edge === "left" ? undefined : parent.right
        width: hud.vertical ? 56 : parent.width
        height: hud.vertical ? parent.height : 56

        HoverHandler {
            id: edgeHover
            onHoveredChanged: {
                if (hovered) {
                    hud.revealed = true
                    hideTimer.stop()
                } else if (!hud.pinned && !hud.keepOpen) {
                    hideTimer.restart()
                }
            }
        }
    }

    // Translucent magnetic snap-edge preview shown while dragging the HUD.
    Rectangle {
        visible: hud.dragging && hud.snapPreviewEdge.length > 0
        radius: 6
        color: Qt.rgba(hud.theme.accent.r, hud.theme.accent.g, hud.theme.accent.b, 0.22)
        border.width: 1
        border.color: hud.theme.accent
        x: hud.snapPreviewEdge === "left" ? 10
         : hud.snapPreviewEdge === "right" ? hud.width - 50
         : (hud.width - 280) / 2
        y: hud.snapPreviewEdge === "top" ? 10
         : hud.snapPreviewEdge === "bottom" ? hud.height - 50
         : (hud.height - 280) / 2
        width: (hud.snapPreviewEdge === "left" || hud.snapPreviewEdge === "right") ? 40 : 280
        height: (hud.snapPreviewEdge === "top" || hud.snapPreviewEdge === "bottom") ? 40 : 280
    }

    // Floating pill bar, docked cleanly to `hud.edge` (or following pointer while dragging).
    Rectangle {
        id: pill
        objectName: "viewerCompactHudPill"
        readonly property real dockedX:
            hud.edge === "left" ? 12
          : hud.edge === "right" ? Math.max(12, hud.width - pill.width - 12)
          : Math.round((hud.width - pill.width) / 2)
        readonly property real dockedY:
            hud.edge === "top" ? 12
          : hud.edge === "bottom" ? Math.max(12, hud.height - pill.height - 12)
          : Math.round((hud.height - pill.height) / 2)

        property real dragX: 0
        property real dragY: 0

        x: hud.dragging ? pill.dragX : pill.dockedX
        y: hud.dragging ? pill.dragY : pill.dockedY
        width: hud.vertical ? 42 : (pillGrid.implicitWidth + 14)
        height: hud.vertical ? (pillGrid.implicitHeight + 14) : 42
        radius: 10
        color: Qt.rgba(hud.theme.surface.r, hud.theme.surface.g, hud.theme.surface.b, 0.92)
        border.width: 1
        border.color: hud.dragging ? hud.theme.accent : hud.theme.border
        opacity: (hud.revealed || hud.pinned || hud.keepOpen || hud.dragging) ? 1.0 : 0.0
        visible: opacity > 0.01

        Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
        }

        HoverHandler {
            id: pillHover
            onHoveredChanged: {
                if (hovered) {
                    hud.revealed = true
                    hideTimer.stop()
                } else if (!hud.pinned && !hud.keepOpen) {
                    hideTimer.restart()
                }
            }
        }

        TapHandler {
            acceptedButtons: Qt.RightButton
            onSingleTapped: function(point) {
                var pos = pill.mapToItem(hud, point.position.x, point.position.y)
                hudEdgeMenu.popup(hud, pos.x, pos.y)
            }
        }

        GridLayout {
            id: pillGrid
            anchors.centerIn: parent
            flow: hud.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
            rows: hud.vertical ? -1 : 1
            columns: hud.vertical ? 1 : -1
            rowSpacing: 2
            columnSpacing: 2

            // Grip handle for dragging the HUD to any of the 4 edges.
            Item {
                id: dragGrip
                objectName: "compactHudDragGrip"
                implicitWidth: hud.vertical ? 30 : 18
                implicitHeight: hud.vertical ? 18 : 30
                Layout.alignment: Qt.AlignCenter

                Grid {
                    anchors.centerIn: parent
                    columns: hud.vertical ? 3 : 2
                    spacing: 3
                    Repeater {
                        model: 6
                        Rectangle {
                            width: 2.5
                            height: 2.5
                            radius: 1.25
                            color: gripHover.hovered || hud.dragging
                                   ? hud.theme.text : hud.theme.textMuted
                        }
                    }
                }

                HoverHandler {
                    id: gripHover
                    cursorShape: hud.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                }

                DragHandler {
                    id: gripDrag
                    target: null
                    acceptedDevices: PointerDevice.AllDevices
                    property real startX: 0
                    property real startY: 0
                    onActiveChanged: {
                        if (active) {
                            startX = pill.dockedX
                            startY = pill.dockedY
                            pill.dragX = startX
                            pill.dragY = startY
                            hud.dragging = true
                            hud.snapPreviewEdge = hud.edge
                            hideTimer.stop()
                        } else if (hud.dragging) {
                            var target = hud.snapPreviewEdge || hud.edge
                            hud.dragging = false
                            hud.snapPreviewEdge = ""
                            hud.edge = target
                            hud.showBriefly()
                        }
                    }
                    onTranslationChanged: {
                        if (!active) return
                        pill.dragX = Math.max(8, Math.min(hud.width - pill.width - 8, startX + translation.x))
                        pill.dragY = Math.max(8, Math.min(hud.height - pill.height - 8, startY + translation.y))
                        hud.snapPreviewEdge = hud.nearestEdge(pill.dragX + pill.width / 2,
                                                              pill.dragY + pill.height / 2)
                    }
                }
            }

            ToolbarButton {
                objectName: "compactHudBrowser"
                visible: !hud.fullscreen
                theme: hud.theme
                icon.source: "icons/browser.svg"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Browser")
                onClicked: hud.browserRequested()
            }

            ToolbarButton {
                objectName: "compactHudEditor"
                visible: !hud.fullscreen
                theme: hud.theme
                icon.source: "icons/editor.svg"
                display: AbstractButton.IconOnly
                enabled: hud.hasImage
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Edit image")
                onClicked: hud.editorRequested()
            }

            Rectangle {
                visible: !hud.fullscreen
                Layout.alignment: Qt.AlignCenter
                implicitWidth: hud.vertical ? 20 : 1
                implicitHeight: hud.vertical ? 1 : 20
                color: hud.theme.border
            }

            ToolbarButton {
                objectName: "compactHudPrev"
                theme: hud.theme
                icon.name: "media-skip-backward-symbolic"
                display: AbstractButton.IconOnly
                enabled: hud.imageCount > 0
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Previous image (Left)")
                onClicked: hud.previousRequested()
            }

            Label {
                visible: hud.imageCount > 0
                Layout.alignment: Qt.AlignCenter
                text: (hud.imageIndex + 1) + "/" + hud.imageCount
                color: hud.theme.textMuted
                font.pixelSize: hud.vertical ? 10 : 12
                leftPadding: hud.vertical ? 0 : 4
                rightPadding: hud.vertical ? 0 : 4
                topPadding: hud.vertical ? 2 : 0
                bottomPadding: hud.vertical ? 2 : 0
            }

            ToolbarButton {
                objectName: "compactHudNext"
                theme: hud.theme
                icon.name: "media-skip-forward-symbolic"
                display: AbstractButton.IconOnly
                enabled: hud.imageCount > 0
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Next image (Right)")
                onClicked: hud.nextRequested()
            }

            Rectangle {
                Layout.alignment: Qt.AlignCenter
                implicitWidth: hud.vertical ? 20 : 1
                implicitHeight: hud.vertical ? 1 : 20
                color: hud.theme.border
            }

            ToolbarButton {
                objectName: "compactHudZoomOut"
                theme: hud.theme
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: hud.hasImage
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom out")
                onClicked: hud.zoomOutRequested()
            }

            ToolbarButton {
                objectName: "compactHudFit"
                theme: hud.theme
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: hud.hasImage
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Fit to window (F)")
                onClicked: hud.fitRequested()
            }

            ToolbarButton {
                objectName: "compactHudZoomIn"
                theme: hud.theme
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: hud.hasImage
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom in")
                onClicked: hud.zoomInRequested()
            }

            Rectangle {
                Layout.alignment: Qt.AlignCenter
                implicitWidth: hud.vertical ? 20 : 1
                implicitHeight: hud.vertical ? 1 : 20
                color: hud.theme.border
            }

            ToolbarButton {
                id: compactColorBtn
                objectName: "compactHudColor"
                theme: hud.theme
                checked: hud.colorAdjustActive
                icon.source: "icons/adjust.svg"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Color & light")
                onClicked: hud.colorToggleRequested(compactColorBtn, hud.edge)
            }

            ToolbarButton {
                id: compactModeBtn
                objectName: "compactHudMode"
                theme: hud.theme
                icon.source: "icons/viewer-mode.svg"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Viewer mode & layout (M)")
                onClicked: hud.modeToggleRequested(compactModeBtn, hud.edge)
            }

            ToolbarButton {
                objectName: "compactHudFullscreen"
                theme: hud.theme
                icon.source: hud.fullscreen ? "icons/fullscreen-exit.svg" : "icons/fullscreen.svg"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: hud.fullscreen ? qsTr("Exit fullscreen (F11)") : qsTr("Fullscreen (F11)")
                onClicked: hud.fullscreenToggleRequested()
            }
        }
    }

    AppMenu {
        id: hudEdgeMenu
        objectName: "compactHudEdgeMenu"
        theme: hud.theme

        MenuItem {
            text: qsTr("Dock top")
            checkable: true
            checked: hud.edge === "top"
            onTriggered: hud.edge = "top"
        }
        MenuItem {
            text: qsTr("Dock bottom")
            checkable: true
            checked: hud.edge === "bottom"
            onTriggered: hud.edge = "bottom"
        }
        MenuItem {
            text: qsTr("Dock left")
            checkable: true
            checked: hud.edge === "left"
            onTriggered: hud.edge = "left"
        }
        MenuItem {
            text: qsTr("Dock right")
            checkable: true
            checked: hud.edge === "right"
            onTriggered: hud.edge = "right"
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Keep toolbar visible")
            checkable: true
            checked: hud.pinned
            onTriggered: hud.pinned = !hud.pinned
        }
    }
}
