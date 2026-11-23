import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// A titled group inside a form: a heading, a hairline under it, then the rows
/// that answer that heading.
///
/// Three forms grouped their rows three ways — Settings in accent-bold
/// headings with the rule under them, the batch form in plain bold headings
/// with the rule above — so the same kind of group read differently depending
/// on which dialog it was in. There is one shape now: a 12 px bold heading in
/// the theme's text colour, one 1 px rule, then the rows.
ColumnLayout {
    id: section

    property Theme theme: Theme {}
    /// The words above the rule. Empty means no heading, just the rows — a form
    /// with one group has nothing to name.
    property string title: ""
    /// The gap between two rows of this section.
    property int rowSpacing: 8

    /// The rows.
    default property alias content: rows.data

    spacing: 6

    Label {
        objectName: section.objectName + "Heading"
        visible: section.title !== ""
        Layout.fillWidth: true
        Layout.topMargin: section.title === "" ? 0 : 2
        text: section.title
        color: section.theme.text
        font.pixelSize: 12
        font.bold: true
        elide: Text.ElideRight
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        visible: section.title !== ""
        color: section.theme.border
    }

    ColumnLayout {
        id: rows
        Layout.fillWidth: true
        spacing: section.rowSpacing
    }
}
