#!/usr/bin/env bash
# Drives behaviour-diff.sh against throwaway git repositories. Prints a table.
# Usage: run.sh [scripts-dir]   (default: the pr-fixer copy)
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$T/../../.agents/skills/pr-fixer/scripts}"
SRC="$(cd "$SRC" && pwd)"; BD="$SRC/behaviour-diff.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W/repo" "$W/tmp"
W="$(cd "$W" && pwd -P)"
# git never walks up out of the scratch folder into this checkout, and the script's temporary
# worktrees land in the scratch folder, so a row can check that none is left behind.
export GIT_CEILING_DIRECTORIES="$W" TMPDIR="$W/tmp"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1"); fi; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad; fi; }
g() { git -C "$W/repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
# Every call is bounded: a broken copy that hangs fails its row instead of hanging the suite.
run() { (cd "$W/repo" && perl -e 'alarm shift; exec @ARGV' 60 bash "$BD" "$@") >"$W/out" 2>"$W/err"; echo $?; }
clean() { [ "$(g worktree list | wc -l | tr -d ' ')" = 1 ] && [ -z "$(ls -A "$W/tmp")" ]; }
has() { grep -qF -- "$1" "$W/out"; }

g init -q . 2>/dev/null
[ "$(g rev-parse --show-toplevel 2>/dev/null)" = "$W/repo" ] || { echo "cannot make the scratch repository"; exit 1; }
mkdir -p "$W/repo/src"
cat >"$W/repo/src/clamp.sh" <<'EOF'
n="${1-}"
case "$n" in ''|*[!0-9]*) echo "usage: clamp N" >&2; exit 2 ;; esac
if [ "$n" -gt 10 ]; then echo 11; else echo "$n"; fi
EOF
echo 'echo hello' >"$W/repo/src/greet.sh"
echo readme >"$W/repo/README"
g add -A; g commit -q -m base; BASE="$(g rev-parse HEAD)"
echo 'readme, edited' >"$W/repo/README"; g commit -q -am docs; DOCS="$(g rev-parse HEAD)"
g checkout -q -b fix "$BASE"
perl -pi -e 's/echo 11/echo 10/' "$W/repo/src/clamp.sh"; g commit -q -am "C1: clamp to 10"; FIX="$(g rev-parse HEAD)"
echo 'echo hi' >"$W/repo/src/greet.sh"; g commit -q -am "C1 and an unasked change"; WIDE="$(g rev-parse HEAD)"
g checkout -q -b hang "$FIX"
printf 'sleep 30 &\necho $! >>"$1"\nwait\n' >"$W/repo/src/hang.sh"; g add -A; g commit -q -m hang; HANG="$(g rev-parse HEAD)"

cat >"$W/p-main.json" <<'EOF'
{"probes": [
  {"id": "clamp-max", "finding": "C1", "argv": ["bash", "src/clamp.sh", "11"]},
  {"id": "clamp-low", "argv": ["bash", "src/clamp.sh", "5"]},
  {"id": "where", "argv": ["bash", "-c", "pwd; echo \"$PWD\""], "stdout": true},
  {"id": "greet", "argv": ["bash", "src/greet.sh"], "stdout": true}
]}
EOF

# 1. No change: a commit that touches only a README. The pwd probe proves both commits ran at one path.
r=$(run "$BASE" "$DOCS" "$W/p-main.json")
check "no change -> 0, every probe compared and same (the cwd probe included), worktree removed" \
  eval '[ $r = 0 ] && has "same          where finding=-" && has "4 probes; same 3, expected 0, supplementary 0, not-changed 1, inconclusive 0" && clean'

# 2. A tagged expected change: the fix changes clamp-max, which C1 tags; nothing else moves.
r=$(run "$BASE" "$FIX" "$W/p-main.json")
check "tagged expected change -> 0, clamp-max reported expected for C1 with its stdout hashes" \
  eval '[ $r = 0 ] && has "expected      clamp-max finding=C1: stdout " && has "same 3, expected 1, supplementary 0" && clean'

# 3. An untagged supplementary change: the same fix also changes greet, which no finding tags.
r=$(run "$BASE" "$WIDE" "$W/p-main.json")
check "untagged change -> 1, greet reported supplementary with both stdout texts" \
  eval '[ $r = 1 ] && has "supplementary greet finding=-: stdout " && has "(supplementary semantic change: no finding names it; for the reviewer)" \
    && has "  base stdout: \"hello\\n\"" && has "  head stdout: \"hi\\n\"" && has "expected 1, supplementary 1" && clean'

# 4. The generator: values, then the boundaries around a number and a string, deduplicated, in order.
cat >"$W/p-gen.json" <<'EOF'
{"probes": [{"id": "clamp", "finding": "C1", "argv": ["bash", "src/clamp.sh", "{}"],
  "values": ["x"], "around": {"numbers": [10], "strings": ["ab"]}}]}
EOF
r=$(run --list "$BASE" "$FIX" "$W/p-gen.json")
long="$(awk '/^clamp\[13\] /{print length($0)}' "$W/out")"
check "generator --list -> 14 probes: x, 9 10 11 0 1 -1, 40 nines, empty, a, ab, abb, 4096 chars, unicode" \
  eval '[ $r = 0 ] && has "behaviour-diff: 14 probes" && has "clamp[1] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"x\"]" \
    && has "clamp[2] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"9\"]" && has "clamp[4] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"11\"]" \
    && has "clamp[8] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"9999999999999999999999999999999999999999\"]" \
    && has "clamp[9] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"\"]" && has "clamp[10] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"a\"]" \
    && has "clamp[12] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"abb\"]" \
    && has "clamp[14] finding=C1 argv=[\"bash\", \"src/clamp.sh\", \"ab\\u00e9\\u65e5\"]" && [ "${long:-0}" -gt 4096 ] && clean'
r=$(run "$BASE" "$FIX" "$W/p-gen.json")
check "generator run -> 0, only the value 11 changes, named in the report" \
  eval '[ $r = 0 ] && has "expected      clamp[4] finding=C1" && has "  value: \"11\"" && has "14 probes; same 0, expected 1, supplementary 0, not-changed 13" && clean'
echo '{"probes": [{"id": "t", "argv": ["bash", "src/clamp.sh"], "values": ["1"]}]}' >"$W/p-noslot.json"
r=$(run --list "$BASE" "$FIX" "$W/p-noslot.json")
check "a template with no {} in its argv -> 2" eval '[ $r = 2 ] && grep -q "needs \"{}\"" "$W/err"'

# 5. A probe that times out, bounded: killed with its child after 1 s; at both commits it is inconclusive (2).
printf '{"timeout": 1, "probes": [{"id": "stuck", "argv": ["bash", "-c", "sleep 30 & echo $! >>\\"$0\\"; wait", "%s"]}]}\n' "$W/pids" >"$W/p-to.json"
t0=$(date +%s); r=$(run "$BASE" "$FIX" "$W/p-to.json"); el=$(( $(date +%s) - t0 ))
alive=0; while read -r p; do kill -0 "$p" 2>/dev/null && alive=1; done <"$W/pids"
check "a probe that hangs at both commits -> 2 inconclusive, within 10 s, its children killed" \
  eval '[ $r = 2 ] && has "inconclusive  stuck finding=-: timed out at both commits after 1s" && [ $el -lt 10 ] \
    && [ "$(wc -l <"$W/pids" | tr -d " ")" = 2 ] && [ $alive = 0 ] && clean'
printf '{"timeout": 1, "probes": [{"id": "stuck", "argv": ["bash", "-c", "sleep 30 & wait"]},\n {"id": "maybe", "argv": ["bash", "src/hang.sh", "%s"]}]}\n' "$W/pids2" >"$W/p-to2.json"
r=$(run "$FIX" "$HANG" "$W/p-to2.json")
check "a probe that hangs at the head only -> a difference (exit 127 -> timeout); 1 wins over inconclusive" \
  eval '[ $r = 1 ] && has "supplementary maybe finding=-: exit 127 -> timeout" && has "inconclusive 1" && clean'

# 6. Cannot run: each case is 2, with the reason on stderr, and leaves no worktree.
r=$(run "$BASE" 0123456789abcdef0123456789abcdef01234567 "$W/p-main.json")
check "a head commit that does not exist -> 2, cannot resolve" eval '[ $r = 2 ] && grep -q "cannot resolve" "$W/err" && ! has "probes;" && clean'
r=$(run -- "--output=x" "$FIX" "$W/p-main.json")
check "a commit that starts with - -> 2" eval '[ $r = 2 ] && grep -q "may not start with -" "$W/err" && clean'
g tag -f tree-only "$(g rev-parse "$BASE^{tree}")" >/dev/null 2>&1
r=$(run tree-only "$FIX" "$W/p-main.json")
check "a name that is a tree, not a commit -> 2" eval '[ $r = 2 ] && grep -q "cannot resolve" "$W/err" && clean'
echo '{"probes": [{"id": "x", "argv": "bash -c pwd"}]}' >"$W/p-bad.json"
r=$(run "$BASE" "$FIX" "$W/p-bad.json")
check "argv as one string instead of an array -> 2, nothing run" eval '[ $r = 2 ] && grep -q "argv must be a non-empty list" "$W/err" && ! has "behaviour-diff: base" && clean'
echo '{"probes": [' >"$W/p-trunc.json"
r=$(run "$BASE" "$FIX" "$W/p-trunc.json")
check "a probe file that is not JSON -> 2" eval '[ $r = 2 ] && grep -q "not valid JSON" "$W/err" && clean'
r=$( (cd "$W/tmp" && perl -e 'alarm shift; exec @ARGV' 60 bash "$BD" "$BASE" "$FIX" "$W/p-main.json") >"$W/out" 2>"$W/err"; echo $?)
check "run outside any repository -> 2" eval '[ $r = 2 ] && grep -q "not inside a git repository" "$W/err" && clean'
echo '{"probes": [{"id": "nope", "argv": ["./no-such-program"]}]}' >"$W/p-nocmd.json"
r=$(run "$BASE" "$FIX" "$W/p-nocmd.json")
check "a program that cannot start at either commit -> same, 0 (not an internal error)" eval '[ $r = 0 ] && has "same          nope finding=-: exit cannot-start" && clean'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
