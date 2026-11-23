import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// A row of one form: the label in the form's label column and the control
/// beside it.
///
/// The label column is what makes a form read as a form: with every label at
/// `labelWidth` the controls start at one x, and a dialog that mixes a fixed
/// column with natural-width labels (as Resize and Settings both did) has two
/// left edges to read at once. Two shapes cover every row in the window:
///
/// - `labelFill: false` (the default) — the label keeps the column and the
///   control takes the rest of the width. This is what a text field, a dropdown
///   and a swatch row want.
/// - `labelFill: true` — the label takes the rest of the width and the control
///   keeps its own. This is what a checkbox row and a right-aligned dropdown
///   want (Settings' Theme and Language rows).
///
/// The control keeps its own layout attached properties, so a form writes it
/// exactly as it would write it inside a row.
RowLayout {
    id: row

    property Theme theme: Theme {}
    /// The words in the label column. Empty means the row has no label and the
    /// control starts at the form's left edge.
    property string label: ""
    /// The label column's width, when the label does not fill the row.
    property int labelWidth: 96
    /// Whether the label takes the leftover width instead of a fixed column.
    property bool labelFill: false

    /// The label. It is `textMuted` in every form: it names a control, and the
    /// value the control shows is the row's ink.
    property alias labelItem: labelField

    /// The control (or controls) of the row.
    default property alias fields: fieldsRow.data

    spacing: 8

    Label {
        id: labelField
        text: row.label
        visible: row.label !== ""
        color: row.theme.textMuted
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
        Layout.fillWidth: row.labelFill
        Layout.preferredWidth: row.labelFill ? -1 : row.labelWidth
        Layout.maximumWidth: row.labelFill ? 1e9 : row.labelWidth
    }

    RowLayout {
        id: fieldsRow
        spacing: 8
        Layout.fillWidth: !row.labelFill
    }
}
