use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(QmlModule::new("io.github.tienv2i.KogaView").qml_files([
        "qml/Main.qml",
        "qml/Icon.qml",
        "qml/ToolbarButton.qml",
        "qml/ToolRailButton.qml",
        "qml/UnitField.qml",
        "qml/CompactToolbarButton.qml",
        "qml/MenuShortcut.qml",
        "qml/ToolbarMetrics.qml",
        "qml/ToolbarSeparator.qml",
        "qml/WorkspaceSwitcher.qml",
        "qml/Theme.qml",
        "qml/Checkerboard.qml",
        "qml/ColourPair.qml",
        "qml/BackgroundPopup.qml",
        "qml/PanelSplitter.qml",
        "qml/PanelTabs.qml",
        "qml/PanelAction.qml",
        "qml/RightDock.qml",
        "qml/InfoPanel.qml",
        "qml/PreviewPanel.qml",
        "qml/HistoryPanel.qml",
        "qml/BatchPanel.qml",
        "qml/QuickAccessPanel.qml",
        "qml/ExplorerPanel.qml",
        "qml/LeftDock.qml",
        "qml/FolderMenu.qml",
        "qml/ThumbnailBook.qml",
        "qml/WheelScroll.qml",
        "qml/StateSnapshot.qml",
        "qml/UiLines.qml",
        "qml/CachedThumbnail.qml",
        "qml/BrowserView.qml",
        "qml/Viewer.qml",
        "qml/EditorView.qml",
        "qml/SettingsDialog.qml",
        "qml/ResizeDialog.qml",
        "qml/BatchJobDialog.qml",
        "qml/BatchResizeDialog.qml",
        "qml/BatchCropDialog.qml",
        "qml/BatchConvertDialog.qml",
    ]))
    // The Editor tool rail's own icons. They are not themed icons: Breeze
    // ships crop/brush/eraser drawings, Adwaita and Papirus do not, and an
    // icon-only rail with missing icons is a row of blank buttons.
    .qrc("icons.qrc")
    .qt_module("Core")
    .qt_module("Gui")
    .qt_module("Qml")
    .qt_module("Quick")
    .qt_module("QuickControls2")
    .files(["src/bridge.rs"])
    .build();
}
