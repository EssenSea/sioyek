#!/usr/bin/env bash
# =============================================================================
# test_dependencies_resolution_contract.sh
# Contract for cmake/SioyekDependencies.cmake (the unified dependency resolver).
#
# The resolver claims to find a dependency through three routes and to report a
# usable target plus a version for each. Three regressions are locked down here,
# all of which were real:
#
#   1. LEGACY VARIABLES. A Find module that sets only <Name>_FOUND/_LIBRARIES
#      (no imported target) must still resolve. The old code upper-cased the
#      name before testing ${NAME}_FOUND, so a conventionally-spelled
#      FakeDep_FOUND was never seen and this branch never worked at all.
#   2. VERSION REPORTING. OUT_VERSION must be non-empty when the dependency is
#      resolved via an imported target. It used to be set only on the
#      pkg-config path, which silently disabled downstream version checks
#      (e.g. the SQLite baseline warning was dead code).
#   3. PKG-CONFIG TARGET ISOLATION. Each dependency must get its OWN
#      PkgConfig:: target; a fixed internal prefix made a second pkg-config
#      fallback silently overwrite the first dependency target.
#
# The probe is a throwaway CMake project in a temp dir; nothing in the source
# tree is modified.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== dependency resolution contract ==="

mkdir -p "${WORK}/mods"
cat > "${WORK}/mods/FindFakeDep.cmake" <<'EOF'
# Deliberately uses the CONVENTIONAL mixed-case spelling and provides no
# imported target: this is the shape the legacy branch exists to support.
set(FakeDep_FOUND TRUE)
set(FakeDep_LIBRARIES /usr/lib64/libm.so)
set(FakeDep_INCLUDE_DIRS /usr/include)
set(FakeDep_VERSION 9.9.9)
EOF

cat > "${WORK}/mods/FindUpperDep.cmake" <<'EOF'
# The all-upper spelling must work too.
set(UPPERDEP_FOUND TRUE)
set(UPPERDEP_LIBRARIES /usr/lib64/libm.so)
set(UPPERDEP_INCLUDE_DIRS /usr/include)
EOF

cat > "${WORK}/CMakeLists.txt" <<'CMAKEEOF'
cmake_minimum_required(VERSION 3.16)
project(dep_probe NONE)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/mods")
list(APPEND CMAKE_MODULE_PATH "${SIOYEK_CMAKE_DIR}")
include(SioyekDependencies)

sioyek_find_dependency(NAME FakeDep PKG_NAMES fake-dep-nonexistent
                       OUT_TARGET T_LEGACY OUT_VERSION V_LEGACY)
message(STATUS "PROBE_LEGACY target=[${T_LEGACY}] version=[${V_LEGACY}]")

sioyek_find_dependency(NAME UpperDep PKG_NAMES upper-dep-nonexistent
                       OUT_TARGET T_UPPER OUT_VERSION V_UPPER)
message(STATUS "PROBE_UPPER target=[${T_UPPER}] version=[${V_UPPER}]")

# A dependency that resolves through a real imported target: the version must
# be reported (this is regression 2).
sioyek_find_dependency(NAME ZLIB PKG_NAMES zlib
                       OUT_TARGET T_ZLIB OUT_VERSION V_ZLIB)
message(STATUS "PROBE_ZLIB target=[${T_ZLIB}] version=[${V_ZLIB}]")

# Two pkg-config fallbacks in a row must NOT share a target (regression 3).
sioyek_find_dependency(NAME PcOne PKG_NAMES harfbuzz
                       OUT_TARGET T_PC1 OUT_VERSION V_PC1)
sioyek_find_dependency(NAME PcTwo PKG_NAMES zlib
                       OUT_TARGET T_PC2 OUT_VERSION V_PC2)
message(STATUS "PROBE_PC one=[${T_PC1}] two=[${T_PC2}]")
CMAKEEOF

LOG="${WORK}/probe.log"
if ! cmake -S "${WORK}" -B "${WORK}/out" -DSIOYEK_CMAKE_DIR="${REPO_ROOT}/cmake" > "${LOG}" 2>&1; then
    bad "the dependency probe project failed to configure"
    sed -n "1,40p" "${LOG}"
else
    ok "the dependency probe project configured"

    legacy="$(grep -o 'PROBE_LEGACY.*' "${LOG}" | head -1)"
    if [[ "${legacy}" == *"target=[sioyek_dep_FakeDep]"* ]]; then
        ok "legacy mixed-case <Name>_FOUND resolves to a target"
    else
        bad "legacy mixed-case variables did not resolve (got: ${legacy})"
    fi
    if [[ "${legacy}" == *"version=[9.9.9]"* ]]; then
        ok "legacy path reports the version"
    else
        bad "legacy path did not report a version (got: ${legacy})"
    fi

    upper="$(grep -o 'PROBE_UPPER.*' "${LOG}" | head -1)"
    if [[ "${upper}" == *"target=[sioyek_dep_UpperDep]"* ]]; then
        ok "legacy all-upper <NAME>_FOUND also resolves"
    else
        bad "legacy all-upper variables did not resolve (got: ${upper})"
    fi

    zlib="$(grep -o 'PROBE_ZLIB.*' "${LOG}" | head -1)"
    if [[ "${zlib}" == *"target=[ZLIB::ZLIB]"* ]]; then
        ok "imported-target path resolves for ZLIB"
    else
        bad "ZLIB did not resolve to its imported target (got: ${zlib})"
    fi
    if [[ "${zlib}" == *"version=[]"* || "${zlib}" == *"version=[ ]"* ]]; then
        bad "imported-target path reported an EMPTY version (regression)"
    else
        ok "imported-target path reports a non-empty version"
    fi

    pc="$(grep -o 'PROBE_PC.*' "${LOG}" | head -1)"
    one="$(sed -E 's/.*one=\[([^]]*)\].*/\1/' <<<"${pc}")"
    two="$(sed -E 's/.*two=\[([^]]*)\].*/\1/' <<<"${pc}")"
    if [[ -n "${one}" && -n "${two}" && "${one}" != "${two}" ]]; then
        ok "successive pkg-config fallbacks get distinct targets"
    else
        bad "pkg-config fallbacks shared a target (one=${one} two=${two})"
    fi
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
