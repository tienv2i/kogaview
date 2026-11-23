cmake_minimum_required(VERSION 3.24)

project(KogaView VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Single canonical artifact location for `just run` and `just doctor`.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 DBus Concurrent)

# Translations are compiled into the binary, not read from the host: the `.ts`
# sources live in `i18n/` and `lrelease` turns them into `.qm` files that are
# registered in the resource system as `:/i18n/`. A sandboxed Flatpak then needs
# nothing from outside. `lrelease` ships with Qt's tools package, which not every
# distribution installs with Qt itself, so it is located by a script that also
# knows about a bundled PySide6 (`scripts/find_lrelease.py`); the build runs
# untranslated when it is missing, it does not fail.
set(KOGAVIEW_LRELEASE "" CACHE FILEPATH "Path to Qt's lrelease (empty: search for it)")
# `scripts/dev.py` exports the tool it found; use it as the seed value the
# first time this build directory is configured.
if(NOT KOGAVIEW_LRELEASE AND DEFINED ENV{KOGAVIEW_LRELEASE}
   AND EXISTS "$ENV{KOGAVIEW_LRELEASE}")
  set(KOGAVIEW_LRELEASE "$ENV{KOGAVIEW_LRELEASE}" CACHE FILEPATH
      "Path to Qt's lrelease" FORCE)
endif()
# A cached path can outlive the file: this machine once had the cache pointing
# into a `/tmp` copy that was cleaned, and every build then failed with "No rule
# to make target '…/lrelease'". A dead path is not a decision, so search again.
if(KOGAVIEW_LRELEASE AND NOT EXISTS "${KOGAVIEW_LRELEASE}")
  message(STATUS "KogaView: cached lrelease is gone (${KOGAVIEW_LRELEASE}); searching again")
  set(KOGAVIEW_LRELEASE "" CACHE FILEPATH "Path to Qt's lrelease (empty: search for it)" FORCE)
endif()
if(NOT KOGAVIEW_LRELEASE)
  find_package(Python3 COMPONENTS Interpreter QUIET)
  if(Python3_Interpreter_FOUND)
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/find_lrelease.py"
      OUTPUT_VARIABLE _found_lrelease OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_found_lrelease)
      set(KOGAVIEW_LRELEASE "${_found_lrelease}" CACHE FILEPATH "Path to Qt's lrelease" FORCE)
    endif()
  endif()
endif()

set(KOGAVIEW_QM_FILES "")
set(KOGAVIEW_TRANSLATIONS vi)
if(KOGAVIEW_LRELEASE)
  foreach(language IN LISTS KOGAVIEW_TRANSLATIONS)
    set(_ts "${CMAKE_CURRENT_SOURCE_DIR}/i18n/kogaview_${language}.ts")
    set(_qm "${CMAKE_CURRENT_BINARY_DIR}/i18n/kogaview_${language}.qm")
    add_custom_command(
      OUTPUT "${_qm}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/i18n"
      COMMAND "${KOGAVIEW_LRELEASE}" -silent "${_ts}" -qm "${_qm}"
      DEPENDS "${_ts}" "${KOGAVIEW_LRELEASE}"
      COMMENT "lrelease ${language}")
    list(APPEND KOGAVIEW_QM_FILES "${_qm}")
  endforeach()
else()
  message(STATUS "KogaView: lrelease not found; building without translations "
                 "(set KOGAVIEW_LRELEASE or install qt6-tools)")
endif()

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

add_executable(kogaview cpp/main.cpp cpp/language.cpp cpp/platform.cpp cpp/thumbnailcache.cpp
                         cpp/translations.cpp
                         ${KOGAVIEW_QM_FILES})
target_link_libraries(kogaview PRIVATE kogaview_qml_module Qt6::DBus Qt6::Concurrent)

# AVIF decoding is the Rust `image` crate's `avif-native` feature, which calls
# the system libdav1d (ADR 0005 revision). The staticlib records that need, but
# the C++ link line must name the shared library too or every `dav1d_*` symbol is
# undefined. The Rust side already needs `pkg-config` for the same library, so
# this adds no new build requirement.
find_package(PkgConfig REQUIRED)
pkg_check_modules(DAV1D REQUIRED IMPORTED_TARGET dav1d)
target_link_libraries(kogaview PRIVATE PkgConfig::DAV1D)

# `.qm` files through a generated index, onto a resource prefix of their own.
# Qt 6's `rcc` refuses a bare `.qm` as its file argument (it parses whatever it
# is handed as a `.qrc`), so the index names each file with its resource alias,
# and `rcc --binary` turns it into an `.rcc` the shell registers by hand
# (`cpp/language.cpp`). The binary format is what makes the path independent of
# the QML module's `/qt/qml` tree, which would otherwise own any resource under
# it.
if(KOGAVIEW_QM_FILES)
  get_target_property(_qt_qmake_executable Qt6::qmake IMPORTED_LOCATION)
  get_filename_component(_qt_bin_dir "${_qt_qmake_executable}" DIRECTORY)
  find_program(KOGAVIEW_RCC rcc HINTS "${_qt_bin_dir}" NO_DEFAULT_PATH)
  if(NOT KOGAVIEW_RCC)
    find_program(KOGAVIEW_RCC rcc)
  endif()
  set(KOGAVIEW_TRANSLATIONS_RCC "${CMAKE_CURRENT_BINARY_DIR}/i18n/kogaview_translations.rcc")
  set(KOGAVIEW_QM_QRC "${CMAKE_CURRENT_BINARY_DIR}/i18n/kogaview_translations.qrc")
  set(_qrc_entries "")
  foreach(qm IN LISTS KOGAVIEW_QM_FILES)
    get_filename_component(qm_name "${qm}" NAME)
    string(APPEND _qrc_entries "    <file alias=\"${qm_name}\">${qm}</file>\n")
  endforeach()
  # A bracket argument keeps the newlines real: `file(WRITE)` writes a quoted
  # `\n` as the two characters, and `rcc` then refuses the index.
  file(WRITE "${KOGAVIEW_QM_QRC}"
       [=[<?xml version="1.0" encoding="UTF-8"?>
<RCC>
  <qresource prefix="/i18n">
]=])
  file(APPEND "${KOGAVIEW_QM_QRC}" "${_qrc_entries}")
  file(APPEND "${KOGAVIEW_QM_QRC}"
       [=[
  </qresource>
</RCC>
]=])
  add_custom_command(
    OUTPUT "${KOGAVIEW_TRANSLATIONS_RCC}"
    COMMAND "${KOGAVIEW_RCC}" --binary --name kogaview_translations
            --output "${KOGAVIEW_TRANSLATIONS_RCC}" "${KOGAVIEW_QM_QRC}"
    DEPENDS "${KOGAVIEW_QM_QRC}" ${KOGAVIEW_QM_FILES} "${KOGAVIEW_RCC}"
    COMMENT "rcc translations")
  # A plain target, so CMake makes it and gives it a job that runs before the
  # link — a custom command that nothing was named on is never scheduled.
  add_custom_target(kogaview_translations DEPENDS "${KOGAVIEW_TRANSLATIONS_RCC}")
  add_dependencies(kogaview kogaview_translations)
endif()

set_target_properties(
  kogaview
  PROPERTIES
    OUTPUT_NAME kogaview
    WIN32_EXECUTABLE TRUE
    MACOSX_BUNDLE FALSE
)

# Where the compiled translations are, for `InterfaceLanguage` to register: a
# path is not a resource, so it is passed as a definition rather than guessed.
if(TARGET kogaview_translations)
  target_compile_definitions(kogaview PRIVATE
    KOGAVIEW_TRANSLATIONS_RCC="${KOGAVIEW_TRANSLATIONS_RCC}")
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Debug" OR KOGAVIEW_DEV_HARNESS)
  # M0-only window-grab evidence harness, never part of a release build. The
  # `KOGAVIEW_DEV_HARNESS` cache option exists so the `dev-prod` preset can build
  # an *optimized* binary with the hooks and the production identity, which is
  # what a development install needs; a plain Release build keeps it off.
  target_compile_definitions(kogaview PRIVATE KOGAVIEW_DEV_HARNESS)
  # The pan hook drives a real drag; a `DragHandler` needs the pointer sequence
  # `QTest` produces, which a hand-rolled `QMouseEvent` does not satisfy.
  find_package(Qt6 REQUIRED COMPONENTS Test)
  target_link_libraries(kogaview PRIVATE Qt6::Test)
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
    "kogaview_browser_qml_tests:tst_browser.cpp"
    "kogaview_batch_tests:tst_batchdialog.cpp"
    "kogaview_browser_cache_tests:tst_thumbnails.cpp"
    "kogaview_state_tests:tst_statesnapshot.cpp"
    "kogaview_settings_tests:tst_settings.cpp"
    "kogaview_dialogs_tests:tst_dialogs.cpp"
    "kogaview_editor_tests:tst_editor.cpp"
    "kogaview_language_tests:tst_language.cpp"
    "kogaview_toolbar_tests:tst_toolbar.cpp")

  foreach(suite IN LISTS KOGAVIEW_QML_TEST_SUITES)
    string(REPLACE ":" ";" parts "${suite}")
    list(GET parts 0 target)
    list(GET parts 1 source)
    set(suite_sources tests/qml/${source})
    # A suite may need non-QML sources from the app (the thumbnail cache is
    # exercised directly, without a QML scene).
    if(target STREQUAL "kogaview_browser_cache_tests")
      list(APPEND suite_sources cpp/thumbnailcache.cpp)
    endif()
    # The language suite drives the real translator installer, so it needs the
    # same compiled-in catalogue the application registers. The toolbar suite
    # does too: it asserts that the label threshold follows the interface
    # language, which is only true if the measurements read the real catalogue.
    set(suite_translations OFF)
    if(target STREQUAL "kogaview_language_tests" OR target STREQUAL "kogaview_toolbar_tests")
      list(APPEND suite_sources cpp/language.cpp)
      set(suite_translations ON)
    endif()
    # The thumbnail stub is a QObject both view suites drive; listing the header
    # is what lets AUTOMOC generate its meta-object into these targets.
    if(target STREQUAL "kogaview_qml_tests" OR target STREQUAL "kogaview_browser_qml_tests"
       OR target STREQUAL "kogaview_editor_tests")
      list(APPEND suite_sources tests/qml/stubthumbnailcache.h)
    endif()
    add_executable(${target} ${suite_sources})
    target_link_libraries(${target} PRIVATE Qt6::Quick Qt6::Test Qt6::GuiPrivate Qt6::Concurrent)
    target_compile_definitions(${target}
      PRIVATE KOGAVIEW_QML_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/crates/desktop/qml"
              KOGAVIEW_QML_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/qml")
    if(suite_translations)
      target_compile_definitions(${target} PRIVATE
        KOGAVIEW_TRANSLATIONS_RCC="${KOGAVIEW_TRANSLATIONS_RCC}")
      add_dependencies(${target} kogaview_translations)
    endif()
    target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/cpp")
  endforeach()
endif()

message(STATUS "KogaView app ID: io.github.tienv2i.KogaView.Dev (debug) / io.github.tienv2i.KogaView (release)")
message(STATUS "KogaView runtime artifact: ${CMAKE_BINARY_DIR}/bin/kogaview")
