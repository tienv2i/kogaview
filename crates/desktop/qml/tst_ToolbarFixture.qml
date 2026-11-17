import QtQuick
import QtQuick.Controls

// Fixture for `tests/qml/tst_toolbar.cpp`.
//
// It reproduces the two pieces of `Main.qml` the toolbar suite argues about:
// the label decision the window makes from `ToolbarMetrics` (`labels`), and the
// floor it keeps re-applying (`floorWidth`). Loading the real `Main.qml` would
// need a bridge, a C++ `Platform` object and a state snapshot; this fixture
// keeps the *arithmetic and the guard* under test, which is where the bugs were,
// and leaves the rest of the window to the real-window run reported in
// `docs/M1-REPORT.md`.
//
// It is a tracked file beside the views rather than a component written at
// runtime, because Qt only loads a component whose file name is a type name and
// only resolves the local types (`ToolbarMetrics`, `WorkspaceSwitcher`) as
// siblings. It is deliberately **not** listed in `crates/desktop/build.rs`, so
// it is not part of the shipped QML module; the application never references it.
Item {
    id: root

    objectName: "toolbarFixture"
    width: 700
    height: 60

    /// Whether the current width can afford labels — `Main.qml`'s
    /// `toolbarLabels`, from the same two numbers.
    property bool labels: width >= toolbarMetrics.labelThreshold
    /// The width the floor re-application settles on.
    property real floorWidth: width

    ToolbarMetrics {
        id: toolbarMetrics
        objectName: "toolbarMetrics"
    }

    /// `Main.qml`'s guard: a window that ends up narrower than the floor is put
    /// back at it.
    onWidthChanged: {
        if (width < toolbarMetrics.minimumWindowWidth) {
            Qt.callLater(function() { root.floorWidth = toolbarMetrics.minimumWindowWidth })
        } else {
            root.floorWidth = width
        }
    }

    WorkspaceSwitcher {
        objectName: "toolbarSwitcher"
        anchors.left: parent.left
        anchors.right: parent.right
        height: 34
        metrics: toolbarMetrics
        showLabels: root.labels
    }
}
