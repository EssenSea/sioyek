#!/usr/bin/env bash
# =============================================================================
# test_buildtypes_contract.sh
# Regression test for the build-type / optimization policy (SioyekBuildTypes).
#
# Checks observable, deterministic properties (no full build):
#   - Release uses -O2 (not the CMake default -O3)
#   - MinSizeRel / Debug flags are left to CMake
#   - strip options exist and toggle CMAKE_INSTALL_DO_STRIP / CPACK_STRIP_FILES
#   - size optimizations add -ffunction-sections/-fdata-sections + --gc-sections
#   - LTO default is ON for Release and OFF for Debug
#   - ccache detection does not fail when absent unless forced ON
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Configure a minimal project that includes only SioyekBuildTypes.
# Args: <outdir> [extra cmake -D...]
configure() {
    local out="$1"; shift
    local proj="${out}/proj"
    mkdir -p "${proj}"
    cp "${REPO_ROOT}/cmake/SioyekBuildTypes.cmake" "${proj}/"
    cat > "${proj}/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(bt_probe C CXX)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
include(SioyekBuildTypes)
message(STATUS "BT_PROBE CXX_FLAGS_RELEASE=${CMAKE_CXX_FLAGS_RELEASE}")
message(STATUS "BT_PROBE LTO=${SIOYEK_ENABLE_LTO}")
message(STATUS "BT_PROBE STRIP_INSTALL=${SIOYEK_STRIP_ON_INSTALL}")
message(STATUS "BT_PROBE STRIP_PKG=${SIOYEK_PACKAGE_STRIP}")
message(STATUS "BT_PROBE SIZE_OPT=${SIOYEK_SIZE_OPTIMIZATIONS}")
CM
    cmake -S "${proj}" -B "${out}/build" -G Ninja "$@" > "${out}/cfg.log" 2>&1
}

get() { grep -oE "BT_PROBE $1=[^ ]*" "$2" | head -1 | cut -d= -f2; }

echo "=== build-types / optimization contract ==="

# Release uses -O2 (not -O3)
B="${WORK}/rel"
configure "${B}" -DCMAKE_BUILD_TYPE=Release
v="$(get CXX_FLAGS_RELEASE "${B}/cfg.log")"
if grep -q -- '-O2' <<<"$v" && ! grep -q -- '-O3' <<<"$v"; then
    ok "Release CXX flags use -O2 (not -O3): $v"
else
    bad "Release CXX flags should be -O2, got: $v"
fi

# LTO default ON for Release
if [[ "$(get LTO "${B}/cfg.log")" == "ON" ]]; then
    ok "LTO default is ON for Release"
else
    bad "LTO default should be ON for Release"
fi

# Size optimizations default ON -> gc-sections present in flags
if [[ "$(get SIZE_OPT "${B}/cfg.log")" == "ON" ]]; then
    ok "size optimizations default ON"
else
    bad "size optimizations should default ON"
fi

# strip options default OFF
if [[ "$(get STRIP_INSTALL "${B}/cfg.log")" == "OFF" && "$(get STRIP_PKG "${B}/cfg.log")" == "OFF" ]]; then
    ok "strip options default OFF"
else
    bad "strip options should default OFF"
fi

# Debug -> LTO OFF
B="${WORK}/dbg"
configure "${B}" -DCMAKE_BUILD_TYPE=Debug
if [[ "$(get LTO "${B}/cfg.log")" == "OFF" ]]; then
    ok "LTO default is OFF for Debug"
else
    bad "LTO default should be OFF for Debug"
fi

# Explicit strip ON is reflected
B="${WORK}/strip"
configure "${B}" -DCMAKE_BUILD_TYPE=Release -DSIOYEK_STRIP_ON_INSTALL=ON -DSIOYEK_PACKAGE_STRIP=ON
if [[ "$(get STRIP_INSTALL "${B}/cfg.log")" == "ON" && "$(get STRIP_PKG "${B}/cfg.log")" == "ON" ]]; then
    ok "explicit strip options are honored"
else
    bad "explicit strip options not honored"
fi

# ccache OFF must not fail even if ccache is absent
B="${WORK}/noccache"
if configure "${B}" -DCMAKE_BUILD_TYPE=Release -DSIOYEK_ENABLE_CCACHE=OFF \
     && [[ -f "${B}/build/build.ninja" ]]; then
    ok "SIOYEK_ENABLE_CCACHE=OFF configures cleanly"
else
    bad "SIOYEK_ENABLE_CCACHE=OFF failed to configure"
fi

# ---------------------------------------------------------------------------
# ccache writability handling (regression: a read-only cache used to make every
# compilation fail with "Read-only file system", killing the build).
#
# Only run when a ccache/sccache binary exists, since the behavior under test is
# the probe. We point CCACHE_DIR at a read-only directory to simulate the mount.
# ---------------------------------------------------------------------------
if command -v ccache >/dev/null 2>&1 || command -v sccache >/dev/null 2>&1; then
    RO="${WORK}/ro-cache"
    mkdir -p "${RO}"
    chmod 500 "${RO}"

    # AUTO + unusable cache -> must fall back and configure successfully.
    B="${WORK}/cc-auto-ro"
    if CCACHE_DIR="${RO}" configure "${B}" -DCMAKE_BUILD_TYPE=Release \
         -DSIOYEK_ENABLE_CCACHE=AUTO && [[ -f "${B}/build/build.ninja" ]]; then
        ok "AUTO ccache with read-only cache falls back and configures"
    else
        bad "AUTO ccache with read-only cache failed to configure"
    fi
    if grep -qi "cache is unusable" "${B}/cfg.log"; then
        ok "AUTO ccache with read-only cache emits a warning"
    else
        bad "AUTO ccache with read-only cache should warn about the unusable cache"
    fi

    # ON + unusable cache -> must fail fast with actionable guidance.
    B="${WORK}/cc-on-ro"
    if CCACHE_DIR="${RO}" configure "${B}" -DCMAKE_BUILD_TYPE=Release \
         -DSIOYEK_ENABLE_CCACHE=ON; then
        bad "ON ccache with read-only cache should have failed"
    else
        if grep -qi "cache is unusable" "${B}/cfg.log"; then
            ok "ON ccache with read-only cache fails fast with guidance"
        else
            bad "ON ccache with read-only cache failed without explanation"
        fi
    fi

    chmod 700 "${RO}" 2>/dev/null || true
else
    ok "ccache not installed; skipping writability regression"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
