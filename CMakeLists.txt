cmake_minimum_required(VERSION 3.24)

project(KogaView VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Single canonical artifact location for `just run` and `just doctor`.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2)

find_package(CxxQt 0.10 QUIET)
if(NOT CxxQt_FOUND)
  include(FetchContent)
  FetchContent_Declare(
    CxxQt
    GIT_REPOSITORY https://github.com/kdab/cxx-qt-cmake.git
    GIT_TAG 0.10.0
    GIT_SHALLOW TRUE
  )
  FetchContent_MakeAvailable(CxxQt)
endif()

cxx_qt_import_crate(
  MANIFEST_PATH "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
  CRATES kogaview_desktop
  LOCKED
  QT_MODULES Qt::Core Qt::Gui Qt::Qml Qt::Quick
)

cxx_qt_import_qml_module(
  kogaview_qml_module
  URI "io.github.huynhat.KogaView"
  SOURCE_CRATE kogaview_desktop
)

add_executable(kogaview cpp/main.cpp)
target_link_libraries(kogaview PRIVATE kogaview_qml_module)

set_target_properties(
  kogaview
  PROPERTIES
    OUTPUT_NAME kogaview
    WIN32_EXECUTABLE TRUE
    MACOSX_BUNDLE FALSE
)

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  # M0-only window-grab evidence harness, never part of a release build.
  target_compile_definitions(kogaview PRIVATE KOGAVIEW_DEV_HARNESS)
endif()

message(STATUS "KogaView app ID: io.github.huynhat.KogaView.Dev (debug) / io.github.huynhat.KogaView (release)")
message(STATUS "KogaView runtime artifact: ${CMAKE_BINARY_DIR}/bin/kogaview")
