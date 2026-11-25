import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// AI & plugin tool options (Remove Background, Watermark Remover, AI Caption)
/// extracted from `EditorView.qml`.
ColumnLayout {
    id: root

    required property var view
    Layout.fillWidth: true
    spacing: 0
    visible: view.tool === "removeBg" || view.tool === "watermark" || view.tool === "caption"

    readonly property alias rembgBrushMode: removeBgOptionsPanel.rembgBrushMode
    readonly property alias rembgBrushRadius: removeBgOptionsPanel.rembgBrushRadius
    readonly property alias rembgBrushSoftness: removeBgOptionsPanel.rembgBrushSoftness
    readonly property alias wmMode: watermarkOptionsPanel.wmMode
    readonly property string wmDetectorKey: aiDetectorCombo.keys[aiDetectorCombo.currentIndex] || "watermark-yolo26"

    ColumnLayout {
        id: removeBgOptionsPanel
        objectName: "editorRemoveBgPanel"
        Layout.fillWidth: true
        spacing: 10
        visible: view.tool === "removeBg"

        readonly property var models: {
            var all = (view.state && view.state.aiModels) || []
            var out = []
            for (var i = 0; i < all.length; ++i) {
                var t = (all[i].tier || "").toLowerCase()
                if (t !== "ocr" && t !== "upscale" && t !== "caption"
                    && t !== "detector" && t !== "inpaint") out.push(all[i])
            }
            return out
        }
        property string rembgBrushMode: "off" // "off" | "erase" | "restore"
        property int rembgBrushRadius: 24
        property real rembgBrushSoftness: 0.30
        readonly property var activeTask: (view.state && view.state.aiTask) || null
        readonly property bool aiBusy: !!(activeTask && activeTask.running)
        readonly property var selectedModel: {
            if (models.length === 0) return null
            var idx = Math.max(0, Math.min(models.length - 1, rembgModelCombo.currentIndex))
            return models[idx]
        }

        Label {
            text: qsTr("Model")
            color: view.theme.textMuted
            font.pixelSize: 12
        }
        ComboBox {
            id: rembgModelCombo
            objectName: "rembgModelCombo"
            Layout.fillWidth: true
            currentIndex: 1
            model: {
                var list = removeBgOptionsPanel.models
                var labels = []
                for (var i = 0; i < list.length; ++i) {
                    var m = list[i]
                    labels.push(m.name + (m.installed ? "" : " (" + qsTr("Not downloaded") + ")"))
                }
                return labels
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: qsTr("Edge feather")
                color: view.theme.textMuted
                font.pixelSize: 12
                Layout.fillWidth: true
            }
            Label {
                text: rembgFeatherSlider.value + " px"
                color: view.theme.text
                font.pixelSize: 12
            }
        }
        Slider {
            id: rembgFeatherSlider
            Layout.fillWidth: true
            from: 0
            to: 20
            stepSize: 1
            value: 0
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: removeBgOptionsPanel.aiBusy

            Label {
                text: removeBgOptionsPanel.activeTask ? removeBgOptionsPanel.activeTask.stage : ""
                color: view.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: 100
                value: removeBgOptionsPanel.activeTask ? removeBgOptionsPanel.activeTask.percent : 0
            }
        }

        Label {
            visible: !!(removeBgOptionsPanel.activeTask
                        && !removeBgOptionsPanel.activeTask.running
                        && removeBgOptionsPanel.activeTask.error)
            text: removeBgOptionsPanel.activeTask && removeBgOptionsPanel.activeTask.error
                  ? removeBgOptionsPanel.activeTask.error : ""
            color: view.theme.danger
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Button {
            objectName: "rembgDownloadButton"
            Layout.fillWidth: true
            visible: !!(removeBgOptionsPanel.selectedModel
                        && !removeBgOptionsPanel.selectedModel.installed
                        && !removeBgOptionsPanel.aiBusy)
            text: qsTr("Download model (%1)")
                .arg(view.theme.formatBytes(removeBgOptionsPanel.selectedModel
                                            ? (removeBgOptionsPanel.selectedModel.sizeBytes || 0) : 0))
            focusPolicy: Qt.NoFocus
            onClicked: {
                if (removeBgOptionsPanel.selectedModel) {
                    view.command({
                        type: "ai_download_model",
                        model_id: removeBgOptionsPanel.selectedModel.id
                    })
                }
            }
        }

        RowLayout {
            objectName: "rembgApplyTargetRow"
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: qsTr("Apply to")
                color: view.theme.textMuted
                font.pixelSize: 12
            }
            ComboBox {
                objectName: "rembgApplyTargetCombo"
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                readonly property var keys: ["active_layer", "whole_image", "new_layer"]
                model: [qsTr("Active layer"), qsTr("Whole image"), qsTr("New layer")]
                currentIndex: Math.max(0, keys.indexOf(view.aiApplyTarget))
                onActivated: function(idx) {
                    view.aiApplyTarget = keys[idx] || "active_layer"
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Button {
                objectName: "rembgRunButton"
                Layout.fillWidth: true
                text: qsTr("Remove background")
                focusPolicy: Qt.NoFocus
                enabled: view.documentReady
                         && !removeBgOptionsPanel.aiBusy
                         && !!(removeBgOptionsPanel.selectedModel
                               && removeBgOptionsPanel.selectedModel.installed)
                onClicked: {
                    if (removeBgOptionsPanel.selectedModel) {
                        view.command({
                            type: "editor_ai_remove_background",
                            model_id: removeBgOptionsPanel.selectedModel.id,
                            feather: Math.round(rembgFeatherSlider.value),
                            target: view.effectiveAiTarget()
                        })
                    }
                }
            }

            Button {
                objectName: "rembgCancelButton"
                visible: removeBgOptionsPanel.aiBusy
                text: qsTr("Cancel")
                focusPolicy: Qt.NoFocus
                onClicked: view.command({ type: "ai_cancel" })
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            Layout.topMargin: 4
            Layout.bottomMargin: 2
            color: view.theme.border
        }

        Label {
            text: qsTr("Refine mask (Brush)")
            color: view.theme.textMuted
            font.pixelSize: 12
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            PanelAction {
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("Off")
                primary: removeBgOptionsPanel.rembgBrushMode === "off"
                onClicked: removeBgOptionsPanel.rembgBrushMode = "off"
            }
            PanelAction {
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("Erase BG")
                primary: removeBgOptionsPanel.rembgBrushMode === "erase"
                onClicked: removeBgOptionsPanel.rembgBrushMode = "erase"
            }
            PanelAction {
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("Restore FG")
                primary: removeBgOptionsPanel.rembgBrushMode === "restore"
                onClicked: removeBgOptionsPanel.rembgBrushMode = "restore"
            }
        }

        Label {
            visible: removeBgOptionsPanel.rembgBrushMode !== "off"
            text: removeBgOptionsPanel.rembgBrushMode === "restore"
                ? qsTr("Paint on the image to restore cut subject pixels from original (Ctrl+Z to undo)")
                : qsTr("Paint on the image to erase leftover background to transparent (Ctrl+Z to undo)")
            color: view.theme.textMuted
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            visible: removeBgOptionsPanel.rembgBrushMode !== "off"
            Label { text: qsTr("Mask brush size"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: removeBgOptionsPanel.rembgBrushRadius + " px"; color: view.theme.text; font.pixelSize: 12 }
        }
        Slider {
            Layout.fillWidth: true
            visible: removeBgOptionsPanel.rembgBrushMode !== "off"
            focusPolicy: Qt.NoFocus
            from: 6; to: 120; stepSize: 2
            value: removeBgOptionsPanel.rembgBrushRadius
            onMoved: removeBgOptionsPanel.rembgBrushRadius = Math.round(value)
        }

        RowLayout {
            Layout.fillWidth: true
            visible: removeBgOptionsPanel.rembgBrushMode !== "off"
            Label { text: qsTr("Brush softness"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: Math.round(removeBgOptionsPanel.rembgBrushSoftness * 100) + "%"; color: view.theme.text; font.pixelSize: 12 }
        }
        Slider {
            Layout.fillWidth: true
            visible: removeBgOptionsPanel.rembgBrushMode !== "off"
            focusPolicy: Qt.NoFocus
            from: 0.0; to: 1.0; stepSize: 0.05
            value: removeBgOptionsPanel.rembgBrushSoftness
            onMoved: removeBgOptionsPanel.rembgBrushSoftness = value
        }
    }

    // ------------------------------------------- Watermark Remover (Gemini + General Region)
    ColumnLayout {
        id: watermarkOptionsPanel
        objectName: "editorWatermarkPanel"
        Layout.fillWidth: true
        spacing: 10
        visible: view.tool === "watermark"

        property string wmMode: "ai" // "ai" | "gemini" | "region"
        readonly property var activeTask: (view.state && view.state.aiTask) || null
        readonly property bool wmBusy: !!(activeTask && activeTask.running)

        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            PanelAction {
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("AI Auto")
                primary: watermarkOptionsPanel.wmMode === "ai"
                onClicked: watermarkOptionsPanel.wmMode = "ai"
            }
            PanelAction {
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("Gemini")
                primary: watermarkOptionsPanel.wmMode === "gemini"
                onClicked: watermarkOptionsPanel.wmMode = "gemini"
            }
            PanelAction {
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("Region")
                primary: watermarkOptionsPanel.wmMode === "region"
                onClicked: watermarkOptionsPanel.wmMode = "region"
            }
        }

        RowLayout {
            objectName: "watermarkApplyTargetRow"
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: qsTr("Apply to")
                color: view.theme.textMuted
                font.pixelSize: 12
            }
            ComboBox {
                objectName: "watermarkApplyTargetCombo"
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                readonly property var keys: ["active_layer", "whole_image", "new_layer"]
                model: [qsTr("Active layer"), qsTr("Whole image"), qsTr("New layer")]
                currentIndex: Math.max(0, keys.indexOf(view.aiApplyTarget))
                onActivated: function(idx) {
                    view.aiApplyTarget = keys[idx] || "active_layer"
                }
            }
        }

        // Mode 0: AI Watermark Detector (YOLO26 / YOLO11) + Inpainter (MI-GAN / LaMa)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: watermarkOptionsPanel.wmMode === "ai"

            readonly property string detKey: aiDetectorCombo.keys[aiDetectorCombo.currentIndex] || "watermark-yolo26"
            readonly property bool manualMode: detKey === "none"
            readonly property bool brushMode: detKey === "brush"
            readonly property bool autoDetectMode: !manualMode && !brushMode

            Label {
                text: qsTr("Detector model")
                color: view.theme.textMuted
                font.pixelSize: 12
            }
            ComboBox {
                id: aiDetectorCombo
                objectName: "editorAiDetectorCombo"
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                readonly property var keys: ["watermark-yolo26", "watermark-yolo11", "brush", "none"]
                model: [
                    qsTr("YOLO26 Watermark (Fast, 9.8 MB)"),
                    qsTr("YOLO11 Watermark (Balanced, 11 MB)"),
                    qsTr("Brush mask (Paint on image)"),
                    qsTr("Manual region (No detector)")
                ]
                currentIndex: 0
            }

            Label {
                text: qsTr("Inpainter model")
                color: view.theme.textMuted
                font.pixelSize: 12
            }
            ComboBox {
                id: aiInpainterCombo
                objectName: "editorAiInpainterCombo"
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                readonly property var keys: ["migan-pipeline-v2", "lama-fp32"]
                model: [
                    qsTr("MI-GAN v2 (Fast CPU, 28 MB)"),
                    qsTr("LaMa FFC (High Quality, 208 MB)")
                ]
                currentIndex: 0
            }

            RowLayout {
                Layout.fillWidth: true
                visible: parent.autoDetectMode
                Label {
                    text: qsTr("Confidence")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                Label {
                    text: Math.round(aiConfSlider.value * 100) + "%"
                    color: view.theme.text
                    font.pixelSize: 12
                }
            }
            Slider {
                id: aiConfSlider
                Layout.fillWidth: true
                visible: parent.autoDetectMode
                focusPolicy: Qt.NoFocus
                from: 0.15
                to: 0.90
                stepSize: 0.05
                value: 0.45
            }

            RowLayout {
                Layout.fillWidth: true
                visible: parent.autoDetectMode
                Label {
                    text: qsTr("Mask padding")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                Label {
                    text: Math.round(aiPadSlider.value) + " px"
                    color: view.theme.text
                    font.pixelSize: 12
                }
            }
            Slider {
                id: aiPadSlider
                Layout.fillWidth: true
                visible: parent.autoDetectMode
                focusPolicy: Qt.NoFocus
                from: 0
                to: 32
                stepSize: 2
                value: 8
            }

            // Freehand brush mask controls when detector == "brush"
            Label {
                visible: parent.brushMode
                text: qsTr("Paint directly over the watermark on the image")
                color: view.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                visible: parent.brushMode
                Label {
                    text: qsTr("Mask brush size")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                Label {
                    text: view.wmBrushRadius + " px"
                    color: view.theme.text
                    font.pixelSize: 12
                }
            }
            Slider {
                id: aiBrushRadiusSlider
                Layout.fillWidth: true
                visible: parent.brushMode
                focusPolicy: Qt.NoFocus
                from: 6
                to: 120
                stepSize: 2
                value: view.wmBrushRadius
                onMoved: view.wmBrushRadius = Math.round(value)
            }
            PanelAction {
                visible: parent.brushMode
                Layout.fillWidth: true
                theme: view.theme
                text: qsTr("Clear mask")
                enabled: (view.wmBrushStrokes || []).length > 0
                onClicked: view.clearWmBrushMask()
            }

            // Manual region inputs when detector == "none"
            Label {
                visible: parent.manualMode
                text: qsTr("Drag on the image to mark the watermark area")
                color: view.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                visible: parent.manualMode
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↘"; onClicked: view.setWmCornerPreset("br") }
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↙"; onClicked: view.setWmCornerPreset("bl") }
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↗"; onClicked: view.setWmCornerPreset("tr") }
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↖"; onClicked: view.setWmCornerPreset("tl") }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 6; visible: parent.manualMode
                Label { text: "X"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionX)
                    onEditingFinished: view.setWmRegion(parseInt(text) || 0, view.wmRegionY, view.wmRegionW, view.wmRegionH)
                    Keys.onEscapePressed: focus = false
                }
                Label { text: "Y"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionY)
                    onEditingFinished: view.setWmRegion(view.wmRegionX, parseInt(text) || 0, view.wmRegionW, view.wmRegionH)
                    Keys.onEscapePressed: focus = false
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 6; visible: parent.manualMode
                Label { text: "W"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionW)
                    onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, parseInt(text) || 24, view.wmRegionH)
                    Keys.onEscapePressed: focus = false
                }
                Label { text: "H"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionH)
                    onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, view.wmRegionW, parseInt(text) || 24)
                    Keys.onEscapePressed: focus = false
                }
            }

            PanelAction {
                objectName: "editorAiInpaintRunBtn"
                Layout.fillWidth: true
                theme: view.theme
                primary: true
                text: parent.brushMode ? qsTr("Inpaint painted mask (AI)")
                    : parent.manualMode ? qsTr("Inpaint region (AI)")
                    : qsTr("Detect & remove watermark (AI)")
                enabled: view.documentReady && !watermarkOptionsPanel.wmBusy
                         && (!parent.brushMode || (view.wmBrushStrokes || []).length > 0)
                onClicked: {
                    view.command({
                        type: "editor_ai_inpaint",
                        detector_model: aiDetectorCombo.keys[aiDetectorCombo.currentIndex] || "watermark-yolo26",
                        inpainter_model: aiInpainterCombo.keys[aiInpainterCombo.currentIndex] || "migan-pipeline-v2",
                        confidence: aiConfSlider.value,
                        mask_padding: Math.round(aiPadSlider.value),
                        region_x: view.wmRegionX,
                        region_y: view.wmRegionY,
                        region_width: Math.max(8, view.wmRegionW),
                        region_height: Math.max(8, view.wmRegionH),
                        brush_strokes: view.wmBrushStrokes || [],
                        target: view.effectiveAiTarget()
                    })
                }
            }
        }

        // Mode 1: Gemini Reverse Alpha Blending (Advanced)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: watermarkOptionsPanel.wmMode === "gemini"

            Label {
                text: qsTr("Logo size")
                color: view.theme.textMuted
                font.pixelSize: 12
            }
            ComboBox {
                id: geminiSizeCombo
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                readonly property var keys: ["auto", "small", "large"]
                model: [qsTr("Auto (48 / 96 px)"), "48 × 48 px", "96 × 96 px"]
                currentIndex: 0
            }

            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: qsTr("Logo brightness")
                    color: view.theme.textMuted
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                Label {
                    text: Math.round(geminiLogoSlider.value)
                    color: view.theme.text
                    font.pixelSize: 12
                }
            }
            Slider {
                id: geminiLogoSlider
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                from: 200
                to: 255
                stepSize: 1
                value: 255
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: "dX"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    id: geminiOffX
                    Layout.fillWidth: true
                    text: "0"
                    inputMethodHints: Qt.ImhDigitsOnly
                    Keys.onEscapePressed: focus = false
                }
                Label { text: "dY"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    id: geminiOffY
                    Layout.fillWidth: true
                    text: "0"
                    inputMethodHints: Qt.ImhDigitsOnly
                    Keys.onEscapePressed: focus = false
                }
            }

            CheckBox {
                id: geminiForceCheck
                text: qsTr("Force remove (skip detection)")
                checked: false
                focusPolicy: Qt.NoFocus
            }

            PanelAction {
                objectName: "editorGeminiRunBtn"
                Layout.fillWidth: true
                theme: view.theme
                primary: true
                text: qsTr("Remove Gemini logo")
                enabled: view.documentReady && !watermarkOptionsPanel.wmBusy
                onClicked: {
                    view.command({
                        type: "editor_dewatermark_gemini",
                        size: geminiSizeCombo.keys[geminiSizeCombo.currentIndex] || "auto",
                        logo_value: geminiLogoSlider.value,
                        force: geminiForceCheck.checked,
                        offset_x: parseInt(geminiOffX.text) || 0,
                        offset_y: parseInt(geminiOffY.text) || 0,
                        target: view.effectiveAiTarget()
                    })
                }
            }
        }

        // Mode 2: General Watermark Region Inpaint
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: watermarkOptionsPanel.wmMode === "region"

            Label {
                text: qsTr("Drag on the image to mark the watermark area")
                color: view.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Label {
                text: qsTr("Quick corner presets")
                color: view.theme.textMuted
                font.pixelSize: 12
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↘"; onClicked: view.setWmCornerPreset("br") }
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↙"; onClicked: view.setWmCornerPreset("bl") }
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↗"; onClicked: view.setWmCornerPreset("tr") }
                PanelAction { Layout.fillWidth: true; theme: view.theme; text: "↖"; onClicked: view.setWmCornerPreset("tl") }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: "X"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionX)
                    onEditingFinished: view.setWmRegion(parseInt(text) || 0, view.wmRegionY, view.wmRegionW, view.wmRegionH)
                    Keys.onEscapePressed: focus = false
                }
                Label { text: "Y"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionY)
                    onEditingFinished: view.setWmRegion(view.wmRegionX, parseInt(text) || 0, view.wmRegionW, view.wmRegionH)
                    Keys.onEscapePressed: focus = false
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: "W"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionW)
                    onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, parseInt(text) || 24, view.wmRegionH)
                    Keys.onEscapePressed: focus = false
                }
                Label { text: "H"; color: view.theme.textMuted; font.pixelSize: 12 }
                TextField {
                    Layout.fillWidth: true; text: String(view.wmRegionH)
                    onEditingFinished: view.setWmRegion(view.wmRegionX, view.wmRegionY, view.wmRegionW, parseInt(text) || 24)
                    Keys.onEscapePressed: focus = false
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label { text: qsTr("Edge blend"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
                Label { text: Math.round(inpaintFeatherSlider.value) + " px"; color: view.theme.text; font.pixelSize: 12 }
            }
            Slider {
                id: inpaintFeatherSlider
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                from: 0
                to: 20
                stepSize: 1
                value: 4
            }

            PanelAction {
                objectName: "editorInpaintRunBtn"
                Layout.fillWidth: true
                theme: view.theme
                primary: true
                text: qsTr("Remove watermark region")
                enabled: view.documentReady && !watermarkOptionsPanel.wmBusy
                onClicked: {
                    view.command({
                        type: "editor_inpaint_region",
                        x: view.wmRegionX,
                        y: view.wmRegionY,
                        width: Math.max(8, view.wmRegionW),
                        height: Math.max(8, view.wmRegionH),
                        feather: Math.round(inpaintFeatherSlider.value),
                        target: view.effectiveAiTarget()
                    })
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: watermarkOptionsPanel.wmBusy
            Label {
                Layout.fillWidth: true
                text: watermarkOptionsPanel.activeTask && watermarkOptionsPanel.activeTask.stage
                    ? watermarkOptionsPanel.activeTask.stage : qsTr("Working…")
                color: view.theme.textMuted
                font.pixelSize: 11
                elide: Text.ElideRight
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                ProgressBar {
                    Layout.fillWidth: true
                    from: 0; to: 100
                    value: watermarkOptionsPanel.activeTask ? watermarkOptionsPanel.activeTask.percent : 0
                }
                Button {
                    text: qsTr("Cancel")
                    focusPolicy: Qt.NoFocus
                    onClicked: view.command({ type: "ai_cancel" })
                }
            }
        }

        Label {
            visible: !!(watermarkOptionsPanel.activeTask && !watermarkOptionsPanel.wmBusy && watermarkOptionsPanel.activeTask.error)
            text: watermarkOptionsPanel.activeTask && watermarkOptionsPanel.activeTask.error ? watermarkOptionsPanel.activeTask.error : ""
            color: view.theme.danger
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }

    // ------------------------------------------- AI Caption & .txt Editor (Advanced)
    ColumnLayout {
        id: captionOptionsPanel
        objectName: "editorCaptionPanel"
        Layout.fillWidth: true
        spacing: 10
        visible: view.tool === "caption"

        readonly property var activeTask: (view.state && view.state.aiTask) || null
        readonly property bool capBusy: !!(activeTask && activeTask.running)
        readonly property string savedCaption: (view.state && view.state.editorCaption) || ""
        property string _lastAppliedCap: ""

        onSavedCaptionChanged: {
            if (!captionTextArea.activeFocus) {
                captionTextArea.text = savedCaption
            }
        }

        onActiveTaskChanged: {
            if (!activeTask || activeTask.running || !activeTask.captionText) return
            if (activeTask.captionText === _lastAppliedCap) return
            _lastAppliedCap = activeTask.captionText
            if (captionAppendCheck.checked && captionTextArea.text.trim().length > 0) {
                captionTextArea.text = captionTextArea.text.trim() + ", " + activeTask.captionText
            } else {
                captionTextArea.text = activeTask.captionText
            }
        }

        Label {
            text: qsTr("Caption model")
            color: view.theme.textMuted
            font.pixelSize: 12
        }
        ComboBox {
            id: captionModelCombo
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            readonly property var ids: ["wd-vit-tagger-v3", "wd-swinv2-tagger-v3"]
            model: ["WD-ViT v3 (Fast)", "WD-SwinV2 v3 (Accurate)"]
            currentIndex: 0
        }

        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("General threshold"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: captionGenThresh.value.toFixed(2); color: view.theme.text; font.pixelSize: 12 }
        }
        Slider {
            id: captionGenThresh
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: 0.15
            to: 0.85
            stepSize: 0.05
            value: 0.35
        }

        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Character threshold"); color: view.theme.textMuted; font.pixelSize: 12; Layout.fillWidth: true }
            Label { text: captionCharThresh.value.toFixed(2); color: view.theme.text; font.pixelSize: 12 }
        }
        Slider {
            id: captionCharThresh
            Layout.fillWidth: true
            focusPolicy: Qt.NoFocus
            from: 0.30
            to: 0.95
            stepSize: 0.05
            value: 0.85
        }

        TextField {
            id: captionPrefixField
            Layout.fillWidth: true
            placeholderText: qsTr("Prefix tags (optional)")
            Keys.onEscapePressed: focus = false
        }
        TextField {
            id: captionExcludeField
            Layout.fillWidth: true
            placeholderText: qsTr("Exclude tags (comma-separated)")
            Keys.onEscapePressed: focus = false
        }

        CheckBox {
            id: captionSpacesCheck
            text: qsTr("Replace underscores with spaces")
            checked: true
            focusPolicy: Qt.NoFocus
        }
        CheckBox {
            id: captionAppendCheck
            text: qsTr("Append to existing caption")
            checked: false
            focusPolicy: Qt.NoFocus
        }

        PanelAction {
            objectName: "editorCaptionGenerateBtn"
            Layout.fillWidth: true
            theme: view.theme
            primary: true
            text: qsTr("Generate caption (AI)")
            enabled: view.documentReady && !captionOptionsPanel.capBusy
            onClicked: {
                captionOptionsPanel._lastAppliedCap = ""
                view.command({
                    type: "editor_generate_caption",
                    model_id: captionModelCombo.ids[captionModelCombo.currentIndex] || "wd-vit-tagger-v3",
                    general_threshold: captionGenThresh.value,
                    character_threshold: captionCharThresh.value,
                    replace_underscores: captionSpacesCheck.checked,
                    prefix: captionPrefixField.text,
                    suffix: "",
                    exclude_tags: captionExcludeField.text
                })
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: captionOptionsPanel.capBusy
            Label {
                Layout.fillWidth: true
                text: captionOptionsPanel.activeTask && captionOptionsPanel.activeTask.stage
                    ? captionOptionsPanel.activeTask.stage : qsTr("Working…")
                color: view.theme.textMuted
                font.pixelSize: 11
                elide: Text.ElideRight
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                ProgressBar {
                    Layout.fillWidth: true
                    from: 0; to: 100
                    value: captionOptionsPanel.activeTask ? captionOptionsPanel.activeTask.percent : 0
                }
                Button {
                    text: qsTr("Cancel")
                    focusPolicy: Qt.NoFocus
                    onClicked: view.command({ type: "ai_cancel" })
                }
            }
        }

        Label {
            visible: !!(captionOptionsPanel.activeTask && !captionOptionsPanel.capBusy && captionOptionsPanel.activeTask.error)
            text: captionOptionsPanel.activeTask && captionOptionsPanel.activeTask.error ? captionOptionsPanel.activeTask.error : ""
            color: view.theme.danger
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Label {
            text: qsTr("Caption (.txt)")
            color: view.theme.textMuted
            font.pixelSize: 12
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 140
            clip: true
            TextArea {
                id: captionTextArea
                objectName: "editorCaptionTextArea"
                wrapMode: TextArea.Wrap
                placeholderText: qsTr("Edit or type tags / caption here…")
                text: captionOptionsPanel.savedCaption
                color: view.theme.text
                Keys.onEscapePressed: focus = false
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            PanelAction {
                objectName: "editorCaptionSaveBtn"
                Layout.fillWidth: true
                theme: view.theme
                primary: true
                text: qsTr("Save .txt")
                enabled: view.documentReady
                onClicked: view.command({ type: "editor_save_caption", text: captionTextArea.text })
            }
            PanelAction {
                theme: view.theme
                text: qsTr("Clear")
                enabled: view.documentReady && (captionTextArea.text.length > 0 || captionOptionsPanel.savedCaption.length > 0)
                onClicked: {
                    captionTextArea.text = ""
                    view.command({ type: "editor_save_caption", text: "" })
                }
            }
        }
    }
}
