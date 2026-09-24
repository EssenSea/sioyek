#!/usr/bin/env bash
# =============================================================================
# test_install_contract.sh
# Regression test: verifies the install contract's layout and path consistency.
#
# This test is SELF-CONTAINED: it does not configure the whole sioyek project
# (which would require Qt and other heavy dependencies). Instead it creates a
# minimal CMake project that:
#   - defines a dummy `sioyek` executable target,
#   - includes the real cmake/SioyekInstall.cmake,
# then reads the generated install script and asserts the target paths for the
# standard / portable layouts match the runtime lookup convention in
# pdf_viewer/main.cpp.
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Build a minimal project for the given layout and configure it.
# Args: <layout> <outdir>
configure() {
    local layout="$1" out="$2"
    local proj="${out}/proj"
    mkdir -p "${proj}"
    # Symlink the real install contract and the resource files it references.
    ln -sf "${REPO_ROOT}/cmake/SioyekInstall.cmake" "${proj}/SioyekInstall.cmake"
    ln -sf "${REPO_ROOT}/cmake/SioyekBuildTypes.cmake" "${proj}/SioyekBuildTypes.cmake"
    ln -sf "${REPO_ROOT}/pdf_viewer"  "${proj}/pdf_viewer"
    ln -sf "${REPO_ROOT}/resources"   "${proj}/resources"
    ln -sf "${REPO_ROOT}/tutorial.pdf" "${proj}/tutorial.pdf"
    ln -sf "${REPO_ROOT}/LICENSE"     "${proj}/LICENSE"

    cat > "${proj}/main.c" <<'C'
int main(void) { return 0; }
C
    cat > "${proj}/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(install_probe C)
# Dummy executable target named `sioyek` so the install(TARGETS sioyek ...) rule works.
add_executable(sioyek main.c)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
include(${CMAKE_CURRENT_SOURCE_DIR}/SioyekInstall.cmake)
CM

    cmake -S "${proj}" -B "${out}/build" \
        -DSIOYEK_INSTALL_LAYOUT="${layout}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        >"${out}/cmake.log" 2>&1
}

expect_path() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF "${needle}" "${file}"; then ok "${desc}"; else bad "${desc} (missing ${needle})"; fi
}

echo "=== install contract: layout checks ==="

# ---- standard layout ----
B="${WORK}/std"
if configure standard "${B}"; then
    INST="${B}/build/cmake_install.cmake"
    expect_path "${INST}" "/bin"                                "standard: executable -> bin"
    expect_path "${INST}" "/share/sioyek/shaders"               "standard: shaders -> share/sioyek/shaders"
    expect_path "${INST}" "/share/sioyek"                       "standard: tutorial -> share/sioyek"
    expect_path "${INST}" "/etc/sioyek"                         "standard: config -> /etc/sioyek (absolute)"
    # Regression: the binary reads the ABSOLUTE /etc/sioyek. With prefix=/usr the
    # relative ${CMAKE_INSTALL_SYSCONFDIR} would wrongly expand to /usr/etc/sioyek.
    if grep -qF "/usr/etc/sioyek" "${INST}"; then
        bad "standard: config must NOT install under /usr/etc (binary reads /etc/sioyek)"
    else
        ok "standard: config does not land under /usr/etc"
    fi
    expect_path "${INST}" "/share/applications"                 "standard: desktop -> share/applications"
    expect_path "${INST}" "/share/pixmaps"                      "standard: icon -> share/pixmaps"
    expect_path "${INST}" "/share/man/man1"                     "standard: man -> share/man/man1"
else
    bad "standard layout configuration failed"
    sed -n '1,20p' "${B}/cmake.log" 2>/dev/null | sed 's/^/      | /'
fi

# ---- portable layout ----
B="${WORK}/por"
if configure portable "${B}"; then
    INST="${B}/build/cmake_install.cmake"
    expect_path "${INST}" "/bin/shaders"                        "portable: shaders -> bin/shaders"
    expect_path "${INST}" "/bin"                                "portable: resources beside binary (bin)"
    # portable must not install resources into share/sioyek
    if grep -qF "/share/sioyek/shaders" "${INST}"; then
        bad "portable: should not install to share/sioyek/shaders"
    else
        ok "portable: does not pollute share/sioyek/shaders"
    fi
else
    bad "portable layout configuration failed"
    sed -n '1,20p' "${B}/cmake.log" 2>/dev/null | sed 's/^/      | /'
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
