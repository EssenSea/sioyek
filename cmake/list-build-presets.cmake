# list-build-presets.cmake -- print the non-hidden configure preset names, one
# per line, parsed from CMakePresets.json.
#
# Why this exists: the top-level Makefile derives its per-preset shortcut
# targets (make <preset>) from the configure preset list. The original
# implementation piped `cmake --list-presets` through `sed`, which is not
# available under the Makefile's Windows branch and is an unnecessary extra
# dependency everywhere. Parsing CMakePresets.json with CMake is portable and
# needs no external tools (CMake is, by definition, present).
#
# Usage:
#   cmake -D SIOYEK_PRESETS_FILE=<path/to/CMakePresets.json> -P list-build-presets.cmake

if(NOT DEFINED SIOYEK_PRESETS_FILE)
    message(FATAL_ERROR "SIOYEK_PRESETS_FILE must be defined")
endif()
if(NOT EXISTS "${SIOYEK_PRESETS_FILE}")
    return()
endif()

file(READ "${SIOYEK_PRESETS_FILE}" _json)
# Strip /* ... */ and // comments (CMakePresets.json may legally contain them).
string(REGEX REPLACE "/\\*.*\\*/" "" _json "${_json}")
string(REGEX REPLACE "//[^\n]*" "" _json "${_json}")

# Walk configurePresets entries and collect their "name" when not hidden.
string(JSON _len LENGTH "${_json}" configurePresets)
if(_len GREATER 0)
    math(EXPR _last "${_len} - 1")
    foreach(_i RANGE 0 ${_last})
        # Skip malformed entries defensively.
        string(JSON _name ERROR_VARIABLE _err GET "${_json}" configurePresets ${_i} name)
        if(_name STREQUAL "NOTFOUND" OR _err)
            continue()
        endif()
        string(JSON _hidden ERROR_VARIABLE _herr GET "${_json}" configurePresets ${_i} hidden)
        if(_herr)
            set(_hidden "FALSE")
        endif()
        if(NOT _hidden)
            # NOTE: message() writes to stderr, which callers (the Makefile)
            # discard. Emit to real stdout instead via `cmake -E echo`.
            execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${_name}")
        endif()
    endforeach()
endif()
