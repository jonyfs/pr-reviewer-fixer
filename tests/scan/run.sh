#!/usr/bin/env bash
# Drives the model-key scan of tests/run-all.sh (`run-all.sh --scan-only`) against planted trees.
# Every planted file lives in a scratch copy under tests/scan/work-*/ (gitignored), never in the
# work tree, and the scratch copy is its own git repository because the scan asks git which files
# are tracked. The keys are built from pieces at run time, so this file does not match the scan.
# Usage: run.sh   (no arguments; TEST_TAG names the scratch directory)
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$T/../.." && pwd)"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS + 1)); ROWS+=("ok   | $1"); else FAIL=$((FAIL + 1)); ROWS+=("FAIL | $1 :: $(tail -c 400 "$W/out" | tr '\n' ' ')"); fi; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad; fi; }

KEY="uses: anthropic""s/claude-code-""action@v1"
trees=(.github/workflows .github/scripts .github/actions/foo .agents/skills/pr-reviewer/templates
       .agents/skills/pr-fixer/templates .agents/skills/pr-reviewer/scripts .agents/skills/pr-fixer/scripts
       tests/foo)

# mkfix <dir>: a clean copy of the layout the scan reads, as its own git repository, with the real
# tests/run-all.sh. The real script is copied from the work tree, so the rows test what is edited.
mkfix() {
  local d="$1" t; mkdir -p "$d"
  for t in "${trees[@]}"; do mkdir -p "$d/$t"; echo "echo clean" >"$d/$t/ok.sh"; done
  echo "echo clean" >"$d/install.sh"; echo "* @owner" >"$d/.github/CODEOWNERS"
  cp "$ROOT/tests/run-all.sh" "$d/tests/run-all.sh"
  ( cd "$d" && git init -q && git add -A ) >/dev/null 2>&1
}
# scan <dir> [env...]: run the scan alone in a fixture; sets r and writes $W/out.
scan() { local d="$1"; shift; r=0; env "$@" bash "$d/tests/run-all.sh" --scan-only >"$W/out" 2>&1 || r=$?; }
has() { grep -qF -- "$1" "$W/out"; }

S0="$(git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null)"
F="$W/fix"; mkfix "$F"
scan "$F"
check "a clean tree: exit 0 and the pass line" eval '[ $r = 0 ] && has "no model action or provider key"'
check "the real work tree is clean too" eval 'bash "$ROOT/tests/run-all.sh" --scan-only >"$W/out" 2>&1'

# The key in each scanned tree, under an ordinary name and under the name run-all.sh, which the
# scan once skipped at any depth.
for t in "${trees[@]}"; do
  for n in x.yml run-all.sh; do
    printf '%s\n' "$KEY" >"$F/$t/$n"; scan "$F"
    check "$KEY in $t/$n: exit 1 and named" eval '[ $r = 1 ] && has "a model action or provider key appears"'
    rm -f "$F/$t/$n"
  done
done
printf '%s\n' "$KEY" >>"$F/install.sh"; scan "$F"
check "the key in the root install.sh: exit 1" eval '[ $r = 1 ] && has "a model action or provider key appears"'
echo "echo clean" >"$F/install.sh"
printf '%s\n' "$KEY" >"$F/.github/CODEOWNERS"; scan "$F"
check "the key in .github/CODEOWNERS: exit 1" eval '[ $r = 1 ]'
echo "* @owner" >"$F/.github/CODEOWNERS"
# tests/run-all.sh is scanned like any other file: its pattern is written in pieces.
cp "$F/tests/run-all.sh" "$W/run-all.bak"; printf '# %s\n' "$KEY" >>"$F/tests/run-all.sh"; scan "$F"
check "the key in tests/run-all.sh itself: exit 1" eval '[ $r = 1 ] && has "a model action or provider key appears"'
cp "$W/run-all.bak" "$F/tests/run-all.sh"

# The other patterns, in a file with an ordinary name.
for k in "codex-""action@v1" "ANTHROPIC""_API_KEY" "OPENAI""_API_KEY" "FIXER_PUSH""_TOKEN" "openai/""codex"; do
  printf 'x: %s\n' "$k" >"$F/.github/workflows/y.yml"; scan "$F"
  check "$k in a workflow: exit 1" eval '[ $r = 1 ]'
  rm -f "$F/.github/workflows/y.yml"
done
scan "$F"
check "after the planted files are removed the tree is clean again" eval '[ $r = 0 ]'

# The state-*/work-* skip: tests/ only, and only for untracked scratch.
mkdir -p "$F/tests/foo/work-1" "$F/.agents/skills/pr-fixer/scripts/state-1"
printf '%s\n' "$KEY" >"$F/tests/foo/work-1/f"; scan "$F"
check "an untracked key under tests/*/work-*: skipped, exit 0" eval '[ $r = 0 ]'
printf '%s\n' "$KEY" >"$F/.agents/skills/pr-fixer/scripts/state-1/f"; scan "$F"
check "a key under scripts/state-*: not skipped, exit 1" eval '[ $r = 1 ] && has "a model action or provider key appears"'
rm -rf "$F/.agents/skills/pr-fixer/scripts/state-1"
git -C "$F" add -f tests/foo/work-1/f >/dev/null 2>&1; scan "$F"
check "a tracked file in a work-* folder: exit 1 and named" eval '[ $r = 1 ] && has "a tracked file sits in a state-* or work-* folder"'
git -C "$F" rm -qf --cached tests/foo/work-1/f >/dev/null 2>&1; rm -rf "$F/tests/foo/work-1"

# Fail closed.
mkfix "$W/nogit"; rm -rf "$W/nogit/.git"; scan "$W/nogit" GIT_CEILING_DIRECTORIES="$W"
check "no git repository at all: exit 1, cannot tell tracked files" eval '[ $r = 1 ] && has "git ls-files failed"'
mkdir -p "$W/outer"; ( cd "$W/outer" && git init -q ) >/dev/null 2>&1; mkfix "$W/outer/inner"; rm -rf "$W/outer/inner/.git"
scan "$W/outer/inner"
check "a copy inside another repository: exit 1, not the top of its own" eval '[ $r = 1 ] && has "is not the top of its own git repository"'
mkdir -p "$W/fakebin"; printf '#!/bin/sh\nexit 1\n' >"$W/fakebin/git"; chmod +x "$W/fakebin/git"
scan "$F" PATH="$W/fakebin:$PATH"
check "git failing: exit 1 even on a clean tree" eval '[ $r = 1 ] && has "git ls-files failed"'
mv "$F/.github" "$W/dot-github"; scan "$F"
check "a missing tree: exit 1, the scan could not read it" eval '[ $r = 1 ] && has "could not read a tree"'
mv "$W/dot-github" "$F/.github"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$F/tests/foo"; scan "$F"; chmod 755 "$F/tests/foo"
  check "an unreadable folder: exit 1, the scan could not read it" eval '[ $r = 1 ] && has "could not read a tree"'
fi
scan "$F"
check "the fixture is clean again at the end" eval '[ $r = 0 ]'
check "nothing was planted in the work tree" eval '[ "$(git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null)" = "$S0" ]'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
