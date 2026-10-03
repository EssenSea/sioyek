#!/usr/bin/env bash
# =============================================================================
# verify_cmake_install_contract.sh
#
# Applies documented install-directory rules to a sioyek source tree and shows
# where the tree does not satisfy them. It reads the tree you point it at; it is
# not tied to any fork.
#
# WHAT IT CHECKS, AND AGAINST WHAT
#   Every result names its rule. The rules come from two locally verifiable
#   sources:
#
#     1. CMake GNUInstallDirs, which documents what each install directory means
#        (Modules/GNUInstallDirs.cmake):
#
#            SYSCONFDIR   read-only single-machine data (etc)
#            DATADIR      read-only architecture-independent data (DATAROOTDIR)
#
#     2. The program itself, which states the absolute paths it reads on Linux
#        (pdf_viewer/main.cpp, LINUX_STANDARD_PATHS).
#
#   It does NOT decide whether a file should be installed at all -- that is a
#   project decision. It reports files the program reads, or that convention
#   places in a standard directory, that no Linux install() rule covers.
#
#   Static analysis cannot prove a package works. `cmake --install` into a
#   staging prefix, compared against the paths in main.cpp, is the conclusive
#   test; this script is meant to be cheap enough to run on every commit.
#
# USAGE
#   ./verify_cmake_install_contract.sh [source-tree]   (default: .)
#   Needs bash + python3 only.
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:-.}

if [ ! -f "$ROOT/CMakeLists.txt" ]; then
    echo "error: $ROOT/CMakeLists.txt not found; pass the source tree as the first argument." >&2
    exit 2
fi

ANALYSER="$HERE/cmake/tests/check_install_coverage.py"
[ -f "$ANALYSER" ] || ANALYSER="$ROOT/cmake/tests/check_install_coverage.py"
[ -f "$ANALYSER" ] || ANALYSER="$HERE/check_install_coverage.py"
if [ ! -f "$ANALYSER" ]; then
    echo "error: check_install_coverage.py not found (looked in $HERE/cmake/tests, $ROOT/cmake/tests, $HERE)." >&2
    exit 2
fi

python3 "$ANALYSER" "$ROOT"
