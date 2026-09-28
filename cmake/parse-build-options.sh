#!/bin/sh
# Translate friendly build options (--enable-X / --disable-X / --with-X[=V]) into
# -DSIOYEK_* CMake flags. Backed by cmake/options.mk's tables via env vars.
#
# Usage: parse-build-options.sh "<args...>"
# Prints the resulting "-D..." flags on stdout; exits non-zero on unknown option.

set -eu

ARGS="$*"

# name:CMakeVar tables (keep in sync with `make options`).
BOOL_OPTIONS="
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
"
TRISTATE_OPTIONS="
system-mupdf:SIOYEK_USE_SYSTEM_MUPDF
system-sqlite:SIOYEK_USE_SYSTEM_SQLITE
"
VALUE_OPTIONS="
install-layout:SIOYEK_INSTALL_LAYOUT
mupdf-unembed-fonts:SIOYEK_MUPDF_UNEMBED_FONTS
package-formats:SIOYEK_PACKAGE_FORMATS
"

out=""
for a in $ARGS; do
case "$a" in
-*) ;;                      # already has a leading dash
*) a="--$a" ;;              # convenience: enable-lto -> --enable-lto
esac

matched=0

# --enable-X / --disable-X
for pair in $BOOL_OPTIONS; do
key=${pair%%:*}; var=${pair##*:}
case "$a" in
--enable-"$key")  out="$out -D$var=ON";  matched=1 ;;
--disable-"$key") out="$out -D$var=OFF"; matched=1 ;;
esac
done

# --with-X / --without-X / --with-X=VALUE
for pair in $TRISTATE_OPTIONS; do
key=${pair%%:*}; var=${pair##*:}
case "$a" in
--with-"$key")    out="$out -D$var=ON";  matched=1 ;;
--without-"$key") out="$out -D$var=OFF"; matched=1 ;;
--with-"$key"=*)  out="$out -D$var=${a#*=}"; matched=1 ;;
esac
done

# --with-X=VALUE
for pair in $VALUE_OPTIONS; do
key=${pair%%:*}; var=${pair##*:}
case "$a" in
--with-"$key"=*) out="$out -D$var=${a#*=}"; matched=1 ;;
esac
done

# raw -D passthrough
case "$a" in
-D*) out="$out $a"; matched=1 ;;
esac

if [ "$matched" = 0 ]; then
echo "error: unrecognized build option '$a'" >&2
echo "       run 'make options' to list supported --enable/--disable/--with flags" >&2
exit 2
fi
done

echo "$out"
