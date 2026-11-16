import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: dialog
    property Theme theme: Theme {}
    property string initialTheme: "dark"
    property bool initialRemember: true
    property bool initialBackground: true
    /// The stored interface language (`system`, `en`, `vi`).
    property string initialLanguage: "system"
    /// The languages the picker offers, `Platform.languages()` in the app and
    /// an empty list where the dialog runs alone (the QML tests).
    property var languageChoices: []

    title: qsTr("Settings")
    modal: true
    dim: true
    width: Math.min(620, parent ? parent.width - 48 : 620)
    height: Math.min(520, parent ? parent.height - 48 : 520)
    padding: 0
    // Escape dismisses without saving, like a desktop dialog. A click outside
    // still does not: the dialog owns the Save/Reset contract.
    closePolicy: Popup.CloseOnEscape
    // x/y are set by hand instead of `anchors.centerIn`: an anchor owns the
    // position and snaps a written x back within one frame (measured in a probe:
    // 10 -> 90), which also makes a header drag impossible. `moved` keeps a
    // dialog the user placed where they dropped it.
    property bool moved: false
    function centerInParent() {
        if (!parent) return
        x = Math.round((parent.width - width) / 2)
        y = Math.round((parent.height - height) / 2)
    }
    onOpened: {
        moved = false
        centerInParent()
        if (dialog.languageChoices && dialog.languageChoices.length > 0) {
            languageChoice.refresh(dialog.languageChoices, dialog.initialLanguage)
        }
    }
    onWidthChanged: if (!moved) centerInParent()
    onHeightChanged: if (!moved) centerInParent()
    background: Rectangle { color: dialog.theme.surface; border.color: dialog.theme.border; border.width: 1; radius: dialog.theme.radius }

    header: Rectangle {
        objectName: "settingsHeader"
        implicitHeight: 52; color: dialog.theme.surfaceAlt
        border.color: dialog.theme.border; border.width: 1
        // Drag the dialog by its title bar. `target: null` keeps the handler off
        // the header's own coordinates and moves the dialog instead; the clamp
        // stops a drag from parking it outside the window.
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
        RowLayout { anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 10
            Label { text: dialog.title; color: dialog.theme.text; font.pixelSize: 17; font.bold: true; Layout.fillWidth: true }
            ToolButton { objectName: "settingsClose"; text: qsTr("×"); font.pixelSize: 24; onClicked: dialog.reject() }
        }
    }

    contentItem: Flickable { objectName: "settingsContent"; clip: true; contentHeight: settingsColumn.implicitHeight + 40
        ColumnLayout { id: settingsColumn; objectName: "settingsColumn"; x: 20; y: 20; width: parent.width - 40; spacing: 18
            Label { text: qsTr("Appearance"); color: dialog.theme.accent; font.bold: true }
            Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
            RowLayout { Layout.fillWidth: true
                Label { text: qsTr("Theme"); color: dialog.theme.text; Layout.fillWidth: true }
                ComboBox { id: themeChoice; model: [qsTr("Dark"), qsTr("Light")]; currentIndex: dialog.initialTheme === "light" ? 1 : 0; Layout.preferredWidth: 220 }
            }
            RowLayout { Layout.fillWidth: true
                Label { text: qsTr("Language"); color: dialog.theme.text; Layout.fillWidth: true }
                ComboBox {
                    id: languageChoice
                    objectName: "languageChoice"
                    Layout.preferredWidth: 220
                    // A picker you can only read in the language you do not
                    // speak yet is useless, so an entry names its language in
                    // that language and, in parentheses, in English. The
                    // entries come from C++ (`Platform.languages()`); the list
                    // is copied once on open instead of bound, because
                    // `textRole` on a plain JS array is what makes every entry
                    // render.
                    textRole: "label"
                    model: []
                    /// Which code the picker will report: the chosen entry, or
                    /// `system` when the model was never filled (the dialog is
                    /// used without a shell, as in the QML tests).
                    function selectedCode() {
                        return currentIndex >= 0 && model[currentIndex]
                               ? model[currentIndex].code : "system";
                    }
                    function refresh(choices, current) {
                        var entries = [];
                        var index = 0;
                        var selected = 0;
                        for (var choice = 0; choice < choices.length; choice++) {
                            var entry = choices[choice];
                            entries.push({
                                code: entry.code,
                                label: entry.code === "vi"
                                      ? entry.vietnamese
                                      : entry.english + " (" + entry.vietnamese + ")"
                            });
                            if (entry.code === current) selected = index;
                            index++;
                        }
                        model = entries;
                        currentIndex = selected;
                    }
                }
            }
            Label { text: qsTr("Browsing"); color: dialog.theme.accent; font.bold: true }
            Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
            // These two are stored in `config.json` and obeyed by Core; the
            // dialog is the only place they can be changed, so they live here
            // rather than being passed through untouched from the snapshot.
            CheckBox {
                id: rememberChoice
                objectName: "settingsRemember"
                text: qsTr("Remember the last opened folder")
                checked: dialog.initialRemember
                Layout.fillWidth: true
            }
            CheckBox {
                id: backgroundChoice
                objectName: "settingsBackground"
                text: qsTr("Generate thumbnails in the background")
                checked: dialog.initialBackground
                Layout.fillWidth: true
            }
            Label {
                text: qsTr("Changes are applied when you press Save.")
                color: dialog.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
    }

    footer: DialogButtonBox {
        // Explicit buttons, not `standardButtons`: Qt draws "Save"/"Cancel"
        // from the system's `qtbase_<locale>.qm`, and a machine without that
        // file (this one ships no `qtbase_vi`) leaves a Vietnamese dialog with
        // two English buttons. These read the app's own catalogue, which
        // travels inside the binary.
        objectName: "settingsButtons"
        alignment: Qt.AlignRight
        padding: 12
        Button {
            text: qsTr("Cancel")
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        }
        Button {
            objectName: "settingsSave"
            text: qsTr("Save")
            highlighted: true
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
        Button { text: qsTr("Reset"); DialogButtonBox.buttonRole: DialogButtonBox.Reset; onClicked: dialog.resetRequested() }
        onAccepted: {
            dialog.saveRequested(themeChoice.currentIndex === 1 ? "light" : "dark",
                                 rememberChoice.checked, backgroundChoice.checked,
                                 languageChoice.selectedCode());
            dialog.accept();
        }
        onRejected: dialog.reject()
    }
    signal resetRequested()
    signal saveRequested(string themeName, bool rememberLastFolder, bool backgroundThumbnails, string language)
}
