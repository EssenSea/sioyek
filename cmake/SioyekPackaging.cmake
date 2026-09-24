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

# Generator priority: user-overridable
set(SIOYEK_PACKAGE_FORMATS "DEB;RPM;TGZ" CACHE STRING
    "CPack generators to enable (semicolon-separated), e.g. DEB;RPM;TGZ.")

set(CPACK_PACKAGE_NAME        "sioyek")
set(CPACK_PACKAGE_VENDOR      "sioyek")
set(CPACK_PACKAGE_DESCRIPTION "PDF viewer optimized for research papers and textbooks")
set(CPACK_PACKAGE_VERSION     "${PROJECT_VERSION}")
set(CPACK_PACKAGE_CONTACT     "Ali Mostafavi <a.hr.mostafavi@gmail.com>")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://sioyek.info")

# DEB
set(CPACK_DEBIAN_PACKAGE_SECTION      "misc")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS    ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS      "libqt6core6 | libqt6widgets6, libharfbuzz0b, libsqlite3-0")

# RPM
set(CPACK_RPM_PACKAGE_LICENSE     "GPL-3.0-or-later")
set(CPACK_RPM_PACKAGE_GROUP       "Applications/Graphics")
set(CPACK_RPM_PACKAGE_REQUIRES    "qt6-qtbase, harfbuzz, sqlite-libs")

# TGZ
set(CPACK_ARCHIVE_COMPONENT_INSTALL OFF)

# Do not package the manifest that CPack itself should not include
set(CPACK_MONOLITHIC_INSTALL ON)

# Strip policy for packaged binaries (opt-in; see SioyekBuildTypes.cmake).
if(SIOYEK_PACKAGE_STRIP)
    set(CPACK_STRIP_FILES ON)
    message(STATUS "sioyek: CPack will strip packaged binaries (SIOYEK_PACKAGE_STRIP=ON)")
endif()

include(CPack)

message(STATUS "sioyek: CPack packaging configured (formats=${SIOYEK_PACKAGE_FORMATS}, version=${PROJECT_VERSION})")
