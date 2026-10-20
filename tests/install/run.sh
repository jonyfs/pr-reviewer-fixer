#!/usr/bin/env bash
# Drives install.sh in scratch directories. Prints a pass/fail table.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$T/../.." && pwd)"
ORIG_IN="${1:-$ROOT/install.sh}"
# The scratch tree holds copies of the skills, so it lives outside tests/ (run-all.sh greps tests/).
W="$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT; mkdir -p "$W/proj" "$W/home"
# Every row runs a copy of install.sh and of the skills next to it, inside $W, so a refusal that
# regressed can only damage the scratch tree, never the checkout the suite was started from.
mkdir -p "$W/repo/.agents"; cp "$ORIG_IN" "$W/repo/install.sh"
cp -R "$(cd "$(dirname "$ORIG_IN")" && pwd -P)/.agents/skills" "$W/repo/.agents/skills"
[ ! -f "$(dirname "$ORIG_IN")/VERSION" ] || cp "$(dirname "$ORIG_IN")/VERSION" "$W/repo/VERSION"
IN="$W/repo/install.sh"
# The checksum of every file under a folder, to show that a refused run left it byte for byte.
tree_sum() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort); }
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = skip ]; then ROWS+=("SKIP | $1"); elif [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
eq() { [ "$1" = "$2" ]; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }
ins() { (cd "$W/proj" && HOME="$W/home" bash "$IN" "$@") >"$W/out" 2>&1; echo $?; }
SRC="$W/repo/.agents/skills"
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
# The header's last comment line is the end of the exit-codes paragraph; a fixed line range once cut it.
HDR_LAST="$(awk '/^set -uo/ {print prev; exit} {prev=$0}' "$IN")"
check "--help prints the whole header, through the exit-codes sentence" \
  eval '[ $r = 0 ] && grep -q "EXIT CODES" "$W/out" && [ "$(tail -n 1 "$W/out")" = "$HDR_LAST" ]'
# chmod 000 does not stop root from reading, so this case only runs for other users.
if [ "$(id -u)" != 0 ]; then
cp -R "$SRC" "$W/badsrc"; chmod 000 "$W/badsrc/pr-fixer/SKILL.md"; mkdir -p "$W/keep/pr-fixer"; echo keep >"$W/keep/pr-fixer/old.md"
r=$(ins --source "$W/badsrc" --target "$W/keep" --skill pr-fixer --yes); check "failed copy -> refused, old install untouched, no stage left" eval '[ $r = 1 ] && [ -f "$W/keep/pr-fixer/old.md" ] && [ -z "$(ls -A "$W/keep" | grep "^\.")" ]'
chmod 644 "$W/badsrc/pr-fixer/SKILL.md"
else
  row "failed copy (root ignores chmod 000)" skip
fi
SRC_SUM="$(tree_sum "$SRC")"
r=$(ins --target "$SRC" --yes); check "source equals destination -> refused, source unchanged" eval '[ $r = 1 ] && grep -q "same folder" "$W/out" && [ "$(tree_sum "$SRC")" = "$SRC_SUM" ]'

# An option given last with no value once spun forever on `shift 2`; each run is killed after 5 s.
for opt in --harness --scope --skill --target --source; do
  (cd "$W/proj" && HOME="$W/home" perl -e 'alarm shift; exec @ARGV' 5 bash "$IN" "$opt") >"$W/out" 2>&1; r=$?
  check "$opt with no value -> refused at once, naming it" eval '[ $r = 1 ] && grep -q -- "$opt needs a value" "$W/out"'
done
# Symbolic links resolve before the same-folder check, and a source skill folder that is a link is
# refused: either way the copy and the template rewrite would have written into the source tree.
mkdir -p "$W/sc/skills" "$W/proj2/.claude"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/sc/skills/"
SC_TPL="$(cksum <"$W/sc/skills/pr-reviewer/templates/review-gate.yml")"
ln -s "$W/sc/skills" "$W/proj2/.claude/skills"
r=$( (cd "$W/proj2" && HOME="$W/home" bash "$IN" --harness claude-code --source "$W/sc/skills" --yes) >"$W/out" 2>&1; echo $?)
check "destination root linked to the source -> refused as the same folder, source untouched" \
  eval '[ $r = 1 ] && grep -q "same folder" "$W/out" && [ "$(cksum <"$W/sc/skills/pr-reviewer/templates/review-gate.yml")" = "$SC_TPL" ]'
mkdir -p "$W/sl"; ln -s "$W/sc/skills/pr-reviewer" "$W/sl/pr-reviewer"
r=$(ins --harness claude-code --source "$W/sl" --skill pr-reviewer --yes)
check "source skill folder that is a symlink -> refused, source untouched" \
  eval '[ $r = 1 ] && grep -q "symbolic link" "$W/out" && [ "$(cksum <"$W/sc/skills/pr-reviewer/templates/review-gate.yml")" = "$SC_TPL" ]'

# A link nested inside a source skill folder is kept by `cp -R`, and the template rewrite would write
# through it into the source: any link anywhere under the skill folder is refused before any change.
mkdir -p "$W/nl" "$W/realtpl"; cp -R "$SRC/pr-reviewer" "$W/nl/"
mv "$W/nl/pr-reviewer/templates/"* "$W/realtpl/"; rmdir "$W/nl/pr-reviewer/templates"; ln -s "$W/realtpl" "$W/nl/pr-reviewer/templates"
NL_TPL="$(cksum <"$W/realtpl/review-gate.yml")"
r=$(ins --harness claude-code --source "$W/nl" --skill pr-reviewer --yes)
check "link nested in a source skill folder -> refused, linked template untouched" \
  eval '[ $r = 1 ] && grep -q "symbolic link" "$W/out" && [ "$(cksum <"$W/realtpl/review-gate.yml")" = "$NL_TPL" ]'
r=$(ins --harness claude-code --source "$W/nl" --skill pr-reviewer); check "the nested link is refused in the dry run too" eq "$r" 1
# A destination inside the source would put a copy of the skill inside the source skill itself.
mkdir -p "$W/n5"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/n5/"
r=$(ins --source "$W/n5" --target "$W/n5/pr-reviewer" --skill pr-reviewer --yes)
check "destination inside the source -> refused, nothing created in the source" \
  eval '[ $r = 1 ] && grep -q "inside the source" "$W/out" && [ ! -e "$W/n5/pr-reviewer/pr-reviewer" ]'
r=$(ins --source "$W/n5" --target "$W/n5/pr-fixer/not/yet" --skill pr-reviewer --yes)
check "destination not yet created, inside the source -> refused" eval '[ $r = 1 ] && [ ! -e "$W/n5/pr-fixer/not" ]'
r=$(ins --source "$W/n5" --target "$W/n5-sibling" --skill pr-reviewer --yes)
check "destination whose name only starts like the source -> installed" eval '[ $r = 0 ] && [ -f "$W/n5-sibling/pr-reviewer/SKILL.md" ]'


# A source inside a skill folder the install replaces: the repository cloned as
# ~/.claude/skills/pr-reviewer and run with --scope user. The swap would rm -rf the clone with the old
# install. It is refused before any change, in the dry run too, and the clone is left byte for byte.
C1H="$W/c1home"; C1="$C1H/.claude/skills/pr-reviewer"; mkdir -p "$C1/.agents"
cp "$IN" "$C1/install.sh"; cp -R "$SRC" "$C1/.agents/skills"; echo "uncommitted work" >"$C1/MYWORK.txt"
C1_SUM="$(tree_sum "$C1")"
r=$( (cd "$W/proj" && HOME="$C1H" bash "$C1/install.sh" --harness claude-code --scope user) >"$W/out" 2>&1; echo $?)
check "source inside a skill folder it would replace -> refused in the dry run" eval '[ $r = 1 ] && grep -q "inside the destination skill folder" "$W/out"'
r=$( (cd "$W/proj" && HOME="$C1H" bash "$C1/install.sh" --harness claude-code --scope user --yes) >"$W/out" 2>&1; echo $?)
check "source inside a skill folder it would replace -> refused, clone unchanged" \
  eval '[ $r = 1 ] && grep -q "inside the destination skill folder" "$W/out" && [ "$(tree_sum "$C1")" = "$C1_SUM" ] && [ "$(ls -A "$C1H/.claude/skills")" = pr-reviewer ]'
r=$( (cd "$W/proj" && HOME="$C1H" bash "$C1/install.sh" --harness claude-code --scope user --source "$SRC" --yes) >"$W/out" 2>&1; echo $?)
check "install.sh run from inside a skill folder it would replace, --source elsewhere -> refused, clone unchanged" \
  eval '[ $r = 1 ] && grep -q "runs from inside the destination skill folder" "$W/out" && [ "$(tree_sum "$C1")" = "$C1_SUM" ]'
# `<link>/..` names the link target's parent to the kernel, which a logical `cd` resolved to the
# link's own parent: the same-folder check passed, and the swap set the source skill folder aside.
mkdir -p "$W/w2"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/w2/"; ln -s "$W/w2/pr-reviewer" "$W/w2lnk"
W2_SUM="$(tree_sum "$W/w2")"
r=$(ins --source "$W/w2" --target "$W/w2lnk/.." --skill pr-reviewer --yes)
check "--target <link to a source skill>/.. -> refused as the same folder, source unchanged" \
  eval '[ $r = 1 ] && grep -q "same folder" "$W/out" && [ "$(tree_sum "$W/w2")" = "$W2_SUM" ] && [ "$(ls -A "$W/w2" | tr "\n" " ")" = "pr-fixer pr-reviewer " ]'
# `..` after a folder that does not exist yet cannot be resolved, so it is refused, not kept as written.
mkdir -p "$W/n7" "$W/other"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/n7/"; N7_SUM="$(tree_sum "$W/n7")"
r=$(ins --source "$W/n7" --target "$W/other/nonexist/../../n7/pr-fixer" --skill pr-reviewer --yes)
check "--target with .. through a missing folder -> refused, nothing created" \
  eval '[ $r = 1 ] && grep -q "cannot resolve" "$W/out" && [ "$(tree_sum "$W/n7")" = "$N7_SUM" ] && [ ! -e "$W/other/nonexist" ]'
# An exported CDPATH sends a relative `cd` elsewhere and makes it print the folder; the path checks
# must still see the folder the copy writes to.
mkdir -p "$W/n9/s" "$W/n9decoy/s"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/n9/s/"; N9_SUM="$(tree_sum "$W/n9/s")"
r=$( (cd "$W/n9" && CDPATH="$W/n9decoy" HOME="$W/home" bash "$IN" --source "$W/n9/s" --target s --skill pr-reviewer --yes) >"$W/out" 2>&1; echo $?)
check "exported CDPATH and a relative --target equal to the source -> refused, source unchanged" \
  eval '[ $r = 1 ] && grep -q "same folder" "$W/out" && [ "$(tree_sum "$W/n9/s")" = "$N9_SUM" ]'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
