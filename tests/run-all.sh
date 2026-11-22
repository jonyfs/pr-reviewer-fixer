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
# Each suite records its own wall time in seconds, so a slow one is named in the log (the suites run together,
# so the total is the slowest one, not the sum).
# --only <words> runs just the suites whose name holds one of the comma-separated words, for iteration on one
# change. It is never a substitute for the full run: a PASSED verdict or a merge needs the full
# run with no filter. Unset, every suite runs.
# The filter comes from the command line only, never from the caller's environment, as the other settings here do.
unset RUN_ONLY
unset PRINT_KEY
FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) RUN_ONLY="${2:-}"; shift 2
      case "$RUN_ONLY" in ''|,*|*,|*,,*) echo "run-all: --only needs comma-separated words, none of them empty" >&2; exit 2 ;; esac ;;
    --fresh) FRESH=1; shift ;;
    --print-key) PRINT_KEY=1; shift ;;
    *) echo "run-all: unknown option $1" >&2; exit 2 ;;
  esac
done
# THE SUITE CACHE. A full run of an identical tree (the commit, its uncommitted changes, and the untracked files) that
# already passed is not run again: the key is written only after a green full run, and a filtered run never reads or
# writes it. --fresh runs everything; the run before a PASSED verdict or a merge is always --fresh. The cache lives in
# the user's cache folder and is only as good as this key: a change anywhere in the tree changes it.
CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-}/.cache}/pr-reviewer-fixer/run-all"
tree_key() {
  # Every input a suite can read: the commit, the tracked changes (git diff carries mode changes too), and each
  # untracked file by NAME, MODE and CONTENT. A symbolic link is keyed by its target, never followed (a link to a
  # device or a huge file would hang the key). Names are NUL-separated: spaces, tabs and non-ASCII names are kept.
  # The toolchain is part of the key: a different git, shell or python is a different run.
  {
    git -C "$ROOT" rev-parse HEAD 2>/dev/null
    git -C "$ROOT" -c core.quotePath=false diff --no-ext-diff --text HEAD -- 2>/dev/null
    git -C "$ROOT" ls-files -o --exclude-standard -z -- . ':!.claude' 2>/dev/null | while IFS= read -r -d '' f; do
      printf 'untracked %s\0' "$f"
      if [ -L "$ROOT/$f" ]; then printf 'link %s\0' "$(readlink "$ROOT/$f" 2>/dev/null)"
      elif [ -f "$ROOT/$f" ]; then
        if [ -x "$ROOT/$f" ]; then printf 'mode x\0'; else printf 'mode -\0'; fi
        git -C "$ROOT" hash-object --no-filters -- "$f" 2>/dev/null
      else printf 'other\0'; fi
    done
    printf 'toolchain %s | %s | %s | %s | %s | %s | %s\n' "$(git --version 2>/dev/null)" "$(bash --version 2>/dev/null | head -n 1)" \
      "$(python3 -V 2>&1)" "$(uname -sm 2>/dev/null)" "$(node -v 2>/dev/null)" "$(jq --version 2>/dev/null)" \
      "$(curl --version 2>/dev/null | head -n 1)"
    # the user's global git configuration changes what git diff and git hash-object produce: its digest is part of the key
    shasum -a 256 "${HOME:-/dev/null}/.gitconfig" "${XDG_CONFIG_HOME:-${HOME:-/dev/null}/.config}/git/config" 2>/dev/null
  } | shasum -a 256 2>/dev/null | cut -d' ' -f1
}
if [ "${PRINT_KEY:-0}" = 1 ]; then tree_key; exit 0; fi
KEY=""
if [ -z "${RUN_ONLY:-}" ]; then
  KEY="$(tree_key)"   # computed on every full run: a --fresh run writes the key too
  if [ "$FRESH" = 0 ] && [ -n "$KEY" ] && [ -f "$CACHE_DIR/$KEY" ]; then
    echo "== run-all: this exact tree already passed a full run (key ${KEY:0:12}); nothing re-run. Pass --fresh to run every suite."
    exit 0
  fi
fi
started=0
start() {
  local n="$1" pat keep="" words
  shift
  if [ -n "${RUN_ONLY:-}" ]; then
    IFS=',' read -ra words <<<"$RUN_ONLY"
    for pat in "${words[@]}"; do case "$n" in *"$pat"*) keep=1 ;; esac; done
    [ -n "$keep" ] || return 0
  fi
  started=$((started + 1))
  # A nested call (the refusals suite calls this file) never starts a suite: it refuses here, so a broken
  # refusal above cannot make the run call itself without end (PR 60 pass 3, W3).
  if [ -n "${RUN_ALL_NESTED:-}" ]; then echo "run-all: a nested run starts no suite" >&2; exit 3; fi
  names+=("$n"); ( t0=$(date +%s); "$@" >"$OUT/${#names[@]}.log" 2>&1; echo $? >"$OUT/${#names[@]}.rc"; echo $(( $(date +%s) - t0 )) >"$OUT/${#names[@]}.secs" ) & pids+=($!); }
run_t0=$(date +%s)
# The shared scripts run once, from the reviewer's copy: the cmp checks below fail when the fixer's
# copy differs by one byte, so a second run of the same bytes adds time and no coverage.
start "review-cycle.sh and gate"                 env TEST_TAG="${P}rev" bash "$HERE/fake-gh/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "triage-pr.sh"                             env TEST_TAG="${P}run" bash "$HERE/fake-gh/triage/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "push-guard.sh"                             env TEST_TAG="${P}run" bash "$HERE/push-guard/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "fetch-feedback.py"                        env TEST_TAG="${P}run" python3 "$HERE/feedback/t.py" "$ROOT/.agents/skills/pr-fixer/scripts"
start "review eval scorer"                       env TEST_TAG="${P}run" bash "$HERE/eval/selftest.sh"
start "install.sh"                                env TEST_TAG="${P}run" bash "$HERE/install/run.sh" "$ROOT/install.sh"
start "install-remote.sh"                         env TEST_TAG="${P}run" bash "$HERE/remote/run.sh"
start "remote-review.sh"                          env TEST_TAG="${P}run" bash "$HERE/remote-review/run.sh"
start "preflight (scratch repositories)"         env TEST_TAG="${P}run" bash "$HERE/preflight/run.sh"
start "run-all --only refusals"                env TEST_TAG="${P}run" bash "$HERE/run-only/run.sh"
start "run-all cache key and refusals"             env TEST_TAG="${P}run" bash "$HERE/run-cache/run.sh"
start "mutation check (guards)"                 env TEST_TAG="${P}run" bash "$HERE/mutation/run.sh"
start "cycle budget and extend"                  env TEST_TAG="${P}rev" python3 "$HERE/budget/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "scan-hidden.py"                           env TEST_TAG="${P}rev" python3 "$HERE/scan-hidden/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "check-version.sh"                         env TEST_TAG="${P}rev" bash "$HERE/version/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "release.sh"                                env TEST_TAG="${P}run" bash "$HERE/release/run.sh"
start "update.sh"                                 env TEST_TAG="${P}rev" bash "$HERE/update/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts" "$ROOT/install.sh"
start "model-key scan"                            env TEST_TAG="${P}run" bash "$HERE/scan/run.sh"
wait ${pids[@]+"${pids[@]}"}
if [ -n "${RUN_ONLY:-}" ] && [ "$started" = 0 ]; then
  echo "run-all: --only $RUN_ONLY matches no suite; nothing ran" >&2; exit 1
fi
echo "== all suites: $(( $(date +%s) - run_t0 ))s wall${RUN_ONLY:+ (only: $RUN_ONLY: NOT the full run; a PASSED verdict or a merge needs the full run)}"
for i in "${!names[@]}"; do
  n=$((i + 1)); echo "== ${names[$i]} ($(cat "$OUT/$n.secs" 2>/dev/null || echo ?)s)"; tail -n 3 "$OUT/$n.log"
  [ "$(cat "$OUT/$n.rc" 2>/dev/null || echo 1)" -eq 0 ] || fail=1
done
# Every skill states the summary shape, so the three reports read the same way to a person: the
# reviewer's template, the fixer's closure rule, the merge fixer's closure rule and the shared protocol.
# The phrase is a presence check. Where the file holds a template, one structural line of that
# template must also be there (the plain `Next:` line that ends the summary lines), so a template
# that drops its summary fails even when the sentence describing it stays. The protocol holds no
# template.
for spec in \
  "pr-reviewer/references/report-contract.md|## Summary standard|^Next: pr-fixer" \
  "pr-fixer/references/falsify-and-prove.md|Summary first, same shape|^Next: reviewer pass" \
  "pr-merge-fixer/SKILL.md|Same summary shape as the other two skills|^Next: reviewer pass" \
  "pr-reviewer/references/pr-protocol.md|Summary shape, the same in all three skills|" \
  "pr-reviewer/references/pr-protocol.md|Links in a comment or in a pull request body are absolute|"; do
  rel="${spec%%|*}"; rest="${spec#*|}"; phrase="${rest%%|*}"; shape="${rest#*|}"
  f="$ROOT/.agents/skills/$rel"
  if grep -qF "$phrase" "$f" && { [ -z "$shape" ] || grep -qE "$shape" "$f"; }; then
    echo "== summary standard in $rel"
  else
    echo "== summary standard MISSING from $rel (sentence or template Next: line)"; fail=1
  fi
done
# Agent comments are plain text: Markdown belongs in the pull request description only. A comment
# template is a fenced block in a skill's Markdown whose first line is a protocol marker. Outside its
# own `findings` fence, a template may hold no table row, heading, bold, bullet, checkbox, quote or
# other fenced block (Mermaid included). A floor on the templates found keeps a wrong path from
# passing with nothing read.
if ! plain_out="$(python3 -I - "$ROOT/.agents/skills" <<'PY'
import os, re, sys
markers = ("<!-- adversarial-review:", "<!-- pr-fixer-closure:", "<!-- pr-merge-fixer-closure:",
           "<!-- pr-skill-status:")
rules = [(re.compile(r"^\s*\|"), "table row"), (re.compile(r"^\s*#{1,6}\s"), "heading"),
         (re.compile(r"\*\*|__\S"), "bold"), (re.compile(r"^\s*([-*+]|\d+[.)])\s"), "list item"),
         (re.compile(r"^\s*>"), "quote")]
found, bad = 0, []
for d, _, fs in os.walk(sys.argv[1]):
    for name in sorted(fs):
        if not name.endswith(".md"):
            continue
        path = os.path.join(d, name)
        lines = open(path, encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            m = re.match(r"^(\s*)(`{3,})", lines[i])
            if not m:
                i += 1; continue
            n, start = len(m.group(2)), i
            close = re.compile(r"^\s*`{%d,}\s*$" % n)
            i += 1; body = []
            while i < len(lines) and not close.match(lines[i]):
                body.append((i + 1, lines[i])); i += 1
            i += 1
            first = next((t.strip() for _, t in body if t.strip()), "")
            if not first.startswith(markers):
                continue
            found += 1
            inner = None
            for ln, t in body:
                f = re.match(r"^\s*(`{3,})\s*(\S*)", t)
                if inner is not None:
                    if f and len(f.group(1)) >= len(inner) and not f.group(2):
                        inner = None
                    continue
                if f:
                    if f.group(2) != "findings":
                        bad.append("%s:%d fenced block %s" % (path, ln, f.group(2) or "(untagged)"))
                    inner = f.group(1); continue
                for rx, what in rules:
                    if rx.search(t):
                        bad.append("%s:%d %s" % (path, ln, what))
print(found)
for b in bad:
    print(b)
sys.exit(1 if bad or found < 5 else 0)
PY
)"; then
  echo "== a comment template holds Markdown (templates found, then each offending line):"
  printf '%s\n' "$plain_out" | sed "s|$ROOT/||"; fail=1
else
  echo "== agent comment templates are plain text ($(printf '%s\n' "$plain_out" | head -n 1) templates)"
fi
# 0.20.1 wording rules: each must stay in its file, or the defect it closes returns.
for check in \
  "pr-reviewer/references/harness-loop.md|json mergeable,mergeStateStatus|read both fields (N1)" \
  "pr-merge-fixer/references/conflicts.md|Stage the resolved files, then run|the staged screen runs before the commit (N9)" \
  "pr-merge-fixer/SKILL.md|screen --file <file>|the closure is screened before posting (N10)" \
  "pr-merge-fixer/SKILL.md|Never set \`PUSH_GUARD_ALLOW_SENSITIVE\` yourself|the merge fixer never sets the allow variable (N11)"; do
  rel="${check%%|*}"; rest="${check#*|}"; phrase="${rest%%|*}"; why="${rest#*|}"
  grep -qF "$phrase" "$ROOT/.agents/skills/$rel" \
    && echo "== $why" || { echo "== MISSING from $rel: $why"; fail=1; }
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
# Without pr-merge-fixer installed, step 0 skips itself, so a fix row that sent a conflict there
# would circle with no dispatch, no cycle spent and no stop. The row stops and names the install
# command instead. This guards the wording only, not the path the loop agent takes.
if printf %s "$fix_row" | grep -qE 'pr-merge-fixer/SKILL.md` is not installed, do not go to step 0[^|]*stop, and tell the person' \
   && printf %s "$fix_row" | grep -qF 'install.sh --harness <name> --skill pr-merge-fixer --yes'; then
  echo "== the loop's fix row stops on a conflict when pr-merge-fixer is not installed"
else
  echo "== the loop's fix row has no stop for a conflict when pr-merge-fixer is not installed"; fail=1
fi
# The merge fixer reads the PR text and commit messages for intent, so step 0 scans them for hidden
# text and passes the hits in its brief, and the merge fixer never takes flagged text as evidence.
step0="$(awk '/^0\. \*\*Conflicts first/{on=1} on&&/^1\. \*\*Read the state/{exit} on{print}' \
  "$ROOT/.agents/skills/pr-reviewer/references/harness-loop.md")"
if printf %s "$step0" | grep -q 'scan-hidden.py --pr <pr>' \
   && printf %s "$step0" | grep -q 'Hidden-content hits: <hidden.json' \
   && grep -q 'is never evidence of intent' "$ROOT/.agents/skills/pr-merge-fixer/SKILL.md" \
   && grep -q 'never evidence of intent' "$ROOT/.agents/skills/pr-merge-fixer/references/conflicts.md"; then
  echo "== step 0 passes hidden-content hits to the merge fixer, which never takes flagged text as intent"
else
  echo "== step 0 or the merge fixer does not handle hidden-content hits"; fail=1
fi
cmp -s "$ROOT/.agents/skills/pr-reviewer/templates/review-gate.yml" "$ROOT/.github/workflows/review-gate.yml" \
  && echo "== review-gate.yml matches its template" || { echo "== review-gate.yml DIFFERS from its template"; fail=1; }
# The model-key scan runs here, last: see model_key_scan, defined near the top.
model_key_scan
# Only a green full run is written to the cache (see the cache note above).
if [ "$fail" = 0 ] && [ -z "${RUN_ONLY:-}" ] && [ -n "${KEY:-}" ]; then
  mkdir -p "$CACHE_DIR" 2>/dev/null && : >"$CACHE_DIR/$KEY" 2>/dev/null
fi
exit $fail
