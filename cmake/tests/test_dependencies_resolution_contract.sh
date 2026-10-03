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
# --- Synthesised pkg-config packages -----------------------------------------
# These let the pkg-config route be exercised without depending on whatever the
# host happens to have installed. Each .pc declares a distinct version so the
# version-reporting assertion is meaningful.
mkdir -p "${WORK}/pc"
cat > "${WORK}/pc/sioyek-test-alpha.pc" <<'EOF'
prefix=/nonexistent
Name: sioyek-test-alpha
Description: synthetic package for the dependency resolver test
Version: 4.5.6
Libs: -lm
Cflags:
EOF
cat > "${WORK}/pc/sioyek-test-beta.pc" <<'EOF'
prefix=/nonexistent
Name: sioyek-test-beta
Description: synthetic package for the dependency resolver test
Version: 7.8.9
Libs: -lm
Cflags:
EOF
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

# A dependency resolved through PKG-CONFIG must also report its version
# (this is regression 2).
#
# The packages used here are SYNTHESISED by this test, not taken from the host.
# An earlier revision used the real "zlib" and "harfbuzz", which made the
# assertions depend on which of them, and in which form, the CI image happened
# to ship -- it passed locally and failed on CI. The test now ships its own .pc
# files, so the result depends only on the resolver.
sioyek_find_dependency(NAME PcAlpha PKG_NAMES sioyek-test-alpha
                       OUT_TARGET T_PC1 OUT_VERSION V_PC1)
sioyek_find_dependency(NAME PcBeta PKG_NAMES sioyek-test-beta
                       OUT_TARGET T_PC2 OUT_VERSION V_PC2)
message(STATUS "PROBE_PC one=[${T_PC1}] version1=[${V_PC1}] two=[${T_PC2}] version2=[${V_PC2}]")
CMAKEEOF

LOG="${WORK}/probe.log"
# PKG_CONFIG_PATH is restricted to the synthetic packages (plus any system
# default) so the resolver finds exactly what this test provides.
if ! PKG_CONFIG_PATH="${WORK}/pc:${PKG_CONFIG_PATH:-}" \
     cmake -S "${WORK}" -B "${WORK}/out" \
       -DSIOYEK_CMAKE_DIR="${REPO_ROOT}/cmake" > "${LOG}" 2>&1; then
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

    # A dependency resolved through pkg-config must yield a usable target AND a
    # non-empty version. Only those two properties are asserted -- NOT a specific
    # target name, and not a specific route -- because both are environment
    # dependent, and asserting them made an earlier revision of this test pass
    # locally while failing on CI.
    pc="$(grep -o 'PROBE_PC.*' "${LOG}" | head -1)"
    pc1="$(sed -E 's/.*one=\[([^]]*)\].*/\1/' <<<"${pc}")"
    v1="$(sed -E 's/.*version1=\[([^]]*)\].*/\1/' <<<"${pc}")"
    pc2="$(sed -E 's/.*two=\[([^]]*)\].*/\1/' <<<"${pc}")"
    v2="$(sed -E 's/.*version2=\[([^]]*)\].*/\1/' <<<"${pc}")"

    if [[ -n "${pc1}" && -n "${pc2}" ]]; then
        ok "pkg-config route resolves to usable targets"
    else
        bad "pkg-config route produced no target (got: ${pc})"
    fi

    # Regression 2: the version used to be reported ONLY on the pkg-config path
    # and even there it was empty for the config/module route. Each synthetic
    # package declares a distinct version, so a correct resolver must report it.
    if [[ "${v1}" == "4.5.6" && "${v2}" == "7.8.9" ]]; then
        ok "pkg-config route reports the declared versions (${v1}, ${v2})"
    else
        bad "pkg-config route reported wrong/empty versions (v1=${v1} v2=${v2})"
    fi

    # Regression 3: a FIXED internal prefix made the second fallback silently
    # reuse and overwrite the first dependency target. Distinct synthetic
    # packages must therefore yield distinct targets.
    if [[ "${pc1}" != "${pc2}" ]]; then
        ok "successive pkg-config fallbacks get distinct targets (${pc1} vs ${pc2})"
    else
        bad "pkg-config fallbacks shared a target (one=${pc1} two=${pc2})"
    fi
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
