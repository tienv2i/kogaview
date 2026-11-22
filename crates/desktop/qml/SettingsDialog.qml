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

    /// One panel row, shared by the three workspace pages.
    ///
    /// The words take the theme's own colour: a `CheckBox` inside a `Popup`
    /// resolves the *platform* palette (light on this desktop), and its stock
    /// content item drew near-black text on the dark form — measured at
    /// `#2b2f36` on `#181b21`, which is a list a user cannot read. The
    /// indicator stays the style's, so the check mark keeps its accent.
    Component {
        id: panelRow
        CheckBox {
            id: row
            required property var modelData
            text: modelData.label
            checked: dialog.panelValue(modelData.key)
            Layout.fillWidth: true
            onToggled: dialog.setPanel(modelData.key, checked)
            contentItem: Text {
                text: row.text
                color: row.enabled ? dialog.theme.text : dialog.theme.textMuted
                font: row.font
                leftPadding: row.indicator.width + row.spacing
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                opacity: row.enabled ? 1.0 : 0.6
            }
        }
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
        dialog.layoutPreviewRequested(dialog.copyLayout(dialog.editedLayout))
    }

    /// The shell merged a layout change into the preview (a splitter, a rail
    /// toggle) while the form was open; the checkboxes follow it.
    function adoptLayout(layout) {
        dialog.editedLayout = dialog.copyLayout(layout)
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
        dialog.section = "general"
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

    contentItem: ColumnLayout {
        spacing: 0

        PanelTabs {
            objectName: "settingsTabs"
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Layout.topMargin: 12
            theme: dialog.theme
            tabs: dialog.sections
            currentKey: dialog.section
            keyPrefix: "settingsTab"
            onActivated: function(key) { dialog.section = key }
        }

        Flickable {
            objectName: "settingsContent"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: settingsColumn.implicitHeight + 40

            ColumnLayout {
                id: settingsColumn
                objectName: "settingsColumn"
                x: 20
                y: 20
                width: parent.width - 40
                spacing: 10

                // -------------------------------------------------- General
                ColumnLayout {
                    objectName: "settingsGeneralPage"
                    Layout.fillWidth: true
                    spacing: 10
                    visible: dialog.section === "general"

                    Label { text: qsTr("Look"); color: dialog.theme.accent; font.bold: true }
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
                            onCurrentIndexChanged: if (dialog.visible) dialog.changed()
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
                            onCurrentIndexChanged: if (dialog.visible) dialog.changed()
                        }
                    }

                    Label { text: qsTr("Panels"); color: dialog.theme.accent; font.bold: true; Layout.topMargin: 6 }
                    Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
                    Label {
                        text: qsTr("The sidebar and detail panel widths are dragged on the window; the saved layout keeps them.")
                        color: dialog.theme.textMuted
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Button {
                            objectName: "settingsResetLayout"
                            text: qsTr("Reset layout")
                            onClicked: {
                                dialog.resetLayout()
                                dialog.restoreValues(dialog.themeCode(), rememberChoice.checked,
                                                     backgroundChoice.checked,
                                                     dialog.languageCode())
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    Label { text: qsTr("Browsing"); color: dialog.theme.accent; font.bold: true; Layout.topMargin: 6 }
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
                        onToggled: if (dialog.visible) dialog.changed()
                        contentItem: Text {
                            text: rememberChoice.text
                            color: rememberChoice.enabled ? dialog.theme.text
                                                          : dialog.theme.textMuted
                            font: rememberChoice.font
                            leftPadding: rememberChoice.indicator.width
                                         + rememberChoice.spacing
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                    }
                    CheckBox {
                        id: backgroundChoice
                        objectName: "settingsBackground"
                        text: qsTr("Generate thumbnails in the background")
                        checked: dialog.initialBackground
                        Layout.fillWidth: true
                        onToggled: if (dialog.visible) dialog.changed()
                        contentItem: Text {
                            text: backgroundChoice.text
                            color: backgroundChoice.enabled ? dialog.theme.text
                                                            : dialog.theme.textMuted
                            font: backgroundChoice.font
                            leftPadding: backgroundChoice.indicator.width
                                         + backgroundChoice.spacing
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                    }
                }

                // -------------------------------------------------- Browser
                ColumnLayout {
                    objectName: "settingsBrowserPage"
                    Layout.fillWidth: true
                    spacing: 6
                    visible: dialog.section === "browser"

                    Label { text: qsTr("Panels"); color: dialog.theme.accent; font.bold: true }
                    Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
                    Repeater {
                        model: dialog.browserPanels
                        delegate: panelRow
                    }
                }

                // -------------------------------------------------- Editor
                ColumnLayout {
                    objectName: "settingsEditorPage"
                    Layout.fillWidth: true
                    spacing: 6
                    visible: dialog.section === "editor"

                    Label { text: qsTr("Panels"); color: dialog.theme.accent; font.bold: true }
                    Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
                    Repeater {
                        model: dialog.editorPanels
                        delegate: panelRow
                    }
                }

                // -------------------------------------------------- Viewer
                ColumnLayout {
                    objectName: "settingsViewerPage"
                    Layout.fillWidth: true
                    spacing: 6
                    visible: dialog.section === "viewer"

                    Label { text: qsTr("Panels"); color: dialog.theme.accent; font.bold: true }
                    Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }
                    Repeater {
                        model: dialog.viewerPanels
                        delegate: panelRow
                    }
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
                onClicked: {
                    dialog.resetLayout()
                    dialog.restoreValues(dialog.defaultTheme, dialog.defaultRemember,
                                         dialog.defaultBackground, dialog.defaultLanguage)
                }
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
