#!/usr/bin/env bash
# Drives the model-key scan of tests/run-all.sh (`run-all.sh --scan-only`) against planted trees.
# Every planted file lives in a scratch copy under tests/scan/work-*/ (gitignored), never in the
# work tree, and the scratch copy is its own git repository because the scan asks git which files
# to read (the tracked ones and the untracked ones .gitignore does not hide). The keys are built
# from pieces at run time, so this file does not match the scan.
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
  printf 'state-*/\nwork-*/\n' >"$d/.gitignore"
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

# plant <path> [content]: write a file in the fixture and add it to the index, the way a change
# reaches the scan. unplant <path>: take it out of the index and the work tree again.
plant() { mkdir -p "$(dirname "$F/$1")"; printf '%s\n' "${2:-$KEY}" >"$F/$1"; git -C "$F" add -f -- "$1" >/dev/null 2>&1; }
unplant() { git -C "$F" rm -qf --cached -- "$1" >/dev/null 2>&1; rm -f "$F/$1"; }
found() { [ $r = 1 ] && has "a model action or provider key appears"; }

# A tracked key in each scanned tree is found whatever the file or the folder is called: an ordinary
# name, run-all.sh (the scan once skipped it), a name with a space, a newline or a leading dash, and
# folders called state-x and work-x (the scan once skipped those under tests/).
for t in "${trees[@]}"; do
  for n in x.yml run-all.sh "a b.yml" $'a\nb.yml' -r.yml state-x/x.yml work-x/x.yml work-x/run-all.sh; do
    plant "$t/$n"; scan "$F"
    check "tracked key in $t/$(printf %q "$n"): exit 1 and named" found
    unplant "$t/$n"; rmdir "$F/$t/state-x" "$F/$t/work-x" 2>/dev/null
  done
done
plant install.sh "$KEY"; scan "$F"
check "the key in the root install.sh: exit 1" found
plant install.sh "echo clean"
plant .github/CODEOWNERS "$KEY"; scan "$F"
check "the key in .github/CODEOWNERS: exit 1" found
plant .github/CODEOWNERS "* @owner"
# tests/run-all.sh is scanned like any other file: its pattern is written in pieces.
cp "$F/tests/run-all.sh" "$W/run-all.bak"; printf '# %s\n' "$KEY" >>"$F/tests/run-all.sh"; scan "$F"
check "the key in tests/run-all.sh itself: exit 1" found
cp "$W/run-all.bak" "$F/tests/run-all.sh"
# A tracked file whose content was changed after it was added is read from the work tree.
plant tests/foo/late.sh "echo clean"; printf '%s\n' "$KEY" >"$F/tests/foo/late.sh"; scan "$F"
check "a tracked file edited after git add: the work tree copy is read, exit 1" found
unplant tests/foo/late.sh

# The other patterns, in a file with an ordinary name.
for k in "codex-""action@v1" "ANTHROPIC""_API_KEY" "OPENAI""_API_KEY" "FIXER_PUSH""_TOKEN" "openai/""codex"; do
  plant .github/workflows/y.yml "x: $k"; scan "$F"
  check "$k in a workflow: exit 1" found
  unplant .github/workflows/y.yml
done
scan "$F"
check "after the planted files are removed the tree is clean again" eval '[ $r = 0 ]'

# What .gitignore hides is not read (scratch in work-*/ and state-*/); a new file that is not
# ignored is read before it is `git add`ed.
mkdir -p "$F/tests/foo/work-1" "$F/.agents/skills/pr-fixer/scripts/state-1"
printf '%s\n' "$KEY" >"$F/tests/foo/work-1/f"
printf '%s\n' "$KEY" >"$F/.agents/skills/pr-fixer/scripts/state-1/f"
scan "$F"
check "an ignored key (scratch in work-* and state-*): not read, exit 0" eval '[ $r = 0 ]'
check "it still prints the pass line" has "no model action or provider key"
printf '%s\n' "$KEY" >"$F/tests/foo/untracked.yml"; scan "$F"
check "an untracked key in an ordinary place, not yet git added: exit 1 and named" found
rm -f "$F/tests/foo/untracked.yml"
mkdir -p "$F/.github/workflows/new dir"; printf '%s\n' "$KEY" >"$F/.github/workflows/new dir/n.yml"
scan "$F"
check "an untracked key in a new folder under .github: exit 1 and named" found
rm -rf "$F/tests/foo/work-1" "$F/.agents/skills/pr-fixer/scripts/state-1" \
  "$F/.github/workflows/new dir"
# A tracked clean file in a folder with such a name is simply read (no refusal).
plant tests/foo/work-1/f "echo clean"; plant .github/state-notes/n.md "notes"; scan "$F"
check "a tracked clean file in work-*/ and state-*/ folders: exit 0" eval '[ $r = 0 ]'
unplant tests/foo/work-1/f; unplant .github/state-notes/n.md; rmdir "$F/tests/foo/work-1" "$F/.github/state-notes" 2>/dev/null

# The checkout's own path does not matter: a copy under work-projects/ and one under state-x/.
for d in "$W/work-projects/repo" "$W/state-x/repo" "$W/plain/repo"; do
  mkfix "$d"; scan "$d"
  check "a clean copy at ${d#"$W"/}: exit 0" eval '[ $r = 0 ]'
  for t in tests/foo .github/workflows; do
    printf '%s\n' "$KEY" >"$d/$t/k.yml"; git -C "$d" add -f "$t/k.yml" >/dev/null 2>&1; scan "$d"
    check "a tracked key in ${d#"$W"/}/$t: exit 1 and named" found
  done
done

# git's pathspec variables must not change what is listed (a literal `*` would list nothing).
plant .agents/skills/pr-reviewer/templates/p.yml; scan "$F" GIT_LITERAL_PATHSPECS=1
check "GIT_LITERAL_PATHSPECS=1 exported: the glob pathspecs still list the templates, exit 1" found
scan "$F" GIT_NOGLOB_PATHSPECS=1
check "GIT_NOGLOB_PATHSPECS=1 exported: the same, exit 1" found
unplant .agents/skills/pr-reviewer/templates/p.yml
scan "$F" GIT_LITERAL_PATHSPECS=1
check "GIT_LITERAL_PATHSPECS=1 on a clean tree: exit 0 and the pass line" \
  eval '[ $r = 0 ] && has "no model action or provider key"'

# The scan hands grep 100 files at a time. A tree of more than 100 files, with a key in the 100th
# file, the 101st (the first of the second batch) and the last, so a batch that is skipped, cut
# short or stepped over would miss one. The positions come from the same listing the scan uses.
B="$W/big"; mkfix "$B"; mkdir -p "$B/tests/foo/many"
for ((n = 1; n <= 130; n++)); do
  echo "echo clean $n" >"$B/tests/foo/many/f$(printf %03d $n).sh"
done
git -C "$B" add -A >/dev/null 2>&1
LIST=()
while IFS= read -r -d '' f; do LIST+=("$f"); done < <(git -C "$B" ls-files -z --cached --others \
  --exclude-standard -- .github install.sh '.agents/skills/*/templates/*' \
  '.agents/skills/*/scripts/*' tests)
scan "$B"
check "a clean tree of more than 100 files (${#LIST[@]}): exit 0 and the count in the pass line" \
  eval '[ ${#LIST[@]} -gt 101 ] && [ $r = 0 ] && has "in ${#LIST[@]} files"'
for pos in 1 99 100 101 102 200 "${#LIST[@]}"; do
  [ "$pos" -le "${#LIST[@]}" ] || continue
  f="${LIST[$((pos - 1))]}"; cp "$B/$f" "$W/big.bak"
  printf '# %s\n' "$KEY" >>"$B/$f"; scan "$B"
  check "a key in file $pos of ${#LIST[@]} ($f): exit 1 and named" \
    eval 'found && has "$f"'
  cp "$W/big.bak" "$B/$f"
done
scan "$B"
check "the big tree is clean again: exit 0" eval '[ $r = 0 ]'

# Fail closed.
mkfix "$W/nogit"; rm -rf "$W/nogit/.git"; scan "$W/nogit" GIT_CEILING_DIRECTORIES="$W"
check "no git repository at all: exit 1, cannot tell tracked files" eval '[ $r = 1 ] && has "git ls-files failed"'
mkdir -p "$W/outer"; ( cd "$W/outer" && git init -q ) >/dev/null 2>&1; mkfix "$W/outer/inner"; rm -rf "$W/outer/inner/.git"
scan "$W/outer/inner"
check "a copy inside another repository: exit 1, not the top of its own" eval '[ $r = 1 ] && has "is not the top of its own git repository"'
mkdir -p "$W/fakebin"; printf '#!/bin/sh\nexit 1\n' >"$W/fakebin/git"; chmod +x "$W/fakebin/git"
scan "$F" PATH="$W/fakebin:$PATH"
check "git failing: exit 1 even on a clean tree" eval '[ $r = 1 ] && has "git ls-files failed"'
mkfix "$W/empty"; echo "tests/run-all.sh" >>"$W/empty/.gitignore"
git -C "$W/empty" rm -rqf --cached .github .agents install.sh tests >/dev/null 2>&1
rm -rf "$W/empty/.github" "$W/empty/.agents" "$W/empty/install.sh" "$W/empty/tests/foo"
scan "$W/empty"
check "git lists no file in the trees: exit 1" eval '[ $r = 1 ] && has "lists no file"'
mkdir -p "$W/badgrep"; printf '#!/bin/sh\nexit 2\n' >"$W/badgrep/grep"; chmod +x "$W/badgrep/grep"
scan "$F" PATH="$W/badgrep:$PATH"
check "grep exiting 2: exit 1 even on a clean tree" \
  eval '[ $r = 1 ] && has "could not read a listed file"'
printf '#!/bin/sh\nexit 3\n' >"$W/badgrep/grep"
scan "$F" PATH="$W/badgrep:$PATH"
check "grep exiting 3: exit 1 even on a clean tree" \
  eval '[ $r = 1 ] && has "could not read a listed file"'
mv "$F/.github" "$W/dot-github"; scan "$F"
check "a tracked tree missing from the work tree: exit 1, the scan could not read it" \
  eval '[ $r = 1 ] && has "could not read a listed file"'
mv "$W/dot-github" "$F/.github"
plant tests/foo/gone.sh "echo clean"; rm -f "$F/tests/foo/gone.sh"; scan "$F"
check "a tracked file deleted from the work tree: exit 1, the scan could not read it" \
  eval '[ $r = 1 ] && has "could not read a listed file"'
unplant tests/foo/gone.sh
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$F/tests/foo"; scan "$F"; chmod 755 "$F/tests/foo"
  check "an unreadable folder: exit 1, the scan could not read it" \
    eval '[ $r = 1 ] && has "could not read a listed file"'
fi
scan "$F"
check "the fixture is clean again at the end" eval '[ $r = 0 ]'
check "nothing was planted in the work tree" eval '[ "$(git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null)" = "$S0" ]'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
