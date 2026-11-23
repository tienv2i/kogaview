import QtQuick
import QtQuick.Controls

/// A radio button whose words are the app's.
///
/// The same problem and the same answer as `FormCheck.qml`: a stock
/// `RadioButton` in a popup drew its label with the platform palette's window
/// text, which is near-black on this window's dark forms. The dot stays the
/// style's; the sentence beside it is the theme's, muted while the row is
/// disabled (which is how a batch form says "this source is not available").
RadioButton {
    id: box

    property Theme theme: Theme {}

    focusPolicy: Qt.NoFocus

    contentItem: Text {
        text: box.text
        color: box.enabled ? box.theme.text : box.theme.textMuted
        font: box.font
        leftPadding: box.indicator.width + box.spacing
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        opacity: box.enabled ? 1.0 : 0.6
    }
}
