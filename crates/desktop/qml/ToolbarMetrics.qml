import QtQuick

// The measured pieces the main toolbar's layout is decided from.
//
// One object, read by `Main.qml` (what the window must be and whether labels
// are allowed) and by `WorkspaceSwitcher.qml` (how wide each of its buttons
// is). Keeping the arithmetic here is what stops the window floor and the
// label threshold from drifting apart as buttons are added: both are derived
// from `compactToolbarWidth` and `labelledToolbarWidth`.
//
// Text is measured with `TextMetrics` at the application font — the font the
// labels are drawn in. Nothing here reads a width that any of it writes, so
// there is no binding loop (the trap a `Menu`'s own font has).
// An `Item`, not a `QtObject`: `TextMetrics` has to be declared as a child, and
// `QtObject` has no default property to put one in. It is never shown.
Item {
    id: metrics
    visible: false
    width: 0
    height: 0

    /// An icon-only toolbar button. It is the same square whether or not the
    /// label is showing (`CompactToolbarButton.implicitWidth`).
    readonly property int buttonWidth: 34
    /// Room a label adds next to the icon: the gap and the right padding.
    readonly property int labelPadding: 12
    readonly property int buttonSpacing: 2
    /// `ToolbarSeparator` plus the row's own spacing around it.
    readonly property int separatorWidth: 9
    /// The main menu button, which always trails the row.
    readonly property int menuButtonWidth: 34

    /// The header row itself (`Main.qml`): 8 px either side and a 4 px gap
    /// between its children. These are the real numbers from that `RowLayout`,
    /// not estimates — the label threshold is checked against the live row in
    /// `tests/qml/tst_toolbar.cpp`, which fails if these drift.
    readonly property int rowSideMargins: 2 * 8
    readonly property int childSpacing: 4
    /// How many children the row always has besides the switcher, the
    /// separator and the workspace toolbar: the elastic spacer, the busy
    /// indicator and the menu button.
    readonly property int trailingChildren: 3
    /// The row's children, counted: the three above plus the switcher, the
    /// separator and the workspace toolbar. A `RowLayout` puts one gap
    /// *between* adjacent children, so there are `rowChildren - 1` of them —
    /// counting gaps per trailing child instead was 8 px short of the live row
    /// (`tests/qml/tst_toolbar.cpp` now measures against the layout itself).
    readonly property int rowChildren: metrics.trailingChildren + 3
    /// The `BusyIndicator`, sized in `Main.qml`.
    readonly property int busyIndicatorWidth: 28

    /// How many icon slots each workspace toolbar has, and how many separators
    /// it draws between them — counted from the real toolbars in
    /// `BrowserView.qml`, `Viewer.qml` and `EditorView.qml`. A workspace that
    /// adds a button or a separator must update these two numbers;
    /// `tests/qml/tst_toolbar.cpp` counts the workspace toolbars in the QML
    /// sources and fails when they disagree.
    readonly property int browserButtons: 6
    readonly property int browserSeparators: 1
    readonly property int viewerButtons: 12
    readonly property int viewerSeparators: 4
    readonly property int editorButtons: 15
    readonly property int editorSeparators: 6

    /// `EditorView`'s zoom readout is a fixed 48 px (`Layout.preferredWidth`),
    /// wider than the icon square it stands in for. The Middle other readouts
    /// grow with the data instead and are measured at their widest likely
    /// value below.
    readonly property int editorZoomLabelWidth: 48

    /// Measured at the application font: the widest text each flexible
    /// readout in a workspace toolbar can show. A `1 / 12` counter becomes
    /// `12 / 1200` in a large folder; an editor zoom shows `100 %` at most.
    /// Over-estimating is the safe direction — it makes the window floor a
    /// little wider, never narrower than a control.
    TextMetrics {
        id: viewerCounterLabel
        font: Qt.application.font
        // 6 px of padding on either side, like the real `Label`.
        text: "9999 / 9999      "
    }
    TextMetrics {
        id: editorZoomLabel
        font: Qt.application.font
        text: "100 %    "
    }


    // ------------------------------------------------------------- measuring
    //
    // One measurement per label; the widths below read their advances. An
    // `advanceWidth` read before the item completes is 0, which keeps every
    // width finite instead of NaN.
    //
    // The strings are fetched with `qsTranslate(context, …)` and **not** with
    // `qsTr()`: `qsTr` would look them up in this file's own context
    // (`ToolbarMetrics`), which the catalogue does not have, so it would silently
    // measure the English source while the window drew a longer translation.
    // `qsTranslate` names the context the label is really translated in — the
    // switcher for the three workspaces, `Main` for the menu — so these are the
    // same words, in the same font, as the buttons they measure.
    //
    // `scripts/check_translations.py` fails if either half of a `qsTranslate`
    // is not in the catalogue, so a moved or renamed label cannot degrade into
    // an English measurement without the gate noticing.
    TextMetrics {
        id: browserLabel
        font: Qt.application.font
        text: qsTranslate("WorkspaceSwitcher", "Browser")
    }
    TextMetrics {
        id: viewerLabel
        font: Qt.application.font
        text: qsTranslate("WorkspaceSwitcher", "Viewer")
    }
    TextMetrics {
        id: editorLabel
        font: Qt.application.font
        text: qsTranslate("WorkspaceSwitcher", "Editor")
    }
    TextMetrics {
        id: menuLabel
        font: Qt.application.font
        text: qsTranslate("Main", "Menu")
    }

    readonly property var switcherLabelWidths:
        [browserLabel.advanceWidth, viewerLabel.advanceWidth, editorLabel.advanceWidth]

    /// Width of one button with its label.
    function labelledButtonWidth(labelWidth) {
        return metrics.buttonWidth + labelWidth + metrics.labelPadding
    }

    /// The switcher, three icons and no labels.
    readonly property real switcherIconsWidth:
        metrics.switcherLabelWidths.length * metrics.buttonWidth
        + (metrics.switcherLabelWidths.length - 1) * metrics.buttonSpacing

    /// The switcher, three `<icon> <text>` buttons.
    readonly property real switcherLabelsWidth: {
        var total = (metrics.switcherLabelWidths.length - 1) * metrics.buttonSpacing
        for (var index = 0; index < metrics.switcherLabelWidths.length; ++index) {
            total += metrics.labelledButtonWidth(metrics.switcherLabelWidths[index])
        }
        return total
    }

    /// Width of one workspace's toolbar in icons: its buttons, the gaps between
    /// them (the row's `spacing: 2`, which also falls either side of a
    /// separator) and its `ToolbarSeparator`s.
    function toolbarWidth(buttons, separators) {
        return buttons * metrics.buttonWidth
                + separators * metrics.separatorWidth
                + Math.max(0, buttons + separators - 1) * metrics.buttonSpacing
    }

    /// Width of one workspace's toolbar: its buttons, separators and any text
    /// readout between them (the Viewer's image counter, the Editor's zoom).
    readonly property real browserToolbarWidth:
        metrics.toolbarWidth(metrics.browserButtons, metrics.browserSeparators)
    readonly property real viewerToolbarWidth:
        metrics.toolbarWidth(metrics.viewerButtons, metrics.viewerSeparators)
        + viewerCounterLabel.advanceWidth
    readonly property real editorToolbarWidth:
        metrics.toolbarWidth(metrics.editorButtons, metrics.editorSeparators)
        + Math.max(metrics.editorZoomLabelWidth, editorZoomLabel.advanceWidth)

    /// The widest workspace toolbar: the one that decides the floor, because
    /// the window must be able to show whichever workspace is open. Every
    /// workspace can be the open one, so the floor takes the widest.
    readonly property real widestToolbarWidth:
        Math.max(metrics.browserToolbarWidth,
                 Math.max(metrics.viewerToolbarWidth, metrics.editorToolbarWidth))

    /// Every gap in the header row, whatever the label state: between the
    /// switcher, the separator, the workspace toolbar, the spacer, the busy
    /// indicator and the menu — plus the row's own margins.
    readonly property real rowGaps:
        metrics.childSpacing * (metrics.rowChildren - 1) + metrics.rowSideMargins

    /// The toolbar with every label turned off. This is the narrowest window
    /// that can still show every control.
    readonly property real compactToolbarWidth:
        metrics.switcherIconsWidth + metrics.separatorWidth + metrics.widestToolbarWidth
        + metrics.busyIndicatorWidth + metrics.menuButtonWidth + metrics.rowGaps

    /// The Browser's and the Editor's fixed side panels, plus a picture wide
    /// enough to be worth looking at. A window that satisfies only the toolbar
    /// would leave the Editor's canvas a few pixels wide.
    readonly property real sidePanelWidth: 260
    readonly property real pictureWidth: 320

    /// The header row with the labels showing: the compact row plus the room
    /// the two labelled controls take beyond their icon squares.
    readonly property real labelledToolbarWidth:
        metrics.compactToolbarWidth
        + (metrics.switcherLabelsWidth - metrics.switcherIconsWidth)
        + (metrics.labelledButtonWidth(menuLabel.advanceWidth) - metrics.menuButtonWidth)

    /// Headroom the labelled row keeps beyond its own intrinsic width. Qt's
    /// `Text` rounds each label to a whole pixel and the layout rounds again,
    /// so a window exactly as wide as the arithmetic says can still lose the
    /// last pixel.
    ///
    /// Measured on the real window with the widest workspace (Editor) open:
    /// the labelled row's own `implicitWidth` is 1039 px in English and 1133 px
    /// in Vietnamese, while `labelledToolbarWidth` says 1114 px and 1208 px —
    /// it budgets the widest workspace whichever one is open, so it is
    /// deliberately generous. The threshold is therefore the widest row plus
    /// this slack, and it moves with the interface language because the labels
    /// above are measured translated.
    readonly property real labelSlack: 16

    /// The width at which the window can afford the labels.
    readonly property real labelThreshold:
        Math.ceil(metrics.labelledToolbarWidth + metrics.labelSlack)

    /// The window floor: the toolbar with every label dropped *and* room left
    /// for a sidebar and a picture. The window must never be so narrow that a
    /// control is cut off; it *may* be narrower than the labelled toolbar —
    /// that is what dropping the labels is for.
    readonly property real minimumWindowWidth:
        Math.ceil(Math.max(metrics.compactToolbarWidth,
                           metrics.sidePanelWidth + metrics.pictureWidth))

}
