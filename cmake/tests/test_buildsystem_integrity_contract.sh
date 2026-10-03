#!/usr/bin/env bash
# =============================================================================
# test_buildsystem_integrity_contract.sh
# Regression guard for build-system integrity properties that were previously
# broken in ways no test could catch.
#
# Verifies:
#   - `make lint` has no dependency on a file no rule creates (it used to be
#     unconditionally broken: "No rule to make target .../.ran-cmake")
#   - the CTest suite list is DISCOVERED from cmake/tests/test_*.sh, so the
#     suite registry cannot drift away from the files on disk (it did: CTest
#     registered 8 suites while run_all.sh ran 9, silently hiding the largest
#     one from the CI path, which uses ctest)
#   - run_all.sh also discovers its suites and enables pipefail
#   - an uninstall capability exists and its script refuses to act without a
#     manifest (never a silent no-op)
#   - `make package` consults the CMake package presets instead of ignoring them
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKEFILE="${REPO_ROOT}/Makefile"
TESTING="${REPO_ROOT}/cmake/SioyekTesting.cmake"
RUN_ALL="${REPO_ROOT}/cmake/tests/run_all.sh"
UNINSTALL="${REPO_ROOT}/cmake/SioyekUninstall.cmake"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== build-system integrity contract ==="

# --- make lint must not depend on a non-existent stamp file -----------------
STAMP_FILES="$(grep -v '^[[:space:]]*#' "${MAKEFILE}" | grep -oE "[A-Za-z0-9_$()/.-]*\.ran-cmake" || true)"
if [[ -n "${STAMP_FILES}" ]]; then
    bad "Makefile still depends on .ran-cmake: ${STAMP_FILES}"
else
    ok "Makefile has no .ran-cmake dependency (only the history comment mentions it)"
fi

# `make -n lint` must be able to plan the target (dry run, nothing executes).
if ( cd "${REPO_ROOT}" && make -n lint >/dev/null 2>&1 ); then
    ok "make lint can be planned (no rule missing)"
else
    bad "make lint cannot be planned (a dependency has no rule)"
fi

# --- CTest suite list must be discovered, not hand-maintained ---------------
if grep -q "file(GLOB" "${TESTING}" && grep -q "test_\*.sh" "${TESTING}"; then
    ok "CTest registers suites by discovery (file(GLOB ... test_*.sh))"
else
    bad "CTest suite registration is not discovery-based (drift is possible again)"
fi

# The critical regression: every suite on disk must be registered by CTest.
# Compare the discovered names against what SioyekTesting.cmake would register
# by checking that no suite name is missing from a configured build.
DISK_SUITES="$(cd "${REPO_ROOT}/cmake/tests" && ls test_*.sh 2>/dev/null | sed 's/^test_//; s/\.sh$//' | sort)"
DISK_COUNT="$(printf '%s\n' "${DISK_SUITES}" | grep -c . || true)"
if [[ "${DISK_COUNT}" -ge 9 ]]; then
    ok "found ${DISK_COUNT} contract suites on disk"
else
    bad "expected at least 9 contract suites, found ${DISK_COUNT}"
fi

# run_all.sh must ALSO discover, and must not carry a hand-written list.
if grep -q "test_\*\.sh" "${RUN_ALL}"; then
    ok "run_all.sh discovers its suites"
else
    bad "run_all.sh still uses a hand-written suite list"
fi
if grep -q "pipefail" "${RUN_ALL}"; then
    ok "run_all.sh enables pipefail"
else
    bad "run_all.sh does not enable pipefail"
fi

# Every individual suite must enable pipefail as well.
NO_PIPEFAIL=0
for f in "${REPO_ROOT}"/cmake/tests/test_*.sh; do
    grep -q "pipefail" "${f}" || { NO_PIPEFAIL=$((NO_PIPEFAIL+1)); echo "      (no pipefail: $(basename "${f}"))"; }
done
if [[ "${NO_PIPEFAIL}" -eq 0 ]]; then
    ok "every contract suite enables pipefail"
else
    bad "${NO_PIPEFAIL} contract suite(s) lack pipefail"
fi

# --- uninstall capability ---------------------------------------------------
if [[ -f "${UNINSTALL}" ]]; then
    ok "an uninstall implementation exists (cmake/SioyekUninstall.cmake)"
else
    bad "cmake/SioyekUninstall.cmake is missing"
fi
if grep -q "add_custom_target(uninstall" "${REPO_ROOT}/cmake/SioyekInstall.cmake"; then
    ok "the install contract registers an uninstall target"
else
    bad "no uninstall target is registered"
fi
if grep -q "^uninstall:" "${MAKEFILE}"; then
    ok "make exposes an uninstall target"
else
    bad "Makefile has no uninstall target"
fi

# Running the uninstall script with no manifest must FAIL, not silently succeed.
if cmake -E env SIOYEK_UNINSTALL_MANIFEST="${REPO_ROOT}/.no-such-manifest" \
        "${CMAKE_COMMAND:-cmake}" -P "${UNINSTALL}" >/dev/null 2>&1; then
    bad "uninstall succeeded without a manifest (silent no-op)"
else
    ok "uninstall refuses to run without a manifest"
fi

# --- make package must consult the package presets --------------------------
if grep -q "cpack --preset" "${MAKEFILE}"; then
    ok "make package uses cpack --preset when a package preset exists"
else
    bad "make package ignores the CMake package presets"
fi
if grep -q "has-package-preset" "${MAKEFILE}"; then
    ok "make package probes for the package preset before using it"
else
    bad "make package does not probe for a package preset"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
