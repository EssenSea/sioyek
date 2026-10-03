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
    # NOTE: `cmake --list-presets` is platform-filtered (it omits windows-* on
    # Linux), so validating CI references against it false-positives when a
    # workflow legitimately uses a cross-platform preset name. Validate against
    # the platform-independent CMakePresets.json parse instead.
    all_presets="$(cmake -D SIOYEK_PRESETS_FILE="${REPO_ROOT}/CMakePresets.json" \
        -P "${REPO_ROOT}/cmake/list-build-presets.cmake" 2>/dev/null)"
    if [[ -z "${ci_presets}" ]]; then
        ok "no CI preset references to check"
    else
        for cp in ${ci_presets}; do
            if grep -qx "${cp}" <<<"${all_presets}"; then
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

# 7) The Makefile discovers per-preset shortcut targets via a portable CMake
#    script (no sed dependency). Verify it exists and lists every non-hidden
#    configure preset, including the platform-specific ones.
if [[ -f "${REPO_ROOT}/cmake/list-build-presets.cmake" ]]; then
    ok "list-build-presets.cmake exists"
    scripts_out="$(cmake -D SIOYEK_PRESETS_FILE="${REPO_ROOT}/CMakePresets.json" \
        -P "${REPO_ROOT}/cmake/list-build-presets.cmake" 2>/dev/null)"
    missing=0
    for p in linux-release linux-debug linux-portable linux-vendored linux-ci \
             linux-appimage linux-relwithdebinfo macos-release macos-debug \
             windows-release windows-debug; do
        grep -qx "${p}" <<<"${scripts_out}" || missing=1
    done
    if [[ ${missing} -eq 0 ]]; then
        ok "list-build-presets.cmake lists every configure preset"
    else
        bad "list-build-presets.cmake is missing some presets"
    fi
    # It must NOT leak hidden presets (base/ninja/linux-base).
    if grep -qE '^(base|ninja|linux-base)$' <<<"${scripts_out}"; then
        bad "list-build-presets.cmake leaked hidden presets"
    else
        ok "list-build-presets.cmake excludes hidden presets"
    fi
else
    bad "cmake/list-build-presets.cmake is missing"
fi

# 7b) Windows presets must NOT pin a specific Visual Studio generator version.
#     The runner image moved past VS 2022, and "Visual Studio 17 2022" then
#     fails with "could not find any instance of Visual Studio". Leaving the
#     generator unset lets CMake pick the newest installed VS on Windows.
if python3 -c "
import json,sys
d=json.load(open('${REPO_ROOT}/CMakePresets.json'))
bad=[p['name'] for p in d['configurePresets']
     if 'windows' in p['name'] and 'generator' in p]
sys.exit(1 if bad else 0)
"; then
    ok "windows presets do not pin a Visual Studio generator version"
else
    bad "windows presets pin a VS generator version (breaks on runner upgrade)"
fi

# 8) The Makefile must no longer depend on sed for preset discovery.
if grep -q "list-build-presets.cmake" "${REPO_ROOT}/Makefile"; then
    ok "Makefile uses the portable preset lister"
else
    bad "Makefile does not use the portable preset lister"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
