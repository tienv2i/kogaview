use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(
        QmlModule::new("io.github.huynhat.KogaView").qml_file("qml/Main.qml"),
    )
    .qt_module("Core")
    .qt_module("Gui")
    .qt_module("Qml")
    .qt_module("Quick")
    .files(["src/bridge.rs"])
    .build();
}
