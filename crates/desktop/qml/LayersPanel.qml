import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Krita / PaintTool SAI-style Layer stack panel for the Editor.
//
// Displays layers top-to-bottom (index len-1 at top, Background at bottom),
// with blend mode + opacity controls for the active layer, visibility/lock
// toggles, inline double-click rename, and bottom stack action buttons.
Item {
    id: panel

    property Theme theme: Theme {}
    /// Bottom-to-top array of `LayerSummary` objects from `state.editor.layers`.
    property var layers: []
    property int activeLayerId: 0
    /// Document-wide canvas background RGB array `[r, g, b]` or `null` when transparent.
    property var canvasBackground: null
    property string lastOpaqueBgHex: "#ffffff"
    property bool hasDocument: false
    property bool collapsed: false
    property bool detached: false

    signal commandRequested(var cmd)
    signal pasteRequested()
    signal canvasBackgroundPopupRequested(var anchor)
    signal toggleCollapsed()
    signal toggleDetached()

    function bgColorHex() {
        var bg = panel.canvasBackground
        if (!bg || bg.length !== 3) return panel.lastOpaqueBgHex
        function h(v) {
            var s = Math.max(0, Math.min(255, Math.round(v))).toString(16)
            return s.length < 2 ? "0" + s : s
        }
        return "#" + h(bg[0]) + h(bg[1]) + h(bg[2])
    }

    function bgColorBytes(hex) {
        var m = /^#([0-9a-fA-F]{6})$/.exec(String(hex || ""))
        if (!m) return [255, 255, 255]
        return [parseInt(m[1].slice(0, 2), 16),
                parseInt(m[1].slice(2, 4), 16),
                parseInt(m[1].slice(4, 6), 16)]
    }

    onCanvasBackgroundChanged: {
        if (canvasBackground && canvasBackground.length === 3) {
            lastOpaqueBgHex = bgColorHex()
        }
    }

    // Reversed list for top-to-bottom display (topmost layer first).
    readonly property var displayLayers: {
        var src = panel.layers || []
        var out = []
        for (var i = src.length - 1; i >= 0; --i) {
            out.push({ stackIndex: i, layer: src[i] })
        }
        return out
    }

    readonly property var activeLayer: {
        var src = panel.layers || []
        for (var i = 0; i < src.length; ++i) {
            if (src[i].id === panel.activeLayerId) return src[i]
        }
        return src.length > 0 ? src[src.length - 1] : null
    }

    readonly property int activeStackIndex: {
        var src = panel.layers || []
        for (var i = 0; i < src.length; ++i) {
            if (src[i].id === panel.activeLayerId) return i
        }
        return -1
    }

    readonly property var blendKeys: ["normal", "multiply", "screen", "overlay", "darken", "lighten", "difference"]
    readonly property var blendLabels: [
        qsTr("Normal"),
        qsTr("Multiply"),
        qsTr("Screen"),
        qsTr("Overlay"),
        qsTr("Darken"),
        qsTr("Lighten"),
        qsTr("Difference")
    ]

    property int editingLayerId: -1

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        // Heading + count + collapse toggle (always visible even when collapsed)
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            spacing: 6
            Label {
                text: qsTr("Layers")
                color: panel.theme.text
                font.bold: true
                Layout.fillWidth: true
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.toggleCollapsed()
                }
            }
            Label {
                visible: panel.hasDocument
                text: String((panel.layers || []).length)
                color: panel.theme.textMuted
                font.pixelSize: 11
            }
            ToolButton {
                objectName: "layersPopoutBtn"
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                padding: 0
                focusPolicy: Qt.NoFocus
                text: panel.detached ? "↙" : "↗"
                ToolTip.visible: hovered
                ToolTip.text: panel.detached ? qsTr("Dock panel") : qsTr("Pop out panel")
                onClicked: panel.toggleDetached()
            }
            ToolButton {
                objectName: "layersCollapseBtn"
                visible: !panel.detached
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                padding: 0
                focusPolicy: Qt.NoFocus
                text: panel.collapsed ? "▸" : "▾"
                onClicked: panel.toggleCollapsed()
            }
        }

        // Active layer Blend Mode + Opacity controls (pinned below header)
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: !panel.collapsed && panel.hasDocument && panel.activeLayer !== null

            ComboBox {
                id: blendCombo
                objectName: "layerBlendCombo"
                Layout.preferredWidth: 112
                focusPolicy: Qt.NoFocus
                model: panel.blendLabels
                currentIndex: {
                    var l = panel.activeLayer
                    if (!l) return 0
                    var idx = panel.blendKeys.indexOf(l.blendMode || "normal")
                    return idx >= 0 ? idx : 0
                }
                onActivated: function(idx) {
                    if (!panel.activeLayer) return
                    panel.commandRequested({
                        type: "editor_layer_set_props",
                        id: panel.activeLayer.id,
                        blend_mode: panel.blendKeys[idx] || "normal"
                    })
                }
            }

            Slider {
                id: opacitySlider
                objectName: "layerOpacitySlider"
                Layout.fillWidth: true
                focusPolicy: Qt.NoFocus
                from: 0
                to: 100
                stepSize: 1
                value: panel.activeLayer ? Math.round((panel.activeLayer.opacity !== undefined ? panel.activeLayer.opacity : 1.0) * 100) : 100
                onPressedChanged: {
                    if (!pressed && panel.activeLayer) {
                        panel.commandRequested({
                            type: "editor_layer_set_props",
                            id: panel.activeLayer.id,
                            opacity: Math.round(value) / 100.0
                        })
                    }
                }
            }

            Label {
                text: Math.round(opacitySlider.value) + "%"
                color: panel.theme.textMuted
                font.pixelSize: 11
                Layout.preferredWidth: 32
                horizontalAlignment: Text.AlignRight
            }
        }

        // Layer stack list (top-to-bottom): fills all vertical space between
        // Blend/Opacity and the bottom action toolbar, scrolling when needed.
        ListView {
            id: layerList
            objectName: "editorLayerList"
            visible: !panel.collapsed
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 36
            clip: true
            spacing: 3
            model: panel.displayLayers
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property var layerData: modelData.layer
                readonly property int stackIndex: modelData.stackIndex
                readonly property bool isActive: layerData.id === panel.activeLayerId
                readonly property bool isEditing: layerData.id === panel.editingLayerId

                width: ListView.view ? ListView.view.width : 200
                height: 34
                radius: panel.theme.radius
                color: isActive ? panel.theme.selection
                     : rowHover.containsMouse ? panel.theme.hover
                     : panel.theme.surface
                border.width: isActive ? 1 : 0
                border.color: panel.theme.accent

                MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function(mouse) {
                        panel.editingLayerId = -1
                        if (!row.isActive) {
                            panel.commandRequested({
                                type: "editor_layer_select",
                                id: row.layerData.id
                            })
                        }
                        if (mouse.button === Qt.RightButton) {
                            layerContextMenu.targetLayer = row.layerData
                            layerContextMenu.targetStackIndex = row.stackIndex
                            layerContextMenu.popup()
                        }
                    }
                    onDoubleClicked: function(mouse) {
                        if (mouse.button !== Qt.LeftButton) return
                        panel.editingLayerId = row.layerData.id
                        renameField.text = row.layerData.name
                        renameField.forceActiveFocus()
                        renameField.selectAll()
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 4

                    // Visibility toggle (eye)
                    ToolButton {
                        objectName: "layerVis_" + row.layerData.id
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        padding: 0
                        focusPolicy: Qt.NoFocus
                        text: row.layerData.visible ? "👁" : "·"
                        opacity: row.layerData.visible ? 1.0 : 0.45
                        ToolTip.visible: hovered
                        ToolTip.text: row.layerData.visible ? qsTr("Hide layer") : qsTr("Show layer")
                        onClicked: panel.commandRequested({
                            type: "editor_layer_set_props",
                            id: row.layerData.id,
                            visible: !row.layerData.visible
                        })
                    }

                    // Layer name (or inline rename field) + subtle meta
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Label {
                            visible: !row.isEditing
                            Layout.fillWidth: true
                            text: row.layerData.name
                            color: row.layerData.visible ? panel.theme.text : panel.theme.textMuted
                            font.pixelSize: 12
                            font.bold: row.isActive
                            elide: Text.ElideRight
                        }

                        TextField {
                            id: renameField
                            visible: row.isEditing
                            Layout.fillWidth: true
                            Layout.preferredHeight: 24
                            font.pixelSize: 12
                            onAccepted: {
                                var n = text.trim()
                                panel.editingLayerId = -1
                                if (n.length > 0 && n !== row.layerData.name) {
                                    panel.commandRequested({
                                        type: "editor_layer_set_props",
                                        id: row.layerData.id,
                                        name: n
                                    })
                                }
                            }
                            Keys.onEscapePressed: panel.editingLayerId = -1
                        }

                        Label {
                            visible: !row.isEditing && (row.layerData.opacity < 0.999 || (row.layerData.blendMode && row.layerData.blendMode !== "normal"))
                            text: (row.layerData.blendMode !== "normal" ? row.layerData.blendMode + " · " : "") + Math.round(row.layerData.opacity * 100) + "%"
                            color: panel.theme.textMuted
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }

                    // Lock toggle
                    ToolButton {
                        objectName: "layerLock_" + row.layerData.id
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        padding: 0
                        focusPolicy: Qt.NoFocus
                        text: row.layerData.locked ? "🔒" : "🔓"
                        opacity: row.layerData.locked ? 1.0 : 0.35
                        ToolTip.visible: hovered
                        ToolTip.text: row.layerData.locked ? qsTr("Unlock layer") : qsTr("Lock layer")
                        onClicked: panel.commandRequested({
                            type: "editor_layer_set_props",
                            id: row.layerData.id,
                            locked: !row.layerData.locked
                        })
                    }
                }
            }
        }

        // Fixed Canvas Background row (Krita / Affinity style): sits underneath
        // all raster layers so the user can switch Transparent <-> Solid color
        // at any time without modifying layer pixels.
        Rectangle {
            id: canvasBgRow
            objectName: "layerCanvasBgRow"
            visible: !panel.collapsed && panel.hasDocument
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            radius: panel.theme.radius
            color: canvasBgHover.containsMouse ? panel.theme.hover : panel.theme.surfaceAlt
            border.width: 1
            border.color: panel.theme.border

            readonly property bool isTransparent: !(panel.canvasBackground && panel.canvasBackground.length === 3)

            MouseArea {
                id: canvasBgHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: panel.canvasBackgroundPopupRequested(canvasBgRow)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                spacing: 6

                // Quick toggle: Transparent <-> Solid color
                ToolButton {
                    objectName: "layerCanvasBgToggle"
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    padding: 0
                    focusPolicy: Qt.NoFocus
                    text: canvasBgRow.isTransparent ? "·" : "👁"
                    opacity: canvasBgRow.isTransparent ? 0.55 : 1.0
                    ToolTip.visible: hovered
                    ToolTip.text: canvasBgRow.isTransparent
                                  ? qsTr("Enable opaque canvas background")
                                  : qsTr("Make canvas background transparent")
                    onClicked: {
                        if (canvasBgRow.isTransparent) {
                            panel.commandRequested({
                                type: "editor_set_canvas_background",
                                transparent: false,
                                color: panel.bgColorBytes(panel.lastOpaqueBgHex)
                            })
                        } else {
                            panel.commandRequested({
                                type: "editor_set_canvas_background",
                                transparent: true
                            })
                        }
                    }
                }

                // Swatch (checkerboard when transparent, solid color when opaque)
                Rectangle {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    radius: 3
                    color: canvasBgRow.isTransparent ? "transparent" : panel.bgColorHex()
                    border.width: 1
                    border.color: panel.theme.border
                    clip: true

                    Checkerboard {
                        anchors.fill: parent
                        visible: canvasBgRow.isTransparent
                        square: 4
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Canvas background")
                    color: panel.theme.text
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

                Label {
                    objectName: "layerCanvasBgStatus"
                    text: canvasBgRow.isTransparent ? qsTr("Transparent") : panel.bgColorHex().toUpperCase()
                    color: panel.theme.textMuted
                    font.pixelSize: 10
                }
            }
        }

        // Bottom Layer actions bar — always anchored to the bottom of the panel
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: !panel.collapsed && panel.hasDocument

            PanelAction {
                objectName: "layerAddBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "+"
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Add empty layer")
                onClicked: panel.commandRequested({ type: "editor_layer_add", name: "" })
            }
            PanelAction {
                objectName: "layerDupBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "⧉"
                enabled: panel.activeLayer !== null
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Duplicate layer")
                onClicked: if (panel.activeLayer) panel.commandRequested({ type: "editor_layer_duplicate", id: panel.activeLayer.id })
            }
            PanelAction {
                objectName: "layerUpBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "▲"
                enabled: panel.activeLayer !== null && panel.activeStackIndex < (panel.layers || []).length - 1
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Move layer up")
                onClicked: if (panel.activeLayer) panel.commandRequested({ type: "editor_layer_reorder", id: panel.activeLayer.id, new_index: panel.activeStackIndex + 1 })
            }
            PanelAction {
                objectName: "layerDownBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "▼"
                enabled: panel.activeLayer !== null && panel.activeStackIndex > 0
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Move layer down")
                onClicked: if (panel.activeLayer) panel.commandRequested({ type: "editor_layer_reorder", id: panel.activeLayer.id, new_index: panel.activeStackIndex - 1 })
            }
            PanelAction {
                objectName: "layerMergeBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "⤓"
                enabled: panel.activeLayer !== null && panel.activeStackIndex > 0 && !panel.activeLayer.locked
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Merge down")
                onClicked: if (panel.activeLayer) panel.commandRequested({ type: "editor_layer_merge_down", id: panel.activeLayer.id })
            }
            PanelAction {
                objectName: "layerFlattenBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "⊟"
                enabled: (panel.layers || []).length > 1
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Flatten image")
                onClicked: panel.commandRequested({ type: "editor_layer_flatten" })
            }
            PanelAction {
                objectName: "layerDeleteBtn"
                Layout.fillWidth: true
                theme: panel.theme
                text: "✕"
                enabled: panel.activeLayer !== null && (panel.layers || []).length > 1 && !panel.activeLayer.locked
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Delete layer")
                onClicked: if (panel.activeLayer) panel.commandRequested({ type: "editor_layer_delete", id: panel.activeLayer.id })
            }
        }
    }

    AppMenu {
        id: layerContextMenu
        objectName: "layerContextMenu"
        theme: panel.theme
        implicitWidth: 210
        property var targetLayer: null
        property int targetStackIndex: -1

        MenuItem {
            text: qsTr("Duplicate layer")
            enabled: layerContextMenu.targetLayer !== null
            onTriggered: if (layerContextMenu.targetLayer) {
                panel.commandRequested({ type: "editor_layer_duplicate", id: layerContextMenu.targetLayer.id })
            }
        }
        MenuItem {
            text: qsTr("Rename")
            enabled: layerContextMenu.targetLayer !== null
            onTriggered: if (layerContextMenu.targetLayer) {
                panel.editingLayerId = layerContextMenu.targetLayer.id
            }
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Copy")
            enabled: layerContextMenu.targetLayer !== null
            onTriggered: panel.commandRequested({ type: "editor_selection_copy", cut: false })
        }
        MenuItem {
            text: qsTr("Cut")
            enabled: layerContextMenu.targetLayer !== null && !layerContextMenu.targetLayer.locked
            onTriggered: panel.commandRequested({ type: "editor_selection_copy", cut: true })
        }
        MenuItem {
            text: qsTr("Paste")
            onTriggered: panel.pasteRequested()
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Merge down")
            enabled: layerContextMenu.targetLayer !== null
                     && layerContextMenu.targetStackIndex > 0
                     && !layerContextMenu.targetLayer.locked
            onTriggered: if (layerContextMenu.targetLayer) {
                panel.commandRequested({ type: "editor_layer_merge_down", id: layerContextMenu.targetLayer.id })
            }
        }
        MenuItem {
            text: qsTr("Flatten image")
            enabled: (panel.layers || []).length > 1
            onTriggered: panel.commandRequested({ type: "editor_layer_flatten" })
        }
        MenuSeparator {}
        MenuItem {
            text: (layerContextMenu.targetLayer && layerContextMenu.targetLayer.visible)
                  ? qsTr("Hide layer") : qsTr("Show layer")
            enabled: layerContextMenu.targetLayer !== null
            onTriggered: if (layerContextMenu.targetLayer) {
                panel.commandRequested({
                    type: "editor_layer_set_props",
                    id: layerContextMenu.targetLayer.id,
                    visible: !layerContextMenu.targetLayer.visible
                })
            }
        }
        MenuItem {
            text: (layerContextMenu.targetLayer && layerContextMenu.targetLayer.locked)
                  ? qsTr("Unlock layer") : qsTr("Lock layer")
            enabled: layerContextMenu.targetLayer !== null
            onTriggered: if (layerContextMenu.targetLayer) {
                panel.commandRequested({
                    type: "editor_layer_set_props",
                    id: layerContextMenu.targetLayer.id,
                    locked: !layerContextMenu.targetLayer.locked
                })
            }
        }
        MenuItem {
            text: qsTr("Delete layer")
            enabled: layerContextMenu.targetLayer !== null
                     && (panel.layers || []).length > 1
                     && !layerContextMenu.targetLayer.locked
            onTriggered: if (layerContextMenu.targetLayer) {
                panel.commandRequested({ type: "editor_layer_delete", id: layerContextMenu.targetLayer.id })
            }
        }
    }
}
