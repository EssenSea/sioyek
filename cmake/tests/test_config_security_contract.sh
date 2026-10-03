#!/usr/bin/env bash
# =============================================================================
# test_config_security_contract.sh
# Security + integrity contract for the ./configure -> config.mk -> make path.
#
# The single most important property of this build system configuration layer:
# a value the user types must NOT be able to become a command that runs, and
# must arrive at CMake unchanged. ./configure records values into config.mk,
# which the Makefile includes, and GNU make expands that file textually while
# PARSING it -- so $(shell ...) in a recorded value executes with no target built.
#
# Verifies:
#   - command-substitution payloads ($(...), backticks, ${...}) are REJECTED
#   - shell metacharacters (; | & < > parens braces globs) are REJECTED
#   - a bare "$" is rejected, so make cannot expand the value into something
#     else (the --prefix=$HOME silent-corruption bug)
#   - a semicolon list is expressible via the --package-formats comma syntax
#   - an empty value after "=" is rejected for BOTH feature and directory
#     options (it used to silently mean ON for features)
#   - every bounded option is validated against its domain
#   - no dangerous character can reach config.mk through either entry point
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="${REPO_ROOT}/cmake/parse-build-options.sh"
CONFIGURE="${REPO_ROOT}/configure"
WORK="$(mktemp -d)"
CONFIG_MK="${REPO_ROOT}/config.mk"
trap 'rm -rf "${WORK}"; rm -f "${CONFIG_MK}"' EXIT

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

parser_rc() { "${PARSER}" "$@" >/dev/null 2>&1; }

expect_reject() {
    local desc="$1"; shift
    local err
    if err="$("${PARSER}" "$@" 2>&1 >/dev/null)"; then
        bad "${desc}: ACCEPTED but must be rejected"
    elif [[ -z "${err}" ]]; then
        bad "${desc}: rejected without a diagnostic"
    else
        ok "${desc} rejected with a diagnostic"
    fi
}

expect_accept() {
    local desc="$1" expected="$2"; shift 2
    local out
    out="$("${PARSER}" "$@" 2>/dev/null)" || { bad "${desc}: rejected but must be accepted"; return; }
    if [[ "${out}" == *"${expected}"* ]]; then
        ok "${desc}"
    else
        bad "${desc} (expected ${expected}, got ${out})"
    fi
}

echo "=== configuration security contract ==="

# --- command substitution ---------------------------------------------------
D="$(printf "\x24")"   # a literal dollar sign, unexpanded
B="$(printf "\x60")"   # a literal backtick
expect_reject "shell command payload"      "--enable-lto=${D}(shell touch /tmp/x)"
expect_reject "command substitution payload" "--with-package-formats=${D}(id)"
expect_reject "backtick payload"           "--with-package-formats=${B}id${B}"
expect_reject "make variable reference"    "--with-package-formats=${D}{HOME}"
expect_reject "bare dollar (corruption)"   "--with-package-formats=a${D}HOME"
expect_reject "bare dollar in a directory" "--prefix=${D}HOME"
expect_reject "bare dollar in a feature"   "--enable-lto=${D}USER"

# --- shell metacharacters ---------------------------------------------------
expect_reject "semicolon"       "--with-package-formats=a;b"
expect_reject "pipe"            "--with-package-formats=a|b"
expect_reject "ampersand"       "--with-package-formats=a&b"
expect_reject "output redirect" "--with-package-formats=a>b"
expect_reject "input redirect"  "--with-package-formats=a<b"
expect_reject "parenthesis"     "--with-package-formats=a(b)"
expect_reject "brace"           "--with-package-formats=a{b}"
expect_reject "glob star"       "--with-package-formats=a*b"
expect_reject "glob question"   "--with-package-formats=a?b"
expect_reject "bracket"         "--with-package-formats=a[b]"
expect_reject "hash"            "--with-package-formats=a#b"
expect_reject "bang"            "--with-package-formats=a!b"
expect_reject "tilde"           "--with-package-formats=a~b"
expect_reject "double quote"    "--with-package-formats=a\"b"
expect_reject "whitespace"      "--with-package-formats=a b"

# --- empty values -----------------------------------------------------------
if parser_rc --enable-lto=; then
    bad "--enable-lto= accepted (must be rejected, not treated as ON)"
else
    ok "--enable-lto= rejected (no silent ON)"
fi
if parser_rc --prefix=; then
    bad "--prefix= accepted (must be rejected)"
else
    ok "--prefix= rejected (consistent with feature options)"
fi
expect_accept "--enable-lto (no =) still means ON"     "-DSIOYEK_ENABLE_LTO=ON"  --enable-lto
expect_accept "--disable-lto (no =) still means OFF"   "-DSIOYEK_ENABLE_LTO=OFF" --disable-lto

# --- bounded option domains -------------------------------------------------
for opt in lto tests unity-build size-optimizations hidden-visibility strip-on-install package-strip install-qt-deploy sqlite-trim allow-unverified-system-mupdf; do
    expect_reject "domain enforced for --${opt}=garbage" "--enable-${opt}=garbage"
done
for opt in ccache strict-warnings werror-return-type system-mupdf system-sqlite; do
    expect_reject "tri-state domain enforced for --${opt}=garbage" "--with-${opt}=garbage"
done
expect_reject "install-layout domain"      "--with-install-layout=garbage"
expect_reject "mupdf-unembed-fonts domain" "--with-mupdf-unembed-fonts=garbage"

# --- list-valued option -----------------------------------------------------
expect_accept "generator list translates to a CMake list" "-DSIOYEK_PACKAGE_FORMATS=DEB;RPM;TGZ" --with-package-formats=DEB,RPM,TGZ
expect_accept "single generator" "-DSIOYEK_PACKAGE_FORMATS=TGZ" --with-package-formats=TGZ
expect_reject "unknown generator"                  "--with-package-formats=GARBAGE"
expect_reject "unknown generator inside a list"    "--with-package-formats=DEB,GARBAGE"
expect_reject "empty list member (trailing comma)" "--with-package-formats=DEB,"
expect_reject "empty list member (leading comma)"  "--with-package-formats=,DEB"
expect_reject "empty list member (doubled comma)"  "--with-package-formats=DEB,,RPM"
expect_reject "raw semicolon list (cannot round-trip)" "--with-package-formats=DEB;RPM"

# --- autoconf aliases -------------------------------------------------------
expect_accept "--disable-X=yes normalises to ON" "-DSIOYEK_ENABLE_LTO=ON" --disable-lto=yes
expect_accept "--enable-X=no normalises to OFF"  "-DSIOYEK_ENABLE_LTO=OFF" --enable-lto=no
expect_accept "--enable-X=1 normalises to ON"    "-DSIOYEK_ENABLE_LTO=ON" --enable-lto=1
expect_accept "--with-X=auto normalises to AUTO" "-DSIOYEK_USE_SYSTEM_MUPDF=AUTO" --with-system-mupdf=auto

# --- end-to-end: nothing dangerous reaches config.mk ------------------------
echo "--- ./configure end-to-end ---"
PAYLOAD="--enable-lto=${D}(shell touch ${WORK}/pwned)"
if ( cd "${WORK}" && "${CONFIGURE}" "${PAYLOAD}" >/dev/null 2>&1 ); then
    bad "./configure accepted a command-substitution payload"
elif [[ -e "${WORK}/pwned" ]]; then
    bad "./configure EXECUTED a command-substitution payload"
else
    ok "./configure rejects the payload and executes nothing"
fi

if ( cd "${WORK}" && "${CONFIGURE}" "--enable-lto=${D}USER" >/dev/null 2>&1 ); then
    bad "./configure accepted a bare-dollar value"
else
    ok "./configure rejects a bare-dollar value (no make-time expansion)"
fi

# NOTE: ./configure always writes config.mk next to itself (the repository
# root), regardless of the caller's cwd, so the assertions target that path and
# the trap removes it again.
( cd "${WORK}" && "${CONFIGURE}" --prefix=/usr --disable-tests >/dev/null 2>&1 )
if [[ -f "${CONFIG_MK}" ]]; then
    if grep -q -- "-DCMAKE_INSTALL_PREFIX=/usr" "${CONFIG_MK}" && grep -q -- "-DSIOYEK_ENABLE_TESTS=OFF" "${CONFIG_MK}"; then
        ok "config.mk records the values verbatim"
    else
        bad "config.mk did not record the expected flags"
    fi
    if grep -q '[$]' "${CONFIG_MK}"; then
        bad "config.mk contains a dollar sign (make would expand it)"
    else
        ok "config.mk contains no dollar sign that make could expand"
    fi
else
    bad "./configure did not write config.mk for a valid invocation"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
