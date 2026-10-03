# list-build-presets.cmake -- query CMakePresets.json without external tools.
#
# Why this exists: the top-level Makefile derives its per-preset shortcut
# targets (make <preset>) from the configure preset list, and needs to know
# whether a given preset also has a *package* preset (so `make package` can use
# `cpack --preset` instead of a bare `cpack`). The original implementation piped
# `cmake --list-presets` through `sed`, which is not available under the
# Makefile's Windows branch and is an unnecessary extra dependency everywhere.
# Parsing CMakePresets.json with CMake is portable and needs no external tools
# (CMake is, by definition, present).
#
# Modes:
#   (default)                      print every non-hidden configure preset name,
#                                  one per line
#   -D SIOYEK_PRESET_NAME=<name> --has-package-preset
#                                  succeed iff <name> is declared in
#                                  packagePresets, fail otherwise
#
# Usage:
#   cmake -D SIOYEK_PRESETS_FILE=<path/to/CMakePresets.json> -P list-build-presets.cmake
#   cmake -D SIOYEK_PRESETS_FILE=... -D SIOYEK_PRESET_NAME=linux-release \
#         -P list-build-presets.cmake --has-package-preset

if(NOT DEFINED SIOYEK_PRESETS_FILE)
    message(FATAL_ERROR "SIOYEK_PRESETS_FILE must be defined")
endif()
if(NOT EXISTS "${SIOYEK_PRESETS_FILE}")
    message(FATAL_ERROR
        "SIOYEK_PRESETS_FILE does not exist: '${SIOYEK_PRESETS_FILE}'")
endif()

file(READ "${SIOYEK_PRESETS_FILE}" _json)

# ---- Comment stripping -----------------------------------------------------
# CMakePresets.json may legally contain comments, which CMake's JSON parser
# rejects, so they are removed first.
#
# The previous implementation used two whole-document regexes and was wrong in
# both directions:
#   * "/\\*.*\\*/" is GREEDY -- with two block comments it deleted everything
#     between them, i.e. real preset entries;
#   * "//[^\n]*" deleted any '//' occurring inside a STRING value, corrupting
#     JSON that contains a URL ("https://...") or a doubled path separator.
#
# Implementation note: a line-splitting loop is NOT used here. CMake's
# string(REPLACE) cannot safely split JSON on "\n" because ';' is also a list
# separator in this language -- any ';' inside the JSON would silently split an
# element and corrupt the document on reassembly (this was observed while
# developing this script). The comment patterns are therefore applied to the
# whole document, but anchored so they cannot consume more than one comment:
#   * the block pattern is made non-greedy/linear by excluding '*' from the body,
#     so it stops at the FIRST "*/" instead of spanning to the last one;
#   * the line pattern requires the '//' to be preceded by start-of-line or
#     whitespace AND to have no '"' between the line start and the '//', which
#     is what keeps URLs inside string values intact.
string(REGEX REPLACE "/\\*([^*]|\\*+[^*/])*\\*+/" "" _json "${_json}")
string(REGEX REPLACE "(^|\n)([ \t]*)//[^\n]*" "\\1\\2" _json "${_json}")

# ---- Helpers ---------------------------------------------------------------
# Set <out>_NAMES (list of "name" values) and <out>_HIDDEN (parallel list of
# hidden flags, "TRUE"/"FALSE") for the array <key>. A missing array yields
# empty results rather than an error, so the script also works with a presets
# file that declares no packagePresets.
function(_sioyek_read_names json key out)
    set(_names "")
    set(_hidden_flags "")
    string(JSON _len ERROR_VARIABLE _len_err LENGTH "${json}" ${key})
    if(NOT _len_err AND _len GREATER 0)
        math(EXPR _last "${_len} - 1")
        foreach(_i RANGE 0 ${_last})
            string(JSON _name ERROR_VARIABLE _name_err
                   GET "${json}" ${key} ${_i} name)
            if(_name STREQUAL "NOTFOUND" OR _name_err)
                # Reported, never skipped in silence: a malformed preset would
                # otherwise make its Makefile shortcut target vanish with no
                # explanation at all.
                message(WARNING
                    "list-build-presets: entry ${_i} of '${key}' has no usable "
                    "'name' field; ignoring it.")
                continue()
            endif()
            string(JSON _hidden ERROR_VARIABLE _hidden_err
                   GET "${json}" ${key} ${_i} hidden)
            if(_hidden_err OR NOT _hidden)
                set(_hidden "FALSE")
            endif()
            list(APPEND _names "${_name}")
            list(APPEND _hidden_flags "${_hidden}")
        endforeach()
    endif()
    set(${out}_NAMES "${_names}" PARENT_SCOPE)
    set(${out}_HIDDEN "${_hidden_flags}" PARENT_SCOPE)
endfunction()

# ---- Mode: --has-package-preset -------------------------------------------
if(SIOYEK_PRESET_NAME)
    _sioyek_read_names("${_json}" packagePresets _pkg)
    if("${SIOYEK_PRESET_NAME}" IN_LIST _pkg_NAMES)
        # Exit status carries the answer; print nothing so callers can test it
        # directly in a shell conditional.
        return()
    endif()
    message(FATAL_ERROR
        "no package preset named '${SIOYEK_PRESET_NAME}' "
        "(available: ${_pkg_NAMES})")
endif()

# ---- Mode: list the non-hidden configure presets --------------------------
_sioyek_read_names("${_json}" configurePresets _cfg)

set(_visible "")
list(LENGTH _cfg_NAMES _n)
if(_n GREATER 0)
    math(EXPR _last "${_n} - 1")
    foreach(_i RANGE 0 ${_last})
        list(GET _cfg_NAMES ${_i} _name)
        list(GET _cfg_HIDDEN ${_i} _hidden)
        if(NOT _hidden)
            list(APPEND _visible "${_name}")
        endif()
    endforeach()
endif()

if(_visible)
    # message() writes to stderr, which callers (the Makefile) discard, so emit
    # to real stdout via `cmake -E echo`. One process for the whole list: the
    # previous implementation spawned a `cmake -E echo` per preset.
    string(REPLACE ";" "\n" _out "${_visible}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${_out}")
endif()
