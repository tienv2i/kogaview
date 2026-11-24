import QtQuick

// The measured pieces the main toolbar's layout is decided from.
//
// One object, read by `Main.qml` (which of the three modes the window is in,
// what the window must be and whether labels are allowed) and by
// `WorkspaceSwitcher.qml` (how wide each of its buttons is). Keeping the
// arithmetic here is what stops the window floor and the label thresholds from
// drifting apart as buttons are added: the floor and every threshold are derived
// from these widths.
//
// A workspace row has three modes: labels (`full`), every icon (`compact`) and
// the folded row (`mini`). Each workspace is measured on its own, because a
// window that fits the Browser's six buttons has no reason to fold its toolbar
// just because the Editor — three workspace switches away — needs twelve. The
// switcher's three buttons are part of every one of those sums, so switching
// workspace re-measures the row instead of inheriting a tier chosen for
// another view. See `modeFor()`.
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
    /// sources and fails when they disagree. The overflow button is not
    /// counted: it is the one control the mini row adds in place of the ones
    /// it folds, so counting it would budget room for a button the compact row
    /// never draws.
    readonly property int browserButtons: 4
    readonly property int browserSeparators: 1
    readonly property int viewerButtons: 15
    readonly property int viewerSeparators: 3
    readonly property int editorButtons: 12
    readonly property int editorSeparators: 3

    /// The buttons each workspace keeps once the window is too narrow for the
    /// whole icon row, the overflow button included. The rest of its actions
    /// move into that button's menu (`*OverflowMenu` in each view), and the
    /// mini row draws no separators: at 9 px each they buy nothing when the
    /// row is being folded. The QML suites count the visible buttons in the
    /// real toolbars, so a button whose `visible` does not follow this rule
    /// fails there rather than quietly making the floor too narrow.
    readonly property int browserMiniButtons: 4
    readonly property int viewerMiniButtons: 4
    readonly property int editorMiniButtons: 5

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

    /// The switcher collapsed into a single icon + chevron dropdown button
    /// with comfortable left padding before folding secondary toolbar buttons.
    readonly property int switcherCollapsedWidth: 52

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

    /// Width of the Viewer's 24 px canvas-background swatch plus its 2 px gap.
    readonly property int viewerBgSwatchWidth: 26

    /// Width of one workspace's toolbar: its buttons, separators and any text
    /// readout between them (the Viewer's image counter, the Editor's zoom).
    readonly property real browserToolbarWidth:
        metrics.toolbarWidth(metrics.browserButtons, metrics.browserSeparators)
    readonly property real viewerNoCounterToolbarWidth:
        metrics.toolbarWidth(metrics.viewerButtons, metrics.viewerSeparators)
        + metrics.viewerBgSwatchWidth
    readonly property real viewerToolbarWidth:
        metrics.viewerNoCounterToolbarWidth + viewerCounterLabel.advanceWidth
    readonly property real editorToolbarWidth:
        metrics.toolbarWidth(metrics.editorButtons, metrics.editorSeparators)
        + Math.max(metrics.editorZoomLabelWidth, editorZoomLabel.advanceWidth)

    /// The widest workspace toolbar: kept for the window floor and for the
    /// tests that assert no workspace is forgotten. The fold points themselves
    /// are per workspace (see `modeFor()`), so the Browser is not folded at the
    /// Editor's width.
    readonly property real widestToolbarWidth:
        Math.max(metrics.browserToolbarWidth,
                 Math.max(metrics.viewerToolbarWidth, metrics.editorToolbarWidth))

    /// The same three rows folded into their mini form: fewer buttons, no
    /// separators, and — in the Editor — no zoom readout, because the buttons
    /// that change that zoom are the ones that moved into the menu.
    readonly property real browserMiniToolbarWidth:
        metrics.toolbarWidth(metrics.browserMiniButtons, 0)
    // In mini mode the Viewer also hides its `1 / N` image counter label.
    readonly property real viewerMiniToolbarWidth:
        metrics.toolbarWidth(metrics.viewerMiniButtons, 0)
    readonly property real editorMiniToolbarWidth:
        metrics.toolbarWidth(metrics.editorMiniButtons, 0)
    readonly property real widestMiniToolbarWidth:
        Math.max(metrics.browserMiniToolbarWidth,
                 Math.max(metrics.viewerMiniToolbarWidth, metrics.editorMiniToolbarWidth))

    /// Every gap in the header row, whatever the mode: between the switcher, the
    /// separator, the workspace toolbar, the spacer, the busy indicator and the
    /// menu — plus the row's own margins.
    readonly property real rowGaps:
        metrics.childSpacing * (metrics.rowChildren - 1) + metrics.rowSideMargins

    /// One workspace's header row with the labels off: the switcher as three
    /// icons, the separator, that workspace's toolbar, the busy indicator, the
    /// Menu button and every gap. The switcher's three buttons are inside this
    /// sum, which is why switching workspace changes the answer.
    function rowWidth(switcherWidth, workspaceWidth) {
        return switcherWidth + metrics.separatorWidth + workspaceWidth
                + metrics.busyIndicatorWidth + metrics.menuButtonWidth
                + metrics.rowGaps
    }

    /// The row with every workspace control on screen and no labels. This is
    /// where that workspace starts folding: below it its own icons do not fit.
    readonly property real browserCompactRowWidth:
        metrics.rowWidth(metrics.switcherIconsWidth, metrics.browserToolbarWidth)
    readonly property real viewerCompactRowWidth:
        metrics.rowWidth(metrics.switcherIconsWidth, metrics.viewerToolbarWidth)
    readonly property real editorCompactRowWidth:
        metrics.rowWidth(metrics.switcherIconsWidth, metrics.editorToolbarWidth)

    /// The row with the switcher collapsed to 1 dropdown button while every
    /// workspace icon still fits.
    readonly property real browserCollapsedRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.browserToolbarWidth)
    readonly property real viewerCollapsedRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.viewerToolbarWidth)
    readonly property real viewerNoCounterRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.viewerNoCounterToolbarWidth)
    readonly property real editorCollapsedRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.editorToolbarWidth)

    /// The same rows folded (with the switcher collapsed to one dropdown button
    /// and the Viewer's image counter hidden).
    readonly property real browserMiniRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.browserMiniToolbarWidth)
    readonly property real viewerMiniRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.viewerMiniToolbarWidth)
    readonly property real editorMiniRowWidth:
        metrics.rowWidth(metrics.switcherCollapsedWidth, metrics.editorMiniToolbarWidth)

    /// What the two labelled controls add to any row: the switcher's labels
    /// beyond its three icon squares, and the Menu's label beyond its square.
    readonly property real labelExtraWidth:
        (metrics.switcherLabelsWidth - metrics.switcherIconsWidth)
        + (metrics.labelledButtonWidth(menuLabel.advanceWidth) - metrics.menuButtonWidth)

    /// The row with its workspace labels and the Menu label.
    readonly property real browserLabelledRowWidth:
        metrics.browserCompactRowWidth + metrics.labelExtraWidth
    readonly property real viewerLabelledRowWidth:
        metrics.viewerCompactRowWidth + metrics.labelExtraWidth
    readonly property real editorLabelledRowWidth:
        metrics.editorCompactRowWidth + metrics.labelExtraWidth

    /// The widest of the three rows in each state. They are derived from the
    /// per-workspace rows above, so there is one arithmetic and no second set of
    /// constants: the floor fits the widest folded row and the label test uses
    /// the widest labelled row.
    readonly property real compactToolbarWidth:
        Math.max(metrics.browserCompactRowWidth,
                 Math.max(metrics.viewerCompactRowWidth, metrics.editorCompactRowWidth))
    readonly property real miniToolbarWidth:
        Math.max(metrics.browserMiniRowWidth,
                 Math.max(metrics.viewerMiniRowWidth, metrics.editorMiniRowWidth))
    readonly property real labelledToolbarWidth:
        Math.max(metrics.browserLabelledRowWidth,
                 Math.max(metrics.viewerLabelledRowWidth, metrics.editorLabelledRowWidth))

    /// The Browser's and the Editor's fixed side panels, plus a picture wide
    /// enough to be worth looking at. Keeps the window from being resized too small.
    readonly property real sidePanelWidth: 260
    readonly property real pictureWidth: 320

    /// Headroom a labelled row keeps beyond its own intrinsic width. Qt's
    /// `Text` rounds each label to a whole pixel and the layout rounds again,
    /// so a window exactly as wide as the arithmetic says can still lose the
    /// last pixel.
    ///
    /// Measured on the real window with the widest workspace (Editor) open:
    /// the labelled row's own `implicitWidth` is 1039 px in English and 1133 px
    /// in Vietnamese, while `labelledToolbarWidth` says 1114 px and 1208 px, so
    /// the arithmetic budgets a little more than the row needs. The threshold
    /// is therefore the row plus this slack, and it moves with the interface
    /// language because the labels above are measured translated.
    readonly property real labelSlack: 16

    /// The width at which one workspace's row can afford its labels. Each is
    /// that workspace's own row: the Browser draws them earlier than the
    /// Editor, because it has six buttons rather than thirteen.
    readonly property real browserLabelThreshold:
        Math.ceil(metrics.browserLabelledRowWidth + metrics.labelSlack)
    readonly property real viewerLabelThreshold:
        Math.ceil(metrics.viewerLabelledRowWidth + metrics.labelSlack)
    readonly property real editorLabelThreshold:
        Math.ceil(metrics.editorLabelledRowWidth + metrics.labelSlack)

    /// The widest label threshold, for tests and for the fallback that has no
    /// workspace name.
    readonly property real labelThreshold:
        Math.max(metrics.browserLabelThreshold,
                 Math.max(metrics.viewerLabelThreshold, metrics.editorLabelThreshold))

    /// One workspace's fold point: below this width its own icon row does not
    /// fit, so it folds.
    function compactRowFor(workspace) {
        if (workspace === "viewer") return metrics.viewerCompactRowWidth
        if (workspace === "editor") return metrics.editorCompactRowWidth
        return metrics.browserCompactRowWidth
    }

    /// One workspace's switcher-collapse point: below `compactRowFor` the
    /// 3-button switcher collapses into 1 dropdown while keeping all workspace
    /// icons visible; below `collapsedRowFor` secondary buttons fold into `⋯`.
    function collapsedRowFor(workspace) {
        if (workspace === "viewer") return metrics.viewerCollapsedRowWidth
        if (workspace === "editor") return metrics.editorCollapsedRowWidth
        return metrics.browserCollapsedRowWidth
    }

    /// One workspace's label point: at or above this width its row fits with
    /// the switcher and Menu labels showing.
    function labelThresholdFor(workspace) {
        if (workspace === "viewer") return metrics.viewerLabelThreshold
        if (workspace === "editor") return metrics.editorLabelThreshold
        return metrics.browserLabelThreshold
    }

    /// Progressive 4-tier toolbar compaction per workspace:
    ///   width ≥ labelThreshold  ⇒ "full"      (switcher text + all icons)
    ///   width ≥ compactRow      ⇒ "compact"   (3 switcher icons + all icons)
    ///   width ≥ collapsedRow    ⇒ "collapsed" (1 switcher dropdown + all icons)
    ///   anything narrower       ⇒ "mini"      (1 switcher dropdown + folded `⋯` + hide image counter)
    function modeFor(workspace, width) {
        var collapsed = metrics.collapsedRowFor(workspace)
        var compact = metrics.compactRowFor(workspace)
        var labelled = metrics.labelThresholdFor(workspace)
        if (width >= labelled) return "full"
        if (width >= compact) return "compact"
        if (width >= collapsed) return "collapsed"
        return "mini"
    }

    /// True once the Viewer's `1 / N` image counter must hide (after the
    /// switcher collapses to 1 dropdown, before folding toolbar buttons).
    function viewerHideCounterFor(windowWidth) {
        return windowWidth < metrics.viewerCollapsedRowWidth
    }

    /// How many trailing Viewer toolbar controls must fold one-by-one into `⋯`
    /// at `windowWidth`:
    ///   0  ⇒ all controls fit (counter may be hidden)
    ///   1  ⇒ Canvas background swatch folded
    ///   2  ⇒ + Viewer mode & layout folded
    ///   3  ⇒ + Info & color folded
    ///   4  ⇒ + Filmstrip folded
    ///   5  ⇒ + Fullscreen folded (also drops separator 3)
    ///   6  ⇒ + Flip vertical folded
    ///   7  ⇒ + Flip horizontal folded
    ///   8  ⇒ + Rotate right folded
    ///   9  ⇒ + Rotate left folded (also drops separator 2)
    ///   10 ⇒ + Actual size 100% folded
    ///   11 ⇒ + Zoom in folded
    ///   12 ⇒ + Zoom out folded (also drops separator 1; leaves Prev, Next, Fit, ⋯)
    function viewerFoldCountFor(windowWidth) {
        if (windowWidth >= metrics.viewerNoCounterRowWidth) return 0
        var avail = Math.max(0, windowWidth
                                - metrics.switcherCollapsedWidth
                                - metrics.separatorWidth
                                - metrics.busyIndicatorWidth
                                - metrics.menuButtonWidth
                                - metrics.rowGaps)
        var slot = metrics.buttonWidth + metrics.buttonSpacing
        var sepSlot = metrics.separatorWidth + metrics.buttonSpacing
        // Showing `⋯` costs one button slot; start with all controls + `⋯`.
        var needed = metrics.viewerNoCounterToolbarWidth + slot
        var widths = [
            metrics.viewerBgSwatchWidth, // 1: Canvas background
            slot,                        // 2: Viewer mode & layout
            slot,                        // 3: Info & color
            slot,                        // 4: Filmstrip
            slot + sepSlot,              // 5: Fullscreen + sep 3
            slot,                        // 6: Reset view
            slot,                        // 7: Flip vertical
            slot,                        // 8: Flip horizontal
            slot,                        // 9: Rotate right
            slot + sepSlot,              // 10: Rotate left + sep 2
            slot,                        // 11: Actual size 100%
            slot,                        // 12: Zoom in
            slot + sepSlot               // 13: Zoom out + sep 1
        ]
        var folded = 0
        for (var i = 0; i < widths.length; ++i) {
            needed -= widths[i]
            folded = i + 1
            if (needed <= avail) break
        }
        return folded
    }

    /// The window floor: the widest folded row *and* room left for a sidebar and
    /// a picture. The window must never be so narrow that a control is cut off;
    /// it *may* be narrower than the icon row and the labelled row — that is
    /// what the overflow menu and the dropped labels are for.
    readonly property real minimumWindowWidth:
        Math.ceil(Math.max(metrics.miniToolbarWidth,
                           metrics.sidePanelWidth + metrics.pictureWidth))

}
