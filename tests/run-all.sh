#!/usr/bin/env bash
# Runs every test against fake `gh` binaries. No network and no GitHub access needed.
# Needs: bash, python3, node, jq.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
# The independent suites run at the same time, each with its own scratch directory (TEST_TAG), and
# print in a fixed order afterwards.
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
names=(); pids=()
start() { local n="$1"; shift; names+=("$n"); ( "$@" >"$OUT/${#names[@]}.log" 2>&1; echo $? >"$OUT/${#names[@]}.rc" ) & pids+=($!); }
start "review-cycle.sh and gate (reviewer copy)" env TEST_TAG=rev bash "$HERE/fake-gh/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "review-cycle.sh and gate (fixer copy)"    env TEST_TAG=fix bash "$HERE/fake-gh/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "triage-pr.sh"                             bash "$HERE/fake-gh/triage/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "push-guard.sh"                             env TEST_TAG=run bash "$HERE/push-guard/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "review eval scorer"                       env TEST_TAG=run bash "$HERE/eval/selftest.sh"
start "install.sh"                                env TEST_TAG=run bash "$HERE/install/run.sh" "$ROOT/install.sh"
start "cycle budget and extend (reviewer copy)"  env TEST_TAG=rev python3 "$HERE/budget/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "cycle budget and extend (fixer copy)"     env TEST_TAG=fix python3 "$HERE/budget/t.py" "$ROOT/.agents/skills/pr-fixer/scripts"
start "check-version.sh (reviewer copy)"         env TEST_TAG=rev bash "$HERE/version/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "check-version.sh (fixer copy)"            env TEST_TAG=fix bash "$HERE/version/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
wait "${pids[@]}"
for i in "${!names[@]}"; do
  n=$((i + 1)); echo "== ${names[$i]}"; tail -n 3 "$OUT/$n.log"
  [ "$(cat "$OUT/$n.rc" 2>/dev/null || echo 1)" -eq 0 ] || fail=1
done
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
# Shared reference files and the gate template ship in both skills and must stay identical.
for f in scripts/pr-json.py references/pr-protocol.md references/harness-matrix.md references/harness-loop.md templates/review-gate.yml; do
  cmp -s "$ROOT/.agents/skills/pr-reviewer/$f" "$ROOT/.agents/skills/pr-fixer/$f" \
    && echo "== $f identical" || { echo "== $f DIFFERS between the skills"; fail=1; }
done
cmp -s "$ROOT/.agents/skills/pr-reviewer/templates/review-gate.yml" "$ROOT/.github/workflows/review-gate.yml" \
  && echo "== review-gate.yml matches its template" || { echo "== review-gate.yml DIFFERS from its template"; fail=1; }
# No workflow, template or script may call a model or name a provider key. Review and fix run as
# agents in a person's own harness session, never in GitHub Actions.
if grep -rniE 'claude-code-action|codex-action|anthropic_api_key|openai_api_key|fixer_push_token|anthropics/|openai/codex' \
     "$ROOT/.github/workflows" "$ROOT"/.agents/skills/*/templates "$ROOT"/.agents/skills/*/scripts "$ROOT/tests" \
     --exclude=run-all.sh >/dev/null; then
  echo "== a model action or provider key appears in a workflow, template, script or test"; fail=1
else
  echo "== no model action or provider key in workflows, templates, scripts or tests"
fi
exit $fail
