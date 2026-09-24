#[[============================================================================
  SioyekWarnings.cmake
  ---------------------------------------------------------------------------
  Warning policy contract (third-party isolation + compiler detection)

  Background:
    The project embeds several third-party libraries whose code produces many
    warnings, drowning out the signal from the project's own code. Also, some
    compiler-specific warning flags were appended unconditionally (GCC reports
    "unrecognized command-line option").

  Embedded third-party components (explicitly listed):
    - utf8cpp        : pdf_viewer/utf8.h, pdf_viewer/utf8/{checked,core,unchecked}.h
    - rapidfuzz      : pdf_viewer/rapidfuzz_amalgamated.hpp
    - fts_fuzzy_match: pdf_viewer/fts_fuzzy_match.h
    - sqlite3        : pdf_viewer/sqlite3.{c,h}, pdf_viewer/sqlite3ext.h, pdf_viewer/shell.c
    - synctex        : pdf_viewer/synctex/*
    - fzf            : fzf/fzf.{c,h}

  Measures:
    (1) Compiler detection: compiler-specific flags are probed before being added
        (fixes the GCC "unrecognized option" noise).
    (2) Third-party source downgrade: sqlite3.c / shell.c / synctex/*.c / fzf
        translation units use -w.
    (3) Qt generated unit downgrade: mocs_compilation.cpp / qrc_*.cpp use -w.
    (4) SIOYEK_STRICT_NON_THIRD_PARTY_WARN: enables -Wall -Wextra for the
        project's own translation units (AUTO/ON/OFF). AUTO enables them for
        Debug-like build types. This is off for release builds by default so a
        distro's own CFLAGS/CXXFLAGS keep full control.
    (5) SIOYEK_WERROR_RETURN_TYPE: promotes -Wreturn-type to an error
        (-Werror=return-type). This catches a class of real undefined behaviour
        (a non-void function falling off its end without returning), which is
        exactly the defect surfaced by GCC 15 in config.cpp:1577. Enabled by
        the Debug presets (AUTO mode).

  Honest note:
    The utf8cpp headers are included via quoted #include "utf8/..." resolved from
    pdf_viewer/, and they are included by the project's own utils.h. GCC/Clang
    system-header suppression does not apply to headers pulled in with quotes from
    a project header, so the utf8cpp warnings cannot be silenced by CMake options
    alone without modifying functional code (include paths).
============================================================================]]#

include_guard(GLOBAL)
include(CheckCXXCompilerFlag)

# Tri-state: AUTO (enable for Debug-like builds), ON (always), OFF (never).
set(SIOYEK_STRICT_NON_THIRD_PARTY_WARN "AUTO" CACHE STRING
    "Enable -Wall -Wextra for sioyek's own translation units (AUTO/ON/OFF).")
set_property(CACHE SIOYEK_STRICT_NON_THIRD_PARTY_WARN PROPERTY STRINGS AUTO ON OFF)

# Promote -Wreturn-type to an error. Non-void functions that fall off the end
# are undefined behaviour; this turns the warning into a hard failure.
# Tri-state as well: AUTO enables it whenever the strict warnings above are on.
set(SIOYEK_WERROR_RETURN_TYPE "AUTO" CACHE STRING
    "Treat -Wreturn-type as an error (-Werror=return-type) (AUTO/ON/OFF).")
set_property(CACHE SIOYEK_WERROR_RETURN_TYPE PROPERTY STRINGS AUTO ON OFF)

# Resolve AUTO for both options from the build type.
set(_sioyek_warn_default OFF)
if(CMAKE_BUILD_TYPE MATCHES "Debug")
    set(_sioyek_warn_default ON)
endif()

if(SIOYEK_STRICT_NON_THIRD_PARTY_WARN STREQUAL "AUTO")
    set(_sioyek_strict_warn "${_sioyek_warn_default}")
elseif(SIOYEK_STRICT_NON_THIRD_PARTY_WARN)
    set(_sioyek_strict_warn ON)
else()
    set(_sioyek_strict_warn OFF)
endif()

if(SIOYEK_WERROR_RETURN_TYPE STREQUAL "AUTO")
    set(_sioyek_werror_return_type "${_sioyek_strict_warn}")
elseif(SIOYEK_WERROR_RETURN_TYPE)
    set(_sioyek_werror_return_type ON)
else()
    set(_sioyek_werror_return_type OFF)
endif()

# Compiler-specific flag: probe before adding
function(_sioyek_add_flag_if_supported target flag)
    string(MAKE_C_IDENTIFIER "SIOYEK_HAVE_${flag}" _var)
    if(NOT DEFINED ${_var})
        check_cxx_compiler_flag("${flag}" ${_var})
    endif()
    if(${${_var}})
        target_compile_options(${target} PRIVATE "${flag}")
    endif()
endfunction()

# (1) Warning settings for the project's own code
function(sioyek_apply_self_warnings target)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
        # clang-only: suppress override mismatch warnings from Qt moc output
        _sioyek_add_flag_if_supported(${target} -Wno-inconsistent-missing-override)
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        # GCC has no such flag; appending it unconditionally produces
        # "unrecognized command-line option" noise.
    endif()

    if(_sioyek_strict_warn AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
        _sioyek_add_flag_if_supported(${target} -Wall)
        _sioyek_add_flag_if_supported(${target} -Wextra)
    endif()

    if(_sioyek_werror_return_type AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
        _sioyek_add_flag_if_supported(${target} -Werror=return-type)
        message(STATUS "sioyek: -Wreturn-type promoted to error for the project's own code")
    endif()
endfunction()

# (2) Downgrade third-party translation units
function(sioyek_downgrade_third_party_sources target)
    set(_tp_sources
        "pdf_viewer/sqlite3.c"
        "pdf_viewer/shell.c"
        "pdf_viewer/synctex/synctex_parser.c"
        "pdf_viewer/synctex/synctex_parser_utils.c"
    )
    foreach(_src IN LISTS _tp_sources)
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_src}")
            set_source_files_properties("${_src}" TARGET_DIRECTORY ${target}
                PROPERTIES COMPILE_OPTIONS "-w")
        endif()
    endforeach()
    if(TARGET fzf)
        target_compile_options(fzf PRIVATE -w)
    endif()
endfunction()

# (3) Downgrade Qt generated units
function(sioyek_downgrade_autogen target)
    set(_gen_files
        "${CMAKE_CURRENT_BINARY_DIR}/${target}_autogen/mocs_compilation.cpp")
    file(GLOB _qrc_files "${CMAKE_CURRENT_BINARY_DIR}/${target}_autogen/*/qrc_*.cpp")
    list(APPEND _gen_files ${_qrc_files})
    foreach(_f IN LISTS _gen_files)
        if(EXISTS "${_f}")
            set_source_files_properties("${_f}" TARGET_DIRECTORY ${target}
                PROPERTIES COMPILE_OPTIONS "-w")
        endif()
    endforeach()
endfunction()
