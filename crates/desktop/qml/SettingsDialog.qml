import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// The Settings dialog: a live preview plus the standard four-button contract.
///
/// Every control previews *immediately* — the shell applies the look and the
/// layout without writing anything, so the user judges the result on the real
/// window instead of guessing what a checkbox will do. Nothing reaches
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
/// The form is four pages behind a tab strip: General, Browser, Editor,
/// Viewer. General owns the look, the interface language and the two saved
/// dock widths; each workspace owns the checklist of the panels it can show.
/// A panel is hidden or shown here rather than from a control attached to the
/// column it hides, so the one list is honest about all three workspaces.
///
/// The order of the buttons (Defaults | Cancel · Apply · OK) follows GTK and
/// KDE: the value-restoring button sits apart on the left, the exit buttons on
/// the right, and the default action is the rightmost one.
DialogFrame {
    id: dialog
    namePrefix: "settings"
    title: qsTr("Settings")
    preferredWidth: 620
    // Four tabs share one fixed body, so the dialog keeps the height it asks
    // for instead of growing and shrinking as a page is switched.
    fitToContent: false
    preferredHeight: 520

    property string initialTheme: "dark"
    property bool initialRemember: true
    property bool initialBackground: true
    /// The stored interface language (`system`, `en`, `vi`).
    property string initialLanguage: "system"
    /// The languages the picker offers, `Platform.languages()` in the app and
    /// an empty list where the dialog runs alone (the QML tests).
    property var languageChoices: []
    /// The saved layout, as `set_layout` carries it (`LayoutState` in the
    /// protocol). The dialog edits a copy, so a checkbox is a preview.
    property var initialLayout: ({})

    /// The page on screen: `general`, `browser`, `editor` or `viewer`.
    property string section: "general"
    /// The strip's tabs. The labels are the workspace's own word; the drawings
    /// are this repository's SVGs so the strip follows the theme on a desktop
    /// with no icons for them.
    readonly property var sections: [
        { key: "general", label: qsTr("General"), icon: "icons/preferences.svg" },
        { key: "browser", label: qsTr("Browser"), icon: "icons/browser.svg" },
        { key: "editor", label: qsTr("Editor"), icon: "icons/editor.svg" },
        { key: "viewer", label: qsTr("Viewer"), icon: "icons/viewer.svg" }
    ]

    /// The panels each workspace offers, with the keys `LayoutState` uses.
    /// Quick access and Explorer are the two halves of the left dock, shared by
    /// the three workspaces; the rest belong to one.
    readonly property var browserPanels: [
        { key: "browser.quickAccess", label: qsTr("Quick access") },
        { key: "browser.explorer", label: qsTr("Explorer") },
        { key: "browser.preview", label: qsTr("Preview") },
        { key: "browser.batch", label: qsTr("Batch action") }
    ]
    readonly property var editorPanels: [
        { key: "editor.quickAccess", label: qsTr("Quick access") },
        { key: "editor.explorer", label: qsTr("Explorer") },
        { key: "editor.tools", label: qsTr("Tool rail") },
        { key: "editor.options", label: qsTr("Tool options") },
        { key: "editor.info", label: qsTr("Info") },
        { key: "editor.history", label: qsTr("History") },
        { key: "editor.original", label: qsTr("Original") }
    ]
    readonly property var viewerPanels: [
        { key: "viewer.quickAccess", label: qsTr("Quick access") },
        { key: "viewer.explorer", label: qsTr("Explorer") },
        { key: "viewer.info", label: qsTr("Info") }
    ]

    /// Every key the layout knows, in the order a reset writes them. It mirrors
    /// `LAYOUT_PANEL_KEYS` in the protocol; the shell sanitizes the layout, so
    /// a key this list forgets comes back visible rather than hidden.
    readonly property var allPanelKeys: [
        "browser.quickAccess", "browser.explorer", "browser.preview", "browser.batch",
        "viewer.quickAccess", "viewer.explorer", "viewer.info",
        "editor.quickAccess", "editor.explorer", "editor.tools", "editor.options",
        "editor.info", "editor.history", "editor.original"
    ]

    /// What the dialog was opened with, captured on open so Cancel and the ×
    /// can put the preview back exactly as it was.
    property string openedTheme: initialTheme
    property bool openedRemember: initialRemember
    property bool openedBackground: initialBackground
    property string openedLanguage: initialLanguage
    property var openedLayout: ({})

    /// The layout the form is editing. Replaced rather than mutated so every
    /// checkbox binding sees the change.
    property var editedLayout: ({})

    /// The built-in values "Defaults" restores. The layout numbers mirror
    /// `LayoutState::default()` in the protocol.
    readonly property string defaultTheme: "dark"
    readonly property bool defaultRemember: true
    readonly property bool defaultBackground: true
    readonly property string defaultLanguage: "system"
    readonly property var defaultLayout: ({
        leftWidth: 260, rightWidth: 300, editorToolColumns: 2,
        editorReferenceHeight: 0, editorReferenceTab: "info", panels: ({})
    })

    /// True while the form differs from what is stored *and* saved. Drives the
    /// Apply button: pressing it with nothing pending would be a no-op, and an
    /// always-enabled Apply reads as broken.
    readonly property bool hasPendingChanges: themeChoice.currentIndex !== seenTheme
                                              || rememberChoice.checked !== seenRemember
                                              || backgroundChoice.checked !== seenBackground
                                              || languageChoice.selectedCode() !== seenLanguage
                                              || !dialog.layoutsEqual(dialog.editedLayout,
                                                                      dialog.seenLayout)

    /// What the last save wrote (or what the dialog opened with), so Apply can
    /// tell a fresh change from the one it just committed.
    property int seenTheme: 0
    property bool seenRemember: true
    property bool seenBackground: true
    property string seenLanguage: "system"
    property var seenLayout: ({})

    function themeCode() {
        return themeChoice.currentIndex === 1 ? "light" : "dark"
    }

    function languageCode() {
        return languageChoice.selectedCode()
    }

    function copyLayout(source) {
        return JSON.parse(JSON.stringify(source || ({})))
    }

    /// Is this panel on? An absent key is visible, which is also what a layout
    /// Core has sanitized guarantees.
    function panelValue(key) {
        var panels = dialog.editedLayout.panels || ({})
        return panels[key] !== false
    }

    /// One panel checkbox. The layout is Core's contract, so the key travels
    /// unchanged and only its value differs.
    function setPanel(key, visible) {
        var next = dialog.copyLayout(dialog.editedLayout)
        next.panels = next.panels || ({})
        next.panels[key] = visible
        dialog.editedLayout = next
        dialog.changed()
    }

    /// Compare two layouts field by field. A JSON string comparison would also
    /// compare key order, which a copy from a different source can change
    /// without changing the layout.
    function layoutsEqual(left, right) {
        var a = left || ({})
        var b = right || ({})
        if ((a.leftWidth || 0) !== (b.leftWidth || 0)) return false
        if ((a.rightWidth || 0) !== (b.rightWidth || 0)) return false
        if ((a.editorToolColumns || 0) !== (b.editorToolColumns || 0)) return false
        if ((a.editorReferenceHeight || 0) !== (b.editorReferenceHeight || 0)) return false
        if ((a.editorReferenceTab || "info") !== (b.editorReferenceTab || "info")) return false
        for (var index = 0; index < dialog.allPanelKeys.length; ++index) {
            var key = dialog.allPanelKeys[index]
            var leftPanels = a.panels || ({})
            var rightPanels = b.panels || ({})
            if ((leftPanels[key] !== false) !== (rightPanels[key] !== false)) return false
        }
        return true
    }

    function resetLayout() {
        var next = dialog.copyLayout(dialog.defaultLayout)
        next.panels = ({})
        for (var index = 0; index < dialog.allPanelKeys.length; ++index)
            next.panels[dialog.allPanelKeys[index]] = true
        dialog.editedLayout = next
    }

    /// A save button was pressed: record what was written (so Apply knows it is
    /// no longer pending) and tell the shell.
    function commit() {
        dialog.seenTheme = themeChoice.currentIndex
        dialog.seenRemember = rememberChoice.checked
        dialog.seenBackground = backgroundChoice.checked
        dialog.seenLanguage = dialog.languageCode()
        dialog.seenLayout = dialog.copyLayout(dialog.editedLayout)
        // From now on the form *is* the stored configuration, so closing must
        // not revert it.
        dialog.saved = true
        dialog.saveRequested(dialog.themeCode(), rememberChoice.checked,
                             backgroundChoice.checked, dialog.languageCode())
        dialog.layoutSaveRequested(dialog.copyLayout(dialog.editedLayout))
    }

    /// Put the form back to the values it opened with (or the defaults) and
    /// tell the shell, so the preview follows the form rather than lagging it.
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

    /// True while `restoreValues` is writing the form, so several property
    /// writes produce one preview instead of one each.
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

    /// A control changed. Re-read the form into one preview.
    function changed() {
        if (dialog.restoring) return
        dialog.emitPreview()
    }

    /// One panel row, shared by the three workspace pages. The words and their
    /// colour are `FormCheck`'s (a stock `CheckBox` in a popup drew near-black
    /// text on the dark form); the row only says which panel it is.
    Component {
        id: panelRow
        FormCheck {
            id: row
            theme: dialog.theme
            required property var modelData
            text: modelData.label
            checked: dialog.panelValue(modelData.key)
            Layout.fillWidth: true
            onToggled: dialog.setPanel(modelData.key, checked)
        }
    }

    /// Report the form's current values for a live preview. Emitted on every
    /// change; the shell applies it without persisting.
    function emitPreview() {
        if (dialog.restoring) return
        dialog.previewRequested(dialog.themeCode(), rememberChoice.checked,
                                backgroundChoice.checked, dialog.languageCode())
        dialog.layoutPreviewRequested(dialog.copyLayout(dialog.editedLayout))
    }

    /// The shell merged a layout change into the preview (a splitter, a rail
    /// toggle) while the form was open; the checkboxes follow it.
    function adoptLayout(layout) {
        dialog.editedLayout = dialog.copyLayout(layout)
    }

    /// The opening values, captured before the first visible frame. The frame
    /// has already centred the form and dropped a previous drag by the time
    /// this runs.
    function prepare() {
        dialog.saved = false
        dialog.section = "general"
        // The form *is* the stored configuration on open, and it is written
        // here rather than left to the controls' declarations: a `ComboBox`
        // writes its own `currentIndex` when its model is re-evaluated, and the
        // theme picker's model is `[Dark, Light]` — two translated strings — so
        // the language landing after boot reset the picker to its first entry
        // while the stored theme was light. `themeCode()` then answered `dark`,
        // and simply opening Settings flipped the whole window to dark and drew
        // a dark form around the desktop's light controls. Measured on the real
        // window in light mode. `restoring` keeps the writes from emitting a
        // preview of a form that has not been touched yet.
        dialog.restoring = true
        themeChoice.currentIndex = dialog.initialTheme === "light" ? 1 : 0
        rememberChoice.checked = dialog.initialRemember
        backgroundChoice.checked = dialog.initialBackground
        dialog.restoring = false
        if (dialog.languageChoices && dialog.languageChoices.length > 0) {
            languageChoice.refresh(dialog.languageChoices, dialog.initialLanguage)
        }
        dialog.openedTheme = dialog.initialTheme
        dialog.openedRemember = dialog.initialRemember
        dialog.openedBackground = dialog.initialBackground
        dialog.openedLanguage = dialog.initialLanguage
        dialog.openedLayout = dialog.copyLayout(dialog.initialLayout)
        dialog.editedLayout = dialog.copyLayout(dialog.initialLayout)
        dialog.seenLayout = dialog.copyLayout(dialog.initialLayout)
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
        dialog.editedLayout = dialog.copyLayout(dialog.openedLayout)
        dialog.restoreValues(dialog.openedTheme, dialog.openedRemember,
                             dialog.openedBackground, dialog.openedLanguage)
        dialog.revertRequested()
    }

    /// The × is Cancel: everything previewed is put back before the form
    /// closes, so a stray click cannot keep a change the user never saved.
    onCloseRequested: dialog.revertAndClose()

    /// The tab strip is the frame's `headerStrip`: it sits between the title
    /// bar and the scrolling body, and does not scroll with the body.
    headerStrip: Component {
        Item {
            objectName: "settingsStrip"
            implicitHeight: settingsTabs.implicitHeight + 12

            PanelTabs {
                id: settingsTabs
                objectName: "settingsTabs"
                x: dialog.bodyPadding
                y: 6
                width: parent.width - 2 * dialog.bodyPadding
                theme: dialog.theme
                tabs: dialog.sections
                currentKey: dialog.section
                keyPrefix: "settingsTab"
                onActivated: function(key) { dialog.section = key }
            }
        }
    }

    // -------------------------------------------------- General
    ColumnLayout {
        objectName: "settingsGeneralPage"
        Layout.fillWidth: true
        spacing: 10
        visible: dialog.section === "general"

        FormSection {
            theme: dialog.theme
            title: qsTr("Look")
            Layout.fillWidth: true

            FormRow {
                theme: dialog.theme
                label: qsTr("Theme")
                labelFill: true
                Layout.fillWidth: true

                ComboBox {
                    id: themeChoice
                    objectName: "settingsTheme"
                    Layout.preferredWidth: 220
                    // The two entries are *values* — the labels are only what
                    // they are called in the current interface language. The
                    // model used to be `[qsTr("Dark"), qsTr("Light")]`, which
                    // made the words the entries: any retranslation (the
                    // language lands after boot, and the picker below changes
                    // it) rebuilt the model, a `ComboBox` answers a rebuilt
                    // model by going back to its first row, and the picker then
                    // claimed Dark while the stored theme was Light. Measured on
                    // the real window in light mode: opening Settings answered
                    // `themeCode()` = dark and flipped the whole window dark.
                    model: ["dark", "light"]
                    currentIndex: dialog.initialTheme === "light" ? 1 : 0
                    displayText: themeChoice.currentIndex === 1 ? qsTr("Light") : qsTr("Dark")
                    delegate: ItemDelegate {
                        required property int index
                        width: themeChoice.width
                        text: index === 1 ? qsTr("Light") : qsTr("Dark")
                        highlighted: themeChoice.highlightedIndex === index
                    }
                    // Preview as soon as it changes, not when it is saved.
                    onCurrentIndexChanged: if (dialog.visible) dialog.changed()
                }
            }

            FormRow {
                theme: dialog.theme
                label: qsTr("Language")
                labelFill: true
                Layout.fillWidth: true

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
                    onCurrentIndexChanged: if (dialog.visible) dialog.changed()
                }
            }
        }

        FormSection {
            theme: dialog.theme
            title: qsTr("Panels")
            Layout.fillWidth: true

            Label {
                text: qsTr("The sidebar and detail panel widths are dragged on the window; the saved layout keeps them.")
                color: dialog.theme.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                PanelAction {
                    objectName: "settingsResetLayout"
                    theme: dialog.theme
                    text: qsTr("Reset layout")
                    implicitWidth: 120
                    onClicked: {
                        dialog.resetLayout()
                        dialog.restoreValues(dialog.themeCode(), rememberChoice.checked,
                                             backgroundChoice.checked,
                                             dialog.languageCode())
                    }
                }
                Item { Layout.fillWidth: true }
            }
        }

        FormSection {
            theme: dialog.theme
            title: qsTr("Browsing")
            Layout.fillWidth: true

            // These two are stored in `config.json` and obeyed by Core; the
            // dialog is the only place they can be changed, so they live here
            // rather than being passed through untouched from the snapshot.
            FormCheck {
                id: rememberChoice
                theme: dialog.theme
                objectName: "settingsRemember"
                text: qsTr("Remember the last opened folder")
                checked: dialog.initialRemember
                Layout.fillWidth: true
                onToggled: if (dialog.visible) dialog.changed()
            }
            FormCheck {
                id: backgroundChoice
                theme: dialog.theme
                objectName: "settingsBackground"
                text: qsTr("Generate thumbnails in the background")
                checked: dialog.initialBackground
                Layout.fillWidth: true
                onToggled: if (dialog.visible) dialog.changed()
            }
        }
    }

    // -------------------------------------------------- Browser
    ColumnLayout {
        objectName: "settingsBrowserPage"
        Layout.fillWidth: true
        spacing: 6
        visible: dialog.section === "browser"

        FormSection {
            theme: dialog.theme
            title: qsTr("Panels")
            Layout.fillWidth: true

            Repeater {
                model: dialog.browserPanels
                delegate: panelRow
            }
        }
    }

    // -------------------------------------------------- Editor
    ColumnLayout {
        objectName: "settingsEditorPage"
        Layout.fillWidth: true
        spacing: 6
        visible: dialog.section === "editor"

        FormSection {
            theme: dialog.theme
            title: qsTr("Panels")
            Layout.fillWidth: true

            Repeater {
                model: dialog.editorPanels
                delegate: panelRow
            }
        }
    }

    // -------------------------------------------------- Viewer
    ColumnLayout {
        objectName: "settingsViewerPage"
        Layout.fillWidth: true
        spacing: 6
        visible: dialog.section === "viewer"

        FormSection {
            theme: dialog.theme
            title: qsTr("Panels")
            Layout.fillWidth: true

            Repeater {
                model: dialog.viewerPanels
                delegate: panelRow
            }
        }
    }

    Label {
        objectName: "settingsHint"
        text: qsTr("Changes are previewed as you make them. Apply saves them; OK saves and closes.")
        color: dialog.theme.textMuted
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }

    footer: DialogFooter {
        namePrefix: "settings"
        theme: dialog.theme
        height: dialog.footerHeight

        // Restores the built-in values into the form and previews them. It
        // deliberately does not save: a user who only wanted to look at the
        // defaults can still press Cancel. It sits apart on the left, the way
        // GTK and KDE put the value-restoring button.
        PanelAction {
            objectName: "settingsDefaults"
            theme: dialog.theme
            text: qsTr("Defaults")
            implicitWidth: 88
            onClicked: {
                dialog.resetLayout()
                dialog.restoreValues(dialog.defaultTheme, dialog.defaultRemember,
                                     dialog.defaultBackground, dialog.defaultLanguage)
            }
        }
        Item { Layout.fillWidth: true }
        PanelAction {
            objectName: "settingsCancel"
            theme: dialog.theme
            text: qsTr("Cancel")
            implicitWidth: 88
            onClicked: dialog.revertAndClose()
        }
        PanelAction {
            objectName: "settingsApply"
            theme: dialog.theme
            text: qsTr("Apply")
            implicitWidth: 88
            // Enabled only while the form differs from what was last saved,
            // so the button says whether pressing it would do anything.
            enabled: dialog.hasPendingChanges
            onClicked: dialog.commit()
        }
        PanelAction {
            objectName: "settingsOk"
            theme: dialog.theme
            text: qsTr("OK")
            implicitWidth: 88
            // The default action: it saves and closes, and it is the one verb
            // painted with the accent.
            primary: true
            onClicked: {
                dialog.commit();
                dialog.close();
            }
        }
    }

    /// The form changed and the shell should show it without saving.
    signal previewRequested(string themeName, bool rememberLastFolder,
                            bool backgroundThumbnails, string language)
    /// The layout half of the preview: panels, dock widths and the Editor's
    /// split. Separate from the signal above because a strict signature keeps
    /// the shape every existing control already sends.
    signal layoutPreviewRequested(var layout)
    /// Apply or OK: persist the form's values. The dialog stays open for Apply
    /// and closes for OK, which is decided by the button, not here.
    signal saveRequested(string themeName, bool rememberLastFolder,
                         bool backgroundThumbnails, string language)
    signal layoutSaveRequested(var layout)
    /// Cancel, × or Escape: everything previewed is being undone. Emitted
    /// before the dialog closes.
    signal revertRequested()
}
