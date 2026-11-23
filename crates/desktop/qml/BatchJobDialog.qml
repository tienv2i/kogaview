import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

/// One batch job, asked as a form.
///
/// The Browser's Batch page offers three actions, and each one is its own
/// dialog — `BatchResizeDialog`, `BatchCropDialog`, `BatchConvertDialog`. The
/// title says which action is being asked and the form draws that action's
/// options and nothing else, so there is no mode strip to switch a half-filled
/// form into another job. This file is the part the three share, so they cannot
/// disagree about where the images come from or where the results go.
///
/// The form asks four things, in the order a user decides them:
///   1. the action's own options — a size, a rectangle, a format;
///   2. which images: the Browser's selection, the folder it shows, or a
///      folder picked here;
///   3. where the results go: the images' own folder, or another one;
///   4. the remaining choices — a suffix, and replacing the originals on
///      purpose.
///
/// Nothing is written until **Run**, and a source is never a destination unless
/// "Replace the originals" is ticked. The dialog only formats the command
/// (`batch_run`). Core resolves the folder, validates the whole job and
/// publishes its progress; the Batch page draws that.
DialogFrame {
    id: dialog
    namePrefix: "batch"
    preferredWidth: 600
    property Theme theme: Theme {}

    /// `resize`, `crop` or `convert`. Each concrete dialog names its own, so
    /// this file draws the fields of one action and cannot be talked into
    /// another one at run time.
    property string operation: "resize"

    /// The Browser's selection, already narrowed to images by the shell.
    property var selectionPaths: []
    /// The folder the Browser shows, offered as the second input.
    property string currentFolder: ""
    /// The first image the job would process. The size form opens on its shape,
    /// so the fields describe a real picture instead of a guess; zero when the
    /// listing has no image yet.
    property int sampleWidth: 0
    property int sampleHeight: 0

    // ------------------------------------------------------------ form state
    /// Which images the job reads: `selection`, `currentFolder` or
    /// `otherFolder` (a folder picked in this form).
    property string inputKind: "selection"
    property string inputFolder: ""

    /// Where results go: `source` (beside the images) or `folder` (a folder
    /// picked in this form). `overwrite` is a third answer of its own and
    /// disables both, because Core refuses a job that both replaces the
    /// originals and writes a copy elsewhere.
    property string outputKind: "source"
    property string outputFolder: ""
    property bool overwrite: false

    // Resize state, as in `ResizeDialog.qml`.
    property bool constraint: true
    property var lockedRatio: ({ width: 0, height: 0 })
    property string fitMode: "stretch"
    property string backgroundMode: "none"
    property color customColor: "#808080"
    property string filter: "auto"

    // Convert state.
    property string format: "png"
    property int quality: 90

    /// The suffix field is the source of truth: it is typed, not derived.
    // The fields below are declared inside the dialog's content item, so a
    // function in this scope cannot name them directly: a plain identifier here
    // resolves through the scope's cache, captured before the content exists.
    // These aliases go through the property system, which always reaches the
    // live item.
    readonly property string suffix: suffixBox.text
    readonly property alias suffixBox: suffixField

    readonly property alias cropXBox: cropXField
    readonly property alias cropYBox: cropYField
    readonly property alias cropWidthBox: cropWidthField
    readonly property alias cropHeightBox: cropHeightField
    readonly property alias widthBox: widthField
    readonly property alias heightBox: heightField

    readonly property var fits: [
        { key: "stretch", label: qsTr("Stretch to size") },
        { key: "cover", label: qsTr("Crop to fill") },
        { key: "pad", label: qsTr("Fit with background") }
    ]
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
    /// The encoders this build carries, in the order the form lists them.
    readonly property var formats: [
        { key: "png", label: ".png" },
        { key: "jpeg", label: ".jpg" },
        { key: "webp", label: ".webp" },
        { key: "tiff", label: ".tiff" },
        { key: "gif", label: ".gif" },
        { key: "bmp", label: ".bmp" },
        { key: "tga", label: ".tga" },
        { key: "qoi", label: ".qoi" }
    ]

    /// The × is Cancel: the form sends nothing until Run, so closing it is
    /// the whole undo.
    onCloseRequested: dialog.close()

    /// The form opens on the action's own defaults.
    function prepare() {
        dialog.resetForm()
    }

    // --------------------------------------------------------------- helpers
    /// The suffix a fresh form starts on for `operation`. Convert changes the
    /// extension, so it needs no suffix; the other two keep the format and
    /// must not write over the source.
    function defaultSuffix(operation) {
        switch (operation) {
        case "resize": return "_resized"
        case "crop": return "_cropped"
        default: return ""
        }
    }

    /// The percentage a crop field holds. The fields are `%` only, so this is
    /// the value the command carries; `UnitField.pixels()` would round it to a
    /// whole percent of a reference image, which is not what a batch means.
    function percentOf(field) {
        var value = parseFloat(String(field.text).trim())
        return isFinite(value) ? value : NaN
    }

    function fillIndex() {
        for (var index = 0; index < dialog.fits.length; ++index) {
            if (dialog.fits[index].key === dialog.fitMode) return index
        }
        return 0
    }

    function backgroundIndex() {
        for (var index = 0; index < dialog.backgrounds.length; ++index) {
            if (dialog.backgrounds[index].key === dialog.backgroundMode) return index
        }
        return 0
    }

    function filterIndex() {
        for (var index = 0; index < dialog.filters.length; ++index) {
            if (dialog.filters[index].key === dialog.filter) return index
        }
        return 0
    }

    /// The extension a format writes, from the form's own table: `.jpg` for
    /// `jpeg`. The key is not the extension — comparing against `".jpeg"`
    /// would let a `.jpg` source through, and Core would then refuse the job
    /// after Run instead of the form saying so first.
    function extensionOf(key) {
        for (var index = 0; index < dialog.formats.length; ++index) {
            if (dialog.formats[index].key === key) return dialog.formats[index].label
        }
        return "." + key
    }

    function formatIndex() {
        for (var index = 0; index < dialog.formats.length; ++index) {
            if (dialog.formats[index].key === dialog.format) return index
        }
        return 0
    }

    /// Start the aspect chain from the pair on screen, or from the sample.
    function captureRatio() {
        var width = widthField.acceptableInput ? widthField.pixels() : 0
        var height = heightField.acceptableInput ? heightField.pixels() : 0
        if (!(width > 0) || !(height > 0)) {
            width = dialog.sampleWidth > 0 ? dialog.sampleWidth : 1024
            height = dialog.sampleHeight > 0 ? dialog.sampleHeight : 1024
        }
        dialog.lockedRatio = { width: width, height: height }
    }

    function setConstraint(enabled) {
        dialog.constraint = enabled
        constraintButton.checked = enabled
        if (enabled) dialog.captureRatio()
    }

    function linkHeightFromWidth() {
        if (!dialog.constraint || !widthField.acceptableInput) return
        var width = widthField.pixels()
        if (!(width > 0)) return
        var factor = dialog.lockedRatio
        if (factor && factor.width > 0 && factor.height > 0) {
            heightField.setPixels(Math.max(1, Math.min(20000,
                    Math.round(width * factor.height / factor.width))))
        }
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
    }

    function chooseFit(index) {
        if (index < 0 || index >= dialog.fits.length) return
        dialog.fitMode = dialog.fits[index].key
        fitBox.currentIndex = index
    }

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

    function rgb(color) {
        return [Math.round(color.r * 255), Math.round(color.g * 255),
                Math.round(color.b * 255)]
    }

    /// The colour the resize carries, or null when nothing is painted.
    function fillForCommand() {
        if (dialog.fitMode !== "pad") return null
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

    /// The last part of a path: how a folder is named in a sentence.
    function folderName(path) {
        var text = String(path).replace(/\/+$/, "")
        var index = text.lastIndexOf("/")
        return index >= 0 ? text.substring(index + 1) : text
    }

    /// The folder the Browser shows, as the second input's label says it.
    function folderLabel() {
        return dialog.currentFolder.length === 0 ? qsTr("the open folder")
                                                 : dialog.folderName(dialog.currentFolder)
    }

    /// The folder the results land in when the images keep their own folder.
    ///
    /// A selection is always from the folder the Browser shows, so that is the
    /// folder named here; a job over another folder names that one instead.
    function sourceFolderLabel() {
        var path = dialog.inputKind === "otherFolder" ? dialog.inputFolder
                                                      : dialog.currentFolder
        return path.length === 0 ? qsTr("their own folder") : dialog.folderName(path)
    }

    /// The one reason Run is unavailable, or "" when the form is ready.
    ///
    /// Core validates again — this is a courtesy, not the contract — but a
    /// form that lets a refusal through is a form that made the user wait for
    /// a worker to say what the fields already knew.
    function validationError() {
        if (dialog.inputKind === "selection" && dialog.selectionPaths.length === 0) {
            return qsTr("Select at least one image, or use the open folder.")
        }
        if (dialog.inputKind === "currentFolder" && dialog.currentFolder.length === 0) {
            return qsTr("Open a folder first, or select images.")
        }
        if (dialog.inputKind === "otherFolder" && dialog.inputFolder.length === 0) {
            return qsTr("Choose the folder to process.")
        }

        if (dialog.operation === "resize") {
            if (!dialog.widthBox.acceptableInput || !dialog.heightBox.acceptableInput
                    || dialog.widthBox.pixels() < 1 || dialog.heightBox.pixels() < 1) {
                return qsTr("Width and height must be at least 1 pixel.")
            }
        } else if (dialog.operation === "crop") {
            var x = dialog.percentOf(dialog.cropXBox)
            var y = dialog.percentOf(dialog.cropYBox)
            var width = dialog.percentOf(dialog.cropWidthBox)
            var height = dialog.percentOf(dialog.cropHeightBox)
            if (!isFinite(x) || !isFinite(y) || !isFinite(width) || !isFinite(height)) {
                return qsTr("Enter a number for X, Y, width and height.")
            }
            if (width <= 0 || height <= 0) {
                return qsTr("Width and height must be above 0 %.")
            }
            if (x < 0 || y < 0 || x + width > 100 || y + height > 100) {
                return qsTr("The rectangle must stay inside the image: X + width and Y + height cannot pass 100 %.")
            }
            if (x === 0 && y === 0 && width === 100 && height === 100) {
                return qsTr("That rectangle covers the whole image; set a width or height below 100 %.")
            }
        }

        if (!dialog.overwrite && dialog.outputKind === "folder"
                && dialog.outputFolder.length === 0) {
            return qsTr("Choose an output folder, or write beside the source.")
        }
        if (!dialog.overwrite
                && (dialog.suffix.indexOf("/") >= 0 || dialog.suffix.indexOf("\\") >= 0)) {
            return qsTr("A suffix cannot contain a path separator.")
        }
        if (!dialog.overwrite && dialog.outputKind === "source"
                && dialog.operation !== "convert" && dialog.suffix.length === 0) {
            return qsTr("An empty suffix beside the source would replace it; add a suffix, choose another folder, or tick “Replace the originals”.")
        }
        if (!dialog.overwrite && dialog.outputKind === "source"
                && dialog.operation === "convert"
                && dialog.suffix.length === 0 && dialog.inputKind === "selection") {
            // The form can see the selection; a folder's mixed contents are
            // Core's to refuse, with the same sentence naming the file.
            var extension = dialog.extensionOf(dialog.format)
            for (var index = 0; index < dialog.selectionPaths.length; ++index) {
                var path = String(dialog.selectionPaths[index]).toLowerCase()
                // Compare the whole suffix, not a prefix: `a.pngx` is not
                // already a png.
                if (path.length > extension.length
                        && path.slice(path.length - extension.length) === extension) {
                    return qsTr("%1 is already %2; add a suffix to keep a copy.")
                            .arg(dialog.baseName(path)).arg(extension)
                }
            }
        }
        return ""
    }

    function baseName(path) {
        var text = String(path)
        var index = text.lastIndexOf("/")
        return index >= 0 ? text.substring(index + 1) : text
    }

    /// The sentence under the form: what will be written, and where.
    function summary() {
        var files
        switch (dialog.inputKind) {
        case "selection":
            files = qsTr("%1 selected image(s)").arg(dialog.selectionPaths.length)
            break
        case "currentFolder":
            files = qsTr("every image in %1").arg(dialog.folderLabel())
            break
        default:
            files = qsTr("every image in %1").arg(dialog.folderName(dialog.inputFolder))
            break
        }
        if (dialog.overwrite) {
            return qsTr("%1 will be replaced in place; a .bak copy is kept.").arg(files)
        }
        var place = dialog.outputKind === "folder"
                ? qsTr("into %1").arg(dialog.outputFolder)
                : qsTr("beside each source")
        var name = dialog.suffix.length > 0
                ? qsTr("with %1 before the extension").arg(dialog.suffix)
                : qsTr("keeping the name")
        return qsTr("%1 will be written %2 %3.").arg(files).arg(place).arg(name)
    }

    function toLocalPath(url) {
        var text = "" + url
        if (text.indexOf("file://") === 0) {
            text = text.substring("file://".length)
        }
        try {
            return decodeURIComponent(text)
        } catch (error) {
            return text
        }
    }

    /// The command the Run button sends. One typed job: Core owns the list, the
    /// destinations, the progress and the cancellation.
    function command() {
        var operation
        if (dialog.operation === "resize") {
            operation = {
                operation: "resize",
                width: dialog.widthBox.pixels(),
                height: dialog.heightBox.pixels(),
                mode: dialog.fitMode,
                filter: dialog.filter,
                fill: dialog.fillForCommand(),
                fill_alpha: dialog.fillAlpha()
            }
        } else if (dialog.operation === "crop") {
            operation = {
                operation: "crop",
                x: dialog.percentOf(dialog.cropXBox),
                y: dialog.percentOf(dialog.cropYBox),
                width: dialog.percentOf(dialog.cropWidthBox),
                height: dialog.percentOf(dialog.cropHeightBox)
            }
        } else {
            operation = {
                operation: "convert",
                format: dialog.format,
                quality: dialog.format === "jpeg" ? dialog.quality : null
            }
        }
        var source
        switch (dialog.inputKind) {
        case "selection":
            source = { source: "selection", paths: dialog.selectionPaths }
            break
        case "currentFolder":
            source = { source: "folder", path: dialog.currentFolder }
            break
        default:
            // The third choice is the same command as the open folder: Core
            // reads one folder either way, and `is_batchable` decides what in
            // it is an image.
            source = { source: "folder", path: dialog.inputFolder }
            break
        }
        var output = {
            folder: (!dialog.overwrite && dialog.outputKind === "folder")
                    ? dialog.outputFolder : null,
            suffix: dialog.overwrite ? "" : dialog.suffix,
            overwrite: dialog.overwrite
        }
        return { type: "batch_run", operation: operation, source: source,
                 output: output }
    }

    function run() {
        if (dialog.validationError().length > 0) return
        dialog.runRequested(dialog.command())
        dialog.close()
    }

    /// Put every field back on the initial answer. Called on every open, so a
    /// cancelled form does not decide the next one's answer.
    ///
    /// Not named `reset`: `Dialog` has had a `reset` signal since Qt 6.9 (the
    /// applied/reset/discarded standard buttons), and a function of that name is
    /// an invalid override Qt silently drops — the form then kept the previous
    /// job's answer.
    function resetForm() {
        // The images: the selection when it has any, otherwise the open folder,
        // and never a folder the last visit picked.
        dialog.inputKind = dialog.selectionPaths.length > 0
                ? "selection"
                : (dialog.currentFolder.length > 0 ? "currentFolder" : "otherFolder")
        dialog.inputFolder = ""
        selectionRadio.checked = dialog.inputKind === "selection"
        folderRadio.checked = dialog.inputKind === "currentFolder"
        otherFolderRadio.checked = dialog.inputKind === "otherFolder"

        // Resize starts on the sample's own size, in pixels: a target size is
        // absolute, and `%` of one image would be a lie about the others.
        var width = dialog.sampleWidth > 0 ? dialog.sampleWidth : 1024
        var height = dialog.sampleHeight > 0 ? dialog.sampleHeight : 1024
        widthField.unit = "px"
        heightField.unit = "px"
        widthField.setPixels(width)
        heightField.setPixels(height)
        dialog.lockedRatio = { width: width, height: height }
        dialog.constraint = true
        constraintButton.checked = true
        dialog.fitMode = "stretch"
        dialog.backgroundMode = "none"
        dialog.filter = "auto"
        fitBox.currentIndex = 0
        backgroundBox.currentIndex = 0
        filterBox.currentIndex = 0

        // Crop starts on the whole image. Run stays disabled until the
        // rectangle trims something, because Core refuses a no-op crop.
        cropXField.text = "0"
        cropYField.text = "0"
        cropWidthField.text = "100"
        cropHeightField.text = "100"

        dialog.format = "png"
        formatBox.currentIndex = 0
        dialog.quality = 90
        qualityBox.value = 90

        // The results go beside the images unless the user says otherwise, and
        // the suffix starts on the one this action keeps a copy under.
        dialog.overwrite = false
        overwriteBox.checked = false
        dialog.outputKind = "source"
        dialog.outputFolder = ""
        besideRadio.checked = true
        folderDestinationRadio.checked = false
        suffixField.text = dialog.defaultSuffix(dialog.operation)
    }



    ButtonGroup { id: inputGroup }
    ButtonGroup { id: outputGroup }

    // ------------------------------------------- the action's options
    // First, because it is what the dialog's title promises: the size,
    // the rectangle or the format, exactly as the Editor's own tool
    // asks for it. Only the fields of this dialog's action exist here.

    // ------------------------------------------------------ resize
    ColumnLayout {
        Layout.fillWidth: true
        visible: dialog.operation === "resize"
        spacing: 8

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
                objectName: "batchResizeWidth"
                Layout.fillWidth: true
                font.pixelSize: 12
                // A target size is absolute: `%` would name one
                // picture's size and mean nothing for the others.
                unitsVisible: false
                minimumPixels: 1
                maximumPixels: 20000
                nextField: heightField
                onTextEdited: dialog.linkHeightFromWidth()
                onAccepted: dialog.run()
            }
            ToolButton {
                id: constraintButton
                objectName: "batchResizeConstraint"
                Layout.rowSpan: 2
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 32
                implicitHeight: 32
                checkable: true
                checked: dialog.constraint
                focusPolicy: Qt.NoFocus
                Accessible.name: qsTr("Constrain proportions")
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Constrain proportions")
                onToggled: dialog.setConstraint(checked)
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
                        ctx.strokeStyle = constraintButton.checked
                                ? dialog.theme.accent : dialog.theme.text
                        ctx.lineWidth = 1.5
                        ctx.lineCap = "round"
                        ctx.translate(width / 2, height / 2)
                        ctx.rotate(-Math.PI / 4)
                        drawLink(ctx, -3.7)
                        drawLink(ctx, 3.7)
                    }
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
                objectName: "batchResizeHeight"
                Layout.fillWidth: true
                font.pixelSize: 12
                unitsVisible: false
                minimumPixels: 1
                maximumPixels: 20000
                previousField: widthField
                onTextEdited: dialog.linkWidthFromHeight()
                onAccepted: dialog.run()
            }
        }

        FormRow {
            theme: dialog.theme
            label: qsTr("Fit")
            labelWidth: dialog.labelWidth
            Layout.fillWidth: true

            ComboBox {
                id: fitBox
                objectName: "batchResizeFit"
                Layout.fillWidth: true
                model: dialog.fits
                textRole: "label"
                currentIndex: dialog.fillIndex()
                // `currentIndex` is bound to the state the handler
                // writes, so it still holds the old choice here; the
                // signal's index is the one the user picked.
                onActivated: function(index) { dialog.chooseFit(index) }
            }
        }

        FormRow {
            theme: dialog.theme
            label: qsTr("Background")
            labelWidth: dialog.labelWidth
            Layout.fillWidth: true
            visible: dialog.fitMode === "pad"

            ComboBox {
                id: backgroundBox
                objectName: "batchResizeBackground"
                Layout.fillWidth: true
                model: dialog.backgrounds
                textRole: "label"
                currentIndex: dialog.backgroundIndex()
                onActivated: function(index) { dialog.chooseBackground(index) }
            }
            Rectangle {
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

        FormRow {
            theme: dialog.theme
            label: qsTr("Filter")
            labelWidth: dialog.labelWidth
            Layout.fillWidth: true

            ComboBox {
                id: filterBox
                objectName: "batchResizeFilter"
                Layout.fillWidth: true
                model: dialog.filters
                textRole: "label"
                currentIndex: dialog.filterIndex()
                onActivated: function(index) {
                    dialog.filter = dialog.filters[index].key
                }
            }
        }
    }

    // -------------------------------------------------------- crop
    ColumnLayout {
        Layout.fillWidth: true
        visible: dialog.operation === "crop"
        spacing: 8

        GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: 6
            rowSpacing: 6

            Label {
                text: qsTr("X")
                color: dialog.theme.textMuted
            }
            UnitField {
                id: cropXField
                objectName: "batchCropX"
                Layout.fillWidth: true
                font.pixelSize: 12
                unit: "%"
                unitsVisible: false
                unitReference: 100
                minimumPixels: 0
                maximumPixels: 100
            }
            Label {
                text: qsTr("Y")
                color: dialog.theme.textMuted
            }
            UnitField {
                id: cropYField
                objectName: "batchCropY"
                Layout.fillWidth: true
                font.pixelSize: 12
                unit: "%"
                unitsVisible: false
                unitReference: 100
                minimumPixels: 0
                maximumPixels: 100
            }

            Label {
                text: qsTr("Width")
                color: dialog.theme.textMuted
            }
            UnitField {
                id: cropWidthField
                objectName: "batchCropWidth"
                Layout.fillWidth: true
                font.pixelSize: 12
                unit: "%"
                unitsVisible: false
                unitReference: 100
                minimumPixels: 1
                maximumPixels: 100
            }
            Label {
                text: qsTr("Height")
                color: dialog.theme.textMuted
            }
            UnitField {
                id: cropHeightField
                objectName: "batchCropHeight"
                Layout.fillWidth: true
                font.pixelSize: 12
                unit: "%"
                unitsVisible: false
                unitReference: 100
                minimumPixels: 1
                maximumPixels: 100
            }
        }

        Label {
            Layout.fillWidth: true
            text: qsTr("Percentages are of each image's own sides, so one rectangle trims the same relative area from every size.")
            color: dialog.theme.textMuted
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }
    }

    // ----------------------------------------------------- convert
    ColumnLayout {
        Layout.fillWidth: true
        visible: dialog.operation === "convert"
        spacing: 8

        FormRow {
            theme: dialog.theme
            label: qsTr("Format")
            labelWidth: dialog.labelWidth
            Layout.fillWidth: true

            ComboBox {
                id: formatBox
                objectName: "batchConvertFormat"
                Layout.fillWidth: true
                model: dialog.formats
                textRole: "label"
                currentIndex: dialog.formatIndex()
                // The signal carries the index; `currentIndex` is a
                // binding to `dialog.format`, so reading it here would
                // echo the old format back.
                onActivated: function(index) {
                    dialog.format = dialog.formats[index].key
                }
            }
        }

        FormRow {
            theme: dialog.theme
            label: qsTr("Quality")
            labelWidth: dialog.labelWidth
            Layout.fillWidth: true
            // Only JPEG reads the quality; the other encoders are
            // lossless or fixed, so the row would be a lie there.
            visible: dialog.format === "jpeg"

            // The same slider the Editor's Export draws: the batch is
            // the editor's own encoder, so its one lossy setting should
            // look and read the same way, not as a white spin box on
            // the dark form.
            Slider {
                id: qualityBox
                objectName: "batchConvertQuality"
                Layout.fillWidth: true
                from: 10
                to: 100
                stepSize: 1
                value: dialog.quality
                onMoved: dialog.quality = Math.round(value)
            }
            Label {
                Layout.preferredWidth: 32
                text: String(Math.round(qualityBox.value))
                color: dialog.theme.text
                font.pixelSize: 12
            }
        }
    }

    // ------------------------------------------------------- input
    Label {
        Layout.fillWidth: true
        Layout.topMargin: 4
        text: qsTr("Images")
        color: dialog.theme.text
        font.bold: true
        font.pixelSize: 12
    }
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: dialog.theme.border
    }

    // The three answers, in the order a user looks for them: what is
    // picked, what is open, what is somewhere else.
    FormRadio {
        id: selectionRadio
        theme: dialog.theme
        objectName: "batchInputSelection"
        Layout.fillWidth: true
        text: qsTr("The selection (%1 image(s))").arg(dialog.selectionPaths.length)
        enabled: dialog.selectionPaths.length > 0
        ButtonGroup.group: inputGroup
        checked: dialog.inputKind === "selection"
        onClicked: dialog.inputKind = "selection"
    }
    FormRadio {
        id: folderRadio
        theme: dialog.theme
        objectName: "batchInputFolder"
        Layout.fillWidth: true
        text: qsTr("Every image in %1").arg(dialog.folderLabel())
        enabled: dialog.currentFolder.length > 0
        ButtonGroup.group: inputGroup
        checked: dialog.inputKind === "currentFolder"
        onClicked: dialog.inputKind = "currentFolder"
    }
    FormRadio {
        id: otherFolderRadio
        theme: dialog.theme
        objectName: "batchInputOtherFolder"
        Layout.fillWidth: true
        text: qsTr("Another folder")
        ButtonGroup.group: inputGroup
        checked: dialog.inputKind === "otherFolder"
        onClicked: dialog.inputKind = "otherFolder"
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 28
        spacing: 8

        Label {
            objectName: "batchInputFolderPath"
            Layout.fillWidth: true
            text: dialog.inputFolder.length > 0 ? dialog.inputFolder
                                                : qsTr("No folder chosen")
            color: dialog.inputFolder.length > 0 ? dialog.theme.text
                                                 : dialog.theme.textMuted
            elide: Text.ElideMiddle
        }
        PanelAction {
            objectName: "batchChooseInputFolder"
            theme: dialog.theme
            text: qsTr("Choose…")
            implicitWidth: 96
            onClicked: {
                dialog.inputKind = "otherFolder"
                otherFolderRadio.checked = true
                inputFolderDialog.open()
            }
        }
    }

    // ------------------------------------------------------- output
    Label {
        Layout.fillWidth: true
        Layout.topMargin: 4
        text: qsTr("Save to")
        color: dialog.theme.text
        font.bold: true
        font.pixelSize: 12
    }
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: dialog.theme.border
    }

    FormRadio {
        id: besideRadio
        theme: dialog.theme
        objectName: "batchOutputBeside"
        Layout.fillWidth: true
        text: qsTr("The images' folder (%1)").arg(dialog.sourceFolderLabel())
        enabled: !dialog.overwrite
        ButtonGroup.group: outputGroup
        // The two destination radios follow `outputKind` in both
        // directions: whichever one is bound, the group cannot fall
        // back to "nothing checked".
        checked: dialog.outputKind === "source" && !dialog.overwrite
        onClicked: dialog.outputKind = "source"
    }

    FormRadio {
        id: folderDestinationRadio
        theme: dialog.theme
        objectName: "batchOutputFolder"
        Layout.fillWidth: true
        text: qsTr("Another folder")
        enabled: !dialog.overwrite
        ButtonGroup.group: outputGroup
        // The radio is the answer, not a notification: a folder chosen
        // in `FolderDialog` or handed in by a host lands here too.
        checked: dialog.outputKind === "folder" && !dialog.overwrite
        onClicked: dialog.outputKind = "folder"
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 28
        spacing: 8
        enabled: !dialog.overwrite

        Label {
            objectName: "batchOutputFolderPath"
            Layout.fillWidth: true
            text: dialog.outputFolder.length > 0 ? dialog.outputFolder
                                                 : qsTr("No folder chosen")
            color: dialog.outputFolder.length > 0 ? dialog.theme.text
                                                  : dialog.theme.textMuted
            elide: Text.ElideMiddle
        }
        PanelAction {
            objectName: "batchChooseFolder"
            theme: dialog.theme
            text: qsTr("Choose…")
            implicitWidth: 96
            onClicked: outputFolderDialog.open()
        }
    }

    // ------------------------------------------------------- options
    Label {
        Layout.fillWidth: true
        Layout.topMargin: 4
        text: qsTr("Options")
        color: dialog.theme.text
        font.bold: true
        font.pixelSize: 12
    }
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: dialog.theme.border
    }

    FormRow {
        theme: dialog.theme
        label: qsTr("Suffix")
        labelWidth: dialog.labelWidth
        Layout.fillWidth: true
        enabled: !dialog.overwrite

        TextField {
            id: suffixField
            objectName: "batchOutputSuffix"
            Layout.fillWidth: true
            font.pixelSize: 12
            placeholderText: qsTr("(none)")
            onAccepted: dialog.run()
        }
    }

    FormCheck {
        id: overwriteBox
        theme: dialog.theme
        objectName: "batchOverwrite"
        Layout.fillWidth: true
        text: qsTr("Replace the originals (a .bak copy is kept)")
        onCheckedChanged: dialog.overwrite = checked
    }

    Label {
        objectName: "batchSummary"
        Layout.fillWidth: true
        text: dialog.summary()
        color: dialog.theme.textMuted
        font.pixelSize: 11
        wrapMode: Text.WordWrap
    }

    Label {
        objectName: "batchWarning"
        Layout.fillWidth: true
        visible: dialog.validationError().length > 0
        text: dialog.validationError()
        color: dialog.theme.danger
        font.pixelSize: 11
        wrapMode: Text.WordWrap
    }


    footer: DialogFooter {
        namePrefix: "batch"
        theme: dialog.theme
        height: dialog.footerHeight

        Item { Layout.fillWidth: true }
        PanelAction {
            objectName: "batchDialogCancel"
            theme: dialog.theme
            text: qsTr("Cancel")
            implicitWidth: 88
            onClicked: dialog.close()
        }
        PanelAction {
            objectName: "batchDialogRun"
            theme: dialog.theme
            text: qsTr("Run")
            implicitWidth: 88
            primary: true
            enabled: dialog.validationError().length === 0
            onClicked: dialog.run()
        }
    }

    FolderDialog {
        id: inputFolderDialog
        objectName: "batchInputFolderDialog"
        title: qsTr("Choose a folder of images")
        onAccepted: {
            dialog.inputFolder = dialog.toLocalPath(selectedFolder)
            dialog.inputKind = "otherFolder"
            otherFolderRadio.checked = true
        }
        onRejected: otherFolderRadio.checked = dialog.inputKind === "otherFolder"
    }

    FolderDialog {
        id: outputFolderDialog
        objectName: "batchOutputFolderDialog"
        title: qsTr("Choose an output folder")
        onAccepted: {
            dialog.outputFolder = dialog.toLocalPath(selectedFolder)
            folderDestinationRadio.checked = true
            dialog.outputKind = "folder"
        }
    }

    ColorDialog {
        id: fillColorDialog
        objectName: "batchFillColorDialog"
        title: qsTr("Background color")
        selectedColor: dialog.customColor
        onAccepted: {
            dialog.customColor = selectedColor
            dialog.backgroundMode = "custom"
            backgroundBox.currentIndex = dialog.backgroundIndex()
        }
        onRejected: backgroundBox.currentIndex = dialog.backgroundIndex()
    }

    /// The user chose this job. The shell turns it into one `batch_run`; the
    /// dialog closes and the Batch page draws Core's progress.
    signal runRequested(var command)
}
