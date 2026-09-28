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
# Args: <layout> <outdir> [extra -D flags...]
configure() {
    local layout="$1" out="$2"; shift 2
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
        "${@}" \
        >"${out}/cmake.log" 2>&1
}

expect_path() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF "${needle}" "${file}"; then ok "${desc}"; else bad "${desc} (missing ${needle})"; fi
}

echo "=== install contract: layout checks ==="

# ---- standard layout ----
B="${WORK}/std"
if configure standard "${B}" -DCMAKE_INSTALL_PREFIX=/usr; then
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
if configure portable "${B}" -DCMAKE_INSTALL_PREFIX=/usr; then
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

# ---------------------------------------------------------------------------
# Runtime-path consistency guard (prefix != /usr).
#
# The runtime hard-codes /etc/sioyek and /usr/share/sioyek; an install with a
# different prefix would silently not match. SioyekInstall must warn by default
# and error under SIOYEK_STRICT_INSTALL_PREFIX=ON.
# ---------------------------------------------------------------------------
echo "--- runtime-path consistency guard ---"

# (a) /usr/ is consistent -> no warning.
B="${WORK}/std_usr"
if configure standard "${B}" -DCMAKE_INSTALL_PREFIX=/usr; then
    if grep -qi "hard-coded lookup paths" "${B}/cmake.log"; then
        bad "prefix=/usr should NOT warn about runtime-path mismatch"
    else
        ok "prefix=/usr: no runtime-path warning (consistent)"
    fi
else
    bad "prefix=/usr standard configure failed"
fi

# (b) /usr/local is inconsistent -> WARNING by default (still configures).
B="${WORK}/std_local"
if configure standard "${B}" -DCMAKE_INSTALL_PREFIX=/usr/local; then
    if grep -qi "hard-coded lookup paths" "${B}/cmake.log"; then
        ok "prefix=/usr/local: warns about runtime-path mismatch"
    else
        bad "prefix=/usr/local: expected a runtime-path warning"
    fi
else
    bad "prefix=/usr/local standard configure should still succeed (warning only)"
fi

# (c) strict -> hard error.
B="${WORK}/std_strict"
if configure standard "${B}" -DCMAKE_INSTALL_PREFIX=/usr/local -DSIOYEK_STRICT_INSTALL_PREFIX=ON; then
    bad "SIOYEK_STRICT_INSTALL_PREFIX=ON must fail for inconsistent prefix"
else
    ok "SIOYEK_STRICT_INSTALL_PREFIX=ON fails on inconsistent prefix"
fi

# (d) portable layout is the sanctioned relocation mechanism -> no warning.
B="${WORK}/por_reloc"
if configure portable "${B}" -DCMAKE_INSTALL_PREFIX=/opt/sioyek; then
    if grep -qi "hard-coded lookup paths" "${B}/cmake.log"; then
        bad "portable layout should not warn about runtime-path mismatch"
    else
        ok "portable layout at a custom prefix: no runtime-path warning"
    fi
else
    bad "portable layout at a custom prefix failed to configure"
fi

# ---------------------------------------------------------------------------
# strip rule must resolve DESTDIR at install time, not configure time.
#
# Baking $ENV{DESTDIR} at configure time silently drops it, making the rule
# strip the REAL system path instead of the staged copy. Guard that the
# generated script contains an install-time $ENV{DESTDIR} reference and no
# unresolved @...@ placeholder.
# ---------------------------------------------------------------------------
echo "--- strip rule path handling ---"
B="${WORK}/strip"
if configure standard "${B}" -DCMAKE_INSTALL_PREFIX=/usr -DSIOYEK_STRIP_ON_INSTALL=ON; then
    INST="${B}/build/cmake_install.cmake"
    if grep -qF '@_sioyek_strip' "${INST}"; then
        bad "strip rule left an unresolved @...@ placeholder"
    else
        ok "strip rule has no unresolved placeholder"
    fi
    if grep -qF '$ENV{DESTDIR}' "${INST}"; then
        ok "strip rule resolves DESTDIR at install time"
    else
        bad "strip rule does not reference DESTDIR at install time"
    fi
    if grep -qF 'refusing to silently install an unstripped binary' "${INST}"; then
        ok "strip rule fails loudly if stripping fails"
    else
        bad "strip rule does not guard against silent strip failure"
    fi
else
    bad "strip-enabled configure failed"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
