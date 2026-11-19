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
# The scan reads the files git lists in .github (workflows, scripts, actions, CODEOWNERS), the root
# install.sh, both skills' templates and scripts, and tests/: the tracked ones and the untracked
# ones that .gitignore does not hide (`git ls-files -z --cached --others --exclude-standard`). It
# passes the list to grep as file operands, 100 at a time. It has no --exclude, no --exclude-dir
# and no skip by name or path, so a file is read whatever it is called, in whatever folder, and
# whatever the path of the checkout (a checkout under a folder called work-projects is read like
# any other). A new file is read before it is `git add`ed. Only what .gitignore hides is not read:
# the suites' scratch directories (state-*/, work-*/), whether a red run left them behind or not.
# git's pathspec variables (GIT_LITERAL_PATHSPECS and GIT_NOGLOB_PATHSPECS) are set to 0 for the
# listing, so a caller's value cannot turn the `*` in a pathspec into a literal and empty the list.
# It fails closed: when git cannot answer, when ROOT is not the top of its own repository (then
# `git ls-files` would list nothing or another repository's files), when the list is empty, and
# when grep exits with anything but 0 or 1 (a listed file it cannot read, for example). The pattern
# below is written in pieces, so this file does not match it.
# tests/scan/run.sh drives this function against planted trees.
model_key_scan() {
  local list top f i hits="" out rc bad=0 files=()
  if ! list="$(mktemp)"; then
    echo "== mktemp failed, so the model-key scan cannot list the files"; fail=1; return
  fi
  if ! top="$(git -C "$ROOT" rev-parse --show-toplevel 2>&1)" \
     || ! env GIT_LITERAL_PATHSPECS=0 GIT_NOGLOB_PATHSPECS=0 git -C "$ROOT" ls-files -z \
          --cached --others --exclude-standard -- .github install.sh \
          '.agents/skills/*/templates/*' '.agents/skills/*/scripts/*' tests \
          >"$list" 2>/dev/null; then
    echo "== git ls-files failed, so the model-key scan cannot list the files it must read"; bad=1
  elif [ "$(cd "$top" 2>/dev/null && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
    echo "== $ROOT is not the top of its own git repository, so the model-key scan cannot tell"
    echo "   which files to read"; bad=1
  else
    while IFS= read -r -d '' f; do files+=("$ROOT/$f"); done <"$list"
    if [ "${#files[@]}" -eq 0 ]; then
      echo "== git lists no file in .github, install.sh, templates, scripts or tests"; bad=1
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
      echo "== a model action or provider key appears in a file of .github, install.sh, a"
      echo "   template, a script or a test:"; printf '%s' "$hits" | sed 's/^/   /'; bad=1
    fi
    if [ "$err" -ne 0 ]; then
      echo "== the model-key scan could not read a listed file (grep exited with an error)"; bad=1
    fi
    [ "$bad" -ne 0 ] || echo "== no model action or provider key in ${#files[@]} files" \
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
# Every skill states the summary shape, so the three reports read the same way to a person: the
# reviewer's template, the fixer's closure rule, the merge fixer's closure rule and the shared protocol.
# The phrase is a presence check. Where the file holds a template, one structural line of that
# template must also be there (the short table's last row), so a template that drops its summary
# table fails even when the sentence describing it stays. The protocol holds no template.
for spec in \
  "pr-reviewer/references/report-contract.md|## Summary standard|^\| \*\*Next\*\* \| 🔧 pr-fixer" \
  "pr-fixer/references/falsify-and-prove.md|Summary first, same shape|^\| \*\*Next\*\* \| 🔁 reviewer pass" \
  "pr-merge-fixer/SKILL.md|Same summary shape as the other two skills|^\| \*\*Next\*\* \| 🔁 reviewer pass" \
  "pr-reviewer/references/pr-protocol.md|Summary shape, the same in all three skills|" \
  "pr-reviewer/references/pr-protocol.md|Links in a comment or in a pull request body are absolute|"; do
  rel="${spec%%|*}"; rest="${spec#*|}"; phrase="${rest%%|*}"; shape="${rest#*|}"
  f="$ROOT/.agents/skills/$rel"
  if grep -qF "$phrase" "$f" && { [ -z "$shape" ] || grep -qE "$shape" "$f"; }; then
    echo "== summary standard in $rel"
  else
    echo "== summary standard MISSING from $rel (sentence or template table)"; fail=1
  fi
done
# One version for both skills: VERSION, each SKILL.md metadata.version and the newest CHANGELOG entry.
v_root="$(tr -d '[:space:]' < "$ROOT/VERSION")"
v_rev="$("$ROOT/.agents/skills/pr-reviewer/scripts/check-version.sh" --installed)"
v_fix="$("$ROOT/.agents/skills/pr-fixer/scripts/check-version.sh" --installed)"
v_mrg="$("$ROOT/.agents/skills/pr-merge-fixer/scripts/check-version.sh" --installed)"
v_log="$(grep -m1 -E '^## \[?[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/CHANGELOG.md" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -n "$v_root" ] && [ "$v_root" = "$v_rev" ] && [ "$v_root" = "$v_fix" ] && [ "$v_root" = "$v_mrg" ] && [ "$v_root" = "$v_log" ]; then
  echo "== versions agree ($v_root)"
else
  echo "== versions DIFFER: VERSION=$v_root pr-reviewer=$v_rev pr-fixer=$v_fix pr-merge-fixer=$v_mrg CHANGELOG=$v_log"; fail=1
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
# The merge fixer's copies of the shared scripts are compared, file by file, with the reviewer's copy,
# or with pr-fixer's when the reviewer does not ship it (push-guard.sh). A script no other skill ships
# fails: every script in the merge fixer is a copy.
for f in "$ROOT"/.agents/skills/pr-merge-fixer/scripts/*; do
  [ -f "$f" ] || continue; b="$(basename "$f")"; g=""
  for s in pr-reviewer pr-fixer; do
    [ -e "$ROOT/.agents/skills/$s/scripts/$b" ] && { g="$ROOT/.agents/skills/$s/scripts/$b"; break; }
  done
  [ -n "$g" ] || { echo "== scripts/$b in pr-merge-fixer has no copy in another skill"; fail=1; continue; }
  cmp -s "$f" "$g" || { echo "== scripts/$b DIFFERS between pr-merge-fixer and $(basename "$(dirname "$(dirname "$g")")")"; fail=1; }
done
# Shared reference files ship in all three skills and must stay identical. The gate template ships in
# the two skills that run the gate; pr-merge-fixer has none.
for f in references/pr-protocol.md references/harness-matrix.md references/harness-loop.md templates/review-gate.yml; do
  cmp -s "$ROOT/.agents/skills/pr-reviewer/$f" "$ROOT/.agents/skills/pr-fixer/$f" \
    && echo "== $f identical" || { echo "== $f DIFFERS between the skills"; fail=1; }
done
for f in references/pr-protocol.md references/harness-matrix.md references/harness-loop.md; do
  cmp -s "$ROOT/.agents/skills/pr-reviewer/$f" "$ROOT/.agents/skills/pr-merge-fixer/$f" \
    && echo "== $f identical in pr-merge-fixer" || { echo "== $f DIFFERS in pr-merge-fixer"; fail=1; }
done
# The merge fixer runs the project's build, tests and lockfile regeneration on the pull request's code,
# so `review-cycle.sh fix` (the fork and collaborator guard) must run before its first write on every
# pull request, reviewed or not. Its text may not make that step conditional or skippable.
mrg_skill="$ROOT/.agents/skills/pr-merge-fixer/SKILL.md"; mrg_conf="$ROOT/.agents/skills/pr-merge-fixer/references/conflicts.md"
mrg_bad="$(grep -nE 'no cycle to take|Take the cycle when the review owes one|only when a verdict is owed|when a verdict is owed or present' "$mrg_skill" "$mrg_conf")"
if [ -z "$mrg_bad" ] \
   && grep -qE '^1\. \*\*Run the guard on every pull request\.\*\* `scripts/review-cycle\.sh fix <pr>`' "$mrg_skill" \
   && grep -qE '^1\. `scripts/review-cycle\.sh fix <pr>` on every pull request' "$mrg_conf"; then
  echo "== pr-merge-fixer runs review-cycle.sh fix before any write on every pull request"
else
  echo "== pr-merge-fixer may skip review-cycle.sh fix before its first write:"; printf '%s\n' "$mrg_bad"; fail=1
fi
# `review-cycle.sh fix` with no number reads the pull request of the checked-out branch (pr-json.py
# calls `gh pr view` with none), so the guard can pass for a PR other than the one being worked on.
# One mechanical rule over every Markdown file of the three skills, descriptive mentions included:
# each occurrence carries the `<pr>` argument. Checked per occurrence, not per line, with a floor so
# a wrong path cannot pass with nothing found.
fix_all="$(cd "$ROOT" && grep -rnoE 'review-cycle\.sh fix.{0,5}' --include='*.md' .agents/skills || true)"
n_fix="$(printf '%s\n' "$fix_all" | grep -c 'review-cycle' || true)"
fix_bad="$(printf '%s\n' "$fix_all" | grep 'review-cycle' | grep -vE 'review-cycle\.sh fix <pr>' || true)"
if [ "$n_fix" -ge 10 ] && [ -z "$fix_bad" ]; then
  echo "== review-cycle.sh fix names the pull request in all $n_fix mentions in the skills"
else
  echo "== review-cycle.sh fix without a pull request number ($n_fix mentions found, at least 10 expected):"
  printf '%s\n' "$fix_bad"; fail=1
fi
# The loop setup reads the REVIEW_BLOCK_AT repository variable. gh prints a 404 body on stdout and
# exits 1, so the setup must take a value only on exit 0, read a 404 as unset (critical), and stop on
# any other failure. The setup lines are taken from harness-loop.md and run against a stub gh.
rba_src="$(awk '/^rba_err=/{on=1} on{print} on&&/^rm -f "\$rba_err"/{exit}' \
  "$ROOT/.agents/skills/pr-reviewer/references/harness-loop.md")"
mkdir -p "$OUT/rba-bin"
cat >"$OUT/rba-bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$RBA_MODE" in
  set) echo warning ;;
  404) echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  403) echo '{"message":"Resource not accessible by integration","status":"403"}'
       echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
esac
STUB
chmod +x "$OUT/rba-bin/gh"
rba_run() { RBA_MODE="$1" PATH="$OUT/rba-bin:$PATH" bash -c "$rba_src"$'\n''printf "%s" "$REVIEW_BLOCK_AT"' 2>&1; }
if [ "$(printf '%s\n' "$rba_src" | wc -l)" -ge 5 ] && [ "$(rba_run set)" = warning ] \
   && [ "$(rba_run 404)" = critical ] \
   && rba_403="$(rba_run 403)" && printf %s "$rba_403" | grep -q '^setup stopped: .*HTTP 403' \
   && [ "${rba_403##*$'\n'}" = unreadable ]; then
  echo "== loop setup reads REVIEW_BLOCK_AT: set, 404 as critical, 403 stops"
else
  echo "== loop setup misreads REVIEW_BLOCK_AT (set: '$(rba_run set)', 404: '$(rba_run 404)', 403: '$(rba_run 403)')"; fail=1
fi
# A fixer that stops with `conflict owed to pr-merge-fixer` sends the loop back to step 0 (the merge
# fixer), not to step 2, or every cycle ends the same way until the budget is spent.
fix_row="$(grep -E '^ *\| `fix` \|' "$ROOT/.agents/skills/pr-reviewer/references/harness-loop.md")"
if printf %s "$fix_row" | grep -qE 'reports `conflict owed to pr-merge-fixer`[^|]*then go to step 0'; then
  echo "== the loop's fix row returns to step 0 on conflict owed"
else
  echo "== the loop's fix row does not return to step 0 when the fixer reports conflict owed"; fail=1
fi
cmp -s "$ROOT/.agents/skills/pr-reviewer/templates/review-gate.yml" "$ROOT/.github/workflows/review-gate.yml" \
  && echo "== review-gate.yml matches its template" || { echo "== review-gate.yml DIFFERS from its template"; fail=1; }
# The model-key scan runs here, last: see model_key_scan, defined near the top.
model_key_scan
exit $fail
