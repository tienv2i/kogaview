import QtQuick
import QtQuick.Controls

/// The key that runs a menu entry, drawn at the menu's right edge.
///
/// Qt Quick Controls' `MenuItem` carries an `Action.shortcut` but never draws
/// it, and this project builds its entries from `text` and `icon` directly. The
/// hint is therefore a child label of the entry rather than part of its text:
/// the action keeps its own words (which `Theme.menuEntryLabels` measures), and
/// the key gets a right-aligned column of its own (which
/// `Theme.menuShortcutLabels` measures and `Theme.menuWidth` reserves room
/// for).
///
/// The colour comes from the entry's own content item, not from `palette`.
/// A `Menu` popup is drawn by the platform style with the platform's colours,
/// while a `palette.*` lookup inside it resolves the *window's* palette — this
/// app forces a dark one, so `palette.windowText` painted the hints white on
/// the popup's light background (measured: `#fcfcfc` on `#efefef`). The style
/// computes its text colour rather than reading that same property, so the
/// content item it painted is the only source that agrees with the row. `z`
/// keeps the label above that content item, which spans the full width.
Label {
    objectName: "shortcutHint"
    z: 2
    anchors.right: parent.right
    anchors.rightMargin: 12
    anchors.verticalCenter: parent.verticalCenter
    color: parent && parent.palette ? parent.palette.windowText : palette.windowText
    opacity: 0.7
    font: parent.font
}
