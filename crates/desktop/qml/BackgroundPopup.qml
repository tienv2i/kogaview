import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// The background colour's own list: `Transparent`, `White`, `Black`, `Gray`
/// and any colour.
///
/// A `ColorDialog` cannot say "no colour", and transparency is a real answer for
/// new canvas — a cleared border rather than a white one — so the background
/// role needs a list of its own beside the ordinary chooser. The three named
/// colours are the ones a padding or a grown border is actually asked for; the
/// last row reaches the chooser for anything else.
///
/// One component, used by the tool rail's pair, the Crop panel and the Resize
/// form, so no two of them can disagree about what a background may be.
Popup {
    id: popup

    property Theme theme: Theme {}
    /// Whether the current background paints nothing.
    property bool transparent: false
    /// The colour it paints when it does paint something. Kept while
    /// `transparent` is on, so choosing Transparent and then White returns to a
    /// colour the user had, not to a default.
    property color colour: "#ffffff"
    /// Whether transparency cannot survive the document's own format — a JPEG
    /// file, whose encoder composites alpha over white. The list still offers
    /// `Transparent` (the picture on screen really is clear, and Export to a
    /// PNG keeps it); it says what the save will do rather than refusing the
    /// answer.
    property bool alphaLostWarning: false

    signal transparentPicked()
    signal colourPicked(string value)
    signal customPicked()

    /// The rows. `transparent` and `custom` are actions, not colours: one paints
    /// nothing, the other opens the chooser.
    readonly property var entries: [
        { key: "transparent", label: qsTr("Transparent"), colour: "" },
        { key: "white", label: qsTr("White"), colour: "#ffffff" },
        { key: "black", label: qsTr("Black"), colour: "#000000" },
        { key: "gray", label: qsTr("Gray"), colour: "#808080" },
        { key: "custom", label: qsTr("Custom color…"), colour: "" }
    ]

    width: 196
    height: contentColumn.implicitHeight + 2 * padding
    padding: 8
    // A click outside or Escape leaves the background as it was. It is a list,
    // not a form: there is nothing to cancel.
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    property int toggleGuardMs: 250
    property Item _toggleAnchor: null
    property double _dismissedAtMs: 0
    property bool _selfClosed: false

    onClosed: {
        if (popup._selfClosed) {
            popup._selfClosed = false
            popup._dismissedAtMs = 0
            return
        }
        if (!popup._toggleAnchor || popup._toggleAnchor.hovered === true) {
            popup._dismissedAtMs = Date.now()
        } else {
            popup._dismissedAtMs = 0
        }
    }

    background: Rectangle {
        color: popup.theme.surface
        border.width: 1
        border.color: popup.theme.border
        radius: 6
    }

    function _positionFor(anchor) {
        if (!anchor || !popup.parent) return
        var space = popup.parent
        var origin = anchor.mapToItem(space, 0, 0)
        var margin = 6
        var popW = Math.max(popup.width, 196)
        var popH = Math.max(popup.height, contentColumn.implicitHeight + 2 * popup.padding, 190)

        var targetX = Math.round(origin.x)
        if (targetX + popW > space.width - margin)
            targetX = Math.max(margin, Math.round(space.width - popW - margin))
        if (targetX < margin) targetX = margin

        var belowY = Math.round(origin.y + anchor.height + margin)
        var aboveY = Math.round(origin.y - popH - margin)
        var targetY
        if (belowY + popH <= space.height - margin) {
            targetY = belowY
        } else if (aboveY >= margin) {
            targetY = aboveY
        } else {
            targetY = Math.max(margin, Math.round(space.height - popH - margin))
        }

        popup.x = targetX
        popup.y = targetY
    }

    onHeightChanged: {
        if (popup.visible && popup._toggleAnchor) {
            popup._positionFor(popup._toggleAnchor)
        }
    }

    /// Toggle near `anchor` — below when there is room, flipping cleanly above
    /// when near the bottom edge (e.g. the Canvas background row in Layers).
    /// Clicking the same anchor a second time closes the popup cleanly.
    function showBelow(anchor) {
        if (!anchor) return
        if (popup.visible && popup._toggleAnchor === anchor) {
            popup._selfClosed = true
            popup.close()
            return
        }
        var now = Date.now()
        if (popup._dismissedAtMs > 0
                && popup._toggleAnchor === anchor
                && (now - popup._dismissedAtMs) < popup.toggleGuardMs) {
            popup._dismissedAtMs = 0
            return
        }
        popup._dismissedAtMs = 0
        popup._toggleAnchor = anchor
        popup._positionFor(anchor)
        popup.open()
    }

    /// The three bytes as `#rrggbb`. The view's own state is a string of that
    /// shape, and a `color` written straight into it would carry an alpha byte.
    function colourText(value) {
        function byte(part) {
            var text = Math.round(part * 255).toString(16)
            return text.length < 2 ? "0" + text : text
        }
        return "#" + byte(value.r) + byte(value.g) + byte(value.b)
    }

    /// Which row carries the check: the named colour the background currently
    /// is, `Transparent` while it paints nothing, and `Custom color…` for any
    /// other colour. The comparison is text against text — `#rrggbb` both
    /// sides — so a `color` and a model string are never compared as objects.
    function isSelected(key) {
        if (key === "transparent") return popup.transparent
        if (popup.transparent) return false
        var current = popup.colourText(popup.colour)
        if (key === "custom") {
            for (var i = 0; i < popup.entries.length; ++i) {
                if (popup.entries[i].colour === current) return false
            }
            return true
        }
        for (var j = 0; j < popup.entries.length; ++j) {
            if (popup.entries[j].key === key)
                return popup.entries[j].colour === current
        }
        return false
    }

    function choose(key) {
        popup.close()
        if (key === "transparent") {
            popup.transparentPicked()
        } else if (key === "custom") {
            popup.customPicked()
        } else {
            for (var i = 0; i < popup.entries.length; ++i) {
                if (popup.entries[i].key === key) {
                    popup.colourPicked(popup.entries[i].colour)
                    return
                }
            }
        }
    }

    contentItem: ColumnLayout {
        id: contentColumn
        spacing: 2

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: 6
            Layout.bottomMargin: 4
            text: qsTr("Background")
            color: popup.theme.textMuted
            font.pixelSize: 11
        }

        Repeater {
            model: popup.entries

            delegate: Rectangle {
                id: row
                required property var modelData
                objectName: popup.objectName + "Choice_" + modelData.key
                Layout.fillWidth: true
                implicitHeight: 28
                radius: 4
                color: rowArea.containsMouse || popup.isSelected(row.modelData.key)
                       ? popup.theme.hover : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 8

                    // The swatch: a plain colour, or the checkerboard for
                    // "no colour". A checked row is also tinted, so the
                    // selection survives on a colour that happens to match the
                    // hover fill.
                    Rectangle {
                        objectName: popup.objectName + "ChoiceSwatch_" + row.modelData.key
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        radius: 3
                        color: row.modelData.key === "transparent"
                               ? "transparent"
                               : (row.modelData.key === "custom"
                                  ? popup.colour : row.modelData.colour)
                        border.width: 1
                        border.color: popup.theme.border

                        Checkerboard {
                            anchors.fill: parent
                            visible: row.modelData.key === "transparent"
                            square: 4
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        text: row.modelData.label
                        color: popup.theme.text
                        elide: Text.ElideRight
                    }

                    Label {
                        objectName: popup.objectName + "ChoiceCheck_" + row.modelData.key
                        visible: popup.isSelected(row.modelData.key)
                        text: "✓"
                        color: popup.theme.accent
                    }
                }

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.role: Accessible.Button
                    Accessible.name: row.modelData.label
                    onClicked: popup.choose(row.modelData.key)
                }
            }
        }

        // Said at the moment of the choice, because it is the only moment a
        // warning is still useful: the answer is allowed, and the next save is
        // what turns the clear area white.
        Label {
            objectName: "backgroundPopupWarning"
            Layout.fillWidth: true
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            Layout.topMargin: 6
            visible: popup.alphaLostWarning
            text: qsTr("This document is a JPEG, which has no transparency: the background is written as white.")
            color: popup.theme.textMuted
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }
    }
}
