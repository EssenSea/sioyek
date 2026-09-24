#[[============================================================================
  SioyekBuildTypes.cmake
  ---------------------------------------------------------------------------
  Build-type / optimization policy.

  Goals:
    * Make the optimization level and symbol handling explicit and consistent
      across build types (Release, RelWithDebInfo, Debug, MinSizeRel).
    * Allow self-contained distribution builds (portable / AppImage) to strip
      symbols by default, while keeping normal distro/CI builds unstripped.
    * Provide measurable compile-time optimizations that are *optional* so they
      never surprise downstream packagers:
        - SIOYEK_ENABLE_CCACHE  : use ccache if available (default AUTO)
        - SIOYEK_ENABLE_LTO     : enable interprocedural optimization (default ON for Release-like builds)
        - SIOYEK_UNITY_BUILD    : enable CMake unity build (default OFF)

  Options:
    SIOYEK_STRIP_ON_INSTALL   : strip installed binaries (default OFF)
    SIOYEK_PACKAGE_STRIP      : strip files placed into CPack packages (default OFF)

  Notes:
    - Stripping is opt-in; CI and distro packages normally keep symbols and let
      the packager strip separately.
    - The `linux-portable` preset enables stripping (self-contained build).
============================================================================]]#

include_guard(GLOBAL)

# ---------------------------------------------------------------------------
# Optimization flags per build type (only set if the user did not override).
# ---------------------------------------------------------------------------
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Build type" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
        Debug Release RelWithDebInfo MinSizeRel)
endif()

# ---------------------------------------------------------------------------
# Optimization level.
#   We deliberately prefer -O2 over CMake's default -O3 for Release: -O3 can
#   increase code size and compile time with marginal runtime gains for this
#   codebase. MinSizeRel uses -Os. Only applied to single-config generators
#   and only if the user has not overridden *_FLAGS_RELEASE.
# ---------------------------------------------------------------------------
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    set(_sioyek_release_flags "-O2 -DNDEBUG")
    set(CMAKE_C_FLAGS_RELEASE   "${_sioyek_release_flags}"   CACHE STRING "Release C flags"   FORCE)
    set(CMAKE_CXX_FLAGS_RELEASE "${_sioyek_release_flags}"   CACHE STRING "Release CXX flags" FORCE)
endif()

# ---------------------------------------------------------------------------
# Size-reduction helpers (opt-in, default ON for ELF targets):
#   -ffunction-sections -fdata-sections + --gc-sections : drop unused code/data
#   --as-needed (linker): only link libraries actually referenced
# These are safe, standard size optimizations and rarely change behavior.
# ---------------------------------------------------------------------------
option(SIOYEK_SIZE_OPTIMIZATIONS
    "Enable code-size optimizations (-ffunction-sections/-fdata-sections/--gc-sections/--as-needed)."
    ON)

# -fvisibility=hidden hides symbols not explicitly exported. It mainly benefits
# shared libraries / DLLs; for an executable the gain is small and it can
# interfere with RTTI/exception handling across TUs on some toolchains, so it is
# OFF by default and exposed as an opt-in.
option(SIOYEK_HIDDEN_VISIBILITY
    "Compile with -fvisibility=hidden (smaller symbol tables)."
    OFF)
if(SIOYEK_HIDDEN_VISIBILITY AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    add_compile_options(-fvisibility=hidden -fvisibility-inlines-hidden)
    message(STATUS "sioyek: hidden visibility enabled")
endif()

if(SIOYEK_SIZE_OPTIMIZATIONS AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    add_compile_options(-ffunction-sections -fdata-sections)
    if(APPLE)
        add_link_options(-Wl,-dead_strip)
    elseif(UNIX)
        add_link_options(-Wl,--gc-sections -Wl,--as-needed)
    endif()
    message(STATUS "sioyek: size optimizations enabled (function/data sections + gc-sections + as-needed)")
endif()

option(SIOYEK_STRIP_ON_INSTALL "Strip installed binaries." OFF)
option(SIOYEK_PACKAGE_STRIP    "Strip binaries inside CPack packages." OFF)

# ---------------------------------------------------------------------------
# ccache (compile-time speedup)
# ---------------------------------------------------------------------------
set(SIOYEK_ENABLE_CCACHE "AUTO" CACHE STRING
    "Use ccache if available (AUTO/ON/OFF).")
set_property(CACHE SIOYEK_ENABLE_CCACHE PROPERTY STRINGS AUTO ON OFF)

# Determination of the ccache cache directory. Honor an explicitly exported
# CCACHE_DIR (also used by ccache itself); otherwise defer to ccache. We only
# need it to probe writability here.
if(DEFINED ENV{CCACHE_DIR} AND NOT "$ENV{CCACHE_DIR}" STREQUAL "")
    set(_sioyek_ccache_dir "$ENV{CCACHE_DIR}")
elseif(DEFINED ENV{XDG_CACHE_HOME} AND NOT "$ENV{XDG_CACHE_HOME}" STREQUAL "")
    set(_sioyek_ccache_dir "$ENV{XDG_CACHE_HOME}/ccache")
else()
    set(_sioyek_ccache_dir "$ENV{HOME}/.cache/ccache")
endif()

# Probe that the cache directory is actually usable (exists or can be created,
# and is writable). A missing ccache cache dir is created on first use, so a
# non-existent parent is fine as long as we can create it. This catches the
# real-world case of a read-only mount, where ccache as a compiler launcher
# makes *every* compilation fail ("Read-only file system") and the build dies.
#
# IMPORTANT: use `cmake -E touch` via execute_process (whose failure is a normal
# non-zero RESULT_VARIABLE) instead of file(WRITE): file(WRITE) raises a hard
# CMake error on a read-only filesystem and cannot be caught.
function(_sioyek_dir_is_writable dir out_var)
    set(_probe "${dir}/.sioyek-write-probe")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E touch "${_probe}"
        RESULT_VARIABLE _rc
        OUTPUT_QUIET ERROR_QUIET)
    if(_rc EQUAL 0)
        file(REMOVE "${_probe}")
        set(${out_var} TRUE PARENT_SCOPE)
    else()
        set(${out_var} FALSE PARENT_SCOPE)
    endif()
endfunction()

set(_sioyek_ccache_usable TRUE)
if(EXISTS "${_sioyek_ccache_dir}")
    if(NOT IS_DIRECTORY "${_sioyek_ccache_dir}")
        set(_sioyek_ccache_usable FALSE)
        set(_sioyek_ccache_reason "'${_sioyek_ccache_dir}' exists but is not a directory")
    else()
        _sioyek_dir_is_writable("${_sioyek_ccache_dir}" _sioyek_ccache_writable)
        if(NOT _sioyek_ccache_writable)
            set(_sioyek_ccache_usable FALSE)
            set(_sioyek_ccache_reason "'${_sioyek_ccache_dir}' is not writable (read-only mount?)")
        endif()
    endif()
else()
    # Directory does not exist yet: verify the parent is writable so ccache can
    # create it. If the parent does not exist either, stay optimistic and let
    # ccache try (it will create intermediate dirs).
    get_filename_component(_sioyek_ccache_parent "${_sioyek_ccache_dir}" DIRECTORY)
    if(EXISTS "${_sioyek_ccache_parent}")
        _sioyek_dir_is_writable("${_sioyek_ccache_parent}" _sioyek_ccache_parent_writable)
        if(NOT _sioyek_ccache_parent_writable)
            set(_sioyek_ccache_usable FALSE)
            set(_sioyek_ccache_reason "parent '${_sioyek_ccache_parent}' is not writable")
        endif()
    endif()
endif()

if(NOT SIOYEK_ENABLE_CCACHE STREQUAL "OFF")
    find_program(SIOYEK_CCACHE_PROGRAM NAMES ccache sccache)
    if(SIOYEK_CCACHE_PROGRAM)
        if(_sioyek_ccache_usable)
            # Wrap via `cmake -E env` so the cache directory is pinned and users
            # retain an escape hatch (CCACHE_DISABLE=1). Harmless on sccache too
            # (it ignores CCACHE_* and uses SCCACHE_*), so we do not special-case.
            set(CMAKE_CXX_COMPILER_LAUNCHER "${CMAKE_COMMAND}" -E env "CCACHE_DIR=${_sioyek_ccache_dir}" "${SIOYEK_CCACHE_PROGRAM}")
            set(CMAKE_C_COMPILER_LAUNCHER   "${CMAKE_COMMAND}" -E env "CCACHE_DIR=${_sioyek_ccache_dir}" "${SIOYEK_CCACHE_PROGRAM}")
            message(STATUS "sioyek: using compiler launcher ${SIOYEK_CCACHE_PROGRAM} (cache=${_sioyek_ccache_dir})")
        else()
            # The launcher would break the build. ON means the user insists.
            if(SIOYEK_ENABLE_CCACHE STREQUAL "ON")
                message(FATAL_ERROR
                    "SIOYEK_ENABLE_CCACHE=ON but the ccache cache is unusable: "
                    "${_sioyek_ccache_reason}. Set CCACHE_DIR to a writable directory, "
                    "fix its permissions, or configure with -DSIOYEK_ENABLE_CCACHE=OFF.")
            endif()
            message(WARNING
                "sioyek: ccache found but its cache is unusable (${_sioyek_ccache_reason}); "
                "continuing WITHOUT the compiler launcher. To use ccache, point CCACHE_DIR "
                "at a writable directory (or run 'ccache -o cache_dir=<dir>').")
        endif()
    else()
        if(SIOYEK_ENABLE_CCACHE STREQUAL "ON")
            message(FATAL_ERROR "SIOYEK_ENABLE_CCACHE=ON but no ccache/sccache was found.")
        endif()
    endif()
endif()

# ---------------------------------------------------------------------------
# Link Time Optimization (off by default; can measurably speed up and shrink
# binaries, but increases link time and memory).
# ---------------------------------------------------------------------------
# LTO: enabled by default for Release-like builds (it shrinks the binary and
# can speed it up). Automatically skipped when the toolchain does not support
# it, and for Debug builds (where it only slows linking without benefit).
set(_sioyek_lto_default OFF)
if(CMAKE_BUILD_TYPE MATCHES "Release|MinSizeRel|RelWithDebInfo")
    set(_sioyek_lto_default ON)
endif()
option(SIOYEK_ENABLE_LTO "Enable interprocedural optimization (LTO)." ${_sioyek_lto_default})

if(SIOYEK_ENABLE_LTO AND NOT CMAKE_BUILD_TYPE MATCHES "Debug")
    include(CheckIPOSupported)
    check_ipo_supported(RESULT _sioyek_ipo_ok OUTPUT _sioyek_ipo_msg)
    if(_sioyek_ipo_ok)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
        message(STATUS "sioyek: LTO enabled")
    else()
        message(WARNING "sioyek: LTO requested but not supported: ${_sioyek_ipo_msg}")
    endif()
endif()

# ---------------------------------------------------------------------------
# Unity build (fewer translation units -> faster builds). Off by default as it
# can hide missing includes.
# ---------------------------------------------------------------------------
option(SIOYEK_UNITY_BUILD "Enable CMake unity build (faster compile)." OFF)
