#!/usr/bin/env bash
# The suite cache's key and options (PR 65 pass 1, W1, W2, W4), in a scratch repository with a copy of run-all.sh.
# No suite runs here: --print-key prints the key, and the option refusals exit before any suite starts.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; SRC="$(cd "$T/.." && pwd)/run-all.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W/tmp"
# The scratch runs below fail on purpose. A failing run keeps its logs in the user's cache folder, and each run below
# sets XDG_CACHE_HOME to a folder of this suite (or unsets HOME): TMPDIR is this suite's too, for the runs' own folders.
export TMPDIR="$W/tmp"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }
R="$W/repo"; mkdir -p "$R/tests"; cp "$SRC" "$R/tests/run-all.sh"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q -b main; echo base > "$R/a.md"; g add -A; g commit -qm base
key() { bash "$R/tests/run-all.sh" --print-key 2>/dev/null; }
K0="$(key)"
check "the key is stable on an unchanged tree" eval '[ -n "$K0" ] && [ "$K0" = "$(key)" ]'
printf 'new\n' > "$R/n.md"; K1="$(key)"
printf 'changed\n' > "$R/n.md"; K1b="$(key)"
check "changing the content of an untracked file changes the key" [ "$K1b" != "$K1" ]
PRINT_KEY=1 bash "$R/tests/run-all.sh" --only zzz-none >/dev/null 2>&1; r=$?
check "PRINT_KEY from the environment does not bypass the suites (a filter that matches nothing still exits 1)" [ "$r" = 1 ]
check "an added untracked file changes the key" [ "$K1" != "$K0" ]
mv "$R/n.md" "$R/m.md"; K2="$(key)"
check "renaming an untracked file changes the key (the name is part of it)" [ "$K2" != "$K1" ]
chmod +x "$R/m.md"; K3="$(key)"
check "changing the mode of an untracked file changes the key" [ "$K3" != "$K2" ]
printf 'x' > "$R/sp ace é.md"; K4="$(key)"
check "a name with a space and a non-ASCII letter is keyed" eval '[ -n "$K4" ] && [ "$K4" != "$K3" ]'
ln -s /dev/zero "$R/link"; start=$(date +%s); K5="$(key)"; el=$(( $(date +%s) - start ))
check "a symbolic link to a device is not followed (the key returns at once)" eval '[ "$el" -lt 20 ] && [ -n "$K5" ]'
rm -f "$R/link"
ln -s a.md "$R/link2"; K6="$(key)"
check "a symbolic link is keyed by its target" [ "$K6" != "$K4" ]
ln -sf base "$R/link2"; K7="$(key)"
check "changing a link's target changes the key" [ "$K7" != "$K6" ]
bash "$R/tests/run-all.sh" --bogus >/dev/null 2>&1; r=$?
check "an unknown option exits 2 before any suite starts" [ "$r" = 2 ]
bash "$R/tests/run-all.sh" --only zzz-none >/dev/null 2>&1; r=$?
check "a filter that matches no suite exits 1" [ "$r" = 1 ]
# The cache's skip, its --fresh bypass, its write gate and the --only guard (PR 65 pass 3, W4). The scratch repository has
# no suites, so a full run fails at once, and no suite runs here. XDG_CACHE_HOME is a scratch folder.
export XDG_CACHE_HOME="$W/xdg"; CD="$XDG_CACHE_HOME/pr-reviewer-fixer/run-all"
# The folder is made as run-all.sh makes it (mode 700): under a umask of 002 a plain mkdir gives 775, which turns the cache off.
rm -rf "$XDG_CACHE_HOME"; (umask 077; mkdir -p "$CD")
KEYNOW="$(key)"
: >"$CD/$KEYNOW"
out="$(bash "$R/tests/run-all.sh" 2>&1)"; r=$?
check "a key already written for this tree skips the run (nothing re-run, exit 0)" eval '[ $r = 0 ] && printf %s "$out" | grep -q "nothing re-run"'
out="$(bash "$R/tests/run-all.sh" --fresh 2>&1)"; r=$?
check "--fresh runs even when the key is written (no skip message)" eval '! printf %s "$out" | grep -q "nothing re-run"'
out="$(bash "$R/tests/run-all.sh" --only zzz-none 2>&1)"; r=$?
check "--only never skips on a written key (it refuses a filter that matches nothing, exit 1)" eval '[ $r = 1 ] && ! printf %s "$out" | grep -q "nothing re-run"'
rm -f "$CD/$KEYNOW"
out="$(bash "$R/tests/run-all.sh" 2>&1)"; r=$?
check "a run with a failing suite does not write the key (the write gate)" eval '[ $r -ne 0 ] && [ ! -e "$CD/$KEYNOW" ]'
unset XDG_CACHE_HOME
# The toolchain and the global git configuration are part of the key (PR 65 pass 4 W4)
mkdir -p "$W/fakebin" "$W/home"
printf '#!/usr/bin/env bash\necho v99.0.0\n' > "$W/fakebin/node"; chmod +x "$W/fakebin/node"
KB="$(key)"
KN1="$(PATH="$W/fakebin:$PATH" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
check "a different node on PATH changes the key (the toolchain is keyed)" eval '[ -n "$KN1" ] && [ "$KN1" != "$KB" ]'
printf '[user]\n\tname = one\n' > "$W/home/.gitconfig"
KG1="$(HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
printf '[user]\n\tname = two\n' > "$W/home/.gitconfig"
KG2="$(HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
check "changing the global git config changes the key" eval '[ -n "$KG1" ] && [ "$KG1" != "$KG2" ]'
# The XDG git config and GIT_CONFIG_GLOBAL are keyed too (PR 65 pass 5, W6): each changes the key when its content changes
mkdir -p "$W/home/.config/git"
printf '[user]\n\tname = one\n' > "$W/home/.config/git/config"
KX1="$(HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
printf '[user]\n\tname = two\n' > "$W/home/.config/git/config"
KX2="$(HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
check "changing the XDG git config changes the key" eval '[ -n "$KX1" ] && [ "$KX1" != "$KX2" ]'
printf '[user]\n\tname = one\n' > "$W/gcg.config"
KC1="$(GIT_CONFIG_GLOBAL="$W/gcg.config" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
printf '[user]\n\tname = two\n' > "$W/gcg.config"
KC2="$(GIT_CONFIG_GLOBAL="$W/gcg.config" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
check "changing the file GIT_CONFIG_GLOBAL names changes the key" eval '[ -n "$KC1" ] && [ "$KC1" != "$KC2" ]'
# The declared debt of PR 65 (N1-N3)
# N2: a textconv driver must not hide a change: two contents a driver renders alike still give two keys.
printf '#!/bin/sh\necho same\n' > "$W/same.sh"; chmod +x "$W/same.sh"
g config diff.same.textconv "$W/same.sh"; printf 'a.md diff=same\n' > "$R/.git/info/attributes"
printf 'one\n' > "$R/a.md"; KT1="$(key)"; printf 'two\n' > "$R/a.md"; KT2="$(key)"
check "a textconv driver does not hide a change to a tracked file (--no-textconv)" eval '[ -n "$KT1" ] && [ "$KT1" != "$KT2" ]'
g checkout -q -- a.md; rm -f "$R/.git/info/attributes"
# N1: sha256sum is used where it exists (a stub that prints a fixed digest makes the key that digest).
mkdir -p "$W/shabin"; printf '#!/bin/sh\n[ $# -gt 0 ] || cat >/dev/null; echo "stubdigest  -"\n' > "$W/shabin/sha256sum"; chmod +x "$W/shabin/sha256sum"
KS="$(PATH="$W/shabin:$PATH" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
check "the key is made with sha256sum when it is on PATH" [ "$KS" = stubdigest ]
# N3: with HOME and XDG_CACHE_HOME both unset there is no per-user folder, so the cache is off (no shared /.cache).
out="$(env -u HOME -u XDG_CACHE_HOME bash "$R/tests/run-all.sh" 2>&1)"
check "HOME and XDG_CACHE_HOME unset: the cache is off, said plainly" eval 'printf %s "$out" | grep -q "the suite cache is off"'
out="$(env -u HOME XDG_CACHE_HOME= bash "$R/tests/run-all.sh" 2>&1)"
check "HOME unset and XDG_CACHE_HOME empty: the cache is off too" eval 'printf %s "$out" | grep -q "the suite cache is off"'
# N4 (PR 71 pass 1, W1): a green full run records its key only when the tree is unchanged at the end. A second scratch
# repository holds the skills, the gate and suite-check workflows, VERSION and CHANGELOG.md copied from this checkout, so the checks after
# the suites pass, and a stub at each suite path run-all.sh starts (taken from run-all.sh itself), each exiting 0. With
# EDIT_DURING_RUN set, the stubs edit a tracked file while the run is under way.
SR="$(cd "$T/../.." && pwd)"; R2="$W/green"; mkdir -p "$R2/tests"; cp "$SRC" "$R2/tests/run-all.sh"
(cd "$SR" && git ls-files -z -- .agents .github/workflows/review-gate.yml .github/workflows/suite-check.yml VERSION CHANGELOG.md | xargs -0 tar cf -) | tar xf - -C "$R2"
grep -oE '"\$HERE/[^"]+\.(sh|py)"' "$SRC" | sed 's/^"\$HERE\///; s/"$//' | sort -u | while IFS= read -r s; do
  mkdir -p "$R2/tests/$(dirname "$s")"
  case "$s" in
    *.py) printf 'pass\n' > "$R2/tests/$s" ;;
    *) printf '#!/usr/bin/env bash\n[ -z "${EDIT_DURING_RUN:-}" ] || echo edited >> "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/a.md"\nexit 0\n' > "$R2/tests/$s" ;;
  esac
done
echo base > "$R2/a.md"
g2() { git -C "$R2" -c user.name=t -c user.email=t@example.com "$@"; }
g2 init -q -b main; g2 add -A; g2 commit -qm base
export XDG_CACHE_HOME="$W/xdg2"; CD2="$XDG_CACHE_HOME/pr-reviewer-fixer/run-all"; rm -rf "$XDG_CACHE_HOME"
KG="$(bash "$R2/tests/run-all.sh" --print-key 2>/dev/null)"
out="$(EDIT_DURING_RUN=1 bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "a green full run that edits a tracked file is green (exit 0) and edited the file" eval '[ $r = 0 ] && grep -q edited "$R2/a.md"'
check "a green full run whose tree changed during the run writes no key" eval '[ -n "$KG" ] && [ ! -e "$CD2/$KG" ] && [ -z "$(ls -A "$CD2" 2>/dev/null)" ]'
check "a green full run whose tree changed says it was not recorded" eval 'printf %s "$out" | grep -q "not recorded"'
g2 checkout -q -- a.md
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "the same green full run with no edit writes the key" eval '[ $r = 0 ] && [ -e "$CD2/$KG" ]'
# PR 71 debt N3: the cache folder must be this user's alone. It is created with mode 700; a folder others can write
# to, or a link, turns the cache off even when a key file for this tree is in it.
# find -perm reads the same with BSD and GNU find; stat -f means another thing to GNU stat. Owner rwx and no group or
# other bit is mode 700 exactly, except a setgid bit inherited from the folder above (setgid is not g+x) (PR 73 N5).
check "the cache folder is created with mode 700 (a setgid bit from the folder above is allowed)" eval '[ -n "$(find "$CD2" -maxdepth 0 -perm -700 ! -perm -g+w ! -perm -o+w ! -perm -g+r ! -perm -o+r ! -perm -g+x ! -perm -o+x)" ]'
chmod g+w "$CD2"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "a group-writable cache folder with a key for this tree: no skip, the cache is off" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$out" | grep -q "the suite cache is off"'
# PR 73 debt N8: cache_dir_ok refuses a group-writable folder too, and the line says so.
OUT_DIR_LINE="$(printf %s "$out" | grep "the suite cache is off")"
check "the refusal line names a folder writable by its group, not only by others" eval 'printf %s "$OUT_DIR_LINE" | grep -q "writable by its group or others"'
chmod g-w "$CD2"; mv "$CD2" "$CD2.real"; ln -s "$CD2.real" "$CD2"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "a cache folder that is a symbolic link: no skip, the cache is off" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$out" | grep -q "the suite cache is off"'
rm -f "$CD2"; mv "$CD2.real" "$CD2"
# PR 73 pass 1, W2: the other two checks of cache_dir_ok each have a row, a folder writable by others and a folder
# with another owner. The owner row puts an id stub first on PATH that gives another uid for -u, so -user misses.
chmod o+w "$CD2"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "a cache folder writable by others with a key for this tree: no skip, the cache is off" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$out" | grep -q "the suite cache is off"'
chmod o-w "$CD2"
REAL_ID="$(command -v id)"; OTHER_UID=$(( $(id -u) + 1 )); mkdir -p "$W/idbin"
printf '#!/bin/sh\nif [ "$*" = -u ]; then echo %s; else exec %s "$@"; fi\n' "$OTHER_UID" "$REAL_ID" > "$W/idbin/id"; chmod +x "$W/idbin/id"
out="$(PATH="$W/idbin:$PATH" bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "a cache folder with another owner (id -u gives another uid) with a key for this tree: no skip, the cache is off" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$out" | grep -q "the suite cache is off"'
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "the folder restored to the user's alone: the key skips the run again" eval '[ $r = 0 ] && printf %s "$out" | grep -q "nothing re-run"'
# PR 73 debt. N2: the folder above the cache folder is held to the same rule.
chmod o+w "${CD2%/*}"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "the folder above the cache folder writable by others: no skip, the cache is off, and the line says how to fix it" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$out" | grep -q "chmod 700 both folders"'
chmod o-w "${CD2%/*}"
# PR 73 debt N10: the cache root (XDG_CACHE_HOME here) is checked too. Writable by others with no sticky bit, it would
# let them rename pr-reviewer-fixer away and put their own in its place: the cache is off. With the sticky bit (as /tmp
# has) it is allowed, whoever owns it. The modes are restored after.
chmod o+w "$XDG_CACHE_HOME"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
OUT_ROOT_LINE="$(printf %s "$out" | grep "the suite cache is off")"
check "a cache root writable by others with no sticky bit: no skip, the cache is off, said plainly" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$OUT_ROOT_LINE" | grep -q "cache root .* no sticky bit"'
chmod +t "$XDG_CACHE_HOME"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "the same root with the sticky bit (as /tmp): the key skips the run" eval '[ $r = 0 ] && printf %s "$out" | grep -q "nothing re-run"'
chmod o-w,-t "$XDG_CACHE_HOME"
# PR 76 pass 1, N1: a root writable by its group (not only by others) with no sticky bit turns the cache off too.
chmod g+w "$XDG_CACHE_HOME"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
check "a cache root writable by its group with no sticky bit: no skip, the cache is off, said plainly" eval '! printf %s "$out" | grep -q "nothing re-run" && printf %s "$out" | grep -q "cache root .* no sticky bit"'
chmod g-w "$XDG_CACHE_HOME"
# N1: the write gate checks the root too. With no cache folder yet the read gate has nothing to refuse, so only the
# write gate stands between a bad root and a key file: a green run under a root writable by others writes no key.
rm -rf "${CD2%/*}"; chmod o+w "$XDG_CACHE_HOME"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
chmod o-w "$XDG_CACHE_HOME"
check "no cache folder yet under a root writable by others: a green run writes no key and says it is not recorded" eval '[ $r = 0 ] && [ ! -e "$CD2/$KG" ] && [ -z "$(ls -A "$CD2" 2>/dev/null)" ] && printf %s "$out" | grep -q "cache root is writable by its group or others and has no sticky bit"'
# PR 73 debt N11: docs/REFERENCE.md and the run's refusal lines carry the same remedies. The docs paragraph is joined
# into one line and its backticks dropped, so a re-wrap does not break the match.
DOC_CACHE="$(awk '/^The cache lives in/{p=1} p&&/^$/{exit} p' "$T/../../docs/REFERENCE.md" | tr '\n' ' ' | tr -d '`')"
same_remedy() { local t; for t in "$DOC_CACHE" "$OUT_DIR_LINE"; do printf %s "$t" | grep -q "chmod 700" && printf %s "$t" | grep -q "both folders" && printf %s "$t" | grep -q "remov" && printf %s "$t" | grep -q "its group or others" || return 1; done
  printf %s "$DOC_CACHE" | grep -q "is writable by its group or others (it is created with mode 700)" || return 1   # the folder sentence, not the root one
  for t in "$DOC_CACHE" "$OUT_ROOT_LINE"; do printf %s "$t" | grep -q "chmod go-w" && printf %s "$t" | grep -q "chmod +t" && printf %s "$t" | grep -q "no sticky bit" || return 1; done; }
check "docs/REFERENCE.md and the refusal lines give the same remedies (chmod 700 both folders or remove them; chmod go-w or +t on the root)" same_remedy
# N3: a green run whose key cannot be written says so. The folder above is a plain file, so mkdir -p of the cache
# folder fails for every user; a read-only mode would not, since root writes through it (PR 73 pass 3, W3).
rm -rf "${CD2%/*}"; : > "${CD2%/*}"
out="$(bash "$R2/tests/run-all.sh" 2>&1)"; r=$?
rm -f "${CD2%/*}"
check "a green run whose key cannot be written says it is not recorded" eval '[ $r = 0 ] && printf %s "$out" | grep -q "could not be made or written"'
# PR 85 N5, PR 88 W1: a run started outside the checkout runs every suite from the checkout's root (the gate suite's
# export-audit rows resolve the repository from the working directory). One stub records the folder it runs in.
cp "$R2/tests/scan/run.sh" "$W/scan-stub.bak"
printf '#!/usr/bin/env bash\npwd -P >"%s/stub-pwd"\nexit 0\n' "$W" >"$R2/tests/scan/run.sh"; rm -f "$W/stub-pwd"
out="$(cd / && bash "$R2/tests/run-all.sh" --fresh 2>&1)"; r=$?
cp "$W/scan-stub.bak" "$R2/tests/scan/run.sh"
check "a run started outside the checkout runs its suites from the checkout's root" \
  eval '[ $r = 0 ] && [ "$(cat "$W/stub-pwd" 2>/dev/null)" = "$(cd "$R2" && pwd -P)" ]'
# PR 85 N5, PR 86 N1, PR 87 N5: a failing suite names its failing rows and keeps its log. One stub fails with its FAIL row
# first and six passing rows after it (one whose name holds FAIL), so the last three lines of its log do not hold the row.
cp "$R2/tests/scan/run.sh" "$W/scan-stub.bak"
printf '#!/usr/bin/env bash\necho "FAIL | the planted failing row"\necho "PASS | a passing row whose name says FAIL"\nfor i in 1 2 3 4 5; do echo "PASS | filler $i"; done\necho "TOTAL: 5 passed, 1 failed"\nexit 1\n' >"$R2/tests/scan/run.sh"
# PR 88 N1, W4: the kept folders live in this user's cache folder (KB, under the scratch XDG_CACHE_HOME), never under
# TMPDIR. Six older kept folders, a plain file of a kept name, and a folder whose suffix is not six characters are there
# before the run; six older folders under TMPDIR are there too.
KB="$XDG_CACHE_HOME/pr-reviewer-fixer/run-all-failed"
plant_old() { local i; for i in 1 2 3 4 5 6; do mkdir -p "$1/run-all-failed.old00$i"; touch -t "20200101000$i" "$1/run-all-failed.old00$i"; done; }
rm -rf "$KB" "$W/tmp/"run-all-failed.*; (umask 077; mkdir -p "$KB")
plant_old "$KB"; plant_old "$W/tmp"
: >"$KB/run-all-failed.file00"; touch -t 201901010000 "$KB/run-all-failed.file00"
mkdir "$KB/run-all-failed.old1"; touch -t 201901010000 "$KB/run-all-failed.old1"
out="$(bash "$R2/tests/run-all.sh" --fresh 2>&1)"; r=$?
cp "$W/scan-stub.bak" "$R2/tests/scan/run.sh"
KEPT_LOG="$(printf %s "$out" | sed -n 's/^   -- model-key scan FAILED; full log: //p')"
check "a failing suite fails the run" [ "$r" != 0 ]
check "a failing suite prints its FAIL row, not only its last three lines" eval 'printf %s "$out" | grep -q "^   | FAIL | the planted failing row$"'
check "a failing suite keeps its whole log at the printed path, in the user's cache folder (XDG_CACHE_HOME/pr-reviewer-fixer/run-all-failed), after the run" \
  eval '[ -n "$KEPT_LOG" ] && case "$KEPT_LOG" in "$KB/run-all-failed."*/*) true ;; *) false ;; esac && grep -q "FAIL | the planted failing row" "$KEPT_LOG" && grep -q "PASS | filler 5" "$KEPT_LOG"'
check "a passing row whose name holds FAIL is not printed as a failing row" eval '! printf %s "$out" | grep -q "^   | PASS"'
check "a passing suite prints no failing-rows block" eval '[ "$(printf %s "$out" | grep -c " FAILED; full log: ")" = 1 ]'
check "a failing run keeps the newest four older folders and its own, removes the older ones, leaves a plain file and a name that is not mktemp's (PR 88 N1, W4)" \
  eval '[ ! -e "$KB/run-all-failed.old001" ] && [ ! -e "$KB/run-all-failed.old002" ] && [ -d "$KB/run-all-failed.old003" ] && [ -d "$KB/run-all-failed.old006" ] && [ -f "$KB/run-all-failed.file00" ] && [ -d "$KB/run-all-failed.old1" ] && [ -f "$KEPT_LOG" ] && [ "$(ls -d "$KB/"run-all-failed.* | wc -l | tr -d " ")" = 7 ]'
check "the kept folders' folder is made with mode 700" eval '[ -n "$(find "$KB" -maxdepth 0 -perm -700 ! -perm -g+r ! -perm -g+w ! -perm -g+x ! -perm -o+r ! -perm -o+w ! -perm -o+x)" ]'
check "nothing is kept or removed under TMPDIR any more (PR 88 W4)" \
  eval '[ "$(ls -d "$W/tmp/"run-all-failed.* | wc -l | tr -d " ")" = 6 ] && [ -d "$W/tmp/run-all-failed.old001" ]'
# PR 88 W4: prune_kept once split ls output on newlines, so a kept folder whose name holds newlines turned each later
# line into a relative path, which names a folder at the checkout's root (the run works from there), and removed it with
# rm -rf. A third scratch repository (a copy of the green one with its own .git, never the suite's own tree) holds an
# untracked decoy folder; the kept folders' folder holds a newest folder named run-all-failed.zz and then five decoy
# lines and two .git lines, a link of a kept name to a folder outside, and the six older folders. Both decoys, the
# repository, the link and its target must survive a failing run.
R3="$W/nl"; rm -rf "$R3"; cp -R "$R2" "$R3"
printf '#!/usr/bin/env bash\necho "FAIL | the planted failing row"\nexit 1\n' >"$R3/tests/scan/run.sh"
mkdir "$R3/decoy"; echo keep >"$R3/decoy/f"; HEAD3="$(git -C "$R3" rev-parse HEAD)"
mkdir -p "$W/linkdecoy"; echo keep >"$W/linkdecoy/f"
rm -rf "$KB"; (umask 077; mkdir -p "$KB"); plant_old "$KB"
NL="$KB/run-all-failed.zz"$'\n'decoy$'\n'decoy$'\n'decoy$'\n'decoy$'\n'decoy$'\n'.git$'\n'.git; mkdir "$NL"
ln -s "$W/linkdecoy" "$KB/run-all-failed.lnk001"; touch -h -t 201801010000 "$KB/run-all-failed.lnk001" 2>/dev/null
out="$(bash "$R3/tests/run-all.sh" --fresh 2>&1)"; r=$?
check "a kept folder whose name holds newlines is never split: the decoy folder and .git at the checkout's root survive a failing run (PR 88 W4)" \
  eval '[ "$r" != 0 ] && [ -f "$R3/decoy/f" ] && [ "$(git -C "$R3" rev-parse HEAD 2>/dev/null)" = "$HEAD3" ] && [ -d "$NL" ]'
check "a link with a kept folder's name is never counted or removed, and its target survives (PR 88 W4)" \
  eval '[ -L "$KB/run-all-failed.lnk001" ] && [ -f "$W/linkdecoy/f" ]'
check "the same failing run still prunes the real older folders (the newest four and its own are left)" \
  eval '[ ! -e "$KB/run-all-failed.old001" ] && [ ! -e "$KB/run-all-failed.old002" ] && [ -d "$KB/run-all-failed.old003" ]'
# Another owner: an id stub first on PATH gives another uid for -u (no folder of another user can be made without root),
# so the kept folders' folder is not this user's: nothing is kept and nothing is removed.
rm -rf "$KB"; (umask 077; mkdir -p "$KB"); plant_old "$KB"
out="$(PATH="$W/idbin:$PATH" bash "$R3/tests/run-all.sh" --fresh 2>&1)"; r=$?
check "kept folders owned by another uid (id -u gives another uid): nothing is removed, nothing kept, said plainly (PR 88 W4)" \
  eval '[ "$r" != 0 ] && [ "$(ls -d "$KB/"run-all-failed.* | wc -l | tr -d " ")" = 6 ] && printf %s "$out" | grep -q "full log: not kept (no folder owned and writable by this user alone could be made under $KB)"'
# Writable by others: anyone could plant a name there, so nothing is kept and nothing is removed.
rm -rf "$KB"; (umask 077; mkdir -p "$KB"); plant_old "$KB"; chmod o+w "$KB"
out="$(bash "$R3/tests/run-all.sh" --fresh 2>&1)"; r=$?
chmod o-w "$KB"
check "a kept folders' folder writable by others: nothing is removed, nothing kept (PR 88 W4)" \
  eval '[ "$r" != 0 ] && [ "$(ls -d "$KB/"run-all-failed.* | wc -l | tr -d " ")" = 6 ] && printf %s "$out" | grep -q "full log: not kept"'
# A relative XDG_CACHE_HOME would name a folder inside the checkout (the run works from its root): nothing is kept there.
out="$(cd "$W" && XDG_CACHE_HOME=relcache bash "$R3/tests/run-all.sh" --fresh 2>&1)"; r=$?
check "a relative XDG_CACHE_HOME keeps nothing and makes no folder in the checkout or the caller's folder (PR 88 W4)" \
  eval '[ "$r" != 0 ] && [ ! -e "$R3/relcache" ] && [ ! -e "$W/relcache" ] && printf %s "$out" | grep -q "full log: not kept"'
# PR 88 N3: a failing suite whose log holds no FAIL or failed line still shows where it stopped: the filter prints the
# log's last 20 lines, so a line above the last three (which every suite shows) is not hidden.
printf '#!/usr/bin/env bash\necho "boom: the suite stopped in another form"\nfor i in 1 2 3 4 5; do echo "step $i"; done\nexit 1\n' >"$R3/tests/scan/run.sh"
out="$(XDG_CACHE_HOME="$W/xdg-n3" bash "$R3/tests/run-all.sh" --fresh 2>&1)"; r=$?
check "a failing suite with no FAIL or failed line prints its log's last lines, not only its last three (PR 88 N3)" \
  eval '[ "$r" != 0 ] && printf %s "$out" | grep -q "^   | boom: the suite stopped in another form$" && printf %s "$out" | grep -q "no FAIL or failed line in the log"'
unset XDG_CACHE_HOME
# PR 86 N6: the pr-fixer catalog check (the python run-all.sh feeds the catalog) needs a word on each side of a shipped
# path's slash, and the path must exist under .agents/skills/pr-fixer/ or the repository's root. The check is taken out
# of run-all.sh and run on the real catalog and on mutated copies.
CROOT="$(cd "$T/../.." && pwd)"; CAT="$CROOT/.agents/skills/pr-fixer/references/improvements-catalog.md"
awk '/^if cat_out=.*<<.PY.$/{p=1; next} p&&/^PY$/{exit} p' "$SRC" >"$W/catalog-check.py"
python3 -I "$W/catalog-check.py" "$CAT" "$CROOT" >/dev/null 2>&1; r=$?
check "the catalog check passes the real catalog" eval '[ -s "$W/catalog-check.py" ] && [ "$r" = 0 ]'
cat_mut() { sed "s#| shipped: \`scripts/proof-check.sh\` (\#82) |#| shipped: $1 (\#82) |#" "$CAT" >"$W/cat-mut.md"
  grep -qF "shipped: $1 (#82)" "$W/cat-mut.md" && ! python3 -I "$W/catalog-check.py" "$W/cat-mut.md" "$CROOT" >/dev/null 2>&1; }
check "the catalog check fails a lone slash as a shipped path (shipped: / (#82))" cat_mut "/"
check "the catalog check fails a shipped path with no word after its slash (shipped: scripts/ (#82))" cat_mut "scripts/"
check "the catalog check fails a shipped path that names no file (shipped: \`scripts/no-such.sh\` (#82))" cat_mut "\`scripts/no-such.sh\`"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
