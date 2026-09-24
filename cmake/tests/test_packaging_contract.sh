#!/usr/bin/env bash
# =============================================================================
# test_packaging_contract.sh
# Regression test for the CPack packaging facility (SioyekPackaging).
#
# Verifies:
#   - CPack is configured (CPackConfig.cmake generated)
#   - the package name/version/contact are set
#   - SIOYEK_PACKAGE_FORMATS is honored
#   - SIOYEK_PACKAGE_STRIP drives CPACK_STRIP_FILES
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
    mkdir -p "${proj}"
    cp "${REPO_ROOT}/cmake/SioyekPackaging.cmake" "${proj}/"
    cp "${REPO_ROOT}/LICENSE" "${proj}/" 2>/dev/null || echo "x" > "${proj}/LICENSE"
    cat > "${proj}/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(pkg_probe VERSION 2.0.0 LANGUAGES NONE)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
include(SioyekPackaging)
CM
    cmake -S "${proj}" -B "${out}/build" "$@" > "${out}/cfg.log" 2>&1
}

echo "=== packaging (CPack) contract ==="

B="${WORK}/pkg"
if configure "${B}" -DSIOYEK_PACKAGE_STRIP=ON; then
    ok "packaging configures"
else
    bad "packaging configure failed"; sed -n '1,10p' "${B}/cfg.log"; fi

CFG="${B}/build/CPackConfig.cmake"
if [[ -f "$CFG" ]]; then
    ok "CPackConfig.cmake generated"
else
    bad "CPackConfig.cmake missing"
fi

grep_q() { grep -qiE "$1" "${CFG}" 2>/dev/null; }

if grep_q 'CPACK_PACKAGE_NAME "?sioyek'; then ok "package name = sioyek"; else bad "package name not set"; fi
if grep_q 'CPACK_PACKAGE_VERSION "?2.0.0'; then ok "package version = 2.0.0"; else bad "package version not set"; fi
if grep_q 'CPACK_PACKAGE_CONTACT'; then ok "package contact set"; else bad "package contact not set"; fi

# Strip option propagates
if grep -qE 'CPACK_STRIP_FILES "?ON' "${CFG}"; then
    ok "SIOYEK_PACKAGE_STRIP=ON -> CPACK_STRIP_FILES=ON"
else
    bad "SIOYEK_PACKAGE_STRIP not propagated to CPACK_STRIP_FILES"
fi

# Strip OFF by default
B="${WORK}/pkg_off"
configure "${B}"
if ! grep -qE 'CPACK_STRIP_FILES "?ON' "${B}/build/CPackConfig.cmake" 2>/dev/null; then
    ok "CPACK_STRIP_FILES defaults OFF"
else
    bad "CPACK_STRIP_FILES should default OFF"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
