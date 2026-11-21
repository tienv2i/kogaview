import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// The Settings dialog: a live preview plus the standard four-button contract.
///
/// Every control previews *immediately* through `previewRequested` — the shell
/// applies the look without writing anything, so the user judges the result on
/// the real window instead of guessing what "Light" will do. Nothing reaches
/// `config.json` until a save button is pressed:
///
/// - **Defaults** restores the built-in values into the form (and previews
///   them). It does not save and does not close.
/// - **Cancel** puts everything back the way the dialog found it, previews that,
///   and closes; nothing is written.
/// - **Apply** saves and leaves the dialog open, so a second change is one click
///   away.
/// - **OK** saves and closes.
///
/// The order (Defaults | Cancel · Apply · OK) follows GTK and KDE: the
/// value-restoring button sits apart on the left, the exit buttons on the
/// right, and the default action is the rightmost one.
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

    /// The values the dialog was opened with, captured on open so Cancel and
    /// the × can put the preview back exactly as it was.
    readonly property var openedTheme: initialTheme
    readonly property bool openedRemember: initialRemember
    readonly property bool openedBackground: initialBackground
    readonly property string openedLanguage: initialLanguage

    /// The built-in values "Defaults" restores.
    readonly property string defaultTheme: "dark"
    readonly property bool defaultRemember: true
    readonly property bool defaultBackground: true
    readonly property string defaultLanguage: "system"

    /// True while the form differs from what is stored *and* saved. Drives the
    /// Apply button: pressing it with nothing pending would be a no-op, and an
    /// always-enabled Apply reads as broken.
    readonly property bool hasPendingChanges: themeChoice.currentIndex !== seenTheme
                                              || rememberChoice.checked !== seenRemember
                                              || backgroundChoice.checked !== seenBackground
                                              || languageChoice.selectedCode() !== seenLanguage

    /// What the last save wrote (or what the dialog opened with), so Apply can
    /// tell a fresh change from the one it just committed.
    property int seenTheme: 0
    property bool seenRemember: true
    property bool seenBackground: true
    property string seenLanguage: "system"

    function themeCode() {
        return themeChoice.currentIndex === 1 ? "light" : "dark"
    }

    function languageCode() {
        return languageChoice.selectedCode()
    }

    /// A save button was pressed: record what was written (so Apply knows it is
    /// no longer pending) and tell the shell.
    function commit() {
        dialog.seenTheme = themeChoice.currentIndex
        dialog.seenRemember = rememberChoice.checked
        dialog.seenBackground = backgroundChoice.checked
        dialog.seenLanguage = dialog.languageCode()
        // From now on the form *is* the stored configuration, so closing must
        // not revert it.
        dialog.saved = true
        dialog.saveRequested(dialog.themeCode(), rememberChoice.checked,
                             backgroundChoice.checked, dialog.languageCode())
    }

    /// Put the form back to `theme`/`remember`/`background`/`language` and tell
    /// the shell, so the preview follows the form rather than lagging it.
    function restoreValues(themeCode, remember, background, language) {
        dialog.restoring = true
        themeChoice.currentIndex = themeCode === "light" ? 1 : 0
        rememberChoice.checked = remember
        backgroundChoice.checked = background
        if (dialog.languageChoices && dialog.languageChoices.length > 0) {
            languageChoice.refresh(dialog.languageChoices, language)
        }
        dialog.restoring = false
        dialog.emitPreview()
    }

    /// True while `restoreValues` is writing the form, so four property writes
    /// produce one preview instead of four.
    property bool restoring: false
    /// True once Apply or OK has written the form's values to the configuration.
    property bool saved: false

    /// Cancel, × or Escape: undo the preview and close. The stored
    /// configuration was never touched unless something was saved, in which
    /// case the saved values are what the form already holds.
    function revertAndClose() {
        dialog.saved = false
        dialog.close()
    }

    title: qsTr("Settings")
    modal: true
    dim: true
    width: Math.min(620, parent ? parent.width - 48 : 620)
    height: Math.min(520, parent ? parent.height - 48 : 520)
    padding: 0
    // Escape reverts like Cancel; a click outside still does not dismiss, so a
    // stray click cannot silently discard a previewed change.
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
    /// Report the form's current values for a live preview. Emitted on every
    /// change; the shell applies it without persisting.
    function emitPreview() {
        if (dialog.restoring) return
        dialog.previewRequested(dialog.themeCode(), rememberChoice.checked,
                                backgroundChoice.checked, dialog.languageCode())
    }

    // Position and fill the form before it becomes visible. `opened` is emitted
    // only after the style's enter transition, so centring there made the
    // first frames appear at the positioner's default corner and then jump to
    // the middle. `aboutToShow` fires before `visibleChanged`, while the popup
    // already has its parent and its size.
    onAboutToShow: {
        moved = false
        centerInParent()
        dialog.saved = false
        if (dialog.languageChoices && dialog.languageChoices.length > 0) {
            languageChoice.refresh(dialog.languageChoices, dialog.initialLanguage)
        }
        dialog.seenTheme = themeChoice.currentIndex
        dialog.seenRemember = rememberChoice.checked
        dialog.seenBackground = backgroundChoice.checked
        dialog.seenLanguage = dialog.languageCode()
    }
    /// Every way out of the dialog ends here — OK, Cancel, ×, Escape and the
    /// shell closing it. If nothing was saved, whatever was previewed on the
    /// way is undone: the form goes back to the opening values and the shell is
    /// told to repaint with them. The stored configuration was never touched,
    /// so restoring the values is the whole undo.
    onClosed: {
        if (dialog.saved) return
        dialog.restoreValues(dialog.openedTheme, dialog.openedRemember,
                             dialog.openedBackground, dialog.openedLanguage)
        dialog.revertRequested()
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
            // Closing with the title bar's × is Cancel, not OK.
            ToolButton { objectName: "settingsClose"; text: qsTr("×"); font.pixelSize: 24; onClicked: dialog.revertAndClose() }
        }
    }

    contentItem: Flickable { objectName: "settingsContent"; clip: true; contentHeight: settingsColumn.implicitHeight + 40
        ColumnLayout { id: settingsColumn; objectName: "settingsColumn"; x: 20; y: 20; width: parent.width - 40; spacing: 18
            Label { text: qsTr("Appearance"); color: dialog.theme.accent; font.bold: true }
            Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
            RowLayout { Layout.fillWidth: true
                Label { text: qsTr("Theme"); color: dialog.theme.text; Layout.fillWidth: true }
                ComboBox {
                    id: themeChoice
                    objectName: "settingsTheme"
                    model: [qsTr("Dark"), qsTr("Light")]
                    currentIndex: dialog.initialTheme === "light" ? 1 : 0
                    Layout.preferredWidth: 220
                    // Preview as soon as it changes, not when it is saved.
                    onCurrentIndexChanged: if (dialog.visible) dialog.emitPreview()
                }
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
                    onCurrentIndexChanged: if (dialog.visible) dialog.emitPreview()
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
                onToggled: if (dialog.visible) dialog.emitPreview()
            }
            CheckBox {
                id: backgroundChoice
                objectName: "settingsBackground"
                text: qsTr("Generate thumbnails in the background")
                checked: dialog.initialBackground
                Layout.fillWidth: true
                onToggled: if (dialog.visible) dialog.emitPreview()
            }
            Label {
                text: qsTr("Changes are previewed as you make them. Apply saves them; OK saves and closes.")
                color: dialog.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
    }

    footer: Rectangle {
        // A plain footer instead of `DialogButtonBox`: that template re-sorts
        // its buttons by role (Accept first, then Reject, Apply, Reset), so the
        // declaration order is not the drawn order — measured: OK landed at
        // x=446, left of everything. Here the order is literal.
        objectName: "settingsButtons"
        implicitHeight: 60
        color: dialog.theme.surface
        border.color: dialog.theme.border
        border.width: 1
        // Explicit `Button`s, not `standardButtons`: Qt draws "OK"/"Cancel"
        // from the system's `qtbase_<locale>.qm`, and a machine without that
        // file (this one ships no `qtbase_vi`) leaves a Vietnamese dialog with
        // English buttons. These read the app's own catalogue, which travels
        // inside the binary.
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 8

            // Restores the built-in values into the form and previews them. It
            // deliberately does not save: a user who only wanted to look at the
            // defaults can still press Cancel. It sits apart on the left, the
            // way GTK and KDE put the value-restoring button.
            Button {
                objectName: "settingsDefaults"
                text: qsTr("Defaults")
                onClicked: dialog.restoreValues(dialog.defaultTheme, dialog.defaultRemember,
                                                dialog.defaultBackground, dialog.defaultLanguage)
            }
            Item { Layout.fillWidth: true }
            Button {
                objectName: "settingsCancel"
                text: qsTr("Cancel")
                onClicked: dialog.revertAndClose()
            }
            Button {
                objectName: "settingsApply"
                text: qsTr("Apply")
                // Enabled only while the form differs from what was last saved,
                // so the button says whether pressing it would do anything.
                enabled: dialog.hasPendingChanges
                onClicked: dialog.commit()
            }
            Button {
                objectName: "settingsOk"
                text: qsTr("OK")
                highlighted: true
                onClicked: {
                    dialog.commit();
                    dialog.close();
                }
            }
        }
    }

    /// The form changed and the shell should show it without saving.
    signal previewRequested(string themeName, bool rememberLastFolder,
                            bool backgroundThumbnails, string language)
    /// Apply or OK: persist the form's values. The dialog stays open for Apply
    /// and closes for OK, which is decided by the button, not here.
    signal saveRequested(string themeName, bool rememberLastFolder,
                         bool backgroundThumbnails, string language)
    /// Cancel, × or Escape: everything previewed is being undone. Emitted
    /// before the dialog closes.
    signal revertRequested()
}
