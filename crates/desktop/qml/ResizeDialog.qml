import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

/// Setting a new size for the document, as a dialog.
///
/// Resize used to be a column of fields in the Editor's inspector. It is a
/// question with a beginning and an end — what size, and then apply or not — so
/// it is asked the way Settings is asked: a `Dialog` with its own header drag,
/// a form that owns its state, and a footer of explicit buttons. The dialog
/// carries a small preview of the result, because a result is what the user is
/// choosing between; the document itself does not move until Apply.
///
/// The two answers mirror the old panel exactly, so nothing about the edit
/// changed, only where it is typed:
///
/// - **Apply** sends `editor_resize` (through the editor's `command` signal)
///   and closes. It is disabled while the pair is the document's own size,
///   because Core would answer a no-op.
/// - **Cancel**, the × or Escape close without sending anything. The preview
///   rendered on the way is a draft: Core keeps it out of the document and the
///   canvas does not draw it once this dialog is closed.
///
/// Width and Height are one shape: the ratio combo decides what typing one side
/// does to the other, `Free` is the only unlinked choice, and the "Keep current
/// ratio" snapshot freezes whatever pair is on screen. The presets are concrete
/// 64-divisible sizes, and the +/- steppers are the same edit path as typing, so
/// they can never disagree with it.
Dialog {
    id: dialog
    property Theme theme: Theme {}

    /// The document the size is for. Read-only for the dialog: Core owns the
    /// pixels, the dialog only formats a command.
    property real documentWidth: 0
    property real documentHeight: 0
    property bool documentReady: false
    /// The ratio table and the concrete sizes, from the Editor. Handed in
    /// rather than duplicated so the two size tools offer one list.
    property var ratios: []
    property var presets: []
    /// The document's own preview (`file://…`), drawn until a draft lands.
    property string documentPreview: ""
    /// Core's newest resize draft, if any. It is filtered by `kind` on the
    /// Editor's side; here it is only drawn.
    property var draft: null

    /// The draft that was already published when the dialog opened: it belongs
    /// to an earlier visit, so it is not this form's answer and is not drawn.
    property string ignoredDraft: ""

    // ------------------------------------------------------------- form state
    property string ratio: "original"
    /// The pair "Keep current ratio" froze, zero until it is picked.
    property var currentRatio: ({ width: 0, height: 0 })
    property bool padFit: false
    property color fillColor: "#ffffff"
    /// Off every time the dialog opens: the preview shows the document itself
    /// until the user asks to see the target.
    property bool livePreview: false

    /// The draft worth drawing: the newest one, and only while Live preview is
    /// on — that toggle is the user's answer to "show me the result", so a
    /// draft Core still holds from before is not drawn behind their back. The
    /// stale draft from an earlier visit is not this form's answer either. A
    /// draft is only ever a resize here, but the kind is checked anyway so a
    /// stray crop draft can never be painted as a size.
    readonly property var shownDraft:
        livePreview && draft && draft.kind === "resize"
        && (draft.path || "") !== ignoredDraft ? draft : null

    readonly property string previewSource:
        shownDraft ? "file://" + shownDraft.path : documentPreview

    /// What the preview is showing, in the words the user needs: the document,
    /// or the target the draft was rendered at.
    readonly property string previewCaption: {
        if (shownDraft) {
            return qsTr("Preview at %1 × %2 — Apply writes it, Cancel keeps the document.")
                    .arg(String(shownDraft.width)).arg(String(shownDraft.height))
        }
        if (!documentReady) return qsTr("No document")
        return qsTr("The document at %1 × %2.")
                .arg(String(Math.round(documentWidth))).arg(String(Math.round(documentHeight)))
    }

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
    // outside does not dismiss: a form with a preview should be left on purpose.
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

    /// The size the fields start on: the document's own, so the form describes
    /// what is on screen before anything is typed, and the steppers start from
    /// a real number. `Reset` and every open go through here.
    function fillFromDocument() {
        dialog.ratio = "original"
        dialog.currentRatio = ({ width: 0, height: 0 })
        dialog.padFit = false
        var width = Math.max(1, Math.round(dialog.documentWidth))
        var height = Math.max(1, Math.round(dialog.documentHeight))
        widthField.text = String(width)
        heightField.text = String(height)
        ratioBox.currentIndex = dialog.ratioIndex()
        presetBox.currentIndex = dialog.matchingPreset()
    }

    /// Whether Apply would do something. Core's own rule: the same width and
    /// height is a no-op, pad colour or not, because fitting the whole source
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

    /// The factor for a ratio key, or null when the sides are not linked.
    function factor(key) {
        for (var index = 0; index < dialog.ratios.length; ++index) {
            var entry = dialog.ratios[index]
            if (entry.key !== key) continue
            if (entry.key === "free") return null
            if (entry.key === "current") {
                if (dialog.currentRatio && dialog.currentRatio.width > 0
                        && dialog.currentRatio.height > 0) return dialog.currentRatio
                if (!dialog.documentReady) return null
                return { width: dialog.documentWidth, height: dialog.documentHeight }
            }
            if (entry.key === "original") {
                if (!dialog.documentReady) return null
                return { width: dialog.documentWidth, height: dialog.documentHeight }
            }
            return entry
        }
        return null
    }

    function ratioIndex() {
        for (var index = 0; index < dialog.ratios.length; ++index) {
            if (dialog.ratios[index].key === dialog.ratio) return index
        }
        return -1
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

    /// Typing one side keeps the other on the chosen ratio. Programmatic writes
    /// (a preset, Reset, the linked side) do not come through `textEdited`, so
    /// they never feed back on themselves.
    function linkHeightFromWidth() {
        if (!widthField.acceptableInput) return
        var width = parseInt(widthField.text)
        if (!(width > 0)) return
        var factor = dialog.factor(dialog.ratio)
        if (factor) {
            heightField.text = String(Math.max(1, Math.min(20000,
                    Math.round(width * factor.height / factor.width))))
        }
        presetBox.currentIndex = dialog.matchingPreset()
    }

    function linkWidthFromHeight() {
        if (!heightField.acceptableInput) return
        var height = parseInt(heightField.text)
        if (!(height > 0)) return
        var factor = dialog.factor(dialog.ratio)
        if (factor) {
            widthField.text = String(Math.max(1, Math.min(20000,
                    Math.round(height * factor.width / factor.height))))
        }
        presetBox.currentIndex = dialog.matchingPreset()
    }

    /// Keep the fields on the selected ratio when the ratio is picked: a 16:9
    /// choice with 1024 × 1024 typed must not leave a square pair on a 16:9
    /// label. The first typed side wins, width first.
    function relinkFields() {
        if (widthField.acceptableInput && parseInt(widthField.text) > 0) {
            dialog.linkHeightFromWidth()
        } else if (heightField.acceptableInput && parseInt(heightField.text) > 0) {
            dialog.linkWidthFromHeight()
        }
    }

    /// Freeze the pair on screen as the "Keep current ratio" shape; the
    /// document's aspect is the honest fallback when a side is empty.
    function captureCurrentRatio() {
        var width = widthField.acceptableInput ? parseInt(widthField.text) : 0
        var height = heightField.acceptableInput ? parseInt(heightField.text) : 0
        if (!(width > 0) || !(height > 0)) {
            if (!dialog.documentReady) return
            width = dialog.documentWidth
            height = dialog.documentHeight
        }
        dialog.currentRatio = { width: width, height: height }
    }

    /// Select a ratio. The combo index is written imperatively because the
    /// control owns `currentIndex`; picking "Keep current ratio" snapshots the
    /// pair before relinking, so the fields on screen become the locked shape.
    function setRatio(key) {
        if (key === "current") dialog.captureCurrentRatio()
        dialog.ratio = key
        ratioBox.currentIndex = dialog.ratioIndex()
    }

    /// One click of a field's +/- stepper. An empty or invalid field starts
    /// from the document's own dimension, so the first nudge moves 4000 to 4001
    /// rather than jumping from 1, and the linked side follows exactly as
    /// typing it would.
    function stepField(field, delta, isWidth) {
        var current = field.acceptableInput ? parseInt(field.text) : 0
        if (!(current > 0)) {
            current = Math.round(isWidth ? dialog.documentWidth : dialog.documentHeight)
        }
        if (!(current > 0)) return
        field.text = String(Math.max(1, Math.min(20000, current + delta)))
        if (isWidth) {
            dialog.linkHeightFromWidth()
        } else {
            dialog.linkWidthFromHeight()
        }
        debounce.restart()
    }

    /// Apply a concrete size. `onActivated` calls this for a real pick; a
    /// programmatic `currentIndex` write (the link code mirrors a matching
    /// size) must not re-apply it.
    function choosePreset(index) {
        if (index < 0 || index >= dialog.presets.length) return
        var preset = dialog.presets[index]
        widthField.text = String(preset.width)
        heightField.text = String(preset.height)
        dialog.setRatio(preset.ratio)
        presetBox.currentIndex = index
        debounce.restart()
    }

    /// The three bytes the typed command carries.
    function rgb(color) {
        return [Math.round(color.r * 255), Math.round(color.g * 255),
                Math.round(color.b * 255)]
    }

    /// Ask Core for a rendered draft of the current pair. Debounced, so a typed
    /// side does not spawn one render per key; the previous draft stays on
    /// screen until the newest one lands.
    function requestDraft() {
        debounce.stop()
        if (!dialog.livePreview || !dialog.fieldsValid() || !dialog.changed()) return
        dialog.draftRequested(parseInt(widthField.text), parseInt(heightField.text),
                              dialog.padFit ? dialog.rgb(dialog.fillColor) : null)
    }

    function apply() {
        if (!dialog.changed()) return
        dialog.resizeRequested(parseInt(widthField.text), parseInt(heightField.text),
                               dialog.padFit ? dialog.rgb(dialog.fillColor) : null)
        dialog.close()
    }

    onOpened: {
        moved = false
        centerInParent()
        dialog.livePreview = false
        dialog.ignoredDraft = draft ? (draft.path || "") : ""
        dialog.fillFromDocument()
    }

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
        // The title bar moves the dialog, the way Settings does: the preview
        // stays in the dialog, but a user may still want it off the picture's
        // middle. `target: null` keeps the handler off the coordinates and
        // moves the dialog itself; the clamp stops a drag parking it outside.
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
        // Pad to fit adds a colour row and a sentence of explanation. On a
        // short window the whole form may no longer fit; the dialog caps its
        // height at the window, so the bar is how a clipped form says so.
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: resizeColumn
            objectName: "resizeColumn"
            x: 20
            y: 20
            width: parent.width - 40
            spacing: 10

            // What the choice looks like. The document's preview until Live
            // preview lands a draft; `cache: false` because a draft is a new
            // file with the same role, not a cached old one.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 150
                radius: dialog.theme.radius
                color: dialog.theme.thumb
                clip: true

                Image {
                    objectName: "resizePreview"
                    anchors.fill: parent
                    anchors.margins: 6
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectFit
                    source: dialog.previewSource
                }
                Label {
                    anchors.centerIn: parent
                    visible: dialog.previewSource === ""
                    text: dialog.documentReady ? qsTr("No preview yet") : qsTr("No document")
                    color: dialog.theme.textMuted
                }
            }

            Label {
                objectName: "resizeCaption"
                Layout.fillWidth: true
                text: dialog.previewCaption
                color: dialog.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

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
                    onTextEdited: {
                        dialog.linkHeightFromWidth()
                        debounce.restart()
                    }
                }
                // The small +/- pair every size field has: one pixel per press,
                // auto-repeat while held, and the linked side follows because
                // this is the same path as typing.
                Column {
                    spacing: 0

                    Button {
                        objectName: "resizeWidthStepUp"
                        implicitWidth: 24
                        implicitHeight: 16
                        padding: 0
                        font.pixelSize: 9
                        text: "\u25b2"
                        enabled: dialog.documentReady
                        focusPolicy: Qt.NoFocus
                        autoRepeat: true
                        autoRepeatDelay: 350
                        autoRepeatInterval: 60
                        Accessible.name: qsTr("Increase width")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Increase width")
                        onClicked: dialog.stepField(widthField, 1, true)
                    }
                    Button {
                        objectName: "resizeWidthStepDown"
                        implicitWidth: 24
                        implicitHeight: 16
                        padding: 0
                        font.pixelSize: 9
                        text: "\u25bc"
                        enabled: dialog.documentReady
                        focusPolicy: Qt.NoFocus
                        autoRepeat: true
                        autoRepeatDelay: 350
                        autoRepeatInterval: 60
                        Accessible.name: qsTr("Decrease width")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Decrease width")
                        onClicked: dialog.stepField(widthField, -1, true)
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
                    onTextEdited: {
                        dialog.linkWidthFromHeight()
                        debounce.restart()
                    }
                }
                Column {
                    spacing: 0

                    Button {
                        objectName: "resizeHeightStepUp"
                        implicitWidth: 24
                        implicitHeight: 16
                        padding: 0
                        font.pixelSize: 9
                        text: "\u25b2"
                        enabled: dialog.documentReady
                        focusPolicy: Qt.NoFocus
                        autoRepeat: true
                        autoRepeatDelay: 350
                        autoRepeatInterval: 60
                        Accessible.name: qsTr("Increase height")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Increase height")
                        onClicked: dialog.stepField(heightField, 1, false)
                    }
                    Button {
                        objectName: "resizeHeightStepDown"
                        implicitWidth: 24
                        implicitHeight: 16
                        padding: 0
                        font.pixelSize: 9
                        text: "\u25bc"
                        enabled: dialog.documentReady
                        focusPolicy: Qt.NoFocus
                        autoRepeat: true
                        autoRepeatDelay: 350
                        autoRepeatInterval: 60
                        Accessible.name: qsTr("Decrease height")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Decrease height")
                        onClicked: dialog.stepField(heightField, -1, false)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: qsTr("Ratio")
                    color: dialog.theme.textMuted
                }
                ComboBox {
                    id: ratioBox
                    objectName: "resizeRatio"
                    Layout.fillWidth: true
                    model: dialog.ratios
                    textRole: "label"
                    // Set imperatively: ComboBox owns currentIndex, so a binding
                    // here would break on the first pick. `setRatio` keeps them
                    // in step.
                    currentIndex: dialog.ratioIndex()
                    Component.onCompleted: currentIndex = dialog.ratioIndex()
                    onActivated: {
                        dialog.setRatio(dialog.ratios[currentIndex].key)
                        dialog.relinkFields()
                        debounce.restart()
                    }
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

            CheckBox {
                id: padCheck
                objectName: "resizePadToFit"
                Layout.fillWidth: true
                text: qsTr("Pad to fit")
                checked: dialog.padFit
                enabled: dialog.documentReady
                // A Popup built inside the workspace's Loader resolves the
                // platform (light) palette, and this Qt build ignores a QML
                // `palette` write on the control, so the style's own label came
                // out dark-on-dark. The label is spelled out here in the app's
                // own colour instead; the indicator stays the style's.
                contentItem: Text {
                    leftPadding: padCheck.indicator && !padCheck.mirrored
                                 ? padCheck.indicator.width + padCheck.spacing : 0
                    rightPadding: padCheck.indicator && padCheck.mirrored
                                  ? padCheck.indicator.width + padCheck.spacing : 0
                    text: padCheck.text
                    font: padCheck.font
                    color: padCheck.enabled ? dialog.theme.text : dialog.theme.textMuted
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Keep the whole image in shape and fill the leftover with the fill color")
                onToggled: {
                    dialog.padFit = checked
                    debounce.restart()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: dialog.padFit
                spacing: 6

                Rectangle {
                    objectName: "resizeFillColorSwatch"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    radius: 4
                    color: dialog.fillColor
                    border.width: 1
                    border.color: dialog.theme.border
                }
                Button {
                    objectName: "resizeFillColorButton"
                    text: qsTr("Fill color")
                    onClicked: fillColorDialog.open()
                }
                Label {
                    Layout.fillWidth: true
                    text: dialog.fillColor.toString()
                    color: dialog.theme.textMuted
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            Label {
                Layout.fillWidth: true
                visible: dialog.padFit
                text: qsTr("Scales the whole image to fit and fills the leftover with this color.")
                color: dialog.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            CheckBox {
                id: liveCheck
                objectName: "resizeLivePreview"
                Layout.fillWidth: true
                text: qsTr("Live preview")
                checked: dialog.livePreview
                enabled: dialog.documentReady
                contentItem: Text {
                    leftPadding: liveCheck.indicator && !liveCheck.mirrored
                                 ? liveCheck.indicator.width + liveCheck.spacing : 0
                    rightPadding: liveCheck.indicator && liveCheck.mirrored
                                  ? liveCheck.indicator.width + liveCheck.spacing : 0
                    text: liveCheck.text
                    font: liveCheck.font
                    color: liveCheck.enabled ? dialog.theme.text : dialog.theme.textMuted
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Show the resized image before applying it")
                onToggled: {
                    dialog.livePreview = checked
                    debounce.restart()
                }
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
                onClicked: dialog.fillFromDocument()
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
        title: qsTr("Fill color")
        selectedColor: dialog.fillColor
        onAccepted: {
            dialog.fillColor = selectedColor
            debounce.restart()
        }
    }

    /// The form changed and Core should render a draft, not an edit.
    signal draftRequested(int width, int height, var fill)
    /// Apply: the user chose this size. The editor turns it into one
    /// `editor_resize`; the dialog closes on its own.
    signal resizeRequested(int width, int height, var fill)

    Timer {
        id: debounce
        interval: 200
        repeat: false
        onTriggered: dialog.requestDraft()
    }
}
