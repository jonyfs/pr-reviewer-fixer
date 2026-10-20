#!/usr/bin/env bash
# Drives install.sh in scratch directories. Prints a pass/fail table.
# Usage: run.sh [path/to/install.sh]. The argument (default: install.sh at the repository root) must
# sit beside the .agents/skills folder and the VERSION file it installs, as in a clone: the suite
# copies all three into its scratch tree and fails before the first row when they are not there.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$T/../.." && pwd)"
ORIG_IN="${1:-$ROOT/install.sh}"
# The scratch tree holds copies of the skills, so it lives outside tests/ (run-all.sh greps tests/).
# A row leaves a read-only or immutable file behind when it fails, so the cleanup clears both first.
W="$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")"; trap 'command -v chflags >/dev/null 2>&1 && chflags -R nouchg "$W" 2>/dev/null; chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT; mkdir -p "$W/proj" "$W/home"
# Every row runs a copy of install.sh and of the skills next to it, inside $W, so a refusal that
# regressed can only damage the scratch tree, never the checkout the suite was started from.
ORIG_DIR="$(cd "$(dirname "$ORIG_IN")" && pwd -P)" || { echo "install suite: cannot enter the folder of $ORIG_IN" >&2; exit 1; }
for f in install.sh .agents/skills/pr-reviewer/SKILL.md .agents/skills/pr-fixer/SKILL.md VERSION; do
  [ -f "$ORIG_DIR/$f" ] || { echo "install suite: $ORIG_DIR/$f not found; the argument must be an install.sh beside .agents/skills and VERSION" >&2; exit 1; }
done
mkdir -p "$W/repo/.agents"; cp "$ORIG_IN" "$W/repo/install.sh"
cp -R "$ORIG_DIR/.agents/skills" "$W/repo/.agents/skills"
cp "$ORIG_DIR/VERSION" "$W/repo/VERSION"
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
mkdir -p "$W/half" "$W/elsewhere2"; ln -s "$W/elsewhere2" "$W/half/pr-fixer"; cp -R "$SRC/pr-reviewer" "$W/half/pr-reviewer"; echo keep >"$W/half/pr-reviewer/old.md"
r=$(ins --target "$W/half" --yes); check "both skills, second is a symlink -> refused before any removal" eval '[ $r = 1 ] && [ -f "$W/half/pr-reviewer/old.md" ]'
r=$(ins --target "$W/half"); check "the symlink is refused in the dry run too" eq "$r" 1
r=$(ins --help); check "--help does not print the shell options line" eval '[ $r = 0 ] && ! grep -q "set -uo" "$W/out"'
# The header's last comment line is the end of the exit-codes paragraph; a fixed line range once cut it.
HDR_LAST="$(awk '/^set -uo/ {print prev; exit} {prev=$0}' "$IN")"
check "--help prints the whole header, through the exit-codes sentence" \
  eval '[ $r = 0 ] && grep -q "EXIT CODES" "$W/out" && [ "$(tail -n 1 "$W/out")" = "$HDR_LAST" ]'
# chmod 000 does not stop root from reading, so this case only runs for other users.
if [ "$(id -u)" != 0 ]; then
# An unreadable file other than SKILL.md: the source checks pass and the copy itself fails.
cp -R "$SRC" "$W/badsrc"; chmod 000 "$W/badsrc/pr-fixer/references/lanes.md"; mkdir -p "$W/keep"; cp -R "$SRC/pr-fixer" "$W/keep/pr-fixer"; echo keep >"$W/keep/pr-fixer/old.md"
r=$(ins --source "$W/badsrc" --target "$W/keep" --skill pr-fixer --yes); check "failed copy -> refused, old install untouched, no stage left" eval '[ $r = 1 ] && grep -q "copy of pr-fixer failed" "$W/out" && [ -f "$W/keep/pr-fixer/old.md" ] && [ -z "$(ls -A "$W/keep" | grep "^\.")" ]'
chmod 644 "$W/badsrc/pr-fixer/references/lanes.md"
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
# must still see the folder the copy writes to. What keeps this green is that physical() makes the
# path absolute before its `cd`; the CDPATH='' beside it is belt and braces and this row does not
# depend on it.
mkdir -p "$W/n9/s" "$W/n9decoy/s"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/n9/s/"; N9_SUM="$(tree_sum "$W/n9/s")"
r=$( (cd "$W/n9" && CDPATH="$W/n9decoy" HOME="$W/home" bash "$IN" --source "$W/n9/s" --target s --skill pr-reviewer --yes) >"$W/out" 2>&1; echo $?)
check "exported CDPATH and a relative --target equal to the source -> refused, source unchanged" \
  eval '[ $r = 1 ] && grep -q "same folder" "$W/out" && [ "$(tree_sum "$W/n9/s")" = "$N9_SUM" ]'

# Path strings are not folder identity. On a case-insensitive file system (the macOS default)
# `SKILLS/pr-reviewer` and `skills/pr-reviewer`, or `skills/Pr-Reviewer` and `skills/pr-reviewer`, are
# one folder, so the overlap checks compare folders by device and inode. These rows only mean
# something where letter case does not matter, so a case-sensitive scratch file system skips them.
mkdir "$W/CaseProbe"; if [ -e "$W/caseprobe" ]; then CI_FS=1; else CI_FS=0; fi
# A clone of the repository with a .git and uncommitted work, as a person would have it.
mk_clone() {
  mkdir -p "$1/.agents" "$1/.git"; echo "ref: refs/heads/main" >"$1/.git/HEAD"
  cp "$IN" "$1/install.sh"; cp -R "$SRC" "$1/.agents/skills"; cp "$W/repo/VERSION" "$1/VERSION"
  echo "uncommitted work" >"$1/MYWORK.txt"
}
if [ "$CI_FS" = 1 ]; then
  H="$W/c2a"; mk_clone "$H/.claude/skills/pr-reviewer"; C2A_SUM="$(tree_sum "$H/.claude/skills/pr-reviewer")"
  r=$( (cd "$W/proj" && HOME="$H" bash "$H/.claude/SKILLS/pr-reviewer/install.sh" --harness claude-code --scope user --yes) >"$W/out" 2>&1; echo $?)
  check "clone in a skill folder, run through a path in other letter case -> refused, clone unchanged" \
    eval '[ $r = 1 ] && grep -q "inside the destination skill folder" "$W/out" && [ "$(tree_sum "$W/c2a/.claude/skills/pr-reviewer")" = "$C2A_SUM" ] && [ "$(ls -A "$W/c2a/.claude/skills")" = pr-reviewer ]'
  H="$W/c2b"; mk_clone "$H/.claude/skills/Pr-Reviewer"; C2B_SUM="$(tree_sum "$H/.claude/skills/Pr-Reviewer")"
  r=$( (cd "$W/proj" && HOME="$H" bash "$H/.claude/skills/Pr-Reviewer/install.sh" --harness claude-code --scope user) >"$W/out" 2>&1; echo $?)
  check "clone stored as skills/Pr-Reviewer -> refused in the dry run" eval '[ $r = 1 ] && grep -q "inside the destination skill folder" "$W/out"'
  r=$( (cd "$W/proj" && HOME="$H" bash "$H/.claude/skills/Pr-Reviewer/install.sh" --harness claude-code --scope user --yes) >"$W/out" 2>&1; echo $?)
  check "clone stored as skills/Pr-Reviewer -> refused, clone unchanged" \
    eval '[ $r = 1 ] && grep -q "inside the destination skill folder" "$W/out" && [ "$(tree_sum "$W/c2b/.claude/skills/Pr-Reviewer")" = "$C2B_SUM" ] && [ "$(ls -A "$W/c2b/.claude/skills")" = Pr-Reviewer ]'
  mkdir -p "$W/c2c/skills"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/c2c/skills/"; C2C_SUM="$(tree_sum "$W/c2c")"
  r=$(ins --source "$W/c2c/SKILLS" --target "$W/c2c/skills" --yes)
  check "--source and --target one folder in two letter cases -> refused as the same folder" \
    eval '[ $r = 1 ] && grep -q "same folder" "$W/out" && [ "$(tree_sum "$W/c2c")" = "$C2C_SUM" ]'
  mkdir -p "$W/c2d"; cp -R "$SRC/pr-reviewer" "$SRC/pr-fixer" "$W/c2d/"; C2D_SUM="$(tree_sum "$W/c2d")"
  r=$(ins --source "$W/c2d" --target "$W/C2D/PR-REVIEWER" --skill pr-fixer --yes)
  check "destination inside the source in other letter case -> refused, nothing created in the source" \
    eval '[ $r = 1 ] && grep -q "inside the source" "$W/out" && [ "$(tree_sum "$W/c2d")" = "$C2D_SUM" ]'
else
  row "clone run through a path in other letter case (file system is case-sensitive)" skip
  row "clone stored as skills/Pr-Reviewer (file system is case-sensitive)" skip
  row "--source and --target in two letter cases (file system is case-sensitive)" skip
  row "destination inside the source in other letter case (file system is case-sensitive)" skip
fi

# Whatever the path checks miss, the install only replaces a folder that looks like one of its own
# copies: a real folder holding SKILL.md with the skill's name and no .git anywhere. Runs everywhere.
mkdir -p "$W/g1"; mk_clone "$W/g1/pr-reviewer"; G1_SUM="$(tree_sum "$W/g1")"
r=$(ins --target "$W/g1" --skill pr-reviewer --yes)
check "a repository clone as the destination skill folder, source elsewhere -> refused, clone unchanged" \
  eval '[ $r = 1 ] && grep -q "\.git" "$W/out" && [ "$(tree_sum "$W/g1")" = "$G1_SUM" ]'
mkdir -p "$W/g2"; cp -R "$SRC/pr-fixer" "$W/g2/pr-fixer"; mkdir -p "$W/g2/pr-fixer/scripts/.git"; echo x >"$W/g2/pr-fixer/scripts/.git/HEAD"; G2_SUM="$(tree_sum "$W/g2")"
r=$(ins --target "$W/g2" --skill pr-fixer); check "an installed copy holding a .git at any depth -> refused in the dry run" eval '[ $r = 1 ] && grep -q "\.git" "$W/out"'
r=$(ins --target "$W/g2" --skill pr-fixer --yes)
check "an installed copy holding a .git at any depth -> refused, unchanged" eval '[ $r = 1 ] && [ "$(tree_sum "$W/g2")" = "$G2_SUM" ]'
mkdir -p "$W/g3/pr-fixer"; echo "my notes" >"$W/g3/pr-fixer/notes.md"
r=$(ins --target "$W/g3" --skill pr-fixer --yes)
check "a destination skill folder with no SKILL.md of that skill -> refused, kept" eval '[ $r = 1 ] && grep -q "does not look like an install" "$W/out" && [ -f "$W/g3/pr-fixer/notes.md" ]'
mkdir -p "$W/g4"; cp -R "$SRC/pr-reviewer" "$W/g4/pr-fixer"
r=$(ins --target "$W/g4" --skill pr-fixer --yes)
check "a destination pr-fixer that holds the pr-reviewer skill -> refused, kept" eval '[ $r = 1 ] && grep -q "does not look like an install" "$W/out" && grep -qx "name: pr-reviewer" "$W/g4/pr-fixer/SKILL.md"'
mkdir -p "$W/g5"; echo "a file" >"$W/g5/pr-fixer"
r=$(ins --target "$W/g5" --skill pr-fixer --yes)
check "a destination pr-fixer that is a file -> refused, file kept" eval '[ $r = 1 ] && grep -q "not a folder" "$W/out" && [ "$(cat "$W/g5/pr-fixer")" = "a file" ]'
# The stage and set-aside names carry the process id. `exec` keeps the shell's process id, so the
# folders made here are the ones the run would name; they are someone else's and must survive.
for kind in new old; do
  mkdir -p "$W/g6$kind"; cp -R "$SRC/pr-fixer" "$W/g6$kind/pr-fixer"
  r=$( (cd "$W/proj" && HOME="$W/home" sh -c 'mkdir "$1/.pr-fixer.$3.$$" && echo mine >"$1/.pr-fixer.$3.$$/keep.txt" && exec bash "$2" --target "$1" --skill pr-fixer --yes' sh "$W/g6$kind" "$IN" "$kind") >"$W/out" 2>&1; echo $?)
  check "a folder already named like this run's .$kind folder -> refused, kept" \
    eval '[ $r = 1 ] && grep -q "already exists" "$W/out" && [ "$(cat "$W/g6$kind"/.pr-fixer.$kind.*/keep.txt)" = mine ]'
done
# The version line reads VERSION two folders above the source; a source with none says unknown, and
# the failed read prints no shell error.
mkdir -p "$W/n12/a/b"; cp -R "$SRC" "$W/n12/a/b/skills"
r=$(ins --source "$W/n12/a/b/skills" --target "$W/n12t" --skill pr-fixer --yes)
check "a source with no VERSION -> installed as unknown, no shell error" eval '[ $r = 0 ] && grep -q "(unknown)" "$W/out" && ! grep -q "No such file" "$W/out"'

# One rule decides "looks like an install of <skill>", for each source skill folder before any change
# and for an existing destination before it is replaced, so whatever the install writes it accepts on
# the next run. Each pair below installs, then installs again over its own copy.
mkdir -p "$W/w3a"; cp -R "$SRC/pr-fixer" "$W/w3a/"; perl -pi -e 's/\n/\r\n/' "$W/w3a/pr-fixer/SKILL.md"
r=$(ins --source "$W/w3a" --target "$W/w3at" --skill pr-fixer --yes); r2=$(ins --source "$W/w3a" --target "$W/w3at" --skill pr-fixer --yes)
check "a source whose SKILL.md has CRLF line endings -> installs, and installs again over its copy" \
  eval '[ $r = 0 ] && [ $r2 = 0 ] && grep -q "installed" "$W/out" && grep -q $'"'"'\r$'"'"' "$W/w3at/pr-fixer/SKILL.md"'
mkdir -p "$W/w3b"; cp -R "$SRC/pr-reviewer" "$W/w3b/"; echo "gitdir: ../x" >"$W/w3b/pr-reviewer/.git"
r=$(ins --source "$W/w3b" --target "$W/w3bt" --skill pr-reviewer); check "a source skill folder holding a .git -> refused in the dry run" eval '[ $r = 1 ] && grep -q "\.git" "$W/out"'
r=$(ins --source "$W/w3b" --target "$W/w3bt" --skill pr-reviewer --yes)
check "a source skill folder holding a .git -> refused before any change" eval '[ $r = 1 ] && grep -q "\.git" "$W/out" && [ ! -e "$W/w3bt" ]'
mkdir -p "$W/w3c"; cp -R "$SRC/pr-fixer" "$W/w3c/"; mkdir "$W/w3c/pr-fixer/scripts/.GIT"
r=$(ins --source "$W/w3c" --target "$W/w3ct" --skill pr-fixer --yes)
check "a source skill folder holding .GIT, in other letter case -> refused before any change" eval '[ $r = 1 ] && grep -qi "\.git" "$W/out" && [ ! -e "$W/w3ct" ]'
mkdir -p "$W/w3d"; cp -R "$SRC/pr-fixer" "$W/w3d/pr-fixer"; mkdir "$W/w3d/pr-fixer/.GIT"; echo x >"$W/w3d/pr-fixer/.GIT/HEAD"; W3D_SUM="$(tree_sum "$W/w3d")"
r=$(ins --target "$W/w3d" --skill pr-fixer --yes)
check "a destination copy holding .GIT, in other letter case -> refused, unchanged" eval '[ $r = 1 ] && [ "$(tree_sum "$W/w3d")" = "$W3D_SUM" ]'
# The name counts only inside the frontmatter: the first block, from a first line of --- to the next.
mkdir -p "$W/n16/pr-reviewer"; printf -- '---\ndescription: my notes\n---\n\nname: pr-reviewer\n' >"$W/n16/pr-reviewer/SKILL.md"; echo mine >"$W/n16/pr-reviewer/notes.md"
r=$(ins --target "$W/n16" --skill pr-reviewer --yes)
check "a destination whose SKILL.md names the skill only in its body -> refused, kept" \
  eval '[ $r = 1 ] && grep -q "does not look like an install" "$W/out" && [ -f "$W/n16/pr-reviewer/notes.md" ]'
mkdir -p "$W/n16s"; cp -R "$W/n16/pr-reviewer" "$W/n16s/"
r=$(ins --source "$W/n16s" --target "$W/n16st" --skill pr-reviewer --yes)
check "a source whose SKILL.md names the skill only in its body -> refused before any change" eval '[ $r = 1 ] && [ ! -e "$W/n16st" ]'
# A refused destination is refused before the plan, so the dry run never says it will replace it.
r=$(ins --target "$W/g3" --skill pr-fixer)
check "the dry run does not promise to replace a folder it refuses" eval '[ $r = 1 ] && grep -q "does not look like an install" "$W/out" && ! grep -q "will REPLACE" "$W/out"'
# `cp -R` keeps a read-only folder read-only, so the old copy could not be removed on the next run and
# was left beside the new one. The install makes every folder of its copy writable by its owner.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$W/ro"; cp -R "$SRC/pr-fixer" "$W/ro/"; chmod 0555 "$W/ro/pr-fixer/references"
  r=$(ins --source "$W/ro" --target "$W/rot" --skill pr-fixer --yes); r2=$(ins --source "$W/ro" --target "$W/rot" --skill pr-fixer --yes)
  check "a source with a read-only folder -> installs again over its copy, nothing left beside it" \
    eval '[ $r = 0 ] && [ $r2 = 0 ] && [ "$(ls -A "$W/rot")" = pr-fixer ] && [ -w "$W/rot/pr-fixer/references" ]'
  chmod 0755 "$W/ro/pr-fixer/references"
  # An install made before that fix can still hold a read-only folder; it is replaced in full too.
  mkdir -p "$W/rod"; cp -R "$SRC/pr-fixer" "$W/rod/"; chmod 0555 "$W/rod/pr-fixer/references"
  r=$(ins --target "$W/rod" --skill pr-fixer --yes)
  check "an installed copy holding a read-only folder -> replaced, nothing left beside it" eval '[ $r = 0 ] && [ "$(ls -A "$W/rod")" = pr-fixer ]'
  # When the old copy still cannot be removed (an immutable file), the run says where it is and exits 1.
  if command -v chflags >/dev/null 2>&1; then
    mkdir -p "$W/imm"; cp -R "$SRC/pr-fixer" "$W/imm/"; chflags uchg "$W/imm/pr-fixer/references/lanes.md"
    r=$(ins --target "$W/imm" --skill pr-fixer --yes)
    check "an old copy that cannot be removed in full -> new copy in place, exit 1 naming the leftover" \
      eval '[ $r = 1 ] && grep -q "could not be removed in full" "$W/out" && [ -f "$W/imm/pr-fixer/SKILL.md" ] && ls -A "$W/imm" | grep -q "^\.pr-fixer\.old\."'
    check "an old copy left behind without its SKILL.md -> the message does not warn about one" \
      eval '! ls "$W"/imm/.pr-fixer.old.*/SKILL.md >/dev/null 2>&1 && ! grep -q "still holds a SKILL.md" "$W/out"'
    chflags -R nouchg "$W/imm"
    # A SKILL.md that cannot be removed stays in the old copy, and the message says so.
    mkdir -p "$W/imm2"; cp -R "$SRC/pr-fixer" "$W/imm2/"; chflags uchg "$W/imm2/pr-fixer/SKILL.md"
    r=$(ins --target "$W/imm2" --skill pr-fixer --yes)
    check "an old copy whose SKILL.md cannot be removed -> exit 1, the message says it still holds one" \
      eval '[ $r = 1 ] && grep -q "still holds a SKILL.md" "$W/out"'
    chflags -R nouchg "$W/imm2"
  else
    row "old copy that cannot be removed (no chflags here)" skip
  fi
else
  row "read-only folder in the source (root ignores the mode)" skip
fi
# A failed copy can leave a stage its owner cannot read (a umask of 0400, say); drop_stage restores
# every mode bit it needs and removes it.
DS="$(awk '/^drop_stage\(\)/,/^}/' "$IN")"
mkdir -p "$W/ds/stage/a/b"; echo x >"$W/ds/stage/a/b/f"; chmod 0 "$W/ds/stage/a/b" "$W/ds/stage/a"
r=$(bash -c "$DS"'; drop_stage "$1"; echo "rc=$?"' _ "$W/ds/stage" 2>&1)
check "drop_stage removes a stage with folders its owner cannot read or enter" eval '[ "$r" = "rc=0" ] && [ ! -e "$W/ds/stage" ]'
# A byte that is not UTF-8 in the frontmatter: awk under a UTF-8 locale gave up on it, so a copy
# installed once was refused on the next run. The rule runs awk in the C locale.
mkdir -p "$W/u8"; cp -R "$SRC/pr-fixer" "$W/u8/"
printf -- '---\nname: pr-fixer\ndescription: caf\351\n---\nbody\n' >"$W/u8/pr-fixer/SKILL.md"
r=$(LC_ALL=C.UTF-8 ins --source "$W/u8" --target "$W/u8t" --skill pr-fixer --yes); r2=$(LC_ALL=C.UTF-8 ins --source "$W/u8" --target "$W/u8t" --skill pr-fixer --yes)
check "a SKILL.md with a byte that is not UTF-8, under a UTF-8 locale -> installs, and installs again" eval '[ $r = 0 ] && [ $r2 = 0 ]'
# Two SKILL.md files that differ only in letter case exist only on a case-sensitive file system.
mkdir -p "$W/cs/pr-fixer"; echo a >"$W/cs/pr-fixer/SKILL.md"; echo b >"$W/cs/pr-fixer/skill.md"
if [ "$(cat "$W/cs/pr-fixer/SKILL.md")" = a ]; then
  rm -rf "$W/cs"; mkdir -p "$W/cs"; cp -R "$SRC/pr-fixer" "$W/cs/"; cp "$W/cs/pr-fixer/SKILL.md" "$W/cs/pr-fixer/skill.md"
  r=$(ins --source "$W/cs" --target "$W/cst" --skill pr-fixer --yes)
  check "a source holding SKILL.md and skill.md -> refused before any change" eval '[ $r = 1 ] && grep -q "more than one SKILL.md" "$W/out" && [ ! -e "$W/cst" ]'
else
  row "SKILL.md and skill.md in one source (case-insensitive file system here)" skip
fi
# same_or_inside walks up with dirname; on a relative path dirname settles on `.` and the walk never
# ended. It must return at once (killed after 3 s otherwise).
SOI="$(awk '/^same_or_inside\(\)/,/^}/' "$IN")"
r=$(perl -e 'alarm shift; exec @ARGV' 3 bash -c "$SOI"'; same_or_inside rel/path /; echo "rc=$?"' 2>&1); rc=$?
check "same_or_inside on a relative path -> returns false at once" eval '[ $rc = 0 ] && [ "$r" = "rc=1" ]'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
