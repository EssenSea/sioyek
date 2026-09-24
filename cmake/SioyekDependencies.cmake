#[[============================================================================
  SioyekDependencies.cmake
  ---------------------------------------------------------------------------
  Unified, robust dependency resolution helper.

  Rationale:
    Different Linux distributions ship dependencies in different forms:
      - a CMake config package (e.g. harfbuzz-config.cmake, Qt6Config.cmake),
      - a CMake Find module (e.g. FindHarfBuzz.cmake, FindZLIB.cmake),
      - only a pkg-config file (e.g. Ubuntu's harfbuzz.pc).
    A find_package() that only understands one form fails on some distros.

  This module provides a single helper that tries, in order:
    (1) find_package(<Name> [version] QUIET)              -- config or module
    (2) pkg-config via pkg_check_modules(<Name>)           -- last resort
  and returns a normalized INTERFACE target plus the resolved version.

  Usage:
    sioyek_find_dependency(
        NAME        HarfBuzz
        PKG_NAMES   harfbuzz
        OUT_TARGET  <var>
        OUT_VERSION <var>
        [VERSION    x.y.z]
        [REQUIRED]
        [EXTRA_TARGETS t1 t2 ...]      # additionally accept these imported targets
    )
============================================================================]]#

include_guard(GLOBAL)
include(CMakeParseArguments)
find_package(PkgConfig QUIET)

# sioyek_find_dependency(
#     NAME <Name> PKG_NAMES <p1;p2;...>
#     [VERSION <v>] [REQUIRED]
#     OUT_TARGET <var> OUT_VERSION <var>
#     [EXTRA_TARGETS <t1;t2;...>]
# )
function(sioyek_find_dependency)
    set(_opts REQUIRED)
    set(_one  NAME VERSION OUT_TARGET OUT_VERSION)
    set(_multi PKG_NAMES EXTRA_TARGETS)
    cmake_parse_arguments(SFD "${_opts}" "${_one}" "${_multi}" ${ARGN})

    if(NOT SFD_NAME)
        message(FATAL_ERROR "sioyek_find_dependency: NAME is required")
    endif()

    # ---- (1) find_package (config or module) ----
    set(_found FALSE)
    set(_target "")
    set(_version "")

    if(SFD_VERSION)
        find_package(${SFD_NAME} ${SFD_VERSION} QUIET)
    else()
        find_package(${SFD_NAME} QUIET)
    endif()

    # Try a set of well-known imported target names (config packages differ in
    # capitalization; e.g. HarfBuzz config provides "harfbuzz::harfbuzz").
    string(TOLOWER "${SFD_NAME}" _name_lc)
    set(_candidate_targets
        "${SFD_NAME}::${SFD_NAME}"
        "${_name_lc}::${_name_lc}"
        "${SFD_NAME}::${SFD_NAME}Lib"
        "${_name_lc}::${_name_lc}Lib"
        "${SFD_NAME}"
        "${_name_lc}"
    )
    if(SFD_EXTRA_TARGETS)
        list(APPEND _candidate_targets ${SFD_EXTRA_TARGETS})
    endif()
    foreach(_t IN LISTS _candidate_targets)
        if(NOT _found AND TARGET ${_t})
            set(_found TRUE)
            set(_target "${_t}")
        endif()
    endforeach()

    # Some Find modules only define <NAME>_FOUND / <NAME>_LIBRARIES.
    # Derive a properly-namespaced target for the common ZLIB case.
    if(NOT _found AND TARGET ZLIB::ZLIB AND SFD_NAME STREQUAL "ZLIB")
        set(_found TRUE)
        set(_target "ZLIB::ZLIB")
    endif()

    if(NOT _found)
        string(TOUPPER "${SFD_NAME}" _UPPER)
        if(${_UPPER}_FOUND)
            set(_version "${${_UPPER}_VERSION}")
            # Build an INTERFACE target from the module variables if possible.
            set(_mod_libs "${${_UPPER}_LIBRARIES}")
            set(_mod_incs "${${_UPPER}_INCLUDE_DIRS}")
            if(_mod_libs)
                if(NOT TARGET sioyek_dep_${SFD_NAME})
                    add_library(sioyek_dep_${SFD_NAME} INTERFACE IMPORTED GLOBAL)
                    set_target_properties(sioyek_dep_${SFD_NAME} PROPERTIES
                        INTERFACE_LINK_LIBRARIES "${_mod_libs}")
                    if(_mod_incs)
                        set_target_properties(sioyek_dep_${SFD_NAME} PROPERTIES
                            INTERFACE_INCLUDE_DIRECTORIES "${_mod_incs}")
                    endif()
                endif()
                set(_found TRUE)
                set(_target "sioyek_dep_${SFD_NAME}")
            endif()
        endif()
    endif()

    # ---- (2) pkg-config fallback ----
    if(NOT _found AND SFD_PKG_NAMES AND PkgConfig_FOUND)
        foreach(_pkg IN LISTS SFD_PKG_NAMES)
            if(NOT _found)
                if(SFD_VERSION)
                    pkg_check_modules(_SFD_PC QUIET IMPORTED_TARGET "${_pkg}>=${SFD_VERSION}")
                else()
                    pkg_check_modules(_SFD_PC QUIET IMPORTED_TARGET "${_pkg}")
                endif()
                if(_SFD_PC_FOUND AND TARGET PkgConfig::_SFD_PC)
                    set(_found TRUE)
                    set(_target "PkgConfig::_SFD_PC")
                    set(_version "${_SFD_PC_VERSION}")
                endif()
            endif()
        endforeach()
    endif()

    # ---- result ----
    if(_found)
        if(SFD_OUT_TARGET)
            set(${SFD_OUT_TARGET} "${_target}" PARENT_SCOPE)
        endif()
        if(SFD_OUT_VERSION)
            set(${SFD_OUT_VERSION} "${_version}" PARENT_SCOPE)
        endif()
        message(STATUS "sioyek: found dependency ${SFD_NAME} -> target=${_target} version=${_version}")
    else()
        if(SFD_OUT_TARGET)
            set(${SFD_OUT_TARGET} "" PARENT_SCOPE)
        endif()
        if(SFD_REQUIRED)
            message(FATAL_ERROR
                "sioyek: required dependency '${SFD_NAME}' was not found "
                "(tried find_package and pkg-config: ${SFD_PKG_NAMES}).")
        endif()
    endif()
endfunction()
