#!/usr/bin/env bash
# Tests score.py with canned reports. No model is run. Prints a pass/fail table.
set -u
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what is refused; a row that
# needs one sets it itself.
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
SC="$T/score.py"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
eq() { [ "$1" = "$2" ]; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }
# rep <dir> <case> [file:line:SEVERITY[:status]]...
rep() {
  local d="$1" c="$2"; shift 2; mkdir -p "$W/$d"
  { echo "## Review: $c"; echo; echo '```findings'; echo "version: 1"; echo "findings:"
    local i=0 spec f l s st
    for spec in "$@"; do
      i=$((i+1)); IFS=: read -r f l s st <<<"$spec"
      echo "  - id: F$i"; echo "    severity: $s"; echo "    file: $f"; echo "    line: $l"
      [ -z "${st:-}" ] || echo "    status: $st"
    done
    echo '```'; } >"$W/$d/$c.md"
}
# The three real-bug cases: empty reports for every run except "perfect".
rest() { rep "$1" mention-url; rep "$1" push-guard-rename; rep "$1" hunk-header; }
sc() { python3 -I "$SC" --reports "$W/$1" "${@:2}"; }

# perfect: every defect hit, nothing else.
rep perfect sql-injection src/users.py:6:CRITICAL; rep perfect off-by-one src/page.js:3:WARNING; rep perfect clean-rename
rep perfect mention-url tools/mentions.py:10:WARNING; rep perfect push-guard-rename scripts/scope-check.sh:10:WARNING; rep perfect hunk-header tools/anchors.py:9:WARNING
check "perfect run -> recall 1, precision 1" eval 'sc perfect --json | jq -e ".recall == 1 and .precision == 1" >/dev/null'

# missed: the SQL injection is not found; the off-by-one is.
rep missed sql-injection; rep missed off-by-one src/page.js:4:WARNING; rep missed clean-rename
rest missed
check "a missed defect lowers recall and is named" eval '[ "$(sc missed --json | jq -r ".recall")" = "0.2" ] && sc missed | grep -q "D1"'

# noisy: both defects hit, plus a CRITICAL on the decoy and a WARNING on the clean rename.
rep noisy sql-injection src/users.py:6:CRITICAL src/users.py:12:CRITICAL; rep noisy off-by-one src/page.js:3:CRITICAL; rep noisy clean-rename src/util.ts:3:WARNING
rest noisy
check "false findings lower precision, decoy hits counted" eval '[ "$(sc noisy --json | jq -r ".precision")" = "0.5" ] && [ "$(sc noisy --json | jq -r ".total.decoy_hits")" = "2" ]'

# severity floor: a NOTE on the right line is not a hit for a CRITICAL defect.
rep floor sql-injection src/users.py:6:NOTE; rep floor off-by-one src/page.js:3:WARNING; rep floor clean-rename
rest floor
check "a NOTE does not meet min_severity CRITICAL" eval '[ "$(sc floor --json | jq -r ".cases[\"sql-injection\"].hit")" = "0" ]'

# line tolerance: three lines away is a miss for tolerance 1.
rep far sql-injection src/users.py:9:CRITICAL; rep far off-by-one src/page.js:3:WARNING; rep far clean-rename
rest far
check "outside the tolerance is a miss" eval '[ "$(sc far --json | jq -r ".cases[\"sql-injection\"].hit")" = "0" ]'

# a closed finding is not counted.
rep closed sql-injection src/users.py:6:CRITICAL:verified; rep closed off-by-one src/page.js:3:WARNING; rep closed clean-rename
rest closed
check "a verified (closed) finding is ignored" eval '[ "$(sc closed --json | jq -r ".cases[\"sql-injection\"].reported")" = "0" ]'

# thresholds drive the exit code.
sc missed --min-recall 0.9 >/dev/null; r=$?; check "--min-recall unmet -> exit 1" eq "$r" 1
sc perfect --min-recall 0.9 --min-precision 0.9 >/dev/null; r=$?; check "thresholds met -> exit 0" eq "$r" 0

# unreadable input is exit 2, never a score.
mkdir -p "$W/empty"; sc empty >/dev/null 2>&1; r=$?; check "missing report -> exit 2" eq "$r" 2
printf 'no block\n' >"$W/empty/sql-injection.md"; sc empty >/dev/null 2>&1; r=$?; check "report without findings block -> exit 2" eq "$r" 2

python3 -I "$SC" --validate >/dev/null; r=$?; check "case anchors sit inside their diffs" eq "$r" 0

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
