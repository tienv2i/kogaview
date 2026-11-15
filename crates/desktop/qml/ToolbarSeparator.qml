import QtQuick

// Thin vertical divider for toolbars. ToolSeparator follows the platform
// palette and renders as a bright bar against the themed toolbar surface.
Item {
    property Theme theme: Theme {}

    implicitWidth: 9
    implicitHeight: 24

    Rectangle {
        anchors.centerIn: parent
        width: 1
        height: 18
        color: theme.border
    }
}
