import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

/// Setting a new size for the document, as a dialog.
///
/// Resize used to be a column of fields in the Editor's inspector. It is a
/// question with a beginning and an end — what size, and then apply or not — so
/// it is asked the way Settings is asked: a `Dialog` with its own header drag,
/// a form that owns its state, and a footer of explicit buttons.
///
/// The form deliberately carries no picture of the result: the size is typed as
/// two numbers, and an asynchronous preview inside a modal form read as the
/// dialog "loading" before it settled. The document itself does not move until
/// Apply.
///
/// The form follows a scale tool rather than a ratio table: Width and Height
/// are two numbers, the chain between them is the only aspect lock, and a
/// concrete `Size preset` fills both. The background dropdown always shows how
/// the leftover is handled — `None` is the existing centred cover crop, a colour
/// fits the whole picture and pads the leftover, and `Transparent` pads with
/// alpha 0. The filter dropdown travels in the command, so it changes the
/// resampling kernel instead of only its label.
///
/// - **Apply** sends `editor_resize` (through the editor's `command` signal)
///   and closes. It is disabled while the pair is the document's own size,
///   because Core would answer a no-op.
/// - **Cancel**, the × or Escape close without sending anything.
Dialog {
    id: dialog
    property Theme theme: Theme {}

    /// The document the size is for. Read-only for the dialog: Core owns the
    /// pixels, the dialog only formats a command.
    property real documentWidth: 0
    property real documentHeight: 0
    property bool documentReady: false
    /// The concrete sizes, from the Editor. Handed in rather than duplicated so
    /// the two size tools offer one list.
    property var presets: []

    // ------------------------------------------------------------- form state
    /// The chain is the aspect lock. On open it follows the document's shape;
    /// picking a preset moves it to that preset's shape.
    property bool constraint: true
    /// The W:H pair the chain keeps. Zero until a valid pair or a preset exists.
    property var lockedRatio: ({ width: 0, height: 0 })
    /// `none`, `transparent`, `black`, `white`, `gray` or `custom`.
    property string backgroundMode: "none"
    property color customColor: "#808080"
    /// A key from `filters`; `auto` is the fast box average for a downscale.
    property string filter: "auto"

    readonly property var backgrounds: [
        { key: "none", label: qsTr("None") },
        { key: "transparent", label: qsTr("Transparent") },
        { key: "black", label: qsTr("Black") },
        { key: "white", label: qsTr("White") },
        { key: "gray", label: qsTr("Gray") },
        { key: "custom", label: qsTr("Custom color…") }
    ]
    readonly property var filters: [
        { key: "auto", label: qsTr("Auto") },
        { key: "bilinear", label: qsTr("Bilinear") },
        { key: "bicubic", label: qsTr("Bicubic") },
        { key: "bspline", label: qsTr("BSpline") },
        { key: "lanczos3", label: qsTr("Lanczos3") },
        { key: "nearest", label: qsTr("Nearest") }
    ]

    title: qsTr("Resize image")
    modal: true
    dim: true
    width: Math.min(520, parent ? parent.width - 48 : 520)
    // The form decides the height up to the window's: a fixed tall box would
    // leave a blank page under the footer in one language and clip a wrapped
    // sentence in another. 112 is the header (52) and footer (60).
    height: Math.min(parent ? parent.height - 48 : 720,
                     112 + resizeColumn.implicitHeight + 40)
    padding: 0
    // Escape is Cancel, like Settings and like every other dialog here. A click
    // outside does not dismiss: a form should be left on purpose.
    closePolicy: Popup.CloseOnEscape
    // x/y are set by hand, not with `anchors.centerIn`: an anchor owns the
    // position and snaps a written x back within a frame, which also makes the
    // header drag impossible (the same measurement Settings records).
    property bool moved: false
    function centerInParent() {
        if (!parent) return
        x = Math.round((parent.width - width) / 2)
        y = Math.round((parent.height - height) / 2)
    }
    onWidthChanged: if (!moved) centerInParent()
    onHeightChanged: if (!moved) centerInParent()

    /// Start the chain from the pair on screen, or from the document when a
    /// side is empty. This is the only place the lock is captured.
    function captureRatio() {
        var width = widthField.acceptableInput ? parseInt(widthField.text) : 0
        var height = heightField.acceptableInput ? parseInt(heightField.text) : 0
        if (!(width > 0) || !(height > 0)) {
            if (!dialog.documentReady) return
            width = Math.max(1, Math.round(dialog.documentWidth))
            height = Math.max(1, Math.round(dialog.documentHeight))
        }
        dialog.lockedRatio = { width: width, height: height }
    }

    /// Turn the chain on or off. Enabling it captures the shape it must keep,
    /// so switching the lock on after typing a pair keeps that pair's shape.
    function setConstraint(enabled) {
        dialog.constraint = enabled
        constraintButton.checked = enabled
        if (enabled) dialog.captureRatio()
    }

    /// The size the fields start on: the document's own, so the form describes
    /// what is on screen before anything is typed. `Reset` and every open go
    /// through here; the background and filter start at their defaults.
    function fillFromDocument() {
        var width = Math.max(1, Math.round(dialog.documentWidth))
        var height = Math.max(1, Math.round(dialog.documentHeight))
        widthField.text = String(width)
        heightField.text = String(height)
        dialog.backgroundMode = "none"
        dialog.filter = "auto"
        dialog.lockedRatio = { width: width, height: height }
        dialog.setConstraint(true)
        presetBox.currentIndex = dialog.matchingPreset()
        backgroundBox.currentIndex = dialog.backgroundIndex()
        filterBox.currentIndex = dialog.filterIndex()
    }

    /// A pending focus request, so `onOpened` cannot steal focus back after a
    /// fast user already tabbed to Height or started typing.
    property bool focusPending: false
    function requestWidthFocus() {
        dialog.focusPending = true
        Qt.callLater(dialog.focusWidth)
    }

    /// Focus the first field and select the number the form opened on, so a
    /// keyboard visitor can type the new width immediately. `Tab` then lands on
    /// Height (bound on the field) and Enter applies from either one.
    function focusWidth() {
        if (!dialog.focusPending) return
        widthField.forceActiveFocus()
        widthField.selectAll()
        // Keep the request alive until the field really owns the keyboard:
        // before the popup is visible `forceActiveFocus` can do nothing, and
        // `opened` gets one more try.
        if (widthField.activeFocus) dialog.focusPending = false
    }

    /// Whether Apply would do something. Core's own rule: the same width and
    /// height is a no-op, background or not, because fitting the whole source
    /// into its own size adds nothing.
    function changed() {
        if (!dialog.fieldsValid()) return false
        return parseInt(widthField.text) !== Math.round(dialog.documentWidth)
                || parseInt(heightField.text) !== Math.round(dialog.documentHeight)
    }

    function fieldsValid() {
        return !!dialog.documentReady
                && widthField.acceptableInput && heightField.acceptableInput
                && parseInt(widthField.text) > 0 && parseInt(heightField.text) > 0
    }

    /// Index of the preset that matches both fields, or -1 for `Custom`.
    function matchingPreset() {
        if (!widthField.acceptableInput || !heightField.acceptableInput) return -1
        var width = parseInt(widthField.text)
        var height = parseInt(heightField.text)
        for (var index = 0; index < dialog.presets.length; ++index) {
            var preset = dialog.presets[index]
            if (preset.width === width && preset.height === height) return index
        }
        return -1
    }

    /// Typing one side keeps the other on the locked shape. Programmatic writes
    /// (a preset, Reset, the linked side) do not come through `textEdited`, so
    /// they never feed back on themselves.
    function linkHeightFromWidth() {
        if (!dialog.constraint || !widthField.acceptableInput) return
        var width = parseInt(widthField.text)
        if (!(width > 0)) return
        var factor = dialog.lockedRatio
        if (factor && factor.width > 0 && factor.height > 0) {
            heightField.text = String(Math.max(1, Math.min(20000,
                    Math.round(width * factor.height / factor.width))))
        }
        presetBox.currentIndex = dialog.matchingPreset()
    }

    function linkWidthFromHeight() {
        if (!dialog.constraint || !heightField.acceptableInput) return
        var height = parseInt(heightField.text)
        if (!(height > 0)) return
        var factor = dialog.lockedRatio
        if (factor && factor.width > 0 && factor.height > 0) {
            widthField.text = String(Math.max(1, Math.min(20000,
                    Math.round(height * factor.width / factor.height))))
        }
        presetBox.currentIndex = dialog.matchingPreset()
    }

    /// Apply a concrete size. `onActivated` calls this for a real pick; a
    /// programmatic `currentIndex` write (the link code mirrors a matching
    /// size) must not re-apply it. A preset also becomes the shape the chain
    /// keeps, so typing one side after picking 16:9 stays 16:9.
    function choosePreset(index) {
        if (index < 0 || index >= dialog.presets.length) return
        var preset = dialog.presets[index]
        widthField.text = String(preset.width)
        heightField.text = String(preset.height)
        dialog.lockedRatio = { width: preset.width, height: preset.height }
        presetBox.currentIndex = index
    }

    function backgroundIndex() {
        for (var index = 0; index < dialog.backgrounds.length; ++index) {
            if (dialog.backgrounds[index].key === dialog.backgroundMode) return index
        }
        return 0
    }

    /// Pick a background. `Custom color…` opens the colour chooser; a cancelled
    /// chooser leaves the previous choice on screen rather than pretending a
    /// colour was picked.
    function chooseBackground(index) {
        if (index < 0 || index >= dialog.backgrounds.length) return
        var key = dialog.backgrounds[index].key
        if (key === "custom") {
            fillColorDialog.open()
            return
        }
        dialog.backgroundMode = key
        backgroundBox.currentIndex = index
    }

    function filterIndex() {
        for (var index = 0; index < dialog.filters.length; ++index) {
            if (dialog.filters[index].key === dialog.filter) return index
        }
        return 0
    }

    /// The swatch the dropdown shows next to its label. `None` has no colour to
    /// show, and transparent is drawn as the form's own surface with a zero.
    function backgroundColor() {
        switch (dialog.backgroundMode) {
        case "transparent": return dialog.theme.surfaceAlt
        case "black": return "#000000"
        case "white": return "#ffffff"
        case "gray": return "#808080"
        case "custom": return dialog.customColor
        default: return "transparent"
        }
    }

    /// The three bytes the typed command carries, or null for no padding.
    function rgb(color) {
        return [Math.round(color.r * 255), Math.round(color.g * 255),
                Math.round(color.b * 255)]
    }

    function fillForCommand() {
        switch (dialog.backgroundMode) {
        case "none": return null
        case "transparent": return [0, 0, 0]
        case "black": return [0, 0, 0]
        case "white": return [255, 255, 255]
        case "gray": return [128, 128, 128]
        case "custom": return dialog.rgb(dialog.customColor)
        default: return null
        }
    }

    function fillAlpha() {
        return dialog.backgroundMode === "transparent" ? 0 : 255
    }

    function apply() {
        if (!dialog.changed()) return
        dialog.resizeRequested(parseInt(widthField.text), parseInt(heightField.text),
                               dialog.fillForCommand(), dialog.fillAlpha(),
                               dialog.filter)
        dialog.close()
    }

    // Position and fill the form before it becomes visible. `opened` is emitted
    // only after the style's enter transition (Breeze fades for ~300 ms), so
    // centring there made the first frames appear at the positioner's default
    // corner and then jump to the middle. `aboutToShow` fires before
    // `visibleChanged`, while the popup already has its parent and its size.
    onAboutToShow: {
        moved = false
        centerInParent()
        dialog.fillFromDocument()
        // The field does not accept focus until the popup is visible; one turn
        // of the event loop is enough, and the fade does not delay it. If it
        // still did not take, `opened` gets one more try.
        dialog.requestWidthFocus()
    }
    onOpened: if (dialog.focusPending) Qt.callLater(dialog.focusWidth)

    background: Rectangle {
        color: dialog.theme.surface
        border.color: dialog.theme.border
        border.width: 1
        radius: dialog.theme.radius
    }

    header: Rectangle {
        objectName: "resizeHeader"
        implicitHeight: 52
        color: dialog.theme.surfaceAlt
        border.color: dialog.theme.border
        border.width: 1
        // The title bar moves the dialog, the way Settings does: a user may
        // want the form off the picture's middle. `target: null` keeps the
        // handler off the coordinates and moves the dialog itself; the clamp
        // stops a drag parking it outside.
        DragHandler {
            target: null
            property real originX: 0
            property real originY: 0
            onActiveChanged: if (active) { originX = dialog.x; originY = dialog.y; dialog.moved = true }
            onActiveTranslationChanged: {
                if (!active) return
                var maxX = dialog.parent ? Math.max(0, dialog.parent.width - dialog.width) : dialog.x
                var maxY = dialog.parent ? Math.max(0, dialog.parent.height - dialog.height) : dialog.y
                dialog.x = Math.max(0, Math.min(maxX, originX + activeTranslation.x))
                dialog.y = Math.max(0, Math.min(maxY, originY + activeTranslation.y))
            }
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 10
            Label {
                text: dialog.title
                color: dialog.theme.text
                font.pixelSize: 17
                font.bold: true
                Layout.fillWidth: true
            }
            // The × is Cancel, not Apply.
            ToolButton {
                objectName: "resizeClose"
                text: qsTr("×")
                font.pixelSize: 24
                onClicked: dialog.close()
            }
        }
    }

    contentItem: Flickable {
        objectName: "resizeContent"
        clip: true
        contentHeight: resizeColumn.implicitHeight + 40
        // On a short window the whole form may not fit; the dialog caps its
        // height at the window, so the bar is how a clipped form says so.
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: resizeColumn
            objectName: "resizeColumn"
            x: 20
            y: 20
            width: dialog.width - 40
            spacing: 10

            GridLayout {
                Layout.fillWidth: true
                columns: 3
                columnSpacing: 6
                rowSpacing: 6

                Label {
                    text: qsTr("Width")
                    color: dialog.theme.textMuted
                }
                TextField {
                    id: widthField
                    objectName: "resizeWidth"
                    Layout.fillWidth: true
                    font.pixelSize: 12
                    placeholderText: dialog.documentReady
                                     ? String(Math.round(dialog.documentWidth)) : "0"
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 1; top: 20000 }
                    // The keyboard path this form is built around: opening
                    // selects the width, Tab goes to Height, Enter applies.
                    KeyNavigation.tab: heightField
                    onTextEdited: dialog.linkHeightFromWidth()
                    onAccepted: dialog.apply()
                }
                ToolButton {
                    id: constraintButton
                    objectName: "resizeConstraint"
                    Layout.rowSpan: 2
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 32
                    implicitHeight: 32
                    checkable: true
                    checked: dialog.constraint
                    enabled: dialog.documentReady
                    focusPolicy: Qt.NoFocus
                    Accessible.name: qsTr("Constrain proportions")
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Constrain proportions")
                    onToggled: dialog.setConstraint(checked)

                    // The chain is drawn, not typed: an emoji glyph was blank
                    // on this session's font, and a themed `Icon` would depend
                    // on the desktop having an `insert-link` icon. Two capsule
                    // links on a 45° diagonal read as a chain at 18 px and
                    // follow the theme's own colours, including the accent
                    // when the lock is on.
                    contentItem: Canvas {
                        id: chainCanvas
                        implicitWidth: 20
                        implicitHeight: 20
                        Component.onCompleted: requestPaint()
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            ctx.strokeStyle = !constraintButton.enabled
                                    ? dialog.theme.textMuted
                                    : (constraintButton.checked ? dialog.theme.accent
                                                                : dialog.theme.text)
                            ctx.lineWidth = 1.5
                            ctx.lineCap = "round"
                            ctx.translate(width / 2, height / 2)
                            ctx.rotate(-Math.PI / 4)
                            drawLink(ctx, -3.7)
                            drawLink(ctx, 3.7)
                        }
                        /// One rounded link outline centred on `cx`.
                        function drawLink(ctx, cx) {
                            var span = 9
                            var thick = 6
                            var radius = thick / 2
                            ctx.beginPath()
                            ctx.moveTo(cx - span / 2 + radius, -radius)
                            ctx.lineTo(cx + span / 2 - radius, -radius)
                            ctx.arc(cx + span / 2 - radius, 0, radius,
                                    -Math.PI / 2, Math.PI / 2)
                            ctx.lineTo(cx - span / 2 + radius, radius)
                            ctx.arc(cx - span / 2 + radius, 0, radius,
                                    Math.PI / 2, -Math.PI / 2)
                            ctx.closePath()
                            ctx.stroke()
                        }
                        Connections {
                            target: constraintButton
                            function onCheckedChanged() { chainCanvas.requestPaint() }
                            function onEnabledChanged() { chainCanvas.requestPaint() }
                        }
                    }
                }
                Label {
                    text: qsTr("Height")
                    color: dialog.theme.textMuted
                }
                TextField {
                    id: heightField
                    objectName: "resizeHeight"
                    Layout.fillWidth: true
                    font.pixelSize: 12
                    placeholderText: dialog.documentReady
                                     ? String(Math.round(dialog.documentHeight)) : "0"
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 1; top: 20000 }
                    KeyNavigation.backtab: widthField
                    onTextEdited: dialog.linkWidthFromHeight()
                    onAccepted: dialog.apply()
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    text: qsTr("Size preset")
                    color: dialog.theme.textMuted
                }
                ComboBox {
                    id: presetBox
                    objectName: "resizeSizePreset"
                    Layout.fillWidth: true
                    // Nothing is applied until the list is activated:
                    // `onCurrentIndexChanged` also fires for the programmatic
                    // index write that mirrors a typed pair, and that write must
                    // not re-apply the row.
                    currentIndex: -1
                    model: dialog.presets
                    textRole: "label"
                    displayText: currentIndex < 0 ? qsTr("Custom") : currentText
                    onActivated: dialog.choosePreset(currentIndex)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: qsTr("Background")
                    color: dialog.theme.textMuted
                }
                ComboBox {
                    id: backgroundBox
                    objectName: "resizeBackground"
                    Layout.fillWidth: true
                    model: dialog.backgrounds
                    textRole: "label"
                    currentIndex: dialog.backgroundIndex()
                    onActivated: dialog.chooseBackground(currentIndex)
                }
                Rectangle {
                    objectName: "resizeBackgroundSwatch"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    radius: 4
                    color: dialog.backgroundColor()
                    border.width: 1
                    border.color: dialog.theme.border
                    visible: dialog.backgroundMode !== "none"
                    Label {
                        anchors.centerIn: parent
                        visible: dialog.backgroundMode === "transparent"
                        text: "0"
                        color: dialog.theme.textMuted
                        font.pixelSize: 10
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: qsTr("Filter")
                    color: dialog.theme.textMuted
                }
                ComboBox {
                    id: filterBox
                    objectName: "resizeFilter"
                    Layout.fillWidth: true
                    model: dialog.filters
                    textRole: "label"
                    currentIndex: dialog.filterIndex()
                    onActivated: dialog.filter = dialog.filters[currentIndex].key
                }
            }

            Label {
                Layout.fillWidth: true
                visible: dialog.backgroundMode !== "none"
                text: dialog.backgroundMode === "transparent"
                      ? qsTr("Fits the whole image inside the target and leaves the leftover transparent.")
                      : qsTr("Fits the whole image inside the target and fills the leftover with this background.")
                color: dialog.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }
    }

    footer: Rectangle {
        objectName: "resizeButtons"
        implicitHeight: 60
        color: dialog.theme.surface
        border.color: dialog.theme.border
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 8

            // Back to the document's own size in the form. It sends nothing, so
            // a half-entered size never reaches Core.
            Button {
                objectName: "resizeReset"
                text: qsTr("Reset")
                onClicked: {
                    dialog.fillFromDocument()
                    dialog.requestWidthFocus()
                }
            }
            Item { Layout.fillWidth: true }
            Button {
                objectName: "resizeCancel"
                text: qsTr("Cancel")
                onClicked: dialog.close()
            }
            Button {
                objectName: "resizeApply"
                text: qsTr("Apply")
                highlighted: true
                // Core refuses the document's own size as a no-op, so the
                // button says so before it is pressed.
                enabled: dialog.changed()
                onClicked: dialog.apply()
            }
        }
    }

    ColorDialog {
        id: fillColorDialog
        objectName: "resizeFillColorDialog"
        title: qsTr("Background color")
        selectedColor: dialog.customColor
        onAccepted: {
            dialog.customColor = selectedColor
            dialog.backgroundMode = "custom"
            backgroundBox.currentIndex = dialog.backgroundIndex()
        }
        onRejected: backgroundBox.currentIndex = dialog.backgroundIndex()
    }

    /// Apply: the user chose this size. The editor turns it into one
    /// `editor_resize`; the dialog closes on its own. `fill` is null for the
    /// existing cover crop, and `fillAlpha` is 0 for the transparent pad.
    signal resizeRequested(int width, int height, var fill, int fillAlpha, string filter)
}
