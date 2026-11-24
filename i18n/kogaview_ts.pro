# Qt Linguist project file. It names the QML sources so `lupdate` can refresh
# `kogaview_vi.ts` without a full Qt project build:
#
#   lupdate i18n/kogaview_ts.pro
#
# `just build` then runs `lrelease` on the result and compiles the `.qm` into
# the binary under `:/i18n/` (see the top-level `CMakeLists.txt`).
TEMPLATE = app
LANGUAGE = C++
# Every QML file that draws a translated string must be listed. `UiLines.qml`
# carries the sentence for each line Core publishes and `ToolbarMetrics.qml`
# measures the labels with `qsTranslate`, so leaving either out makes the next
# `lupdate` mark its strings `vanished` — and `lrelease` drops those silently,
# which is a Vietnamese window with English status lines. `just test` fails a
# QML file with `qsTr` that this list does not name.
SOURCES = ../crates/desktop/qml/Main.qml \
          ../crates/desktop/qml/BrowserView.qml \
          ../crates/desktop/qml/Viewer.qml \
          ../crates/desktop/qml/ViewerModePopup.qml \
          ../crates/desktop/qml/ViewerColorPopover.qml \
          ../crates/desktop/qml/ViewerCompactHud.qml \
          ../crates/desktop/qml/ViewerDualSpread.qml \
          ../crates/desktop/qml/ViewerWebtoonView.qml \
          ../crates/desktop/qml/EditorView.qml \
          ../crates/desktop/qml/EditorResizePanel.qml \
          ../crates/desktop/qml/EditorCanvasSizePanel.qml \
          ../crates/desktop/qml/ColorAdjustPanel.qml \
          ../crates/desktop/qml/UnitField.qml \
          ../crates/desktop/qml/DimensionRatioGrid.qml \
          ../crates/desktop/qml/SettingsDialog.qml \
          ../crates/desktop/qml/ResizeDialog.qml \
          ../crates/desktop/qml/CanvasSizeDialog.qml \
          ../crates/desktop/qml/ColorPickerDialog.qml \
          ../crates/desktop/qml/BatchJobDialog.qml \
          ../crates/desktop/qml/BatchResizeDialog.qml \
          ../crates/desktop/qml/BatchCropDialog.qml \
          ../crates/desktop/qml/BatchConvertDialog.qml \
          ../crates/desktop/qml/InfoPanel.qml \
          ../crates/desktop/qml/PreviewPanel.qml \
          ../crates/desktop/qml/HistoryPanel.qml \
          ../crates/desktop/qml/BatchPanel.qml \
          ../crates/desktop/qml/QuickAccessPanel.qml \
          ../crates/desktop/qml/ExplorerPanel.qml \
          ../crates/desktop/qml/LeftDock.qml \
          ../crates/desktop/qml/FolderMenu.qml \
          ../crates/desktop/qml/RightDock.qml \
          ../crates/desktop/qml/SidePanelRail.qml \
          ../crates/desktop/qml/WorkspaceSwitcher.qml \
          ../crates/desktop/qml/UiLines.qml \
          ../crates/desktop/qml/ToolbarMetrics.qml \
          ../crates/desktop/qml/MenuShortcut.qml \
          ../crates/desktop/qml/DialogFrame.qml \
          ../crates/desktop/qml/DialogFooter.qml \
          ../crates/desktop/qml/FormRow.qml \
          ../crates/desktop/qml/FormSection.qml \
          ../crates/desktop/qml/FormCheck.qml \
          ../crates/desktop/qml/FormRadio.qml \
          ../crates/desktop/qml/ColourPair.qml \
          ../crates/desktop/qml/BackgroundPopup.qml \
          ../crates/desktop/qml/Theme.qml
TRANSLATIONS = kogaview_vi.ts
