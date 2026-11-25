import QtQuick

/// Shared color choosers and background popups for `EditorView`.
/// Keeps the palette, canvas backdrop, document canvas background, and
/// gradient stop pickers out of `EditorView.qml` while preserving every
/// objectName and theme/command contract.
Item {
    id: root

    required property var view
    property var layersPanel: null

    anchors.fill: parent

    readonly property bool colorPickerOpen:
        foregroundColorDialog.visible
        || backgroundColorDialog.visible
        || canvasBgColorDialog.visible
        || docCanvasBgColorDialog.visible
        || gradientStopColorDialog.visible

    function openForegroundChooser() {
        foregroundColorDialog.selectedColor = root.view.foregroundColor
        foregroundColorDialog.open()
    }

    function openBackgroundPopup(anchor) {
        if (!anchor) return
        backgroundPopup.transparent = root.view.backgroundTransparent
        backgroundPopup.colour = root.view.backgroundColor
        backgroundPopup.showBelow(anchor)
    }

    function openBackgroundChooser() {
        backgroundColorDialog.selectedColor = root.view.backgroundColor
        backgroundColorDialog.open()
    }

    function openCanvasBgPopup(anchor) {
        if (!anchor) return
        canvasBgPopup.transparent = !root.view.canvasBgUseTheme && root.view.canvasBgChecker
        canvasBgPopup.colour = root.view.canvasBgColor
        canvasBgPopup.showBelow(anchor)
    }

    function openCanvasBgChooser() {
        canvasBgColorDialog.selectedColor = root.view.canvasBgColor
        canvasBgColorDialog.open()
    }

    function openDocCanvasBgPopup(anchor) {
        if (!anchor) return
        var bg = root.view.editor ? root.view.editor.canvasBackground : null
        docCanvasBgPopup.transparent = !(bg && bg.length === 3)
        docCanvasBgPopup.colour = root.layersPanel ? root.layersPanel.bgColorHex() : "#ffffff"
        docCanvasBgPopup.showBelow(anchor)
    }

    function openGradientStopChooser(initialColor) {
        gradientStopColorDialog.selectedColor = initialColor
        gradientStopColorDialog.open()
    }

    /// The foreground's chooser. One instance for every pair, because there is
    /// one foreground: a click says which role is being changed, never which
    /// copy of it. A cancelled chooser changes nothing, and the box keeps
    /// showing what the next mark would get.
    ColorPickerDialog {
        id: foregroundColorDialog
        objectName: "foregroundColorDialog"
        theme: root.view.theme
        title: qsTr("Foreground color")
        selectedColor: root.view.foregroundColor
        onAccepted: {
            root.view.setForegroundColor(root.view.colorText(selectedColor))
            root.view.forceActiveFocus()
        }
    }

    /// New canvas, as a list: transparent, three named colours, or the chooser.
    /// One instance serves the rail, the Crop panel and the Resize form, so a
    /// border grown by hand and a padded resize cannot describe two different
    /// backgrounds.
    BackgroundPopup {
        id: backgroundPopup
        objectName: "backgroundPopup"
        theme: root.view.theme
        transparent: root.view.backgroundTransparent
        colour: root.view.backgroundColor
        alphaLostWarning: root.view.documentIsJpeg
        onTransparentPicked: root.view.setBackgroundTransparent(true)
        onColourPicked: function(value) { root.view.setBackgroundColor(value) }
        onCustomPicked: root.openBackgroundChooser()
    }

    /// The chooser behind `Custom color…`. Uses the shared `ColorPickerDialog`
    /// built on `DialogFrame`.
    ColorPickerDialog {
        id: backgroundColorDialog
        objectName: "backgroundColorDialog"
        theme: root.view.theme
        title: qsTr("Background color")
        selectedColor: root.view.backgroundColor
        onAccepted: {
            root.view.setBackgroundColor(root.view.colorText(selectedColor))
            root.view.forceActiveFocus()
        }
    }

    /// Canvas backdrop list (checkerboard, white, black, gray, custom).
    BackgroundPopup {
        id: canvasBgPopup
        objectName: "canvasBgPopup"
        theme: root.view.theme
        transparent: !root.view.canvasBgUseTheme && root.view.canvasBgChecker
        colour: root.view.canvasBgColor
        onTransparentPicked: {
            root.view.canvasBgUseTheme = false
            root.view.canvasBgChecker = true
        }
        onColourPicked: function(value) {
            root.view.canvasBgUseTheme = false
            root.view.canvasBgChecker = false
            root.view.canvasBgColor = value
        }
        onCustomPicked: root.openCanvasBgChooser()
    }

    ColorPickerDialog {
        id: canvasBgColorDialog
        objectName: "canvasBgColorDialog"
        theme: root.view.theme
        title: qsTr("Canvas background")
        selectedColor: root.view.canvasBgColor
        onAccepted: {
            root.view.canvasBgUseTheme = false
            root.view.canvasBgChecker = false
            root.view.canvasBgColor = root.view.colorText(selectedColor)
            root.view.forceActiveFocus()
        }
    }

    /// Document-wide Canvas Background popup (Krita / Affinity style, from LayersPanel).
    BackgroundPopup {
        id: docCanvasBgPopup
        objectName: "docCanvasBgPopup"
        theme: root.view.theme
        transparent: !(root.view.editor && root.view.editor.canvasBackground && root.view.editor.canvasBackground.length === 3)
        colour: root.layersPanel ? root.layersPanel.bgColorHex() : "#ffffff"
        alphaLostWarning: root.view.documentIsJpeg
        onTransparentPicked: root.view.command({
            type: "editor_set_canvas_background",
            transparent: true
        })
        onColourPicked: function(value) {
            root.view.command({
                type: "editor_set_canvas_background",
                transparent: false,
                color: root.view.colorBytes(value)
            })
        }
        onCustomPicked: {
            docCanvasBgColorDialog.selectedColor = root.layersPanel ? root.layersPanel.bgColorHex() : "#ffffff"
            docCanvasBgColorDialog.open()
        }
    }

    ColorPickerDialog {
        id: docCanvasBgColorDialog
        objectName: "docCanvasBgColorDialog"
        theme: root.view.theme
        title: qsTr("Canvas background")
        selectedColor: "#ffffff"
        onAccepted: {
            root.view.command({
                type: "editor_set_canvas_background",
                transparent: false,
                color: root.view.colorBytes(root.view.colorText(selectedColor))
            })
            root.view.forceActiveFocus()
        }
    }

    ColorPickerDialog {
        id: gradientStopColorDialog
        objectName: "gradientStopColorDialog"
        theme: root.view.theme
        title: qsTr("Gradient stop color")
        selectedColor: "#ffffff"
        onAccepted: {
            root.view.updateGradientStop(root.view.gradientSelectedStop, { hex: root.view.colorText(selectedColor) })
            root.view.forceActiveFocus()
        }
    }
}
