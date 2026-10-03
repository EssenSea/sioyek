#[[============================================================================
  SioyekAppImage.cmake
  ---------------------------------------------------------------------------
  Self-contained AppImage packaging, as a CMake target.

  AppImage is not a CPack generator, so this module generates a shell script that
  drives linuxdeploy (+ its Qt plugin) and exposes it as the `appimage` target:

      cmake --build build/linux-appimage --target appimage

  The top-level Makefile's `make appimage` is a thin forwarder to that target, so
  all build/packaging logic lives in CMake.

  Outputs (relative to the build directory):
    appimage/AppDir/...     staged install tree (via the install contract)
    appimage/*.AppImage     the produced AppImage
  Tools are downloaded on demand into build/tools (network required).

  Option:
    SIOYEK_BUILD_APPIMAGE (default OFF) -- register the `appimage` target. It is
    OFF by default so ordinary builds do not require a working linuxdeploy; the
    linux-appimage entry point enables it.
============================================================================]]#

include_guard(GLOBAL)

option(SIOYEK_BUILD_APPIMAGE "Register the `appimage` packaging target." OFF)

if(NOT SIOYEK_BUILD_APPIMAGE)
  message(STATUS "sioyek: AppImage target disabled (SIOYEK_BUILD_APPIMAGE=OFF)")
  return()
endif()

if(APPLE OR WIN32)
  message(STATUS "sioyek: AppImage packaging is Linux-only; target not registered")
  return()
endif()

find_program(SIOYEK_WGET NAMES wget curl)
if(NOT SIOYEK_WGET)
  message(FATAL_ERROR
    "SIOYEK_BUILD_APPIMAGE=ON but neither wget nor curl was found "
    "(needed to fetch linuxdeploy).")
endif()

# Allow the output/working locations to be overridden, mirroring the old
# Makefile variables.
set(SIOYEK_APPIMAGE_DIR "${CMAKE_BINARY_DIR}/appimage"
    CACHE PATH "Directory for AppImage staging/output.")
set(SIOYEK_APPIMAGE_TOOLS_DIR "${CMAKE_BINARY_DIR}/tools"
    CACHE PATH "Directory for downloaded linuxdeploy tools.")
set(SIOYEK_LINUXDEPLOY_URL
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20240109-1/linuxdeploy-x86_64.AppImage"
    CACHE STRING "linuxdeploy download URL.")
set(SIOYEK_LINUXDEPLOY_QT_URL
    "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20240109-1/linuxdeploy-plugin-qt-x86_64.AppImage"
    CACHE STRING "linuxdeploy Qt plugin download URL.")

# SHA-256 of the two artifacts above (SLSA: verify what you fetch).
#
# WHY: the fetch step downloads an executable and then runs it. Without an
# integrity check, a compromised release asset, a hijacked upstream account or a
# broken CDN turns directly into arbitrary code execution inside the packaging
# job -- and these tools run on the RELEASE path. Pinning the URL to a release
# tag is not sufficient, because tags and release assets are mutable upstream.
#
# The check is MANDATORY: an empty expected hash is a hard error rather than a
# silent skip, so this cannot degrade into "unverified" by accident, and a
# mismatch aborts the build instead of executing the wrong binary.
#
# HOW TO (RE)DERIVE THESE VALUES when bumping the pin above:
#   curl -sL -o /tmp/ld   <SIOYEK_LINUXDEPLOY_URL>    && sha256sum /tmp/ld
#   curl -sL -o /tmp/ldqt <SIOYEK_LINUXDEPLOY_QT_URL> && sha256sum /tmp/ldqt
# Derive them from an INDEPENDENT download (a different machine or network)
# and confirm both agree, then cross-check against the upstream release notes
# if any are published. The value recorded here was derived from a completed
# download whose hash was stable across repeated reads and whose payload is a
# valid ELF executable; it has NOT been cross-checked against an upstream-
# published digest, because linuxdeploy publishes none for these assets.
# Treat it as TOFU (trust-on-first-use): it pins the bytes you have reviewed,
# and it will catch any later substitution, but it cannot by itself prove that
# the first download was not already malicious.
set(SIOYEK_LINUXDEPLOY_SHA256
    "33af59b89032b5a01ac6e7bcd9d0d91fbc0f8135af17350f9d6c1d680bb23dcd"
    CACHE STRING "Expected SHA-256 of the linuxdeploy AppImage (REQUIRED when SIOYEK_BUILD_APPIMAGE=ON).")
set(SIOYEK_LINUXDEPLOY_QT_SHA256
    "f53349093d333a6558c560844c1a0f64a3b6bd077bf02740af3ad3dbb8827433"
    CACHE STRING "Expected SHA-256 of the linuxdeploy Qt plugin AppImage (REQUIRED when SIOYEK_BUILD_APPIMAGE=ON).")
set(SIOYEK_APPIMAGE_QML_SOURCES
    "${CMAKE_SOURCE_DIR}/pdf_viewer/touchui"
    CACHE PATH "QML sources passed to the linuxdeploy Qt plugin.")

set(_appdir     "${SIOYEK_APPIMAGE_DIR}/AppDir")
set(_tools      "${SIOYEK_APPIMAGE_TOOLS_DIR}")
set(_ld         "${_tools}/linuxdeploy-x86_64.AppImage")
set(_ldqt       "${_tools}/linuxdeploy-plugin-qt-x86_64.AppImage")

# Generate the driver script. It: stages the install tree with DESTDIR, resolves
# the usr/local -> usr layout quirk, fetches linuxdeploy if needed, and runs it.
set(_script "${CMAKE_BINARY_DIR}/sioyek_build_appimage.sh")
# Shell helper embedded into the generated driver script.
#
# It is assembled here, OUTSIDE file(GENERATE), and then interpolated as a whole.
# Writing it inline inside the CONTENT argument does not work: that argument is
# parsed as a CMake argument list, where a semicolon separates LIST ITEMS, so a
# natural multi-statement line such as "_a=$1; _b=$2" silently splits into four
# arguments and CMake reports "Unknown argument to GENERATE subcommand".
# Shell helper embedded into the generated driver script.
#
# The body is assembled with string(JOIN "\n" ...) rather than written inline
# inside file(GENERATE CONTENT ...). Two reasons, both learned the hard way:
#
#   1. That argument is parsed as a CMake ARGUMENT LIST, in which a semicolon
#      separates list items. A natural shell line such as "_a=$1; _b=$2" then
#      splits into four arguments and CMake fails with
#      "Unknown argument to GENERATE subcommand".
#   2. Statements written as separate quoted LIST ITEMS get joined with
#      semicolons, not newlines, which also produces invalid shell.
#
# string(JOIN) makes the separator explicit and keeps the shell readable.
set(_sioyek_fetch_verified_lines
"# Fetch a tool and verify its SHA-256 BEFORE it is made executable."
"# Every failure path is fatal: this runs on the release path, so a binary"
"# that cannot be verified must never be used."
"fetch_verified() {"
"  _name=$1"
"  _dst=$2"
"  _want=$3"
"  _url=$4"
"  if [ -z \"$_want\" ]; then"
"    echo \"error: no expected SHA-256 configured for $_name\" >&2"
"    echo \"       pass -DSIOYEK_LINUXDEPLOY_SHA256 / -DSIOYEK_LINUXDEPLOY_QT_SHA256\" >&2"
"    exit 1"
"  fi"
"  echo \"==> Fetching $_name\""
"  rm -f \"$_dst\""
"  \"$FETCH\" -q -O \"$_dst\" \"$_url\""
"  _have=$(sha256sum \"$_dst\" | cut -d\" \" -f1)"
"  if [ \"$_have\" != \"$_want\" ]; then"
"    echo \"error: SHA-256 MISMATCH for $_name\" >&2"
"    echo \"       expected: $_want\" >&2"
"    echo \"       actual:   $_have\" >&2"
"    echo \"       refusing to execute an unverified binary\" >&2"
"    exit 1"
"  fi"
"  echo \"    verified $_name (sha256 $_have)\""
"  chmod +x \"$_dst\""
"}"
)
set(_sioyek_fetch_verified_script "")
string(JOIN "\n" _sioyek_fetch_verified_script ${_sioyek_fetch_verified_lines})
file(GENERATE OUTPUT "${_script}" CONTENT
"#!/bin/sh
set -eu
APPDIR='${_appdir}'
TOOLS='${_tools}'
LD='${_ld}'
LDQT='${_ldqt}'
SRC='${CMAKE_SOURCE_DIR}'
BUILD='${CMAKE_BINARY_DIR}'
FETCH='${SIOYEK_WGET}'

echo '==> Staging install tree into AppDir'
rm -rf \"\$APPDIR\"
DESTDIR=\"\$APPDIR\" \"${CMAKE_COMMAND}\" --install \"\$BUILD\"
# linuxdeploy expects \$APPDIR/usr/bin; the default prefix installs to usr/local.
if [ -d \"\$APPDIR/usr/local\" ] && [ ! -e \"\$APPDIR/usr/bin\" ]; then
  mv \"\$APPDIR/usr/local\"/* \"\$APPDIR/usr/\" 2>/dev/null || true
  rmdir \"\$APPDIR/usr/local\" 2>/dev/null || true
fi

${_sioyek_fetch_verified_script}
echo '==> Fetching linuxdeploy if needed'
mkdir -p \"\$TOOLS\"
[ -x \"\$LD\" ]   || fetch_verified \"linuxdeploy\"           \"\$LD\"   \"${SIOYEK_LINUXDEPLOY_SHA256}\"    '${SIOYEK_LINUXDEPLOY_URL}'
[ -x \"\$LDQT\" ] || fetch_verified \"linuxdeploy-plugin-qt\" \"\$LDQT\" \"${SIOYEK_LINUXDEPLOY_QT_SHA256}\" '${SIOYEK_LINUXDEPLOY_QT_URL}'

echo '==> Building AppImage'
mkdir -p '${SIOYEK_APPIMAGE_DIR}'
cd \"\$TOOLS\"
QML_SOURCES_PATHS='${SIOYEK_APPIMAGE_QML_SOURCES}' \\
  \"./\$(basename \"\$LD\")\" \\
  --appdir \"\$APPDIR\" \\
  --desktop-file \"\$APPDIR/usr/share/applications/sioyek.desktop\" \\
  --icon-file \"\$APPDIR/usr/share/pixmaps/sioyek-icon-linux.png\" \\
  --plugin qt \\
  --output appimage
mv -f \"\$TOOLS\"/*.AppImage '${SIOYEK_APPIMAGE_DIR}/' 2>/dev/null || true
echo '==> Done. AppImage in ${SIOYEK_APPIMAGE_DIR}'
")

add_custom_target(appimage
  COMMAND /bin/sh "${_script}"
  COMMENT "Packaging a self-contained AppImage"
  VERBATIM)

message(STATUS "sioyek: AppImage target enabled (output=${SIOYEK_APPIMAGE_DIR})")
