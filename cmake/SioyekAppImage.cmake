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

echo '==> Fetching linuxdeploy if needed'
mkdir -p \"\$TOOLS\"
[ -x \"\$LD\" ]   || { \"\$FETCH\" -q -O \"\$LD\"   '${SIOYEK_LINUXDEPLOY_URL}';    chmod +x \"\$LD\"; }
[ -x \"\$LDQT\" ] || { \"\$FETCH\" -q -O \"\$LDQT\" '${SIOYEK_LINUXDEPLOY_QT_URL}'; chmod +x \"\$LDQT\"; }

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
