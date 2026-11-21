import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts

// The Editor dock's reference tabs: what the document is, what was done to it,
// what it looks like. The armed tool's options live above this strip, so a tab
// can stay open while Crop or Brush is in hand.
//
// The strip is drawn here rather than with `TabBar` for two measured reasons:
// the platform style paints its own light strip on a dark window (the collision
// the context menus had), and each tab needs a stable `objectName` for the QML
// suite. The labels arrive from the view, so this file draws no string and owns
// no translation.
Item {
    id: root

    property Theme theme: Theme {}
    /// `[{ key, label, icon }]`, in the order they are drawn.
    property var tabs: []
    property string currentKey: ""
    /// Fold the labels away when the dock is too narrow for them; the drawing
    /// and its tooltip still say which tab it is.
    property bool compact: false
    property int tabHeight: 30
    /// The pages under this strip are put away: only the strip is left, and the
    /// chevron points back down.
    property bool folded: false
    /// The chevron's sentence, supplied by the view because this file owns no
    /// translation (the tab labels are the view's words too).
    property string foldTooltip: ""

    signal activated(string key)
    /// The chevron was pressed: the view flips its own flag and sends nothing.
    signal foldRequested()

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

                objectName: "editorTab_" + modelData.key
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
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        IconImage {
                            objectName: "editorTabIcon_" + tab.modelData.key
                            source: tab.modelData.icon
                            sourceSize: Qt.size(32, 32)
                            Layout.preferredWidth: 16
                            Layout.preferredHeight: 16
                            Layout.alignment: Qt.AlignVCenter
                            fillMode: Image.PreserveAspectFit
                            color: tab.ink
                        }

                        Label {
                            objectName: "editorTabLabel_" + tab.modelData.key
                            visible: !root.compact
                            text: tab.modelData.label
                            color: tab.ink
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }

        // The strip is also the way to put the pages away. It has to live here
        // rather than in the dock: the strip is one row, and a chevron added
        // outside it would be a second row that a folded dock would still have
        // to draw.
        AbstractButton {
            id: foldButton
            objectName: "stripFoldToggle"
            visible: root.tabs.length > 1
            // Smaller than the tabs it sits beside: it is a fold, not a mode.
            Layout.preferredWidth: 24
            Layout.fillHeight: true
            padding: 0
            focusPolicy: Qt.NoFocus
            activeFocusOnTab: false
            hoverEnabled: true

            Accessible.role: Accessible.Button
            Accessible.name: root.foldTooltip
            ToolTip.visible: hovered && root.foldTooltip.length > 0
            ToolTip.text: root.foldTooltip

            onClicked: root.foldRequested()

            background: Rectangle {
                radius: root.theme.radius
                color: foldButton.hovered ? root.theme.hover : "transparent"
            }

            contentItem: Item {
                IconImage {
                    objectName: "stripFoldIcon"
                    source: "icons/chevron.svg"
                    sourceSize: Qt.size(32, 32)
                    width: 14
                    height: 14
                    anchors.centerIn: parent
                    fillMode: Image.PreserveAspectFit
                    color: foldButton.hovered ? root.theme.text : root.theme.textMuted
                    // Down while the pages are open, up when they are away.
                    rotation: root.folded ? 180 : 0
                }
            }
        }
    }
}
