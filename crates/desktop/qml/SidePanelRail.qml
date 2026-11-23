import QtQuick
import QtQuick.Layouts

/// Narrow vertical icon rail pinned to the left or right edge of a workspace
/// (Browser, Viewer, Editor) for one-click toggling and switching of side
/// panels, plus a bottom action to hide all panels on that side.
Rectangle {
    id: rail

    property Theme theme: Theme {}
    /// `"left"` or `"right"`: controls divider side, outer active indicator
    /// bar edge, and the hide-all icon direction.
    property string edge: "right"
    /// `[{ key, label, icon, active, separatorBefore }]`
    property var entries: []
    /// Prefix used for each button's `objectName` (`<prefix>_<key>`).
    property string buttonPrefix: rail.edge === "left" ? "leftRail" : "rightRail"
    /// True while at least one panel managed by this rail is currently shown;
    /// enables the bottom Hide-all button.
    property bool anyActive: false
    /// Tooltip for the bottom Hide-all button.
    property string hideAllTooltip: qsTr("Hide all panels")

    signal toggled(string key)
    signal hideAll()

    implicitWidth: 40
    Layout.preferredWidth: 40
    Layout.fillHeight: true
    color: rail.theme.surface

    // Inner 1 px divider separating the rail from the sidebar or main canvas.
    Rectangle {
        anchors.left: rail.edge === "right" ? parent.left : undefined
        anchors.right: rail.edge === "left" ? parent.right : undefined
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

                    // Active edge indicator bar on the outer edge.
                    Rectangle {
                        anchors.right: rail.edge === "right" ? parent.right : undefined
                        anchors.rightMargin: rail.edge === "right" ? -3 : 0
                        anchors.left: rail.edge === "left" ? parent.left : undefined
                        anchors.leftMargin: rail.edge === "left" ? -3 : 0
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

        Rectangle {
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
                objectName: rail.buttonPrefix + "_hideAll"
                anchors.centerIn: parent
                theme: rail.theme
                iconSource: rail.edge === "left"
                            ? "icons/panel-hide-left.svg"
                            : "icons/panel-hide-right.svg"
                tooltip: rail.hideAllTooltip
                enabled: rail.anyActive
                onClicked: rail.hideAll()
            }
        }
    }
}
