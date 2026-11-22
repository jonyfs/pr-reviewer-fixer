#!/usr/bin/env bash
# The --only filter of tests/run-all.sh (PR 60, W2): a filter that matches no suite exits 1, an empty word exits 2.
# Both refusals come before any suite starts, so this suite never starts one (no recursion).
set -u
T="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$T/../.." && pwd)"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }
bash "$ROOT/tests/run-all.sh" --only zzz-no-such-suite >/dev/null 2>&1; r=$?
check "a filter that matches no suite exits 1 and runs nothing" [ "$r" = 1 ]
bash "$ROOT/tests/run-all.sh" --only ",x" >/dev/null 2>&1; r=$?
check "an empty word in the filter is refused (exit 2)" [ "$r" = 2 ]
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
