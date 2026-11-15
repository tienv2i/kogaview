use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(QmlModule::new("io.github.tienv2i.KogaView").qml_files([
        "qml/Main.qml",
        "qml/Icon.qml",
        "qml/ToolbarButton.qml",
        "qml/ToolbarSeparator.qml",
        "qml/Theme.qml",
        "qml/BrowserView.qml",
        "qml/Viewer.qml",
        "qml/EditorView.qml",
    ]))
    .qt_module("Core")
    .qt_module("Gui")
    .qt_module("Qml")
    .qt_module("Quick")
    .qt_module("QuickControls2")
    .files(["src/bridge.rs"])
    .build();
}
