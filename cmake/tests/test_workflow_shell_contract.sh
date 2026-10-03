#!/usr/bin/env bash
# =============================================================================
# test_workflow_shell_contract.sh
# Every bash snippet embedded in a workflow must actually be valid shell.
#
# WHY: the run: blocks of a workflow are shell that nothing syntax-checks. They
# are strings inside YAML -- invisible to the compiler, to shellcheck (which is
# pointed at .sh files) and to the build. A single stray quote survives review
# and fails only in CI, minutes into a run, with a line number relative to the
# generated script rather than to the workflow. That is exactly what happened: a
# mis-quoted assignment in an SBOM step produced
#
#     line 14: syntax error near unexpected token `('
#
# and cost several runs to localise, because the reported line pointed at a block
# that had already been rewritten.
#
# This suite extracts every run: block from every workflow, wraps each in the
# same "set -euo pipefail" GitHub Actions applies, and requires that it parses
# (bash -n) and is shellcheck-clean. PowerShell blocks (jobs declaring
# "shell: pwsh") are recognised and skipped, since bash -n rejects them by
# construction.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF_DIR="${REPO_ROOT}/.github/workflows"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== workflow embedded-shell contract ==="

# Extract each "run: |" block body. A block ends at the first line less
# indented than its first content line (standard YAML block scalar rules).
extract_blocks() {
    awk '
        /^[ \t]*run: \|/ { inblk=1; n++; next }
        inblk {
            if ($0 ~ /^[ \t]*$/) { print n "\t" $0; next }
            match($0, /^[ \t]*/)
            ind = RLENGTH
            if (ind < 10) { inblk=0; next }
            sub(/^[ \t]{10}/, "", $0)
            print n "\t" $0
        }' "$1"
}

# Print "yes" when block <n> of workflow <file> belongs to a PowerShell step.
# "shell:" applies to the step or job that follows it, so a pending flag is
# carried forward until the matching run: block is reached.
is_powershell_block() {
    awk -v want="$1" '
        /^[ \t]*shell: *pwsh/ { pending=1; next }
        /^[ \t]*shell: *bash/ { pending=0; next }
        /^[ \t]*run: \|/ { n++; if (n == want) { print (pending ? "yes" : "no"); exit } }
        ' "$2"
}

NBLOCKS=0
NCHECKED=0
NSKIPPED=0

for wf in "${WF_DIR}"/*.yml; do
    wfname="$(basename "${wf}")"
    extract_blocks "${wf}" > "${WORK}/blocks.tsv"
    [ -s "${WORK}/blocks.tsv" ] || continue

    # Split the numbered stream into one file per block.
    rm -f "${WORK}"/blk_*
    awk -F'\t' -v d="${WORK}" '{ print $2 > (d "/blk_" $1 ".sh") }' "${WORK}/blocks.tsv"

    for f in "${WORK}"/blk_*.sh; do
        [ -e "$f" ] || continue
        NBLOCKS=$((NBLOCKS+1))
        n="$(basename "$f" .sh)"; n="${n#blk_}"

        if [ "$(is_powershell_block "$n" "$wf")" = "yes" ]; then
            NSKIPPED=$((NSKIPPED+1))
            continue
        fi

        # GitHub Actions applies these options to every bash block.
        { echo "set -euo pipefail"; cat "$f"; } > "$f.wrapped"

        if ! err="$(bash -n "$f.wrapped" 2>&1)"; then
            bad "${wfname} block ${n}: not valid shell"
            printf '%s\n' "$err" | head -3 | sed 's/^/        /'
        else
            NCHECKED=$((NCHECKED+1))
        fi

        if command -v shellcheck >/dev/null 2>&1; then
            if out="$(shellcheck -S warning -s bash "$f.wrapped" 2>&1)" && [ -n "$out" ]; then
                bad "${wfname} block ${n}: shellcheck warnings"
                printf '%s\n' "$out" | head -6 | sed 's/^/        /'
            fi
        fi
    done
done

if [ "${NBLOCKS}" -eq 0 ]; then
    bad "no run: blocks were found at all (workflows missing?)"
else
    ok "checked ${NBLOCKS} block(s): ${NCHECKED} parsed cleanly, ${NSKIPPED} PowerShell skipped"
fi

# The literal failure that motivated this suite: a command substitution whose
# assignment lost its opening quote, leaving a stray trailing quote.
if grep -rqE '=\$\\(.*\\)"[[:space:]]*$' "${WF_DIR}"/*.yml; then
    bad "a command substitution appears to have a stray trailing quote"
else
    ok "no stray-quote command substitutions detected"
fi

echo
echo "=============================================="
echo "passed: ${PASS}   failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
