#!/usr/bin/env bash
# Runs every test against fake `gh` binaries. No network and no GitHub access needed.
# Needs: bash, python3, node, jq, git, curl, tar, sha256sum and GNU timeout.
set -u
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what the scripts refuse, so
# every suite starts without them; a row that needs one sets it itself.
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
# A caller's TEST_TAG becomes a prefix of each suite's own tag, so two runs of this file with
# different tags never share a scratch directory.
P="${TEST_TAG:+$TEST_TAG-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Every suite runs from the checkout's root, wherever the run was started: some rows resolve the repository from the
# working directory (the gate suite's export-audit rows), so a run started outside the checkout failed them (PR 85 N5,
# PR 88 W1).
cd "$ROOT" || { echo "run-all: cannot enter $ROOT" >&2; exit 2; }
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
# With neither XDG_CACHE_HOME nor HOME set there is no per-user folder: the cache is off, rather than a /.cache that
# every user of the machine would share.
if [ -n "${XDG_CACHE_HOME:-}" ]; then CACHE_DIR="$XDG_CACHE_HOME/pr-reviewer-fixer/run-all"
elif [ -n "${HOME:-}" ]; then CACHE_DIR="$HOME/.cache/pr-reviewer-fixer/run-all"
else CACHE_DIR=""; fi
# A planted key file would skip every suite, so the folder must be this user's alone: a real directory (not a link),
# owned by this user, and writable by nobody else. Anything else turns the cache off. It is created with mode 700. The
# folder above it (pr-reviewer-fixer, made with it) is held to the same rule, since whoever can write there can swap
# the folder for another between the check and the read. The cache root above them (XDG_CACHE_HOME or ~/.cache) is
# checked by cache_root_ok: any owner, and a link is followed, but a root that its group or others can write is
# refused unless it has the sticky bit (as /tmp has), since without it they could rename pr-reviewer-fixer away and
# put their own in its place. find printing the path means OK, so an unreadable root refuses too. The trust boundary
# is the root: its owner and the folders above it are trusted and not checked.
cache_dir_ok() {
  local d
  for d in "$CACHE_DIR" "${CACHE_DIR%/*}"; do
    [ -d "$d" ] && [ ! -L "$d" ] || return 1
    [ -n "$(find "$d" -maxdepth 0 -user "$(id -u)" ! -perm -g+w ! -perm -o+w 2>/dev/null)" ] || return 1
  done
}
CACHE_ROOT="${CACHE_DIR%/*/*}"
cache_root_ok() {
  [ -n "$(find -H "$CACHE_ROOT" -maxdepth 0 -type d \( -perm -1000 -o \( ! -perm -g+w ! -perm -o+w \) \) 2>/dev/null)" ]
}
# sha256sum where it exists (the header names it), shasum -a 256 otherwise: the same digest either way.
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
tree_key() {
  # Every input a suite can read: the commit, the tracked changes (git diff carries mode changes too), and each
  # untracked file by NAME, MODE and CONTENT. A symbolic link is keyed by its target, never followed (a link to a
  # device or a huge file would hang the key). Names are NUL-separated: spaces, tabs and non-ASCII names are kept.
  # The toolchain is part of the key: a different git, shell or python is a different run.
  {
    git -C "$ROOT" rev-parse HEAD 2>/dev/null
    git -C "$ROOT" -c core.quotePath=false diff --no-ext-diff --no-textconv --text HEAD -- 2>/dev/null
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
    # the user's global git configuration changes what git diff and git hash-object produce: its digest is part of the key.
    # The system configuration (git config --system), the repository's own .git/config and .git/info/attributes are
    # not keyed: a change there (a clean filter, for example) needs --fresh.
    sha256 "${HOME:-/dev/null}/.gitconfig" "${XDG_CONFIG_HOME:-${HOME:-/dev/null}/.config}/git/config" \
      "${GIT_CONFIG_GLOBAL:-/dev/null}" 2>/dev/null
  } | sha256 2>/dev/null | cut -d' ' -f1
}
if [ "${PRINT_KEY:-0}" = 1 ]; then tree_key; exit 0; fi
KEY=""
if [ -z "${RUN_ONLY:-}" ] && [ -z "$CACHE_DIR" ]; then
  echo "== run-all: HOME and XDG_CACHE_HOME are unset, so there is no per-user cache folder; the suite cache is off."
elif [ -z "${RUN_ONLY:-}" ]; then
  KEY="$(tree_key)"   # computed on every full run: a --fresh run writes the key too
  if [ -e "$CACHE_DIR" ] && ! cache_root_ok; then
    echo "== run-all: the cache root $CACHE_ROOT is writable by its group or others and has no sticky bit; the suite cache is off. chmod go-w it, or chmod +t it, to turn it back on."
    KEY=""
  elif [ -e "$CACHE_DIR" ] && ! cache_dir_ok; then
    echo "== run-all: the cache folder $CACHE_DIR (or the folder above it) is not this user's alone (another owner, a link, or writable by its group or others); the suite cache is off. If it is yours, chmod 700 both folders, or remove them, to turn it back on."
    KEY=""
  fi
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
start "proof-check.sh"                            env TEST_TAG="${P}run" bash "$HERE/proof-check/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "fetch-feedback.py"                        env TEST_TAG="${P}run" python3 "$HERE/feedback/t.py" "$ROOT/.agents/skills/pr-fixer/scripts"
start "behaviour-diff.sh"                        env TEST_TAG="${P}run" bash "$HERE/behaviour-diff/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "review eval scorer"                       env TEST_TAG="${P}run" bash "$HERE/eval/selftest.sh"
start "lens eval cases well formed"              python3 -I "$HERE/eval/lens_check.py" "$HERE/eval/lens/cases"
start "fixer eval scorer"                        env TEST_TAG="${P}run" bash "$HERE/fixer-eval/selftest.sh"
start "golden set scorer"                        env TEST_TAG="${P}run" bash "$HERE/golden/selftest.sh"
start "install.sh"                                env TEST_TAG="${P}run" bash "$HERE/install/run.sh" "$ROOT/install.sh"
start "install-remote.sh"                         env TEST_TAG="${P}run" bash "$HERE/remote/run.sh"
start "remote-review.sh"                          env TEST_TAG="${P}run" bash "$HERE/remote-review/run.sh"
start "preflight (scratch repositories)"         env TEST_TAG="${P}run" bash "$HERE/preflight/run.sh"
start "run-all --only refusals"                env TEST_TAG="${P}run" bash "$HERE/run-only/run.sh"
start "merge conflict end to end (preflight)"    env TEST_TAG="${P}run" bash "$HERE/merge-integration/run.sh"
start "run-all cache key and refusals"             env TEST_TAG="${P}run" bash "$HERE/run-cache/run.sh"
start "mutation check (guards)"                 env TEST_TAG="${P}run" bash "$HERE/mutation/run.sh"
start "cycle budget and extend"                  env TEST_TAG="${P}rev" python3 "$HERE/budget/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "fix-ledger.sh"                             env TEST_TAG="${P}run" bash "$HERE/fix-ledger/run.sh" "$ROOT/.agents/skills/pr-fixer/scripts"
start "review-metrics.sh"                        env TEST_TAG="${P}rev" bash "$HERE/review-metrics/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "repro-sandbox.sh"                         env TEST_TAG="${P}rev" bash "$HERE/repro-sandbox/run.sh" "$ROOT/.agents/skills/pr-reviewer/scripts"
start "review-cycle.sh export-sarif"            env TEST_TAG="${P}rev" python3 "$HERE/sarif/t.py" "$ROOT/.agents/skills/pr-reviewer/scripts"
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
# A suite that fails prints every FAIL or failed line of its log, not only the last three lines, and its whole log is
# kept in a folder that outlives the run (the run's own folder is removed at exit), so a row that fails only under load
# can be named and told from a defect. The folder is made at the first failure and its path is printed.
# It lives in this user's cache folder, beside the suite cache: KEPT_BASE is <cache root>/pr-reviewer-fixer/run-all-failed
# (XDG_CACHE_HOME or ~/.cache), created with mode 700 and held, with the folder above it, to the cache folder's rule (a
# real directory, this user's, writable by nobody else; the root as cache_root_ok says), so no other user can plant a
# name in it. A cache root that is not an absolute path (the run works from the checkout's root) or no root at all
# keeps no log and removes nothing (PR 88 W4).
# Before the new folder is made, the older ones are pruned: this user's newest four are kept (with the new one, the
# last five failing runs), and older ones are removed, so a host that fails often does not pile up copies of every log
# (PR 88 N1). The names come from the glob, never from parsed ls output: an entry is counted only when its whole name is
# run-all-failed. and the six letters or digits mktemp puts there (so no newline and no slash), and it is a real
# directory (not a link) owned by this user. Anything else is skipped, never removed. python3 orders the counted names
# by mtime and prints the indexes of the older ones; rm gets only "$KEPT_BASE/<checked name>". When python3 fails,
# nothing is removed (PR 88 W4).
KEPT="" KEPT_TRIED=0 KEPT_BASE=""
case "$CACHE_DIR" in /*) KEPT_BASE="${CACHE_DIR%/*}/run-all-failed" ;; esac
own_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ -n "$(find "$1" -maxdepth 0 -user "$(id -u)" ! -perm -g+w ! -perm -o+w 2>/dev/null)" ]; }
kept_base_ok() { own_dir "$KEPT_BASE" && own_dir "${KEPT_BASE%/*}" && cache_root_ok; }
KEPT_RE='^run-all-failed\.[0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]{6}$'
prune_kept() {
  local f i old names=()
  for f in "$KEPT_BASE"/run-all-failed.*; do
    f="${f#"$KEPT_BASE"/}"
    [[ "$f" =~ $KEPT_RE ]] && own_dir "$KEPT_BASE/$f" || continue
    names+=("$f")
  done
  [ "${#names[@]}" -gt 4 ] || return 0
  old="$(python3 -I -c 'import os, sys
b, n = sys.argv[1], sys.argv[2:]
order = sorted(range(len(n)), key=lambda i: os.lstat(os.path.join(b, n[i])).st_mtime_ns, reverse=True)
print(" ".join(str(i) for i in order[4:]))' "$KEPT_BASE" "${names[@]}" 2>/dev/null)" || return 0
  for i in $old; do
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "${#names[@]}" ] || continue
    rm -rf -- "$KEPT_BASE/${names[$i]}"
  done
}
failed_rows() {
  local n="$1" name="$2" log="$OUT/$1.log" dest rows
  if [ "$KEPT_TRIED" = 0 ]; then
    KEPT_TRIED=1
    if [ -n "$KEPT_BASE" ] && (umask 077; mkdir -p "$KEPT_BASE") 2>/dev/null && kept_base_ok; then
      prune_kept; KEPT="$(mktemp -d "$KEPT_BASE/run-all-failed.XXXXXX" 2>/dev/null)" || KEPT=""
    fi
  fi
  dest=""
  if [ -n "$KEPT" ]; then
    dest="$KEPT/$n-$(printf %s "$name" | tr -c 'A-Za-z0-9._-' '_').log"
    cp "$log" "$dest" 2>/dev/null || dest=""
  fi
  echo "   -- ${name} FAILED; full log: ${dest:-not kept (no folder owned and writable by this user alone could be made under ${KEPT_BASE:-a cache folder: XDG_CACHE_HOME or HOME is unset or not an absolute path})}"
  # A FAIL line, and a failed line unless it counts 0 failed; never a passing row whose name holds the word.
  # A suite reports a failing row as `FAIL | <name>` (or a line holding FAIL or failed, as a test runner's summary does).
  # A log with no such line (a suite that stopped early, or reports in another form) prints its last 20 lines instead,
  # so nothing above the three lines every suite shows is hidden (PR 88 N3).
  rows="$(awk '!/^(PASS|ok)[ :|]/ && (/FAIL/ || (/[Ff]ailed/ && !/(^|[^0-9])0 failed/))' "$log" 2>/dev/null)"
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows" | head -n 60 | sed 's/^/   | /'
    [ "$(printf '%s\n' "$rows" | wc -l)" -le 60 ] || echo "   | ... $(( $(printf '%s\n' "$rows" | wc -l) - 60 )) more in the full log"
  else
    echo "   | (no FAIL or failed line in the log: the suite stopped early, or reports in another form; its last 20 lines:)"
    tail -n 20 "$log" 2>/dev/null | sed 's/^/   | /'
  fi
}
for i in "${!names[@]}"; do
  n=$((i + 1)); echo "== ${names[$i]} ($(cat "$OUT/$n.secs" 2>/dev/null || echo ?)s)"; tail -n 3 "$OUT/$n.log"
  if [ "$(cat "$OUT/$n.rc" 2>/dev/null || echo 1)" -ne 0 ]; then fail=1; failed_rows "$n" "${names[$i]}"; fi
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
# own fence, a template may hold no table row, heading, bold, bullet, checkbox, quote or other fenced
# block (Mermaid included). The fence is tied to the marker: `findings` in a verdict
# (adversarial-review) only, `proofs` in a fixer closure (pr-fixer-closure) only, none in the others.
# A floor on the templates found, and on the proofs fences found, keeps a wrong path or a template
# that lost its proofs block from passing with nothing read (PR 85 N2).
if ! plain_out="$(python3 -I - "$ROOT/.agents/skills" <<'PY'
import os, re, sys
markers = ("<!-[-] adversarial-review:", "<!-[-] pr-fixer-closure:", "<!-[-] pr-merge-fixer-closure:",
           "<!-[-] pr-skill-status:")
own = {"<!-[-] adversarial-review:": "findings", "<!-[-] pr-fixer-closure:": "proofs"}
proofs_seen = 0
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
            allowed = next((v for k, v in own.items() if first.startswith(k)), None)
            inner = None
            for ln, t in body:
                f = re.match(r"^\s*(`{3,})\s*(\S*)", t)
                if inner is not None:
                    if f and len(f.group(1)) >= len(inner) and not f.group(2):
                        inner = None
                    continue
                if f:
                    if allowed is None or f.group(2) != allowed:
                        bad.append("%s:%d fenced block %s under %s" % (path, ln, f.group(2) or "(untagged)", first.split()[1]))
                    elif allowed == "proofs":
                        proofs_seen += 1
                    inner = f.group(1); continue
                for rx, what in rules:
                    if rx.search(t):
                        bad.append("%s:%d %s" % (path, ln, what))
print(found)
if proofs_seen < 1:
    bad.append("no pr-fixer-closure template shows its proofs fence (falsify-and-prove.md)")
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
  "pr-merge-fixer/SKILL.md|Never set \`PUSH_GUARD_ALLOW_SENSITIVE\` yourself|the merge fixer never sets the allow variable (N11)" \
  "pr-merge-fixer/SKILL.md|**Start the review loop again.**|the merge fixer starts the review loop after a merge push" \
  "pr-merge-fixer/SKILL.md|runs [references/harness-loop.md](references/harness-loop.md) from|a direct run takes the loop agent's role" \
  "pr-merge-fixer/SKILL.md|The merge fixer does not review its own merge|the merge is never reviewed in the context that wrote it (PR 83 N5)" \
  "pr-merge-fixer/SKILL.md|A run that stopped after the push still owes the pass|a stop after the push still starts the loop (PR 83 W1)" \
  "pr-merge-fixer/SKILL.md|A fresh-context sub-agent never takes the loop role|a sub-agent never runs a second loop (PR 83 N1)" \
  "pr-merge-fixer/SKILL.md|harness can start a fresh-context sub-agent; when it cannot, do not run \`start\`|the direct run checks for a sub-agent before start (PR 83 N8)" \
  "pr-reviewer/references/harness-loop.md|directly and it pushed a merge, the session's agent takes the loop agent's role|the direct handover is keyed on the push (PR 83 W2)" \
  "pr-reviewer/references/harness-loop.md|once the merge run ends (after its closure comment, or after the step that stopped it)|a stop after the push still hands the loop over (PR 83 W2)" \
  "pr-reviewer/references/harness-loop.md|not an escalation: the merge was pushed, so go on to step 1|step 0 goes on after a stop past the push (PR 83 N9)" \
  "pr-reviewer/references/harness-loop.md|Wait for its closure comment or its stopped line, then compare the head|step 0 waits for the merge run's end, then reads the head (PR 83 N10)" \
  "pr-reviewer/references/harness-loop.md|A merge that escalates, or stops before|an escalation or a stop before the push stops the loop (PR 83 N10)" \
  "pr-reviewer/references/harness-loop.md|Note the pull request's head sha, then dispatch the merge fixer|step 0 notes the head before the merge dispatch (PR 83 N11, PR 85 N1)" \
  "pr-reviewer/references/harness-loop.md|with the one before the dispatch, and read that comment or line for pushed or escalated|step 0 reads the merge run's closure or stopped line, not only the head (PR 85 N3)" \
  "pr-reviewer/references/harness-loop.md|merge was pushed only when the head moved and the closure marker says|a pushed merge needs the moved head and the merge run's own line (PR 85 N3)" \
  "pr-reviewer/references/harness-loop.md|\`head=\` other than the first 12 characters of the noted head|the closure marker's 12-character head is compared with the noted head's first 12 characters (PR 85 N7)" \
  "pr-reviewer/references/harness-loop.md|(a later push may sit on top of it)|a person's push on top of the merge still reads as a pushed merge (PR 85 N3)" \
  "pr-reviewer/references/harness-loop.md|A moved head alone is not a|a concurrent push during an escalation is not a pushed merge (PR 85 N3)" \
  "pr-reviewer/references/harness-loop.md|the push, stops the loop even when the head moved|an escalation stops the loop even when the head moved (PR 85 N3)" \
  "pr-reviewer/references/harness-loop.md|go no further on this pull request until the person answers|step 0 waits for the person after a stop (PR 83 N11)" \
  "pr-fixer/references/pr-protocol.md|a fenced block other than \`findings\` or \`proofs\`|the comment rules allow the proofs block (PR 82 N1)" \
  "pr-fixer/SKILL.md|Record each red, green, suite and mutation run|the Finding step names the runs recorded as proof (PR 82 N8)" \
  "pr-fixer/SKILL.md|Leave the behaviour-diff run out of the block|the behaviour-diff run is not a proof entry (PR 82 N8)" \
  "pr-reviewer/references/harness-loop.md|the \`pr-merge-fixer\` skill finishes a merge push|a merge push triggers the loop"; do
  rel="${check%%|*}"; rest="${check#*|}"; phrase="${rest%%|*}"; why="${rest#*|}"
  grep -qF "$phrase" "$ROOT/.agents/skills/$rel" \
    && echo "== $why" || { echo "== MISSING from $rel: $why"; fail=1; }
done
# 0.25.2 execution rules. Each dispatch call in the skills passes its model, its effort and its profile, and never
# inherits; the fixers name a dispatch call; every file that holds a dispatch call or a brief names the read-only
# probe profile; the probe brief keeps writes inside the scratchpad; the matrix date is not older than its sources.
# The blocks are found, not listed: a fence whose first line starts with `Agent(` is a dispatch call, a fence whose
# first line starts with `Probe brief` is a probe brief, and a fence whose first line starts with `You are` is a
# dispatch brief, and so is a quoted "Follow `.agents/skills/..." instruction (the review loop's briefs). Floors keep
# a wrong path from passing with nothing read.
if exec_out="$(python3 -I - "$ROOT/.agents/skills" <<'PY'
import os, re, sys, datetime
root = sys.argv[1]
profiles = ("read-only review", "read-only probe", "writer")
calls, probes, briefs, bad = {}, 0, set(), []
for d, _, fs in os.walk(root):
    for name in sorted(fs):
        if not name.endswith(".md"):
            continue
        path = os.path.join(d, name); rel = os.path.relpath(path, root)
        text = open(path, encoding="utf-8").read(); lines = text.split("\n"); i = 0
        while i < len(lines):
            m = re.match(r"^\s*(`{3,})", lines[i])
            if not m:
                i += 1; continue
            close = re.compile(r"^\s*`{%d,}\s*$" % len(m.group(1))); start = i + 1; i += 1; body = []
            while i < len(lines) and not close.match(lines[i]):
                body.append(lines[i]); i += 1
            i += 1
            first = next((t.strip() for t in body if t.strip()), ""); blk = "\n".join(body)
            if first.startswith("Agent("):
                calls[rel] = calls.get(rel, 0) + 1; briefs.add(rel)
                mm = re.search(r"\bmodel:\s*([^,\n]+)", blk); ee = re.search(r"\beffort:\s*([^,\n]+)", blk)
                pp = re.search(r"\bprofile:\s*([^,\n]+)", blk)
                if not mm or "inherit" in mm.group(1):
                    bad.append("%s:%d dispatch call without an explicit model" % (rel, start))
                if not ee or "inherit" in ee.group(1):
                    bad.append("%s:%d dispatch call without an explicit effort" % (rel, start))
                if not pp or not any(p in pp.group(1) for p in profiles):
                    bad.append("%s:%d dispatch call names no profile (%s)" % (rel, start, ", ".join(profiles)))
            elif first.startswith("Probe brief"):
                probes += 1; briefs.add(rel)
                for need in ("Profile: read-only probe", "Write only inside <scratchpad>",
                             "never in the repository"):
                    if need not in blk:
                        bad.append("%s:%d probe brief lacks %r" % (rel, start, need))
            elif first.startswith("You are"):
                briefs.add(rel)
        # The review loop writes its dispatch briefs as quoted instructions, not fences.
        if '"Follow `.agents/skills/' in text:
            briefs.add(rel)
for rel in sorted(briefs):
    if "read-only probe" not in open(os.path.join(root, rel), encoding="utf-8").read():
        bad.append("%s holds a dispatch call or brief but does not name the read-only probe profile" % rel)
for rel in ("pr-fixer/SKILL.md", "pr-merge-fixer/SKILL.md", "pr-reviewer/references/agents-and-dispatch.md"):
    if not calls.get(rel):
        bad.append("%s has no dispatch call (an Agent( fence with model, effort and profile)" % rel)
for s in ("pr-reviewer", "pr-fixer", "pr-merge-fixer"):
    if s + "/references/harness-loop.md" not in briefs:
        bad.append("%s/references/harness-loop.md is not seen as a file that writes dispatch briefs" % s)
if probes < 2:
    bad.append("%d probe brief templates found, at least 2 expected (falsify-and-prove.md, agents-and-dispatch.md)" % probes)
# The matrix date: the header's `Checked:` date is the newest date of its Sources lines, each of which carries its own
# `(checked YYYY-MM-DD)`, and each execution-profiles.md repeats the header's date.
mx = open(os.path.join(root, "pr-reviewer/references/harness-matrix.md"), encoding="utf-8").read()
hd = re.search(r"^Checked: (\d{4}-\d{2}-\d{2})", mx, re.M)
src = mx.split("\n## Sources", 1)[-1] if "\n## Sources" in mx else ""
rows = [l for l in src.split("\n") if re.match(r"^\d+\. ", l)]
dates = []
for l in rows:
    m = re.search(r"\(checked (\d{4}-\d{2}-\d{2})\)\s*$", l)
    if not m:
        bad.append("harness-matrix.md source without its own (checked YYYY-MM-DD): %s" % l[:60])
    else:
        dates.append(datetime.date.fromisoformat(m.group(1)))
if len(rows) < 20:
    bad.append("harness-matrix.md lists %d sources, at least 20 expected" % len(rows))
if not hd:
    bad.append("harness-matrix.md has no 'Checked: YYYY-MM-DD' header line")
elif dates and datetime.date.fromisoformat(hd.group(1)) != max(dates):
    bad.append("harness-matrix.md header date %s is not its newest source date %s" % (hd.group(1), max(dates)))
for s in ("pr-reviewer", "pr-fixer", "pr-merge-fixer"):
    ep = open(os.path.join(root, s, "references/execution-profiles.md"), encoding="utf-8").read()
    m = re.search(r"checked on\s+\*\*(\d{4}-\d{2}-\d{2})\*\*", ep)
    if not hd or not m or m.group(1) != hd.group(1):
        bad.append("%s/references/execution-profiles.md does not repeat the matrix date (%s)" % (s, m.group(1) if m else "none"))
print("%d dispatch calls, %d probe briefs, %d files with briefs, matrix %s" % (
    sum(calls.values()), probes, len(briefs), hd.group(1) if hd else "undated"))
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
)"; then
  echo "== dispatch calls pass model, effort and profile; probe profile named; matrix date current ($(printf '%s\n' "$exec_out" | head -n 1))"
else
  echo "== dispatch, probe profile or matrix date rule broken:"; printf '%s\n' "$exec_out" | sed 's/^/   /'; fail=1
fi
# 0.25.2 profile rows and wording: each must stay in its file.
for check in \
  "pr-reviewer/references/execution-profiles.md|| Fixer and merge fixer on security-sensitive files | none | deep |the reviewer's profile names the security-sensitive fixer row at deep" \
  "pr-fixer/references/execution-profiles.md|| Any lane on a security-sensitive file | deep, never lowered |the fixer runs security-sensitive files at deep" \
  "pr-merge-fixer/references/execution-profiles.md|| Security-sensitive file | deep |the merge fixer classifies security-sensitive files at deep" \
  "pr-merge-fixer/references/execution-profiles.md|Posture rules 3 and 8 still hold|the deep row does not loosen the merge fixer's escalation" \
  "pr-fixer/SKILL.md|Pass \`model\` and \`effort\` on every dispatch call, never inherit|the fixer passes model and effort explicitly" \
  "pr-merge-fixer/SKILL.md|Pass \`model\` and \`effort\` on every dispatch call, never inherit|the merge fixer passes model and effort explicitly" \
  "pr-reviewer/references/harness-loop.md|Every dispatch of a skill passes \`model\`, \`effort\` and a profile on the call, never inherited|the review loop passes model, effort and profile when it dispatches a skill" \
  "pr-merge-fixer/references/orchestration.md|| The file is security-sensitive (|the merge fixer's tier ladder scores a security-sensitive file deep" \
  "pr-reviewer/references/execution-profiles.md|## Read-only probe profile|the reviewer's profile defines the read-only probe profile" \
  "pr-fixer/references/execution-profiles.md|## Read-only probe profile|the fixer's profile defines the read-only probe profile" \
  "pr-reviewer/references/execution-profiles.md|## Orchestrator tier|the reviewer's profile states the orchestrator's floor" \
  "pr-reviewer/SKILL.md|If the session model is below the \`standard\` tier|the start line says when the session model is below standard" \
  "pr-reviewer/references/progress-and-notifications.md|Orchestrator below standard:|the start line template names the orchestrator substitution" \
  "pr-reviewer/references/pr-protocol.md|https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax|the alert and emoji rule cites GitHub's syntax page" \
  "pr-reviewer/references/pr-protocol.md|https://docs.github.com/en/communities/moderating-comments-and-conversations/managing-disruptive-comments|the hide rule cites GitHub's moderation page" \
  "pr-reviewer/references/pr-protocol.md|https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-checks|the check-run decision cites GitHub's checks guide" \
  "pr-reviewer/references/pr-protocol.md|https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api|the serial-posting rule cites GitHub's REST practices" \
  "pr-reviewer/references/pr-protocol.md|https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api|the serial-posting rule cites GitHub's content limits"; do
  rel="${check%%|*}"; rest="${check#*|}"; phrase="${rest%|*}"; why="${rest##*|}"
  grep -qF -- "$phrase" "$ROOT/.agents/skills/$rel" \
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
# Each skill's improvements catalog (pr-fixer and pr-reviewer) has a Counts section that must agree
# with its tables: 100 rows, each Target one of
# SKILL, reference, shipped or backlog, the SKILL, shipped and backlog item lists equal to the rows
# with that Target, and the reference count equal to the rest.
# Every row is counted before the dict is built, so a repeated item number fails even when the copy
# has the same Target, and a shipped Target must name a path (`shipped: <path>`), not stand bare: a word on each side
# of a slash, naming a file or folder under that catalog's own skill folder (.agents/skills/<skill>/) or the
# repository's root (PR 86 N6). The path is the cell's first token: `scripts/review-cycle.sh export-sarif` names
# scripts/review-cycle.sh. The python takes the catalog, the root and the skill folder relative to the root.
for cat_skill in pr-fixer pr-reviewer; do
if cat_out="$(python3 -I - "$ROOT/.agents/skills/$cat_skill/references/improvements-catalog.md" "$ROOT" ".agents/skills/$cat_skill" <<'PY'
import collections, os, re, sys
skill_dir = sys.argv[3]
text = open(sys.argv[1], encoding="utf-8").read()
found = [(int(m.group(1)), m.group(2).strip())
         for m in re.finditer(r"^\| (\d+) \|.*\| ([^|]*?) \|\s*$", text, re.M)]
bad = ["item %d appears %d times" % (n, c)
       for n, c in sorted(collections.Counter(n for n, _ in found).items()) if c > 1]
rows, nopath = {}, set()
for n, t in found:
    p = re.match(r"shipped: `?([\w.-]*\w[\w.-]*/[\w./-]*\w[\w./-]*)", t)
    if t.startswith("shipped") and not p:
        bad.append("item %d Target %r: shipped needs 'shipped: <path>'" % (n, t)); nopath.add(n)
    elif p and not any(os.path.exists(os.path.join(sys.argv[2], d, p.group(1))) for d in (skill_dir, "")):
        bad.append("item %d Target %r: %s is not under %s/ or the root" % (n, t, p.group(1), skill_dir)); nopath.add(n)
    rows[n] = "shipped" if t.startswith("shipped: ") and n not in nopath else t
got = {k: sorted(n for n, t in rows.items() if t == k) for k in ("SKILL", "reference", "shipped", "backlog")}
bad += ["%d rows, not items 1-100" % len(rows)] if sorted(rows) != list(range(1, 101)) else []
bad += ["item %d Target %r" % (n, t) for n, t in sorted(rows.items()) if t not in got and n not in nopath]
counts = text.split("## Counts", 1)[-1].split("\n## ", 1)[0]
for k, label in (("SKILL", "SKILL (lean body)"), ("shipped", "shipped (formerly backlog)"), ("backlog", "backlog")):
    m = re.search(r"^- %s: (none|items ([\d, ]+) \((\d+)\))\." % re.escape(label), counts, re.M)
    said = [] if m and m.group(1) == "none" else [int(x) for x in m.group(2).split(",")] if m else None
    if said is None or (m.group(3) and int(m.group(3)) != len(said)) or said != got[k]:
        bad.append("%s: counts line says %s, the tables have %s" % (k, m.group(1) if m else "nothing", got[k]))
m = re.search(r"^- reference: the remaining (\d+)\.", counts, re.M)
if not m or int(m.group(1)) != len(got["reference"]):
    bad.append("reference: counts line says %s, the tables have %d" % (m.group(1) if m else "nothing", len(got["reference"])))
print("; ".join(bad) or " ".join("%s %d" % (k, len(v)) for k, v in got.items()))
sys.exit(1 if bad else 0)
PY
)"; then
  echo "== $cat_skill catalog counts match its Target column ($cat_out)"
else
  echo "== $cat_skill catalog counts DISAGREE with its Target column: $cat_out"; fail=1
fi
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
# suite-check.yml runs the pull request's own code (PR 87 N4). That is safe only while its one trigger is pull_request
# (never pull_request_target or workflow_run), its token is contents: read and nothing more (one permissions block,
# none per job), and every checkout drops the token (persist-credentials: false). push-guard keeps a fixer out of
# workflows; this keeps a later edit by anyone from loosening them unseen. Comment lines are not read, and a form this
# check does not parse (an inline `on:` list, for example) fails it. The parser below (PR 87 W1) accepts only lines of
# the form `indent [- ]plain-key: value`, so a quoted key, a space before the colon, a flow mapping, an anchor or a
# block scalar fails it; it reads each `- ` step by indent, and a step whose uses names actions/checkout (quoted or
# not, any case) must hold exactly one persist-credentials: false directly under its own with:.
# A parser of the raw text can be outrun by YAML itself (PR 87 W2: an escape in a double-quoted value, a single-quoted
# value left open over later lines), so the first line of defence is a pin: the workflow must match the sha256 below
# byte for byte. Any edit to it, a whitespace-only one included, fails here until the pin is updated in the same pull
# request, which a reviewer then sees in the diff. That a harmless edit fails is intended. The parser stays as the
# second line of defence and, since W2, also fails on any backslash in a value and on any quoted value that does not
# close on its own line (one quoted token, with no inner quote of its kind, then at most a comment).
sc_pin=d72298283d66d2ab0905727c900fe7407eec78d1364575711bccb683f5bdbec0
sc_sum="$(sha256 "$ROOT/.github/workflows/suite-check.yml" 2>/dev/null | cut -d' ' -f1)"
if [ -n "$sc_sum" ] && [ "$sc_sum" = "$sc_pin" ]; then
  echo "== suite-check.yml matches the sha256 pinned in tests/run-all.sh"
else
  echo "== suite-check.yml DIFFERS from the sha256 pinned in tests/run-all.sh (now '${sc_sum}'): review the edit, then update the pin in the same pull request"; fail=1
fi
sc="$(grep -v '^[[:space:]]*#' "$ROOT/.github/workflows/suite-check.yml" 2>/dev/null)"
sc_on="$(printf '%s\n' "$sc" | awk '/^on:/{on=1;next} on&&/^[^[:space:]]/{exit} on&&/^  [^[:space:]]/{print}')"
sc_perm="$(printf '%s\n' "$sc" | awk '/^permissions:/{on=1;next} on&&/^[^[:space:]]/{exit} on&&/[^[:space:]]/{print}')"
sc_co="$(printf '%s\n' "$sc" | grep -cE 'uses:[[:space:]]*actions/checkout@')"
sc_pc="$(printf '%s\n' "$sc" | grep -cE '^[[:space:]]*persist-credentials:[[:space:]]*false[[:space:]]*$')"
sc_py=1
python3 -I - "$ROOT/.github/workflows/suite-check.yml" >/dev/null 2>&1 <<'PY' && sc_py=0
import re, sys
try:
    lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
except Exception:
    sys.exit(1)
shape = re.compile(r"( *)(- )?([A-Za-z0-9_-]+):(?: (.*))?$")
rows = []  # (indent, dash, key column, key, value, line lowercased)
for raw in lines:
    if not raw.strip() or raw.lstrip(" ").startswith("#"):
        continue
    m = shape.match(raw)
    if not m:
        sys.exit(1)
    ind, dash, key, val = len(m.group(1)), m.group(2) is not None, m.group(3), (m.group(4) or "").strip()
    if val[:1] in ("{", "&", "*", "|", ">", "!") or (val[:1] == "[" and key != "types"):
        sys.exit(1)
    if "\\" in val:  # PR 87 W2: YAML decodes escapes in a double-quoted value; the raw text is not the value
        sys.exit(1)
    if val[:1] in ("'", '"'):  # PR 87 W2: a quote left open swallows the lines below it
        close = val.find(val[0], 1)
        if close < 0 or not re.fullmatch(r"(\s+#.*)?", val[close + 1:]):
            sys.exit(1)
    rows.append((ind, dash, ind + 2 if dash else ind, key, val, raw.lower()))
top = [r[3] for r in rows if r[2] == 0]
perms = [r for r in rows if r[3] == "permissions"]
if len(top) != len(set(top)) or len(perms) != 1 or perms[0][2] != 0 or perms[0][4] != "":
    sys.exit(1)
def end(i):  # the row after the step that starts at row i
    j = i + 1
    while j < len(rows) and rows[j][0] > rows[i][0]:
        j += 1
    return j
checkouts = set()
for n, r in enumerate(rows):
    if "actions/checkout" not in r[5]:
        continue
    starts = [i for i in range(n + 1) if rows[i][1] and n < end(i)]
    if not starts:
        sys.exit(1)
    s = starts[-1]
    if r[3] != "uses" or r[2] != rows[s][2] or (r[1] and n != s):
        sys.exit(1)
    if not re.sub(r"\s+#.*$", "", r[4]).strip("\"'").lower().startswith("actions/checkout@"):
        sys.exit(1)
    checkouts.add(s)
for s in checkouts:
    k, e = rows[s][2], end(s)
    withs = [i for i in range(s, e) if rows[i][2] == k and rows[i][3] == "with" and not rows[i][1]]
    if [rows[i][3] for i in range(s + 1, e) if rows[i][2] == k].count("with") != 1 or len(withs) != 1 or rows[withs[0]][4]:
        sys.exit(1)
    w = withs[0]
    kids = []
    for i in range(w + 1, e):
        if rows[i][0] <= k:
            break
        kids.append(rows[i])
    pc = [x for x in kids if x[3] == "persist-credentials"]
    allpc = [i for i in range(s, e) if rows[i][3] == "persist-credentials"]
    if not kids or len(pc) != 1 or len(allpc) != 1 or pc[0][4] != "false" or pc[0][0] != kids[0][0]:
        sys.exit(1)
sys.exit(0 if checkouts else 1)
PY
if [ -n "$sc" ] && [ "$sc_on" = "  pull_request:" ] && [ "$sc_perm" = "  contents: read" ] \
   && [ "$(printf '%s\n' "$sc" | grep -cE "(^|[[:space:]{,])[\"']?permissions[\"']?[[:space:]]*:")" = 1 ] \
   && ! printf '%s\n' "$sc" | grep -qE 'pull_request_target|workflow_run|persist-credentials:[[:space:]]*[^f[:space:]]' \
   && [ "$sc_co" -ge 1 ] && [ "$sc_pc" = "$sc_co" ] && [ "$sc_py" = 0 ]; then
  echo "== suite-check.yml: pull_request only, contents: read only, persist-credentials: false on every checkout"
else
  echo "== suite-check.yml is not pull_request only, contents: read only, with persist-credentials: false on every checkout"; fail=1
fi
# The model-key scan runs here, last: see model_key_scan, defined near the top.
model_key_scan
# Only a green full run is written to the cache (see the cache note above), and only when the tree is still the one
# the key was taken from: a file changed during the run would otherwise be recorded as passed without being run.
# Such a run says so, so a suite that leaves a file behind does not turn the cache off without a word.
if [ "$fail" = 0 ] && [ -z "${RUN_ONLY:-}" ] && [ -n "${KEY:-}" ] && [ -n "$CACHE_DIR" ]; then
  if [ "$(tree_key)" = "$KEY" ]; then
    if ! { (umask 077; mkdir -p "$CACHE_DIR") 2>/dev/null && cache_root_ok && cache_dir_ok && : >"$CACHE_DIR/$KEY" 2>/dev/null; }; then
      echo "== run-all: the cache folder $CACHE_DIR could not be made or written, or it is not this user's alone, or its cache root is writable by its group or others and has no sticky bit, so this green run is not recorded in the suite cache."
    fi
  else
    echo "== run-all: the tree changed during the run (a suite or an edit touched a file), so this green run is not recorded in the suite cache."
  fi
fi
exit $fail
