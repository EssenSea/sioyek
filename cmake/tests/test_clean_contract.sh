#!/usr/bin/env bash
# =============================================================================
# test_clean_contract.sh
# Regression test for the clean-up facility (SioyekClean).
#
# Verifies, using a throwaway sandbox (never the real source tree):
#   - the clean-* targets are registered after configure
#   - clean-in-source removes generated in-source leftovers
#   - clean-in-source does NOT touch authored source files
#   - clean-stage removes stage/
# =============================================================================
# Strict mode. `-u` fails on an unset variable (a bug, not an empty string) and
# `-o pipefail` makes a pipeline report the rightmost NON-ZERO status, so
# `command | grep -q pattern` can no longer report success when `command`
# itself crashed. `-e` is deliberately NOT set: this suite counts failures and
# must keep running after one, reporting the full picture in a single pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Build a sandbox that mimics the repo layout (source dir == project root) so
# SioyekClean's CMAKE_SOURCE_DIR-relative paths target the sandbox.
sandbox() {
    local d="$1"
    mkdir -p "${d}"
    cp "${REPO_ROOT}/cmake/SioyekClean.cmake" "${d}/"
    cat > "${d}/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(clean_probe C)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
include(SioyekClean)
CM
    # authored source file that must survive cleaning
    echo 'int main(void){return 0;}' > "${d}/a_real_source.c"

    # Hand-written, git-tracked wrapper files that MUST survive every clean
    # target. Regression guard: an earlier SioyekClean revision listed
    # "${repo_root}/Makefile" among "accidental in-source CMake files" and
    # deleted the tracked wrapper. Reproduce that layout here so the test would
    # have caught it.
    printf 'all:\n\t@true\n' > "${d}/Makefile"
    printf 'project(hand_written)\n' > "${d}/CMakePresets.json"

    # Dependency/submodule build residue (must be removed by clean-deps).
    mkdir -p "${d}/mupdf/build/release" "${d}/mupdf/generated" "${d}/zlib/build"
    echo obj > "${d}/mupdf/build/release/foo.o"
    echo gen > "${d}/mupdf/generated/res.c"
    echo obj > "${d}/zlib/build/z.o"
}

echo "=== clean facility contract ==="

D="${WORK}/sb"
sandbox "${D}"

# Pre-create an in-source leftover + a staged install
mkdir -p "${D}/CMakeFiles" "${D}/stage/usr/bin"
echo x > "${D}/CMakeCache.txt"
echo x > "${D}/stage/usr/bin/sioyek"

# Configure in a separate build dir (out-of-source) so SioyekClean is loaded
# with CMAKE_SOURCE_DIR == sandbox.
if cmake -S "${D}" -B "${D}/build" -G Ninja >"${D}/cfg.log" 2>&1; then
    ok "sandbox configures"
else
    bad "sandbox configure failed"; sed -n '1,10p' "${D}/cfg.log"; fi

# Targets registered?
if cmake --build "${D}/build" --target help 2>/dev/null | grep -q "clean-in-source"; then
    ok "clean-in-source target registered"
else
    bad "clean-in-source target missing"
fi
for t in clean-stage clean-packages clean-all clean-build; do
    if cmake --build "${D}/build" --target help 2>/dev/null | grep -q "^${t}:"; then
        ok "target ${t} registered"
    else
        bad "target ${t} missing"
    fi
done

# clean-in-source should remove generated leftovers but keep authored files
cmake --build "${D}/build" --target clean-in-source >/dev/null 2>&1
if [[ ! -e "${D}/CMakeCache.txt" && ! -d "${D}/CMakeFiles" ]]; then
    ok "clean-in-source removed generated leftovers"
else
    bad "clean-in-source left generated leftovers"
fi
if [[ -f "${D}/a_real_source.c" ]]; then
    ok "clean-in-source preserved authored source"
else
    bad "clean-in-source deleted an authored source file!"
fi

# P0 regression guard: the hand-written Makefile / presets must survive.
if [[ -f "${D}/Makefile" ]]; then
    ok "clean-in-source preserved hand-written Makefile"
else
    bad "clean-in-source DELETED the hand-written Makefile (P0 regression)!"
fi
if [[ -f "${D}/CMakePresets.json" ]]; then
    ok "clean-in-source preserved CMakePresets.json"
else
    bad "clean-in-source DELETED CMakePresets.json (P0 regression)!"
fi

# clean-stage should remove stage/
cmake --build "${D}/build" --target clean-stage >/dev/null 2>&1
if [[ ! -d "${D}/stage" ]]; then
    ok "clean-stage removed stage/"
else
    bad "clean-stage left stage/"
fi

# clean-deps should remove only submodule build residue, never submodule sources.
if cmake --build "${D}/build" --target help 2>/dev/null | grep -q "^clean-deps:"; then
    ok "target clean-deps registered"
    # Recreate residue (clean-in-source above does not touch it) and clean.
    mkdir -p "${D}/mupdf/build/release" "${D}/mupdf/generated" "${D}/zlib/build"
    echo obj > "${D}/mupdf/build/release/foo.o"
    echo gen > "${D}/mupdf/generated/res.c"
    echo obj > "${D}/zlib/build/z.o"
    cmake --build "${D}/build" --target clean-deps >/dev/null 2>&1
    if [[ ! -d "${D}/mupdf/build" && ! -d "${D}/mupdf/generated" && ! -d "${D}/zlib/build" ]]; then
        ok "clean-deps removed submodule build residue"
    else
        bad "clean-deps left submodule build residue"
    fi
else
    bad "clean-deps target missing"
fi

# ---------------------------------------------------------------------------
# Regression: glob-based packaging artifacts must actually be REMOVED.
#
# `cmake -E rm -rf <pattern-with-*>` does NOT expand globs; it treats '*' as a
# literal and exits 0 while deleting nothing. An earlier clean-packages /
# clean-all implementation had this silent no-op. Guard that real *.deb/*.rpm/
# *.tar.gz/*.AppImage files are gone after clean-packages.
# ---------------------------------------------------------------------------
echo "--- clean-packages really removes glob artifacts ---"
mkdir -p "${D}/build/appimage"
touch "${D}/pkg.deb" "${D}/pkg.rpm" "${D}/pkg.tar.gz" "${D}/pkg.AppImage" \
      "${D}/build/tree.tar.gz"
echo x > "${D}/build/appimage/AppRun"
cmake --build "${D}/build" --target clean-packages >/dev/null 2>&1
glob_left=0
for f in "${D}/pkg.deb" "${D}/pkg.rpm" "${D}/pkg.tar.gz" "${D}/pkg.AppImage" "${D}/build/tree.tar.gz"; do
    [[ -e "${f}" ]] && glob_left=1
done
if [[ ${glob_left} -eq 0 ]]; then
    ok "clean-packages removed every globbed artifact (*.deb/*.rpm/*.tar.gz/*.AppImage)"
else
    bad "clean-packages left globbed artifacts behind (cmake -E rm does not expand globs)"
fi
if [[ ! -d "${D}/build/appimage" ]]; then
    ok "clean-packages removed build/appimage"
else
    bad "clean-packages left build/appimage"
fi

# clean-all must also honor the glob patterns.
echo "--- clean-all really removes glob artifacts ---"
touch "${D}/pkg2.deb" "${D}/pkg2.rpm"
cmake --build "${D}/build" --target clean-all >/dev/null 2>&1 || true
# clean-all schedules the build-dir removal asynchronously; the glob artifacts
# outside the build dir are removed synchronously in the same target.
if [[ ! -e "${D}/pkg2.deb" && ! -e "${D}/pkg2.rpm" ]]; then
    ok "clean-all removed globbed artifacts"
else
    bad "clean-all left globbed artifacts behind"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
