#[[============================================================================
  SioyekMupdf.cmake
  ---------------------------------------------------------------------------
  mupdf dependency consumption contract.

  Goals:
    * Hide the differences between "vendored static libs" and "system shared lib"
      behind a single interface target `mupdf`.
    * sioyek directly reads public mupdf struct fields (ABI-level coupling), so a
      system mupdf may only be used within an empirically verified version range;
      otherwise fall back to the vendored build.

  Version policy (based on upstream research):
    - verified range:  1.26.11 <= v < 1.27
    - extended range:  1.26.11 <= v < 1.29   (only when escape hatch is enabled)
    * inside verified range          -> use system mupdf
    * system not installed           -> fall back to vendored
    * system out of range            -> vendored (default) / error (explicit ON) /
                                        force system (escape hatch)
    * SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF=ON -> use system within extended range

  Outputs:
    - target `mupdf` (INTERFACE), used via
      target_link_libraries(sioyek PRIVATE mupdf)
    - SIOYEK_MUPDF_SOURCE = "system" | "vendored"
============================================================================]]#

include_guard(GLOBAL)

include(ExternalProject)
include(FindPackageHandleStandardArgs)
include(SioyekDependencies)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
set(SIOYEK_USE_SYSTEM_MUPDF "AUTO" CACHE STRING
    "Use system-provided mupdf instead of the vendored submodule. \
AUTO: prefer system when its version is within the verified range, else vendored. \
ON: require a system mupdf (error if unavailable/out of range). \
OFF: always build the vendored mupdf.")
set_property(CACHE SIOYEK_USE_SYSTEM_MUPDF PROPERTY STRINGS AUTO ON OFF)

option(SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF
    "Allow using a system mupdf whose version is outside the verified range (escape hatch)."
    OFF)

# mupdf embeds several font groups: CJK (han/*.ttc + droid/*.ttf, ~32 MB),
# Noto (~13 MB) and SIL (~0.2 MB). Unembedding them
# substantially shrinks the vendored binary at the cost of relying on system
# fonts for missing glyphs. Only affects the vendored route.
#   OFF (default) - keep all embedded fonts
#   CJK           - drop CJK collection fonts (han/*.ttc, droid fallback)
#   CJK_LANG      - drop only han/*.ttc
#   ALL           - drop as many embedded fonts as mupdf allows (-DTOFU)
set(SIOYEK_MUPDF_UNEMBED_FONTS "OFF" CACHE STRING
    "Unembed fonts from vendored mupdf to reduce binary size (OFF/CJK/CJK_LANG/ALL).")
set_property(CACHE SIOYEK_MUPDF_UNEMBED_FONTS PROPERTY STRINGS OFF CJK CJK_LANG ALL)

# Verified range (inclusive lower bound, exclusive upper bound)
set(SIOYEK_MUPDF_VERIFIED_MIN "1.26.11")
set(SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE "1.27")

# Extended range (only effective when the escape hatch is enabled)
set(SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE "1.29")

# ---------------------------------------------------------------------------
# Helper: version range check
#   _sioyek_mupdf_version_in_range(<out> <version> <min> <max_exclusive>)
# ---------------------------------------------------------------------------
function(_sioyek_mupdf_version_in_range out_var version vmin vmax)
    if(version VERSION_LESS vmin)
        set(${out_var} FALSE PARENT_SCOPE)
    elseif(NOT version VERSION_LESS vmax)
        set(${out_var} FALSE PARENT_SCOPE)
    else()
        set(${out_var} TRUE PARENT_SCOPE)
    endif()
endfunction()

# verified: [1.26.11, 1.27)
function(_sioyek_mupdf_version_is_verified out_var version)
    _sioyek_mupdf_version_in_range(_ok "${version}"
        "${SIOYEK_MUPDF_VERIFIED_MIN}" "${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}")
    set(${out_var} ${_ok} PARENT_SCOPE)
endfunction()

# extended: [1.26.11, 1.29)  (range covered by the escape hatch)
function(_sioyek_mupdf_version_is_extended out_var version)
    _sioyek_mupdf_version_in_range(_ok "${version}"
        "${SIOYEK_MUPDF_VERIFIED_MIN}" "${SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE}")
    set(${out_var} ${_ok} PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# Step 1: detect system mupdf
# ---------------------------------------------------------------------------
set(_sioyek_system_mupdf_found FALSE)
set(_sioyek_system_mupdf_version "")

find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(PC_MUPDF QUIET mupdf)
    if(PC_MUPDF_FOUND)
        set(_sioyek_system_mupdf_found TRUE)
        set(_sioyek_system_mupdf_version "${PC_MUPDF_VERSION}")
    endif()
endif()

# ---------------------------------------------------------------------------
# Step 2: pick a source based on the tri-state option and version range
# ---------------------------------------------------------------------------
set(_sioyek_use_system FALSE)

if(SIOYEK_USE_SYSTEM_MUPDF STREQUAL "OFF")
    # Force vendored
    set(_sioyek_use_system FALSE)

elseif(NOT _sioyek_system_mupdf_found)
    # System not available
    if(SIOYEK_USE_SYSTEM_MUPDF STREQUAL "ON")
        message(FATAL_ERROR
            "SIOYEK_USE_SYSTEM_MUPDF=ON but no system mupdf was found (pkg-config did not provide mupdf).\n"
            "Install a mupdf development package, or set SIOYEK_USE_SYSTEM_MUPDF to AUTO/OFF to use the vendored version.")
    endif()
    set(_sioyek_use_system FALSE)

else()
    # System available -> range check
    #   verified : [1.26.11, 1.27) -> use system directly
    #   extended : [1.26.11, 1.29) -> use system only with the escape hatch
    #   out of range (low/high)    -> vendored / error
    _sioyek_mupdf_version_is_verified(_sioyek_verified "${_sioyek_system_mupdf_version}")
    _sioyek_mupdf_version_is_extended(_sioyek_extended "${_sioyek_system_mupdf_version}")

    if(_sioyek_verified)
        set(_sioyek_use_system TRUE)
        message(STATUS "sioyek: system mupdf ${_sioyek_system_mupdf_version} is within the verified range "
                       "[${SIOYEK_MUPDF_VERIFIED_MIN}, ${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}); using the system library.")

    elseif(_sioyek_extended)
        # Within extended range [1.27, 1.29): only the escape hatch can allow it
        if(SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF)
            set(_sioyek_use_system TRUE)
            message(WARNING
                "sioyek: system mupdf ${_sioyek_system_mupdf_version} is within the extended range "
                "[${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}, ${SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE}), "
                "outside the verified range [${SIOYEK_MUPDF_VERIFIED_MIN}, ${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}).\n"
                "         It is accepted because SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF=ON -- this combination has not "
                "been verified upstream and may break due to mupdf public struct layout changes (compile-time or runtime).")
        elseif(SIOYEK_USE_SYSTEM_MUPDF STREQUAL "ON")
            message(FATAL_ERROR
                "SIOYEK_USE_SYSTEM_MUPDF=ON but system mupdf ${_sioyek_system_mupdf_version} is outside the verified range "
                "[${SIOYEK_MUPDF_VERIFIED_MIN}, ${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}).\n"
                "To use a system mupdf within the extended range "
                "[${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}, ${SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE}), set "
                "-DSIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF=ON (at your own risk).\n"
                "Otherwise set -DSIOYEK_USE_SYSTEM_MUPDF=OFF to use the vendored version.")
        else()
            set(_sioyek_use_system FALSE)
            message(STATUS
                "sioyek: detected system mupdf ${_sioyek_system_mupdf_version} within the extended range "
                "[${SIOYEK_MUPDF_VERIFIED_MAX_EXCLUSIVE}, ${SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE}), "
                "but the escape hatch is not enabled; falling back to the vendored mupdf.")
        endif()

    else()
        # Outside the extended range (v < 1.26.11 or v >= 1.29): not covered by the escape hatch either
        if(SIOYEK_USE_SYSTEM_MUPDF STREQUAL "ON")
            message(FATAL_ERROR
                "SIOYEK_USE_SYSTEM_MUPDF=ON but system mupdf ${_sioyek_system_mupdf_version} is outside the acceptable range "
                "[${SIOYEK_MUPDF_VERIFIED_MIN}, ${SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE}).\n"
                "This version is neither verified nor covered by the escape hatch. Use the vendored version "
                "(-DSIOYEK_USE_SYSTEM_MUPDF=OFF) or install a supported system mupdf.")
        else()
            set(_sioyek_use_system FALSE)
            message(STATUS
                "sioyek: detected system mupdf ${_sioyek_system_mupdf_version} outside the acceptable range "
                "[${SIOYEK_MUPDF_VERIFIED_MIN}, ${SIOYEK_MUPDF_EXTENDED_MAX_EXCLUSIVE}); falling back to the vendored mupdf.")
        endif()
    endif()
endif()

# ---------------------------------------------------------------------------
# Step 3: create the unified `mupdf` target
# ---------------------------------------------------------------------------
# An INTERFACE wrapper target pointing to either the system or vendored target.
# Named `mupdf` to match the existing target_link_libraries(sioyek PRIVATE mupdf).

if(_sioyek_use_system)
    # ---- system branch ----
    # The pkg-config IMPORTED target carries library paths, include paths and
    # transitive dependencies (freetype2/openjp2/crypto, etc.).
    pkg_check_modules(MUPDF REQUIRED IMPORTED_TARGET mupdf)

    if(NOT TARGET mupdf)
        add_library(mupdf INTERFACE)
    endif()
    # The system mupdf pkg-config file may not declare all transitive deps (e.g. zlib);
    # sioyek already does find_package(ZLIB), so add it explicitly to ensure complete linking.
    target_link_libraries(mupdf INTERFACE PkgConfig::MUPDF ZLIB::ZLIB)
    set(SIOYEK_MUPDF_SOURCE "system" CACHE INTERNAL "Chosen mupdf source")
    set(SIOYEK_MUPDF_VERSION "${_sioyek_system_mupdf_version}" CACHE INTERNAL "Chosen mupdf version")

else()
    # ---- vendored branch ----
    # Precondition check: mupdf sources and headers must be present.
    # NOTE: we do NOT FATAL_ERROR here, so that:
    #   - CTest contract tests can still be registered and run (they do not
    #     depend on mupdf sources);
    #   - the error is deferred to "actually building the sioyek target", with
    #     a clear message.
    set(_sioyek_mupdf_src "${CMAKE_CURRENT_SOURCE_DIR}/mupdf")
    set(_sioyek_mupdf_src_ok TRUE)
    if(NOT EXISTS "${_sioyek_mupdf_src}/Makefile")
        set(_sioyek_mupdf_src_ok FALSE)
    endif()
    if(NOT EXISTS "${_sioyek_mupdf_src}/include/mupdf/fitz.h")
        set(_sioyek_mupdf_src_ok FALSE)
    endif()

    if(NOT _sioyek_mupdf_src_ok)
        message(WARNING
            "Vendored mupdf sources/headers are missing: ${_sioyek_mupdf_src}\n"
            "  To use the vendored mupdf, run first:\n"
            "      git submodule update --init --recursive\n"
            "  (mupdf's thirdparty submodules are also required, otherwise its make cannot build.)\n"
            "  Configuration will continue (so CTest contract tests can run), but building the sioyek target will fail.\n"
            "  If you only intend to run contract tests, you can ignore this warning.")
    endif()

    set(_sioyek_mupdf_out "${CMAKE_CURRENT_BINARY_DIR}/mupdf-out")
    set(_sioyek_mupdf_lib      "${_sioyek_mupdf_out}/libmupdf.a")
    set(_sioyek_mupdf_third    "${_sioyek_mupdf_out}/libmupdf-third.a")
    set(_sioyek_mupdf_threads  "${_sioyek_mupdf_out}/libmupdf-threads.a")

    # Unified INTERFACE target
    if(NOT TARGET mupdf)
        add_library(mupdf INTERFACE)
    endif()

    if(_sioyek_mupdf_src_ok)
        # mupdf ships its own GNU Make build system, which uses make-variable
        # syntax (e.g. "libs OUT=... HAVE_GLUT=no"). This is NOT compatible with
        # CMAKE_MAKE_PROGRAM when that is Ninja (ninja has different options and
        # a bare "-j" is invalid). So locate a real GNU make explicitly.
        find_program(SIOYEK_MUPDF_MAKE
            NAMES gmake make
            DOC "GNU make used to build the vendored mupdf")
        if(NOT SIOYEK_MUPDF_MAKE)
            message(FATAL_ERROR
                "GNU make (gmake/make) is required to build the vendored mupdf, but it was not found.\n"
                "Install the make package, or use -DSIOYEK_USE_SYSTEM_MUPDF=ON with a system mupdf.")
        endif()

        # -------------------------------------------------------------------
        # Parallelism for mupdf's own make.
        #
        # IMPORTANT: `cmake --build --preset <p> -j<N>` does NOT propagate <N>
        # to mupdf. The `-j` there is a *client* (cmake driver) option that only
        # tells the underlying generator (ninja/make) how many jobs to run; it
        # is not exported as a CMake variable nor placed in the environment of
        # the custom commands. Ninja additionally schedules via its own job
        # pool and does not advertise the parallelism to child processes at all,
        # so a vendored mupdf build cannot observe `-j<N>` from `cmake --build`.
        #
        # What *does* work, in priority order:
        #   1. SIOYEK_MUPDF_JOBS in the environment at configure time (escape
        #      hatch; also usable non-interactively in CI);
        #   2. CMAKE_BUILD_PARALLEL_LEVEL, either as a configure-time cache
        #      variable (-DCMAKE_BUILD_PARALLEL_LEVEL=N) or in the configure
        #      environment (CMAKE_BUILD_PARALLEL_LEVEL=N cmake ...). When used
        #      as an environment variable it also becomes the default
        #      parallelism of `cmake --build` itself, so this is the closest
        #      thing to "inherit -j from the outer build";
        #   3. automatic detection of the online CPU count, so a plain
        #      `cmake --preset linux-vendored && cmake --build ...` does not
        #      silently fall back to a single-threaded mupdf build.
        #
        # The value is baked into the generated build script at configure time.
        # -------------------------------------------------------------------
        set(_sioyek_mupdf_jobs "")
        if(DEFINED ENV{SIOYEK_MUPDF_JOBS} AND NOT "$ENV{SIOYEK_MUPDF_JOBS}" STREQUAL "")
            set(_sioyek_mupdf_jobs "$ENV{SIOYEK_MUPDF_JOBS}")
            set(_sioyek_mupdf_jobs_src "SIOYEK_MUPDF_JOBS env")
        elseif(CMAKE_BUILD_PARALLEL_LEVEL OR (DEFINED ENV{CMAKE_BUILD_PARALLEL_LEVEL}
                AND NOT "$ENV{CMAKE_BUILD_PARALLEL_LEVEL}" STREQUAL ""))
            # Prefer the cache/normal variable; fall back to the environment
            # variable (which cmake --build also honours as its default -j).
            if(CMAKE_BUILD_PARALLEL_LEVEL)
                set(_sioyek_mupdf_jobs "${CMAKE_BUILD_PARALLEL_LEVEL}")
                set(_sioyek_mupdf_jobs_src "CMAKE_BUILD_PARALLEL_LEVEL variable")
            else()
                set(_sioyek_mupdf_jobs "$ENV{CMAKE_BUILD_PARALLEL_LEVEL}")
                set(_sioyek_mupdf_jobs_src "CMAKE_BUILD_PARALLEL_LEVEL env")
            endif()
        else()
            include(ProcessorCount)
            ProcessorCount(_sioyek_mupdf_detected_jobs)
            if(NOT _sioyek_mupdf_detected_jobs EQUAL 0)
                set(_sioyek_mupdf_jobs "${_sioyek_mupdf_detected_jobs}")
                set(_sioyek_mupdf_jobs_src "auto-detected CPU count")
            else()
                set(_sioyek_mupdf_jobs 1)
                set(_sioyek_mupdf_jobs_src "fallback (CPU count unknown)")
            endif()
        endif()
        message(STATUS "sioyek: vendored mupdf will build with -j${_sioyek_mupdf_jobs} (${_sioyek_mupdf_jobs_src}; "
                       "set SIOYEK_MUPDF_JOBS to override)")

        # Because we build mupdf with USE_SYSTEM_HARFBUZZ=yes, the produced
        # libmupdf.a references HarfBuzz symbols and must be linked against the
        # system HarfBuzz. Use the unified resolver (config -> module -> pkg-config),
        # since distros ship it in different forms (Ubuntu: only harfbuzz.pc).
        # HarfBuzz is a hard requirement for a vendored mupdf build, so fail fast.
        sioyek_find_dependency(
            NAME         HarfBuzz
            PKG_NAMES    harfbuzz
            OUT_TARGET   _sioyek_harfbuzz_target
            OUT_VERSION  _sioyek_harfbuzz_version)
        if(NOT _sioyek_harfbuzz_target)
            message(FATAL_ERROR
                "HarfBuzz is required to link the vendored mupdf (built with USE_SYSTEM_HARFBUZZ=yes),\n"
                "but it was not found. Install the HarfBuzz development package, or use "
                "-DSIOYEK_USE_SYSTEM_MUPDF=ON with a system mupdf that bundles HarfBuzz.")
        endif()

        # Font unembedding flags (applied via XCFLAGS to mupdf's own make).
        set(_sioyek_mupdf_xcflags "")
        if(SIOYEK_MUPDF_UNEMBED_FONTS STREQUAL "CJK")
            set(_sioyek_mupdf_xcflags "-DTOFU_CJK")
        elseif(SIOYEK_MUPDF_UNEMBED_FONTS STREQUAL "CJK_LANG")
            set(_sioyek_mupdf_xcflags "-DTOFU_CJK_LANG")
        elseif(SIOYEK_MUPDF_UNEMBED_FONTS STREQUAL "ALL")
            # mupdf's -DTOFU excludes only noto/ + sil/; combine it with
            # -DTOFU_CJK (han + droid) to drop every embedded font group.
            set(_sioyek_mupdf_xcflags "-DTOFU -DTOFU_CJK")
        endif()
        if(_sioyek_mupdf_xcflags)
            message(STATUS "sioyek: vendored mupdf font unembedding enabled (${_sioyek_mupdf_xcflags})")
        endif()

        # -------------------------------------------------------------------
        # Drive mupdf's own make to build the static libs.
        #
        # Robustness measures (see the "mupdf build race" note below):
        #
        #  1. Pre-create the entire output directory tree. mupdf's recipes create
        #     each object's directory lazily with `mkdir -p $(dir $@) ; cc -MMD ...`.
        #     When several objects that live in the same (deep) directory are
        #     built by more than one make/goal at once, the `-MMD` dependency-file
        #     write can race the `mkdir -p` and fail with:
        #         cc: fatal error: opening dependency file
        #             .../mupdf-out/thirdparty/brotli/c/enc/backward_references.d:
        #             No such file or directory
        #     Creating the tree up front makes those `mkdir -p` calls no-ops, so
        #     the dependency-file path always exists.
        #
        #  2. Run the build through `cmake -E env` with the make job-server /
        #     parallel environment variables cleared. Even though we pass -j, some
        #     make versions honor MAKEFLAGS/GNUMAKEFLAGS/MFLAGS inherited from the
        #     outer build, which can silently re-enable parallelism and re-open the
        #     race above. Clearing them makes the requested -j authoritative.
        #
        #  3. Build `libs` and `libmupdf-threads` in a single make invocation
        #     (they share the THIRD_* object list, so spawning two invocations
        #     would double-drive the same recipes).
        #
        # The tree mirror is derived from the actual source layout so it stays
        # correct when mupdf adds/removes files.
        # -------------------------------------------------------------------
        file(GLOB_RECURSE _sioyek_mupdf_all_src
            "${_sioyek_mupdf_src}/source/*.c"
            "${_sioyek_mupdf_src}/source/*.cc"
            "${_sioyek_mupdf_src}/source/*.cpp"
            "${_sioyek_mupdf_src}/thirdparty/brotli/*.c"
            "${_sioyek_mupdf_src}/thirdparty/freetype/*.c"
            "${_sioyek_mupdf_src}/thirdparty/gumbo-parser/*.c"
            "${_sioyek_mupdf_src}/thirdparty/harfbuzz/*.cc"
            "${_sioyek_mupdf_src}/thirdparty/libjpeg/*.c"
            "${_sioyek_mupdf_src}/thirdparty/lcms2/*.c"
            "${_sioyek_mupdf_src}/thirdparty/mujs/*.c"
            "${_sioyek_mupdf_src}/thirdparty/zlib/*.c"
        )
        set(_sioyek_mupdf_mkdirs "")
        foreach(_src IN LISTS _sioyek_mupdf_all_src)
            file(RELATIVE_PATH _rel "${_sioyek_mupdf_src}" "${_src}")
            get_filename_component(_reldir "${_rel}" DIRECTORY)
            # Object files mirror the source path under OUT.
            list(APPEND _sioyek_mupdf_mkdirs "${_sioyek_mupdf_out}/${_reldir}")
        endforeach()
        # Also cover the generated-resource and helper directories used by the
        # Makefile (not derivable from the globs above).
        list(APPEND _sioyek_mupdf_mkdirs
            "${_sioyek_mupdf_out}"
            "${_sioyek_mupdf_out}/generated"
            "${_sioyek_mupdf_out}/source/helpers/mu-threads"
        )
        list(REMOVE_DUPLICATES _sioyek_mupdf_mkdirs)

        # Write a small, self-contained build script. Passing a long, quoted,
        # multi-line shell snippet through ExternalProject/BUILD_COMMAND is
        # fragile (CMake re-splits it on spaces and the quoting gets mangled by
        # the generator). A generated script file sidesteps all of that and can
        # be inspected/debugged by packagers.
        set(_sioyek_mupdf_build_script "${CMAKE_CURRENT_BINARY_DIR}/sioyek_mupdf_build.sh")
        set(_sioyek_mupdf_build_body "")
        foreach(_d IN LISTS _sioyek_mupdf_mkdirs)
            string(APPEND _sioyek_mupdf_build_body "mkdir -p '${_d}'\n")
        endforeach()
        string(APPEND _sioyek_mupdf_build_body
            "exec '${SIOYEK_MUPDF_MAKE}' -C '${_sioyek_mupdf_src}' -j${_sioyek_mupdf_jobs} "
            "libs libmupdf-threads "
            "OUT='${_sioyek_mupdf_out}' "
            "HAVE_GLUT=no HAVE_X11=no USE_SYSTEM_HARFBUZZ=yes "
            "XCFLAGS='${_sioyek_mupdf_xcflags}'\n")
        file(GENERATE OUTPUT "${_sioyek_mupdf_build_script}"
             CONTENT "#!/bin/sh\n${_sioyek_mupdf_build_body}")

        ExternalProject_Add(sioyek_mupdf_ep
            SOURCE_DIR        "${_sioyek_mupdf_src}"
            CONFIGURE_COMMAND ""
            # Run mupdf's make in its own source directory (-C); its Makefile
            # lives at the source root, not in the ExternalProject build dir.
            #
            # MAKEFLAGS/MFLAGS/GNUMAKEFLAGS/MAKELEVEL are cleared so the requested
            # -j is authoritative and no outer parallel job server leaks in.
            BUILD_COMMAND
                ${CMAKE_COMMAND} -E env
                    "MAKEFLAGS="
                    "MFLAGS="
                    "GNUMAKEFLAGS="
                    "MAKELEVEL="
                    /bin/sh "${_sioyek_mupdf_build_script}"
            BUILD_IN_SOURCE   FALSE
            BUILD_BYPRODUCTS
                "${_sioyek_mupdf_lib}"
                "${_sioyek_mupdf_third}"
                "${_sioyek_mupdf_threads}"
            INSTALL_COMMAND   ""
            UPDATE_COMMAND    ""
            USES_TERMINAL_BUILD TRUE
        )

        # IMPORTED static target pointing at the produced artifacts
        add_library(sioyek_mupdf_static STATIC IMPORTED GLOBAL)
        set_target_properties(sioyek_mupdf_static PROPERTIES
            IMPORTED_LOCATION "${_sioyek_mupdf_lib}"
            INTERFACE_INCLUDE_DIRECTORIES "${_sioyek_mupdf_src}/include"
            INTERFACE_LINK_LIBRARIES
                "${_sioyek_mupdf_third};${_sioyek_mupdf_threads};${_sioyek_harfbuzz_target};ZLIB::ZLIB;${CMAKE_DL_LIBS}"
        )
        add_dependencies(sioyek_mupdf_static sioyek_mupdf_ep)
        target_link_libraries(mupdf INTERFACE sioyek_mupdf_static)
    else()
        # Sources missing: provide a placeholder target that fails at build time.
        # Configuration can continue (so CTest contract tests run); building the
        # sioyek target fails here with a clear message.
        add_custom_target(sioyek_mupdf_missing ALL
            COMMAND ${CMAKE_COMMAND} -E echo
                "[error] vendored mupdf sources are missing; cannot build."
            COMMAND ${CMAKE_COMMAND} -E echo
                "Run: git submodule update --init --recursive"
            COMMAND ${CMAKE_COMMAND} -E false
            VERBATIM
        )
        add_library(sioyek_mupdf_static INTERFACE)
        target_include_directories(sioyek_mupdf_static INTERFACE "${_sioyek_mupdf_src}/include")
        add_dependencies(sioyek_mupdf_static sioyek_mupdf_missing)
        target_link_libraries(mupdf INTERFACE sioyek_mupdf_static)
    endif()

    set(SIOYEK_MUPDF_SOURCE "vendored" CACHE INTERNAL "Chosen mupdf source")
    set(SIOYEK_MUPDF_VERSION "1.26.11" CACHE INTERNAL "Chosen mupdf version")

    if(NOT _sioyek_mupdf_src_ok)
        message(STATUS "sioyek: vendored mupdf sources missing; building the sioyek target will fail (see warning above).")
    endif()
endif()

message(STATUS "sioyek: mupdf consumption contract -> source=${SIOYEK_MUPDF_SOURCE}, version=${SIOYEK_MUPDF_VERSION}")
