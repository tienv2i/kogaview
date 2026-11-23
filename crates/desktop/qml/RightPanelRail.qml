import QtQuick
import QtQuick.Layouts

/// Narrow vertical icon rail pinned to the right edge of every workspace
/// (Browser, Viewer, Editor) for one-click toggling and switching of the right
/// sidebar panels.
Rectangle {
    id: rail

    property Theme theme: Theme {}
    /// `[{ key, label, icon, active, separatorBefore }]`
    property var entries: []
    /// Prefix used for each button's `objectName` (`<prefix>_<key>`).
    property string buttonPrefix: "rightRail"

    signal toggled(string key)

    implicitWidth: 40
    Layout.preferredWidth: 40
    Layout.fillHeight: true
    color: rail.theme.surface

    // Left 1 px divider separating the rail from the sidebar or main canvas.
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: rail.theme.border
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 3
        anchors.rightMargin: 3
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        spacing: 4

        Repeater {
            model: rail.entries

            delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 4

                Rectangle {
                    visible: !!modelData.separatorBefore
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    implicitHeight: 1
                    color: rail.theme.border
                }

                Item {
                    Layout.fillWidth: true
                    implicitHeight: 34

                    ToolRailButton {
                        objectName: rail.buttonPrefix + "_" + modelData.key
                        anchors.centerIn: parent
                        theme: rail.theme
                        iconSource: modelData.icon || ""
                        tooltip: modelData.label || ""
                        active: !!modelData.active
                        onClicked: rail.toggled(modelData.key)
                    }

                    // Active edge indicator bar on the outer right edge.
                    Rectangle {
                        anchors.right: parent.right
                        anchors.rightMargin: -3
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: modelData.active ? 18 : 0
                        radius: 1
                        color: rail.theme.accent
                        opacity: modelData.active ? 1.0 : 0.0
                        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
