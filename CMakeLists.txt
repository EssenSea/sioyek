cmake_minimum_required(VERSION 3.16)
# Note on versioning (kept intentionally in sync with the presets):
#   * 3.16 is the hard minimum for building directly with `cmake -S . -B <dir>`.
#   * CMakePresets.json declares `cmakeMinimumRequired` 3.25 because preset
#     schema version 6 was adopted for the `${presetName}`/inheritance features
#     used by the presets. Using the presets therefore requires CMake >= 3.25,
#     while a direct (preset-less) configure still works with 3.16.
#   * This mirrors neovim: a low CMakeLists minimum + presets as a convenience
#     layer. See cmake/README.md ("Requirements").
cmake_policy(VERSION 3.16)
project(sioyek VERSION 2.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# Build-type / optimization / strip policy (ccache, LTO, unity build, strip).
include(SioyekBuildTypes)

# CTest contract regression tests: registered early, independent of any dependency
# probe result, so that even with missing vendored sources (configuration fails later)
# the contract tests can still run via -DSIOYEK_ENABLE_TESTS=ON.
include(SioyekTesting)

# Unified, robust dependency resolution (config -> module -> pkg-config)
include(SioyekDependencies)

# mupdf dependency consumption contract (provides the unified target `mupdf` and options)
include(SioyekMupdf)
include(SioyekSQLite)
include(SioyekWarnings)

# Qt Stuff
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Qt6 only; 6.5 is the hard minimum (code uses QT_VERSION_CHECK(6,5,0)),
# the upstream development branch recommends 6.7/6.8.
find_package(Qt6 6.5 REQUIRED COMPONENTS
      Core Gui Widgets Network OpenGL QuickWidgets
      Svg TextToSpeech OpenGLWidgets
)
if(Qt6_VERSION VERSION_LESS 6.7)
  message(STATUS "sioyek: detected Qt ${Qt6_VERSION}. The upstream development branch recommends Qt 6.7 or 6.8.")
endif()

if(APPLE AND TARGET WrapOpenGL::WrapOpenGL)
  set_property(TARGET WrapOpenGL::WrapOpenGL PROPERTY INTERFACE_LINK_LIBRARIES "-framework OpenGL")
endif()

qt_standard_project_setup()

qt_add_executable(sioyek WIN32 MACOSX_BUNDLE
    resources.qrc
    pdf_viewer/OpenWithApplication.cpp pdf_viewer/OpenWithApplication.h
    pdf_viewer/RunGuard.cpp pdf_viewer/RunGuard.h
    pdf_viewer/book.cpp pdf_viewer/book.h
    pdf_viewer/checksum.cpp pdf_viewer/checksum.h
    pdf_viewer/config.cpp pdf_viewer/config.h
    pdf_viewer/coordinates.cpp pdf_viewer/coordinates.h
    pdf_viewer/database.cpp pdf_viewer/database.h
    pdf_viewer/document.cpp pdf_viewer/document.h
    pdf_viewer/document_view.cpp pdf_viewer/document_view.h
    pdf_viewer/fts_fuzzy_match.h
    pdf_viewer/input.cpp pdf_viewer/input.h
    pdf_viewer/main.cpp
    pdf_viewer/main_widget.cpp pdf_viewer/main_widget.h
    pdf_viewer/mysortfilterproxymodel.cpp pdf_viewer/mysortfilterproxymodel.h
    pdf_viewer/new_file_checker.cpp pdf_viewer/new_file_checker.h
    pdf_viewer/path.cpp pdf_viewer/path.h
    pdf_viewer/pdf_renderer.cpp pdf_viewer/pdf_renderer.h
    pdf_viewer/pdf_view_opengl_widget.cpp pdf_viewer/pdf_view_opengl_widget.h
    pdf_viewer/rapidfuzz_amalgamated.hpp
    pdf_viewer/touchui/TouchAudioButtons.cpp pdf_viewer/touchui/TouchAudioButtons.h
    pdf_viewer/touchui/TouchCheckbox.cpp pdf_viewer/touchui/TouchCheckbox.h
    pdf_viewer/touchui/TouchConfigMenu.cpp pdf_viewer/touchui/TouchConfigMenu.h
    pdf_viewer/touchui/TouchCopyOptions.cpp pdf_viewer/touchui/TouchCopyOptions.h
    pdf_viewer/touchui/TouchDeleteButton.cpp pdf_viewer/touchui/TouchDeleteButton.h
    pdf_viewer/touchui/TouchDrawControls.cpp pdf_viewer/touchui/TouchDrawControls.h
    pdf_viewer/touchui/TouchGenericButtons.cpp pdf_viewer/touchui/TouchGenericButtons.h
    pdf_viewer/touchui/TouchHighlightButtons.cpp pdf_viewer/touchui/TouchHighlightButtons.h
    pdf_viewer/touchui/TouchListView.cpp pdf_viewer/touchui/TouchListView.h
    pdf_viewer/touchui/TouchMacroEditor.cpp pdf_viewer/touchui/TouchMacroEditor.h
    pdf_viewer/touchui/TouchMainMenu.cpp pdf_viewer/touchui/TouchMainMenu.h
    pdf_viewer/touchui/TouchMarkSelector.cpp pdf_viewer/touchui/TouchMarkSelector.h
    pdf_viewer/touchui/TouchPageSelector.cpp pdf_viewer/touchui/TouchPageSelector.h
    pdf_viewer/touchui/TouchRangeSelectUI.cpp pdf_viewer/touchui/TouchRangeSelectUI.h
    pdf_viewer/touchui/TouchRectangleSelectUI.cpp pdf_viewer/touchui/TouchRectangleSelectUI.h
    pdf_viewer/touchui/TouchSearchButtons.cpp pdf_viewer/touchui/TouchSearchButtons.h
    pdf_viewer/touchui/TouchSettings.cpp pdf_viewer/touchui/TouchSettings.h
    pdf_viewer/touchui/TouchSlider.cpp pdf_viewer/touchui/TouchSlider.h
    pdf_viewer/touchui/TouchTextEdit.cpp pdf_viewer/touchui/TouchTextEdit.h
    pdf_viewer/ui.cpp pdf_viewer/ui.h
    pdf_viewer/utf8.h
    pdf_viewer/utf8/checked.h
    pdf_viewer/utf8/core.h
    pdf_viewer/utf8/unchecked.h
    pdf_viewer/utils.cpp pdf_viewer/utils.h
)

if(APPLE)
    file(GLOB_RECURSE SIOYEK_SHADER_FILES CONFIGURE_DEPENDS
      "${CMAKE_CURRENT_SOURCE_DIR}/pdf_viewer/shaders/*"
    )

    target_sources(sioyek PRIVATE
      pdf_viewer/keys.config
      pdf_viewer/prefs.config
      ${SIOYEK_SHADER_FILES}
    )

    set_source_files_properties(
      pdf_viewer/keys.config
      pdf_viewer/prefs.config
        PROPERTIES MACOSX_PACKAGE_LOCATION "Resources"
    )

    set_source_files_properties(
      ${SIOYEK_SHADER_FILES}
        PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/shaders"
    )

  target_sources(sioyek PRIVATE
        pdf_viewer/macos_specific.mm
  )
endif()

# Warning policy: compiler-specific flag detection + third-party isolation (see cmake/SioyekWarnings.cmake)
sioyek_apply_self_warnings(sioyek)

# Optional unity build (fewer TUs -> faster builds; off by default).
if(SIOYEK_UNITY_BUILD)
  set_target_properties(sioyek PROPERTIES UNITY_BUILD ON)
  message(STATUS "sioyek: unity build enabled")
endif()

target_include_directories(sioyek PRIVATE
    pdf_viewer
)

target_compile_definitions(sioyek PRIVATE
    QT_OPENGLEXTENSIONS_LIB
    QT_OPENGL_LIB
    QT_WIDGETS_LIB
)

target_link_libraries(sioyek PRIVATE
    Qt::Core
    Qt::Gui
    Qt::Network
    Qt::OpenGL
    Qt::QuickWidgets
    Qt::Svg
    Qt::TextToSpeech
    Qt::Widgets
)

if(NOT ANDROID)
  target_sources(sioyek PUBLIC
        pdf_viewer/synctex/synctex_parser.c pdf_viewer/synctex/synctex_parser.h
        pdf_viewer/synctex/synctex_parser_utils.c pdf_viewer/synctex/synctex_parser_utils.h
  )
else()
  target_compile_definitions(sioyek PRIVATE
        SIOYEK_ANDROID
  )
endif()

if(WIN32)
  target_compile_definitions(sioyek PRIVATE
        _CRT_SECURE_NO_WARNINGS
        _CRT_NONSTDC_NO_DEPRECATE
        NOMINMAX
  )

  if(MSVC)
    target_compile_options(sioyek PRIVATE /bigobj /MP)
  endif()
endif()

if(UNIX AND NOT APPLE)
  target_compile_definitions(sioyek PRIVATE
        LINUX_STANDARD_PATHS
  )
endif()

# ZLIB is used to link the vendored mupdf static libs (the system branch gets it via pkg-config).
# Resolve it robustly (config/module/pkg-config) via the unified helper.
sioyek_find_dependency(
    NAME        ZLIB
    PKG_NAMES   zlib
    OUT_TARGET  SIOYEK_ZLIB_TARGET
    OUT_VERSION SIOYEK_ZLIB_VERSION
    REQUIRED)
# Normalize to ZLIB::ZLIB for downstream use (the helper may return a different name).
if(SIOYEK_ZLIB_TARGET AND NOT TARGET ZLIB::ZLIB)
    add_library(ZLIB::ZLIB INTERFACE IMPORTED GLOBAL)
    set_target_properties(ZLIB::ZLIB PROPERTIES INTERFACE_LINK_LIBRARIES "${SIOYEK_ZLIB_TARGET}")
endif()

# Qt6 only: always define SIOYEK_QT6 and link OpenGLWidgets
target_compile_definitions(sioyek PRIVATE
      SIOYEK_QT6
)
target_link_libraries(sioyek PRIVATE
      Qt::OpenGLWidgets
)

add_library(fzf STATIC
    fzf/fzf.c
    fzf/fzf.h
)

# Downgrade third-party sources (sqlite3.c/shell.c/synctex/fzf)
sioyek_downgrade_third_party_sources(sioyek)

# Downgrade Qt generated units (mocs_compilation.cpp / qrc_*.cpp)
sioyek_downgrade_autogen(sioyek)

target_link_libraries(sioyek PRIVATE
    ${CMAKE_DL_LIBS}
    mupdf            # mupdf consumption contract target (system or vendored)
    fzf
    sqlite_link      # SQLite consumption contract target (system or vendored)
)

if(APPLE)
  # mupdf linking is handled by the consumption contract target `mupdf` (no hardcoded -L/-l paths)
  target_link_libraries(sioyek PRIVATE
      "-framework AppKit"
  )
else()
  # Note: historically this used string(REPLACE ... CMAKE_CXX_FLAGS ...) to strip
  # -mno-direct-extern-access, but that option is actually supplied by Qt6's
  # INTERFACE_COMPILE_OPTIONS (a target property), not present in CMAKE_CXX_FLAGS,
  # so the replacement was dead code and has been removed.
  # Qt6 adds this option intentionally; it is harmless in the current environment.
endif()

# Install contract (must be included after the sioyek target is defined)
include(SioyekInstall)

# Qt runtime deployment (packs Qt libs/plugins into the install tree).
# Disable for distro packaging (downstream reuse) so the packager uses system Qt;
# enable for self-contained distribution (AppImage / portable bundle).
# Default: ON for Windows/macOS (self-contained), OFF elsewhere (delegated to downstream).
if(WIN32 OR APPLE)
  set(_sioyek_qt_deploy_default ON)
else()
  set(_sioyek_qt_deploy_default OFF)
endif()
option(SIOYEK_INSTALL_QT_DEPLOY
    "Deploy Qt runtime libraries/plugins into the install tree (disable for distro packaging)."
    ${_sioyek_qt_deploy_default})

if(SIOYEK_INSTALL_QT_DEPLOY)
  qt_generate_deploy_app_script(
      TARGET sioyek
      OUTPUT_SCRIPT deploy_script
      NO_UNSUPPORTED_PLATFORM_ERROR
  )
  install(SCRIPT ${deploy_script})
  message(STATUS "sioyek: Qt runtime deployment enabled (SIOYEK_INSTALL_QT_DEPLOY=ON)")
else()
  message(STATUS "sioyek: Qt runtime deployment disabled (downstream packager uses system Qt)")
endif()

# CPack packaging (reuses the install contract; must be at the end of the file to
# collect all variables defined above)
include(SioyekPackaging)

# Clean-up targets (clean-all / clean-packages / clean-stage / clean-in-source).
include(SioyekClean)
