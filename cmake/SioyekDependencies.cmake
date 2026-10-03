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
    (2) legacy <Name>_FOUND/_LIBRARIES variables           -- targetless modules
    (3) pkg-config via pkg_check_modules(<Name>)           -- last resort
  and returns a normalized INTERFACE target plus the resolved version.

  Version reporting:
    The resolved version is reported through OUT_VERSION for ALL three paths.
    Previously only the pkg-config path set it, so callers that gate behaviour on
    a version (notably SioyekSQLite.cmake's baseline warning) never saw one.

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

    # Version back-fill for the config/module path.
    #
    # Previously _version was only ever assigned in the (broken) legacy branch
    # and the pkg-config branch, so a dependency resolved through an imported
    # target reported an EMPTY version. That silently disabled every downstream
    # version check -- e.g. SioyekSQLite.cmake guards its "below the known-good
    # baseline" warning with `if(_sioyek_sys_sqlite_version AND ...)`, which could
    # never fire. Config packages expose their version through a set of
    # conventional variables; probe them all, then fall back to the imported
    # target's IMPORTED_VERSION property (CMake >= 3.24 for most packages).
    if(_found AND NOT _version)
        string(TOUPPER "${SFD_NAME}" _UPPER_NAME)
        string(TOLOWER "${SFD_NAME}" _LOWER_NAME)
        foreach(_vpfx IN ITEMS "${SFD_NAME}" "${_UPPER_NAME}" "${_LOWER_NAME}")
            foreach(_vsuffix IN ITEMS _VERSION VERSION_STRING VERSION_MAJOR)
                if(NOT _version AND ${_vpfx}${_vsuffix})
                    set(_version "${${_vpfx}${_vsuffix}}")
                endif()
            endforeach()
        endforeach()
        if(NOT _version AND TARGET ${_target})
            get_target_property(_tv ${_target} IMPORTED_VERSION)
            if(_tv AND NOT _tv MATCHES "-NOTFOUND$")
                set(_version "${_tv}")
            endif()
        endif()
    endif()

    # Some Find modules only define <NAME>_FOUND / <NAME>_LIBRARIES.
    # Derive a properly-namespaced target for the common ZLIB case.
    if(NOT _found AND TARGET ZLIB::ZLIB AND SFD_NAME STREQUAL "ZLIB")
        set(_found TRUE)
        set(_target "ZLIB::ZLIB")
    endif()

    # Some Find modules only define <NAME>_FOUND / <NAME>_LIBRARIES and create no
    # imported target (e.g. several of CMake's own Find modules). Build a
    # namespaced INTERFACE target from those legacy variables.
    #
    # CASE SENSITIVITY (this was a real bug): CMake variable names are
    # case-sensitive, and a Find module conventionally sets "<Name>_FOUND" with
    # the SAME capitalization as the find_package() argument. The previous
    # implementation upper-cased the name (`string(TOUPPER ...)`) and then tested
    # ${_UPPER}_FOUND, i.e. it looked for "FAKEDEP_FOUND" while the module had set
    # "FakeDep_FOUND" -- so this entire branch never matched in practice and the
    # documented "a distro that only provides legacy variables still works"
    # guarantee silently did not hold. We now probe the exact-name spelling
    # first, then the all-upper variant, so both conventions work. The same
    # applies to the _VERSION/_LIBRARIES/_INCLUDE_DIRS companions below.
    if(NOT _found)
        set(_legacy_prefixes "${SFD_NAME}")
        string(TOUPPER "${SFD_NAME}" _UPPER)
        if(NOT _UPPER STREQUAL "${SFD_NAME}")
            list(APPEND _legacy_prefixes "${_UPPER}")
        endif()
        string(TOLOWER "${SFD_NAME}" _LOWER)
        if(NOT _LOWER STREQUAL "${SFD_NAME}" AND NOT _LOWER STREQUAL "${_UPPER}")
            list(APPEND _legacy_prefixes "${_LOWER}")
        endif()

        foreach(_pfx IN LISTS _legacy_prefixes)
            if(_found)
                break()
            endif()
            if(${_pfx}_FOUND)
                # Version: accept the several spellings CMake modules use.
                set(_version "${${_pfx}_VERSION}")
                if(NOT _version AND ${_pfx}_VERSION_STRING)
                    set(_version "${${_pfx}_VERSION_STRING}")
                endif()

                set(_mod_libs "${${_pfx}_LIBRARIES}")
                set(_mod_incs "${${_pfx}_INCLUDE_DIRS}")
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
        endforeach()
        # A found-but-targetless module must not be reported as "found" without a
        # usable target, or downstream code would link against an empty string.
        if(NOT _found AND _legacy_prefixes)
            foreach(_pfx IN LISTS _legacy_prefixes)
                if(${_pfx}_FOUND AND NOT _found)
                    message(STATUS
                        "sioyek: ${SFD_NAME} reports ${_pfx}_FOUND but sets no "
                        "${_pfx}_LIBRARIES and provides no imported target; "
                        "ignoring it and trying pkg-config.")
                endif()
            endforeach()
        endif()
    endif()

    # ---- (2) pkg-config fallback ----
    #
    # The prefix passed to pkg_check_modules is DERIVED FROM THE DEPENDENCY NAME
    # rather than being the fixed literal "_SFD_PC". pkg_check_modules creates an
    # IMPORTED GLOBAL target (`PkgConfig::<prefix>`) that outlives this function
    # call, so a fixed prefix meant that the second dependency to fall back to
    # pkg-config would REUSE and silently overwrite the first one's target:
    # the first caller's OUT_TARGET would then carry the *second* package's
    # include directories and link libraries. Namespacing by NAME keeps every
    # dependency's target distinct.
    if(NOT _found AND SFD_PKG_NAMES AND PkgConfig_FOUND)
        # A CMake-identifier-safe, collision-free prefix for this dependency.
        string(MAKE_C_IDENTIFIER "${SFD_NAME}" _pc_prefix)
        foreach(_pkg IN LISTS SFD_PKG_NAMES)
            if(NOT _found)
                if(SFD_VERSION)
                    pkg_check_modules(${_pc_prefix}_PC QUIET IMPORTED_TARGET "${_pkg}>=${SFD_VERSION}")
                else()
                    pkg_check_modules(${_pc_prefix}_PC QUIET IMPORTED_TARGET "${_pkg}")
                endif()
                if(${_pc_prefix}_PC_FOUND AND TARGET PkgConfig::${_pc_prefix}_PC)
                    set(_found TRUE)
                    set(_target "PkgConfig::${_pc_prefix}_PC")
                    set(_version "${${_pc_prefix}_PC_VERSION}")
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
