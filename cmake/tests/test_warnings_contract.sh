#!/usr/bin/env bash
# =============================================================================
# test_warnings_contract.sh
# Regression test for the warning policy (SioyekWarnings).
#
# Verifies:
#   - SIOYEK_STRICT_NON_THIRD_PARTY_WARN is tri-state (AUTO/ON/OFF):
#       AUTO -> ON for Debug builds, OFF otherwise; ON/OFF force the value.
#     When enabled it adds -Wall -Wextra to the target.
#   - SIOYEK_WERROR_RETURN_TYPE (AUTO/ON/OFF) adds -Werror=return-type; AUTO
#     follows the strict-warnings state.
#   - the compiler-specific flag -Wno-inconsistent-missing-override is NOT added
#     unconditionally (it is probed; on GCC it must not be present)
#   - the third-party source downgrade helper adds -w to listed files
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

configure() {
    local out="$1"; shift
    local proj="${out}/proj"
    mkdir -p "${proj}/pdf_viewer"
    cp "${REPO_ROOT}/cmake/SioyekWarnings.cmake" "${proj}/"
    # minimal stand-ins for the third-party files the helper downgrades
    echo 'int x;' > "${proj}/pdf_viewer/sqlite3.c"
    cat > "${proj}/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(warn_probe C CXX)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
include(SioyekWarnings)
add_executable(app pdf_viewer/sqlite3.c)
sioyek_apply_self_warnings(app)
sioyek_downgrade_third_party_sources(app)
get_target_property(opts app COMPILE_OPTIONS)
message(STATUS "WARN_PROBE COMPILER_ID=${CMAKE_CXX_COMPILER_ID}")
message(STATUS "WARN_PROBE SELF_OPTS=${opts}")
get_source_file_property(sopts pdf_viewer/sqlite3.c COMPILE_OPTIONS)
message(STATUS "WARN_PROBE SQLITE_OPTS=${sopts}")
CM
    cmake -S "${proj}" -B "${out}/build" -G Ninja "$@" > "${out}/cfg.log" 2>&1
}

echo "=== warning policy contract ==="

# AUTO (default) with no build type -> OFF (no -Wall on self)
B="${WORK}/auto-none"
if configure "${B}"; then ok "warning module configures"; else bad "configure failed"; fi
if ! grep -qE "WARN_PROBE SELF_OPTS=.*-Wall" "${B}/cfg.log"; then
    ok "AUTO with no build type leaves strict warnings OFF"
else
    bad "AUTO (no build type) unexpectedly enables -Wall"
fi

# AUTO + Debug -> ON (both -Wall and -Werror=return-type)
B="${WORK}/auto-debug"
configure "${B}" -DCMAKE_BUILD_TYPE=Debug
if grep -qE "WARN_PROBE SELF_OPTS=.*-Wall" "${B}/cfg.log"; then
    ok "AUTO enables -Wall for Debug builds"
else
    bad "AUTO did not enable -Wall for Debug"
fi
if grep -qE "WARN_PROBE SELF_OPTS=.*-Werror=return-type" "${B}/cfg.log"; then
    ok "AUTO enables -Werror=return-type for Debug builds"
else
    bad "AUTO did not enable -Werror=return-type for Debug"
fi

# AUTO + Release -> OFF
B="${WORK}/auto-release"
configure "${B}" -DCMAKE_BUILD_TYPE=Release
if ! grep -qE "WARN_PROBE SELF_OPTS=.*-Wall" "${B}/cfg.log"; then
    ok "AUTO leaves strict warnings OFF for Release builds"
else
    bad "AUTO enabled -Wall for Release"
fi

# Strict ON -> -Wall -Wextra (+ -Werror=return-type via AUTO)
B="${WORK}/strict"
configure "${B}" -DSIOYEK_STRICT_NON_THIRD_PARTY_WARN=ON
if grep -qE "WARN_PROBE SELF_OPTS=.*-Wall" "${B}/cfg.log"; then
    ok "strict ON adds -Wall to self target"
else
    bad "strict ON did not add -Wall"
fi
if grep -qE "WARN_PROBE SELF_OPTS=.*-Werror=return-type" "${B}/cfg.log"; then
    ok "strict ON enables -Werror=return-type (AUTO)"
else
    bad "strict ON did not enable -Werror=return-type"
fi

# Strict OFF + Debug -> still OFF (explicit OFF overrides AUTO)
B="${WORK}/strict-off-debug"
configure "${B}" -DCMAKE_BUILD_TYPE=Debug -DSIOYEK_STRICT_NON_THIRD_PARTY_WARN=OFF
if ! grep -qE "WARN_PROBE SELF_OPTS=.*-Wall" "${B}/cfg.log"; then
    ok "explicit strict OFF overrides Debug AUTO"
else
    bad "explicit OFF still enabled -Wall"
fi

# WERROR ON independently of strict warnings
B="${WORK}/werror"
configure "${B}" -DSIOYEK_WERROR_RETURN_TYPE=ON
if grep -qE "WARN_PROBE SELF_OPTS=.*-Werror=return-type" "${B}/cfg.log"; then
    ok "SIOYEK_WERROR_RETURN_TYPE=ON adds -Werror=return-type independently"
else
    bad "SIOYEK_WERROR_RETURN_TYPE=ON did not add -Werror=return-type"
fi

# Third-party source downgraded to -w
B="${WORK}/tp"
configure "${B}"
if grep -qE "WARN_PROBE SQLITE_OPTS=.*-w" "${B}/cfg.log"; then
    ok "third-party source downgraded to -w"
else
    bad "third-party source not downgraded"
fi

# The clang-only flag must NOT be applied under GCC.
# Determine the compiler id via CMake (authoritative), then assert.
comp_id="$(grep -oE "WARN_PROBE COMPILER_ID=[^ ]*" "${B}/cfg.log" | head -1 | cut -d= -f2)"
if [[ "${comp_id}" == "GNU" ]]; then
    if grep -q "inconsistent-missing-override" "${B}/cfg.log"; then
        bad "GCC got clang-only -Wno-inconsistent-missing-override"
    else
        ok "clang-only flag not applied under GCC"
    fi
else
    ok "compiler id=${comp_id:-unknown}; GCC-specific check skipped"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
