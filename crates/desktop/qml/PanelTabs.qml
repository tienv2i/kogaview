import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts

// The dock's tabs: what the document is, what was done to it, what it looks
// like — or, in the Browser, the picture and the batch page. The armed tool's
// options live above the Editor's strip, so a tab can stay open while Crop or
// Brush is in hand.
//
// The strip is drawn here rather than with `TabBar` for two measured reasons:
// the platform style paints its own light strip on a dark window (the collision
// the context menus had), and each tab needs a stable `objectName` for the QML
// suite. The labels arrive from the view, so this file draws no string and owns
// no translation.
//
// A tab whose `shown` is false stays in the model but draws no button: the
// page keeps its place in the dock's stack, and the sidebar's panel menu is
// what puts it back. Hiding the panel therefore never renumbers the pages.
Item {
    id: root

    property Theme theme: Theme {}
    /// `[{ key, label, icon, shown }]`, in the order they are drawn. `shown`
    /// defaults to true when the view omits it.
    property var tabs: []
    property string currentKey: ""
    /// Fold the labels away when the dock is too narrow for them; the drawing
    /// and its tooltip still say which tab it is.
    property bool compact: false
    property int tabHeight: 30
    /// Names each button (`<prefix>_<key>`), its drawing
    /// (`<prefix>Icon_<key>`) and its label (`<prefix>Label_<key>`). The Editor
    /// keeps the historical `editorTab` prefix; the Browser and the Viewer use
    /// their own, so a suite can tell three strips apart in one window.
    property string keyPrefix: "editorTab"

    signal activated(string key)

    implicitHeight: tabHeight

    RowLayout {
        anchors.fill: parent
        spacing: 4

        Repeater {
            model: root.tabs

            delegate: AbstractButton {
                id: tab

                required property var modelData

                readonly property bool active: root.currentKey === modelData.key
                readonly property color ink: tab.active ? root.theme.text
                                              : tab.hovered ? root.theme.text
                                              : root.theme.textMuted

                objectName: root.keyPrefix + "_" + modelData.key
                visible: modelData.shown !== false
                Layout.fillWidth: true
                Layout.fillHeight: true
                padding: 4
                focusPolicy: Qt.NoFocus
                activeFocusOnTab: false
                hoverEnabled: true

                Accessible.role: Accessible.PageTab
                Accessible.name: modelData.label

                ToolTip.visible: hovered && root.compact
                ToolTip.text: modelData.label

                onClicked: root.activated(modelData.key)

                background: Rectangle {
                    radius: root.theme.radius
                    color: tab.active ? root.theme.selection
                         : tab.hovered ? root.theme.hover
                         : "transparent"
                    border.width: tab.active ? 1 : 0
                    border.color: root.theme.accent
                }

                // The content item is a plain Item so the icon can sit centred
                // when the labels are folded; a RowLayout as the content item
                // would keep the icon at the left edge even alone.
                contentItem: Item {
                    clip: true
                    RowLayout {
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, parent.width)
                        spacing: 4

                        IconImage {
                            objectName: root.keyPrefix + "Icon_" + tab.modelData.key
                            source: tab.modelData.icon
                            sourceSize: Qt.size(32, 32)
                            Layout.preferredWidth: 16
                            Layout.preferredHeight: 16
                            Layout.alignment: Qt.AlignVCenter
                            fillMode: Image.PreserveAspectFit
                            color: tab.ink
                        }

                        Label {
                            objectName: root.keyPrefix + "Label_" + tab.modelData.key
                            visible: !root.compact
                            text: tab.modelData.label
                            color: tab.ink
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }
    }
}
