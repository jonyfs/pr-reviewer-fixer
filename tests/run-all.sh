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
# No workflow, template, action, script or test may call a model or name a provider key. Review and
# fix run as agents in a person's own harness session, never in GitHub Actions.
# The scan reads exactly the files git tracks in .github (workflows, scripts, actions, CODEOWNERS),
# the root install.sh, both skills' templates and scripts, and tests/. It takes the list from
# `git ls-files -z` and passes it to grep as file operands. It has no --exclude, no --exclude-dir
# and no skip by name or path, so a tracked file is read whatever it is called, in whatever folder,
# and whatever the path of the checkout (a checkout under a folder called work-projects is read
# like any other). The suites' scratch directories (state-*/, work-*/) are untracked and gitignored,
# so they are never read, whether a red run left them behind or not; a new file is read once it is
# added to the index (`git add`). It fails closed: when git cannot answer, when ROOT is not the top
# of its own repository (then `git ls-files` would list nothing or another repository's files),
# when the list is empty, and when grep exits with anything but 0 or 1 (a tracked file it cannot
# read, for example). The pattern below is written in pieces, so this file does not match it.
# tests/scan/run.sh drives this function against planted trees.
model_key_scan() {
  local list top f i hits="" out rc bad=0 files=()
  if ! list="$(mktemp)"; then
    echo "== mktemp failed, so the model-key scan cannot list the tracked files"; fail=1; return
  fi
  if ! top="$(git -C "$ROOT" rev-parse --show-toplevel 2>&1)" \
     || ! git -C "$ROOT" ls-files -z -- .github install.sh '.agents/skills/*/templates/*' \
          '.agents/skills/*/scripts/*' tests >"$list" 2>/dev/null; then
    echo "== git ls-files failed, so the model-key scan cannot tell which files are tracked"; bad=1
  elif [ "$(cd "$top" 2>/dev/null && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
    echo "== $ROOT is not the top of its own git repository, so the model-key scan cannot tell"
    echo "   which files are tracked"; bad=1
  else
    while IFS= read -r -d '' f; do files+=("$ROOT/$f"); done <"$list"
    if [ "${#files[@]}" -eq 0 ]; then
      echo "== git lists no tracked file in .github, install.sh, templates, scripts or tests"; bad=1
    fi
  fi
  rm -f "$list"
  if [ "$bad" -eq 0 ]; then
    local pat='claude-code-''action|codex-''action|anthropic''_api_key|openai''_api_key'
    pat="$pat"'|fixer_push''_token|anthropic''s/|openai/''codex'
    local err=0
    for ((i = 0; i < ${#files[@]}; i += 100)); do
      out="$(grep -liE -e "$pat" -- "${files[@]:i:100}" 2>/dev/null)"; rc=$?
      [ -z "$out" ] || hits="$hits$out"$'\n'
      [ "$rc" -le 1 ] || err=1
    done
    if [ -n "$hits" ]; then
      echo "== a model action or provider key appears in a tracked file of .github, install.sh, a"
      echo "   template, a script or a test:"; printf '%s' "$hits" | sed 's/^/   /'; bad=1
    fi
    if [ "$err" -ne 0 ]; then
      echo "== the model-key scan could not read a tracked file (grep exited with an error)"; bad=1
    fi
    [ "$bad" -ne 0 ] || echo "== no model action or provider key in ${#files[@]} tracked files" \
      "of .github, install.sh, templates, scripts and tests"
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
start "model-key scan"                            env TEST_TAG="${P}run" bash "$HERE/scan/run.sh"
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
