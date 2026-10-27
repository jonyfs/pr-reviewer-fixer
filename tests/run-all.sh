#!/usr/bin/env bash
# Runs every test against fake `gh` binaries. No network and no GitHub access needed.
# Needs: bash, python3, node, jq, git, curl, tar and sha256sum.
set -u
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what the scripts refuse, so
# every suite starts without them; a row that needs one sets it itself.
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
# A caller's TEST_TAG becomes a prefix of each suite's own tag, so two runs of this file with
# different tags never share a scratch directory.
P="${TEST_TAG:+$TEST_TAG-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
# No workflow, template or script may call a model or name a provider key. Review and fix run as
# agents in a person's own harness session, never in GitHub Actions.
# The suites' own scratch directories (state-*/ and work-*/, gitignored) hold copies of the skills
# and of whatever a run fed them, and a run in progress or a red run leaves them behind, so the scan
# skips them under tests/ and nowhere else. That loses nothing only while no tracked file anywhere
# sits in a folder with such a name, which is checked first and fails closed when git cannot answer.
model_key_scan() {
  local tracked bad=0
  if ! tracked="$(git -C "$ROOT" ls-files 2>&1)"; then
    echo "== git ls-files failed, so the model-key scan cannot tell tracked files from scratch ones"; bad=1
  elif printf '%s\n' "$tracked" | grep -Eq '(^|/)(state|work)-[^/]*/'; then
    echo "== a tracked file sits in a state-* or work-* folder, which the model-key scan skips under tests/"; bad=1
  fi
  local pat='claude-code-action|codex-action|anthropic_api_key|openai_api_key|fixer_push_token|anthropics/|openai/codex' rc1 rc2
  grep -rniE "$pat" "$ROOT/.github/workflows" "$ROOT/.github/scripts" "$ROOT"/.agents/skills/*/templates \
       "$ROOT"/.agents/skills/*/scripts --exclude=run-all.sh >/dev/null; rc1=$?
  grep -rniE "$pat" "$ROOT/tests" --exclude=run-all.sh --exclude-dir='state-*' --exclude-dir='work-*' >/dev/null; rc2=$?
  if [ "$rc1" -eq 0 ] || [ "$rc2" -eq 0 ]; then
    echo "== a model action or provider key appears in a workflow, template, script or test"; bad=1
  elif [ "$rc1" -ne 1 ] || [ "$rc2" -ne 1 ]; then
    echo "== the model-key scan could not read a tree (grep exit $rc1 and $rc2)"; bad=1
  elif [ "$bad" -eq 0 ]; then
    echo "== no model action or provider key in workflows, workflow scripts, templates, scripts or tests"
  fi
  [ "$bad" -eq 0 ] || fail=1
}
# `run-all.sh --scan-only` runs this scan alone, without the suites.
if [ "${1:-}" = "--scan-only" ]; then model_key_scan; exit $fail; fi
# The independent suites run at the same time, each with its own scratch directory (TEST_TAG), and
# print in a fixed order afterwards.
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
# A version-manager shim (pyenv, asdf) costs a few hundred ms per python3, and the suites start it
# thousands of times. A link to the interpreter the shim resolves to goes first on PATH; that halves
# the run on a machine with a shim and changes nothing on one without.
# Inside a virtual environment the link is not made: a link outside the venv's folder loses its
# pyvenv.cfg, and with it the venv's packages. The suites use only the standard library today.
mkdir -p "$OUT/python"
PYEXE="$(python3 -I -c 'import sys; print(sys.executable if sys.prefix == sys.base_prefix else "")' 2>/dev/null)" \
  && [ -n "$PYEXE" ] && [ -x "$PYEXE" ] && ln -sf "$PYEXE" "$OUT/python/python3"
export PATH="$OUT/python:$PATH"
names=(); pids=()
start() { local n="$1"; shift; names+=("$n"); ( "$@" >"$OUT/${#names[@]}.log" 2>&1; echo $? >"$OUT/${#names[@]}.rc" ) & pids+=($!); }
# The shared scripts run once, from the reviewer's copy: the cmp checks below fail when the fixer's
# copy differs by one byte, so a second run of the same bytes adds time and no coverage.
start "review-cycle.sh and gate"                 env TEST_TAG="${P}rev" bash "$HERE/fake-gh/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "triage-pr.sh"                             env TEST_TAG="${P}run" bash "$HERE/fake-gh/triage/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "push-guard.sh"                             env TEST_TAG="${P}run" bash "$HERE/push-guard/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "fetch-feedback.py"                        env TEST_TAG="${P}run" python3 "$HERE/feedback/t.py" "$ROOT/.agents/skills/pr-fixer/scripts"
start "review eval scorer"                       env TEST_TAG="${P}run" bash "$HERE/eval/selftest.sh"
start "install.sh"                                env TEST_TAG="${P}run" bash "$HERE/install/run.sh" "$ROOT/install.sh"
start "cycle budget and extend"                  env TEST_TAG="${P}rev" python3 "$HERE/budget/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "scan-hidden.py"                           env TEST_TAG="${P}rev" python3 "$HERE/scan-hidden/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "check-version.sh"                         env TEST_TAG="${P}rev" bash "$HERE/version/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "release.sh"                                env TEST_TAG="${P}run" bash "$HERE/release/run.sh"
start "update.sh"                                 env TEST_TAG="${P}rev" bash "$HERE/update/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts" "$ROOT/install.sh"
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
# Every script that ships in both skills must be byte-identical: the suites above run them from the
# reviewer's copy only. The list is found, not written down, so a new shared script is covered too.
n_shared=0
for f in "$ROOT"/.agents/skills/pr-reviewer/scripts/*; do
  [ -f "$f" ] || continue; b="$(basename "$f")"; g="$ROOT/.agents/skills/pr-fixer/scripts/$b"
  [ -e "$g" ] || continue; n_shared=$((n_shared + 1))
  cmp -s "$f" "$g" || { echo "== scripts/$b DIFFERS between the skills"; fail=1; }
done
[ "$n_shared" -ge 6 ] && echo "== $n_shared shared scripts checked" || { echo "== only $n_shared shared scripts found; expected at least 6"; fail=1; }
# Shared reference files and the gate template ship in both skills and must stay identical.
for f in references/pr-protocol.md references/harness-matrix.md references/harness-loop.md templates/review-gate.yml; do
  cmp -s "$ROOT/.agents/skills/pr-reviewer/$f" "$ROOT/.agents/skills/pr-fixer/$f" \
    && echo "== $f identical" || { echo "== $f DIFFERS between the skills"; fail=1; }
done
cmp -s "$ROOT/.agents/skills/pr-reviewer/templates/review-gate.yml" "$ROOT/.github/workflows/review-gate.yml" \
  && echo "== review-gate.yml matches its template" || { echo "== review-gate.yml DIFFERS from its template"; fail=1; }
# The model-key scan runs here, last: see model_key_scan, defined near the top.
model_key_scan
exit $fail
