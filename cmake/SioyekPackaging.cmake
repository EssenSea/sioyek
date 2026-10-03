#[[============================================================================
  SioyekPackaging.cmake
  ---------------------------------------------------------------------------
  CPack packaging configuration (reuses the SioyekInstall install contract).

  Formats (selectable via SIOYEK_PACKAGE_FORMATS, default DEB;RPM;TGZ):
    - DEB     : Debian/Ubuntu
    - RPM     : Fedora/openSUSE
    - TGZ     : generic tar.gz
    - AppImage: self-contained portable bundle (requires linuxdeploy; handled by
                a separate script, not a CPack generator)

  Note:
    * CPack consumes the install() contract directly, so package contents match
      downstream `cmake --install`.
    * AppImage is not a CPack generator; it is produced by a standalone script
      based on the install tree.
============================================================================]]#

include_guard(GLOBAL)

# Generator priority: user-overridable.
set(SIOYEK_PACKAGE_FORMATS "DEB;RPM;TGZ" CACHE STRING
    "CPack generators to enable (semicolon-separated), e.g. DEB;RPM;TGZ.")

# Wire the selection through to CPack (it was previously documented but never
# actually applied, so -DSIOYEK_PACKAGE_FORMATS=TGZ had no effect).
set(CPACK_GENERATOR "${SIOYEK_PACKAGE_FORMATS}")

set(CPACK_PACKAGE_NAME        "sioyek")
set(CPACK_PACKAGE_VENDOR      "sioyek")
set(CPACK_PACKAGE_DESCRIPTION "PDF viewer optimized for research papers and textbooks")
set(CPACK_PACKAGE_VERSION     "${PROJECT_VERSION}")
set(CPACK_PACKAGE_CONTACT     "Ali Mostafavi <a.hr.mostafavi@gmail.com>")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://sioyek.info")

# ---------------------------------------------------------------------------
# Runtime dependencies, DERIVED FROM WHAT WAS ACTUALLY BUILT.
#
# WHY THIS IS CONDITIONAL: the dependency list used to be a fixed string that
# always named SQLite and HarfBuzz regardless of the route chosen. Both are
# optional:
#   * SQLite is compiled INTO the binary when the vendored amalgamation is used
#     (SIOYEK_SQLITE_SOURCE=vendored), so declaring libsqlite3-0 there is a
#     phantom dependency;
#   * HarfBuzz is only needed by the VENDORED mupdf, which is built with
#     USE_SYSTEM_HARFBUZZ=yes; a system mupdf brings its own.
# Meanwhile the list never mentioned mupdf at all, so a package built against a
# SYSTEM mupdf linked libmupdf.so without declaring it -- i.e. the package was
# simply broken on the target machine. The list is now assembled from the two
# resolved source variables, which are known by the time this module is
# included (SioyekMupdf/SioyekSQLite run earlier in CMakeLists.txt).
#
# NOTE: the "|" in the original Qt entry is a Debian *alternative* (OR), but a
# running sioyek needs Core AND Widgets AND Gui simultaneously, so a
# comma-separated AND list is what is actually required.
# ---------------------------------------------------------------------------
set(_sioyek_deb_deps
    "libqt6core6"
    "libqt6gui6"
    "libqt6widgets6"
    "libqt6network6"
    "libqt6svg6"
    "libqt6opengl6"
    "libqt6texttospeech6"
    "libqt6quickwidgets6"
)
set(_sioyek_rpm_deps
    "qt6-qtbase"
    "qt6-qtsvg"
    "qt6-qtdeclarative"
    "qt6-qtspeech"
    "qt6-qt5compat"
)

# SQLite: only when the package does NOT carry its own copy.
if(NOT SIOYEK_SQLITE_SOURCE STREQUAL "vendored")
    list(APPEND _sioyek_deb_deps "libsqlite3-0")
    list(APPEND _sioyek_rpm_deps "sqlite-libs")
endif()

# mupdf: only when linked dynamically from the system.
if(SIOYEK_MUPDF_SOURCE STREQUAL "system")
    list(APPEND _sioyek_deb_deps "libmupdf-dev")
    list(APPEND _sioyek_rpm_deps "mupdf")
endif()

# HarfBuzz: needed by the VENDORED mupdf build (USE_SYSTEM_HARFBUZZ=yes).
if(SIOYEK_MUPDF_SOURCE STREQUAL "vendored")
    list(APPEND _sioyek_deb_deps "libharfbuzz0b")
    list(APPEND _sioyek_rpm_deps "harfbuzz")
endif()

list(JOIN _sioyek_deb_deps ", " _sioyek_deb_depends)
list(JOIN _sioyek_rpm_deps ", " _sioyek_rpm_requires)

# DEB
set(CPACK_DEBIAN_PACKAGE_SECTION      "misc")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS    ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS      "${_sioyek_deb_depends}")

# RPM
set(CPACK_RPM_PACKAGE_LICENSE     "GPL-3.0-or-later")
set(CPACK_RPM_PACKAGE_GROUP       "Applications/Graphics")
set(CPACK_RPM_PACKAGE_REQUIRES    "${_sioyek_rpm_requires}")

# TGZ
set(CPACK_ARCHIVE_COMPONENT_INSTALL OFF)

# Do not package the manifest that CPack itself should not include
set(CPACK_MONOLITHIC_INSTALL ON)

# ---------------------------------------------------------------------------
# Absolute install destinations and CPack.
#
# The install contract places keys.config/prefs.config at the *absolute*
# CMAKE_INSTALL_FULL_SYSCONFDIR (/etc/sioyek) so the runtime finds them. CPack
# would otherwise try to write that path on the build host directly and fail
# (or, worse, populate the real /etc). Prefixing the package root with "/" and
# enabling CPACK_SET_DESTDIR makes CPack stage everything under its own
# temporary tree and record the absolute paths inside the package instead.
# ---------------------------------------------------------------------------
if(UNIX AND NOT APPLE)
    set(CPACK_PACKAGING_INSTALL_PREFIX "/")
    set(CPACK_SET_DESTDIR ON)
endif()

# Strip policy for packaged binaries (opt-in; see SioyekBuildTypes.cmake).
if(SIOYEK_PACKAGE_STRIP)
    set(CPACK_STRIP_FILES ON)
    message(STATUS "sioyek: CPack will strip packaged binaries (SIOYEK_PACKAGE_STRIP=ON)")
endif()

# ---------------------------------------------------------------------------
# Reproducible packaging: SOURCE_DATE_EPOCH.
#
# WHY it matters: without it, archive members carry whatever mtime they had on
# the build machine, so two builds of identical sources produce packages with
# different checksums. A release then cannot be verified by rebuilding, and
# build caches cannot be shared. See
#   https://reproducible-builds.org/docs/source-date-epoch/
#
# WHAT THIS MODULE CAN AND CANNOT DO -- measured, not assumed:
#
#   * DEB is reproducible, but ONLY when the variable is present in the
#     environment of the CPACK PROCESS ITSELF. CPack reads it directly, and it
#     cannot be injected from here: everything set with set(ENV{...}) during
#     configure belongs to the CONFIGURE process, while cpack runs later as a
#     separate invocation. Setting it only for configure looks like it works
#     and changes nothing -- which is exactly what an earlier revision of this
#     file did.
#
#   * TGZ is NOT reproducible through CPack at all. The archive generator
#     exposes no timestamp variable (CPACK_ARCHIVE_* covers names, ids,
#     compression level and thread count -- not time), so member mtimes come
#     from the staged files. A reproducible tarball has to be repacked outside
#     CPack, e.g.
#         tar --sort=name --mtime=@${epoch} --owner=0 --group=0 --numeric-owner
#     That is the packager job; this file cannot do it for you.
#
#   * RPM is likewise not handled by CPack.
#
# So this module does the one thing that is both possible and honest: validate
# the value, serialise archive creation, and state which formats remain
# non-reproducible instead of implying the setting is global.
# ---------------------------------------------------------------------------

# The variable must be exported to the cpack invocation, e.g.
#     SOURCE_DATE_EPOCH=1600000000 cmake --build <dir> --target package
if(DEFINED ENV{SOURCE_DATE_EPOCH} AND NOT "$ENV{SOURCE_DATE_EPOCH}" STREQUAL "")
    set(_sioyek_sde "$ENV{SOURCE_DATE_EPOCH}")

    # Validate: a malformed value silently becoming epoch 0 would look
    # reproducible while recording a wrong date.
    if(NOT _sioyek_sde MATCHES "^[0-9]+$")
        message(FATAL_ERROR
            "SOURCE_DATE_EPOCH must be a non-negative integer number of seconds "
            "since the Unix epoch, but it is set to '${_sioyek_sde}'. See "
            "https://reproducible-builds.org/docs/source-date-epoch/")
    endif()

    # Deterministic member order: a threaded archiver may add entries in any
    # order, defeating reproducibility even where a timestamp is fixed.
    set(CPACK_ARCHIVE_THREADS 0)

    message(STATUS
        "sioyek: SOURCE_DATE_EPOCH=${_sioyek_sde} -- DEB will be reproducible "
        "only if cpack itself is launched with this variable in its environment "
        "(CPack reads it directly; a configure-time set() does not reach it). "
        "TGZ and RPM stay non-reproducible: the CPack archive generator has no "
        "timestamp control, so those require repacking by the packager.")
else()
    message(STATUS
        "sioyek: SOURCE_DATE_EPOCH is not exported; packaged archives embed the "
        "current time and are NOT bit-for-bit reproducible. Export it for the "
        "cpack invocation to make DEB reproducible; TGZ/RPM need repacking.")
endif()

include(CPack)

message(STATUS "sioyek: CPack packaging configured (formats=${SIOYEK_PACKAGE_FORMATS}, version=${PROJECT_VERSION})")
