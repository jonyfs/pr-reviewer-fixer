#!/usr/bin/env bash
# The suite cache's key and options (PR 65 pass 1, W1, W2, W4), in a scratch repository with a copy of run-all.sh.
# No suite runs here: --print-key prints the key, and the option refusals exit before any suite starts.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; SRC="$(cd "$T/.." && pwd)/run-all.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
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
rm -rf "$XDG_CACHE_HOME"; mkdir -p "$CD"
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
mkdir -p "$W/shabin"; printf '#!/bin/sh\ncat >/dev/null; echo "stubdigest  -"\n' > "$W/shabin/sha256sum"; chmod +x "$W/shabin/sha256sum"
KS="$(PATH="$W/shabin:$PATH" bash "$R/tests/run-all.sh" --print-key 2>/dev/null)"
check "the key is made with sha256sum when it is on PATH" [ "$KS" = stubdigest ]
# N3: with HOME and XDG_CACHE_HOME both unset there is no per-user folder, so the cache is off (no shared /.cache).
out="$(env -u HOME -u XDG_CACHE_HOME bash "$R/tests/run-all.sh" 2>&1)"
check "HOME and XDG_CACHE_HOME unset: the cache is off, said plainly" eval 'printf %s "$out" | grep -q "the suite cache is off"'
out="$(env -u HOME XDG_CACHE_HOME= bash "$R/tests/run-all.sh" 2>&1)"
check "HOME unset and XDG_CACHE_HOME empty: the cache is off too" eval 'printf %s "$out" | grep -q "the suite cache is off"'
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
