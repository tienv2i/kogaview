import QtQuick
import QtQuick.Controls

// Decorative themed icon.
//
// Qt Quick has no public "icon" element; `IconLabel`/`IconImage` live in the
// private QtQuick.Controls.impl module. This wrapper reuses the stock-button
// icon rendering while remaining non-interactive and non-focusable.
ToolButton {
    id: root
    property string iconName: ""
    property int iconSize: 20
    property color iconColor: "transparent"

    display: AbstractButton.IconOnly
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false
    enabled: false
    padding: 0
    implicitWidth: iconSize
    implicitHeight: iconSize
    background: null
    icon.name: root.iconName
    icon.width: root.iconSize
    icon.height: root.iconSize
    icon.color: root.iconColor
}
