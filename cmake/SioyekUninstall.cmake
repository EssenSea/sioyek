#[[============================================================================
  SioyekUninstall.cmake
  ---------------------------------------------------------------------------
  Implementation of the `uninstall` target (invoked via `cmake -P`).

  Reads the manifest that `cmake --install` writes, removes the listed files,
  and prunes directories that the install created and that are now empty.

  Inputs (environment / cache):
    SIOYEK_UNINSTALL_MANIFEST  path to install_manifest.txt (defaults to
                               ${CMAKE_BINARY_DIR}/install_manifest.txt)
    DESTDIR                    optional staging prefix, exactly as for install

  Contract:
    * only paths listed in the manifest are ever removed;
    * a missing manifest is a hard error (never a silent no-op);
    * a missing FILE is tolerated (the tree may be partially removed already),
      but reported in the summary;
    * directories are removed only when empty, deepest-first;
    * ${DESTDIR} is prepended at uninstall time, mirroring the install contract,
      so uninstalling from a staged tree cannot touch the real system prefix.
============================================================================]]#

if(NOT DEFINED CMAKE_COMMAND OR "${CMAKE_COMMAND}" STREQUAL "")
    message(FATAL_ERROR "SioyekUninstall: CMAKE_COMMAND is not defined")
endif()

# -- Manifest ---------------------------------------------------------------
if(DEFINED ENV{SIOYEK_UNINSTALL_MANIFEST} AND
   NOT "$ENV{SIOYEK_UNINSTALL_MANIFEST}" STREQUAL "")
    set(_manifest "$ENV{SIOYEK_UNINSTALL_MANIFEST}")
elseif(DEFINED SIOYEK_UNINSTALL_MANIFEST AND
       NOT "${SIOYEK_UNINSTALL_MANIFEST}" STREQUAL "")
    set(_manifest "${SIOYEK_UNINSTALL_MANIFEST}")
else()
    message(FATAL_ERROR
        "SioyekUninstall: SIOYEK_UNINSTALL_MANIFEST is not set; run the "
        "'uninstall' target instead of this script directly.")
endif()

if(NOT EXISTS "${_manifest}")
    message(FATAL_ERROR
        "SioyekUninstall: no install manifest at '${_manifest}'.\n"
        "Nothing is known to be installed from this build directory, so there is "
        "nothing safe to remove. Install first (\`cmake --install\`), or point "
        "SIOYEK_UNINSTALL_MANIFEST at the manifest of the build you want to undo.")
endif()

file(STRINGS "${_manifest}" _entries)
list(LENGTH _entries _total)
if(_total EQUAL 0)
    message(FATAL_ERROR "SioyekUninstall: manifest '${_manifest}' is empty.")
endif()

# -- Optional DESTDIR staging prefix ---------------------------------------
set(_destdir "$ENV{DESTDIR}")
if(_destdir)
    # Normalise away a trailing slash so the join below is unambiguous.
    string(REGEX REPLACE "/+$" "" _destdir "${_destdir}")
    message(STATUS "SioyekUninstall: using DESTDIR='${_destdir}' (staged tree)")
else()
    message(STATUS "SioyekUninstall: no DESTDIR set (removing from the real prefix)")
endif()

# -- Remove files -----------------------------------------------------------
set(_removed 0)
set(_missing 0)
set(_dirs "")

foreach(_entry IN LISTS _entries)
    if(_entry STREQUAL "")
        continue()
    endif()
    if(_destdir)
        set(_path "${_destdir}${_entry}")
    else()
        set(_path "${_entry}")
    endif()

    if(EXISTS "${_path}" OR IS_SYMLINK "${_path}")
        file(REMOVE "${_path}")
        math(EXPR _removed "${_removed} + 1")
        message(STATUS "Removing ${_path}")

        # Remember the parent for the empty-directory sweep.
        get_filename_component(_dir "${_path}" DIRECTORY)
        list(APPEND _dirs "${_dir}")
    else()
        math(EXPR _missing "${_missing} + 1")
    endif()
endforeach()

# -- Prune directories that are now empty, deepest first --------------------
# Sorting by descending path length is a portable way to visit children before
# their parents without assuming a '/' depth or a particular sort tool.
if(_dirs)
    list(REMOVE_DUPLICATES _dirs)
    set(_sorted "")
    foreach(_d IN LISTS _dirs)
        string(LENGTH "${_d}" _len)
        list(APPEND _sorted "${_len}|${_d}")
    endforeach()
    list(SORT _sorted ORDER DESCENDING)

    set(_dirs_removed 0)
    foreach(_item IN LISTS _sorted)
        string(FIND "${_item}" "|" _bar)
        math(EXPR _start "${_bar} + 1")
        string(SUBSTRING "${_item}" ${_start} -1 _d)

        if(NOT IS_DIRECTORY "${_d}")
            continue()
        endif()
        # Guard against removing anything that is NOT already empty: file(GLOB)
        # returns the entries, and an empty result means the directory holds
        # nothing, so removing it cannot destroy another package's files.
        file(GLOB _leftovers "${_d}/*")
        if(_leftovers)
            continue()
        endif()
        file(REMOVE_RECURSE "${_d}")
        math(EXPR _dirs_removed "${_dirs_removed} + 1")
    endforeach()
endif()

message(STATUS
    "SioyekUninstall: removed ${_removed} file(s) (${_missing} already absent), "
    "pruned ${_dirs_removed} empty director(y|ies)")

# Keep the manifest honest: it no longer describes an existing installation.
# Leaving it in place would make a second uninstall look successful while doing
# nothing, which is exactly the silent no-op this target avoids.
file(REMOVE "${_manifest}")
message(STATUS "SioyekUninstall: removed the consumed manifest '${_manifest}'")
