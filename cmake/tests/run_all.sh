#!/usr/bin/env bash
# =============================================================================
# run_all.sh -- run all contract regression test suites.
#
# Usage:  ./cmake/tests/run_all.sh
# Returns: 0 if all pass, non-zero otherwise.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_FAIL=0

for t in test_mupdf_contract.sh test_sqlite_contract.sh test_install_contract.sh \
         test_buildtypes_contract.sh test_clean_contract.sh test_packaging_contract.sh \
         test_warnings_contract.sh test_presets.sh; do
    echo
    echo "############################################################"
    echo "# ${t}"
    echo "############################################################"
    if bash "${HERE}/${t}"; then
        :
    else
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
done

echo
echo "############################################################"
if [[ ${TOTAL_FAIL} -eq 0 ]]; then
    echo "# all test suites passed"
    exit 0
else
    echo "# ${TOTAL_FAIL} test suite(s) failed"
    exit 1
fi
