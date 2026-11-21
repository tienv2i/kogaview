import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A number field with its unit selector beside it.
//
// The document, the protocol and Core work in whole pixels; a unit is a way of
// writing the same pixel quantity, so nothing here ever changes what a command
// carries. `pixels()` is what the panels read, and `setPixels` is how they
// write — a programmatic write is not a keystroke, so it must not trigger the
// "the user typed this" path that links Width and Height.
//
// Two units for now: `px` and `%` of the document side the field belongs to
// (see `unitReference`). A physical unit needs a DPI the document does not
// carry, so it is deliberately absent rather than a 96-dpi guess.
RowLayout {
    id: field

    /// `px` or `%`.
    property string unit: "px"
    /// Whether this quantity can be written in a unit at all. A place (X, Y)
    /// is only ever a pixel coordinate, so its selector is hidden.
    property bool unitsVisible: true
    /// The document side a percentage is taken of: the width for Width, the
    /// height for Height. Ignored in `px`, and unused by a field whose selector
    /// is hidden.
    property real unitReference: 1
    /// Pixel bounds, so a swap to `%` keeps the same limits in another spelling.
    property int minimumPixels: 1
    property int maximumPixels: 20000

    /// The last pixel quantity the text described. A unit switch redraws this
    /// one, so switching `px` → `%` → `px` cannot drift by a rounding step.
    property int lastPixels: 0

    /// Field order for Tab: the dialog sets these so the keyboard walks the
    /// form the way it did when the text field was the whole control.
    property var nextField: null
    property var previousField: null

    readonly property bool percent: unit === "%"
    /// The real text control. The suite and the dialog focus this one, because
    /// a RowLayout itself cannot take the keyboard.
    readonly property TextField inputField: input

    property alias text: input.text
    property alias acceptableInput: input.acceptableInput
    property alias placeholderText: input.placeholderText
    property alias horizontalAlignment: input.horizontalAlignment
    property alias font: input.font

    signal textEdited()
    signal accepted()
    signal editingFinished()

    spacing: 4

    /// The integer pixel quantity in the field, whatever unit it is written in.
    ///
    /// A function, not a bound property: `TextField` emits `textEdited` before
    /// it notifies `text`, so a binding derived from `text` still holds the
    /// previous keystroke's value inside the handler that reacts to the key the
    /// user just pressed. Reading the text here is what the old `parseInt` did.
    function pixels() {
        var text = String(field.text).trim()
        if (text.length === 0) return 0
        if (field.unit === "%") {
            if (!(field.unitReference > 0)) return 0
            const value = parseFloat(text)
            if (!isFinite(value)) return 0
            return Math.round(value / 100 * field.unitReference)
        }
        const pixels = parseInt(text)
        return isFinite(pixels) ? pixels : 0
    }

    /// Write a pixel quantity in the current unit.
    function setPixels(pixels) {
        if (!isFinite(pixels)) return
        if (field.unit !== "%") {
            field.text = String(Math.round(pixels))
            return
        }
        if (!(field.unitReference > 0)) {
            field.text = ""
            return
        }
        // Two decimals: enough for a one-pixel step of a document up to 10000
        // pixels wide to survive a round trip through percentages.
        field.text = String(Math.round(pixels / field.unitReference * 10000) / 100)
    }

    onUnitChanged: {
        unitBox.currentIndex = field.percent ? 1 : 0
        if (field.text.length === 0) return
        // Setting the text from `lastPixels` is a re-display, not a keystroke:
        // `textEdited` never fires, so the ratio link and the auto-follow flags
        // stay out of a unit switch.
        field.setPixels(field.lastPixels)
    }

    IntValidator {
        id: pixelValidator
        bottom: field.minimumPixels
        top: field.maximumPixels
    }
    DoubleValidator {
        id: percentValidator
        // `C` locale: the field carries a `.` whatever the interface language
        // is, so a percentage cannot be refused because of a decimal comma.
        locale: "C"
        notation: DoubleValidator.StandardNotation
        decimals: 2
        bottom: field.unitReference > 0
                ? field.minimumPixels / field.unitReference * 100 : 0
        top: field.unitReference > 0
             ? field.maximumPixels / field.unitReference * 100 : 20000
    }

    TextField {
        id: input
        Layout.fillWidth: true
        Layout.fillHeight: true
        validator: field.percent ? percentValidator : pixelValidator
        inputMethodHints: field.percent ? Qt.ImhFormattedNumbersOnly
                                        : Qt.ImhDigitsOnly
        // The form's own keyboard path, forwarded from the fields that own it.
        KeyNavigation.tab: field.nextField ? field.nextField.inputField : null
        KeyNavigation.backtab:
            field.previousField ? field.previousField.inputField : null
        onTextChanged: field.lastPixels = field.pixels()
        onTextEdited: field.textEdited()
        onAccepted: field.accepted()
        onEditingFinished: field.editingFinished()
    }

    // The selector is a control of its own, not a decoration inside the field:
    // an inline one had no room for its own height and read as part of the
    // number. It sits beside the input, margin included, and matches its
    // height so the pair reads as one row.
    ComboBox {
        id: unitBox
        objectName: field.objectName ? field.objectName + "Unit" : "unitSelector"
        visible: field.unitsVisible
        Layout.fillHeight: true
        // Wide enough for "px" and the style's own arrow: a 42 px box elided it
        // to a single clipped letter.
        Layout.minimumWidth: 52
        Layout.preferredWidth: 56
        Layout.maximumWidth: 64
        model: ["px", "%"]
        currentIndex: field.percent ? 1 : 0
        focusPolicy: Qt.NoFocus
        activeFocusOnTab: false
        font.pixelSize: 10
        padding: 2
        ToolTip.visible: hovered
        ToolTip.text: qsTr("Unit")
        Accessible.name: qsTr("Unit")
        onActivated: function(index) {
            field.unit = index === 1 ? "%" : "px"
        }
    }
}
