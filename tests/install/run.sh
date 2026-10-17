#!/usr/bin/env bash
# Drives install.sh in scratch directories. Prints a pass/fail table.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$T/../.." && pwd)"
IN="${1:-$ROOT/install.sh}"
# The scratch tree holds copies of the skills, so it lives outside tests/ (run-all.sh greps tests/).
W="$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT; mkdir -p "$W/proj" "$W/home"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
eq() { [ "$1" = "$2" ]; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }
ins() { (cd "$W/proj" && HOME="$W/home" bash "$IN" "$@") >"$W/out" 2>&1; echo $?; }
SRC="$ROOT/.agents/skills"
TPL_BEFORE="$(cksum <"$SRC/pr-reviewer/templates/review-gate.yml")"

r=$(ins --harness claude-code); check "dry run -> 0, nothing created" eval '[ $r = 0 ] && grep -q "dry run" "$W/out" && [ ! -e "$W/proj/.claude" ]'
r=$(ins --harness claude-code --yes); check "claude-code project install -> both skills" eval '[ $r = 0 ] && [ -f "$W/proj/.claude/skills/pr-reviewer/SKILL.md" ] && [ -f "$W/proj/.claude/skills/pr-fixer/SKILL.md" ]'
check "gate template points at the new path" eval 'grep -q "\.claude/skills/pr-reviewer/scripts/" "$W/proj/.claude/skills/pr-reviewer/templates/review-gate.yml" && ! grep -q "\.agents/skills/pr-reviewer/scripts/" "$W/proj/.claude/skills/pr-reviewer/templates/review-gate.yml"'
check "source template untouched" eq "$(cksum <"$SRC/pr-reviewer/templates/review-gate.yml")" "$TPL_BEFORE"

echo stale >"$W/proj/.claude/skills/pr-reviewer/old-file.md"
r=$(ins --harness claude-code); check "dry run names the folder it would remove" eval 'grep -q "will REPLACE" "$W/out" && [ -f "$W/proj/.claude/skills/pr-reviewer/old-file.md" ]'
r=$(ins --harness claude-code --yes); check "reinstall drops a file the release no longer ships" eval '[ $r = 0 ] && [ ! -e "$W/proj/.claude/skills/pr-reviewer/old-file.md" ]'

r=$(ins --harness codex --yes); check "codex keeps the .agents/skills prefix" eval '[ $r = 0 ] && grep -q "\.agents/skills/pr-reviewer/scripts/" "$W/proj/.agents/skills/pr-reviewer/templates/review-gate.yml"'
r=$(ins --harness claude-code --scope user --skill pr-fixer --yes); check "user scope, one skill, under HOME" eval '[ $r = 0 ] && [ -f "$W/home/.claude/skills/pr-fixer/SKILL.md" ] && [ ! -e "$W/home/.claude/skills/pr-reviewer" ]'
r=$(ins --target "$W/custom" --yes); check "--target needs no harness" eval '[ $r = 0 ] && [ -f "$W/custom/pr-reviewer/SKILL.md" ]'
r=$(ins --harness nope); check "unknown harness -> refused" eval '[ $r = 1 ] && grep -q "unknown harness" "$W/out"'
r=$(ins --harness aider); check "aider -> refused with the reason" eval '[ $r = 1 ] && grep -q "no skills feature" "$W/out"'
r=$(ins --scope sideways --harness codex); check "bad --scope -> refused" eq "$r" 1
r=$(ins); check "no harness and no target -> refused" eq "$r" 1
r=$(ins --harness codex --source "$W/empty" --yes); check "source without skills -> refused" eq "$r" 1
mkdir -p "$W/linked-target" "$W/elsewhere"; ln -s "$W/elsewhere" "$W/linked-target/pr-fixer"
r=$(ins --target "$W/linked-target" --skill pr-fixer --yes); check "destination that is a symlink -> refused, target kept" eval '[ $r = 1 ] && [ -d "$W/elsewhere" ]'
mkdir -p "$W/half" "$W/elsewhere2"; ln -s "$W/elsewhere2" "$W/half/pr-fixer"; mkdir -p "$W/half/pr-reviewer"; echo keep >"$W/half/pr-reviewer/old.md"
r=$(ins --target "$W/half" --yes); check "both skills, second is a symlink -> refused before any removal" eval '[ $r = 1 ] && [ -f "$W/half/pr-reviewer/old.md" ]'
r=$(ins --target "$W/half"); check "the symlink is refused in the dry run too" eq "$r" 1
r=$(ins --help); check "--help does not print the shell options line" eval '[ $r = 0 ] && ! grep -q "set -uo" "$W/out"'
# chmod 000 does not stop root from reading, so this case only runs for other users.
if [ "$(id -u)" != 0 ]; then
cp -R "$SRC" "$W/badsrc"; chmod 000 "$W/badsrc/pr-fixer/SKILL.md"; mkdir -p "$W/keep/pr-fixer"; echo keep >"$W/keep/pr-fixer/old.md"
r=$(ins --source "$W/badsrc" --target "$W/keep" --skill pr-fixer --yes); check "failed copy -> refused, old install untouched, no stage left" eval '[ $r = 1 ] && [ -f "$W/keep/pr-fixer/old.md" ] && [ -z "$(ls -A "$W/keep" | grep "^\.")" ]'
chmod 644 "$W/badsrc/pr-fixer/SKILL.md"
else
  row "SKIP failed copy (root ignores chmod 000)" ok
fi
r=$(ins --target "$SRC" --yes); check "source equals destination -> refused" eval '[ $r = 1 ] && grep -q "same folder" "$W/out"'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
