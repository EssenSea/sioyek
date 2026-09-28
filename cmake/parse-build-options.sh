#!/bin/sh
# Translate friendly build options into -DSIOYEK_* CMake flags.
#
# Autoconf conventions: the same option may be written with any of the prefixes
#   --enable-X / --with-X      ->  -DSIOYEK_*=ON   (or =VALUE with --enable-X=V)
#   --disable-X / --without-X  ->  -DSIOYEK_*=OFF
# and, per autoconf, an explicit value overrides the prefix direction:
#   --disable-X=yes   == --enable-X=yes  (yes/on/true/1 -> ON)
#   --enable-X=no     == --disable-X     (no/off/false/0 -> OFF)
#   anything else is passed verbatim as the value.
#
# The prefix may be omitted for --enable/--disable (bare "enable-lto").
# Raw -D flags are passed through. Unknown options are an error.
#
# Prints the resulting "-D..." flags on stdout; exits 2 on an unknown option.

set -eu

# The single option table: name:CMakeVar. Adding an option here (and to
# `make options`) is all that is needed.
OPTIONS="
lto:SIOYEK_ENABLE_LTO
tests:SIOYEK_ENABLE_TESTS
ccache:SIOYEK_ENABLE_CCACHE
unity-build:SIOYEK_UNITY_BUILD
size-optimizations:SIOYEK_SIZE_OPTIMIZATIONS
hidden-visibility:SIOYEK_HIDDEN_VISIBILITY
strip-on-install:SIOYEK_STRIP_ON_INSTALL
package-strip:SIOYEK_PACKAGE_STRIP
install-qt-deploy:SIOYEK_INSTALL_QT_DEPLOY
sqlite-trim:SIOYEK_SQLITE_TRIM
strict-warnings:SIOYEK_STRICT_NON_THIRD_PARTY_WARN
werror-return-type:SIOYEK_WERROR_RETURN_TYPE
allow-unverified-system-mupdf:SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF
system-mupdf:SIOYEK_USE_SYSTEM_MUPDF
system-sqlite:SIOYEK_USE_SYSTEM_SQLITE
install-layout:SIOYEK_INSTALL_LAYOUT
mupdf-unembed-fonts:SIOYEK_MUPDF_UNEMBED_FONTS
package-formats:SIOYEK_PACKAGE_FORMATS
"

# Constrained-value table: feature-name:allowed-values (space separated).
# Used to fail fast on typos instead of silently passing a bogus value to CMake
# (which previously surfaced only later, or was silently ignored). Options not
# listed here accept any non-empty value. The special value "ANY" means the
# option accepts arbitrary values (e.g. a free-form version string).
ENUMS="
ccache:AUTO,ON,OFF
strict-warnings:AUTO,ON,OFF
werror-return-type:AUTO,ON,OFF
system-mupdf:AUTO,ON,OFF
system-sqlite:AUTO,ON,OFF
install-layout:standard,portable
mupdf-unembed-fonts:OFF,CJK,CJK_LANG,ALL
install-qt-deploy:ON,OFF
sqlite-trim:ON,OFF
"

# Installation-directory options (autoconf/GNUInstallDirs style): name:CMakeVar.
# These take a DIR value, e.g. --prefix=/usr, --sysconfdir=/etc.
DIRS="
prefix:CMAKE_INSTALL_PREFIX
exec-prefix:CMAKE_INSTALL_PREFIX
bindir:CMAKE_INSTALL_BINDIR
libdir:CMAKE_INSTALL_LIBDIR
libexecdir:CMAKE_INSTALL_LIBEXECDIR
includedir:CMAKE_INSTALL_INCLUDEDIR
datarootdir:CMAKE_INSTALL_DATAROOTDIR
datadir:CMAKE_INSTALL_DATADIR
sysconfdir:CMAKE_INSTALL_SYSCONFDIR
localstatedir:CMAKE_INSTALL_LOCALSTATEDIR
runstatedir:CMAKE_INSTALL_RUNSTATEDIR
sharedstatedir:CMAKE_INSTALL_SHAREDSTATEDIR
mandir:CMAKE_INSTALL_MANDIR
docdir:CMAKE_INSTALL_DOCDIR
"

# --list: print the feature option table (name:CMakeVar), one per line, for
# generated help/completion.
if [ "${1:-}" = "--list" ]; then
for pair in $OPTIONS; do echo "$pair"; done
exit 0
fi

# --list-dirs: print the installation-directory table (name:CMakeVar).
if [ "${1:-}" = "--list-dirs" ]; then
for pair in $DIRS; do echo "$pair"; done
exit 0
fi

# Normalize a value token (yes/on/true/1 -> ON, no/off/false/0 -> OFF).
_normalize_value() {
case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
yes|on|true|1) echo ON ;;
no|off|false|0) echo OFF ;;
auto) echo AUTO ;;
*) echo "$1" ;;
esac
}

# Validate a value: reject characters that would break the "config.mk ->
# make -> -D flag" round-trip (word splitting / shell injection), and enforce
# the ENUMS table when one is registered for this option.
# Usage: _validate_value <option-name> <value>   (prints nothing, exits 2 on error)
_validate_value() {
_vn=$1
_vv=$2
case "$_vv" in
"")
    echo "error: option '--$_vn' was given an empty value" >&2
    exit 2
    ;;
*[[:space:]]*)
    echo "error: option '--$_vn' value '$_vv' contains whitespace;" >&2
    echo "       values must be a single unquoted token (no spaces/tabs)" >&2
    exit 2
    ;;
*\"*)
    echo "error: option '--$_vn' value '$_vv' contains a double quote" >&2
    exit 2
    ;;
*\'*)
    echo "error: option '--$_vn' value '$_vv' contains a single quote" >&2
    exit 2
    ;;
esac
# Enforce the ENUMS table, if any, for this option (case-insensitive).
for _ep in $ENUMS; do
    _ek=${_ep%%:*}
    _ev=$(echo "${_ep#*:}" | tr ',' ' ')
    if [ "$_ek" = "$_vn" ]; then
        _ok=0
        _vnorm=$(echo "$_vv" | tr '[:upper:]' '[:lower:]')
        for _e in $_ev; do
            _enorm=$(echo "$_e" | tr '[:upper:]' '[:lower:]')
            [ "$_vnorm" = "$_enorm" ] && { _ok=1; break; }
        done
        if [ "$_ok" = 0 ]; then
            echo "error: invalid value '$_vv' for --$_vn (allowed: $_ev)" >&2
            exit 2
        fi
        break
    fi
done
return 0
}

out=""
for a in "$@"; do
# Allow bare names by adding a default --enable/--with prefix heuristically:
# "enable-lto" -> "--enable-lto", "disable-tests" -> "--disable-tests".
case "$a" in
enable-*)  a="--$a" ;;
disable-*) a="--$a" ;;
with-*)    a="--$a" ;;
without-*) a="--$a" ;;
esac

matched=0

# Installation-directory options: --prefix=DIR, --sysconfdir=DIR, ...
case "$a" in
--*=*)
dkey=${a#--}; dkey=${dkey%%=*}; dval=${a#*=}
for pair in $DIRS; do
k=${pair%%:*}; v=${pair##*:}
if [ "$k" = "$dkey" ]; then
if [ -z "$dval" ]; then
echo "error: option '--$dkey' was given an empty value" >&2
exit 2
fi
case "$dval" in
*[[:space:]]*)
echo "error: option '--$dkey' value '$dval' contains whitespace;" >&2
echo "       install-directory values must be a single unquoted token" >&2
exit 2
;;
*\"*|*\'*)
echo "error: option '--$dkey' value '$dval' contains a quote" >&2
exit 2
;;
esac
out="$out -D$v=$dval"
matched=1
break
fi
done
;;
esac

# Split "key" and optional "=VALUE".
key=${a#--}
val=""
case "$key" in
*=*) val=${key#*=}; key=${key%%=*} ;;
esac

# Strip the prefix to get the bare option name.
name=""
dir=""
case "$key" in
enable-*)  name=${key#enable-};  dir=enable ;;
disable-*) name=${key#disable-}; dir=disable ;;
with-*)    name=${key#with-};    dir=with ;;
without-*) name=${key#without-}; dir=without ;;
*) name="" ;;
esac

if [ -n "$name" ]; then
# find the CMake variable for this name
var=""
for pair in $OPTIONS; do
k=${pair%%:*}; v=${pair##*:}
[ "$k" = "$name" ] && { var=$v; break; }
done
if [ -n "$var" ]; then
if [ -n "$val" ]; then
# explicit value wins over the prefix direction
_validate_value "$name" "$val"
out="$out -D$var=$(_normalize_value "$val")"
else
case "$dir" in
enable|with)    out="$out -D$var=ON" ;;
disable|without) out="$out -D$var=OFF" ;;
esac
fi
matched=1
fi
fi

# raw -D passthrough
case "$a" in
-D*) out="$out $a"; matched=1 ;;
esac

if [ "$matched" = 0 ]; then
echo "error: unrecognized build option '$a'" >&2
echo "       run 'make options' for the list of supported options" >&2
exit 2
fi
done

echo "$out"
