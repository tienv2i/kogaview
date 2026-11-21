import QtQuick
import QtQuick.Layouts

// The right-hand reference column, shared by the three workspaces.
//
// It is only the surface, the tab strip and the stack: what goes inside is the
// view's business, so the Browser can put a preview above the file's details,
// the Viewer just the details, and the Editor three tabs' worth. The words on
// the tabs arrive from the view, which is why this file draws no string of its
// own (see `PanelTabs.qml`).
//
// One panel means no strip: a single tab is a label for the only thing on
// screen, and the Browser's preview and metadata are read together.
Item {
    id: dock

    property Theme theme: Theme {}
    /// Surface under the panels. The Browser and the Viewer draw their sidebars
    /// in the sidebar colour; the Editor's dock sits on the canvas surface.
    property color backgroundColor: dock.theme.surface
    property color borderColor: dock.theme.border

    /// `[{ key, label, icon }]`, in tab order.
    property var tabs: []
    property string currentKey: ""
    /// Fold the labels away when the dock is too narrow for them.
    property bool compact: false
    /// Room around the strip and around the pages.
    property int stripMargin: 8
    property int pageMargin: 12
    /// Names the chosen strip and pages so the QML suites and the dev harness
    /// can find them; empty means "no name" rather than an empty object name.
    property string stripObjectName: ""
    property string pagesObjectName: ""

    /// The pages, in tab order. Each one fills the stack, so a page that
    /// scrolls owns its own `ScrollView`.
    default property alias pages: stack.data

    signal activated(string key)

    readonly property bool stripShown: dock.tabs.length > 1
    /// The stack's index for `currentKey`; an unknown key falls back to the
    /// first tab instead of leaving the pages without a current index.
    readonly property int currentIndex: {
        for (var index = 0; index < dock.tabs.length; ++index) {
            if (dock.tabs[index].key === dock.currentKey) return index
        }
        return 0
    }

    Rectangle {
        anchors.fill: parent
        color: dock.backgroundColor
        border.width: 1
        border.color: dock.borderColor
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PanelTabs {
            objectName: dock.stripObjectName
            Layout.fillWidth: true
            Layout.leftMargin: dock.stripMargin
            Layout.rightMargin: dock.stripMargin
            Layout.topMargin: dock.stripMargin
            Layout.bottomMargin: 2
            // An invisible layout child takes no room, so a single-panel dock
            // starts at its pages instead of leaving an empty strip.
            visible: dock.stripShown
            theme: dock.theme
            tabs: dock.tabs
            currentKey: dock.currentKey
            compact: dock.compact
            onActivated: function(key) { dock.activated(key) }
        }

        StackLayout {
            id: stack
            objectName: dock.pagesObjectName
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: dock.pageMargin
            currentIndex: dock.currentIndex
        }
    }
}
