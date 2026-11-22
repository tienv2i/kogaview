import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts

// The sidebar's own panel checklist.
//
// A narrow gutter on the right edge of the dock, with one vertical-dots button
// at the top. It replaces the chevrons that used to fold the tool options and
// the reference tabs: hiding a panel is now one explicit item in a list, so a
// user can arrange the sidebar without learning what each chevron points at.
//
// The list is the view's: this file draws no panel name of its own, only the
// one sentence that names the button. Checking an item shows the panel,
// unchecking it hides it, and the view owns what "showing" means (a tab, the
// tool options, a whole page).
Item {
    id: root

    property Theme theme: Theme {}
    /// `[{ key, label, checked }]`, in menu order. The view supplies the
    /// labels, so a new panel is a row in the view and no string here.
    property var panels: []
    /// Names the button and the menu for the QML suites and the dev harness.
    property string buttonObjectName: "panelMenuButton"
    property string menuObjectName: "panelMenu"

    signal toggled(string key, bool checked)

    implicitWidth: 26
    implicitHeight: 34
    // A dock with no checklist takes no gutter; the Editor's reference half
    // passes an empty list because the checklist covers the whole sidebar.
    visible: root.panels.length > 0

    AbstractButton {
        id: button
        objectName: root.buttonObjectName
        width: 26
        height: 30
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        padding: 0
        focusPolicy: Qt.NoFocus
        activeFocusOnTab: false
        hoverEnabled: true

        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Sidebar panels")
        ToolTip.visible: hovered
        ToolTip.text: qsTr("Sidebar panels")

        onClicked: menu.open()

        background: Rectangle {
            radius: root.theme.radius
            color: button.hovered ? root.theme.hover : "transparent"
        }

        contentItem: Item {
            IconImage {
                source: "icons/panel-menu.svg"
                sourceSize: Qt.size(32, 32)
                width: 16
                height: 16
                anchors.centerIn: parent
                fillMode: Image.PreserveAspectFit
                color: button.hovered ? root.theme.text : root.theme.textMuted
            }
        }

        // The list hangs from the button, right-aligned to it and just under
        // it. `popup()` without a position uses the popup's default placement,
        // which on this style put the list at the window's left edge instead of
        // under the control that opened it.
        Menu {
            id: menu
            objectName: root.menuObjectName
            parent: button
            y: button.height + 2
            x: button.width - width

            Repeater {
                model: root.panels

                delegate: MenuItem {
                    required property var modelData

                    text: modelData.label
                    checkable: true
                    checked: !!modelData.checked
                    onToggled: root.toggled(modelData.key, checked)
                }
            }
        }
    }
}
