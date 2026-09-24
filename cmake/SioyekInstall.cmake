#[[============================================================================
  SioyekInstall.cmake
  ---------------------------------------------------------------------------
  Install contract -- the single authoritative install manifest, reusable by
  downstream packagers.

  Design (must match the runtime path lookup logic in pdf_viewer/main.cpp):
    * standard layout (when LINUX_STANDARD_PATHS is defined):
        binary        -> <prefix>/bin/sioyek
        shaders       -> <prefix>/share/sioyek/shaders
        tutorial.pdf  -> <prefix>/share/sioyek/tutorial.pdf
        keys.config   -> <sysconfdir>/sioyek/keys.config (absolute, i.e. /etc/sioyek)
        prefs.config  -> <sysconfdir>/sioyek/prefs.config (absolute, i.e. /etc/sioyek)
        desktop/icon/man -> standard system locations
    * portable layout:
        resources live beside the binary (the parent dir lookup)
    * macOS: resources go into the bundle's Contents/Resources
    * Windows: executable + runtime libs (handled by the qt deploy script)

  Option:
    SIOYEK_INSTALL_LAYOUT = standard | portable (default standard; non-Apple only)

  Outputs:
    - complete install() rules honoring DESTDIR / CMAKE_INSTALL_PREFIX
    - reusable by CPack
============================================================================]]#

include_guard(GLOBAL)
include(GNUInstallDirs)
include(SioyekBuildTypes)

# ---------------------------------------------------------------------------
# Layout option
# ---------------------------------------------------------------------------
set(SIOYEK_INSTALL_LAYOUT "standard" CACHE STRING
    "Install layout for non-Apple Unix: standard (FHS paths) or portable (resources beside binary).")
set_property(CACHE SIOYEK_INSTALL_LAYOUT PROPERTY STRINGS standard portable)

# ---------------------------------------------------------------------------
# Strip policy (opt-in). CMAKE_INSTALL_DO_STRIP makes `cmake --install` strip
# the installed binaries. Portable/self-contained builds enable this via preset.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Main executable
# ---------------------------------------------------------------------------
install(TARGETS sioyek
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

if(SIOYEK_STRIP_ON_INSTALL)
    # Strip explicitly via an install() rule. Relying on CMAKE_INSTALL_DO_STRIP
    # only works when the user passes `cmake --install --strip`; an explicit rule
    # makes the behavior deterministic for `cmake --install` as well.
    find_program(SIOYEK_STRIP_PROGRAM NAMES strip llvm-strip)
    if(NOT SIOYEK_STRIP_PROGRAM)
        message(FATAL_ERROR "SIOYEK_STRIP_ON_INSTALL=ON but no 'strip' tool was found.")
    endif()
    install(CODE "
        message(STATUS \"Stripping: \$ENV{DESTDIR}${CMAKE_INSTALL_FULL_BINDIR}/sioyek\")
        execute_process(COMMAND \"${SIOYEK_STRIP_PROGRAM}\"
            \"\$ENV{DESTDIR}${CMAKE_INSTALL_FULL_BINDIR}/sioyek\")
    ")
    message(STATUS "sioyek: install will strip binaries (SIOYEK_STRIP_ON_INSTALL=ON, tool=${SIOYEK_STRIP_PROGRAM})")
endif()

# ---------------------------------------------------------------------------
# Platform-specific resources
# ---------------------------------------------------------------------------
if(APPLE)
    # macOS: resources are already packed into the bundle via MACOSX_PACKAGE_LOCATION
    # (handled in CMakeLists.txt). The bundle install is already covered by the
    # install(TARGETS sioyek BUNDLE DESTINATION .) above; nothing more is needed here.

elseif(WIN32)
    # Windows: runtime libraries are handled by qt_generate_deploy_app_script /
    # windeployqt. Any extra runtime DLLs are provided by the downstream or the
    # deploy script. Keep the minimal set here: the executable is installed above.

else()
    # ---- Linux / other Unix ----
    if(SIOYEK_INSTALL_LAYOUT STREQUAL "portable")
        # Portable: resources beside the binary
        install(FILES pdf_viewer/keys.config pdf_viewer/prefs.config
                DESTINATION ${CMAKE_INSTALL_BINDIR})
        install(DIRECTORY pdf_viewer/shaders/
                DESTINATION ${CMAKE_INSTALL_BINDIR}/shaders)
        install(FILES tutorial.pdf
                DESTINATION ${CMAKE_INSTALL_BINDIR})
    else()
        # Standard (FHS) layout: matches the runtime LINUX_STANDARD_PATHS.
        #
        # NOTE on the config destination: the application runtime (main.cpp)
        # reads default config from the ABSOLUTE path `/etc/sioyek`. We must
        # therefore install to GNUInstallDirs' *absolute* sysconfdir
        # (`CMAKE_INSTALL_FULL_SYSCONFDIR`, which is `/etc` when the prefix is
        # `/usr`), NOT the *relative* `${CMAKE_INSTALL_SYSCONFDIR}`.
        #
        # Using the relative form would land the files in `<prefix>/etc/sioyek`
        # (e.g. `/usr/etc/sioyek`), which the binary never looks at: the
        # installed defaults would be silently ineffective for distros that use
        # the conventional `-DCMAKE_INSTALL_PREFIX=/usr`. An absolute
        # destination is still staged correctly under `DESTDIR`.
        install(FILES pdf_viewer/keys.config pdf_viewer/prefs.config
                DESTINATION ${CMAKE_INSTALL_FULL_SYSCONFDIR}/sioyek)
        install(DIRECTORY pdf_viewer/shaders/
                DESTINATION ${CMAKE_INSTALL_DATADIR}/sioyek/shaders)
        install(FILES tutorial.pdf
                DESTINATION ${CMAKE_INSTALL_DATADIR}/sioyek)

        install(FILES resources/sioyek.desktop
                DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
        install(FILES resources/sioyek-icon-linux.png
                DESTINATION ${CMAKE_INSTALL_DATADIR}/pixmaps)
        install(FILES resources/sioyek.1
                DESTINATION ${CMAKE_INSTALL_MANDIR}/man1)
    endif()
endif()

message(STATUS "sioyek: install contract enabled (layout=${SIOYEK_INSTALL_LAYOUT}, prefix=${CMAKE_INSTALL_PREFIX})")
