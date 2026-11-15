cmake_minimum_required(VERSION 3.24)

project(KogaView VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Single canonical artifact location for `just run` and `just doctor`.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 DBus Concurrent)

find_package(CxxQt 0.10 QUIET)
if(NOT CxxQt_FOUND)
  include(FetchContent)
  # Skip the per-configure `git fetch` step: it fails intermittently in this
  # environment ("_ep_write_gitupdate_script: No such file or directory") and the
  # pinned sources do not change between builds.
  set(FETCHCONTENT_UPDATES_DISCONNECTED ON CACHE BOOL "" FORCE)
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
  QT_MODULES Qt::Core Qt::Gui Qt::Qml Qt::Quick Qt::QuickControls2
)

cxx_qt_import_qml_module(
  kogaview_qml_module
  URI "io.github.tienv2i.KogaView"
  SOURCE_CRATE kogaview_desktop
)

add_executable(kogaview cpp/main.cpp cpp/platform.cpp)
target_link_libraries(kogaview PRIVATE kogaview_qml_module Qt6::DBus Qt6::Concurrent)

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

# QML regression tests: load the real `.qml` sources and assert on what Qt Quick
# actually does (viewer transforms, explorer commands). Built for `just test`;
# never installed or packaged.
option(KOGAVIEW_BUILD_TESTS "Build the Qt Quick regression tests" ON)
if(KOGAVIEW_BUILD_TESTS)
  find_package(Qt6 REQUIRED COMPONENTS Test GuiPrivate)

  # Suite sources are paired with the target that runs them.
  set(KOGAVIEW_QML_TEST_SUITES
    "kogaview_qml_tests:tst_viewer.cpp"
    "kogaview_browser_qml_tests:tst_browser.cpp")

  foreach(suite IN LISTS KOGAVIEW_QML_TEST_SUITES)
    string(REPLACE ":" ";" parts "${suite}")
    list(GET parts 0 target)
    list(GET parts 1 source)
    add_executable(${target} tests/qml/${source})
    target_link_libraries(${target} PRIVATE Qt6::Quick Qt6::Test Qt6::GuiPrivate)
    target_compile_definitions(${target}
      PRIVATE KOGAVIEW_QML_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/crates/desktop/qml")
  endforeach()
endif()

message(STATUS "KogaView app ID: io.github.tienv2i.KogaView.Dev (debug) / io.github.tienv2i.KogaView (release)")
message(STATUS "KogaView runtime artifact: ${CMAKE_BINARY_DIR}/bin/kogaview")
