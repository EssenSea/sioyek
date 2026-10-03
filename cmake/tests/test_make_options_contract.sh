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
#   - ./configure (autoconf front-end) records options into config.mk
#   - the Makefile picks them up and injects them into the configure command
#   - `make options` lists every mapped key
#   - per-preset shortcuts (`make <preset>`, `make install-<preset>`, ...) exist,
#     resolve to the right preset, and also use the recorded options
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="${REPO_ROOT}/cmake/parse-build-options.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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

# --- autoconf prefix interchangeability -------------------------------------
out="$(run_parser --with-lto)"
grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${out}" && ok "--with-lto == --enable-lto (booleans accept --with)" \
    || bad "--with-<boolean> not accepted (got: ${out})"

out="$(run_parser --without-strip-on-install)"
grep -q -- '-DSIOYEK_STRIP_ON_INSTALL=OFF' <<<"${out}" && ok "--without-<boolean> == --disable-<boolean>" \
    || bad "--without-<boolean> not accepted (got: ${out})"

out="$(run_parser --enable-system-mupdf)"
grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${out}" && ok "tri-state accepts --enable- prefix" \
    || bad "tri-state --enable- not accepted (got: ${out})"

out="$(run_parser --disable-system-sqlite)"
grep -q -- '-DSIOYEK_USE_SYSTEM_SQLITE=OFF' <<<"${out}" && ok "tri-state accepts --disable- prefix" \
    || bad "tri-state --disable- not accepted (got: ${out})"

# --- explicit value overrides prefix direction (autoconf semantics) ----------
out="$(run_parser --disable-lto=yes)"
grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${out}" && ok "--disable-X=yes -> ON" \
    || bad "--disable-X=yes not normalized (got: ${out})"

out="$(run_parser --enable-lto=no)"
grep -q -- '-DSIOYEK_ENABLE_LTO=OFF' <<<"${out}" && ok "--enable-X=no -> OFF" \
    || bad "--enable-X=no not normalized (got: ${out})"

out="$(run_parser --with-system-mupdf=auto)"
grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=AUTO' <<<"${out}" && ok "value normalization: auto -> AUTO" \
    || bad "auto not normalized (got: ${out})"

# --- --list and help completeness -------------------------------------------
nlist="$("${PARSER}" --list | wc -l)"
[[ "${nlist}" -ge 18 ]] && ok "--list prints the option table (${nlist} options)" \
    || bad "--list too short (${nlist})"

# every option in the table must appear in `make options` AND in ./configure --help
mk_help="$(cd "${REPO_ROOT}" && make options 2>/dev/null)"
conf_help=""
[ -x "${REPO_ROOT}/configure" ] && conf_help="$(cd "${REPO_ROOT}" && ./configure --help 2>/dev/null)"
missing=0
while IFS=: read -r name var; do
    grep -q -- "--enable-${name}\|--with-${name}" <<<"${mk_help}" || missing=$((missing+1))
    [ -n "${conf_help}" ] && { grep -q -- "--enable-${name}\|--with-${name}" <<<"${conf_help}" || missing=$((missing+1)); }
done < <("${PARSER}" --list)
[[ ${missing} -eq 0 ]] && ok "every option appears in make options and ./configure --help" \
    || bad "${missing} option(s) missing from help"

# --- installation-directory options (autoconf/GNUInstallDirs) ---------------
out="$(run_parser --prefix=/usr)"
grep -q -- '-DCMAKE_INSTALL_PREFIX=/usr' <<<"${out}" && ok "--prefix=/usr -> CMAKE_INSTALL_PREFIX" \
    || bad "--prefix not translated (got: ${out})"

out="$(run_parser --sysconfdir=/etc)"
grep -q -- '-DCMAKE_INSTALL_SYSCONFDIR=/etc' <<<"${out}" && ok "--sysconfdir=/etc -> CMAKE_INSTALL_SYSCONFDIR" \
    || bad "--sysconfdir not translated (got: ${out})"

out="$(run_parser --bindir=/usr/bin --mandir=/usr/share/man --docdir=/usr/share/doc/sioyek)"
grep -q -- '-DCMAKE_INSTALL_BINDIR=/usr/bin' <<<"${out}" \
    && grep -q -- '-DCMAKE_INSTALL_MANDIR=/usr/share/man' <<<"${out}" \
    && grep -q -- '-DCMAKE_INSTALL_DOCDIR=/usr/share/doc/sioyek' <<<"${out}" \
    && ok "multiple dir options translated" || bad "dir options not translated (got: ${out})"

nlist="$("${PARSER}" --list-dirs | wc -l)"
[[ "${nlist}" -ge 10 ]] && ok "--list-dirs prints the directory table (${nlist})" \
    || bad "--list-dirs too short (${nlist})"

# ./configure must record dir options and list them in --help
conf_help="$("${REPO_ROOT}/configure" --help 2>/dev/null)"
grep -q -- "--prefix=" <<<"${conf_help}" && grep -q -- "--sysconfdir=" <<<"${conf_help}" \
    && ok "./configure --help lists installation-directory options" \
    || bad "./configure --help missing dir options"

# --- ./configure must be POSIX-sh portable (CI runs it with dash) -----------
# Guard against bash-isms that break /bin/sh = dash on Debian/Ubuntu CI.
if [ -f "${REPO_ROOT}/configure" ]; then
    if grep -qE '<\(|\bdeclare\b|\blocal\b|\[\[' "${REPO_ROOT}/configure"; then
        bad "./configure uses non-POSIX shell constructs (e.g. process substitution / local / [[)"
    else
        ok "./configure is POSIX-sh portable"
    fi
    if grep -qE '<\(|\bdeclare\b|\blocal\b|\[\[' "${PARSER}"; then
        bad "parse-build-options.sh uses non-POSIX shell constructs"
    else
        ok "parse-build-options.sh is POSIX-sh portable"
    fi
fi

# --- unknown option fails ---------------------------------------------------
if "${PARSER}" --enable-frobnicate >/dev/null 2>&1; then
    bad "unknown option --enable-frobnicate should fail"
else
    ok "unknown option fails (non-zero exit)"
fi
err="$("${PARSER}" --enable-frobnicate 2>&1 >/dev/null)"
grep -q "unrecognized build option" <<<"${err}" && ok "unknown option prints a diagnostic" \
    || bad "unknown option diagnostic missing (got: ${err})"

# --- ./configure -> config.mk -> make integration ---------------------------
# Run ./configure in a throwaway copy of the repo's build files so we do not
# touch the real working tree.
if command -v make >/dev/null 2>&1; then
    CONFROOT="${WORK}/conf"
    mkdir -p "${CONFROOT}/cmake"
    cp "${REPO_ROOT}/configure" "${CONFROOT}/"
    cp "${REPO_ROOT}/Makefile" "${CONFROOT}/"
    cp "${REPO_ROOT}/CMakePresets.json" "${CONFROOT}/"
    cp "${REPO_ROOT}/cmake/options.mk" "${CONFROOT}/cmake/"
    cp "${REPO_ROOT}/cmake/parse-build-options.sh" "${CONFROOT}/cmake/"

    # ./configure records the flags.
    if (cd "${CONFROOT}" && ./configure --enable-lto --disable-tests --with-system-mupdf >/dev/null 2>&1); then
        ok "./configure runs and writes config.mk"
    else
        bad "./configure failed"
    fi
    if grep -q -- '-DSIOYEK_ENABLE_LTO=ON' "${CONFROOT}/config.mk" \
       && grep -q -- '-DSIOYEK_ENABLE_TESTS=OFF' "${CONFROOT}/config.mk" \
       && grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' "${CONFROOT}/config.mk"; then
        ok "./configure records the translated flags in config.mk"
    else
        bad "config.mk missing translated flags (got: $(cat "${CONFROOT}/config.mk" 2>/dev/null))"
    fi

    # make picks up config.mk and injects the flags.
    cmd="$(cd "${CONFROOT}" && make -n configure 2>/dev/null)"
    if grep -q -- '-DSIOYEK_ENABLE_LTO=ON' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_ENABLE_TESTS=OFF' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${cmd}"; then
        ok "make injects the flags recorded by ./configure"
    else
        bad "make did not inject recorded flags (got: ${cmd})"
    fi

    # ./configure --preset=... sets the default preset used by make.
    # --prefix/--sysconfdir are recorded too.
    (cd "${CONFROOT}" && ./configure --prefix=/opt/sioyek --sysconfdir=/etc >/dev/null 2>&1)
    cmd="$(cd "${CONFROOT}" && make -n configure 2>/dev/null)"
    if grep -q -- '-DCMAKE_INSTALL_PREFIX=/opt/sioyek' <<<"${cmd}" \
       && grep -q -- '-DCMAKE_INSTALL_SYSCONFDIR=/etc' <<<"${cmd}"; then
        ok "./configure records installation directories"
    else
        bad "installation directories not recorded (got: ${cmd})"
    fi

    (cd "${CONFROOT}" && ./configure --preset=linux-portable >/dev/null 2>&1)
    cmd="$(cd "${CONFROOT}" && make -n configure 2>/dev/null)"
    grep -q -- "--preset linux-portable" <<<"${cmd}" && ok "./configure --preset sets the default preset" \
        || bad "./configure --preset did not set the preset (got: ${cmd})"

    # ./configure rejects an unknown option.
    if (cd "${CONFROOT}" && ./configure --enable-frobnicate >/dev/null 2>&1); then
        bad "./configure should reject an unknown option"
    else
        ok "./configure rejects unknown options"
    fi

    # ./configure --wipe removes config.mk.
    (cd "${CONFROOT}" && ./configure --wipe >/dev/null 2>&1)
    [[ -f "${CONFROOT}/config.mk" ]] && bad "./configure --wipe left config.mk" \
        || ok "./configure --wipe removes config.mk"

    # unknown option must abort make
    if (cd "${REPO_ROOT}" && make -n configure CMAKE_EXTRA_FLAGS="--enable-frobnicate" >/dev/null 2>&1); then
        :  # CMAKE_EXTRA_FLAGS are raw -D; not applicable
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
# Per-preset shortcuts must also pick up the ./configure-recorded options.
# ---------------------------------------------------------------------------
echo "--- shortcuts use recorded options ---"

if command -v make >/dev/null 2>&1; then
    # In the throwaway tree, record --disable-lto then build via a preset shortcut.
    (cd "${CONFROOT}" && ./configure --disable-lto --with-system-mupdf >/dev/null 2>&1)
    cmd="$(cd "${CONFROOT}" && make -n linux-portable 2>/dev/null)"
    if grep -qE -- "--preset linux-portable" <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_ENABLE_LTO=OFF' <<<"${cmd}" \
       && grep -q -- '-DSIOYEK_USE_SYSTEM_MUPDF=ON' <<<"${cmd}"; then
        ok "preset shortcut composes with ./configure options"
    else
        bad "preset shortcut did not use recorded options (got: ${cmd})"
    fi
fi

# ---------------------------------------------------------------------------
# With no config.mk, make must still work (defaults) and `make options` must list
# every mapped key.
# ---------------------------------------------------------------------------
echo "--- defaults without config.mk ---"

if command -v make >/dev/null 2>&1; then
    # Use a clean throwaway tree without config.mk so the check is independent of
    # the developer's working tree.
    NOCFG="${WORK}/nocfg"
    mkdir -p "${NOCFG}"
    cp "${REPO_ROOT}/configure" "${REPO_ROOT}/Makefile" "${REPO_ROOT}/CMakePresets.json" "${NOCFG}/"
    mkdir -p "${NOCFG}/cmake"
    cp "${REPO_ROOT}/cmake/options.mk" "${REPO_ROOT}/cmake/parse-build-options.sh" "${NOCFG}/cmake/"
    cmd="$(cd "${NOCFG}" && make -n configure 2>/dev/null)"
    if grep -q -- "--preset linux-release" <<<"${cmd}" \
       && ! grep -q -- '-DSIOYEK_' <<<"${cmd}" \
       && ! grep -q -- '-DCMAKE_INSTALL_' <<<"${cmd}"; then
        ok "make works with no config.mk (no injected -D flags)"
    else
        bad "make without config.mk unexpected (got: ${cmd})"
    fi
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
