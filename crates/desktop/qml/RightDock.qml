import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The right-hand column, shared by the three workspaces.
//
// It is only the surface, the tab strip, the pages and the panel checklist:
// what goes inside is the view's business, so the Browser can put its preview
// and its batch page side by side, the Viewer just the details, and the Editor
// three tabs' worth. The words on the tabs arrive from the view, which is why
// this file draws no panel name of its own (see `PanelTabs.qml`).
//
// One visible page means no strip: a single tab is a label for the only thing
// on screen, and the Browser's preview and metadata are read together.
Item {
    id: dock

    property Theme theme: Theme {}
    /// Surface under the panels. The Browser and the Viewer draw their sidebars
    /// in the sidebar colour; the Editor's dock sits on the canvas surface.
    property color backgroundColor: dock.theme.surface
    property color borderColor: dock.theme.border

    /// `[{ key, label, icon, shown }]`, in tab order. A tab with `shown: false`
    /// keeps its page in the stack but draws no button; the panel menu below is
    /// what puts it back.
    property var tabs: []
    property string currentKey: ""
    /// Fold the labels away when the dock is too narrow for them.
    property bool compact: false
    /// `[{ key, label, checked }]` for the checklist on the right edge. The
    /// view supplies the labels; empty means "no checklist", which is what the
    /// Editor's reference half wants.
    property var panels: []
    /// Room around the strip and around the pages.
    property int stripMargin: 8
    property int pageMargin: 12
    /// Names the chosen strip and pages so the QML suites and the dev harness
    /// can find them; empty means "no name" rather than an empty object name.
    property string stripObjectName: ""
    property string pagesObjectName: ""
    property string menuObjectName: "panelMenu"
    /// Prefix for each tab's `objectName`; the view chooses it so the suite can
    /// address three strips in one window.
    property string tabKeyPrefix: "editorTab"

    /// The pages, in tab order. Each one fills the stack, so a page that
    /// scrolls owns its own `ScrollView`.
    default property alias pages: stack.data

    signal activated(string key)
    signal panelToggled(string key, bool checked)

    readonly property bool stripShown: dock.shownTabCount > 1
    /// A page whose tab was hidden by the panel menu still owns its stack
    /// slot, so `currentIndex` has to name the slot, not the visible rank.
    readonly property int currentIndex: {
        for (var index = 0; index < dock.tabs.length; ++index) {
            if (dock.tabs[index].key === dock.currentKey
                && dock.tabs[index].shown !== false) return index
        }
        for (var fallback = 0; fallback < dock.tabs.length; ++fallback) {
            if (dock.tabs[fallback].shown !== false) return fallback
        }
        return -1
    }
    readonly property int shownTabCount: {
        var count = 0
        for (var index = 0; index < dock.tabs.length; ++index) {
            if (dock.tabs[index].shown !== false) ++count
        }
        return count
    }

    Rectangle {
        anchors.fill: parent
        color: dock.backgroundColor
        border.width: 1
        border.color: dock.borderColor
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            PanelTabs {
                id: strip
                objectName: dock.stripObjectName
                Layout.fillWidth: true
                Layout.leftMargin: dock.stripMargin
                Layout.rightMargin: dock.stripMargin
                Layout.topMargin: dock.stripMargin
                Layout.bottomMargin: 2
                // An invisible layout child takes no room, so a single-panel
                // dock starts at its pages instead of leaving an empty strip.
                visible: dock.stripShown
                theme: dock.theme
                tabs: dock.tabs
                currentKey: dock.currentKey
                compact: dock.compact
                keyPrefix: dock.tabKeyPrefix
                onActivated: function(key) { dock.activated(key) }
            }

            StackLayout {
                id: stack
                objectName: dock.pagesObjectName
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: dock.pageMargin
                currentIndex: dock.currentIndex
                // A menu that hid every page leaves the dock as the checklist
                // and its surface, which is the way back to a page.
                visible: dock.shownTabCount > 0
            }

            // The empty state: every page was unchecked. The checklist button
            // is still on the right edge; this says why the body is blank
            // instead of leaving a column that reads as a failed load.
            Label {
                objectName: dock.pagesObjectName + "Empty"
                Layout.fillWidth: true
                Layout.leftMargin: dock.pageMargin + 2
                Layout.rightMargin: dock.pageMargin
                Layout.topMargin: dock.pageMargin
                // Take the pages' leftover height and draw the sentence at its
                // top: `Layout.alignment` alone did not pin it, because the
                // hidden `StackLayout` leaves the column with no filler and the
                // label was centred in the column's spare height.
                Layout.fillHeight: true
                verticalAlignment: Text.AlignTop
                visible: dock.shownTabCount === 0
                text: qsTr("No panels shown")
                color: dock.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }

        PanelMenu {
            objectName: "dockPanelMenu"
            Layout.fillHeight: true
            theme: dock.theme
            panels: dock.panels
            menuObjectName: dock.menuObjectName
            onToggled: function(key, checked) { dock.panelToggled(key, checked) }
        }
    }
}
