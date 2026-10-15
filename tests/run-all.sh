#!/usr/bin/env bash
# Runs every test against fake `gh` binaries. No network and no GitHub access needed.
# Needs: bash, python3 with PyYAML, node, jq.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
run() { echo "== $1"; shift; "$@" 2>&1 | tail -n 3; [ "${PIPESTATUS[0]}" -eq 0 ] || fail=1; }

run "review-cycle.sh and gate (reviewer copy)" bash "$HERE/fake-gh/run.sh" "$ROOT/pr-reviewer/scripts"
run "review-cycle.sh and gate (fixer copy)"    bash "$HERE/fake-gh/run.sh" "$ROOT/pr-fixer/scripts"
run "triage-pr.sh"                             bash "$HERE/fake-gh/triage/run.sh" "$ROOT/pr-fixer/scripts"
for h in claude codex; do
  run "extension-wait step ($h)" python3 "$HERE/extwait/run.py" "$ROOT/pr-fixer/templates/pr-review-cycle.$h.yml"
  run "budget logic ($h)"        python3 "$HERE/budget/t.py"    "$ROOT/pr-fixer/templates/pr-review-cycle.$h.yml"
done
cmp -s "$ROOT/pr-reviewer/scripts/review-cycle.sh" "$ROOT/pr-fixer/scripts/review-cycle.sh" \
  && cmp -s "$ROOT/pr-reviewer/scripts/gate-pr-review-state.py" "$ROOT/pr-fixer/scripts/gate-pr-review-state.py" \
  && echo "== shared scripts identical" || { echo "== shared scripts DIFFER"; fail=1; }
exit $fail
