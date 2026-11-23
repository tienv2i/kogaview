import QtQuick
import QtQuick.Controls

/// A tick box whose words are the app's.
///
/// A stock `CheckBox` inside a `Popup` resolves the *platform* palette, and its
/// stock label came out near-black on the dark form: measured in the Export
/// dialog, `#26292e` on `#181b21`, a line a reader has to lean into. The
/// indicator stays the style's — it is the part the platform already draws in
/// the theme's accent — and the words come from `Theme`, muted while the control
/// is disabled.
///
/// Every form wore its own copy of this `contentItem` before, and the forms that
/// had not been visited yet (Export) simply had no colour at all, so the same
/// control read differently in two dialogs.
CheckBox {
    id: box

    property Theme theme: Theme {}

    // A tick box is answered with the mouse or by its mnemonic; tabbing into it
    // would cost the forms' fields a stop each.
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
