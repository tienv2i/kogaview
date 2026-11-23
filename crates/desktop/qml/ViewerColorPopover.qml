import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Translucent floating popover hosting the shared `ColorAdjustPanel` for
/// Viewer's `compact` and `fullscreen` modes. Positions itself opposite the
/// active HUD edge (`top` / `bottom` / `left` / `right`) without dimming the
/// image so live 60 fps adjustments remain fully visible.
Popup {
    id: popup

    property Theme theme: Theme {}
    property alias brightness: adjustPanel.brightness
    property alias contrast: adjustPanel.contrast
    property alias saturation: adjustPanel.saturation
    readonly property bool changed: adjustPanel.changed

    padding: 12
    dim: false
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property double _lastClosedMs: 0
    onClosed: _lastClosedMs = Date.now()

    function toggleNear(anchor, edge) {
        if (popup.visible) {
            popup.close()
            return
        }
        if (Date.now() - popup._lastClosedMs < 200) {
            return
        }
        if (anchor && popup.parent) {
            var w = popup.implicitWidth > 0 ? popup.implicitWidth : 284
            var h = popup.implicitHeight > 0 ? popup.implicitHeight : 230
            var topLeft = anchor.mapToItem(popup.parent, 0, 0)
            var px = topLeft.x
            var py = topLeft.y + anchor.height + 6
            if (edge === "bottom") {
                px = topLeft.x + (anchor.width - w) / 2
                py = topLeft.y - h - 6
            } else if (edge === "left") {
                px = topLeft.x + anchor.width + 8
                py = topLeft.y + (anchor.height - h) / 2
            } else if (edge === "right") {
                px = topLeft.x - w - 8
                py = topLeft.y + (anchor.height - h) / 2
            } else {
                px = topLeft.x + (anchor.width - w) / 2
                py = topLeft.y + anchor.height + 6
            }
            var maxX = Math.max(8, popup.parent.width - w - 8)
            var maxY = Math.max(8, popup.parent.height - h - 8)
            popup.x = Math.max(8, Math.min(px, maxX))
            popup.y = Math.max(8, Math.min(py, maxY))
        }
        popup.open()
    }

    background: Rectangle {
        color: Qt.rgba(popup.theme.surface.r, popup.theme.surface.g, popup.theme.surface.b, 0.94)
        border.width: 1
        border.color: popup.theme.border
        radius: popup.theme.radius + 2
    }

    contentItem: ColumnLayout {
        spacing: 8
        implicitWidth: 260

        Label {
            text: qsTr("Color & light")
            color: popup.theme.text
            font.bold: true
            font.pixelSize: 12
        }

        ColorAdjustPanel {
            id: adjustPanel
            objectName: "compactColorAdjustPanel"
            Layout.fillWidth: true
            theme: popup.theme
            viewOnly: true
            showReset: true
        }
    }
}
