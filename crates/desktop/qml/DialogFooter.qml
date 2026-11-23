import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// The action row at the foot of every `DialogFrame` form.
///
/// The 60 px surface, the 12 px margins and the 8 px gap are the same in every
/// dialog, and the verbs are `PanelAction`s — the app's own button — rather than
/// a stock `Button`. That is not tidiness for its own sake: a stock `Button` on
/// this window's dark theme painted a near-white slab, and its "OK"/"Cancel"
/// words come from the platform's `qtbase_<locale>.qm`, which a machine without
/// that file renders in English inside a Vietnamese form.
///
/// A form declares its verbs as children, in the order they should read. A form
/// that keeps a value-restoring verb apart on the left (Defaults, Reset) opens
/// its own `Item { Layout.fillWidth: true }` before it, which is the spacer every
/// dialog already wrote; the rest then sit against the right edge.
Item {
    id: footer

    property Theme theme: Theme {}
    /// Root of this footer's object name (`settingsFooter`, `resizeFooter`).
    property string namePrefix: ""

    implicitHeight: 60
    // `DialogFrame` sizes this row; a form that overrides the footer only names
    // its verbs.
    Layout.fillWidth: true

    /// The verbs, left to right. They are direct children of the inner
    /// `RowLayout`, so `Layout.fillWidth` and the spacer behave as they always
    /// have.
    default property alias items: actions.data

    Rectangle {
        anchors.fill: parent
        color: footer.theme.surface
        border.color: footer.theme.border
        border.width: 1
    }

    RowLayout {
        id: actions
        objectName: footer.namePrefix + "Footer"
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 8
    }
}
