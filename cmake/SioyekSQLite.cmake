#[[============================================================================
  SioyekSQLite.cmake
  ---------------------------------------------------------------------------
  SQLite dependency consumption contract.

  Rationale (based on upstream research):
    * sioyek's use of SQLite is very shallow: only six long-stable APIs:
        sqlite3_open / sqlite3_close / sqlite3_exec
        sqlite3_errmsg / sqlite3_free / sqlite3_mprintf
      All SQL goes through sqlite3_exec with basic standard SQL; no FTS/JSON/
      window functions or other optional features; no direct struct field access
      (no ABI-level coupling).
    * SQLite has a strong backward-compatibility commitment.
    => A real compile check can replace/relax a strict version constraint:
         - compile probe (hard): try_compile a probe calling the six APIs above
           to decide whether the system library is usable;
         - version floor (soft): only a "known-good baseline" hint (WARNING),
           non-blocking;
         - fallback: when the probe fails, compile the vendored sqlite3.c.

  Outputs:
    - target `sqlite_link` (INTERFACE), used via target_link_libraries
    - SIOYEK_SQLITE_SOURCE = "system" | "vendored"
============================================================================]]#

include_guard(GLOBAL)

include(CheckCSourceCompiles)
include(SioyekDependencies)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
set(SIOYEK_USE_SYSTEM_SQLITE "AUTO" CACHE STRING
    "Use system-provided SQLite instead of the vendored amalgamation. \
AUTO: prefer system when it passes the compile probe, else vendored. \
ON: require a usable system SQLite (error if unavailable). \
OFF: always compile the vendored sqlite3.c.")
set_property(CACHE SIOYEK_USE_SYSTEM_SQLITE PROPERTY STRINGS AUTO ON OFF)

# Known-good baseline (soft, hint only)
set(SIOYEK_SQLITE_BASELINE_VERSION "3.31.1")

# ---------------------------------------------------------------------------
# Compile probe: verify the six APIs sioyek actually uses can be
# compiled + linked against the system SQLite.
# ---------------------------------------------------------------------------
set(_sioyek_sqlite_probe_src
"#include <sqlite3.h>
int main(void)
{
    sqlite3 *db = 0;
    char *err = 0;
    if (sqlite3_open(\":memory:\", &db) != SQLITE_OK) return 1;
    sqlite3_exec(db, \"SELECT 1;\", 0, 0, &err);
    if (err) sqlite3_free(err);
    const char *msg = sqlite3_errmsg(db);
    char *dup = sqlite3_mprintf(\"%s\", msg ? msg : \"\");
    sqlite3_free(dup);
    sqlite3_close(db);
    return 0;
}
")

# ---------------------------------------------------------------------------
# Detect system SQLite (via CMake's FindSQLite3, which supports a version argument)
# ---------------------------------------------------------------------------
# Vendored-only size trimming: omit SQLite features sioyek does not use.
# NOT applied to the system route (which uses the distro's build).
# Conservative set: only features confirmed unused by sioyek's SQL.
# NOTE: AUTOINCREMENT is USED by sioyek, so SQLITE_OMIT_AUTOINCREMENT must NOT be set.
option(SIOYEK_SQLITE_TRIM "Omit unused SQLite features in the vendored amalgamation." ON)

set(_sioyek_sys_sqlite_found FALSE)
set(_sioyek_sys_sqlite_version "")
set(_sioyek_sys_sqlite_probe_ok FALSE)

sioyek_find_dependency(
    NAME        SQLite3
    PKG_NAMES   sqlite3
    OUT_TARGET  _sioyek_sqlite_target
    OUT_VERSION _sioyek_sys_sqlite_version)

if(_sioyek_sqlite_target)
    set(_sioyek_sys_sqlite_found TRUE)

    # Compile probe: verify the six APIs sioyek uses can actually be compiled
    # and linked. A child try_compile project re-resolves SQLite itself (imported
    # targets do not cross project boundaries), which also validates that the
    # dependency is discoverable in a standalone build.
    set(_sioyek_probe_src_dir "${CMAKE_CURRENT_BINARY_DIR}/_sioyek_sqlite_probe")
    file(MAKE_DIRECTORY "${_sioyek_probe_src_dir}")
    file(WRITE "${_sioyek_probe_src_dir}/main.c" "${_sioyek_sqlite_probe_src}")
    file(WRITE "${_sioyek_probe_src_dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.16)
project(sqlite_probe C)
list(APPEND CMAKE_MODULE_PATH \"${CMAKE_CURRENT_SOURCE_DIR}/cmake\")
include(SioyekDependencies)
sioyek_find_dependency(NAME SQLite3 PKG_NAMES sqlite3 OUT_TARGET SQLITE_T OUT_VERSION SQLITE_V REQUIRED)
add_executable(sqlite_probe main.c)
target_link_libraries(sqlite_probe PRIVATE \"\${SQLITE_T}\")
")
    try_compile(_sioyek_sqlite_probe_ok
        "${CMAKE_CURRENT_BINARY_DIR}/_sioyek_sqlite_probe_build"
        "${_sioyek_probe_src_dir}"
        sqlite_probe
        CMAKE_FLAGS "-DCMAKE_C_STANDARD=11"
        OUTPUT_VARIABLE _sioyek_sqlite_probe_output)
    if(_sioyek_sqlite_probe_ok)
        set(_sioyek_sys_sqlite_probe_ok TRUE)
    else()
        set(_sioyek_sys_sqlite_probe_ok FALSE)
    endif()
endif()

# ---------------------------------------------------------------------------
# Pick a source based on the tri-state option and the probe result
# ---------------------------------------------------------------------------
set(_sioyek_use_system FALSE)

if(SIOYEK_USE_SYSTEM_SQLITE STREQUAL "OFF")
    set(_sioyek_use_system FALSE)

elseif(NOT _sioyek_sys_sqlite_found)
    if(SIOYEK_USE_SYSTEM_SQLITE STREQUAL "ON")
        message(FATAL_ERROR
            "SIOYEK_USE_SYSTEM_SQLITE=ON but no system SQLite was found.\n"
            "Install a SQLite development package, or set it to AUTO/OFF to use the vendored amalgamation.")
    endif()
    set(_sioyek_use_system FALSE)

elseif(NOT _sioyek_sys_sqlite_probe_ok)
    # Library found but the compile probe failed -> unusable system SQLite
    if(SIOYEK_USE_SYSTEM_SQLITE STREQUAL "ON")
        message(FATAL_ERROR
            "SIOYEK_USE_SYSTEM_SQLITE=ON but system SQLite ${_sioyek_sys_sqlite_version} failed the compile probe.\n"
            "Check whether the system SQLite is complete, or set it to AUTO/OFF to use the vendored amalgamation.")
    endif()
    set(_sioyek_use_system FALSE)
    message(STATUS
        "sioyek: system SQLite ${_sioyek_sys_sqlite_version} failed the compile probe; falling back to the vendored version.")

else()
    # Library found and probe passed -> use the system library
    set(_sioyek_use_system TRUE)

    # Soft version baseline hint (non-blocking); only if a version is known.
    if(_sioyek_sys_sqlite_version AND _sioyek_sys_sqlite_version VERSION_LESS SIOYEK_SQLITE_BASELINE_VERSION)
        message(WARNING
            "sioyek: system SQLite ${_sioyek_sys_sqlite_version} is below the known-good baseline "
            "${SIOYEK_SQLITE_BASELINE_VERSION}, but passed the compile probe.\n"
            "         (SQLite is highly backward-compatible, so this is usually fine; if issues appear, use "
            "-DSIOYEK_USE_SYSTEM_SQLITE=OFF to use the vendored version.)")
    else()
        message(STATUS
            "sioyek: system SQLite ${_sioyek_sys_sqlite_version} passed the compile probe; using the system library.")
    endif()
endif()

# ---------------------------------------------------------------------------
# Create the unified `sqlite_link` target
# ---------------------------------------------------------------------------
if(NOT TARGET sqlite_link)
    add_library(sqlite_link INTERFACE)
endif()

if(_sioyek_use_system)
    # Link the target resolved by sioyek_find_dependency (already normalized,
    # whether it came from find_package or pkg-config).
    target_link_libraries(sqlite_link INTERFACE "${_sioyek_sqlite_target}")
    set(SIOYEK_SQLITE_SOURCE "system" CACHE INTERNAL "Chosen SQLite source")
    set(SIOYEK_SQLITE_VERSION "${_sioyek_sys_sqlite_version}" CACHE INTERNAL "Chosen SQLite version")
else()
    set(_sioyek_sqlite_c "${CMAKE_CURRENT_SOURCE_DIR}/pdf_viewer/sqlite3.c")
    if(NOT EXISTS "${_sioyek_sqlite_c}")
        message(FATAL_ERROR
            "Vendored SQLite amalgamation is missing: ${_sioyek_sqlite_c}")
    endif()
    target_sources(sqlite_link INTERFACE "${_sioyek_sqlite_c}")
    target_include_directories(sqlite_link INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/pdf_viewer")

    if(SIOYEK_SQLITE_TRIM)
        # WARNING: SQLITE_OMIT_* macros are NOT safe to apply selectively to an
        # amalgamation that is also compiled with LTO: some OMIT macros remove
        # function *definitions* that the parser still *calls*, producing
        # undefined references at link time (observed: sqlite3Alter*,
        # sqlite3Analyze, sqlite3Attach/Detach, sqlite3VtabArg*). For this
        # reason the only trimming applied by default is SQLITE_DQS=0 (disable
        # the double-quoted string misfeature), which is behavior-preserving and
        # does not remove any code path.
        target_compile_definitions(sqlite_link INTERFACE
            SQLITE_DQS=0
        )
        message(STATUS "sioyek: vendored SQLite trimming enabled (SQLITE_DQS=0 only)")
    endif()
    set(SIOYEK_SQLITE_SOURCE "vendored" CACHE INTERNAL "Chosen SQLite source")
    set(SIOYEK_SQLITE_VERSION "3.31.1" CACHE INTERNAL "Chosen SQLite version")
endif()

message(STATUS "sioyek: SQLite consumption contract -> source=${SIOYEK_SQLITE_SOURCE}, version=${SIOYEK_SQLITE_VERSION}")
