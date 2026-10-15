#!/usr/bin/env bash
# Runs every test against fake `gh` binaries. No network and no GitHub access needed.
# Needs: bash, python3 with PyYAML, node, jq.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
run() { echo "== $1"; shift; "$@" 2>&1 | tail -n 3; [ "${PIPESTATUS[0]}" -eq 0 ] || fail=1; }

run "review-cycle.sh and gate (reviewer copy)" bash "$HERE/fake-gh/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
run "review-cycle.sh and gate (fixer copy)"    bash "$HERE/fake-gh/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
run "triage-pr.sh"                             bash "$HERE/fake-gh/triage/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
for h in claude codex; do
  run "extension-wait step ($h)" python3 "$HERE/extwait/run.py" "$ROOT/.agents/skills/pr-fixer/templates/pr-review-cycle.$h.yml"
  run "budget logic ($h)"        python3 "$HERE/budget/t.py"    "$ROOT/.agents/skills/pr-fixer/templates/pr-review-cycle.$h.yml"
done
run "check-version.sh (reviewer copy)"         bash "$HERE/version/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
run "check-version.sh (fixer copy)"            bash "$HERE/version/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
# One version for both skills: VERSION, each SKILL.md metadata.version and the newest CHANGELOG entry.
v_root="$(tr -d '[:space:]' < "$ROOT/VERSION")"
v_rev="$("$ROOT/.agents/skills/pr-reviewer/scripts/check-version.sh" --installed)"
v_fix="$("$ROOT/.agents/skills/pr-fixer/scripts/check-version.sh" --installed)"
v_log="$(grep -m1 -E '^## \[?[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/CHANGELOG.md" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -n "$v_root" ] && [ "$v_root" = "$v_rev" ] && [ "$v_root" = "$v_fix" ] && [ "$v_root" = "$v_log" ]; then
  echo "== versions agree ($v_root)"
else
  echo "== versions DIFFER: VERSION=$v_root pr-reviewer=$v_rev pr-fixer=$v_fix CHANGELOG=$v_log"; fail=1
fi
cmp -s "$ROOT/.agents/skills/pr-reviewer/scripts/check-version.sh" "$ROOT/.agents/skills/pr-fixer/scripts/check-version.sh" \
  && echo "== check-version.sh identical" || { echo "== check-version.sh DIFFERS"; fail=1; }
cmp -s "$ROOT/.agents/skills/pr-reviewer/scripts/review-cycle.sh" "$ROOT/.agents/skills/pr-fixer/scripts/review-cycle.sh" \
  && cmp -s "$ROOT/.agents/skills/pr-reviewer/scripts/gate-pr-review-state.py" "$ROOT/.agents/skills/pr-fixer/scripts/gate-pr-review-state.py" \
  && echo "== shared scripts identical" || { echo "== shared scripts DIFFER"; fail=1; }
exit $fail
