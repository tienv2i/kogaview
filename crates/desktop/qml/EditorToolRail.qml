import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Left tool rail, quick edits, colour pair and column toggle for `EditorView`.
Rectangle {
    id: toolRail

    required property var view
    objectName: "editorTools"
    Layout.preferredWidth: view.toolRailWidth
    Layout.fillHeight: true
    color: view.theme.sidebar
    enabled: !view.filterDialogOpen
    opacity: view.filterDialogOpen ? 0.55 : 1.0
    // The rail is a panel of its own: it is a column beside the
    // canvas, so Settings › Appearance can put it away, and the canvas
    // takes its width when it does.
    visible: view.toolsShown

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        Label {
            objectName: "editsHeading"
            // A one-column rail is narrower than the word; the tooltips
            // already name everything, so the heading goes rather than
            // eliding to "T…".
            visible: view.toolColumns === 2
            text: qsTr("Tools")
            color: view.theme.text
            font.bold: true
        }

        // The tools. The pointer selects nothing, so Core never sees a
        // command from it; Crop, Transform and Paint write the canvas
        // and their options live in the right column. Resize is not a
        // canvas mode: it opens a dialog, and its button stays lit
        // while that form is up so the rail still says where the
        // question came from.
        GridLayout {
            objectName: "editorToolGrid"
            Layout.fillWidth: true
            columns: view.toolColumns
            columnSpacing: 4
            rowSpacing: 4

            ToolRailButton {
                objectName: "toolPointer"
                theme: view.theme
                iconSource: "icons/pointer.svg"
                tooltip: qsTr("Pointer")
                active: view.tool === "pointer"
                onClicked: {
                    view.tool = "pointer"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolHand"
                theme: view.theme
                iconSource: "icons/hand.svg"
                tooltip: qsTr("Hand (H)")
                active: view.tool === "hand"
                onClicked: {
                    view.tool = "hand"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolZoom"
                theme: view.theme
                iconSource: "icons/zoom.svg"
                tooltip: qsTr("Zoom (Z)")
                active: view.tool === "zoom"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "zoom" ? "pointer" : "zoom"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolBrush"
                theme: view.theme
                iconSource: "icons/brush.svg"
                tooltip: qsTr("Brush (B)")
                active: view.tool === "paint" && view.paintMode === "brush"
                enabled: view.documentReady
                onClicked: {
                    view.tool = "paint"
                    view.selectPaintMode("brush")
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolEraser"
                theme: view.theme
                iconSource: "icons/eraser.svg"
                tooltip: qsTr("Eraser (E)")
                active: view.tool === "paint" && view.paintMode === "eraser"
                enabled: view.documentReady
                onClicked: {
                    view.tool = "paint"
                    view.selectPaintMode("eraser")
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolDraw"
                theme: view.theme
                iconSource: "icons/draw-shapes.svg"
                tooltip: qsTr("Shapes & Curves (U)")
                active: view.tool === "draw"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "draw" ? "pointer" : "draw"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolFill"
                theme: view.theme
                iconSource: "icons/fill.svg"
                tooltip: qsTr("Fill / Paint Bucket")
                active: view.tool === "fill"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "fill" ? "pointer" : "fill"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolGradient"
                theme: view.theme
                iconSource: "icons/gradient.svg"
                tooltip: qsTr("Gradient (G)")
                active: view.tool === "gradient"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "gradient" ? "pointer" : "gradient"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolLiquify"
                theme: view.theme
                iconSource: "icons/liquify.svg"
                tooltip: qsTr("Liquify (Q)")
                active: view.tool === "liquify"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "liquify" ? "pointer" : "liquify"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolEyedropper"
                theme: view.theme
                iconSource: "icons/eyedropper.svg"
                tooltip: qsTr("Color picker / Eyedropper (I)")
                active: view.tool === "eyedropper"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "eyedropper" ? "pointer" : "eyedropper"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolSelect"
                theme: view.theme
                iconSource: "icons/select.svg"
                tooltip: qsTr("Select (M)")
                active: view.tool === "select"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "select" ? "pointer" : "select"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolResize"
                theme: view.theme
                iconSource: "icons/resize.svg"
                tooltip: qsTr("Image size — resize or canvas size")
                active: view.tool === "resize"
                enabled: view.documentReady
                onClicked: view.openResizeDialog()
            }
            ToolRailButton {
                objectName: "toolCrop"
                theme: view.theme
                iconSource: "icons/crop.svg"
                tooltip: qsTr("Crop")
                active: view.tool === "crop"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "crop" ? "pointer" : "crop"
                    view.forceActiveFocus()
                }
            }
            ToolRailButton {
                objectName: "toolTransform"
                theme: view.theme
                iconSource: "icons/transform.svg"
                tooltip: qsTr("Transform — move, scale, rotate and flip")
                active: view.tool === "transform"
                enabled: view.documentReady
                onClicked: {
                    view.tool = view.tool === "transform" ? "pointer" : "transform"
                    view.forceActiveFocus()
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            Layout.topMargin: 2
            Layout.bottomMargin: 2
            color: view.theme.border
        }

        // These change pixels the moment they are pressed, so they are
        // actions rather than tools. Undo, Redo and Reset live on the
        // toolbar; the rail keeps the tools and the quick edits.
        GridLayout {
            objectName: "editorEditGrid"
            Layout.fillWidth: true
            columns: view.toolColumns
            columnSpacing: 4
            rowSpacing: 4

            ToolRailButton {
                objectName: "editsRotateLeft"
                theme: view.theme
                iconSource: "icons/rotate-left.svg"
                tooltip: qsTr("Rotate left")
                enabled: view.documentReady
                onClicked: view.command({ type: "editor_rotate", degrees: -90, target: "whole_image" })
            }
            ToolRailButton {
                objectName: "editsRotateRight"
                theme: view.theme
                iconSource: "icons/rotate-right.svg"
                tooltip: qsTr("Rotate right")
                enabled: view.documentReady
                onClicked: view.command({ type: "editor_rotate", degrees: 90, target: "whole_image" })
            }
            ToolRailButton {
                objectName: "editsFlipHorizontal"
                theme: view.theme
                iconSource: "icons/flip-horizontal.svg"
                tooltip: qsTr("Flip horizontal")
                enabled: view.documentReady
                onClicked: view.command({ type: "editor_flip", axis: "horizontal", target: "whole_image" })
            }
            ToolRailButton {
                objectName: "editsFlipVertical"
                theme: view.theme
                iconSource: "icons/flip-vertical.svg"
                tooltip: qsTr("Flip vertical")
                enabled: view.documentReady
                onClicked: view.command({ type: "editor_flip", axis: "vertical", target: "whole_image" })
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            Layout.topMargin: 2
            Layout.bottomMargin: 2
            color: view.theme.border
        }

        // The pair is the Editor's, not the brush's: it sits under the
        // tools because every tool that takes a colour reads one of
        // its two roles, and it stays visible with no document open —
        // dimmed — so the rail does not grow and shrink a row at a
        // time.
        Item {
            objectName: "colourPairRow"
            Layout.fillWidth: true
            Layout.preferredHeight: 34

            ColourPair {
                id: railColourPair
                objectName: "colourPair"
                anchors.horizontalCenter: parent.horizontalCenter
                enabled: view.documentReady
                theme: view.theme
                foreground: view.foregroundColor
                background: view.backgroundColor
                backgroundTransparent: view.backgroundTransparent
                onForegroundClicked: view.openForegroundChooser()
                onBackgroundClicked:
                    view.openBackgroundPopup(railColourPair.backgroundBox)
                onSwapRequested: {
                    view.swapColours()
                    view.forceActiveFocus()
                }
                onResetRequested: {
                    view.resetColours()
                    view.forceActiveFocus()
                }
            }
        }

        // Canvas background swatch: full width of the rail (2 columns
        // wide in normal mode, 1 column in compact mode), directly below
        // the foreground/background pair.
        Rectangle {
            id: canvasBgSwatch
            objectName: "canvasBgSwatch"
            Layout.fillWidth: true
            Layout.preferredHeight: 22
            radius: view.theme.radius
            color: (!view.canvasBgUseTheme && view.canvasBgChecker)
                   ? "transparent"
                   : (view.canvasBgUseTheme ? view.theme.thumb : view.canvasBgColor)
            border.width: 1
            border.color: canvasBgHover.hovered ? view.theme.accent : view.theme.border
            clip: true

            Checkerboard {
                anchors.fill: parent
                visible: !view.canvasBgUseTheme && view.canvasBgChecker
            }
            HoverHandler { id: canvasBgHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                ToolTip.visible: containsMouse
                ToolTip.delay: 400
                ToolTip.text: qsTr("Canvas background")
                onClicked: view.openCanvasBgPopup(canvasBgSwatch)
            }
        }

        Item { Layout.fillHeight: true }

        // The rail's own width is its one control: no splitter, because
        // a rail dragged wide is a column again.
        ToolRailButton {
            objectName: "toolRailColumns"
            theme: view.theme
            iconSource: view.toolColumns === 2 ? "icons/columns-one.svg"
                                               : "icons/columns-two.svg"
            tooltip: view.toolColumns === 2 ? qsTr("One column")
                                            : qsTr("Two columns")
            onClicked: view.setToolColumns(view.toolColumns === 2 ? 1 : 2)
        }
    }
}
