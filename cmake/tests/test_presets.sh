#!/usr/bin/env bash
# =============================================================================
# test_presets.sh
# Regression test: verifies CMakePresets.json is usable and the naming is consistent.
# =============================================================================
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== CMakePresets checks ==="

# 1) Valid JSON
if python3 -c "import json,sys; json.load(open('${REPO_ROOT}/CMakePresets.json'))" 2>/dev/null; then
    ok "CMakePresets.json is valid JSON"
else
    bad "CMakePresets.json is not valid JSON"
fi

# 2) cmake recognizes the configure presets
out="$(cd "${REPO_ROOT}" && cmake --list-presets 2>&1)"
for p in linux-release linux-debug linux-portable linux-vendored macos-release; do
    if grep -q "\"${p}\"" <<<"${out}"; then ok "configure preset: ${p}"; else bad "missing configure preset: ${p}"; fi
done

# 3) build presets
bout="$(cd "${REPO_ROOT}" && cmake --list-presets=build 2>&1)"
if grep -q "\"linux-release\"" <<<"${bout}"; then ok "build preset: linux-release"; else bad "missing build preset"; fi

# 4) package presets
pout="$(cd "${REPO_ROOT}" && cmake --list-presets=package 2>&1)"
if grep -q "\"linux-release\"" <<<"${pout}"; then ok "package preset: linux-release"; else bad "missing package preset"; fi

# 5) CI consistency: every `cmake --preset <name>` used in a workflow must be a
#    real configure preset, and resolve_preset_bindir.sh must resolve it.
workflows_dir="${REPO_ROOT}/.github/workflows"
if [[ -d "${workflows_dir}" ]]; then
    ci_presets="$(grep -rhoE "cmake --preset [A-Za-z0-9_-]+" "${workflows_dir}" | awk '{print $3}' | sort -u)"
    if [[ -z "${ci_presets}" ]]; then
        ok "no CI preset references to check"
    else
        for cp in ${ci_presets}; do
            if grep -q "\"${cp}\"" <<<"${out}"; then
                ok "CI preset exists: ${cp}"
            else
                bad "CI references unknown configure preset: ${cp}"
            fi
            if bash "${REPO_ROOT}/cmake/tests/resolve_preset_bindir.sh" "${cp}" >/dev/null 2>&1; then
                ok "resolve_preset_bindir: ${cp}"
            else
                bad "resolve_preset_bindir failed for CI preset: ${cp}"
            fi
        done
    fi
fi

# 6) The clean targets referenced by CI/Makefile helpers must exist in CMake.
if grep -q "clean-deps" "${REPO_ROOT}/cmake/SioyekClean.cmake"; then
    ok "clean-deps target defined in SioyekClean.cmake"
else
    bad "clean-deps target missing from SioyekClean.cmake"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
