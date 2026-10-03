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
# Every option whose domain is genuinely bounded is listed here, so a typo
# fails at configure time with the allowed set rather than silently reaching
# CMake (where an unrecognised value is frequently treated as a false-y boolean
# and therefore *disables* the feature the user meant to enable).
#
# Options intentionally absent:
#   package-formats -- it is a comma-separated *list*, so it is validated by
#   the dedicated check below (the ENUMS syntax is comma-delimited and cannot
#   express a member that itself contains commas);
#   the installation directories, which accept arbitrary paths.
ENUMS="
lto:ON,OFF
tests:ON,OFF
unity-build:ON,OFF
size-optimizations:ON,OFF
hidden-visibility:ON,OFF
strip-on-install:ON,OFF
package-strip:ON,OFF
allow-unverified-system-mupdf:ON,OFF
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

# Reject a value that cannot survive the "config.mk -> make -> -D flag"
# round-trip without changing meaning.
#
# SECURITY / CORRECTNESS CONTRACT
# -------------------------------
# ./configure records values into config.mk, which the top-level Makefile pulls
# in with `include`. GNU make performs *textual* expansion on every line it
# reads, so a recorded value is re-interpreted by make before it ever reaches
# CMake. Two distinct hazards follow:
#
#   (a) COMMAND EXECUTION. In a makefile, "$(shell ...)" is expanded while the
#       makefile is being *parsed* -- no target needs to be built. A value such
#       as --enable-lto='$(shell touch /x)' would therefore run an arbitrary
#       command on the next `make`. The same applies to "${...}" (make
#       variable reference), backticks evaluated by any shell that reads the
#       file, and shell metacharacters (; | & < > newline) if the value ever
#       reaches a recipe.
#
#   (b) SILENT VALUE CORRUPTION. A bare '$' is expanded by make as a variable
#       reference: --prefix='$HOME' would silently become 'OME' (make reads
#       '$H' as a variable, finds it empty, keeps 'OME'). The value that
#       reaches CMake is then *not* the value the user typed.
#
# Both are prevented by (1) rejecting the dangerous character set outright and
# (2) escaping '$' as '$$' on output, which is make's own escape for a
# literal dollar and is exactly what a value crossing a makefile boundary
# requires. Escaping happens in _emit_flag (see below), so every caller is
# covered by construction rather than by remembering to do it.
#
# Rejected characters: whitespace, both quote characters, '$', backtick,
# backslash, and the shell metacharacters ; | & < > ( ) { } * ? [ ] ! ~ # and
# newline. The remaining accepted set is deliberately narrow: it covers every
# legitimate value this build system actually uses (ON/OFF/AUTO, the ENUMS
# tables, 'standard'/'portable', 'DEB;RPM;TGZ'-style lists are supplied via the
# dedicated --package-formats enum-free option, absolute/relative install
# directories such as /usr, /etc, share, lib64).
_validate_value() {
_vn=$1
_vv=$2
case "$_vv" in
"")
    echo "error: option '--$_vn' was given an empty value" >&2
    exit 2
    ;;
esac
# One case-pattern covers every rejected character; the message names the
# offending character so the failure is actionable.
_bad=""
case "$_vv" in
*[[:space:]]*) _bad="whitespace" ;;
*\"*|*\'*)    _bad="a quote" ;;
*\$*)          _bad="'\$' (make would expand it as a variable)" ;;
*\`*)         _bad="a backtick" ;;
*\\*)         _bad="a backslash" ;;
*\;*)          _bad="';'" ;;
*\|*)          _bad="'|'" ;;
*\&*)          _bad="'&'" ;;
*\<*|*\>*)    _bad="'<' or '>'" ;;
*\(*|*\)*)    _bad="a parenthesis" ;;
*\{*|*\}*)    _bad="a brace" ;;
*\**|*\?*)    _bad="a glob character ('*' or '?')" ;;
*\[*|*\]*)    _bad="a bracket" ;;
*\!*|*\~*)    _bad="'!' or '~'" ;;
*\#*)          _bad="'#'" ;;
esac
if [ -n "$_bad" ]; then
    echo "error: option '--$_vn' value '$_vv' contains $_bad" >&2
    echo "       values must be a single plain token: they are recorded in config.mk," >&2
    echo "       which make re-expands -- see cmake/README.md ('Why values are validated')." >&2
    exit 2
fi
# Enforce the ENUMS table, if any, for this option.
#
# Comparison is case-insensitive and performed on the NORMALISED value, so the
# autoconf spellings users reasonably expect (--enable-lto=yes, --disable-lto=1,
# --with-system-mupdf=auto) are accepted and canonicalised rather than rejected
# as "invalid value 'yes'". Only ON/OFF/AUTO/standard/portable-style canonical
# values are ever emitted; the loose spellings are purely input aliases.
for _ep in $ENUMS; do
    _ek=${_ep%%:*}
    _ev=$(echo "${_ep#*:}" | tr ',' ' ')
    if [ "$_ek" = "$_vn" ]; then
        _ok=0
        _vnorm=$(_normalize_value "$_vv" | tr '[:upper:]' '[:lower:]')
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

# CPack generators accepted by --package-formats, as a space-separated
# whitelist. Members are separated by COMMAS on the command line and converted
# to CMake's semicolon list syntax by the caller; a literal ';' is rejected by
# _validate_value, which is what makes the conversion necessary.
SIOYEK_CPACK_GENERATORS="DEB RPM TGZ ZIP"

# Validate a comma-separated generator list against SIOYEK_CPACK_GENERATORS.
# Usage: _validate_generator_list <option-name> <value>
_validate_generator_list() {
_vg_name=$1
_vg_val=$2
# Split on commas without invoking external tools.
# Reject a leading, trailing or doubled comma up front: those produce an empty
# member, which would silently become an empty element in the CMake list.
case "$_vg_val" in
,*|*,|*,,*)
    echo "error: option '--$_vg_name' value '$_vg_val' has an empty list member" >&2
    exit 2
    ;;
esac
_vg_rest="$_vg_val"
while [ -n "$_vg_rest" ]; do
    case "$_vg_rest" in
    *,*) _vg_item=${_vg_rest%%,*}; _vg_rest=${_vg_rest#*,} ;;
    *)   _vg_item=$_vg_rest; _vg_rest="" ;;
    esac
    _vg_ok=0
    for _vg_known in $SIOYEK_CPACK_GENERATORS; do
        [ "$_vg_item" = "$_vg_known" ] && { _vg_ok=1; break; }
    done
    if [ "$_vg_ok" = 0 ]; then
        echo "error: invalid generator '$_vg_item' in --$_vg_name (allowed: $SIOYEK_CPACK_GENERATORS)" >&2
        exit 2
    fi
done
return 0
}

# Emit one "-D<var>=<value>" token, escaped for safe travel through make.
#
# '$$' is make's escape for a literal '$'. Any '$' in a recorded value is
# doubled so that after make's expansion the *original* text reaches CMake
# unchanged. Today _validate_value() already rejects '$' outright, so this
# escaping is normally a no-op; it is kept as defence in depth so that a future
# relaxation of the character set cannot silently reintroduce the corruption
# described in (b) above.
_emit_flag() {
_ef_var=$1
_ef_val=$2
_ef_escaped=$(printf '%s' "$_ef_val" | sed 's/\$/\$\$/g')
out="$out -D$_ef_var=$_ef_escaped"
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
# Same validated, escaped emission as the feature options: an install
# directory is recorded in config.mk and re-expanded by make too.
_validate_value "$dkey" "$dval"
_emit_flag "$v" "$dval"
matched=1
break
fi
done
;;
esac

# Split "key" and optional "=VALUE".
key=${a#--}
val=""
val_set=0
case "$key" in
*=*) val=${key#*=}; key=${key%%=*}; val_set=1 ;;
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
# Distinguish "no '=' at all" (a plain direction flag: --enable-X) from
# "an '=' with an empty right-hand side" (--enable-X=). The former is the
# normal boolean form; the latter is a user error that must not be silently
# reinterpreted as ON. This mirrors the install-directory branch above, which
# has always rejected an empty value.
if [ "$val_set" = 1 ]; then
# explicit value wins over the prefix direction
_validate_value "$name" "$val"
_norm=$(_normalize_value "$val")
# SIOYEK_PACKAGE_FORMATS is a CMake *list* (semicolon-separated). A literal
# ';' cannot be carried through config.mk -> make -> -D safely (make would treat
# it as a recipe separator in some contexts, and it is rejected by
# _validate_value), so this one option is written by the user with commas and
# translated to CMake's own list syntax here. '\,' is the ENUMS-escaped comma.
if [ "$name" = "package-formats" ]; then
    _validate_generator_list "$name" "$_norm"
    _norm=$(printf '%s' "$_norm" | tr ',' ';')
fi
_emit_flag "$var" "$_norm"
else
case "$dir" in
enable|with)    _emit_flag "$var" "ON" ;;
disable|without) _emit_flag "$var" "OFF" ;;
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
