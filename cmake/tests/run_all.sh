#!/usr/bin/env bash
# =============================================================================
# run_all.sh -- run every contract regression test suite.
#
# Usage:  ./cmake/tests/run_all.sh
#         SIOYEK_TEST_VERBOSE=1 ./cmake/tests/run_all.sh   # per-case detail
# Returns: 0 if all suites pass, non-zero otherwise.
#
# Discovery
# ---------
# The suite list is DISCOVERED (cmake/tests/test_*.sh) instead of being written
# out here. It used to be a hand-maintained list that duplicated the one in
# cmake/SioyekTesting.cmake, and the two drifted: this script ran nine suites
# while the CTest registration listed eight, so test_make_options_contract.sh
# was silently absent from the `ctest` path used by CI. Deriving both from the
# filesystem removes the possibility of drift by construction.
#
# Strictness
# ----------
# `set -euo pipefail` is deliberate:
#   -e  a failing command inside a suite must not be masked;
#   -u  an unset variable is a bug, not an empty string;
#   -o pipefail  the exit status of a pipeline is the rightmost NON-ZERO status,
#                so `some_command | grep -q pattern` no longer reports success
#                when the left-hand command crashed. Without pipefail a suite
#                could pass while the command under test failed outright.
# Suites are still executed in a way that runs ALL of them (no early abort) so a
# single failure does not hide the state of the others; the failure count is
# accumulated and turned into the final exit status.
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
SUITES=("${HERE}"/test_*.sh)
shopt -u nullglob

if [[ ${#SUITES[@]} -eq 0 ]]; then
    echo "run_all.sh: no test suites found in ${HERE} (expected test_*.sh)" >&2
    exit 1
fi

TOTAL_FAIL=0
TOTAL_RUN=0

for suite in "${SUITES[@]}"; do
    TOTAL_RUN=$((TOTAL_RUN+1))
    echo
    echo "############################################################"
    echo "# $(basename "${suite}")"
    echo "############################################################"
    # `if ! bash ...` is required: with `set -e`, a bare failing command would
    # abort the whole run and hide every later suite.
    if ! bash "${suite}"; then
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
done

echo
echo "############################################################"
if [[ ${TOTAL_FAIL} -eq 0 ]]; then
    echo "# all ${TOTAL_RUN} test suite(s) passed"
    exit 0
else
    echo "# ${TOTAL_FAIL} of ${TOTAL_RUN} test suite(s) failed"
    exit 1
fi
