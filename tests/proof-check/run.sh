#!/usr/bin/env bash
# Drives proof-check.sh against a throwaway git repository and the fake gh. Prints a table.
# Usage: bash tests/proof-check/run.sh [<scripts folder>]   (default: the pr-fixer copy)
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE PROOF_CHECK_ALLOW
T="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$T/../../.agents/skills/pr-fixer/scripts}"
SRC="$(cd "$SRC" && pwd)"; PC="$SRC/proof-check.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W/state" "$W/repo"
export PATH="$T/../fake-gh/bin:$PATH" FAKE_DIR="$W/state"
: >"$FAKE_DIR/calls.log"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }
g() { git -C "$W/repo" -c user.name=t -c user.email=t@example.com "$@"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
ALLOW="$W/allow.txt"; printf '# permitted prefixes\nbash tests/\n' >"$ALLOW"
# run <file> [options]: proof-check on a file, from inside the scratch repository, stdin closed.
run() { local f="$1"; shift; (cd "$W/repo" && bash "$PC" --file "$f" --allow-file "$ALLOW" "$@") </dev/null >"$W/out" 2>&1; echo $?; }
has() { grep -q -- "$1" "$W/out"; }
eq() { [ "$1" = "$2" ]; }

# ---- the repository: base, then a fix commit on top, and a side commit off base ----------------
g init -q -b main . 2>/dev/null || { git -C "$W/repo" init -q; g checkout -q -b main; }
mkdir -p "$W/repo/tests" "$W/repo/other"
printf 'echo hello\nexit 0\n' >"$W/repo/tests/pass.sh"
printf 'echo broken >&2\nexit 3\n' >"$W/repo/tests/fail.sh"
printf 'echo "$1"\n' >"$W/repo/tests/echo.sh"
printf 'exit 0\n' >"$W/repo/other/x.sh"
# W2: children a command leaves behind. TOK makes their sleeps findable by pgrep and by nothing else.
TOK="$$$(date +%s | tail -c 5)"
printf 'sleep 21.%s &\necho started\nexit 0\n' "$TOK" >"$W/repo/tests/bg.sh"
printf 'sleep 22.%s\nexit 0\n' "$TOK" >"$W/repo/tests/fg.sh"
printf 'head -c 70000000 /dev/zero\nexit 0\n' >"$W/repo/tests/big.sh"
# W5: a foreground sleep that marks, outside the clone, that it started (sig.sh <name> <digit>).
printf 'touch "%s/started-$1"\nsleep 2$2.%s\nexit 0\n' "$W" "$TOK" >"$W/repo/tests/sig.sh"
# PR 85 W1: waits (at most 15 s) until the reader of the checker's stdout is gone, then exits 0.
printf 'for k in $(seq 1 150); do [ -e "%s/reader-gone" ] && exit 0; sleep 0.1; done\nexit 0\n' "$W" >"$W/repo/tests/wait.sh"
# W3: what the command sees. Distinct exit codes name the rule that broke.
cat >"$W/repo/tests/env.sh" <<'EOF'
case "$1" in
  token) [ -z "${GH_TOKEN:-}" ] || exit 7 ;;
  home) case "$HOME" in */proof-check-*/home-*) ;; *) exit 8 ;; esac
        [ -z "$(ls -A "$HOME")" ] || exit 9 ;;
esac
exit 0
EOF
# N3: a program found only through a relative PATH element, inside the checkout.
printf '#!/bin/sh\nexit 0\n' >"$W/repo/pc-n3prog"; chmod +x "$W/repo/pc-n3prog"
g add -A; g commit -q -m base
BASE="$(g rev-parse HEAD)"; BASE_TREE="$(g rev-parse HEAD^{tree})"
printf 'echo fixed\nexit 0\n' >"$W/repo/tests/fail.sh"; g commit -q -am fix
HEAD="$(g rev-parse HEAD)"; HEAD_TREE="$(g rev-parse HEAD^{tree})"
g checkout -q -b side "$BASE"; echo s >"$W/repo/side.txt"; g add -A; g commit -q -m side
SIDE="$(g rev-parse HEAD)"; SIDE_TREE="$(g rev-parse HEAD^{tree})"
g checkout -q main
OUT_PASS="$(cd "$W/repo" && bash tests/pass.sh </dev/null 2>&1 | sha256)"
ZERO="$(printf 'x' | sha256)"   # a well-formed hash that matches no output here

# entry <command> <exit> <head> <tree> [output sha]: one JSON object.
entry() { printf '{"command":"%s","exit_code":%s,"head_sha":"%s","tree_hash":"%s","tool_versions":{"bash":"%s"},"output_sha256":"%s"}' \
  "$1" "$2" "$3" "$4" "${BASH_VERSION%%(*}" "${5:-$ZERO}"; }
# closure <file> <json array> [marker head]: a closure text whose last block is the proofs block.
closure() {
  { [ -z "${3:-}" ] || printf '<%s pr-fixer-closure: cycle=1 head=%s closed=1 refused=0 debt=0 -->\n' '!--' "${3:0:12}"
    printf 'Written by pr-fixer, cycle 1.\n\nC1 green: 1 passed.\n\n```proofs\n%s\n```\n' "$2"; } >"$1"; }

GOOD="[$(entry 'bash tests/pass.sh' 0 "$HEAD" "$HEAD_TREE" "$OUT_PASS"),$(entry 'bash tests/fail.sh' 3 "$BASE" "$BASE_TREE"),$(entry 'bash tests/fail.sh' 0 "$HEAD" "$HEAD_TREE")]"
closure "$W/good.md" "$GOOD" "$HEAD"
r=$(run "$W/good.md"); check "matching proofs (a red on the parent, two greens on the head) -> 0" \
  eval '[ $r = 0 ] && has "ok, 3 of 3 entries re-run, all match"'
r=$(run "$W/good.md" --check-output --sample 1 --seed 3); \
  check "--check-output with the true output hash -> 0" eval '[ $r = 0 ] || { cat "$W/out"; false; }'

closure "$W/badexit.md" "[$(entry 'bash tests/pass.sh' 0 "$HEAD" "$HEAD_TREE"),$(entry 'bash tests/fail.sh' 0 "$BASE" "$BASE_TREE")]" "$HEAD"
r=$(run "$W/badexit.md"); check "a changed exit code (claimed 0, the run exits 3) -> 1" \
  eval '[ $r = 1 ] && has "entry 2 MISMATCH" && has "exit 3, claimed 0"'
closure "$W/badout.md" "[$(entry 'bash tests/pass.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(run "$W/badout.md" --check-output); check "a wrong output hash with --check-output -> 1" eval '[ $r = 1 ] && has "output sha256"'
r=$(run "$W/badout.md"); check "the same wrong output hash without --check-output -> 0" eq "$r" 0

NOSUCH="$(printf 'nosuch' | sha256)"; NOSUCH="${NOSUCH:0:40}"
closure "$W/nohead.md" "[$(entry 'bash tests/pass.sh' 0 "$NOSUCH" "$HEAD_TREE")]"
r=$(run "$W/nohead.md"); check "a head_sha that is no commit -> 2" eval '[ $r = 2 ] && has "is not a commit"'
closure "$W/sidehead.md" "[$(entry 'bash tests/pass.sh' 0 "$SIDE" "$SIDE_TREE")]" "$HEAD"
r=$(run "$W/sidehead.md"); check "a head_sha off the closure marker's head -> 2" eval '[ $r = 2 ] && has "nor an ancestor"'
closure "$W/sidehead2.md" "[$(entry 'bash tests/pass.sh' 0 "$SIDE" "$SIDE_TREE")]"
r=$(run "$W/sidehead2.md" --head "$HEAD"); check "a head_sha off --head -> 2" eval '[ $r = 2 ] && has "nor an ancestor"'
closure "$W/badtree.md" "[$(entry 'bash tests/pass.sh' 0 "$HEAD" "$BASE_TREE")]" "$HEAD"
r=$(run "$W/badtree.md"); check "a tree_hash that is not the head's tree -> 2" eval '[ $r = 2 ] && has "is not the tree of"'

# Refusals: every one exits 2 before anything runs (no "re-running" line).
refused() { local name="$1" cmd="$2" want="$3"; shift 3
  closure "$W/ref.md" "[$(entry 'bash tests/pass.sh' 0 "$HEAD" "$HEAD_TREE"),$(entry "$cmd" 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
  r=$(run "$W/ref.md" "$@"); check "$name -> 2, nothing run" eval '[ $r = 2 ] && has "$want" && ! has "re-running"'; }
refused "a command outside the allowlist" 'bash other/x.sh' "not on the allowlist"
refused "an allowlisted prefix glued to another word (testsx/)" 'bash testsx/pass.sh' "not on the allowlist"
refused "a shell separator after an allowlisted command" 'bash tests/pass.sh; touch pwned' "command refused"
refused "a .. path part under an allowlisted prefix" 'bash tests/../other/x.sh' "command refused"
refused "an absolute path argument" 'bash tests/echo.sh /etc/passwd' "command refused"
refused "a dollar expansion" 'bash tests/echo.sh $HOME' "command refused"
# W1 (pass 1): a path can hide in an option value, and an entry permits any words after it.
refused "an option value holding an absolute path (--output=/abs)" 'bash tests/echo.sh --output=/etc/passwd' "command refused"
refused "a key=value word holding an absolute path, no dash (out=/abs)" 'bash tests/echo.sh out=/etc/passwd' "command refused"
refused "an @/abs word" 'bash tests/echo.sh @/etc/passwd' "command refused"
refused "a file:/// word" 'bash tests/echo.sh file:///etc/passwd' "command refused"
refused "a ~ after a comma (a,~/x)" 'bash tests/echo.sh a,~/x' "command refused"
refused "a .. path part after = (out=../x)" 'bash tests/echo.sh out=../x' "command refused"
refused "a glued short option after the entry (-o/abs)" 'bash tests/echo.sh -o/etc/passwd' "starts with -"
refused "an option word after the entry (-x)" 'bash tests/echo.sh -x' "starts with -"
PROOF_CHECK_ALLOW=bash refused "bash -c under the one-word entry bash" 'bash -c id' "starts with -"
printf 'precious\n' >"$W/precious.txt"
closure "$W/gitdiff.md" "[$(entry "git diff --output=$W/precious.txt" 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$( (cd "$W/repo" && PROOF_CHECK_ALLOW='git diff' bash "$PC" --file "$W/gitdiff.md") </dev/null >"$W/out" 2>&1; echo $?)
check "git diff --output=<abs scratch file> under the entry git diff -> 2, the file keeps its content" \
  eval '[ $r = 2 ] && ! has "re-running" && [ "$(cat "$W/precious.txt")" = precious ]'
closure "$W/optin.md" "[$(entry 'bash tests/echo.sh -x' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$( (cd "$W/repo" && PROOF_CHECK_ALLOW='bash tests/echo.sh -x' bash "$PC" --file "$W/optin.md") </dev/null >"$W/out" 2>&1; echo $?)
check "an option written into the allowlist entry itself is permitted -> 0" eval '[ $r = 0 ] && has "all match"'
closure "$W/one.md" "[$(entry 'bash tests/pass.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$( (cd "$W/repo" && bash "$PC" --file "$W/one.md") </dev/null >"$W/out" 2>&1; echo $?)
check "no allowlist at all -> 2, nothing run" eval '[ $r = 2 ] && has "no allowlist is configured" && ! has "re-running"'
r=$( (cd "$W/repo" && PROOF_CHECK_ALLOW='bash tests/pass.sh' bash "$PC" --file "$W/one.md") </dev/null >"$W/out" 2>&1; echo $?)
check "PROOF_CHECK_ALLOW naming the exact command -> 0" eq "$r" 0

# W2 (pass 1): each command runs in its own process group, which is stopped when it ends or times out.
gone() { local k; for k in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "slee[p] $1.$TOK" >/dev/null || return 0; sleep 0.2; done; return 1; }
closure "$W/bg.md" "[$(entry 'bash tests/bg.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(run "$W/bg.md" --timeout 5); check "a command that exits 0 and leaves a background child -> 0, the child is stopped" \
  eval '[ $r = 0 ] && has "all match" && gone 21'
closure "$W/fg.md" "[$(entry 'bash tests/fg.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(run "$W/fg.md" --timeout 1); check "a timed-out command -> 2, and its child (the sleep) is stopped too" \
  eval '[ $r = 2 ] && has "timed out after 1 s" && gone 22'
pkill -f "slee[p] 2[12].$TOK" 2>/dev/null
# W5 (pass 2): the checker itself stopped by SIGTERM (an outer timeout) or SIGHUP stops the command's
# group and deletes its work folder. TMPDIR points the work folder at a scratch place this row lists.
SIGTMP="$W/tmp-sig"; mkdir -p "$SIGTMP"; rm -f "$W"/started-*
closure "$W/term.md" "[$(entry 'bash tests/sig.sh term 3' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$( (cd "$W/repo" && TMPDIR="$SIGTMP" timeout --preserve-status -s TERM "${PC_TERM_AFTER:-12}" bash "$PC" --file "$W/term.md" --allow-file "$ALLOW" --timeout 600) </dev/null >"$W/out" 2>&1; echo $?)
check "proof-check under timeout -s TERM (W5) -> exit 2, the command's sleep is stopped, no work folder left" \
  eval '[ -e "$W/started-term" ] && [ $r = 2 ] && has "stopped by signal SIGTERM" && gone 23 && [ -z "$(ls -A "$SIGTMP")" ]'
pkill -f "slee[p] 23.$TOK" 2>/dev/null; rm -rf "$SIGTMP"; mkdir -p "$SIGTMP"
closure "$W/hup.md" "[$(entry 'bash tests/sig.sh hup 4' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
(cd "$W/repo" && TMPDIR="$SIGTMP" exec bash "$PC" --file "$W/hup.md" --allow-file "$ALLOW" --timeout 600) </dev/null >"$W/out" 2>&1 &
pid=$!; for k in $(seq 1 150); do [ -e "$W/started-hup" ] && break; sleep 0.2; done
kill -HUP "$pid" 2>/dev/null; wait "$pid"; r=$?
check "proof-check sent SIGHUP while the command runs (W5) -> 2, the sleep is stopped, no work folder left" \
  eval '[ -e "$W/started-hup" ] && [ $r = 2 ] && has "stopped by signal SIGHUP" && gone 24 && [ -z "$(ls -A "$SIGTMP")" ]'
pkill -f "slee[p] 24.$TOK" 2>/dev/null
# PR 82 N7: a signal after an entry printed MISMATCH exits 1, since a mismatch wins over a later failure.
rm -rf "$SIGTMP"; mkdir -p "$SIGTMP"
closure "$W/mmterm.md" "[$(entry 'bash tests/pass.sh' 1 "$HEAD" "$HEAD_TREE"),$(entry 'bash tests/sig.sh mmterm 5' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
(cd "$W/repo" && TMPDIR="$SIGTMP" exec bash "$PC" --file "$W/mmterm.md" --allow-file "$ALLOW" --timeout 600) </dev/null >"$W/out" 2>&1 &
pid=$!; for k in $(seq 1 150); do [ -e "$W/started-mmterm" ] && break; sleep 0.2; done
kill -TERM "$pid" 2>/dev/null; wait "$pid"; r=$?
check "a MISMATCH, then SIGTERM while the next command runs (PR 82 N7) -> 1, the sleep is stopped, no work folder left" \
  eval '[ -e "$W/started-mmterm" ] && [ $r = 1 ] && has "entry 1 MISMATCH" && has "stopped by signal SIGTERM" && has "1 re-run entries did not match before the stop" && gone 25 && [ -z "$(ls -A "$SIGTMP")" ]'
pkill -f "slee[p] 25.$TOK" 2>/dev/null
# PR 85 W1: a crash after an entry printed MISMATCH exits 1 as well. head -n 2 closes the checker's
# stdout, so its next say() raises BrokenPipeError, which goes through _crash. wait.sh holds entry 2
# until the reader has closed its end of the pipe, so the crash always comes after the MISMATCH.
rm -rf "$SIGTMP"; mkdir -p "$SIGTMP"; rm -f "$W/reader-gone"
closure "$W/mmpipe.md" "[$(entry 'bash tests/pass.sh' 1 "$HEAD" "$HEAD_TREE"),$(entry 'bash tests/wait.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
(cd "$W/repo" && TMPDIR="$SIGTMP" bash "$PC" --file "$W/mmpipe.md" --allow-file "$ALLOW" --timeout 600) </dev/null 2>"$W/err" \
  | { head -n 2 >"$W/out"; exec 0<&-; touch "$W/reader-gone"; }
r=${PIPESTATUS[0]}
check "a MISMATCH, then a crash (stdout closed by head -n 2) while the next entry runs (PR 85 W1) -> 1, no work folder left" \
  eval '[ -e "$W/reader-gone" ] && [ $r = 1 ] && has "entry 1 MISMATCH" && [ -z "$(ls -A "$SIGTMP")" ]'
closure "$W/big.md" "[$(entry 'bash tests/big.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(run "$W/big.md"); check "output past the 64 MiB cap -> 2 (N4)" eval '[ $r = 2 ] && has "MiB"'

# W3 (pass 1): one row per isolation rule, each failing when that rule alone is undone.
closure "$W/envtok.md" "[$(entry 'bash tests/env.sh token' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(GH_TOKEN=plain-test-value run "$W/envtok.md"); check "GH_TOKEN set for the checker does not reach the command -> 0" eval '[ $r = 0 ] && has "all match"'
closure "$W/envhome.md" "[$(entry 'bash tests/env.sh home' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(run "$W/envhome.md"); check "HOME is an empty proof-check scratch folder -> 0" eval '[ $r = 0 ] && has "all match"'
closure "$W/mmfail.md" "[$(entry 'bash tests/pass.sh' 1 "$HEAD" "$HEAD_TREE"),$(entry 'bash tests/fg.sh' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$(run "$W/mmfail.md" --timeout 1); check "a mismatch, then a timeout -> 1 (a mismatch wins)" eval '[ $r = 1 ] && has "also entry 2"'
pkill -f "slee[p] 22.$TOK" 2>/dev/null
mkdir -p "$W/hooks"; printf '#!/bin/sh\ntouch "%s"\n' "$W/hook-ran" >"$W/hooks/post-checkout"; chmod +x "$W/hooks/post-checkout"
printf '[core]\n\thooksPath = %s\n' "$W/hooks" >"$W/gitconfig"; rm -f "$W/hook-ran"
r=$(GIT_CONFIG_GLOBAL="$W/gitconfig" run "$W/one.md"); check "a hooksPath in the checker's git config runs no hook in the clone -> 0" eval '[ $r = 0 ] && [ ! -e "$W/hook-ran" ]'
MANY=""; for k in $(seq 1 201); do MANY="$MANY${MANY:+,}$(entry 'bash tests/pass.sh' 0 "$HEAD" "$HEAD_TREE")"; done
closure "$W/many.md" "[$MANY]" "$HEAD"
r=$(run "$W/many.md"); check "201 entries -> 2, nothing run" eval '[ $r = 2 ] && has "the limit is 200" && ! has "re-running"'
r=$( (cd "$W/repo" && bash "$PC" --file "$W/one.md" --allow-file "$ALLOW" --repo "$W/no-such-dir") </dev/null >"$W/out" 2>&1; echo $?)
check "an unforeseen error (a --repo that does not exist) -> 2, internal error" eval '[ $r = 2 ] && has "internal error"'
# N2: the final line names the head the proofs were bound to, and where it came from.
r=$(run "$W/one.md"); check "the ok line names the head bound and its source (N2)" eval '[ $r = 0 ] && has "head bound ${HEAD:0:12} (the closure marker)"'
# N3: a relative PATH element does not resolve a bare program inside the checkout.
closure "$W/n3.md" "[$(entry 'pc-n3prog' 0 "$HEAD" "$HEAD_TREE")]" "$HEAD"
r=$( (cd "$W/repo" && PATH=".:$PATH" PROOF_CHECK_ALLOW=pc-n3prog bash "$PC" --file "$W/n3.md") </dev/null >"$W/out" 2>&1; echo $?)
check "a bare program found only through a relative PATH element -> 2 (N3)" eval '[ $r = 2 ] && has "could not start"'

# Malformed input: exit 2, never 0.
printf '```proofs\n[{"command": "bash tests/pass.sh",\n```\n' >"$W/bad.md"
r=$(run "$W/bad.md"); check "malformed JSON -> 2" eval '[ $r = 2 ] && has "not valid JSON"'
printf 'no block here\n' >"$W/none.md"
r=$(run "$W/none.md"); check "no proofs block -> 2" eval '[ $r = 2 ] && has "found 0"'
{ cat "$W/one.md"; printf '```proofs\n[]\n```\n'; } >"$W/two.md"
r=$(run "$W/two.md"); check "two proofs blocks -> 2" eval '[ $r = 2 ] && has "found 2"'
closure "$W/empty.md" "[]"
r=$(run "$W/empty.md"); check "an empty array -> 2" eval '[ $r = 2 ] && has "non-empty JSON array"'
closure "$W/missing.md" '[{"command":"bash tests/pass.sh","exit_code":0}]'
r=$(run "$W/missing.md"); check "an entry lacking fields -> 2" eval '[ $r = 2 ] && has "lacks head_sha"'
closure "$W/boolexit.md" "[$(entry 'bash tests/pass.sh' true "$HEAD" "$HEAD_TREE")]"
r=$(run "$W/boolexit.md"); check "exit_code true (not a number) -> 2" eval '[ $r = 2 ] && has "exit_code is not"'

# Sampling: the same seed picks the same entries, and the pick is sha256("<seed>:<index>") order.
SIX=""; for k in 1 2 3 4 5 6; do SIX="$SIX${SIX:+,}$(entry "bash tests/echo.sh e$k" 0 "$HEAD" "$HEAD_TREE")"; done
closure "$W/six.md" "[$SIX]" "$HEAD"
pick() { python3 -I -c 'import hashlib,sys; s=sys.argv[1]; n=int(sys.argv[2])
print(" ".join(str(i) for i in sorted(sorted(range(1,7), key=lambda i: hashlib.sha256(("%s:%d"%(s,i)).encode()).hexdigest())[:n])))' "$1" "$2"; }
picked() { sed -n 's/^proof-check: re-running [0-9]* of [0-9]* entries: //p' "$W/out"; }
# Three runs of 3 out of 6 (20 possible picks): a random pick passes this row about once in 400.
r=$(run "$W/six.md" --sample 3 --seed 7); P1="$(picked)"
r2=$(run "$W/six.md" --sample 3 --seed 7); P2="$(picked)"
r3=$(run "$W/six.md" --sample 3 --seed 7); P3="$(picked)"
check "--sample 3 --seed 7 three times picks the same three entries" eval '[ $r = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ] && [ -n "$P1" ] && [ "$P1" = "$P2" ] && [ "$P1" = "$P3" ] && [ "$(echo $P1 | wc -w | tr -d " ")" = 3 ]'
check "the pick is the sha256 seed order (seed 7)" eval '[ "$P1" = "$(pick 7 3)" ]'
r=$(run "$W/six.md" --sample 3 --seed abc); check "the pick is the sha256 seed order (seed abc, 3)" eval '[ "$(picked)" = "$(pick abc 3)" ]'
# W4 (pass 1): with no --seed the checker draws the seed, prints it, and that seed repeats the pick.
seedof() { sed -n 's/^proof-check: sample seed \([A-Za-z0-9._-]*\) .*/\1/p' "$W/out"; }
r=$(run "$W/six.md" --sample 3); S1="$(seedof)"; P1="$(picked)"
r2=$(run "$W/six.md" --sample 3); S2="$(seedof)"
r3=$(run "$W/six.md" --sample 3 --seed "$S1"); P3="$(picked)"
check "no --seed: the checker draws a seed, prints it, and --seed with it repeats the pick" \
  eval '[ -n "$S1" ] && [ -n "$S2" ] && [ "$S1" != "$S2" ] && [ "$P1" = "$P3" ] && [ "$P1" = "$(pick "$S1" 3)" ]'
# The reviewer's scenario: entry 1 claims exit 1 for a command that exits 0, --sample 5 of 6, no --seed.
# Each run misses entry 1 with odds 1/6; twelve runs all missing it is about 1 in 2 billion.
FALSE1="$(entry 'bash tests/pass.sh' 1 "$HEAD" "$HEAD_TREE")"
for k in 2 3 4 5 6; do FALSE1="$FALSE1,$(entry "bash tests/echo.sh e$k" 0 "$HEAD" "$HEAD_TREE")"; done
closure "$W/false1.md" "[$FALSE1]" "$HEAD"
caught=0; for k in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(run "$W/false1.md" --sample 5)" = 1 ] && caught=$((caught+1)); done
check "a false entry 1, --sample 5 of 6 with no --seed, twelve runs: some run catches it (caught $caught)" eval '[ $caught -gt 0 ]'
r=$(run "$W/six.md" --sample 9); check "--sample larger than the list runs all" eval '[ "$(picked)" = "1 2 3 4 5 6" ]'

# --pr: the closure comment is read through pr-json.py and the fake gh, from a trusted author only.
mkpr() { # head comments-json
  printf '{"number":7,"headRefOid":"%s","labels":[],"comments":%s,"state":"OPEN","isDraft":false,"author":{"login":"jony"},"isCrossRepository":false}' "$1" "$2" >"$FAKE_DIR/pr.json"; }
mc() { python3 -I -c 'import json,sys;print(json.dumps({"body":open(sys.argv[2]).read(),"author":{"login":sys.argv[1]}}))' "$1" "$2"; }
runpr() { (cd "$W/repo" && REVIEW_MARKER_AUTHORS="${AUTH-fixerbot}" bash "$PC" --pr 7 --allow-file "$ALLOW" "$@") </dev/null >"$W/out" 2>&1; echo $?; }
mkpr "$HEAD" "[$(mc fixerbot "$W/good.md")]"
r=$(runpr); check "--pr: a trusted closure that matches -> 0" eval '[ $r = 0 ] && has "all match"'
mkpr "$HEAD" "[$(mc fixerbot "$W/good.md"),$(mc mallory "$W/badexit.md")]"
r=$(runpr); check "--pr: a newer closure by an untrusted login is not read -> 0" eq "$r" 0
mkpr "$HEAD" "[$(mc mallory "$W/good.md")]"
r=$(runpr); check "--pr: only an untrusted author's closure -> 2" eval '[ $r = 2 ] && has "no trusted"'
r=$(AUTH='' runpr); check "--pr: REVIEW_MARKER_AUTHORS empty -> 2" eval '[ $r = 2 ] && has "names no login"'
closure "$W/sideonly.md" "[$(entry 'bash tests/pass.sh' 0 "$SIDE" "$SIDE_TREE")]" "$SIDE"
mkpr "$HEAD" "[$(mc fixerbot "$W/sideonly.md")]"
r=$(runpr); check "--pr: a proof off the pull request's head -> 2" eval '[ $r = 2 ] && has "nor an ancestor"'
mkpr "$HEAD" "[$(mc fixerbot "$W/badexit.md")]"
r=$(runpr); check "--pr: a closure whose exit code changed -> 1" eq "$r" 1
touch "$FAKE_DIR/graphql-fail"
r=$(runpr); check "--pr: the pull request cannot be read -> 2" eval '[ $r = 2 ] && has "could not be read"'
rm -f "$FAKE_DIR/graphql-fail"

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
