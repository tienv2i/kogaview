import QtQuick
import QtQuick.Controls

// A toolbar button that is an icon square, and borrows room for its label only
// when the shell says there is some.
//
// A narrow window used to squash the toolbar's `RowLayout`: the labelled
// workspace buttons kept their text and the buttons after them lost their right
// edge. Here the label is *earned*. `Main.qml` decides from measured widths
// whether the window can afford labels at all, and passes that down; a button
// then asks the layout for `labelledWidth` instead of the icon square. The two
// states are discrete, so a label is never half-drawn or clipped by the row, and
// `text` and the tooltip carry the word in both states.
ToolButton {
    id: root

    property Theme theme: Theme {}
    /// The measured toolbar pieces (`ToolbarMetrics.qml`). One per window, so a
    /// button's labelled width is the width the window's floor was built from.
    property QtObject metrics: ToolbarMetrics {}
    /// True while the shell can afford the labels. Set by the row that lays the
    /// toolbar out; a button never decides this on its own.
    property bool showLabel: false

    /// The square an icon-only button occupies.
    readonly property real iconOnlyWidth: metrics.buttonWidth
    /// What the button occupies when its label is shown.
    readonly property real labelledWidth:
        iconOnlyWidth + labelMetrics.advanceWidth + metrics.labelPadding
    /// Whether the label is drawn. The only property that follows `showLabel`;
    /// the button's width and its `display` both read it.
    readonly property bool useText: showLabel && text.length > 0

    /// The label's own advance at the application font, so `labelledWidth`
    /// matches what the button draws instead of the style's padding guess.
    TextMetrics {
        id: labelMetrics
        font: Qt.application.font
        text: root.text
    }

    // The stock control draws `<icon> <text>` for `TextBesideIcon`; the square
    // alone is `IconOnly`. Switching between them is what makes the button
    // grow and shrink as one piece.
    display: useText ? AbstractButton.TextBesideIcon : AbstractButton.IconOnly
    implicitWidth: useText ? labelledWidth : iconOnlyWidth
    implicitHeight: 34
    leftPadding: 8
    rightPadding: 8
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false
    icon.width: 18
    icon.height: 18
    icon.color: !enabled ? Qt.rgba(theme.textMuted.r, theme.textMuted.g, theme.textMuted.b, 0.4)
                : checked ? theme.accent
                : hovered ? theme.text
                : theme.textMuted

    background: Rectangle {
        radius: root.theme.radius
        color: root.checked ? root.theme.selection
             : (root.hovered ? root.theme.hover : "transparent")
        border.width: root.checked ? 1 : 0
        border.color: root.theme.accent
    }
}
