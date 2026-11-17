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

    property alias metrics: rowMetrics

    ToolbarMetrics {
        id: rowMetrics
    }

    // The header's children, in order, at their measured widths. The elastic
    // spacer contributes nothing to an implicit width.
    Item {
        implicitWidth: rowMetrics.switcherIconsWidth
        implicitHeight: 34
    }
    Item {
        implicitWidth: rowMetrics.separatorWidth
        implicitHeight: 34
    }
    Item {
        implicitWidth: rowMetrics.widestToolbarWidth
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
