import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

/// Setting a new size for the document, as a dialog.
///
/// Resize used to be a column of fields in the Editor's inspector. It is a
/// question with a beginning and an end — what size, and then apply or not — so
/// it is asked the way every other form in this window is asked: a `DialogFrame`
/// with its own title bar and its own action row, and a body of `FormRow`s.
///
/// The form deliberately carries no picture of the result: the size is typed as
/// two numbers, and an asynchronous preview inside a modal form read as the
/// dialog "loading" before it settled. The document itself does not move until
/// Apply.
///
/// The form follows a scale tool rather than a ratio table: Width and Height
/// are two numbers, the chain between them is the only aspect lock, and a
/// concrete `Size preset` fills both. The `Fit` row answers the question a
/// resize cannot avoid when the shape changes — what happens to the source when
/// the target is not its shape:
///
/// - `Stretch to size` scales the whole frame and loses nothing. It is the
///   default, because the user asked for a size, not for a decision about
///   which pixels to throw away.
/// - `Crop to fill` keeps the source's shape and discards a centred rectangle,
///   which is what every resize used to do without saying so.
/// - `Fit with background` scales the whole frame inside the target and pads
///   the leftover with the `Background` colour (or leaves it transparent).
///
/// Only the last one has a background to choose, so that row appears with it.
/// The filter dropdown travels in the command, so it changes the resampling
/// kernel instead of only its label.
///
/// - **Apply** sends `editor_resize` (through the editor's `command` signal)
///   and closes. It is disabled while the pair is the document's own size,
///   because Core would answer a no-op.
/// - **Cancel**, the × or Escape close without sending anything.
DialogFrame {
    id: dialog
    namePrefix: "resize"
    title: qsTr("Resize image")
    preferredWidth: 520

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
    /// `stretch`, `cover` or `pad`; `stretch` is the lossless default.
    property string fitMode: "stretch"
    /// The Editor's one background, handed in: this form does not own a colour,
    /// it only names the role the padding plays. `pad` always has one — a
    /// colour, or nothing at all — so Core's `resize_pad_needs_colour` can no
    /// longer be reached from here; the line stays for API callers.
    property color backgroundColor: "#ffffff"
    property bool backgroundTransparent: false
    /// Whether the document is a JPEG, so the background list can say what its
    /// encoder does to a clear area. The form does not decide it; the Editor
    /// does, and hands it in the way it hands the colour.
    property bool documentIsJpeg: false
    signal backgroundTransparentRequested()
    signal backgroundColorRequested(string value)
    /// A key from `filters`; `auto` is the fast box average for a downscale.
    property string filter: "auto"

    readonly property var fits: [
        { key: "stretch", label: qsTr("Stretch to size") },
        { key: "cover", label: qsTr("Crop to fill") },
        { key: "pad", label: qsTr("Fit with background") }
    ]
    readonly property var filters: [
        { key: "auto", label: qsTr("Auto") },
        { key: "bilinear", label: qsTr("Bilinear") },
        { key: "bicubic", label: qsTr("Bicubic") },
        { key: "bspline", label: qsTr("BSpline") },
        { key: "lanczos3", label: qsTr("Lanczos3") },
        { key: "nearest", label: qsTr("Nearest") }
    ]

    /// The × is Cancel, not Apply.
    onCloseRequested: dialog.close()

    /// Start the chain from the pair on screen, or from the document when a
    /// side is empty. This is the only place the lock is captured.
    function captureRatio() {
        var width = widthField.acceptableInput ? widthField.pixels() : 0
        var height = heightField.acceptableInput ? heightField.pixels() : 0
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
        // A size form opens in pixels, the unit the document is measured in;
        // a previous visit's `%` would describe the same size in a way that
        // makes the two fields read `100` before anything is typed.
        widthField.unit = "px"
        heightField.unit = "px"
        var width = Math.max(1, Math.round(dialog.documentWidth))
        var height = Math.max(1, Math.round(dialog.documentHeight))
        widthField.setPixels(width)
        heightField.setPixels(height)
        dialog.fitMode = "stretch"
        dialog.filter = "auto"
        dialog.lockedRatio = { width: width, height: height }
        dialog.setConstraint(true)
        presetBox.currentIndex = dialog.matchingPreset()
        fitBox.currentIndex = dialog.fitIndex()
        filterBox.currentIndex = dialog.filterIndex()
    }

    /// A pending focus request, so `opened` cannot steal focus back after a
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
        widthField.inputField.forceActiveFocus()
        widthField.inputField.selectAll()
        // Keep the request alive until the field really owns the keyboard:
        // before the popup is visible `forceActiveFocus` can do nothing, and
        // `opened` gets one more try.
        if (widthField.inputField.activeFocus) dialog.focusPending = false
    }

    /// Whether Apply would do something. Core's own rule: the same width and
    /// height is a no-op, background or not, because fitting the whole source
    /// into its own size adds nothing.
    function changed() {
        if (!dialog.fieldsValid()) return false
        return widthField.pixels() !== Math.round(dialog.documentWidth)
                || heightField.pixels() !== Math.round(dialog.documentHeight)
    }

    function fieldsValid() {
        return !!dialog.documentReady
                && widthField.acceptableInput && heightField.acceptableInput
                && widthField.pixels() > 0 && heightField.pixels() > 0
    }

    /// Index of the preset that matches both fields, or -1 for `Custom`.
    function matchingPreset() {
        if (!widthField.acceptableInput || !heightField.acceptableInput) return -1
        var width = widthField.pixels()
        var height = heightField.pixels()
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
        var width = widthField.pixels()
        if (!(width > 0)) return
        var factor = dialog.lockedRatio
        if (factor && factor.width > 0 && factor.height > 0) {
            heightField.setPixels(Math.max(1, Math.min(20000,
                    Math.round(width * factor.height / factor.width))))
        }
        presetBox.currentIndex = dialog.matchingPreset()
    }

    function linkWidthFromHeight() {
        if (!dialog.constraint || !heightField.acceptableInput) return
        var height = heightField.pixels()
        if (!(height > 0)) return
        var factor = dialog.lockedRatio
        if (factor && factor.width > 0 && factor.height > 0) {
            widthField.setPixels(Math.max(1, Math.min(20000,
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
        widthField.setPixels(preset.width)
        heightField.setPixels(preset.height)
        dialog.lockedRatio = { width: preset.width, height: preset.height }
        presetBox.currentIndex = index
    }

    function fitIndex() {
        for (var index = 0; index < dialog.fits.length; ++index) {
            if (dialog.fits[index].key === dialog.fitMode) return index
        }
        return 0
    }

    /// Pick how an aspect change is handled. Choosing a pad keeps whatever
    /// background was already chosen; the other two simply hide that row.
    function chooseFit(index) {
        if (index < 0 || index >= dialog.fits.length) return
        dialog.fitMode = dialog.fits[index].key
        fitBox.currentIndex = index
    }

    function filterIndex() {
        for (var index = 0; index < dialog.filters.length; ++index) {
            if (dialog.filters[index].key === dialog.filter) return index
        }
        return 0
    }

    /// The three bytes the typed command carries, or null for no padding.
    function rgb(color) {
        return [Math.round(color.r * 255), Math.round(color.g * 255),
                Math.round(color.b * 255)]
    }

    /// A `color` as `#rrggbb`, which is what the Editor's pair stores and what
    /// the row shows beside the swatch.
    function colorText(value) {
        function byte(part) {
            var text = Math.round(part * 255).toString(16)
            return text.length < 2 ? "0" + text : text
        }
        return "#" + byte(value.r) + byte(value.g) + byte(value.b)
    }

    /// Open the background list under the row's swatch. The list is the same
    /// component the rail and the Crop panel use; only the item it hangs from
    /// differs.
    function openBackgroundList(anchor) {
        if (!anchor) return
        backgroundPopup.transparent = dialog.backgroundTransparent
        backgroundPopup.colour = dialog.backgroundColor
        backgroundPopup.showBelow(anchor)
    }

    /// The colour the command carries, or null when the mode paints nothing.
    /// A padding always carries one: the Editor's background, which may be
    /// "nothing at all" — the colour plus `fill_alpha: 0` the wire already uses
    /// for a clear area.
    function fillForCommand() {
        if (dialog.fitMode !== "pad") return null
        if (dialog.backgroundTransparent) return [0, 0, 0]
        return dialog.rgb(dialog.backgroundColor)
    }

    function fillAlpha() {
        if (dialog.fitMode !== "pad") return 255
        return dialog.backgroundTransparent ? 0 : 255
    }

    function apply() {
        if (!dialog.changed()) return
        dialog.resizeRequested(widthField.pixels(), heightField.pixels(),
                               dialog.fillForCommand(), dialog.fillAlpha(),
                               dialog.filter, dialog.fitMode)
        dialog.close()
    }

    /// Before the first visible frame the form holds the document's own size.
    /// `opened` is emitted only after the style's enter transition, so centring
    /// there made the first frames appear at the positioner's default corner and
    /// then jump to the middle; the frame centres in `onAboutToShow`, and this
    /// hook is where the values land.
    function prepare() {
        dialog.fillFromDocument()
        // The field does not accept focus until the popup is visible; one turn
        // of the event loop is enough, and the fade does not delay it. If it
        // still did not take, `opened` gets one more try.
        dialog.requestWidthFocus()
    }
    onOpened: if (dialog.focusPending) Qt.callLater(dialog.focusWidth)

    // ------------------------------------------------------------------- body
    FormSection {
        objectName: "resizeSizeSection"
        theme: dialog.theme
        // Not the bare "Size": the browser's file-size column owns that word,
        // and the catalogue gives one translation per English string, which
        // there is "dung lượng" — a picture's file weight, not its sides.
        title: qsTr("Dimensions")
        Layout.fillWidth: true

        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 8
            rowSpacing: 6

            Label {
                text: qsTr("Width")
                color: dialog.theme.textMuted
                elide: Text.ElideRight
                Layout.preferredWidth: dialog.labelWidth
                Layout.maximumWidth: dialog.labelWidth
            }
            UnitField {
                id: widthField
                objectName: "resizeWidth"
                Layout.fillWidth: true
                font.pixelSize: 12
                placeholderText: dialog.documentReady
                                 ? (widthField.percent ? "100"
                                    : String(Math.round(dialog.documentWidth))) : "0"
                unitReference: dialog.documentWidth
                minimumPixels: 1
                maximumPixels: 20000
                // The keyboard path this form is built around: opening
                // selects the width, Tab goes to Height, Enter applies.
                nextField: heightField
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
                elide: Text.ElideRight
                Layout.preferredWidth: dialog.labelWidth
                Layout.maximumWidth: dialog.labelWidth
            }
            UnitField {
                id: heightField
                objectName: "resizeHeight"
                Layout.fillWidth: true
                font.pixelSize: 12
                placeholderText: dialog.documentReady
                                 ? (heightField.percent ? "100"
                                    : String(Math.round(dialog.documentHeight))) : "0"
                unitReference: dialog.documentHeight
                minimumPixels: 1
                maximumPixels: 20000
                previousField: widthField
                onTextEdited: dialog.linkWidthFromHeight()
                onAccepted: dialog.apply()
            }
        }

        FormRow {
            label: qsTr("Size preset")
            labelWidth: dialog.labelWidth
            theme: dialog.theme
            Layout.fillWidth: true

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
    }

    FormSection {
        objectName: "resizeFitSection"
        theme: dialog.theme
        title: qsTr("Fitting")
        Layout.fillWidth: true

        FormRow {
            label: qsTr("Fit")
            labelWidth: dialog.labelWidth
            theme: dialog.theme
            Layout.fillWidth: true

            ComboBox {
                id: fitBox
                objectName: "resizeFit"
                Layout.fillWidth: true
                model: dialog.fits
                textRole: "label"
                currentIndex: dialog.fitIndex()
                onActivated: dialog.chooseFit(currentIndex)
            }
        }

        // Only a pad paints pixels the source does not have, so it is the only
        // mode with a background to pick. The background is the Editor's own —
        // the same colour a grown crop adds — so this row shows it and offers
        // the one list that can change it.
        FormRow {
            id: backgroundRow
            objectName: "resizeBackground"
            label: qsTr("Background")
            labelWidth: dialog.labelWidth
            theme: dialog.theme
            Layout.fillWidth: true
            visible: dialog.fitMode === "pad"

            Rectangle {
                id: backgroundSwatch
                objectName: "resizeBackgroundSwatch"
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 4
                color: dialog.backgroundTransparent
                       ? "transparent" : dialog.backgroundColor
                border.width: swatchArea.containsMouse ? 2 : 1
                border.color: swatchArea.containsMouse
                              ? dialog.theme.accent : dialog.theme.border
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Background color (new canvas)")

                Checkerboard {
                    objectName: "resizeBackgroundCheckerboard"
                    anchors.fill: parent
                    visible: dialog.backgroundTransparent
                    square: 5
                }

                MouseArea {
                    id: swatchArea
                    objectName: "resizeBackgroundArea"
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 500
                    ToolTip.text: qsTr("Background color (new canvas)")
                    onClicked: dialog.openBackgroundList(backgroundSwatch)
                }
            }
            Label {
                objectName: "resizeBackgroundName"
                Layout.fillWidth: true
                text: dialog.backgroundTransparent
                      ? qsTr("Transparent")
                      : dialog.colorText(dialog.backgroundColor)
                color: dialog.theme.text
                elide: Text.ElideRight
            }
        }

        Label {
            Layout.fillWidth: true
            visible: dialog.fitMode === "pad"
            text: dialog.backgroundTransparent
                  ? qsTr("Fits the whole image inside the target and leaves the leftover transparent.")
                  : qsTr("Fits the whole image inside the target and fills the leftover with this background.")
            color: dialog.theme.textMuted
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }
    }

    // The kernel is a separate question from the shape: the two rows above
    // decide which pixels survive, this one decides how the survivors are
    // averaged.
    FormSection {
        objectName: "resizeFilterSection"
        theme: dialog.theme
        title: qsTr("Resampling")
        Layout.fillWidth: true

        FormRow {
            label: qsTr("Filter")
            labelWidth: dialog.labelWidth
            theme: dialog.theme
            Layout.fillWidth: true

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
            text: qsTr("The resampling filter decides how the pixels are combined when the size changes.")
            color: dialog.theme.textMuted
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }
    }

    // ----------------------------------------------------------------- footer
    footer: DialogFooter {
        namePrefix: "resize"
        theme: dialog.theme
        height: dialog.footerHeight

        // Back to the document's own size in the form. It sends nothing, so
        // a half-entered size never reaches Core. Like Settings' Defaults it
        // sits apart on the left, the way GTK and KDE put the
        // value-restoring button.
        PanelAction {
            objectName: "resizeReset"
            theme: dialog.theme
            text: qsTr("Reset")
            implicitWidth: 88
            onClicked: {
                dialog.fillFromDocument()
                dialog.requestWidthFocus()
            }
        }
        Item { Layout.fillWidth: true }
        PanelAction {
            objectName: "resizeCancel"
            theme: dialog.theme
            text: qsTr("Cancel")
            implicitWidth: 88
            onClicked: dialog.close()
        }
        PanelAction {
            objectName: "resizeApply"
            theme: dialog.theme
            text: qsTr("Apply")
            implicitWidth: 88
            primary: true
            // Core refuses the document's own size as a no-op, so the
            // button says so before it is pressed.
            enabled: dialog.changed()
            onClicked: dialog.apply()
        }
    }

    /// The background list, opened under the row's swatch. It is a child of
    /// this form rather than of the window, so the form's modality does not
    /// swallow it while the form is the only thing on screen.
    BackgroundPopup {
        id: backgroundPopup
        objectName: "resizeBackgroundPopup"
        theme: dialog.theme
        transparent: dialog.backgroundTransparent
        colour: dialog.backgroundColor
        alphaLostWarning: dialog.documentIsJpeg
        onTransparentPicked: dialog.backgroundTransparentRequested()
        onColourPicked: function(value) { dialog.backgroundColorRequested(value) }
        onCustomPicked: backgroundColorDialog.open()
    }

    /// `Custom color…` in the list. Its answer travels up to the Editor's one
    /// background, so the next form, the rail's pair and the crop panel all
    /// read the colour this run picked.
    property ColorPickerDialog backgroundColorDialog: ColorPickerDialog {
        id: backgroundColorDialog
        objectName: "resizeBackgroundColorDialog"
        parent: dialog.parent
        theme: dialog.theme
        title: qsTr("Background color")
        selectedColor: dialog.backgroundColor
        onAccepted: dialog.backgroundColorRequested(dialog.colorText(selectedColor))
    }

    /// Apply: the user chose this size. The editor turns it into one
    /// `editor_resize`; the dialog closes on its own. `fill` is null for the
    /// existing cover crop, and `fillAlpha` is 0 for the transparent pad.
    signal resizeRequested(int width, int height, var fill, int fillAlpha, string filter,
                           string mode)
}
