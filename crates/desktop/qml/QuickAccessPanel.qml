import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The left dock's first page: the folders the user pinned.
//
// It is the same list in every workspace, because a favourite is a place the
// user wants to reach from wherever they are. The panel owns no command: a row
// click reports a path and the workspace decides what opening it means (the
// Browser navigates; the Viewer and the Editor hand it to the Browser). The
// right-click menu is the host's too — adding and removing a favourite is a
// Core command and the words live with the rest of the Browser's menus.
Item {
    id: panel

    property Theme theme: Theme {}
    property var favorites: []
    /// Name of the scrolling list, so a suite and the dev harness can find it.
    property string listObjectName: "quickAccessList"
    property string itemObjectName: "quickAccessItem"

    signal openFolder(string path)
    signal openMenu(string path)

    readonly property real naturalHeight: heading.height + 6 + list.contentHeight + 2

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        Label {
            id: heading
            Layout.fillWidth: true
            text: qsTr("Quick access")
            color: panel.theme.textMuted
            font.bold: true
            font.pixelSize: 12
        }

        ListView {
            id: list
            objectName: panel.listObjectName
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            interactive: contentHeight > height
            model: panel.favorites || []
            /// Three 32 px rows per notch.
            WheelScroll {
                view: list
                step: 96
            }

            delegate: Rectangle {
                objectName: panel.itemObjectName
                width: list.width
                height: 32
                radius: panel.theme.radius
                color: quickHover.hovered ? panel.theme.hover : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 6

                    Label {
                        text: "★"
                        color: panel.theme.accent
                    }
                    Label {
                        text: panel.label(modelData)
                        color: panel.theme.text
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                }

                HoverHandler { id: quickHover }
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onSingleTapped: panel.openFolder(modelData)
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onSingleTapped: panel.openMenu(modelData)
                }
            }
        }
    }

    /// The last path component, with the home folder named rather than shown as
    /// a bare user name.
    function label(path) {
        if (!path) return ""
        if (path === (panel.state.home || "")) return qsTr("Home")
        var trimmed = ("" + path).replace(/\/+$/, "")
        var index = trimmed.lastIndexOf("/")
        return index >= 0 ? trimmed.substring(index + 1) : trimmed
    }

    /// The snapshot, for `home`. Kept as a property so the label follows a
    /// state publish like every other sentence.
    property var state: ({})
}
