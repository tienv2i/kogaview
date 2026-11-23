import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// Compact popover for choosing both Viewer chrome density (`compact`, `simple`,
/// `standard`) and image display mode (`single`, `dual`, `webtoon`), plus
/// contextual Dual / Webtoon options that appear only when relevant.
Popup {
    id: popup

    property Theme theme: Theme {}
    property string currentMode: "standard"
    property string displayMode: "single"
    property bool mangaRtl: false
    property bool mangaCoverSeparate: true
    property int mangaPageGap: 8
    property string webtoonFitMode: "auto"

    signal modeSelected(string mode)
    signal displayModeSelected(string mode)
    signal mangaOptionsChanged(var patch)
    signal webtoonFitSelected(string fitMode)

    padding: 8
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property double _lastClosedMs: 0
    onClosed: _lastClosedMs = Date.now()

    function toggleBelow(anchor) {
        popup.toggleNear(anchor, "top")
    }

    function toggleNear(anchor, edge) {
        if (popup.visible) {
            popup.close()
            return
        }
        if (Date.now() - popup._lastClosedMs < 200) {
            return
        }
        if (anchor && popup.parent) {
            var w = popup.implicitWidth > 0 ? popup.implicitWidth : 292
            var h = popup.implicitHeight > 0 ? popup.implicitHeight : 320
            var pos = anchor.mapToItem(popup.parent, 0, 0)
            var px = pos.x
            var py = pos.y + anchor.height + 4
            if (edge === "bottom") {
                px = pos.x + (anchor.width - w) / 2
                py = pos.y - h - 6
            } else if (edge === "left") {
                px = pos.x + anchor.width + 8
                py = pos.y + (anchor.height - h) / 2
            } else if (edge === "right") {
                px = pos.x - w - 8
                py = pos.y + (anchor.height - h) / 2
            } else {
                px = pos.x
                py = pos.y + anchor.height + 4
            }
            var maxX = Math.max(8, popup.parent.width - w - 8)
            var maxY = Math.max(8, popup.parent.height - h - 8)
            popup.x = Math.max(8, Math.min(px, maxX))
            popup.y = Math.max(8, Math.min(py, maxY))
        }
        popup.open()
    }

    readonly property var uiModeChoices: [
        { key: "compact", label: qsTr("Compact") },
        { key: "simple", label: qsTr("Simple") },
        { key: "standard", label: qsTr("Standard") }
    ]

    readonly property var displayModeChoices: [
        {
            key: "single",
            title: qsTr("Single"),
            subtitle: qsTr("One image fitted to the viewport")
        },
        {
            key: "dual",
            title: qsTr("Dual page (book)"),
            subtitle: qsTr("Two-page spread with smart landscape & cover pairing")
        },
        {
            key: "webtoon",
            title: qsTr("Webtoon (vertical)"),
            subtitle: qsTr("Virtualized continuous vertical scroll")
        }
    ]

    background: Rectangle {
        color: popup.theme.surface
        border.width: 1
        border.color: popup.theme.border
        radius: popup.theme.radius + 2
    }

    contentItem: ColumnLayout {
        spacing: 6

        // ---- Section 1: UI Chrome Density (Compact / Simple / Standard) ----
        Label {
            text: qsTr("Viewer layout")
            color: popup.theme.textMuted
            font.pixelSize: 11
            font.bold: true
            Layout.leftMargin: 4
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Repeater {
                model: popup.uiModeChoices

                delegate: Button {
                    id: segBtn
                    required property var modelData
                    readonly property bool selected: popup.currentMode === modelData.key
                    objectName: "viewerModeChoice_" + modelData.key
                    Layout.fillWidth: true
                    implicitHeight: 28
                    padding: 4
                    focusPolicy: Qt.NoFocus
                    text: modelData.label

                    contentItem: Label {
                        text: segBtn.text
                        color: segBtn.selected ? popup.theme.accent : popup.theme.text
                        font.pixelSize: 12
                        font.bold: segBtn.selected
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    background: Rectangle {
                        radius: popup.theme.radius
                        color: segBtn.selected ? popup.theme.selection
                             : segBtn.hovered ? popup.theme.hover
                             : "transparent"
                        border.width: 1
                        border.color: segBtn.selected ? popup.theme.accent : popup.theme.border
                    }

                    onClicked: popup.modeSelected(modelData.key)
                    onDoubleClicked: {
                        popup.modeSelected(modelData.key)
                        popup.close()
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: popup.theme.border
        }

        // ---- Section 2: Display Mode (Single / Dual / Webtoon) ----
        Label {
            text: qsTr("Display mode")
            color: popup.theme.textMuted
            font.pixelSize: 11
            font.bold: true
            Layout.leftMargin: 4
        }

        Repeater {
            model: popup.displayModeChoices

            delegate: ItemDelegate {
                id: rowItem
                required property var modelData
                readonly property bool selected: popup.displayMode === modelData.key

                objectName: "viewerDisplayChoice_" + modelData.key
                Layout.fillWidth: true
                implicitWidth: 272
                leftPadding: 8
                rightPadding: 10
                topPadding: 5
                bottomPadding: 5
                focusPolicy: Qt.NoFocus
                hoverEnabled: true

                background: Rectangle {
                    radius: popup.theme.radius
                    color: rowItem.selected ? popup.theme.selection
                         : rowItem.hovered ? popup.theme.hover
                         : "transparent"
                    border.width: rowItem.selected ? 1 : 0
                    border.color: popup.theme.accent
                }

                contentItem: RowLayout {
                    spacing: 8

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: 14
                        height: 14
                        radius: 7
                        color: "transparent"
                        border.width: rowItem.selected ? 2 : 1.5
                        border.color: rowItem.selected ? popup.theme.accent : popup.theme.textMuted

                        Rectangle {
                            anchors.centerIn: parent
                            width: 6
                            height: 6
                            radius: 3
                            color: popup.theme.accent
                            visible: rowItem.selected
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Label {
                            text: modelData.title
                            color: popup.theme.text
                            font.bold: rowItem.selected
                            font.pixelSize: 12
                            Layout.fillWidth: true
                        }

                        Label {
                            text: modelData.subtitle
                            color: popup.theme.textMuted
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                    }
                }

                onClicked: popup.displayModeSelected(modelData.key)
                onDoubleClicked: {
                    popup.displayModeSelected(modelData.key)
                    popup.close()
                }
            }
        }

        // ---- Section 3: Contextual Dual / Webtoon options ----
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: popup.displayMode === "dual" || popup.displayMode === "webtoon"

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: popup.theme.border
            }

            // Dual-only: Reading direction (LTR / RTL) + Separate cover
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: popup.displayMode === "dual"

                Label {
                    text: qsTr("Direction")
                    color: popup.theme.textMuted
                    font.pixelSize: 11
                    Layout.fillWidth: true
                }

                Repeater {
                    model: [
                        { rtl: false, label: qsTr("LTR →") },
                        { rtl: true, label: qsTr("RTL ←") }
                    ]
                    delegate: Button {
                        id: dirBtn
                        required property var modelData
                        readonly property bool active: popup.mangaRtl === modelData.rtl
                        objectName: modelData.rtl ? "viewerDirectionRtl" : "viewerDirectionLtr"
                        implicitHeight: 24
                        leftPadding: 8
                        rightPadding: 8
                        focusPolicy: Qt.NoFocus
                        text: modelData.label
                        contentItem: Label {
                            text: dirBtn.text
                            color: dirBtn.active ? popup.theme.accent : popup.theme.text
                            font.pixelSize: 11
                            font.bold: dirBtn.active
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: popup.theme.radius
                            color: dirBtn.active ? popup.theme.selection
                                 : dirBtn.hovered ? popup.theme.hover : "transparent"
                            border.width: 1
                            border.color: dirBtn.active ? popup.theme.accent : popup.theme.border
                        }
                        onClicked: popup.mangaOptionsChanged({ mangaRtl: modelData.rtl })
                    }
                }
            }

            FormCheck {
                objectName: "viewerSeparateCover"
                visible: popup.displayMode === "dual"
                theme: popup.theme
                text: qsTr("Separate cover page")
                checked: popup.mangaCoverSeparate
                Layout.fillWidth: true
                onToggled: popup.mangaOptionsChanged({ mangaCoverSeparate: checked })
            }

            // Shared Dual & Webtoon: Page gap (0 / 8 / 16 px)
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Label {
                    text: qsTr("Page gap")
                    color: popup.theme.textMuted
                    font.pixelSize: 11
                    Layout.fillWidth: true
                }

                Repeater {
                    model: [0, 8, 16]
                    delegate: Button {
                        id: gapBtn
                        required property int modelData
                        readonly property bool active: popup.mangaPageGap === modelData
                        implicitHeight: 24
                        leftPadding: 8
                        rightPadding: 8
                        focusPolicy: Qt.NoFocus
                        text: modelData + " px"
                        contentItem: Label {
                            text: gapBtn.text
                            color: gapBtn.active ? popup.theme.accent : popup.theme.text
                            font.pixelSize: 11
                            font.bold: gapBtn.active
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: popup.theme.radius
                            color: gapBtn.active ? popup.theme.selection
                                 : gapBtn.hovered ? popup.theme.hover : "transparent"
                            border.width: 1
                            border.color: gapBtn.active ? popup.theme.accent : popup.theme.border
                        }
                        onClicked: popup.mangaOptionsChanged({ mangaPageGap: modelData })
                    }
                }
            }

            // Webtoon-only: Smart Auto-Fit & sizing modes
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                visible: popup.displayMode === "webtoon"

                Label {
                    text: qsTr("Fit")
                    color: popup.theme.textMuted
                    font.pixelSize: 11
                    Layout.fillWidth: true
                }

                Repeater {
                    model: [
                        { key: "auto", label: qsTr("Auto") },
                        { key: "width", label: qsTr("Width") },
                        { key: "height", label: qsTr("Height") },
                        { key: "original", label: qsTr("100%") }
                    ]
                    delegate: Button {
                        id: fitBtn
                        required property var modelData
                        readonly property bool active: popup.webtoonFitMode === modelData.key
                        objectName: "webtoonFit_" + modelData.key
                        implicitHeight: 24
                        leftPadding: 7
                        rightPadding: 7
                        focusPolicy: Qt.NoFocus
                        text: modelData.label
                        contentItem: Label {
                            text: fitBtn.text
                            color: fitBtn.active ? popup.theme.accent : popup.theme.text
                            font.pixelSize: 11
                            font.bold: fitBtn.active
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: popup.theme.radius
                            color: fitBtn.active ? popup.theme.selection
                                 : fitBtn.hovered ? popup.theme.hover : "transparent"
                            border.width: 1
                            border.color: fitBtn.active ? popup.theme.accent : popup.theme.border
                        }
                        onClicked: popup.webtoonFitSelected(modelData.key)
                    }
                }
            }
        }
    }
}
