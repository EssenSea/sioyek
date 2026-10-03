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
# Runtime-path consistency guard (non-Apple Unix, standard layout).
#
# The application runtime hard-codes the *absolute* lookup paths
#   pdf_viewer/main.cpp:  /etc/sioyek        (default config)
#                         /usr/share/sioyek (shaders, tutorial.pdf)
# when compiled with LINUX_STANDARD_PATHS (set for UNIX AND NOT APPLE in
# CMakeLists.txt). The install() rules below instead derive destinations from
# GNUInstallDirs, which follow CMAKE_INSTALL_PREFIX. The two agree only when
#   CMAKE_INSTALL_FULL_SYSCONFDIR == /etc   and
#   CMAKE_INSTALL_FULL_DATADIR   == /usr/share
# i.e. when the prefix is the conventional `/usr`. With any other prefix the
# installed default config/shaders/tutorial would be invisible to the running
# binary: a silently broken installation.
#
# The presets set CMAKE_INSTALL_PREFIX=/usr, so preset builds are consistent by
# construction. A direct `cmake -S . -B build` uses CMake's default
# /usr/local, which would NOT be consistent; to avoid both a silent bad install
# and a hard block of the documented preset-less workflow, this check:
#   * warns by default (and names the exact fix), and
#   * can be promoted to a hard error with SIOYEK_STRICT_INSTALL_PREFIX=ON
#     (recommended for CI / packaging).
# This is a build-system-only check; the functional/runtime code is untouched.
# ---------------------------------------------------------------------------
option(SIOYEK_STRICT_INSTALL_PREFIX
    "Fail configuration when the 'standard' install prefix is inconsistent with the runtime's hard-coded lookup paths."
    OFF)

if(UNIX AND NOT APPLE AND SIOYEK_INSTALL_LAYOUT STREQUAL "standard")
    # CMAKE_INSTALL_FULL_* are normally defined by GNUInstallDirs; compute a
    # fallback in case the include order ever changes.
    if(NOT DEFINED CMAKE_INSTALL_FULL_SYSCONFDIR)
        set(CMAKE_INSTALL_FULL_SYSCONFDIR "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_SYSCONFDIR}")
    endif()
    if(NOT DEFINED CMAKE_INSTALL_FULL_DATADIR)
        set(CMAKE_INSTALL_FULL_DATADIR "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_DATADIR}")
    endif()

    if(NOT CMAKE_INSTALL_FULL_SYSCONFDIR STREQUAL "/etc"
       OR NOT CMAKE_INSTALL_FULL_DATADIR STREQUAL "/usr/share")
        set(_sioyek_prefix_hint_lines
            "sioyek: the 'standard' install layout will not match the runtime's hard-coded lookup paths, so the installed default config/shaders/tutorial would be silently ineffective."
            "  configured sysconfdir : ${CMAKE_INSTALL_FULL_SYSCONFDIR} (runtime reads /etc)"
            "  configured datadir    : ${CMAKE_INSTALL_FULL_DATADIR} (runtime reads /usr/share)"
            "Use one of:"
            "  * -DCMAKE_INSTALL_PREFIX=/usr (conventional layout, as the presets do), or"
            "  * -DSIOYEK_INSTALL_LAYOUT=portable (resources beside the binary), or"
            "  * explicit -DCMAKE_INSTALL_SYSCONFDIR=etc -DCMAKE_INSTALL_DATADIR=share.")
        string(REPLACE ";" "\n" _sioyek_prefix_hint "${_sioyek_prefix_hint_lines}")
        if(SIOYEK_STRICT_INSTALL_PREFIX)
            message(FATAL_ERROR "${_sioyek_prefix_hint}")
        else()
            message(WARNING "${_sioyek_prefix_hint}")
        endif()
    else()
        message(STATUS
            "sioyek: standard install layout is consistent with the runtime paths "
            "(sysconfdir=${CMAKE_INSTALL_FULL_SYSCONFDIR}, datadir=${CMAKE_INSTALL_FULL_DATADIR})")
    endif()
endif()

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

    # Determine the INSTALL-PREFIX-RELATIVE executable path per platform so we
    # strip the right file. IMPORTANT: the DESTDIR prefix is intentionally NOT
    # baked in here -- it must be resolved at *install time*. Baking
    # $ENV{DESTDIR} at configure time silently drops it (DESTDIR is a make/install
    # variable), which previously made the rule strip the real system path
    # (/usr/bin/sioyek) instead of the staged copy. The generated script below
    # prepends $ENV{DESTDIR} at install time.
    if(APPLE)
        set(_sioyek_strip_install_path
            "${CMAKE_INSTALL_PREFIX}/sioyek.app/Contents/MacOS/sioyek")
    elseif(WIN32)
        set(_sioyek_strip_install_path
            "${CMAKE_INSTALL_FULL_BINDIR}/sioyek.exe")
    else()
        set(_sioyek_strip_install_path
            "${CMAKE_INSTALL_FULL_BINDIR}/sioyek")
    endif()
    string(REPLACE "\\" "/" _sioyek_strip_install_path_unix "${_sioyek_strip_install_path}")

    # A bracket argument ([=[ ... ]=]) avoids all quoting/escaping pitfalls when
    # embedding a CMake script inside install(CODE ...).
    # Build the install-time script. install(CODE ...) is evaluated AT INSTALL
    # TIME, so the configure-time values (tool + binary path) are interpolated
    # here with ${...}, while variables that must live inside the script use
    # escaped \${...}. This avoids the @VAR@ non-substitution and bracket-arg
    # non-interpolation pitfalls.
    set(_sioyek_strip_script
"set(_strip_tool \"${SIOYEK_STRIP_PROGRAM}\")
set(_strip_binary \"\$ENV{DESTDIR}${_sioyek_strip_install_path_unix}\")
message(STATUS \"Stripping: \${_strip_binary}\")
if(NOT EXISTS \"\${_strip_binary}\")
    message(FATAL_ERROR \"SIOYEK_STRIP_ON_INSTALL=ON but '\${_strip_binary}' does not exist; refusing to silently install an unstripped binary. Set -DSIOYEK_STRIP_ON_INSTALL=OFF to install unstripped.\")
endif()
execute_process(COMMAND \"\${_strip_tool}\" \"\${_strip_binary}\" RESULT_VARIABLE _strip_rc)
if(NOT _strip_rc EQUAL 0)
    message(FATAL_ERROR \"stripping '\${_strip_binary}' failed (rc=\${_strip_rc}); refusing to silently install an unstripped binary. Set -DSIOYEK_STRIP_ON_INSTALL=OFF to skip stripping.\")
endif()
")
    install(CODE "${_sioyek_strip_script}")
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

# ---------------------------------------------------------------------------
# Uninstall target.
#
# CMake deliberately does not generate an uninstall rule, but `cmake --install`
# records every file it wrote in install_manifest.txt, so a supported uninstall
# is a replay of that manifest. Without this target a user who ran
# `cmake --install` had no supported way back -- they had to hunt the files
# down by hand, which for the 'standard' layout (which legitimately writes to
# /etc/sioyek) is both tedious and error-prone.
#
# Semantics, matching what a packager expects from `make uninstall`:
#   * reads $DESTDIR-prefixed paths from install_manifest.txt, so an uninstall
#     from a staged tree removes the staged copies and nothing else;
#   * removes only files that were actually installed and still exist;
#   * prunes directories that the install created and that are now empty,
#     walking from deepest to shallowest so parents are considered only after
#     their children -- this is what avoids leaving empty /usr/share/sioyek
#     shells behind, while never deleting a directory that still holds files;
#   * refuses to act when there is no manifest, instead of silently doing
#     nothing (a silent no-op would let a stale install look removed).
#
# The manifest lives in the build directory (CMAKE_BINARY_DIR), not the source
# tree, so this never touches tracked files.
# ---------------------------------------------------------------------------
if(UNIX)
    add_custom_target(uninstall
        COMMAND ${CMAKE_COMMAND} -E env
                "SIOYEK_UNINSTALL_MANIFEST=${CMAKE_BINARY_DIR}/install_manifest.txt"
                ${CMAKE_COMMAND} -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/SioyekUninstall.cmake"
        COMMENT "Removing files installed by the install contract (honours DESTDIR)"
        VERBATIM)
endif()

message(STATUS "sioyek: install contract enabled (layout=${SIOYEK_INSTALL_LAYOUT}, prefix=${CMAKE_INSTALL_PREFIX})")
