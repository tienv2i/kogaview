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
    /// Put the pages away and keep only the strip. The Editor uses it to give
    /// the armed tool's options the whole dock; the chevron in the strip is the
    /// way back, so this is never a state without an exit.
    property bool folded: false
    /// The chevron's sentence; the dock draws no translation of its own.
    property string foldTooltip: ""
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
    signal foldRequested()

    readonly property bool stripShown: dock.tabs.length > 1
    /// What a folded dock keeps: the strip and the margins around it, and none
    /// of the pages. A view that folds the pages uses this as its height.
    readonly property int stripHeight: strip.implicitHeight + dock.stripMargin * 2 + 2
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
            id: strip
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
            folded: dock.folded
            foldTooltip: dock.foldTooltip
            onActivated: function(key) { dock.activated(key) }
            onFoldRequested: dock.foldRequested()
        }

        StackLayout {
            id: stack
            objectName: dock.pagesObjectName
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: dock.pageMargin
            currentIndex: dock.currentIndex
            // A folded dock keeps the strip and drops the pages. They stay
            // instantiated (their state is the view's), so unfolding is one
            // property write and no reload.
            visible: !dock.folded
        }
    }
}
