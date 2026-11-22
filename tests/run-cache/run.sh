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
check "the key is stable on an unchanged tree" [ -n "$K0" ] && [ "$K0" = "$(key)" ]
printf 'new\n' > "$R/n.md"; K1="$(key)"
check "an added untracked file changes the key" [ "$K1" != "$K0" ]
mv "$R/n.md" "$R/m.md"; K2="$(key)"
check "renaming an untracked file changes the key (the name is part of it)" [ "$K2" != "$K1" ]
chmod +x "$R/m.md"; K3="$(key)"
check "changing the mode of an untracked file changes the key" [ "$K3" != "$K2" ]
printf 'x' > "$R/sp ace é.md"; K4="$(key)"
check "a name with a space and a non-ASCII letter is keyed" [ -n "$K4" ] && [ "$K4" != "$K3" ]
ln -s /dev/zero "$R/link"; start=$(date +%s); K5="$(key)"; el=$(( $(date +%s) - start ))
check "a symbolic link to a device is not followed (the key returns at once)" [ "$el" -lt 20 ] && [ -n "$K5" ]
rm -f "$R/link"
ln -s a.md "$R/link2"; K6="$(key)"
check "a symbolic link is keyed by its target" [ "$K6" != "$K4" ]
ln -sf base "$R/link2"; K7="$(key)"
check "changing a link's target changes the key" [ "$K7" != "$K6" ]
bash "$R/tests/run-all.sh" --bogus >/dev/null 2>&1; r=$?
check "an unknown option exits 2 before any suite starts" [ "$r" = 2 ]
bash "$R/tests/run-all.sh" --only zzz-none >/dev/null 2>&1; r=$?
check "a filter that matches no suite exits 1" [ "$r" = 1 ]
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
