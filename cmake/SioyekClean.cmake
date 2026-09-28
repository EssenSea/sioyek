#[[============================================================================
  SioyekClean.cmake
  ---------------------------------------------------------------------------
  Clean-up targets.

  CMake's built-in `clean` only removes files inside the current build
  directory; it never removes the build directory itself. This module adds
  explicit clean targets, including one that removes the entire build tree.

  Key detail: a target that runs while its working directory is inside the
  build dir cannot delete it with `rm -rf .` ("Error removing directory").
  However `cmake -E remove_directory <absolute-path>` works even when the cwd
  is inside that directory. We use that to implement a real `distclean`.

  Targets:
    clean-all       - remove the WHOLE build tree (this binary dir) + staging
                      + packages + in-source leftovers + dependency residue,
                      then warn that the build dir is gone
    distclean       - alias of clean-all
    clean-build     - remove the entire top-level build/ tree (all presets)
                      + dependency residue
    clean-deps      - dependency/submodule build residue only (mupdf, zlib)
    clean-packages  - CPack / AppImage artifacts only
    clean-stage     - staged install output only
    clean-in-source - accidental in-source CMake files only

  Safety:
    * only known build outputs are touched; source files are never deleted;
    * authored/tracked files (top-level Makefile, CMakeLists.txt,
      CMakePresets.json) are listed in `_sioyek_protected_files` and asserted
      against the deletion lists at configure time. An earlier revision used to
      delete the hand-written top-level `Makefile`; that must never happen again.
    * submodule residue is removed only under `mupdf/build`, `mupdf/generated`
      and `zlib/build` (never the submodule sources).
============================================================================]]#

include_guard(GLOBAL)

# Repository root (source dir). Build outputs usually live under it.
set(_sioyek_repo_root "${CMAKE_SOURCE_DIR}")

# Staging / packaging outputs (absolute paths).
set(_sioyek_clean_dirs
    "${_sioyek_repo_root}/stage"
    "${_sioyek_repo_root}/sioyek-release"
    "${_sioyek_repo_root}/.qt"
)
set(_sioyek_clean_globs
    "${_sioyek_repo_root}/*.AppImage"
    "${_sioyek_repo_root}/build/*.AppImage"
    "${_sioyek_repo_root}/*.deb"
    "${_sioyek_repo_root}/*.rpm"
    "${_sioyek_repo_root}/*.tar.gz"
    "${_sioyek_repo_root}/build/*.tar.gz"
)
# Accidental in-source CMake files (generated, not authored).
#
# SAFETY: the hand-written top-level `Makefile` is a tracked source file
# (`.gitignore` explicitly keeps it via `!/Makefile`). CMake also generates a
# `Makefile` when configured *in-source* with the Unix Makefiles generator,
# but that is not the case here: the presets always use out-of-source builds
# (and Ninja). We therefore must NEVER delete `Makefile` -- an earlier version
# of this list did, which destroyed the tracked wrapper. Guard it explicitly.
set(_sioyek_insource_files
    "${_sioyek_repo_root}/CMakeCache.txt"
    "${_sioyek_repo_root}/cmake_install.cmake"
    "${_sioyek_repo_root}/CTestTestfile.cmake"
    "${_sioyek_repo_root}/install_manifest.txt"
    "${_sioyek_repo_root}/CPackConfig.cmake"
    "${_sioyek_repo_root}/CPackSourceConfig.cmake"
)

# Authored/tracked files that must never be removed by any clean target.
# Kept as documentation + defence-in-depth for future edits.
set(_sioyek_protected_files
    "${_sioyek_repo_root}/Makefile"
    "${_sioyek_repo_root}/CMakeLists.txt"
    "${_sioyek_repo_root}/CMakePresets.json"
)
set(_sioyek_insource_dirs
    "${_sioyek_repo_root}/CMakeFiles"
    "${_sioyek_repo_root}/Testing"
)

# ---------------------------------------------------------------------------
# Dependency / submodule build residue.
#
# The vendored mupdf is built by its *own* GNU make (`make -C <mupdf-src>`).
# CMake directs the final archives into `${CMAKE_BINARY_DIR}/mupdf-out`, but
# mupdf's make also creates in-tree intermediates under `mupdf/build/` (and
# `mupdf/generated/`), and the legacy qmake scripts (`build_linux.sh`,
# `build_mac.sh`) build mupdf in-tree as well. None of the top-level build output
# lives there, so it must be cleaned explicitly -- analogous to neovim's
# `distclean` removing `$(DEPS_BUILD_DIR)` (`.deps`).
#
# We only ever remove known build directories inside the submodules; tracked
# submodule sources are never touched.
set(_sioyek_dep_clean_dirs
    "${_sioyek_repo_root}/mupdf/build"
    "${_sioyek_repo_root}/mupdf/generated"
    "${_sioyek_repo_root}/zlib/build"
)

# ---------------------------------------------------------------------------
# Robust removal helpers.
#
# IMPORTANT: `cmake -E rm` does NOT perform glob expansion. Passing a pattern
# such as "<root>/*.deb" to it makes it treat '*' as a literal character, so it
# exits 0 while removing nothing -- a silent no-op that previously left every
# packaging artifact behind. Glob patterns are therefore expanded by a real
# shell (`sh -c 'rm -rf <pattern>'`), whereas literal paths/dirs are removed
# with the portable `cmake -E rm -rf` (no shell dependency).
# ---------------------------------------------------------------------------

# Build a "rm -rf <glob> <glob> ..." shell snippet from glob patterns.
# Patterns are never user-supplied and never overlap _sioyek_protected_files.
function(_sioyek_glob_rm_command out_var)
    set(_cmd "rm -rf")
    foreach(_g IN LISTS ARGN)
        string(APPEND _cmd " ${_g}")
    endforeach()
    set(${out_var} "${_cmd}" PARENT_SCOPE)
endfunction()
# ---------------------------------------------------------------------------
# clean-stage / clean-packages / clean-in-source
# ---------------------------------------------------------------------------
add_custom_target(clean-stage
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${_sioyek_repo_root}/stage"
    COMMENT "Cleaning staged install output"
    VERBATIM)

_sioyek_glob_rm_command(_sioyek_glob_rm ${_sioyek_clean_globs})
add_custom_target(clean-packages
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${_sioyek_repo_root}/build/appimage"
    COMMAND sh -c "${_sioyek_glob_rm}"
    COMMENT "Cleaning packaging artifacts"
    VERBATIM)

# Assert (at configure time) that the protected authored files are never in the
# deletion lists. This fails fast if someone re-adds `Makefile` etc. in future.
foreach(_f IN LISTS _sioyek_insource_files)
    if(_f IN_LIST _sioyek_protected_files)
        message(FATAL_ERROR
            "SioyekClean: refusing to register '${_f}' for deletion: it is an "
            "authored/tracked file (see _sioyek_protected_files).")
    endif()
endforeach()

add_custom_target(clean-in-source
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${_sioyek_insource_files} ${_sioyek_insource_dirs}
    COMMENT "Cleaning in-source CMake leftovers"
    VERBATIM)

# ---------------------------------------------------------------------------
# clean-all / distclean : remove the whole build tree.
#
# Deleting the build directory from within a build target would make ninja/make
# fail to write their log ("No such file or directory"). To avoid that, the
# removal is delegated to a *detached* background helper that waits until the
# current (build-tool) process has exited (polling its PID via `kill -0`)
# before descending on the tree. This replaces an earlier fixed `sleep 1`,
# which was an unreliable race, and keeps the build command's exit status clean.
#
# Portability: the detached-removal step requires a POSIX `sh`; on Windows use
# the `clean-in-source` / `clean-stage` / `clean-packages` targets instead (the
# whole-tree targets are not meaningful under the MSVC generators anyway).
# ---------------------------------------------------------------------------
function(_sioyek_add_clean_all target_name)
    add_custom_target(${target_name}
        COMMAND ${CMAKE_COMMAND} -E rm -rf ${_sioyek_clean_dirs}
        COMMAND sh -c "${_sioyek_glob_rm}"
        COMMAND ${CMAKE_COMMAND} -E rm -rf ${_sioyek_insource_files} ${_sioyek_insource_dirs}
        COMMAND ${CMAKE_COMMAND} -E rm -rf ${_sioyek_dep_clean_dirs}
        # Remove the whole build tree LAST, and delete it from OUTSIDE so the
        # running build tool can still write its log. We use a detached helper
        # that waits for this process to exit (no fixed sleep race): it polls
        # for the parent PID instead of sleeping a magic second.
        COMMAND ${CMAKE_COMMAND} -E echo
            "Removing the build directory '${CMAKE_BINARY_DIR}' after the build tool exits..."
        COMMAND sh -c "nohup sh -c 'while kill -0 $$$$ 2>/dev/null; do sleep 0.2; done; rm -rf \"${CMAKE_BINARY_DIR}\"' >/dev/null 2>&1 &"
        COMMENT "Cleaning ALL build artifacts (build directory removed shortly after)"
        VERBATIM)
endfunction()

_sioyek_add_clean_all(clean-all)
_sioyek_add_clean_all(distclean)

# ---------------------------------------------------------------------------
# clean-build : remove the ENTIRE top-level build/ tree (all presets/configs),
# not just the current binary dir. Useful when several presets coexist.
# ---------------------------------------------------------------------------
add_custom_target(clean-build
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${_sioyek_dep_clean_dirs}
    COMMAND ${CMAKE_COMMAND} -E echo
        "Removing the whole build tree '${_sioyek_repo_root}/build' after the build tool exits..."
    COMMAND sh -c "nohup sh -c 'while kill -0 $$$$ 2>/dev/null; do sleep 0.2; done; rm -rf \"${_sioyek_repo_root}/build\"' >/dev/null 2>&1 &"
    COMMENT "Cleaning the entire build/ tree"
    VERBATIM)

# ---------------------------------------------------------------------------
# clean-deps : dependency/submodule build residue only.
# ---------------------------------------------------------------------------
add_custom_target(clean-deps
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${_sioyek_dep_clean_dirs}
    COMMENT "Cleaning dependency/submodule build residue (mupdf, zlib)"
    VERBATIM)

message(STATUS "sioyek: clean targets available (clean-all, distclean, clean-build, clean-deps, clean-packages, clean-stage, clean-in-source)")
