import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Editor workspace.
//
// Core owns the working document and its history; this view renders
// `state.editor` and turns clicks into editor_* commands. It keeps no domain
// state of its own: which image is open, whether undo can do anything and the
// history list all come from the snapshot, so a command that Core rejects
// leaves the view showing the truth rather than an optimistic guess.
Item {
    id: view

    property Theme theme: Theme {}
    /// The published Core state; `editor` is null until a document is open.
    property var state: ({})
    property int leftPanelWidth: 220
    property int rightPanelWidth: 260
    property var history: editor ? (editor.history || []) : []

    /// Raised by the empty state and the toolbar's open button; Main owns the
    /// file chooser so the portal/fallback path stays in one place.
    signal requestOpen()
    /// Raised by Save as…: Main owns the chooser, and the chosen path becomes an
    /// `editor_save_as` command. `view.saveAsPath` carries the suggestion.
    signal requestSaveAs()
    signal command(var command)

    readonly property var editor: state.editor || null
    readonly property bool hasDocument: !!(editor && editor.width > 0)
    readonly property bool rendering: !!(editor && editor.rendering)
    readonly property bool modified: !!(editor && editor.modified)
    /// True while the pixels are already on disk at the save path.
    readonly property bool saved: !!(editor && editor.saved)
    /// True while a save is being encoded and written on a worker. Core owns the
    /// flag and publishes it with the document, so the buttons come back when
    /// the write really finished — or failed, with the status line saying why.
    readonly property bool saving: !!(editor && editor.saving)
    /// What the save dialog should suggest: the save path, with the extension
    /// swapped for the format the document is in.
    readonly property string saveAsPath: {
        if (!hasDocument) return ""
        var current = editor.savePath || editor.path || ""
        var dot = current.lastIndexOf(".")
        var base = dot > current.lastIndexOf("/") ? current.slice(0, dot) : current
        return base + (editor.format || ".png")
    }

    /// True while the pointer rests on the canvas. The pan handler arms itself
    /// on it, so a drag that starts on a sidebar does not move the picture.
    property bool panHover: false

    // ------------------------------------------------ presentation transform
    // Exactly the Viewer's model: Core knows nothing about it and it survives
    // no command. 100 % means one document pixel per screen pixel, so the
    // 2048 px preview texture costs sharpness at high zoom but never changes
    // what the percentage means. `autoFit` keeps the picture fitted while the
    // document's own size changes (rotate, crop, resize) and is dropped the
    // moment the user chooses a zoom.
    property real zoom: 1
    property real offsetX: 0
    property real offsetY: 0
    property bool autoFit: true
    /// False until the canvas host exists; the document's size handlers fire
    /// while the view is still being constructed.
    property bool hostReady: false
    /// Where the last wheel landed, in canvas-host coordinates. Read by the
    /// debug build's `KOGAVIEW_DEV_EDITOR_WHEEL` hook to prove the handler — not
    /// a stand-in for it — received the event; nothing in the UI reads it.
    property real lastWheelX: -1
    property real lastWheelY: -1

    readonly property string documentPath: editor ? (editor.path || "") : ""
    readonly property real documentWidth: hasDocument ? editor.width : 0
    readonly property real documentHeight: hasDocument ? editor.height : 0

    function sizeLabel() {
        if (!hasDocument) return "—"
        return editor.width + " × " + editor.height
    }

    readonly property int zoomPercent: Math.round(view.zoom * 100)

    function setZoom(value) {
        view.zoom = Math.max(0.02, Math.min(16, value));
        view.autoFit = false;
        view.clampOffsets();
    }

    /// How far a corner of the picture may travel past the canvas edge before
    /// the clamp stops it: enough to clear the canvas, no more. With this
    /// margin a picture smaller than the viewport can still be dragged aside
    /// (the user asked for a pan that does not depend on the picture being
    /// larger than the window), and one larger than the viewport keeps a few
    /// pixels of context instead of ending flush at its edge.
    readonly property real panMargin: 64

    /// Keep the picture reachable rather than pinned.
    ///
    /// A picture wider than the canvas may be dragged until its far edge meets
    /// the canvas edge plus [`panMargin`]; one narrower than the canvas may be
    /// dragged until it is almost off the canvas, which is what makes a pan
    /// feel free instead of snapping back to the centre. The previous rule
    /// pinned each axis that did not overflow to 0, so a 2400 × 1600 photo in a
    /// 786 × 736 host could be panned left and right but not up and down.
    function clampOffsets() {
        if (!hostReady) return
        var shownX = documentWidth * view.zoom
        var shownY = documentHeight * view.zoom
        var maxX = Math.max(0, (shownX - canvasHost.width) / 2) + view.panMargin
        var maxY = Math.max(0, (shownY - canvasHost.height) / 2) + view.panMargin
        view.offsetX = Math.max(-maxX, Math.min(maxX, view.offsetX))
        view.offsetY = Math.max(-maxY, Math.min(maxY, view.offsetY))
    }

    function fit() {
        if (!hasDocument || !hostReady || canvasHost.width <= 0 || canvasHost.height <= 0) {
            return
        }
        var pad = 32
        view.zoom = Math.max(0.02, Math.min(16,
            Math.min((canvasHost.width - pad) / documentWidth,
                     (canvasHost.height - pad) / documentHeight)))
        view.offsetX = 0
        view.offsetY = 0
        view.autoFit = true
    }

    function actualSize() {
        if (!hasDocument) return
        view.offsetX = 0
        view.offsetY = 0
        view.setZoom(1)
    }

    function zoomIn() {
        view.setZoom(view.zoom * 1.25)
    }

    function zoomOut() {
        view.setZoom(view.zoom / 1.25)
    }

    /// Zoom with the document point under the cursor nailed to the cursor.
    /// `pointX`/`pointY` are in canvas-host coordinates.
    function zoomAt(factor, pointX, pointY) {
        if (!hasDocument) return
        var previous = view.zoom > 0 ? view.zoom : 1
        var next = Math.max(0.02, Math.min(16, previous * factor))
        if (Math.abs(next - previous) < 0.000001) {
            return
        }
        var centerX = canvasHost.width / 2 + view.offsetX
        var centerY = canvasHost.height / 2 + view.offsetY
        var shift = 1 - next / previous
        view.offsetX += (pointX - centerX) * shift
        view.offsetY += (pointY - centerY) * shift
        view.zoom = next
        view.autoFit = false
        view.clampOffsets()
    }

    /// Double-click: fitted <-> actual size.
    function toggleZoom() {
        if (!hasDocument) return
        if (view.autoFit) {
            view.actualSize()
        } else {
            view.fit()
        }
    }

    onDocumentPathChanged: {
        view.autoFit = true
        view.zoom = 1
        view.offsetX = 0
        view.offsetY = 0
        if (view.hostReady) {
            view.fit()
        }
    }

    // An edit that changes the document's size keeps a fitted view fitted and
    // leaves a hand-chosen zoom alone (only re-clamping it to the new edges).
    onDocumentWidthChanged: view.autoFit ? view.fit() : view.clampOffsets()
    onDocumentHeightChanged: view.autoFit ? view.fit() : view.clampOffsets()

    // ------------------------------------------------------------ editor menu
    // The long label serves as the width probe: a regression that cuts labels
    // shows up as "Crop to selection…" losing its ellipsis.
    Menu {
        id: contextMenu
        implicitWidth: view.theme.menuWidth(view.theme.menuLabelWidths)

        MenuItem {
            text: view.theme.menuEntries[24]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_rotate", degrees: -90 })
        }
        MenuItem {
            text: view.theme.menuEntries[25]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_rotate", degrees: 90 })
        }
        MenuItem {
            text: view.theme.menuEntries[26]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_flip", axis: "horizontal" })
        }
        MenuItem {
            text: view.theme.menuEntries[27]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_flip", axis: "vertical" })
        }
        MenuSeparator {}
        MenuItem {
            text: view.theme.menuEntries[28]
            enabled: view.modified
            onTriggered: view.command({ type: "editor_reset" })
        }
        MenuItem {
            text: view.theme.menuEntries[29]
            enabled: view.hasDocument
            onTriggered: view.command({ type: "editor_close" })
        }
    }

    // ------------------------------------------------------ editor workspace
    property Component toolbar: Component {
        RowLayout {
            spacing: 2

            ToolbarButton {
                objectName: "editorOpenButton"
                theme: view.theme
                icon.name: "document-open-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Open an image for editing")
                onClicked: view.requestOpen()
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorRotateLeft"
                theme: view.theme
                icon.name: "object-rotate-left-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[24]
                onClicked: view.command({ type: "editor_rotate", degrees: -90 })
            }
            ToolbarButton {
                objectName: "editorRotateRight"
                theme: view.theme
                icon.name: "object-rotate-right-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[25]
                onClicked: view.command({ type: "editor_rotate", degrees: 90 })
            }
            ToolbarButton {
                objectName: "editorFlipHorizontal"
                theme: view.theme
                icon.name: "object-flip-horizontal"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[26]
                onClicked: view.command({ type: "editor_flip", axis: "horizontal" })
            }
            ToolbarButton {
                objectName: "editorFlipVertical"
                theme: view.theme
                icon.name: "object-flip-vertical"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[27]
                onClicked: view.command({ type: "editor_flip", axis: "vertical" })
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorUndo"
                theme: view.theme
                icon.name: "edit-undo-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!(view.editor && view.editor.canUndo)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Undo")
                onClicked: view.command({ type: "editor_undo" })
            }
            ToolbarButton {
                objectName: "editorRedo"
                theme: view.theme
                icon.name: "edit-redo-symbolic"
                display: AbstractButton.IconOnly
                enabled: !!(view.editor && view.editor.canRedo)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Redo")
                onClicked: view.command({ type: "editor_redo" })
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorZoomOut"
                theme: view.theme
                icon.name: "zoom-out-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom out")
                onClicked: view.zoomOut()
            }
            Label {
                objectName: "editorZoomLabel"
                visible: view.hasDocument
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 48
                text: view.zoomPercent + " %"
                color: view.theme.text
                font.pixelSize: 12
            }
            ToolbarButton {
                objectName: "editorZoomIn"
                theme: view.theme
                icon.name: "zoom-in-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Zoom in")
                onClicked: view.zoomIn()
            }
            ToolbarButton {
                objectName: "editorFit"
                theme: view.theme
                icon.name: "zoom-fit-best-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Fit to window")
                onClicked: view.fit()
            }
            ToolbarButton {
                objectName: "editorActualSize"
                theme: view.theme
                icon.name: "zoom-original-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Actual size (100%)")
                onClicked: view.actualSize()
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorToolbarSave"
                theme: view.theme
                icon.name: "document-save-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument && !view.saved && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save")
                onClicked: view.command({ type: "editor_save" })
            }
            ToolbarButton {
                objectName: "editorToolbarSaveAs"
                theme: view.theme
                icon.name: "document-save-as-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument && !view.saving
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Save as…")
                onClicked: view.requestSaveAs()
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorBack"
                theme: view.theme
                icon.name: "go-previous-symbolic"
                display: AbstractButton.IconOnly
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Back to browser")
                onClicked: view.command({ type: "set_workspace", workspace: "browser" })
            }
            ToolbarSeparator { theme: view.theme }
            ToolbarButton {
                objectName: "editorClose"
                theme: view.theme
                icon.name: "window-close-symbolic"
                display: AbstractButton.IconOnly
                enabled: view.hasDocument
                ToolTip.visible: hovered
                ToolTip.text: view.theme.menuEntries[29]
                onClicked: view.command({ type: "editor_close" })
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ----------------------------------------------------- edits (left)
        // Every operation the Editor offers, and the history of the ones that
        // were applied. The right sidebar only *interacts* with an operation
        // (the numbers a resize or crop needs); a button that changes the
        // image lives here, so the two sides cannot drift into a third place.
        Rectangle {
            objectName: "editorHistory"
            Layout.preferredWidth: view.leftPanelWidth
            Layout.fillHeight: true
            color: view.theme.sidebar

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Label {
                    objectName: "editsHeading"
                    text: qsTr("Edits")
                    color: view.theme.text
                    font.bold: true
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 6
                    rowSpacing: 6

                    Button {
                        objectName: "editsRotateLeft"
                        Layout.fillWidth: true
                        text: qsTr("Rotate left")
                        enabled: view.hasDocument
                        onClicked: view.command({ type: "editor_rotate", degrees: -90 })
                    }
                    Button {
                        objectName: "editsRotateRight"
                        Layout.fillWidth: true
                        text: qsTr("Rotate right")
                        enabled: view.hasDocument
                        onClicked: view.command({ type: "editor_rotate", degrees: 90 })
                    }
                    Button {
                        objectName: "editsFlipHorizontal"
                        Layout.fillWidth: true
                        text: qsTr("Flip horizontal")
                        enabled: view.hasDocument
                        onClicked: view.command({ type: "editor_flip", axis: "horizontal" })
                    }
                    Button {
                        objectName: "editsFlipVertical"
                        Layout.fillWidth: true
                        text: qsTr("Flip vertical")
                        enabled: view.hasDocument
                        onClicked: view.command({ type: "editor_flip", axis: "vertical" })
                    }
                }

                MenuSeparator {}

                Label {
                    text: qsTr("History")
                    color: view.theme.text
                    font.bold: true
                }

                ListView {
                    id: historyList
                    objectName: "historyList"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: view.history
                    spacing: 2
                    delegate: Rectangle {
                        required property string modelData
                        required property int index
                        width: ListView.view.width
                        height: 26
                        radius: view.theme.radius
                        color: "transparent"

                        Label {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            color: view.theme.text
                            font.pixelSize: 12
                            text: (index + 1) + ". " + modelData
                        }
                    }
                }

                Label {
                    Layout.fillWidth: true
                    visible: view.history.length === 0
                    text: view.hasDocument ? qsTr("No edits yet") : qsTr("No image open")
                    color: view.theme.textMuted
                    font.pixelSize: 11
                }

                MenuSeparator {}

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Button {
                        objectName: "undoButton"
                        Layout.fillWidth: true
                        text: qsTr("Undo")
                        enabled: !!(view.editor && view.editor.canUndo)
                        onClicked: view.command({ type: "editor_undo" })
                    }
                    Button {
                        objectName: "redoButton"
                        Layout.fillWidth: true
                        text: qsTr("Redo")
                        enabled: !!(view.editor && view.editor.canRedo)
                        onClicked: view.command({ type: "editor_redo" })
                    }
                }
                Button {
                    objectName: "resetButton"
                    Layout.fillWidth: true
                    text: qsTr("Reset to original")
                    enabled: view.modified
                    onClicked: view.command({ type: "editor_reset" })
                }
            }
        }

        PanelSplitter {
            objectName: "editorLeftSplitter"
            theme: view.theme
            Layout.fillHeight: true
            value: view.leftPanelWidth
            minimum: 160
            maximum: 360
            onMoved: function(width) { view.leftPanelWidth = width }
        }

        // ------------------------------------------------------------- canvas
        Rectangle {
            id: canvasHost
            objectName: "editorCanvasHost"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            color: view.theme.thumb

            Image {
                id: canvas
                objectName: "canvas"
                width: Math.max(1, view.documentWidth)
                height: Math.max(1, view.documentHeight)
                scale: view.zoom
                x: (canvasHost.width - width) / 2 + view.offsetX
                y: (canvasHost.height - height) / 2 + view.offsetY
                // The preview is already encoded at the document aspect ratio;
                // the item is the document coordinate system and its scale is
                // purely presentation state.
                fillMode: Image.Stretch
                asynchronous: false
                cache: false
                source: view.editor && view.editor.previewPath
                        ? "file://" + view.editor.previewPath
                        : ""
                opacity: view.rendering ? 0.65 : 1.0
                Behavior on opacity {
                    NumberAnimation { duration: 120 }
                }
            }

            WheelHandler {
                objectName: "editorWheelHandler"
                acceptedDevices: PointerDevice.AllDevices
                onWheel: function(event) {
                    if (!view.hasDocument) return;
                    var factor = 1;
                    if (event.angleDelta.y !== 0) {
                        factor = Math.pow(1.0015, event.angleDelta.y);
                    } else if (event.pixelDelta.y !== 0) {
                        factor = Math.pow(1.01, event.pixelDelta.y);
                    } else {
                        return;
                    }
                    factor = Math.max(0.5, Math.min(2, factor));
                    view.lastWheelX = event.x;
                    view.lastWheelY = event.y;
                    view.zoomAt(factor, event.x, event.y);
                    event.accepted = true;
                }
            }

            DragHandler {
                id: editorPan
                objectName: "editorPanHandler"
                target: null
                // Arm on the picture only: a drag that begins on a sidebar or
                // a scroll view must keep scrolling.
                enabled: view.panHover
                acceptedDevices: PointerDevice.AllDevices
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                property real startX: 0
                property real startY: 0

                onActiveChanged: {
                    if (active) {
                        startX = view.offsetX;
                        startY = view.offsetY;
                    }
                }
                onTranslationChanged: {
                    view.offsetX = startX + translation.x;
                    view.offsetY = startY + translation.y;
                    view.clampOffsets();
                }
            }

            HoverHandler {
                id: canvasHover
                onHoveredChanged: view.panHover = hovered
            }

            // A middle-click drag pans as well, the way every viewer does it.
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onDoubleTapped: view.toggleZoom()
            }

            // Only the picture is clickable, so a click on the empty canvas
            // margin does not look like it did nothing.
            MouseArea {
                id: canvasArea
                anchors.fill: canvas
                acceptedButtons: Qt.RightButton
                enabled: view.hasDocument
                onClicked: function(mouse) {
                    contextMenu.popup(canvasArea, mouse.x, mouse.y)
                }
            }

            Component.onCompleted: {
                view.hostReady = true
                if (view.hasDocument) view.fit()
            }

            Column {
                anchors.centerIn: parent
                spacing: 6
                visible: !view.hasDocument

                BusyIndicator {
                    anchors.horizontalCenter: parent.horizontalCenter
                    running: visible
                    visible: !!view.editor && view.editor.width === 0
                }
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: view.editor && view.editor.width === 0
                          ? qsTr("Opening %1…").arg(view.editor.name)
                          : qsTr("No image open in the editor")
                    color: view.theme.textMuted
                }
                Button {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Open an image…")
                    objectName: "editorOpenButton"
                    onClicked: view.requestOpen()
                }
            }

            // The render spinner never covers the picture; it sits above it.
            BusyIndicator {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 12
                implicitWidth: 24
                implicitHeight: 24
                running: view.rendering
                visible: running
            }
        }

        PanelSplitter {
            objectName: "editorRightSplitter"
            theme: view.theme
            Layout.fillHeight: true
            value: view.rightPanelWidth
            direction: -1
            minimum: 220
            maximum: 400
            onMoved: function(width) { view.rightPanelWidth = width }
        }

        // ------------------------------------------- editor commands (right)
        // Interactions with the operations the left sidebar offers: the numbers
        // a resize or a crop needs, and where saving writes. Nothing here
        // changes a pixel on its own except the Apply buttons, which send the
        // same typed commands the edit list does.
        Rectangle {
            id: inspector
            objectName: "editorInspector"
            property int preferredWidth: view.rightPanelWidth
            property int minimumWidth: 220
            Layout.preferredWidth: view.rightPanelWidth
            Layout.fillHeight: true
            color: view.theme.surface

            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: inspector.width - 24
                    spacing: 10

                    Label {
                        objectName: "imageHeading"
                        text: qsTr("Image")
                        color: view.theme.text
                        font.bold: true
                    }

                    Label {
                        Layout.fillWidth: true
                        objectName: "imageName"
                        text: view.editor
                              ? (view.editor.name + (view.modified ? " · " + qsTr("edited") : ""))
                              : "—"
                        color: view.theme.text
                        elide: Text.ElideMiddle
                    }

                    Label {
                        Layout.fillWidth: true
                        objectName: "imageSize"
                        text: view.sizeLabel()
                        color: view.theme.textMuted
                    }

                    BusyIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        running: view.rendering
                        visible: running
                    }

                    // ---------------------------------------------------- save
                    MenuSeparator {}
                    Label {
                        objectName: "saveHeading"
                        text: qsTr("Save")
                        color: view.theme.text
                        font.bold: true
                    }

                    // What the file list shows for the document's format, and
                    // whether the pixels on disk are the ones on screen.
                    Label {
                        Layout.fillWidth: true
                        objectName: "saveTarget"
                        text: {
                            if (!view.editor) return "—"
                            var where = view.editor.savePath || view.editor.path || ""
                            var name = where.split("/").pop()
                            var style = view.editor.format ? " (" + view.editor.format + ")" : ""
                            var state = view.saved ? qsTr("saved") : qsTr("unsaved changes")
                            return name + style + " · " + state
                        }
                        color: view.saved ? view.theme.textMuted : view.theme.accent
                        font.pixelSize: 11
                        elide: Text.ElideMiddle
                        wrapMode: Text.NoWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Button {
                            objectName: "editorSaveButton"
                            Layout.fillWidth: true
                            text: qsTr("Save")
                            // Save writes over the source: offered only when
                            // there is something to write.
                            enabled: view.hasDocument && !view.saved && !view.saving
                            ToolTip.visible: hovered
                            ToolTip.text: qsTr("Overwrite the file, keeping a .bak copy of the previous one")
                            onClicked: view.command({ type: "editor_save" })
                        }
                        Button {
                            objectName: "editorSaveAsButton"
                            Layout.fillWidth: true
                            text: qsTr("Save as…")
                            enabled: view.hasDocument && !view.saving
                            ToolTip.visible: hovered
                            ToolTip.text: qsTr("Write a copy and continue editing it")
                            onClicked: view.requestSaveAs()
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        BusyIndicator {
                            Layout.preferredWidth: 18
                            Layout.preferredHeight: 18
                            running: view.saving
                            visible: running
                        }
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Saving…")
                            visible: view.saving
                            color: view.theme.textMuted
                            font.pixelSize: 11
                        }
                    }

                    // -------------------------------------------------- resize
                    MenuSeparator {}
                    Label {
                        objectName: "resizeHeading"
                        text: qsTr("Resize")
                        color: view.theme.text
                        font.bold: true
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 6
                        rowSpacing: 4

                        Label {
                            text: qsTr("Width")
                            color: view.theme.textMuted
                        }
                        TextField {
                            id: widthField
                            objectName: "widthField"
                            Layout.fillWidth: true
                            font.pixelSize: 12
                            placeholderText: view.editor ? String(view.editor.width) : "0"
                            inputMethodHints: Qt.ImhDigitsOnly
                            validator: IntValidator { bottom: 1; top: 20000 }
                        }
                        Label {
                            text: qsTr("Height")
                            color: view.theme.textMuted
                        }
                        TextField {
                            id: heightField
                            objectName: "heightField"
                            Layout.fillWidth: true
                            font.pixelSize: 12
                            placeholderText: view.editor ? String(view.editor.height) : "0"
                            inputMethodHints: Qt.ImhDigitsOnly
                            validator: IntValidator { bottom: 1; top: 20000 }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Button {
                            objectName: "applyResize"
                            text: qsTr("Apply")
                            Layout.fillWidth: true
                            enabled: view.hasDocument
                                     && widthField.acceptableInput
                                     && heightField.acceptableInput
                                     && parseInt(widthField.text) > 0
                                     && parseInt(heightField.text) > 0
                            onClicked: {
                                view.command({
                                    type: "editor_resize",
                                    width: parseInt(widthField.text),
                                    height: parseInt(heightField.text)
                                })
                                widthField.text = ""
                                heightField.text = ""
                            }
                        }
                        Button {
                            objectName: "halfSize"
                            text: qsTr("Half")
                            enabled: view.hasDocument
                            onClicked: {
                                widthField.text = String(Math.max(1, Math.round(view.editor.width / 2)))
                                heightField.text = String(Math.max(1, Math.round(view.editor.height / 2)))
                            }
                        }
                    }

                    // ---------------------------------------------------- crop
                    MenuSeparator {}
                    Label {
                        objectName: "cropHeading"
                        text: qsTr("Crop")
                        color: view.theme.text
                        font.bold: true
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 6
                        rowSpacing: 4

                        Label { text: qsTr("X"); color: view.theme.textMuted }
                        TextField {
                            id: cropX
                            objectName: "cropX"
                            Layout.fillWidth: true
                            font.pixelSize: 12
                            text: "0"
                            inputMethodHints: Qt.ImhDigitsOnly
                            validator: IntValidator { bottom: 0; top: 20000 }
                        }
                        Label { text: qsTr("Y"); color: view.theme.textMuted }
                        TextField {
                            id: cropY
                            objectName: "cropY"
                            Layout.fillWidth: true
                            font.pixelSize: 12
                            text: "0"
                            inputMethodHints: Qt.ImhDigitsOnly
                            validator: IntValidator { bottom: 0; top: 20000 }
                        }
                    }

                    Button {
                        objectName: "applyCrop"
                        Layout.fillWidth: true
                        text: qsTr("Apply crop")
                        enabled: view.hasDocument
                                 && cropX.acceptableInput
                                 && cropY.acceptableInput
                                 && widthField.acceptableInput
                                 && heightField.acceptableInput
                                 && parseInt(widthField.text) > 0
                                 && parseInt(heightField.text) > 0
                        onClicked: view.command({
                            type: "editor_crop",
                            x: parseInt(cropX.text),
                            y: parseInt(cropY.text),
                            width: parseInt(widthField.text),
                            height: parseInt(heightField.text)
                        })
                    }

                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Set Width/Height, then enter the rectangle's top-left corner.")
                        color: view.theme.textMuted
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }

                    Item { Layout.fillHeight: true }
                }
            }
        }
    }
}
