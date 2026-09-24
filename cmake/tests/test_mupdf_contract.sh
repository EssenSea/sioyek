#!/usr/bin/env bash
# =============================================================================
# test_mupdf_contract.sh
# Regression test: verifies the mupdf consumption contract's source decision matrix.
#
# Approach:
#   The contract probes the system mupdf version via pkg-config. This test forges a
#   temporary pkgconfig directory containing a fake mupdf.pc of a given version,
#   then runs a minimal CMake project containing only the contract logic and
#   asserts the chosen source.
#
# Matrix (tri-state option x escape hatch x system version):
#   verified range [1.26.11, 1.27):
#     AUTO + 1.26.11/1.26.12           -> system
#     ON   + 1.26.11                   -> system
#   below lower bound (<1.26.11):
#     AUTO + 1.26.10                   -> vendored
#     ON   + 1.26.10                   -> ERROR
#   extended range [1.27, 1.29), needs escape hatch:
#     AUTO + 1.27.0/1.27.2/1.28.2      -> vendored (no escape hatch)
#     ON   + 1.27.0                    -> ERROR
#     AUTO + 1.27.0/1.27.2/1.28.2 + hatch -> system
#     ON   + 1.28.2 + hatch            -> system
#   beyond extended range (>=1.29), escape hatch does not cover:
#     AUTO + 1.29.0                    -> vendored
#     AUTO + 1.29.0/2.0.0 + hatch      -> vendored
#     ON   + 1.29.0/2.0.0 + hatch      -> ERROR
#   other:
#     AUTO + not installed             -> vendored
#     OFF  + 1.26.11/1.28.2            -> vendored
#     ON   + not installed             -> ERROR
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="${REPO_ROOT}/cmake"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

# --- Create a fake system mupdf (visible to pkg-config) ---
make_fake_pc() {
    local ver="$1" pcroot="$2"
    mkdir -p "${pcroot}"
    cat > "${pcroot}/mupdf.pc" <<PC
prefix=/tmp/fake
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: mupdf
Description: fake mupdf for contract test
Version: ${ver}
Libs: -L\${libdir} -lmupdf
Cflags: -I\${includedir}
PC
}

# --- Run the contract once, capture the result ---
# Args: <system_version|NONE> <USE_SYSTEM: AUTO/ON/OFF> <ALLOW: ON/OFF>
# Output: "system" / "vendored" / "ERROR"
run_contract() {
    local sysver="$1" use="$2" allow="$3"
    local d="${WORK}/run_${RANDOM}_$$"
    mkdir -p "${d}"
    local pcdir=""

    if [[ "${sysver}" != "NONE" ]]; then
        pcdir="${d}/pkgconfig"
        make_fake_pc "${sysver}" "${pcdir}"
    else
        pcdir="${d}/empty_pkgconfig"
        mkdir -p "${pcdir}"
    fi

    # Minimal project: include the contract module and print the decision.
    cat > "${d}/CMakeLists.txt" <<CM
cmake_minimum_required(VERSION 3.16)
project(probe NONE)
list(APPEND CMAKE_MODULE_PATH "\${CMAKE_CURRENT_SOURCE_DIR}/mod")
include(\${CMAKE_CURRENT_SOURCE_DIR}/mod/SioyekMupdf.cmake)
message(STATUS "CONTRACT_RESULT=\${SIOYEK_MUPDF_SOURCE}")
CM
    # Provide the module plus a fake mupdf source dir (so the vendored branch passes its precheck).
    mkdir -p "${d}/mod"
    cp "${MODULE_DIR}/SioyekMupdf.cmake" "${d}/mod/"
    # Stub the unified resolver so this decision-matrix test does not depend on
    # HarfBuzz being discoverable in the environment. The vendored branch asks
    # for HarfBuzz; we satisfy it with a harmless interface target.
    cat > "${d}/mod/SioyekDependencies.cmake" <<'DEPS'
function(sioyek_find_dependency)
    set(_args ${ARGN})
    list(FIND _args "OUT_TARGET" _i)
    if(_i GREATER -1)
        math(EXPR _j "${_i}+1")
        list(GET _args ${_j} _var)
        if(NOT TARGET sioyek_test_stub_dep)
            add_library(sioyek_test_stub_dep INTERFACE)
        endif()
        set(${_var} "sioyek_test_stub_dep" PARENT_SCOPE)
    endif()
    list(FIND _args "OUT_VERSION" _i2)
    if(_i2 GREATER -1)
        math(EXPR _j2 "${_i2}+1")
        list(GET _args ${_j2} _var2)
        set(${_var2} "0" PARENT_SCOPE)
    endif()
endfunction()
DEPS
    mkdir -p "${d}/fake_mupdf/include/mupdf"
    touch "${d}/fake_mupdf/include/mupdf/fitz.h"
    printf 'all:\n\t@true\n' > "${d}/fake_mupdf/Makefile"
    # Redirect the contract's reference to CMAKE_CURRENT_SOURCE_DIR/mupdf to the fake dir.
    sed 's#${CMAKE_CURRENT_SOURCE_DIR}/mupdf#${CMAKE_CURRENT_SOURCE_DIR}/fake_mupdf#g; s#${CMAKE_CURRENT_SOURCE_DIR}/mupdf/include#${CMAKE_CURRENT_SOURCE_DIR}/fake_mupdf/include#g' \
        "${MODULE_DIR}/SioyekMupdf.cmake" > "${d}/mod/SioyekMupdf.cmake"

    local out
    out="$(PKG_CONFIG_PATH="${pcdir}" PKG_CONFIG_LIBDIR="${pcdir}" \
           cmake -S "${d}" -B "${d}/build" \
                 -DSIOYEK_USE_SYSTEM_MUPDF="${use}" \
                 -DSIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF="${allow}" 2>&1)"

    if grep -q "CONTRACT_RESULT=system" <<<"${out}"; then
        echo "system"
    elif grep -q "CONTRACT_RESULT=vendored" <<<"${out}"; then
        echo "vendored"
    elif grep -qiE "CMake Error|FATAL_ERROR" <<<"${out}"; then
        echo "ERROR"
        if [[ "${SIOYEK_TEST_VERBOSE:-0}" == "1" ]]; then
            echo "----- last output -----" >&2
            tail -15 <<<"${out}" >&2
        fi
    else
        echo "UNKNOWN"
        echo "----- last output -----" >&2
        tail -15 <<<"${out}" >&2
    fi
}

check() {
    local desc="$1" sysver="$2" use="$3" allow="$4" expect="$5"
    local got
    got="$(run_contract "${sysver}" "${use}" "${allow}")"
    if [[ "${got}" == "${expect}" ]]; then
        printf '  [PASS] %-52s -> %s\n' "${desc}" "${got}"
        PASS=$((PASS+1))
    else
        printf '  [FAIL] %-52s -> %s (expect %s)\n' "${desc}" "${got}" "${expect}"
        FAIL=$((FAIL+1))
    fi
}

echo "=== mupdf consumption contract: source decision matrix ==="
echo "--- verified range [1.26.11, 1.27) ---"
check "AUTO + 1.26.11 (verified lower bound)"  "1.26.11" AUTO OFF system
check "AUTO + 1.26.12 (verified)"              "1.26.12" AUTO OFF system
check "ON   + 1.26.11 (verified)"              "1.26.11" ON   OFF system
echo "--- below lower bound (<1.26.11) ---"
check "AUTO + 1.26.10 (below lower bound)"     "1.26.10" AUTO OFF vendored
check "ON   + 1.26.10 (below) -> error"        "1.26.10" ON   OFF ERROR
echo "--- extended range [1.27, 1.29), needs escape hatch ---"
check "AUTO + 1.27.0  (extended, no hatch)"    "1.27.0"  AUTO OFF vendored
check "AUTO + 1.27.2  (extended, no hatch)"    "1.27.2"  AUTO OFF vendored
check "AUTO + 1.28.2  (extended, no hatch)"    "1.28.2"  AUTO OFF vendored
check "ON   + 1.27.0  (extended) -> error"     "1.27.0"  ON   OFF ERROR
check "AUTO + 1.27.0  + hatch -> system"       "1.27.0"  AUTO ON  system
check "AUTO + 1.27.2  + hatch -> system"       "1.27.2"  AUTO ON  system
check "AUTO + 1.28.2  + hatch -> system"       "1.28.2"  AUTO ON  system
check "ON   + 1.28.2  + hatch -> system"       "1.28.2"  ON   ON  system
echo "--- beyond extended range (>=1.29), escape hatch does not cover ---"
check "AUTO + 1.29.0  (>=1.29)"                "1.29.0"  AUTO OFF vendored
check "AUTO + 1.29.0  + hatch -> vendored"     "1.29.0"  AUTO ON  vendored
check "AUTO + 2.0.0   + hatch -> vendored"     "2.0.0"   AUTO ON  vendored
check "ON   + 1.29.0  + hatch -> error"        "1.29.0"  ON   ON  ERROR
check "ON   + 2.0.0   + hatch -> error"        "2.0.0"   ON   ON  ERROR
echo "--- other ---"
check "AUTO + not installed"                   "NONE"    AUTO OFF vendored
check "OFF  + 1.26.11 (force vendored)"        "1.26.11" OFF  OFF vendored
check "OFF  + 1.28.2  (force vendored)"        "1.28.2"  OFF  ON  vendored
check "ON   + not installed -> error"          "NONE"    ON   OFF ERROR

# ---------------------------------------------------------------------------
# Regression: the vendored mupdf build must be driven by a *generated script*
# that (a) pre-creates the output directory tree and (b) declares the make
# invocation. This guards the fix for the intermittent build failure:
#     cc: fatal error: opening dependency file .../brotli/.../x.d: No such file
# which was caused by mupdf's lazy per-object `mkdir -p` racing `-MMD` when the
# build tree was created concurrently.
# ---------------------------------------------------------------------------
echo "--- vendored build script generation ---"
# This section reports results inline (the matrix above uses check()).
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

VDIR="${WORK}/vendored"
mkdir -p "${VDIR}/mod"

cat > "${VDIR}/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(vprobe NONE)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/mod")
include(${CMAKE_CURRENT_SOURCE_DIR}/mod/SioyekMupdf.cmake)
CM

# Reuse the same stub strategy as the matrix test: satisfy the dependency
# resolver with a harmless interface target so no real HarfBuzz is needed.
cat > "${VDIR}/mod/SioyekDependencies.cmake" <<'DEPS'
function(sioyek_find_dependency)
    set(_args ${ARGN})
    list(FIND _args "OUT_TARGET" _i)
    if(_i GREATER -1)
        math(EXPR _j "${_i}+1")
        list(GET _args ${_j} _var)
        if(NOT TARGET sioyek_test_stub_dep)
            add_library(sioyek_test_stub_dep INTERFACE)
        endif()
        set(${_var} "sioyek_test_stub_dep" PARENT_SCOPE)
    endif()
    list(FIND _args "OUT_VERSION" _i2)
    if(_i2 GREATER -1)
        math(EXPR _j2 "${_i2}+1")
        list(GET _args ${_j2} _var2)
        set(${_var2} "0" PARENT_SCOPE)
    endif()
endfunction()
DEPS

# Fake vendored mupdf with a plausible source layout so the glob runs.
mkdir -p "${VDIR}/fake_mupdf/include/mupdf" \
         "${VDIR}/fake_mupdf/source/fitz" \
         "${VDIR}/fake_mupdf/thirdparty/brotli/c/enc"
touch "${VDIR}/fake_mupdf/include/mupdf/fitz.h"
printf 'int x;\n' > "${VDIR}/fake_mupdf/source/fitz/x.c"
printf 'int y;\n' > "${VDIR}/fake_mupdf/thirdparty/brotli/c/enc/backward_references.c"
printf 'all:\n\t@true\n' > "${VDIR}/fake_mupdf/Makefile"

sed 's#${CMAKE_CURRENT_SOURCE_DIR}/mupdf#${CMAKE_CURRENT_SOURCE_DIR}/fake_mupdf#g; s#${CMAKE_CURRENT_SOURCE_DIR}/mupdf/include#${CMAKE_CURRENT_SOURCE_DIR}/fake_mupdf/include#g' \
    "${MODULE_DIR}/SioyekMupdf.cmake" > "${VDIR}/mod/SioyekMupdf.cmake"

# Force the vendored branch (OFF) so the build script is emitted.
if cmake -S "${VDIR}" -B "${VDIR}/build" -G Ninja -DSIOYEK_USE_SYSTEM_MUPDF=OFF \
        > "${VDIR}/cfg.log" 2>&1; then
    ok "vendored branch configures (for build-script test)"
else
    bad "vendored branch failed to configure (build-script test)"
    sed -n '1,15p' "${VDIR}/cfg.log" | sed 's/^/      | /'
fi

SCRIPT="${VDIR}/build/sioyek_mupdf_build.sh"
if [[ -f "${SCRIPT}" ]]; then
    ok "generated mupdf build script exists"
    if grep -q "mkdir -p" "${SCRIPT}"; then
        ok "build script pre-creates output directories"
    else
        bad "build script is missing the mkdir pre-pass"
    fi
    if grep -q "thirdparty/brotli/c/enc" "${SCRIPT}"; then
        ok "build script pre-creates the brotli enc dir (race guard)"
    else
        bad "build script does not pre-create the brotli enc dir"
    fi
    if grep -qE "exec '.*gmake' -C .* -j[0-9]+ libs libmupdf-threads" "${SCRIPT}"; then
        ok "build script invokes make for 'libs libmupdf-threads'"
    else
        bad "build script does not invoke make correctly"
    fi
    # The generator's build files must reference the generated script and run it
    # under `cmake -E env` with the make environment cleared.
    if grep -rq "sioyek_mupdf_build.sh" "${VDIR}/build" 2>/dev/null; then
        ok "generator build files invoke the generated build script"
    else
        bad "generator build files do not invoke the generated build script"
    fi
    if grep -rq "cmake -E env MAKEFLAGS= MFLAGS= GNUMAKEFLAGS= MAKELEVEL=" \
            "${VDIR}/build" 2>/dev/null; then
        ok "build script is run with the make environment cleared"
    else
        bad "build script is not run with a cleared make environment"
    fi
else
    bad "generated mupdf build script was not created"
fi

# ---------------------------------------------------------------------------
# Parallelism resolution for the vendored mupdf build.
#
# `cmake --build -jN` cannot reach the child mupdf build, so SioyekMupdf.cmake
# resolves -j from, in order: SIOYEK_MUPDF_JOBS (env) > CMAKE_BUILD_PARALLEL_LEVEL
# (variable or env) > auto-detected CPU count. Verify each source, plus that the
# value is embedded in the generated script.
# ---------------------------------------------------------------------------
echo "--- vendored build parallelism ---"

_jobs_in_script() {
    # note: -e is required so the leading "-j" in the pattern is not read as a
    # grep option.
    grep -oE -e "-j[0-9]+ libs libmupdf-threads" "$1" 2>/dev/null | grep -oE "[0-9]+"
}

# Configure the sandbox (env vars from the caller) and print the -j baked into
# the generated script, or NONE on failure.
_probe_jobs() {
    rm -rf "${VDIR}/build"
    if cmake -S "${VDIR}" -B "${VDIR}/build" -G Ninja \
            -DSIOYEK_USE_SYSTEM_MUPDF=OFF "$@" >"${VDIR}/cfg.log" 2>&1; then
        local j
        j="$(_jobs_in_script "${VDIR}/build/sioyek_mupdf_build.sh")"
        printf '%s\n' "${j:-NONE}"
    else
        printf 'CFGFAIL\n'
    fi
}

# 1. explicit SIOYEK_MUPDF_JOBS wins
j="$(SIOYEK_MUPDF_JOBS=3 _probe_jobs)"
if [[ "${j}" == "3" ]]; then ok "SIOYEK_MUPDF_JOBS env is honoured (-j3)"
else bad "SIOYEK_MUPDF_JOBS env not honoured (got -j${j})"; fi

# 2. SIOYEK_MUPDF_JOBS beats CMAKE_BUILD_PARALLEL_LEVEL
j="$(SIOYEK_MUPDF_JOBS=2 CMAKE_BUILD_PARALLEL_LEVEL=9 _probe_jobs)"
if [[ "${j}" == "2" ]]; then ok "SIOYEK_MUPDF_JOBS overrides CMAKE_BUILD_PARALLEL_LEVEL (-j2)"
else bad "priority wrong (got -j${j})"; fi

# 3. CMAKE_BUILD_PARALLEL_LEVEL as a cache variable
j="$(_probe_jobs -DCMAKE_BUILD_PARALLEL_LEVEL=7)"
if [[ "${j}" == "7" ]]; then ok "CMAKE_BUILD_PARALLEL_LEVEL variable is honoured (-j7)"
else bad "CMAKE_BUILD_PARALLEL_LEVEL variable not honoured (got -j${j})"; fi

# 4. CMAKE_BUILD_PARALLEL_LEVEL in the environment (the closest thing to
#    inheriting -j from the outer build)
j="$(CMAKE_BUILD_PARALLEL_LEVEL=5 _probe_jobs)"
if [[ "${j}" == "5" ]]; then ok "CMAKE_BUILD_PARALLEL_LEVEL env is honoured (-j5)"
else bad "CMAKE_BUILD_PARALLEL_LEVEL env not honoured (got -j${j})"; fi

# 5. default: auto-detected CPU count (a positive integer)
j="$(_probe_jobs)"
if [[ "${j}" =~ ^[0-9]+$ ]] && (( j >= 1 )); then
    ok "default resolves to a positive job count (auto-detect, -j${j})"
else
    bad "default did not resolve to a job count (got -j${j})"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
