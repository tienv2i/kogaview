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
          ../crates/desktop/qml/EditorView.qml \
          ../crates/desktop/qml/UnitField.qml \
          ../crates/desktop/qml/SettingsDialog.qml \
          ../crates/desktop/qml/ResizeDialog.qml \
          ../crates/desktop/qml/InfoPanel.qml \
          ../crates/desktop/qml/PreviewPanel.qml \
          ../crates/desktop/qml/HistoryPanel.qml \
          ../crates/desktop/qml/BatchPanel.qml \
          ../crates/desktop/qml/RightDock.qml \
          ../crates/desktop/qml/WorkspaceSwitcher.qml \
          ../crates/desktop/qml/UiLines.qml \
          ../crates/desktop/qml/ToolbarMetrics.qml \
          ../crates/desktop/qml/MenuShortcut.qml \
          ../crates/desktop/qml/Theme.qml
TRANSLATIONS = kogaview_vi.ts
