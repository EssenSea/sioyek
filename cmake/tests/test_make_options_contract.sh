#!/usr/bin/env bash
# =============================================================================
# test_make_options_contract.sh
# Regression test for the friendly --enable/--disable/--with build options
# (cmake/parse-build-options.sh, wired into the top-level Makefile via
# cmake/options.mk).
#
# Verifies:
#   - boolean --enable-X / --disable-X map to -DSIOYEK_*=ON/OFF
#   - tri-state --with-X / --without-X / --with-X=VALUE map to -DSIOYEK_*=...
#   - value options --with-X=VALUE pass the value through
#   - bare names (enable-lto) are accepted as a convenience
#   - raw -D flags pass through untouched
#   - unknown options fail (exit != 0) with a helpful message
#   - the Makefile actually injects the flags into the configure command
#   - `make options` lists every mapped key
#   - per-preset shortcuts (`make <preset>`, `make install-<preset>`, ...) exist,
#     resolve to the right preset, and compose with the friendly options
#   - the sioyek-make wrapper accepts friendly options *inline*, i.e.
#     `./sioyek-make <target> --enable-X` (make itself rejects --long options)
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="${REPO_ROOT}/cmake/parse-build-options.sh"

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# run_parser "<args>" -> prints stdout
run_parser() { "${PARSER}" "$@" 2>/dev/null; }

echo "=== friendly build options contract ==="

# --- booleans ---------------------------------------------------------------
out="$(run_parser --enable-lto)"
grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${out}" && ok "--enable-lto -> -DSIOYEK_ENABLE_LTO=ON" \
    || bad "--enable-lto not translated (got: ${out})"

out="$(run_parser --disable-tests)"
grep -q -- '-DSIOYEK_ENABLE_TESTS=OFF' <<<"${out}" && ok "--disable-tests -> -DSIOYEK_ENABLE_TESTS=OFF" \
    || bad "--disable-tests not translated (got: ${out})"

# --- tri-state --------------------------------------------------------------
out="$(run_parser --with-system-mupdf)"
grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${out}" && ok "--with-system-mupdf -> ...=ON" \
    || bad "--with-system-mupdf not translated (got: ${out})"

out="$(run_parser --without-system-sqlite)"
grep -q -- '-DSIOYEK_USE_SYSTEM_SQLITE=OFF' <<<"${out}" && ok "--without-system-sqlite -> ...=OFF" \
    || bad "--without-system-sqlite not translated (got: ${out})"

out="$(run_parser --with-system-mupdf=AUTO)"
grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=AUTO' <<<"${out}" && ok "--with-system-mupdf=AUTO -> ...=AUTO" \
    || bad "tri-state =VALUE not translated (got: ${out})"

# --- value options ----------------------------------------------------------
out="$(run_parser --with-install-layout=portable)"
grep -q -- '-DSIOYEK_INSTALL_LAYOUT=portable' <<<"${out}" && ok "--with-install-layout=portable translated" \
    || bad "value option not translated (got: ${out})"

out="$(run_parser --with-mupdf-unembed-fonts=ALL)"
grep -q -- '-DSIOYEK_MUPDF_UNEMBED_FONTS=ALL' <<<"${out}" && ok "--with-mupdf-unembed-fonts=ALL translated" \
    || bad "font option not translated (got: ${out})"

# --- bare names -------------------------------------------------------------
out="$(run_parser enable-lto)"
grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${out}" && ok "bare 'enable-lto' accepted" \
    || bad "bare name not accepted (got: ${out})"

# --- raw -D passthrough -----------------------------------------------------
out="$(run_parser -DSIOYEK_ENABLE_LTO=OFF)"
grep -q -- '-DSIOYEK_ENABLE_LTO=OFF' <<<"${out}" && ok "raw -D passed through" \
    || bad "raw -D not passed through (got: ${out})"

# --- multiple args in one call ---------------------------------------------
out="$(run_parser --enable-lto --disable-tests --with-system-mupdf)"
n="$(grep -o -- '-D' <<<"${out}" | wc -l)"
[[ "${n}" -eq 3 ]] && ok "multiple options translated (3 -D flags)" \
    || bad "expected 3 -D flags, got ${n} (out: ${out})"

# --- unknown option fails ---------------------------------------------------
if "${PARSER}" --enable-frobnicate >/dev/null 2>&1; then
    bad "unknown option --enable-frobnicate should fail"
else
    ok "unknown option fails (non-zero exit)"
fi
err="$("${PARSER}" --enable-frobnicate 2>&1 >/dev/null)"
grep -q "unrecognized build option" <<<"${err}" && ok "unknown option prints a diagnostic" \
    || bad "unknown option diagnostic missing (got: ${err})"

# --- Makefile integration: flags reach the configure command ----------------
if command -v make >/dev/null 2>&1; then
    cmd="$(cd "${REPO_ROOT}" && make -n configure PRESET=linux-release \
            EXTRA_CMAKE_ARGS="--enable-lto --disable-tests --with-system-mupdf" 2>/dev/null)"
    if grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_ENABLE_TESTS=OFF' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${cmd}"; then
        ok "Makefile injects translated flags into configure"
    else
        bad "Makefile did not inject translated flags (got: ${cmd})"
    fi

    # unknown option must abort make
    if (cd "${REPO_ROOT}" && make -n configure EXTRA_CMAKE_ARGS="--enable-frobnicate" >/dev/null 2>&1); then
        bad "make should abort on an unknown option"
    else
        ok "make aborts on an unknown option"
    fi

    # `make options` lists every mapped key
    opts="$(cd "${REPO_ROOT}" && make options 2>/dev/null)"
    miss=0
    for k in lto tests ccache unity-build size-optimizations hidden-visibility \
             strip-on-install package-strip install-qt-deploy sqlite-trim \
             strict-warnings werror-return-type allow-unverified-system-mupdf \
             system-mupdf system-sqlite install-layout mupdf-unembed-fonts \
             package-formats; do
        grep -q -- "--enable-${k}\|--disable-${k}\|--with-${k}" <<<"${opts}" || { miss=$((miss+1)); }
    done
    if [[ ${miss} -eq 0 ]]; then
        ok "make options lists all mapped keys"
    else
        bad "make options is missing ${miss} key(s)"
    fi
else
    ok "make not available; skipping Makefile integration checks"
fi

# ---------------------------------------------------------------------------
# Per-preset shortcut targets: `make <preset>` and friends must drive the right
# preset and compose with the friendly options.
# ---------------------------------------------------------------------------
echo "--- per-preset shortcuts ---"

if command -v make >/dev/null 2>&1 && [ -f "${REPO_ROOT}/CMakePresets.json" ]; then
    # Collect the visible configure presets straight from cmake.
    presets="$(cd "${REPO_ROOT}" && cmake --list-presets 2>/dev/null \
        | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p')"
    n=0
    for p in ${presets}; do n=$((n+1)); done
    if [[ ${n} -gt 0 ]]; then
        ok "discovered ${n} configure preset(s) for shortcut checks"
    else
        bad "no configure presets discovered"
    fi

    # `make <preset>` must configure+build the SAME preset.
    bad_short=0
    for p in ${presets}; do
        cmd="$(cd "${REPO_ROOT}" && make -n "${p}" 2>/dev/null)"
        if grep -qE -- "--preset ${p}( |$)" <<<"${cmd}" \
           && grep -qE -- "--build --preset ${p}( |$)" <<<"${cmd}"; then
            :
        else
            bad_short=$((bad_short+1))
        fi
    done
    [[ ${bad_short} -eq 0 ]] && ok "make <preset> drives the matching preset for every preset" \
        || bad "make <preset> mismatched for ${bad_short} preset(s)"

    # `make install-<preset>` must build and install that preset's build dir.
    cmd="$(cd "${REPO_ROOT}" && make -n install-linux-release 2>/dev/null)"
    if grep -qE -- "--preset linux-release( |$)" <<<"${cmd}" \
       && grep -qE -- "--build --preset linux-release" <<<"${cmd}" \
       && grep -qE -- "--install build/linux-release" <<<"${cmd}"; then
        ok "make install-<preset> builds and installs the matching preset"
    else
        bad "make install-<preset> wiring is wrong (got: ${cmd})"
    fi

    # `make test-<preset>` must run ctest against the preset's build dir.
    cmd="$(cd "${REPO_ROOT}" && make -n test-linux-debug 2>/dev/null)"
    if grep -qE -- "--build --preset linux-debug" <<<"${cmd}" \
       && grep -qE -- "ctest --test-dir build/linux-debug" <<<"${cmd}"; then
        ok "make test-<preset> runs ctest in the matching build dir"
    else
        bad "make test-<preset> wiring is wrong (got: ${cmd})"
    fi

    # Composition: shortcut + friendly option must both reach configure.
    cmd="$(cd "${REPO_ROOT}" && make -n linux-release \
            EXTRA_CMAKE_ARGS="--disable-lto --with-system-mupdf" 2>/dev/null)"
    if grep -qE -- "--preset linux-release" <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_ENABLE_LTO=OFF' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${cmd}"; then
        ok "shortcut composes with friendly options (--preset + -D both present)"
    else
        bad "shortcut/option composition failed (got: ${cmd})"
    fi

    # A preset shortcut must NOT shadow the generic targets.
    for t in build install test package; do
        if (cd "${REPO_ROOT}" && make -n "${t}" >/dev/null 2>&1); then :; else
            bad "generic target '${t}' broken by per-preset rules"
        fi
    done
    ok "generic targets (build/install/test/package) still work"
else
    ok "make/CMakePresets.json unavailable; skipping shortcut checks"
fi

# ---------------------------------------------------------------------------
# sioyek-make wrapper: friendly options may be written directly after the target,
# i.e. `./sioyek-make linux-vendored --enable-lto` (plain `make` rejects it).
# ---------------------------------------------------------------------------
echo "--- sioyek-make inline options ---"

WRAP="${REPO_ROOT}/sioyek-make"
if [[ -x "${WRAP}" ]]; then
    ok "sioyek-make wrapper exists and is executable"

    # inline boolean after the target
    cmd="$("${WRAP}" -n linux-vendored --enable-lto 2>/dev/null)"
    if grep -qE -- "--preset linux-vendored" <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${cmd}"; then
        ok "wrapper: '<target> --enable-lto' -> --preset + -DSIOYEK_ENABLE_LTO=ON"
    else
        bad "wrapper inline boolean failed (got: ${cmd})"
    fi

    # mixed enable/with/value, plus a make variable
    cmd="$("${WRAP}" -n install-linux-portable --enable-strip-on-install \
            --with-system-mupdf --with-install-layout=portable DESTDIR=/tmp/s 2>/dev/null)"
    if grep -q -- '-DSIOYEK_STRIP_ON_INSTALL=ON' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_INSTALL_LAYOUT=portable' <<<"${cmd}" \
       && grep -q -- "DESTDIR='/tmp/s'" <<<"${cmd}"; then
        ok "wrapper: mixed inline options + VAR=value pass through correctly"
    else
        bad "wrapper mixed options failed (got: ${cmd})"
    fi

    # no friendly options -> behaves like make
    cmd="$("${WRAP}" -n help 2>/dev/null)"
    grep -q "sioyek Make targets" <<<"${cmd}" && ok "wrapper: no options behaves like plain make" \
        || bad "wrapper passthrough (no options) failed"

    # unknown friendly option -> non-zero
    if "${WRAP}" -n linux-release --enable-frobnicate >/dev/null 2>&1; then
        bad "wrapper should reject an unknown option"
    else
        ok "wrapper rejects unknown options"
    fi

    # plain make must still reject the inline form (documents why the wrapper exists)
    if command -v make >/dev/null 2>&1; then
        if (cd "${REPO_ROOT}" && make -n linux-vendored --enable-lto >/dev/null 2>&1); then
            bad "plain make unexpectedly accepted '--enable-lto'"
        else
            ok "plain make still rejects '--enable-lto' (wrapper is required)"
        fi
    fi

    # bin/make symlink resolves the repo root correctly
    if [[ -e "${REPO_ROOT}/bin/make" ]]; then
        cmd="$(cd "${REPO_ROOT}" && PATH="${REPO_ROOT}/bin:$PATH" make -n linux-vendored --enable-lto 2>/dev/null)"
        grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${cmd}" && ok "bin/make symlink resolves the repo root" \
            || bad "bin/make symlink resolution failed (got: ${cmd})"
    fi
else
    bad "sioyek-make wrapper missing"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
