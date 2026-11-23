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
check "a program that cannot start at either commit -> 2 inconclusive (nothing was compared), not an internal error" \
  eval '[ $r = 2 ] && has "inconclusive  nope finding=-: could not start at both commits" && has "same 0, expected 0, supplementary 0, not-changed 0, inconclusive 1" && clean'
# W3, in the finding's form: a typo in argv[0] across a change that does move greet must not read as "same".
echo '{"probes": [{"id": "greet", "argv": ["bsah", "src/greet.sh"]}]}' >"$W/p-typo.json"
r=$(run "$BASE" "$WIDE" "$W/p-typo.json")
check "a typo in argv[0] (bsah) across a real change -> 2 inconclusive, never same and 0" \
  eval '[ $r = 2 ] && has "inconclusive  greet finding=-: could not start at both commits" && ! has "same          greet" && clean'

# 9. Input validation (N3): each rule has a row, checked with --list so nothing runs.
lrow() { # name expected-exit grep-in-stderr-or-out probe-json
  printf '%s\n' "$4" >"$W/p-v.json"
  local r want="$2" pat="$3"; r=$(run --list "$BASE" "$FIX" "$W/p-v.json")
  check "$1" eval '[ $r = $want ] && grep -qF -- "$pat" "$W/err" "$W/out"'
}
lrow "an id with a trailing newline -> 2 (the id pattern matches the whole id)" 2 "id must match" '{"probes": [{"id": "a\n", "argv": ["true"]}]}'
lrow "an id used twice -> 2" 2 "is used twice" '{"probes": [{"id": "x", "argv": ["true"]}, {"id": "x", "argv": ["false"]}]}'
lrow "an unknown probe key -> 2" 2 "unknown key(s): stdin" '{"probes": [{"id": "x", "argv": ["true"], "stdin": "y"}]}'
lrow "a NUL byte in an argv element -> 2" 2 "holds a NUL byte" '{"probes": [{"id": "x", "argv": ["true", "a\u0000b"]}]}'
lrow "a timeout of 600 s is accepted" 0 "1 probes" '{"timeout": 600, "probes": [{"id": "x", "argv": ["true"]}]}'
lrow "a timeout above 600 s -> 2" 2 "at most 600" '{"probes": [{"id": "x", "argv": ["true"], "timeout": 601}]}'
vals() { python3 -I -c 'import json,sys; print(json.dumps({"probes": [{"id": "x", "argv": ["echo", "{}"], "values": [str(i) for i in range(int(sys.argv[1]))]}]}))' "$1"; }
lrow "a probe file that expands to 500 probes is accepted" 0 "500 probes" "$(vals 500)"
lrow "a probe file that expands to 501 probes -> 2" 2 "more than 500 probes" "$(vals 501)"
# The stdout text in the report is cut to 200 characters, with the full length named.
echo '{"probes": [{"id": "wide", "argv": ["bash", "-c", "printf %0300d 0; bash src/clamp.sh 11"], "stdout": true}]}' >"$W/p-wide.json"
r=$(run "$BASE" "$FIX" "$W/p-wide.json")
check "a stdout text over 200 characters is cut in the report, its length named" \
  eval '[ $r = 1 ] && has "...(303 chars)" && [ "$(grep -c "^  head stdout: \"0\{200\}\.\.\.(303 chars)\"$" "$W/out")" = 1 ] && clean'

# 8. Stated controls (W2), each with a row that a copy without it turns red.
# K1: the probe's process group is killed after a normal exit too, so a background child dies.
# K3: stderr is part of the observable result. K6: a probe reads /dev/null, never the caller's stdin
# (the caller here feeds live lines; a probe that got one would exit 3).
printf '{"probes": [{"id": "bg", "argv": ["bash", "-c", "sleep 300 & echo $! >>\\"$0\\"", "%s"]},\n {"id": "erronly", "argv": ["bash", "-c", "bash src/clamp.sh 11 >&2"]},\n {"id": "stdin", "argv": ["bash", "-c", "read -r x && exit 3; exit 0"]}]}\n' "$W/pids-bg" >"$W/p-ctl.json"
: >"$W/pids-bg"
r=$(printf 'leak\nleak\nleak\n' | run "$BASE" "$FIX" "$W/p-ctl.json")
alive=0; while read -r p; do kill -0 "$p" 2>/dev/null && { alive=1; kill -KILL "$p"; }; done <"$W/pids-bg"
check "a background child of a probe that exits normally is dead after the run (killpg after every run)" \
  eval '[ "$(wc -l <"$W/pids-bg" | tr -d " ")" = 2 ] && [ $alive = 0 ] && has "same          bg finding=-: exit 0" && clean'
check "a probe that differs only on stderr -> 1, reported as a stderr difference" \
  eval '[ $r = 1 ] && has "supplementary erronly finding=-: stderr " && ! grep -q "erronly.*\(stdout\|exit\) " "$W/out"'
check "a probe that reads stdin gets EOF at once, though the caller's stdin has lines" eval 'has "same          stdin finding=-: exit 0"'
# K2: git hooks are off at worktree add, even a committed post-checkout under a relative core.hooksPath.
H="$W/hrepo"; mkdir -p "$H/.husky"
hg() { git -C "$H" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
hg init -q .
printf '#!/bin/sh\necho ran >>"$HOOK_MARK"\n' >"$H/.husky/post-checkout"; chmod +x "$H/.husky/post-checkout"
echo one >"$H/f"; hg add -A; hg commit -q -m one; H1="$(hg rev-parse HEAD)"
echo two >"$H/f"; hg commit -q -am two; H2="$(hg rev-parse HEAD)"
hg config core.hooksPath .husky
echo '{"probes": [{"id": "t", "argv": ["true"]}]}' >"$W/p-true.json"
: >"$W/hook-mark"
r=$(HOOK_MARK="$W/hook-mark" run --repo "$H" "$H1" "$H2" "$W/p-true.json")
check "a committed post-checkout hook under a relative core.hooksPath never runs" \
  eval '[ $r = 0 ] && [ ! -s "$W/hook-mark" ] && has "same          t finding=-" && [ "$(hg worktree list | wc -l | tr -d " ")" = 1 ] && clean'

# 7. Stopped from outside (W1): a TERM, INT or HUP to the script's process group (what `timeout`
# and Ctrl-C send), or a TERM to the script alone, kills the running probe before the script exits.
# The signal is sent only once the probe has written its pid, so the row cannot pass by arriving early.
printf '{"timeout": 60, "probes": [{"id": "slow", "argv": ["bash", "-c", "echo $$ >>\\"$0\\"; exec sleep 300", "%s"]}]}\n' "$W/pids-sig" >"$W/p-sig.json"
sigrow() { # name signal group|script
  local sp pp="" alive=1 rc i=0
  : >"$W/pids-sig"
  (cd "$W/repo" && exec perl -e '$SIG{INT}="DEFAULT"; $SIG{HUP}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
    bash "$BD" "$BASE" "$FIX" "$W/p-sig.json") >"$W/out" 2>"$W/err" </dev/null &
  sp=$!
  while [ $i -lt 100 ] && [ ! -s "$W/pids-sig" ]; do sleep 0.1; i=$((i+1)); done
  pp="$(head -n 1 "$W/pids-sig")"
  if [ -n "$pp" ]; then
    if [ "$3" = group ]; then kill -"$2" -- -"$sp"; else kill -"$2" "$sp"; fi
    i=0; while [ $i -lt 50 ] && kill -0 "$pp" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    kill -0 "$pp" 2>/dev/null || alive=0
  fi
  # A broken copy leaves the probe or the script running: never leave either behind.
  [ -z "$pp" ] || kill -KILL "$pp" 2>/dev/null
  i=0; while [ $i -lt 100 ] && kill -0 "$sp" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  kill -0 "$sp" 2>/dev/null && kill -KILL -- -"$sp" 2>/dev/null
  wait "$sp"; rc=$?
  check "$1" eval '[ -n "$pp" ] && [ $alive = 0 ] && [ $rc = 2 ] && clean'
}
sigrow "TERM to the process group (an outer timeout) -> 2, the running probe is dead, worktree removed" TERM group
sigrow "INT to the process group (Ctrl-C) -> 2, the running probe is dead, worktree removed" INT group
sigrow "HUP to the process group -> 2, the running probe is dead, worktree removed" HUP group
sigrow "TERM to the script alone -> 2, the running probe is dead, worktree removed" TERM script

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
