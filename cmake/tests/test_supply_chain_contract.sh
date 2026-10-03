#!/usr/bin/env bash
# =============================================================================
# test_supply_chain_contract.sh
# Supply-chain hardening contract (OpenSSF Scorecard: Pinned-Dependencies and
# Token-Permissions; SLSA: verify what you fetch).
#
# Verifies:
#   - EVERY "uses:" in EVERY workflow is pinned to a full 40-char commit SHA
#     (a mutable tag lets the action owner, or anyone who compromises the
#      account, change what runs in this repository without a commit here)
#   - every workflow declares permissions, and write access is confined to the
#     jobs that actually publish
#   - Linuxdeploy downloads are integrity-checked before execution
#   - the check cannot silently degrade: an empty expected hash is an error
#   - Dependabot keeps the pins fresh, and it covers every ecosystem present
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF_DIR="${REPO_ROOT}/.github/workflows"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== supply-chain contract ==="

# --- every action pinned to a full SHA -------------------------------------
UNPINNED=0
TOTAL=0
for wf in "${WF_DIR}"/*.yml; do
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        TOTAL=$((TOTAL+1))
        ref="${line#*uses: }"
        ref="${ref%% *}"
        if [[ ! "${ref}" =~ @[0-9a-f]{40}$ ]]; then
            UNPINNED=$((UNPINNED+1))
            echo "      (unpinned in $(basename "${wf}"): ${ref})"
        fi
    done < <(grep -oE "uses: *[^ ]+" "${wf}" 2>/dev/null | sed "s/^uses: *//")
done

if [[ "${TOTAL}" -eq 0 ]]; then
    bad "no action references found at all (workflows missing?)"
elif [[ "${UNPINNED}" -eq 0 ]]; then
    ok "all ${TOTAL} action references are pinned to a full commit SHA"
else
    bad "${UNPINNED} of ${TOTAL} action references are NOT SHA-pinned"
fi

# A pinned action must still say which version it is, or it becomes unauditable.
UNCCOMMENTED=0
for wf in "${WF_DIR}"/*.yml; do
    while IFS= read -r line; do
        if [[ "${line}" =~ @[0-9a-f]{40} ]] && ! echo "${line}" | grep -qE '#[[:space:]]*v?[0-9]'; then
            UNCCOMMENTED=$((UNCCOMMENTED+1))
            echo "      (no version comment in $(basename "${wf}"): ${line##*uses: })"
        fi
    done < <(grep -E "uses: *[^ ]+@[0-9a-f]{40}" "${wf}" 2>/dev/null)
done
if [[ "${UNCCOMMENTED}" -eq 0 ]]; then
    ok "every pinned action carries a version comment (auditable at a glance)"
else
    bad "${UNCCOMMENTED} pinned action(s) lack a version comment"
fi

# --- permissions declared, write confined ----------------------------------
NO_PERMS=0
for wf in "${WF_DIR}"/*.yml; do
    if ! grep -qE "^permissions:" "${wf}"; then
        NO_PERMS=$((NO_PERMS+1))
        echo "      (no top-level permissions: $(basename "${wf}"))"
    fi
done
if [[ "${NO_PERMS}" -eq 0 ]]; then
    ok "every workflow declares a top-level permissions block"
else
    bad "${NO_PERMS} workflow(s) declare no permissions (inherit the default token scope)"
fi

# Every workflow must default to read-only.
NOT_READ=0
for wf in "${WF_DIR}"/*.yml; do
    if grep -qE "^permissions:" "${wf}"; then
        # The line after the top-level permissions: must be contents: read
        if ! grep -A1 -E "^permissions:" "${wf}" | grep -qE "contents: read"; then
            NOT_READ=$((NOT_READ+1))
            echo "      (does not default to contents: read: $(basename "${wf}"))"
        fi
    fi
done
if [[ "${NOT_READ}" -eq 0 ]]; then
    ok "every workflow defaults to contents: read"
else
    bad "${NOT_READ} workflow(s) do not default to read-only"
fi

# Write access must be confined to the jobs that actually publish. The point is
# not a magic count (the repository legitimately has three release pipelines)
# but that NO build/test job can write to the repository.
#
# Implementation note: this is done with a small awk pass that tracks the
# enclosing job key, because "which job does this directive belong to" is a
# question about YAML structure (indentation), not about line content. A naive
# grep also matches the policy COMMENT that mentions "contents: write", which
# is why comments are skipped first.
WRITE_JOBS=0
BAD_WRITE=0
for wf in "${WF_DIR}"/*.yml; do
    _wfname=$(basename "${wf}")
    while IFS= read -r verdict; do
        [ -z "${verdict}" ] && continue
        if [ "${verdict}" = "OK" ]; then
            WRITE_JOBS=$((WRITE_JOBS+1))
        else
            BAD_WRITE=$((BAD_WRITE+1))
            echo "      contents: write outside a publishing job: ${_wfname} [${verdict}]"
        fi
    done < <(awk '
        # Skip full-line comments so a policy comment is not read as a grant.
        /^[[:space:]]*#/ { next }
        # A top-level job key: exactly two spaces of indent, then a name, then colon.
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            job = $1
            sub(/:"$/, "", job)
            next
        }
        /contents: write/ {
            if (job ~ /release|publish|upload/) { print "OK"; next }
            print (length(job) ? job : "<no job>")
        }' "${wf}")
done
if [ "${BAD_WRITE}" -eq 0 ] && [ "${WRITE_JOBS}" -gt 0 ]; then
    ok "contents: write appears only in publishing jobs (${WRITE_JOBS} job(s))"
elif [ "${WRITE_JOBS}" -eq 0 ]; then
    bad "no job grants contents: write; the release pipelines could not publish"
else
    bad "${BAD_WRITE} job(s) grant contents: write without being a publisher"
fi
# --- linuxdeploy integrity check -------------------------------------------
AI="${REPO_ROOT}/cmake/SioyekAppImage.cmake"
if grep -q "sha256sum" "${AI}" && grep -q "fetch_verified" "${AI}"; then
    ok "linuxdeploy downloads are verified with sha256 before execution"
else
    bad "linuxdeploy downloads are not integrity-checked"
fi

# The expected hashes must actually be populated, not left blank.
if grep -qE 'SIOYEK_LINUXDEPLOY_SHA256$' "${AI}" && \
   grep -A1 -E "set\(SIOYEK_LINUXDEPLOY_SHA256$" "${AI}" | grep -qE '"[0-9a-f]{64}"'; then
    ok "a real SHA-256 is recorded for linuxdeploy"
else
    bad "SIOYEK_LINUXDEPLOY_SHA256 is empty; the check would refuse every build"
fi
if grep -A1 -E "set\(SIOYEK_LINUXDEPLOY_QT_SHA256$" "${AI}" | grep -qE '"[0-9a-f]{64}"'; then
    ok "a real SHA-256 is recorded for the linuxdeploy Qt plugin"
else
    bad "SIOYEK_LINUXDEPLOY_QT_SHA256 is empty"
fi

# The check must be MANDATORY: an empty expected hash is an error, so the
# verification can never quietly turn into a no-op.
if grep -q "no expected SHA-256 configured" "${AI}"; then
    ok "an empty expected hash is a hard error (the check cannot degrade silently)"
else
    bad "an empty expected hash is not rejected; verification could silently no-op"
fi

# --- Dependabot -------------------------------------------------------------
DB="${REPO_ROOT}/.github/dependabot.yml"
if [[ -f "${DB}" ]]; then
    ok "a Dependabot configuration exists"
else
    bad "no .github/dependabot.yml: SHA pins would go stale with nothing to update them"
fi
if [[ -f "${DB}" ]]; then
    if grep -q "github-actions" "${DB}"; then
        ok "Dependabot tracks the github-actions ecosystem"
    else
        bad "Dependabot does not track github-actions"
    fi
    # The submodules are real dependencies and must be tracked too.
    if grep -q "gitsubmodule" "${DB}"; then
        ok "Dependabot tracks the git submodules (mupdf, zlib)"
    else
        bad "Dependabot does not track the submodules"
    fi
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
