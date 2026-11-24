import QtQuick
import QtQuick.Layouts

// Fixture for `tests/qml/tst_toolbar.cpp`: the header row of `Main.qml`
// reproduced with `ToolbarMetrics`' own numbers — same children, same 4 px
// spacing, same side margins. The suite asserts that
// `compactToolbarWidth` is what this row actually needs, which is what keeps
// the window floor from disagreeing with the real toolbar.
//
// A tracked file beside the views (Qt needs the file name to be a type name and
// the local types to resolve as siblings), and deliberately **not** listed in
// `crates/desktop/build.rs`, so it never ships. The application never
// references it.
RowLayout {
    id: rowFixture

    objectName: "toolbarRowFixture"
    width: 2000
    height: 60
    // The header's own spacing and margins (`Main.qml` header).
    spacing: 4

    /// Draw the row as the mini toolbar: the workspace slot takes its folded
    /// width. The test sets this between two measurements in the same window.
    property bool mini: false
    /// Which workspace's toolbar fills the workspace slot. Each has its own
    /// compact and folded width, so the fixture is measured once per workspace.
    property string workspace: "editor"

    property alias metrics: rowMetrics

    /// That workspace's toolbar at its full and folded widths, so one fixture
    /// can be measured for all three views.
    function workspaceToolbarWidth(folded) {
        if (rowFixture.workspace === "browser") {
            return folded ? rowMetrics.browserMiniToolbarWidth
                          : rowMetrics.browserToolbarWidth
        }
        if (rowFixture.workspace === "viewer") {
            return folded ? rowMetrics.viewerMiniToolbarWidth
                          : rowMetrics.viewerToolbarWidth
        }
        return folded ? rowMetrics.editorMiniToolbarWidth
                      : rowMetrics.editorToolbarWidth
    }

    ToolbarMetrics {
        id: rowMetrics
    }

    // The header's children, in order, at their measured widths. The elastic
    // spacer contributes nothing to an implicit width.
    Item {
        implicitWidth: rowFixture.mini
                       ? rowMetrics.switcherCollapsedWidth
                       : rowMetrics.switcherIconsWidth
        implicitHeight: 34
    }
    Item {
        implicitWidth: rowMetrics.separatorWidth
        implicitHeight: 34
    }
    Item {
        implicitWidth: rowFixture.mini
                       ? rowFixture.workspaceToolbarWidth(true)
                       : rowFixture.workspaceToolbarWidth(false)
        implicitHeight: 34
    }
    Item {
        Layout.fillWidth: true
        implicitHeight: 34
    }
    Item {
        implicitWidth: rowMetrics.busyIndicatorWidth
        implicitHeight: 34
    }
    Item {
        implicitWidth: rowMetrics.menuButtonWidth
        implicitHeight: 34
    }
}
