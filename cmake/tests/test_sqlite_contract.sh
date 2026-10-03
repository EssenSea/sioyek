#!/usr/bin/env bash
# =============================================================================
# test_sqlite_contract.sh
# Regression test: verifies the SQLite consumption contract's source decision matrix.
#
# Approach:
#   The contract resolves SQLite via sioyek_find_dependency() and validates it
#   with a try_compile probe. This test stubs both so the decision logic can be
#   exercised deterministically for each scenario:
#     - not found                      -> system unavailable
#     - found + probe passed           -> system
#     - found + probe failed           -> fall back to vendored
#
# Matrix (tri-state option x availability x version baseline):
#   AUTO + usable (probe passed)          -> system
#   AUTO + not found                      -> vendored
#   AUTO + found but probe failed         -> vendored
#   OFF  + usable                         -> vendored
#   ON   + usable                         -> system
#   ON   + not found                      -> ERROR
#   ON   + found but probe failed         -> ERROR
#   AUTO + old version but probe passed   -> system (relaxation)
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="${REPO_ROOT}/cmake"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0

# Run the contract: args <scenario> <USE_SYSTEM> ; output system/vendored/ERROR
# scenario: OK | NOTFOUND | PROBEFAIL | OK_OLD
run_contract() {
    local scenario="$1" use="$2"
    local d="${WORK}/run_${scenario}_${use}_$$"
    mkdir -p "${d}/mod"

    cp "${MODULE_DIR}/SioyekSQLite.cmake" "${d}/mod/"
    # Provide a STUB SioyekDependencies.cmake so the contract's own
    # include(SioyekDependencies) picks up our deterministic resolver instead
    # of the real one.
    cat > "${d}/mod/SioyekDependencies.cmake" <<'DEPS'
# Stub resolver used by the contract test.
function(sioyek_find_dependency)
    set(_args ${ARGN})
    list(FIND _args "OUT_TARGET" _i)
    list(FIND _args "OUT_VERSION" _i2)
    if(_sioyek_stub_notfound)
        set(_t "")
        set(_v "")
    else()
        if(NOT TARGET SQLite3::SQLite3)
            add_library(SQLite3::SQLite3 INTERFACE IMPORTED)
        endif()
        set(_t "SQLite3::SQLite3")
        set(_v "${_sioyek_stub_ver}")
    endif()
    if(_i GREATER -1)
        math(EXPR _j "${_i}+1")
        list(GET _args ${_j} _var)
        set(${_var} "${_t}" PARENT_SCOPE)
    endif()
    if(_i2 GREATER -1)
        math(EXPR _j2 "${_i2}+1")
        list(GET _args ${_j2} _var2)
        set(${_var2} "${_v}" PARENT_SCOPE)
    endif()
endfunction()
DEPS

    # Prepare a fake vendored sqlite3.c (the contract checks for its existence)
    mkdir -p "${d}/pdf_viewer"
    echo '/* fake vendored sqlite */' > "${d}/pdf_viewer/sqlite3.c"

    # Stub sioyek_find_dependency and try_compile per scenario.
    local vv="3.53.4" probe="TRUE" notfound="FALSE"
    if [[ "${scenario}" == "OK_OLD" ]]; then vv="2.8.0"; fi
    if [[ "${scenario}" == "PROBEFAIL" ]]; then probe="FALSE"; fi
    if [[ "${scenario}" == "NOTFOUND" ]]; then notfound="TRUE"; fi

    # The stub is written into the same scope as the contract include so the
    # OUT_TARGET/OUT_VERSION variables it sets are visible to the contract.
    cat > "${d}/CMakeLists.txt" <<CM
cmake_minimum_required(VERSION 3.16)
project(probe C)
list(APPEND CMAKE_MODULE_PATH "\${CMAKE_CURRENT_SOURCE_DIR}/mod")

# --- deterministic stubs for the unified resolver and the compile probe ---
set(_sioyek_stub_notfound ${notfound})
set(_sioyek_stub_ver ${vv})
set(_sioyek_stub_probe ${probe})
function(sioyek_find_dependency)
    set(_args \${ARGN})
    list(FIND _args "OUT_TARGET" _i)
    list(FIND _args "OUT_VERSION" _i2)
    if(_sioyek_stub_notfound)
        set(_t "")
        set(_v "")
    else()
        if(NOT TARGET SQLite3::SQLite3)
            add_library(SQLite3::SQLite3 INTERFACE IMPORTED)
        endif()
        set(_t "SQLite3::SQLite3")
        set(_v "\${_sioyek_stub_ver}")
    endif()
    if(_i GREATER -1)
        math(EXPR _j "\${_i}+1")
        list(GET _args \${_j} _var)
        set(\${_var} "\${_t}" PARENT_SCOPE)
    endif()
    if(_i2 GREATER -1)
        math(EXPR _j2 "\${_i2}+1")
        list(GET _args \${_j2} _var2)
        set(\${_var2} "\${_v}" PARENT_SCOPE)
    endif()
endfunction()
function(try_compile)
    list(GET ARGN 0 _resvar)
    set(\${_resvar} "\${_sioyek_stub_probe}" PARENT_SCOPE)
endfunction()
# --------------------------------------------------------------------------

include(\${CMAKE_CURRENT_SOURCE_DIR}/mod/SioyekSQLite.cmake)
message(STATUS "CONTRACT_RESULT=\${SIOYEK_SQLITE_SOURCE}")
CM

    local out
    out="$(cmake -S "${d}" -B "${d}/build" \
                 -DSIOYEK_USE_SYSTEM_SQLITE="${use}" 2>&1)"

    if grep -q "CONTRACT_RESULT=system" <<<"${out}"; then
        echo "system"
    elif grep -q "CONTRACT_RESULT=vendored" <<<"${out}"; then
        echo "vendored"
    elif grep -qiE "CMake Error|FATAL_ERROR" <<<"${out}"; then
        echo "ERROR"
    else
        echo "UNKNOWN"
        tail -8 <<<"${out}" >&2
    fi
}

check() {
    local desc="$1" scenario="$2" use="$3" expect="$4"
    local got; got="$(run_contract "${scenario}" "${use}")"
    if [[ "${got}" == "${expect}" ]]; then
        printf '  [PASS] %-56s -> %s\n' "${desc}" "${got}"; PASS=$((PASS+1))
    else
        printf '  [FAIL] %-56s -> %s (expect %s)\n' "${desc}" "${got}" "${expect}"; FAIL=$((FAIL+1))
    fi
}

echo "=== SQLite consumption contract: source decision matrix ==="
check "AUTO + usable (probe passed)"            OK        AUTO system
check "AUTO + not found"                        NOTFOUND  AUTO vendored
check "AUTO + found but probe failed"           PROBEFAIL AUTO vendored
check "OFF  + usable (force vendored)"          OK        OFF  vendored
check "ON   + usable"                           OK        ON   system
check "ON   + not found -> error"               NOTFOUND  ON   ERROR
check "ON   + found but probe failed -> error"  PROBEFAIL ON   ERROR
check "AUTO + old version but probe passed"     OK_OLD    AUTO system

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
