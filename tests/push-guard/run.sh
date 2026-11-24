#!/usr/bin/env bash
# Drives push-guard.sh against a throwaway git repository and the triage fake gh. Prints a table.
set -u
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what is refused; a row that
# needs one sets it itself.
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$T/../../.agents/skills/pr-fixer/scripts}"
SRC="$(cd "$SRC" && pwd)"; PG="$SRC/push-guard.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W/state" "$W/repo"
export PATH="$T/../fake-gh/triage/bin:$PATH" FAKE_DIR="$W/state"
: >"$FAKE_DIR/calls.log"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
eq() { [ "$1" = "$2" ]; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }
g() { git -C "$W/repo" -c user.name=t -c user.email=t@example.com "$@"; }
prjson() { # state head_ref head_oid cross [base_oid] [base_ref] [url]
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s","baseRefName":"%s","baseRefOid":"%s","isCrossRepository":%s,"url":"%s"}' "$1" "$2" "$3" "${6:-main}" "${5:-$BASE_OID}" "$4" "${7-https://github.com/o/r/pull/7}" >"$FAKE_DIR/pr.json"; }
# The live base tip as GitHub reports it: tip OID [baseRefName] [gql path] writes the GraphQL answer for the pull
# request (by default o/r #7 on github.com, the url prjson writes) and the REST ref the guard before PR 70 N1 read,
# so a row that only the GraphQL read passes is red on that guard. gqlraw writes the GraphQL answer as given.
gqlraw() { mkdir -p "$(dirname "$FAKE_DIR/gql/$2")"; printf '%s' "$1" >"$FAKE_DIR/gql/$2"; }
tip() { printf '%s\n' "$1" >"$FAKE_DIR/base-tip"; rm -rf "$FAKE_DIR/gql"
  gqlraw "$(node -e 'process.stdout.write(JSON.stringify({data:{repository:{pullRequest:{baseRefName:process.argv[2],baseRef:{target:{oid:process.argv[1]}}}}}}))' -- "$1" "${2:-main}")" "${3:-github.com/o/r/7.json}"; }
notip() { rm -rf "$FAKE_DIR/base-tip" "$FAKE_DIR/gql"; }
run() { (cd "$W/repo" && "$PG" 7 "$@") >"$W/out" 2>&1; echo $?; }
# BASHOPTS is readonly in this shell, so an assignment before a function call never reaches the guard: env passes it.
# bash -O sets a shell option on the command line, not through the environment, so the guard keeps it: this is how
# the printf lines are checked under xpg_echo (an inherited BASHOPTS makes the guard restart without it).
# PR 75 N7: a runner that exports BASHOPTS or SHELLOPTS would make the guard restart without the -O option, so the
# rows built on runopt could not fail there; env drops both first.
runopt() { local o="$1"; shift; (cd "$W/repo" && env -u BASHOPTS -u SHELLOPTS bash -O "$o" "$PG" 7 "$@") >"$W/out" 2>&1; echo $?; }
runenv() { local e="$1"; shift; (cd "$W/repo" && env "$e" "$PG" 7 "$@") >"$W/out" 2>&1; echo $?; }

# The locale rows need a UTF-8 locale; without one bash falls back to C and those rows could not fail, so the table says so.
# PR 75 N2: en_US or C UTF-8 first, else any UTF-8 locale the host lists.
pick_ul() { local all; all="$(cat)"
  printf '%s\n' "$all" | grep -iE '^(en_US|C)\.utf-?8$' | head -n 1 | grep . || printf '%s\n' "$all" | grep -iE 'utf-?8' | head -n 1; }
UL="$(locale -a 2>/dev/null | pick_ul)"
[ -n "$UL" ] || { UL=C; ROWS+=("SKIP | no UTF-8 locale on this host: the U+2028, mañana and bash 3.2 rows cannot fail here"); }
g init -q -b main . 2>/dev/null || { git -C "$W/repo" init -q; g checkout -q -b main; }
mkdir -p "$W/repo/src" "$W/repo/tests"
echo a >"$W/repo/src/a.ts"; echo b >"$W/repo/src/b.ts"
g add -A; g commit -q -m base
BASE_OID="$(g rev-parse HEAD)"
g checkout -q -b feat/x
echo c >>"$W/repo/src/a.ts"; g commit -q -am "pr head"
HEAD_OID="$(g rev-parse HEAD)"
printf '## r\n\n```findings\nversion: 1\nfindings:\n  - id: C1\n    severity: CRITICAL\n    file: src/a.ts\n    line: 1\n```\n' >"$W/rep.md"

prjson OPEN feat/x "$HEAD_OID" false
r=$(run --findings "$W/rep.md"); check "no new commit, right branch -> ok" eval '[ $r = 0 ] && grep -q "push-guard: ok" "$W/out"'

echo d >>"$W/repo/src/a.ts"; echo t >"$W/repo/tests/a.test.ts"; g add -A; g commit -q -m fix
r=$(run --findings "$W/rep.md"); check "fix touches finding file and a test -> ok" eq "$r" 0

echo e >>"$W/repo/src/b.ts"; g commit -q -am "creep"
r=$(run --findings "$W/rep.md"); check "touches a file no finding names -> refused" eval '[ $r = 1 ] && grep -q "src/b.ts" "$W/out"'
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "same file with --allow -> ok" eq "$r" 0
r=$(run); check "no --findings and no --allow -> refused" eq "$r" 1

mkdir -p "$W/repo/src/test_cases_not_tests"; echo g >"$W/repo/src/test_cases_not_tests/deploy.ts"
g add -A; g commit -q -m "lookalikes"
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "names that only look like tests -> refused" eval '[ $r = 1 ] && grep -q "src/test_cases_not_tests/deploy.ts" "$W/out"'
r=$(run --findings "$W/rep.md" --allow '../x'); check "--allow with .. -> refused" eq "$r" 1
r=$(run --findings "$W/rep.md" --allow 'src/*'); check "--allow with a glob -> refused" eq "$r" 1
g reset -q --hard HEAD~1
g checkout -q -b other
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "wrong branch checked out -> refused" eval '[ $r = 1 ] && grep -q "checked-out branch is .other." "$W/out"'
g checkout -q feat/x

prjson OPEN feat/x "$HEAD_OID" true
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "fork head -> refused" eval '[ $r = 1 ] && grep -q "fork" "$W/out"'
prjson MERGED feat/x "$HEAD_OID" false
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "merged pull request -> refused" eval '[ $r = 1 ] && grep -q "MERGED" "$W/out"'

# The remote head is a commit local HEAD does not contain: a push would not be a fast-forward.
g checkout -q -b side main; echo z >"$W/repo/src/z.ts"; g add -A; g commit -q -m side
SIDE="$(g rev-parse HEAD)"; g checkout -q feat/x
prjson OPEN feat/x "$SIDE" false
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "remote head not an ancestor -> refused" eval '[ $r = 1 ] && grep -q "fast-forward" "$W/out"'

prjson OPEN feat/x 0000000000000000000000000000000000000000 false
r=$(run --findings "$W/rep.md"); check "head commit absent locally -> 2" eq "$r" 2
touch "$FAKE_DIR/offline"; r=$(run --findings "$W/rep.md"); check "gh offline -> 2" eq "$r" 2; rm -f "$FAKE_DIR/offline"
prjson OPEN feat/x "$HEAD_OID" false
r=$( (cd "$W" && "$PG" abc) >/dev/null 2>&1; echo $?); check "non-numeric pull request -> 2" eq "$r" 2

# A merge commit from the base is not scope-checked.
g checkout -q -b feat/m "$HEAD_OID"; echo q >"$W/repo/src/q.ts"; g add -A; g commit -q -m "base moved"; g checkout -q main
echo y >"$W/repo/src/y.ts"; g add -A; g commit -q -m "main moves"; g checkout -q feat/m
g merge -q --no-edit main >/dev/null 2>&1
prjson OPEN feat/m "$HEAD_OID" false "$(g rev-parse main)"
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "merge commit from the base -> ok" eq "$r" 0
# GitHub's baseRefOid still names the old base before the first push of a merge of a base that moved
# (PR 65): the live tip of the base branch, read from GitHub, keeps the base's commits out of scope.
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID"
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "stale baseRefOid, live base tip unreadable -> refused, the base's file counts" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out"'
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "stale baseRefOid, live base tip unreadable -> the skip line says why" eval '[ $r = 1 ] && grep -q "live tip of the base branch main was not used (GitHub could not be asked for it)" "$W/out"'
tip "$(g rev-parse main)"; : >"$FAKE_DIR/calls.log"
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "stale baseRefOid, live base tip from GitHub -> ok" eq "$r" 0
# PR 70 N1: the tip is the pull request's own base ref, asked through GraphQL in the repository and on the host the
# pull request's url names, so no branch name goes into a URL and gh's {owner}/{repo} plays no part.
grep -qF 'gh api graphql --hostname github.com -f owner=o -f name=r -F number=7 -f query=' "$FAKE_DIR/calls.log" && ! grep -q 'git/ref/heads/' "$FAKE_DIR/calls.log"
check "the live base tip is the pull request's baseRef through GraphQL, never the REST ref by name (N1 of #70)" eq "$?" 0
# Before N1 the name went into a URL path, so a #, a %-escape, a {placeholder}, a .., an empty or dot-leading segment,
# a name git check-ref-format refuses or a non-ASCII letter kept the tip unread. The name now only has to equal the
# baseRefName GitHub answers, so each of these reads the tip, and the push of the merge of the base passes.
for b in 'sprint#4' 'zz/%2e%2e/main' '{branch}' 'a..b' 'a b' './main' '/main' 'a//b' 'main/' 'x/.hidden' 'main.lock' 'mañana'; do
  prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" "$b"; tip "$(g rev-parse main)" "$b"; : >"$FAKE_DIR/calls.log"
  r=$(LC_ALL="$UL" run --findings "$W/rep.md" --allow src/q.ts); check "base name '$b' -> live tip read through GraphQL, ok, no skip line (N1 of #70)" eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out" && ! grep -q "git/ref/heads/" "$FAKE_DIR/calls.log" && ! grep -q "was not used" "$W/out"'
done
# N5 of #70: bash 3.2 (macOS /bin/bash) lets a UTF-8 locale widen a range such as A-Z to ñ; where /bin/bash is 3.2 the
# guard runs under it, elsewhere under the default bash. The name is compared in node, so it reads the tip there too.
B32=bash; case "$(/bin/bash -c 'echo $BASH_VERSION' 2>/dev/null)" in 3.*) B32=/bin/bash ;; esac
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" 'mañana'; tip "$(g rev-parse main)" 'mañana'; : >"$FAKE_DIR/calls.log"
r=$( (cd "$W/repo" && LC_ALL="$UL" "$B32" "$PG" 7 --findings "$W/rep.md" --allow src/q.ts) >"$W/out" 2>&1; echo $?)
check "base name 'mañana' under $B32 and a UTF-8 locale -> live tip read through GraphQL, ok (N1 of #70)" eval '[ $r = 0 ] && ! grep -q "git/ref/heads/" "$FAKE_DIR/calls.log"'
# The tip is used only for the same base branch, as 40 lower-case hex digits. The REST ref holds the right tip in each
# of these rows, so the guard before N1 passes them; this one refuses, and says why.
MAINTIP="$(g rev-parse main)"; prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID"
tip "$MAINTIP" other
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "GraphQL baseRefName differs from the PR's base -> tip not used, refused (N1 of #70)" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out" && grep -q "did not give a commit id for the same base branch" "$W/out"'
tip "$MAINTIP" 'main '
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "GraphQL baseRefName 'main ' (a trailing space) -> tip not used, refused (N1 of #70)" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out"'
UPTIP="$(printf '%s' "$MAINTIP" | tr abcdef ABCDEF)"
for bad in "$UPTIP" "$MAINTIP x" "${MAINTIP:0:39}" "${MAINTIP}0" "x$MAINTIP"; do
  tip "$MAINTIP"; gqlraw "{\"data\":{\"repository\":{\"pullRequest\":{\"baseRefName\":\"main\",\"baseRef\":{\"target\":{\"oid\":\"$bad\"}}}}}}" github.com/o/r/7.json
  r=$(run --findings "$W/rep.md" --allow src/q.ts); check "GraphQL oid '$bad' (not 40 lower-case hex) -> not used, refused (N1 of #70)" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out"'
done
for raw in '{"data":{"repository":{"pullRequest":{"baseRefName":"main","baseRef":null}}}}' \
  '{"data":{"repository":{"pullRequest":{"baseRefName":"main","baseRef":{"target":{}}}}}}' \
  '{"data":{"repository":{"pullRequest":{"baseRefName":"main","baseRef":{"target":{"oid":1}}}}}}' \
  '{"data":{"repository":null},"errors":[{"message":"x"}]}' 'not json'; do
  tip "$MAINTIP"; gqlraw "$raw" github.com/o/r/7.json
  r=$(run --findings "$W/rep.md" --allow src/q.ts); check "GraphQL answer without a usable oid ($raw) -> not used, refused (N1 of #70)" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out" && grep -q "was not used" "$W/out"'
done
# The repository and host asked are the ones the pull request's url names, not the ones gh resolves from the clone's
# remotes (gh 2.33 and older may pick another): only that repository's answer exists, and the REST ref does not.
notip; prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" main https://ghe.example.com/acme/widgets/pull/7
tip "$MAINTIP" main ghe.example.com/acme/widgets/7.json; rm -f "$FAKE_DIR/base-tip"; : >"$FAKE_DIR/calls.log"
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "owner, name and host come from the PR's url -> tip read, ok (N1 of #70)" eval '[ $r = 0 ] && grep -qF "gh api graphql --hostname ghe.example.com -f owner=acme -f name=widgets -F number=7 " "$FAKE_DIR/calls.log"'
# A url that does not name this pull request in a repository (another number, no url, a path that is not a pull
# request, a segment with a character a GitHub name cannot hold) is not asked about; the REST ref still holds the tip.
for u in https://github.com/o/r/pull/8 '' https://github.com/o/r/issues/7 'https://github.com/o/r?x=1/pull/7' 'https://github.com/{owner}/r/pull/7' http://github.com/o/r/pull/7; do
  prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" main "$u"; tip "$MAINTIP"
  for k in github.com/o/r/8.json; do gqlraw "$(cat "$FAKE_DIR/gql/github.com/o/r/7.json")" "$k"; done
  : >"$FAKE_DIR/calls.log"
  r=$(run --findings "$W/rep.md" --allow src/q.ts); check "PR url '$u' -> GitHub not asked, tip not used, refused (N1 of #70)" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out" && ! grep -q "api graphql" "$FAKE_DIR/calls.log" && grep -q "url does not name its repository" "$W/out"'
done
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID"; tip "$MAINTIP"
# A control character in the name is quoted in the skip line, so it cannot forge a line of the output.
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" 'x\nsrc/fake: ok'; r=$(run --findings "$W/rep.md" --allow src/q.ts)
check "a newline in the base name is quoted in the skip line" eval '[ $r = 1 ] && ! grep -q "^src/fake: ok" "$W/out" && grep -qF "\$'"'"'x\\nsrc/fake: ok'"'"'" "$W/out"'
# PR 72 debt. N2: with echo's escapes turned on (xpg_echo from BASHOPTS), the quoted newline still cannot forge a line.
r=$(runopt xpg_echo --findings "$W/rep.md" --allow src/q.ts)
check "xpg_echo on: a newline in the base name still cannot forge a line (printf, not echo)" eval '[ $r = 1 ] && ! grep -q "^src/fake: ok" "$W/out"'
# N1: a Unicode line separator (U+2028) in the name is escaped under a UTF-8 locale too.
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" "x$(printf '\342\200\250')y"
r=$(LC_ALL="$UL" run --findings "$W/rep.md" --allow src/q.ts)
check "U+2028 in the base name is escaped in the skip line" eval '[ $r = 1 ] && ! grep -q "$(printf '"'"'\342\200\250'"'"')" "$W/out" && grep -qF "\\342\\200\\250" "$W/out"'
# N6: with baseRefOid not in the clone either, the skip line says no base commit is excluded.
prjson OPEN feat/m "$HEAD_OID" false 0123456789abcdef0123456789abcdef01234567 'sprint#4'
r=$(run --findings "$W/rep.md" --allow src/q.ts)
check "baseRefOid absent and a name not plain: the skip line says no base commit is excluded" eval '[ $r = 1 ] && grep -q "no base commit is excluded" "$W/out"'
# N3: nocasematch from BASHOPTS would make *_test.* match A_TEST.ts and wave a source file through as a test.
g checkout -q -b feat/nc "$HEAD_OID"; echo t >"$W/repo/src/A_TEST.ts"; g add -A; g commit -q -m upper
prjson OPEN feat/nc "$HEAD_OID" false
r=$(runenv BASHOPTS=nocasematch --findings "$W/rep.md")
check "nocasematch from BASHOPTS is turned off: src/A_TEST.ts is not a test file, refused" eval '[ $r = 1 ] && grep -q "src/A_TEST.ts" "$W/out"'
g checkout -q feat/m
# N8 of #70 checked that the plain-name gate spelled its letters out. N1 of #70 removed the gate: the base name never
# goes into a URL, so no branch name is matched against a letter range at all.
! grep -q 'git/ref/heads' "$PG"
check "the guard reads no ref by name through a REST URL (N1 of #70)" eq "$?" 0
# PR 74 debt. N4: a payload with no baseRefOid at all names that cause in the skip line.
printf '{"state":"OPEN","headRefName":"feat/m","headRefOid":"%s","baseRefName":"sprint#4","baseRefOid":"","isCrossRepository":false,"url":"https://github.com/o/r/pull/7"}' "$HEAD_OID" >"$FAKE_DIR/pr.json"
r=$(run --findings "$W/rep.md" --allow src/q.ts)
check "no baseRefOid and a name not plain: the skip line says no baseRefOid was given" eval '[ $r = 1 ] && grep -q "gave no baseRefOid" "$W/out"'
# N2: an --allow value and the findings-block error are printed with printf, so xpg_echo cannot forge a line.
prjson OPEN feat/m "$HEAD_OID" false
r=$(runopt xpg_echo --findings "$W/rep.md" --allow '../x\nsrc/fake: ok')
check "xpg_echo on: an --allow value cannot forge a line" eval '[ $r = 1 ] && ! grep -q "^src/fake: ok" "$W/out"'
# N3: SHELLOPTS from the environment is dropped too (xtrace would print the guard's own commands). The restart test
# itself runs traced before the restart; nothing after it is (PR 75 N3: the row also asserts the guard ran to its end).
r=$(runenv SHELLOPTS=xtrace --findings "$W/rep.md" --allow src/q.ts)
check "SHELLOPTS=xtrace from the environment: the guard restarts without it, ends in ok, no trace after the restart" eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out" && ! grep -q "^+* *shopt -u nocasematch" "$W/out"'
# PR 75 W1: the restart decides on the variables, not on lines of env output, and happens at most once. Each run is
# bounded, so a loop ends the row as a failure instead of hanging the suite. Not an alarm: bash clears a pending alarm
# when it starts, so an exec loop of bash outlives one. The bound that holds on every platform is a watchdog that
# kills the guard after WD seconds of wall time (status 137). ulimit -t 60 is kept as an extra bound: it stops a busy
# guard after 60 s of CPU, but on macOS it did not stop an exec loop of bash (40 s of CPU, still running at 120 s;
# PR 88 W3), and a restart loop spends most of its time in children, so CPU time is no bound for it there.
# WD is 60 s, times TEST_TIMEOUT_SCALE: a fixed 20 s was within reach of a sound run on a loaded host (one run took 6 s
# at a load of 600 on 12 CPUs; PR 85 N5, PR 86 N1, PR 87 N5), and 300 s let a restart-loop regression take about
# 65 minutes over the 13 rows, past the 1800 s a full run is given, with no row named (PR 88 W3).
WD="$(awk -v s="${TEST_TIMEOUT_SCALE:-1}" 'BEGIN { s += 0; if (s <= 0) s = 1; printf "%d", 60 * s }')"
bnd() { local s="$1" p k rc; shift
  (cd "$W/repo" && ulimit -t 60 && exec "$@") >"$W/out" 2>&1 </dev/null & p=$!
  (sleep "$s"; kill -9 "$p") >/dev/null 2>&1 & k=$!
  wait "$p"; rc=$?; kill "$k" 2>/dev/null; wait "$k" 2>/dev/null; echo "$rc"; }
runb() { local e="$1"; shift; bnd "$WD" env "$e" "$PG" 7 "$@"; }
r=$(runb "FOO=x"$'\n'"BASHOPTS=y" --findings "$W/rep.md" --allow src/q.ts)
check "a value holding a newline then BASHOPTS= -> no restart loop, the guard ends in ok (W1 of #75)" eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out"'
r=$(runb "FOO=x"$'\n'"SHELLOPTS=y" --findings "$W/rep.md" --allow src/q.ts)
check "a value holding a newline then SHELLOPTS= -> no restart loop, the guard ends in ok (W1 of #75)" eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out"'
r=$(runb GREP_OPTIONS=-v --findings "$W/rep.md" --allow src/q.ts)
check "GREP_OPTIONS=-v -> no restart loop, the guard ends in ok (W1 of #75)" eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out"'
# The once-only mark is never a way around the restart: inherited together with BASHOPTS, the guard cannot check (2).
r=$(bnd "$WD" env PUSH_GUARD_RESTARTED=1 BASHOPTS=nocasematch "$PG" 7 --findings "$W/rep.md" --allow src/q.ts)
check "restart mark inherited with BASHOPTS -> 2 INCONCLUSIVE, never a pass with the option on (W1 of #75)" eval '[ $r = 2 ] && grep -q "INCONCLUSIVE" "$W/out"'
# PR 75 N1: the restart runs the bash that started the guard ($BASH), not the first bash on PATH.
mkdir -p "$W/fakebash"; RB="$(command -v bash)"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s/fakebash/log"\nexec "%s" "$@"\n' "$W" "$RB" >"$W/fakebash/bash"; chmod +x "$W/fakebash/bash"; : >"$W/fakebash/log"
r=$(bnd "$WD" env PATH="$W/fakebash:$PATH" BASHOPTS=nocasematch "$RB" "$PG" 7 --findings "$W/rep.md" --allow src/q.ts)
check "the restart runs \$BASH, not the bash first on PATH (N1 of #75)" eval '[ $r = 0 ] && ! grep -q "push-guard.sh$" "$W/fakebash/log"'
# PR 75 N7: BASH_ENV is dropped on the restart, so the second start does not read it again.
printf 'echo x >>"%s/bashenv.log"\n' "$W" >"$W/bashenv.sh"; : >"$W/bashenv.log"
r=$(bnd "$WD" env BASHOPTS=nocasematch BASH_ENV="$W/bashenv.sh" "$PG" 7 --findings "$W/rep.md" --allow src/q.ts)
check "BASH_ENV is not read again after the restart (N7 of #75)" eval '[ $r = 0 ] && [ "$(wc -l <"$W/bashenv.log" | tr -d " ")" = 1 ]'
# PR 75 W2: SHELLOPTS=noexec acts before the guard's first line, so it exits 0 having checked nothing. Started with
# bash -p, bash ignores SHELLOPTS, BASHOPTS and BASH_ENV from the environment, so the guard runs and refuses.
r=$(runenv SHELLOPTS=noexec --findings "$W/rep.md")
check "SHELLOPTS=noexec, plain start -> exit 0 with no ok line: exit 0 alone is not a pass (W2 of #75)" eval '[ $r = 0 ] && ! grep -q "push-guard: ok" "$W/out"'
r=$( (cd "$W/repo" && env SHELLOPTS=noexec bash -p "$PG" 7 --findings "$W/rep.md") >"$W/out" 2>&1; echo $?)
check "SHELLOPTS=noexec, started with bash -p -> the guard runs and refuses src/q.ts (W2 of #75)" eval '[ $r = 1 ] && grep -q "src/q.ts" "$W/out"'
# PR 75 W3: under bash -p an environment BASHOPTS or SHELLOPTS is ignored but still exported, so the guard restarts.
# The restart keeps -p, so an exported function bash -p kept out (here a git that hides every commit's changes) is
# still kept out on the second start, and the refusal stands.
GF='() { case "$*" in *diff-tree*|*merge-tree*) return 0 ;; *) command git "$@" ;; esac; }'
for e in BASHOPTS=nocasematch SHELLOPTS=xtrace; do
  r=$(bnd "$WD" env "BASH_FUNC_git%%=$GF" "$e" bash -p "$PG" 7 --findings "$W/rep.md")
  check "bash -p, $e and an exported git function -> the restart keeps -p, src/q.ts still refused (W3 of #75)" \
    eval '[ $r = 1 ] && grep -q "src/q.ts" "$W/out" && ! grep -q "^push-guard: ok" "$W/out"'
done
# Every caller text starts the guard with bash -p and pushes only on exit 0 with the ok line.
ROOT="$(cd "$T/../.." && pwd)"; docs_ok=0
# PR 75 N9: the reference and the two docs that describe the guard's run say the same.
for f in .agents/skills/pr-fixer/SKILL.md .agents/skills/pr-merge-fixer/SKILL.md .agents/skills/pr-merge-fixer/references/conflicts.md \
  .agents/skills/pr-fixer/references/cycles-and-races.md docs/HOW-IT-WORKS.md docs/REFERENCE.md; do
  grep -qF 'bash -p scripts/push-guard.sh' "$ROOT/$f" && grep -qF '`push-guard: ok.`' "$ROOT/$f" || { docs_ok=1; echo "caller text without bash -p or the ok line: $f" >&2; }
done
check "the callers start the guard with bash -p and require the push-guard: ok. line (W2 of #75)" eq "$docs_ok" 0
check "the restart comment no longer claims every inherited option is covered (W2 of #75)" eval '! grep -q "and any other" "$PG"'
# N1: a touched path with U+2028 in its name is printed quoted in the refusal list.
U28="$(printf '\342\200\250')"
g checkout -q -b feat/u28 "$HEAD_OID"; echo t >"$W/repo/src/a${U28}b.ts"; g add -A; g commit -q -m u28
prjson OPEN feat/u28 "$HEAD_OID" false
r=$(LC_ALL="$UL" run --findings "$W/rep.md")
check "U+2028 in a touched path is escaped in the refusal list" eval '[ $r = 1 ] && ! grep -q "$U28" "$W/out" && grep -qF "\\342\\200\\250" "$W/out"'
g checkout -q feat/m
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID" 'release/v1.2_rc-3'; : >"$FAKE_DIR/calls.log"
tip "$(g rev-parse main)" 'release/v1.2_rc-3'
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "plain base name with / . _ - -> live tip read, ok, no skip line" eval '[ $r = 0 ] && grep -q "api graphql" "$FAKE_DIR/calls.log" && ! grep -q "was not used" "$W/out"'
prjson OPEN feat/m "$HEAD_OID" false "$BASE_OID"
tip 0123456789abcdef0123456789abcdef01234567
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "live base tip not in this clone -> refused, the skip line says fetch" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out" && grep -q "does not hold 0123456789ab; fetch the base first" "$W/out"'
tip "$(g rev-parse main) x"
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "live base tip not a commit id -> refused" eval '[ $r = 1 ] && grep -q "src/y.ts" "$W/out"'
# A commit on the local base that GitHub's base does not hold is the pushing agent's own.
LIVE="$(g rev-parse main)"; g checkout -q main; echo v >"$W/repo/src/v.ts"; g add -A; g commit -q -m "local base only"
g checkout -q feat/m; g merge -q --no-edit main >/dev/null 2>&1; tip "$LIVE"
r=$(run --findings "$W/rep.md" --allow src/q.ts); check "a local base commit the live base lacks -> refused" eval '[ $r = 1 ] && grep -q "src/v.ts" "$W/out"'
g reset -q --hard HEAD~1; g branch -q -f main "$LIVE"; notip

# S4: a merge commit is checked by what it changes beyond the automatic merge of its parents.
g checkout -q -b feat/e "$HEAD_OID"; g checkout -q main; echo w >"$W/repo/src/w.ts"; g add -A; g commit -q -m "main moves again"
g checkout -q feat/e; g merge -q --no-commit --no-ff main >/dev/null 2>&1; echo evil >>"$W/repo/src/b.ts"; g add -A; g commit -q --no-edit
prjson OPEN feat/e "$HEAD_OID" false "$(g rev-parse main)"
r=$(run --findings "$W/rep.md"); check "evil merge: a file changed inside the merge commit -> refused, naming it (S4)" \
  eval '[ $r = 1 ] && grep -q "src/b.ts" "$W/out" && ! grep -q "src/w.ts" "$W/out"'
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "evil merge with that file in scope -> ok (S4)" eq "$r" 0
# The pull request head already edits src/b.ts; the base edits it too; only the conflict merge is new.
g checkout -q -b feat/c "$HEAD_OID"; echo mine >"$W/repo/src/b.ts"; g commit -q -am "branch edits b"; CHEAD="$(g rev-parse HEAD)"
g checkout -q main; echo theirs >"$W/repo/src/b.ts"; g commit -q -am "main edits b"
g checkout -q feat/c; g merge -q --no-edit main >/dev/null 2>&1; echo resolved >"$W/repo/src/b.ts"; g add -A; g commit -q --no-edit
prjson OPEN feat/c "$CHEAD" false "$(g rev-parse main)"
r=$(run --findings "$W/rep.md"); check "conflicted merge: the resolved file is not in scope -> refused (S4)" eval '[ $r = 1 ] && grep -q "src/b.ts" "$W/out"'
r=$(run --findings "$W/rep.md" --allow src/b.ts); check "conflicted merge with the resolved file passed by --allow -> ok (S4)" eq "$r" 0
g checkout -q -b oct1 "$HEAD_OID"; echo o1 >"$W/repo/src/o1.ts"; g add -A; g commit -q -m o1
g checkout -q -b oct2 "$HEAD_OID"; echo o2 >"$W/repo/src/o2.ts"; g add -A; g commit -q -m o2
g checkout -q -b feat/o "$HEAD_OID"; g merge -q --no-ff --no-edit oct1 oct2 >/dev/null 2>&1
prjson OPEN feat/o "$HEAD_OID" false
r=$(run --findings "$W/rep.md" --allow src/o1.ts --allow src/o2.ts); check "octopus merge (three parents) -> refused (S4)" eval '[ $r = 1 ] && grep -q "octopus" "$W/out"'
g checkout -q feat/x

# N5 of #26: with a git that reports 2.37.0, no merge commit can be recomputed, so even the evil merge
# that is otherwise allowed above is refused, naming the version it needs. The wrapper answers only
# `git version` and hands every other call to the real git.
REAL_GIT="$(command -v git)"; mkdir -p "$W/oldgit"
printf '#!/bin/sh\nif [ "$1" = version ] && [ $# -eq 1 ]; then echo "git version 2.37.0"; exit 0; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$W/oldgit/git"
chmod +x "$W/oldgit/git"
g checkout -q feat/e; prjson OPEN feat/e "$HEAD_OID" false "$(g rev-parse main)"
r=$(PATH="$W/oldgit:$PATH" run --findings "$W/rep.md" --allow src/b.ts)
check "git 2.37.0: a merge commit is refused, needs git 2.38 (N5 of #26)" \
  eval '[ $r = 1 ] && grep -q "needs git 2.38 or later" "$W/out"'
w=$(PATH="$W/oldgit:$PATH" git version)
check "git 2.37.0 wrapper is the git push-guard sees (N5 of #26)" eq "$w" "git version 2.37.0"
g checkout -q feat/x

# A rename hides the source path unless renames are turned off.
g checkout -q -b feat/r "$HEAD_OID"; echo s >"$W/repo/src/secret.yml"; g add -A; g commit -q -m "add secret"
RENAME_BASE="$(g rev-parse HEAD)"; mkdir -p "$W/repo/tests"; g mv src/secret.yml tests/secret.yml; g commit -q -m "rename"
prjson OPEN feat/r "$RENAME_BASE" false
r=$(run --findings "$W/rep.md"); check "rename of an out-of-scope file to a test name -> refused" eval '[ $r = 1 ] && grep -q "src/secret.yml" "$W/out"'

# S5: a touched name holding a newline is not split into several scope patterns, and is refused.
g checkout -q -b feat/nl "$HEAD_OID"
NL=$'src/a.ts\n.github/workflows/evil.yml'; mkdir -p "$W/repo/${NL%/*}"; printf 'x\n' >"$W/repo/$NL"; g add -A; g commit -q -m "newline name"
prjson OPEN feat/nl "$HEAD_OID" false
r=$(run --findings "$W/rep.md"); check "touched path with a newline (src/a.ts + evil.yml) -> refused, not read as in scope (S5)" \
  eval '[ $r = 1 ] && grep -q "control character" "$W/out"'
r=$(run --findings "$W/rep.md" --allow $'src/a.ts\nx'); check "--allow with a newline -> refused (S5)" eval '[ $r = 1 ] && grep -q "control character" "$W/out"'
g checkout -q feat/x

# I53: the commits about to be pushed are screened for secrets, by their own added lines.
# The token is built at run time so this file holds none.
TOK="ghp_$(printf 'a%.0s' $(seq 1 36))"
g checkout -q -b feat/s "$HEAD_OID"; mkdir -p "$W/repo/tests"; printf 'const t = "%s";\n' "$TOK" >"$W/repo/tests/s.test.ts"; g add -A; g commit -q -m "test with a token"
prjson OPEN feat/s "$HEAD_OID" false
r=$(run --findings "$W/rep.md"); check "a pushed commit adds a GitHub token in an in-scope test file -> refused, path:line and kind named, value not shown (I53)" \
  eval '[ $r = 1 ] && grep -q "secret:" "$W/out" && grep -q "tests/s.test.ts:1 GitHub token" "$W/out" && ! grep -q "$TOK" "$W/out"'
# PR 75 W3: bash -p keeps exported functions out of the guard but still hands them to its children, so the
# review-cycle.sh it runs starts with -p too. Here an exported python3 skips the screen of a patch and runs the rest.
PF='() { if [ "${X_MODE:-}" = patch ]; then cat >/dev/null; return 0; fi; command python3 "$@"; }'
r=$(bnd "$WD" env "BASH_FUNC_python3%%=$PF" bash -p "$PG" 7 --findings "$W/rep.md")
check "bash -p and an exported python3 that skips the patch screen -> review-cycle.sh starts with -p, still refused, secret (W3 of #75)" \
  eval '[ $r = 1 ] && grep -q "tests/s.test.ts:1 GitHub token" "$W/out" && ! grep -q "^push-guard: ok" "$W/out"'
g rm -q tests/s.test.ts; g commit -q -m "drop the token"
r=$(run --findings "$W/rep.md"); check "a later commit removes it: the commit that added it is still pushed -> refused (I53)" eval '[ $r = 1 ] && grep -q "secret:" "$W/out"'
g checkout -q -b feat/k "$HEAD_OID"; printf -- '-----BEGIN %s PRIVATE KEY-----\n' EC >>"$W/repo/src/a.ts"; g commit -q -am "key"
prjson OPEN feat/k "$HEAD_OID" false
r=$(run --findings "$W/rep.md"); check "a pushed commit adds a private key block to a finding's file -> refused (I53)" eval '[ $r = 1 ] && grep -q "src/a.ts:[0-9]* private key block" "$W/out"'
# A value the base already holds comes in with a merge of the base and is not the fixer's.
g checkout -q -b base-tok main; printf 'k = "%s"\n' "$TOK" >"$W/repo/src/base_tok.py"; g add -A; g commit -q -m "base holds a token"
BTOK="$(g rev-parse HEAD)"; g checkout -q -b feat/bm "$HEAD_OID"; g merge -q --no-edit base-tok >/dev/null 2>&1
prjson OPEN feat/bm "$HEAD_OID" false "$BTOK"
r=$(run --findings "$W/rep.md"); check "a merge of a base that already holds a token -> ok, not the fixer's (I53)" eq "$r" 0
mkdir -p "$W/alone"; cp "$PG" "$W/alone/push-guard.sh"; g checkout -q feat/s
prjson OPEN feat/s "$HEAD_OID" false
r=$( (cd "$W/repo" && "$W/alone/push-guard.sh" 7 --findings "$W/rep.md") >"$W/out" 2>&1; echo $?)
check "review-cycle.sh missing beside push-guard.sh -> 2, the screen cannot run (I53)" eval '[ $r = 2 ] && grep -q "secret screen cannot run" "$W/out"'
g checkout -q feat/x
# W2 (0.12.0 pass 1): a file git treats as binary is still screened as text. Each form on its own:
# a -diff attribute from .git/info/attributes, an untracked .gitattributes, a committed binary
# attribute, and a NUL byte.
bin() { # name file content-format [committed .gitattributes line]
  g checkout -q -B feat/bin "$HEAD_OID"; mkdir -p "$W/repo/tests"
  [ -n "${4:-}" ] && printf '%s\n' "$4" >"$W/repo/.gitattributes" && g add .gitattributes
  printf "$3" "$TOK" >"$W/repo/tests/$2"; g add "tests/$2"; g commit -q -m "binary-looking $2"
  prjson OPEN feat/bin "$HEAD_OID" false
}
bin "info/attributes" k.cfg 'token %s\n'; printf '*.cfg -diff\n' >"$W/repo/.git/info/attributes"
r=$(run --findings "$W/rep.md"); rm -f "$W/repo/.git/info/attributes"
check "a token in a file .git/info/attributes marks -diff -> refused, secret (W2)" eval '[ $r = 1 ] && grep -q "tests/k.cfg:1 GitHub token" "$W/out"'
bin "untracked .gitattributes" k.cfg 'token %s\n'; printf '*.cfg -diff\n' >"$W/repo/.gitattributes"
r=$(run --findings "$W/rep.md"); rm -f "$W/repo/.gitattributes"
check "a token in a file an untracked .gitattributes marks -diff -> refused, secret (W2)" eval '[ $r = 1 ] && grep -q "tests/k.cfg:1 GitHub token" "$W/out"'
bin "committed binary attribute" k.cfg 'token %s\n' '*.cfg binary'
r=$(run --findings "$W/rep.md" --allow .gitattributes)
check "a token in a file a committed .gitattributes marks binary -> refused, secret (W2)" eval '[ $r = 1 ] && grep -q "tests/k.cfg:1 GitHub token" "$W/out"'
bin "NUL byte" blob.dat '\000x\ntoken %s\n'
r=$(run --findings "$W/rep.md")
check "a token in a file holding a NUL byte -> refused, secret (W2)" eval '[ $r = 1 ] && grep -q "tests/blob.dat:2 GitHub token" "$W/out"'
g checkout -q -f feat/x

# I51: sensitive paths are refused even with --allow, and even under a test directory or name.
sens() { # name path class: one commit on top of the head that adds that path, --allow'ed
  g checkout -q -B "feat/sens" "$HEAD_OID"; mkdir -p "$W/repo/$(dirname "$2")"; echo x >"$W/repo/$2"; g add -A; g commit -q -m "touch $2"
  prjson OPEN feat/sens "$HEAD_OID" false
  r=$(run --findings "$W/rep.md" --allow "$2"); sp="$2"; sc="$3"
  check "$1: $2 with --allow -> refused, sensitive-path ($3) (I51)" eval '[ $r = 1 ] && grep -qF "sensitive-path: $sp ($sc)" "$W/out"'
}
sens "workflow" .github/workflows/ci.yml workflows
sens "composite action" .github/actions/setup/action.yml actions
sens "CODEOWNERS at the root" CODEOWNERS codeowners
sens "CODEOWNERS in .github" .github/CODEOWNERS codeowners
sens "CODEOWNERS in docs" docs/CODEOWNERS codeowners
sens "a skill file named like a test" .agents/skills/pr-fixer/tests/x.test.sh skills
sens "agent settings" .claude/settings.json claude
sens "MCP config" .mcp.json mcp
sens "a workflow in other case" .GitHub/Workflows/ci.yml workflows
# W2 of PR #29: the scripts a workflow runs belong to workflows; the files that instruct an agent are
# their own class.
sens "a script release.yml runs" .github/scripts/release.sh workflows
sens "agent instructions at the root" AGENTS.md instructions
sens "agent instructions in a directory" sub/CLAUDE.md instructions
sens "Gemini instructions" GEMINI.md instructions
sens "Copilot instructions" .github/copilot-instructions.md instructions
sens "Copilot path instructions" .github/instructions/go.instructions.md instructions
sens "Codex config" .codex/config.toml instructions
sens "OpenCode agent" .opencode/agents/a.md instructions
sens "Cursor rules" .cursor/rules/r.mdc instructions
sens "agent instructions in other case" Agents.MD instructions
# 0.17.0: CI that does not run on GitHub belongs to workflows too, as path-floor.sh lists it.
sens "GitLab CI" .gitlab-ci.yml workflows
sens "GitLab CI include" .gitlab/ci/build.yml workflows
sens "CircleCI" .circleci/config.yml workflows
sens "a Jenkinsfile in a directory" ci/Jenkinsfile workflows
sens "Azure Pipelines" azure-pipelines.yml workflows
sens "Buildkite" .buildkite/pipeline.yml workflows
sens "Woodpecker" .woodpecker.yaml workflows
sens "Cirrus CI" .cirrus.yml workflows
sens "Semaphore" .semaphore/semaphore.yml workflows
sens "Drone jsonnet" .drone.jsonnet workflows
sens "Codefresh" .codefresh/build.yml workflows
# W7 of PR #29: every project skill folder install.sh writes (and README's .devin/skills) is
# sensitive, whatever harness it is for, and an agent directory counts at any depth.
ROOTS="$(awk '/^paths_for\(\) \{/{f=1;next} f&&/^\}/{f=0} f' "$T/../../install.sh" | sed -n 's/^ *[a-z-]*) *echo "\([^|]*\)|.*/\1/p' | grep -v '^$' | sort -u)"
check "install.sh names at least 11 project skill folders for the rows below (W7 of PR #29)" eval '[ "$(printf "%s\n" "$ROOTS" | grep -c /skills$)" -ge 11 ]'
for sp in $ROOTS .devin/skills; do
  sens "the skill folder install.sh writes" "$sp/s/SKILL.md" "$(case "$sp" in .claude/*) echo claude ;; \
    .github/*|.gemini/*|.cursor/*|.opencode/*|.windsurf/*) echo instructions ;; .qwen|.qwen/*|.factory|.factory/*|.trae|.trae/*|.continue|.continue/*) echo claude ;; *) echo skills ;; esac)"
done
sens "a Roo skill" .roo/skills/pr-fixer/scripts/review-cycle.sh skills
sens "a nested Cursor rule" packages/web/.cursor/rules/evil.mdc instructions
sens "nested agent settings" pkg/.claude/settings.json claude
sens "a nested skill folder" apps/a/.agents/skills/x/SKILL.md skills
sens "a nested Kiro skill" apps/a/.kiro/skills/x/SKILL.md skills
g checkout -q -B feat/sens "$HEAD_OID"; mkdir -p "$W/repo/docs/roo" "$W/repo/src/.agents"
echo x >"$W/repo/docs/roo/skills.md"; echo x >"$W/repo/src/.agents/notes.md"; g add -A; g commit -q -m "near misses"
r=$(run --findings "$W/rep.md" --allow docs/roo/skills.md --allow src/.agents/notes.md)
check "docs/roo/skills.md and src/.agents/notes.md are not skill folders -> ok (W7 of PR #29)" eq "$r" 0
# The opt-in a person sets: it excuses only the classes it names, and the file must still be in scope.
g checkout -q -B feat/sens "$HEAD_OID"; mkdir -p "$W/repo/.agents/skills/s" "$W/repo/.github/workflows"
echo x >"$W/repo/.agents/skills/s/SKILL.md"; g add -A; g commit -q -m "skill edit"
prjson OPEN feat/sens "$HEAD_OID" false
r=$(PUSH_GUARD_ALLOW_SENSITIVE=skills run --findings "$W/rep.md" --allow .agents/skills/s/SKILL.md)
check "PUSH_GUARD_ALLOW_SENSITIVE=skills: a skill file in scope -> ok (I51)" eq "$r" 0
r=$(PUSH_GUARD_ALLOW_SENSITIVE=skills run --findings "$W/rep.md")
check "PUSH_GUARD_ALLOW_SENSITIVE=skills: a skill file not in scope -> refused as out of scope (I51)" \
  eval '[ $r = 1 ] && grep -q "outside the findings" "$W/out" && ! grep -q "sensitive-path" "$W/out"'
echo y >"$W/repo/.github/workflows/ci.yml"; g add -A; g commit -q -m "workflow too"
r=$(PUSH_GUARD_ALLOW_SENSITIVE=skills run --findings "$W/rep.md" --allow .agents/skills/s/SKILL.md --allow .github/workflows/ci.yml)
check "PUSH_GUARD_ALLOW_SENSITIVE=skills does not excuse a workflow -> refused, workflows named (I51)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .github/workflows/ci.yml (workflows)" "$W/out" && ! grep -q "SKILL.md (skills)" "$W/out"'
r=$(PUSH_GUARD_ALLOW_SENSITIVE="skills, workflows" run --findings "$W/rep.md" --allow .agents/skills/s/SKILL.md --allow .github/workflows/ci.yml)
check "PUSH_GUARD_ALLOW_SENSITIVE='skills, workflows' with both in scope -> ok (I51)" eq "$r" 0
r=$(PUSH_GUARD_ALLOW_SENSITIVE=skills,everything run --findings "$W/rep.md" --allow .agents/skills/s/SKILL.md)
check "PUSH_GUARD_ALLOW_SENSITIVE naming an unknown class -> refused, naming it (I51)" eval '[ $r = 1 ] && grep -q "names .everything." "$W/out"'
# N7 of #27: `read` takes only the first line, so a class after a newline was never looked at.
r=$(PUSH_GUARD_ALLOW_SENSITIVE=$'skills,workflows\nbogus' run --findings "$W/rep.md" --allow .agents/skills/s/SKILL.md --allow .github/workflows/ci.yml)
check "PUSH_GUARD_ALLOW_SENSITIVE with a class after a newline -> refused, quoted (N7 of #27)" \
  eval '[ $r = 1 ] && grep -q "may hold only class names" "$W/out" && grep -q "bogus" "$W/out"'
r=$(PUSH_GUARD_ALLOW_SENSITIVE=$'skills,\tworkflows' run --findings "$W/rep.md" --allow .agents/skills/s/SKILL.md --allow .github/workflows/ci.yml)
check "PUSH_GUARD_ALLOW_SENSITIVE with a tab between classes -> ok (N7 of #27)" eq "$r" 0
g checkout -q -B feat/sens "$HEAD_OID"; echo x >"$W/repo/AGENTS.md"; g add -A; g commit -q -m "instructions edit"
r=$(PUSH_GUARD_ALLOW_SENSITIVE=instructions run --findings "$W/rep.md" --allow AGENTS.md)
check "PUSH_GUARD_ALLOW_SENSITIVE=instructions: AGENTS.md in scope -> ok (W2 of PR #29)" eq "$r" 0
r=$(PUSH_GUARD_ALLOW_SENSITIVE=skills,workflows run --findings "$W/rep.md" --allow AGENTS.md)
check "PUSH_GUARD_ALLOW_SENSITIVE=skills,workflows does not excuse AGENTS.md (W2 of PR #29)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: AGENTS.md (instructions)" "$W/out"'
g checkout -q feat/x
# W3 (0.12.0 pass 1): a symlink at a sensitive directory, or at a parent of one, moves the real files
# to a path no class covers. The symlink itself is the sensitive change.
sym() { # name link target: one commit adding evil/settings.json and the symlink link -> target
  g checkout -q -B feat/sym "$HEAD_OID"; mkdir -p "$W/repo/evil" "$W/repo/$(dirname "$2")"
  echo '{}' >"$W/repo/evil/settings.json"; ln -s "$3" "$W/repo/$2"; g add evil/settings.json "$2"; g commit -q -m "symlink $2"
  prjson OPEN feat/sym "$HEAD_OID" false
}
sym "agent settings dir" .claude evil
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow .claude)
check "a symlink .claude -> evil with both --allow'ed -> refused, sensitive-path (W3)" eval '[ $r = 1 ] && grep -q "sensitive-path: .claude (symlink over claude)" "$W/out"'
sym "workflows dir" .github/workflows ../evil
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow .github/workflows)
check "a symlink .github/workflows -> ../evil -> refused, sensitive-path (W3)" eval '[ $r = 1 ] && grep -q "sensitive-path: .github/workflows (symlink over workflows)" "$W/out"'
sym "parent of the skills" .agents evil
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow .agents)
check "a symlink at the parent .agents -> refused, sensitive-path (W3)" eval '[ $r = 1 ] && grep -q "sensitive-path: .agents (symlink over skills)" "$W/out"'
sym "a harness skill root" .roo evil
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow .roo)
check "a symlink .roo -> evil -> refused, skills (W7 of PR #29)" eval '[ $r = 1 ] && grep -q "sensitive-path: .roo (symlink over skills)" "$W/out"'
sym "a nested agent dir" pkg/.claude ../evil
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow pkg/.claude)
check "a symlink pkg/.claude -> ../evil -> refused, claude (W7 of PR #29)" eval '[ $r = 1 ] && grep -q "sensitive-path: pkg/.claude (symlink over claude)" "$W/out"'
sym "parent of three classes, other case" .GitHub evil
r=$(PUSH_GUARD_ALLOW_SENSITIVE=workflows run --findings "$W/rep.md" --allow evil/settings.json --allow .GitHub)
check "a symlink .GitHub with only workflows allowed -> refused, every class it covers named (W3)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .GitHub (symlink over workflows actions codeowners instructions)" "$W/out"'
sym "MCP config" .mcp.json evil/settings.json
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow .mcp.json)
check "a symlink .mcp.json -> evil/settings.json -> refused, sensitive-path (W3)" eval '[ $r = 1 ] && grep -q "sensitive-path: .*\.mcp\.json (symlink over mcp)" "$W/out"'
sym "parent of the skills, class allowed" .agents evil
r=$(PUSH_GUARD_ALLOW_SENSITIVE=skills run --findings "$W/rep.md" --allow evil/settings.json --allow .agents)
check "a symlink .agents with skills allowed and in scope -> ok, the person allowed that class (W3)" eq "$r" 0
sym "an ordinary symlink" src/link evil
r=$(run --findings "$W/rep.md" --allow evil/settings.json --allow src/link)
check "a symlink at a path no class covers -> ok (W3)" eq "$r" 0
g checkout -q -f feat/x
# W7 (0.12.0 pass 2): a link the pull request head already holds. With .claude/skills -> ../skills on
# the base, an edit of skills/x/SKILL.md is an edit of .claude/skills/x/SKILL.md, though no pushed
# commit names a sensitive path. Since W10 the link itself refuses the whole push, whatever is edited.
blink() { # link target edited: the PR head adds skills/x/SKILL.md and link -> target, the fixer edits `edited`
  g checkout -q -f -B feat/blink "$HEAD_OID"; mkdir -p "$W/repo/skills/x" "$W/repo/$(dirname "$1")"
  echo s >"$W/repo/skills/x/SKILL.md"; ln -s "$2" "$W/repo/$1"; g add skills/x/SKILL.md "$1"; g commit -q -m "base link $1"
  prjson OPEN feat/blink "$(g rev-parse HEAD)" false
  echo evil >>"$W/repo/$3"; g add "$3"; g commit -q -m "fixer edits $3"
}
blink .claude/skills ../skills skills/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow skills/x/SKILL.md)
check "a link .claude/skills -> ../skills on the base, the fixer edits its target -> refused, the link named (W7)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over claude)" "$W/out"'
r=$(PUSH_GUARD_ALLOW_SENSITIVE=claude run --findings "$W/rep.md" --allow skills/x/SKILL.md)
check "the same with PUSH_GUARD_ALLOW_SENSITIVE=claude -> ok, the person allowed that class (W7)" eq "$r" 0
blink .claude/skills ../skills src/a.ts
r=$(run --findings "$W/rep.md")
check "a link .claude/skills -> ../skills on the base, the fixer edits a file outside its target -> refused, the link refuses the whole push (W7, W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over claude)" "$W/out"'
blink .Claude/Skills ../SKILLS skills/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow skills/x/SKILL.md)
check "the same link in other case -> refused, sensitive-path (W7)" eval '[ $r = 1 ] && grep -q "sensitive-path: .Claude/Skills (symlink over claude)" "$W/out"'
blink .agents ./skills/x skills/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow skills/x/SKILL.md)
check "a link at the parent .agents -> skills/x on the base, the fixer edits under it -> refused (W7)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .agents (symlink over skills)" "$W/out"'
# A chain: .claude/skills -> ../a and a -> skills. The edit lands at the end of the chain.
g checkout -q -f -B feat/chain "$HEAD_OID"; mkdir -p "$W/repo/skills/x" "$W/repo/.claude"
echo s >"$W/repo/skills/x/SKILL.md"; ln -s ../a "$W/repo/.claude/skills"; ln -s skills "$W/repo/a"
g add skills/x/SKILL.md .claude/skills a; g commit -q -m "base chain"
prjson OPEN feat/chain "$(g rev-parse HEAD)" false
echo evil >>"$W/repo/skills/x/SKILL.md"; g add skills/x/SKILL.md; g commit -q -m "fixer edits through a chain"
r=$(run --findings "$W/rep.md" --allow skills/x/SKILL.md)
check "a chain .claude/skills -> ../a -> skills on the base, the fixer edits the end -> refused (W7)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over claude)" "$W/out"'
# W8 (0.12.0 pass 3): a link inside a sensitive link's target. With .claude/skills -> ../skills and
# skills/y -> ../other/y, .claude/skills/y/SKILL.md is other/y/SKILL.md, a path no class and no
# first-level link target covers. Since W10 the outer link refuses the push. The fixture's own links and files are on the base; the fixer's
# commit edits `edited`, or, with a fourth argument, also retargets a link (LINK:TARGET).
tlink() { # "link:target ..." "file ..." edited [link:newtarget]
  local lt f
  g checkout -q -f -B feat/tlink "$HEAD_OID"
  for f in $2; do mkdir -p "$W/repo/$(dirname "$f")"; echo s >"$W/repo/$f"; g add "$f"; done
  for lt in $1; do mkdir -p "$W/repo/$(dirname "${lt%%:*}")"; ln -s "${lt#*:}" "$W/repo/${lt%%:*}"; g add "${lt%%:*}"; done
  g commit -q -m "base links"; prjson OPEN feat/tlink "$(g rev-parse HEAD)" false
  if [ -n "${4:-}" ]; then rm "$W/repo/${4%%:*}"; ln -s "${4#*:}" "$W/repo/${4%%:*}"; g add "${4%%:*}"; fi
  mkdir -p "$W/repo/$(dirname "$3")"; echo evil >>"$W/repo/$3"; g add "$3"; g commit -q -m "fixer edits $3"
}
tlink ".claude/skills:../skills skills/y:../other/y" "other/y/SKILL.md" other/y/SKILL.md
r=$(run --findings "$W/rep.md" --allow other/y/SKILL.md)
check "a link skills/y -> ../other/y inside the target of .claude/skills -> ../skills, the fixer edits other/y -> refused (W8)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over claude)" "$W/out"'
r=$(PUSH_GUARD_ALLOW_SENSITIVE=claude run --findings "$W/rep.md" --allow other/y/SKILL.md)
check "the same with PUSH_GUARD_ALLOW_SENSITIVE=claude -> ok (W8)" eq "$r" 0
tlink ".claude/skills:../skills skills/y:../other/y other/y/z:../../deep" "deep/SKILL.md" deep/SKILL.md
r=$(run --findings "$W/rep.md" --allow deep/SKILL.md)
check "a link two levels down (other/y/z -> ../../deep) -> refused (W8)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over claude)" "$W/out"'
tlink ".claude/skills:../skills skills/y:/abs/elsewhere" "src/c.ts" src/c.ts
r=$(run --findings "$W/rep.md" --allow src/c.ts)
check "a link inside a sensitive target leading outside the repository -> refused, every class (W8, W10)" \
  eval '[ $r = 1 ] && grep -q "skills/y (symlink over workflows actions codeowners skills claude mcp instructions, its target leaves the repository)" "$W/out"'
tlink "src/link:../skills skills/y:../other/y" "other/y/SKILL.md" other/y/SKILL.md
r=$(run --findings "$W/rep.md" --allow other/y/SKILL.md)
check "the same nested link under an ordinary link -> ok (W8)" eq "$r" 0
tlink ".claude/skills:../skills skills/y:../other/y" "other/y/SKILL.md evil/SKILL.md" evil/SKILL.md skills/y:../evil
r=$(run --findings "$W/rep.md" --allow evil/SKILL.md --allow skills/y)
check "the fixer retargets the nested link skills/y -> ../evil and edits evil -> refused (W8, N15)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over claude)" "$W/out"'
# W9 (0.12.0 pass 3): a target with a non-ASCII letter, refused whatever the locale.
tlink ".claude/skills:../configuração" "configuração/x/SKILL.md" configuração/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow configuração/x/SKILL.md)
check "a link .claude/skills -> ../configuração, the fixer edits under it -> refused (W9)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over workflows actions codeowners skills claude mcp instructions, its target holds a non-ASCII byte)" "$W/out"'
r=$(LC_ALL=C run --findings "$W/rep.md" --allow configuração/x/SKILL.md)
check "the same under LC_ALL=C -> refused (W9)" eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over" "$W/out"'
tlink ".claude/skills:../Configuração" "Configuração/x/SKILL.md" Configuração/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow Configuração/x/SKILL.md)
check "a target with an upper-case ASCII letter and a non-ASCII one -> refused (W9)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude/skills (symlink over" "$W/out"'
blink .claude /abs/elsewhere src/a.ts
r=$(run --findings "$W/rep.md")
check "a link .claude -> an absolute path on the base -> refused, it may lead back into the repository (W7, W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude (symlink over workflows actions codeowners skills claude mcp instructions, its target leaves the repository)" "$W/out"'
blink .claude ../../outside src/a.ts
r=$(run --findings "$W/rep.md")
check "a link .claude -> ../../outside on the base -> refused (W7, W10)" eq "$r" 1
r=$(PUSH_GUARD_ALLOW_SENSITIVE=claude run --findings "$W/rep.md")
check "the same with only claude allowed -> refused, a target outside involves every class (W7, W10)" eq "$r" 1
blink src/link ../skills skills/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow skills/x/SKILL.md)
check "an ordinary link src/link -> ../skills on the base, the fixer edits its target -> ok (W7)" eq "$r" 0
# W10 (0.12.0 pass 4): APFS and NTFS compare names without Unicode case and normalization, so the
# guard folds with Unicode (NFKD, marks dropped, case folded) on both sides, refuses every link that
# sits at, points at, into or above a sensitive path, and refuses any link target with a non-ASCII
# byte or one that leaves the repository. The entries go in through the index, never the disk, so
# the rows hold on any filesystem and whatever core.precomposeunicode says.
iadd() { # mode path content: one index entry, written without the work tree
  local sha; sha="$(printf '%s' "$3" | g hash-object -w --stdin)"; g update-index --add --cacheinfo "$1,$sha,$2"; }
ulink() { # "path=target ..." edited: the PR head holds those links and configuração/x/SKILL.md, the fixer edits `edited`
  local lt
  g checkout -q -f -B feat/ulink "$HEAD_OID"
  iadd 100644 configuração/x/SKILL.md s
  for lt in $1; do iadd 120000 "${lt%%=*}" "${lt#*=}"; done
  g commit -q -m "base links"; g reset -q --hard; prjson OPEN feat/ulink "$(g rev-parse HEAD)" false
  iadd 100644 "$2" evil; g commit -q -m "fixer edits $2"; g reset -q --hard
}
ulink ".claude/skills=../configuraÇÃo" configuração/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow configuração/x/SKILL.md)
check "a link .claude/skills -> ../configuraÇÃo (other non-ASCII case), the fixer edits configuração/x -> refused (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .*\.claude/skills (symlink over" "$W/out"'
ulink ".claude/skills=../configurac$(printf '\314\247')a$(printf '\314\203')o" configuração/x/SKILL.md
r=$(run --findings "$W/rep.md" --allow configuração/x/SKILL.md)
check "a link .claude/skills -> ../configuração spelled in NFD, the fixer edits the NFC path -> refused (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .*\.claude/skills (symlink over" "$W/out"'
ulink "src/link=../configuraÇÃo" src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link whose target holds a non-ASCII byte -> refused, every class (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over workflows actions codeowners skills claude mcp instructions, its target holds a non-ASCII byte)" "$W/out"'
r=$(PUSH_GUARD_ALLOW_SENSITIVE=workflows,actions,codeowners,skills,claude,mcp,instructions run --findings "$W/rep.md")
check "the same with every class allowed -> ok (W10)" eq "$r" 0
ulink "src/link=/etc" src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link to an absolute path -> refused, it leaves the repository (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over workflows actions codeowners skills claude mcp instructions, its target leaves the repository)" "$W/out"'
ulink "src/link=../.Claude" src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link pointing at .Claude -> refused, claude (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over claude, its target .Claude)" "$W/out"'
ulink "src/link=../.agents/skills/x" src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link pointing into .agents/skills -> refused, skills (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over skills, its target .agents/skills/x)" "$W/out"'
ulink "src/link=../AGENTS.md" src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link pointing at AGENTS.md -> refused, instructions (W2 of PR #29)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over instructions, its target AGENTS.md)" "$W/out"'
ulink "src/link=../.github/scripts" src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link pointing at .github/scripts -> refused, workflows (W2 of PR #29)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over workflows, its target .github/scripts)" "$W/out"'
ulink "src/link=.." src/a.ts
r=$(run --findings "$W/rep.md")
check "an ordinary link pointing at the repository root, above every sensitive path -> refused (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over workflows actions codeowners skills claude mcp instructions, its target the repository root)" "$W/out"'
ulink "src/link=../.github" src/a.ts
r=$(PUSH_GUARD_ALLOW_SENSITIVE=workflows,actions run --findings "$W/rep.md")
check "an ordinary link pointing at .github with codeowners not allowed -> refused (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: src/link (symlink over workflows actions codeowners instructions, its target .github)" "$W/out"'
ulink ".agents/ſkills=../x" src/a.ts
r=$(run --findings "$W/rep.md")
check "a link at .agents/ſkills (long s, which folds to s) -> refused, skills (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .agents/ſkills (symlink over skills)" "$W/out"'
# The touched paths fold the same way.
ufile() { # path: the fixer's commit adds that path, through the index
  g checkout -q -f -B feat/ufile "$HEAD_OID"; prjson OPEN feat/ufile "$HEAD_OID" false
  iadd 100644 "$1" x; g commit -q -m "touch $1"; g reset -q --hard
}
ufile ".agents/ſkills/x/SKILL.md"
r=$(run --findings "$W/rep.md" --allow ".agents/ſkills/x/SKILL.md")
check "a touched path .agents/ſkills/x/SKILL.md with --allow -> refused, skills (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .agents/ſkills/x/SKILL.md (skills)" "$W/out"'
ufile ".agents/s$(printf '\342\204\252')ills/x/SKILL.md"
r=$(run --findings "$W/rep.md" --allow ".agents/s$(printf '\342\204\252')ills/x/SKILL.md")
check "a touched path with the Kelvin sign for k (.agents/sKills) -> refused, skills (W10)" \
  eval '[ $r = 1 ] && grep -q "(skills)" "$W/out"'
ufile ".CLAUDE/x"
r=$(run --findings "$W/rep.md" --allow .CLAUDE/x)
check "a touched path .CLAUDE/x (ASCII case, a control) -> refused, claude (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .CLAUDE/x (claude)" "$W/out"'
# A gitlink the PR head already holds at a sensitive path.
g checkout -q -f -B feat/glinkh "$HEAD_OID"; g update-index --add --cacheinfo "160000,$HEAD_OID,.claude"; g commit -q -m "base gitlink"
prjson OPEN feat/glinkh "$(g rev-parse HEAD)" false
echo q >>"$W/repo/src/a.ts"; g add src/a.ts; g commit -q -m "fixer edits src/a.ts"
r=$(run --findings "$W/rep.md")
check "a gitlink .claude the PR head already holds -> refused (W10)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: .claude (gitlink over claude)" "$W/out"'
g checkout -q -f feat/x
# A gitlink (mode 160000) at a sensitive directory moves its files to another repository.
glink() { # path: the fixer's commit adds a gitlink at path
  g checkout -q -f -B feat/glink "$HEAD_OID"; prjson OPEN feat/glink "$HEAD_OID" false
  g update-index --add --cacheinfo "160000,$HEAD_OID,$1"; g commit -q -m "gitlink $1"
}
glink .claude
r=$(run --findings "$W/rep.md" --allow .claude)
check "a gitlink added at .claude, --allow'ed -> refused, sensitive-path (W7)" eval '[ $r = 1 ] && grep -q "sensitive-path: .claude (gitlink over claude)" "$W/out"'
glink .github
r=$(PUSH_GUARD_ALLOW_SENSITIVE=workflows,actions,codeowners,instructions run --findings "$W/rep.md" --allow .github)
check "a gitlink at .github with every class it covers allowed -> ok (W7)" eq "$r" 0
glink src/sub
r=$(run --findings "$W/rep.md" --allow src/sub)
check "a gitlink at a path no class covers -> ok (W7)" eq "$r" 0
g checkout -q -f feat/x

# N19 of #27: a target that steps back with `..` out of another link is not where it reads lexically.
# `x -> a/../skills` reads as skills, but with `a -> .agents/q` it really reaches .agents/skills.
ulink "a=.agents/q x=a/../skills" src/a.ts
r=$(run --findings "$W/rep.md")
check "a link x -> a/../skills where a is a link to .agents/q -> refused, every class (N19 of #27)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: x (symlink over workflows actions codeowners skills claude mcp instructions, its target steps back out of another link)" "$W/out"'
# W1 (0.13.0 pass 1): APFS and NTFS ignore case, so `A/..` steps back out of the link `a` too.
ulink "a=.agents/q x=A/../skills" src/a.ts
r=$(run --findings "$W/rep.md")
check "a link x -> A/../skills where a (other case) is a link to .agents/q -> refused, every class (W1)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: x (symlink over workflows actions codeowners skills claude mcp instructions, its target steps back out of another link)" "$W/out"'
ulink "A=.agents/q x=a/../skills" src/a.ts
r=$(run --findings "$W/rep.md")
check "a link x -> a/../skills where A (other case) is a link to .agents/q -> refused, every class (W1)" \
  eval '[ $r = 1 ] && grep -q "sensitive-path: x (symlink over workflows actions codeowners skills claude mcp instructions, its target steps back out of another link)" "$W/out"'
ulink "a=src x=a/../src/b.ts" src/a.ts
r=$(PUSH_GUARD_ALLOW_SENSITIVE=workflows,actions,codeowners,skills,claude,mcp,instructions run --findings "$W/rep.md")
check "the same shape with every class allowed -> ok, the person decided (N19 of #27)" eq "$r" 0
ulink "a=.agents/q y=a/skills" src/a.ts
r=$(run --findings "$W/rep.md")
check "a link that only descends into another link (y -> a/skills) -> ok, the walk stays lexical (N19 of #27)" eq "$r" 0
# N20 of #27: a link name or target with a control character is the author's text; it is quoted.
g checkout -q -f -B feat/nl "$HEAD_OID"
iadd 120000 $'.claude/a\npush-guard: ok' x
iadd 120000 src/t $'../.claude/b\npush-guard: ok'
g commit -q -m "links with newlines"; g reset -q --hard; prjson OPEN feat/nl "$(g rev-parse HEAD)" false
echo q >>"$W/repo/src/a.ts"; g add src/a.ts; g commit -q -m "fixer edits src/a.ts"
r=$(run --findings "$W/rep.md")
Q1="\$'.claude/a\\npush-guard: ok' (symlink over claude"; Q2="src/t (symlink over claude, its target \$'.claude/b\\npush-guard: ok')"
check "a link name and a link target holding a newline -> refused, both quoted, no forged line (N20 of #27)" \
  eval '[ $r = 1 ] && ! grep -q "^push-guard: ok" "$W/out" && grep -qF "$Q1" "$W/out" && grep -qF "$Q2" "$W/out"'
g checkout -q -f feat/x
# N9 of #27: a commit whose patch git cannot show would drop out of the secret screen unseen.
g checkout -q -f -B feat/gone "$HEAD_OID"; prjson OPEN feat/gone "$HEAD_OID" false
printf 'blob that will vanish\n' >"$W/repo/src/gone.ts"; g add src/gone.ts; g commit -q -m "add gone.ts"
GONE="$(g rev-parse HEAD:src/gone.ts)"; rm -f "$W/repo/.git/objects/${GONE:0:2}/${GONE:2}"
# The work-tree copy goes too: some git builds (seen on Linux with 2.56.1 and 2.39.5, not on macOS 2.56.0) read the
# blob from an unchanged work-tree file (the same content), so the patch would still be complete there and the row could
# not fail for its reason.
rm -f "$W/repo/src/gone.ts"
r=$(run --findings "$W/rep.md" --allow src/gone.ts)
check "a commit whose added blob is missing -> 2 INCONCLUSIVE, not a pass of the secret screen (N9 of #27)" \
  eval '[ $r = 2 ] && grep -q "could not be read for the secret screen" "$W/out"'
g checkout -q -f feat/x 2>/dev/null; g branch -q -D feat/gone 2>/dev/null

# PR 75 debt, pass 2. N2: the locale probe takes any UTF-8 locale when en_US and C UTF-8 are absent.
check "the locale probe falls back to any UTF-8 locale (N2 of #75)" eq "$(printf 'POSIX\nC\nde_DE.UTF-8\n' | pick_ul)" de_DE.UTF-8
# N4: a name that is not valid UTF-8 made sort -u fail on macOS under a UTF-8 locale, so the lists printed no name.
# The names go in through the index: APFS refuses to create them on disk.
g checkout -q -f -B feat/ff "$HEAD_OID"; prjson OPEN feat/ff "$HEAD_OID" false
iadd 100644 "src/x$(printf '\377')y.ts" x; iadd 100644 ".claude/x$(printf '\377')" x; g commit -q -m "invalid UTF-8 names"
r=$(LC_ALL="$UL" run --findings "$W/rep.md")
check "a name that is not valid UTF-8, under a UTF-8 locale -> still listed, out of scope and sensitive (N4 of #75)" \
  eval '[ $r = 1 ] && LC_ALL=C grep -q "files outside the findings. scope: .*src/x" "$W/out" && LC_ALL=C grep -q "sensitive-path: .*\.claude/x" "$W/out"'
g checkout -q -f feat/x 2>/dev/null
# N5: the secret reason prints each path through shown(), so U+2028 in a file name is escaped. A test name keeps the
# file out of the scope list, so the escape is the secret line's own.
g checkout -q -f -B feat/s28 "$HEAD_OID"; mkdir -p "$W/repo/tests"; printf 'const t = "%s";\n' "$TOK" >"$W/repo/tests/a${U28}b.test.ts"; g add -A; g commit -q -m s28
prjson OPEN feat/s28 "$HEAD_OID" false
r=$(LC_ALL="$UL" run --findings "$W/rep.md"); E5="\\342\\200\\250b.test.ts':1 GitHub token"
check "a secret in a file whose name holds U+2028 -> the secret line escapes the name (N5 of #75)" \
  eval '[ $r = 1 ] && grep -q "secret:" "$W/out" && ! grep -q "$U28" "$W/out" && grep -qF "$E5" "$W/out" && ! grep -q "$TOK" "$W/out"'
g checkout -q -f feat/x
# N6: the head branch name is printed through shown() and printf, in the ok line and in the refusals.
B6="feat/b${U28}x"; g checkout -q -f -B "$B6" "$HEAD_OID"; prjson OPEN "$B6" "$HEAD_OID" false
r=$(LC_ALL="$UL" run --findings "$W/rep.md")
check "a head branch name holding U+2028 -> escaped in the ok line (N6 of #75)" \
  eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out" && ! grep -q "$U28" "$W/out" && grep -qF "feat/b\\342\\200\\250x" "$W/out"'
r=$(LC_ALL="$UL" runopt xpg_echo --findings "$W/rep.md")
check "the same with xpg_echo on -> the ok line still escapes it (printf, not echo) (N6 of #75)" \
  eval '[ $r = 0 ] && ! grep -q "$U28" "$W/out" && grep -qF "feat/b\\342\\200\\250x" "$W/out"'
prjson OPEN "feat/b${U28}y" "$HEAD_OID" false
r=$(LC_ALL="$UL" run --findings "$W/rep.md")
check "a head branch name holding U+2028 that is not checked out -> escaped in the refusal (N6 of #75)" \
  eval '[ $r = 1 ] && grep -q "checked-out branch" "$W/out" && ! grep -q "$U28" "$W/out"'
g checkout -q -f feat/x
# N10: after bash -p, the guard restarts without the exported functions (BASH_FUNC_*), so none of its children (git,
# gh, node, python3, sed) receives one. A git shim logs how many it sees; it must have run and seen none.
g checkout -q -f -B feat/fn "$HEAD_OID"; prjson OPEN feat/fn "$HEAD_OID" false
mkdir -p "$W/fnshim"; RG="$(command -v git)"
printf '#!/bin/sh\nenv | grep -c "^BASH_FUNC_" >>"%s/fnshim/log"\nexec "%s" "$@"\n' "$W" "$RG" >"$W/fnshim/git"; chmod +x "$W/fnshim/git"
for e in X_N10=1 BASHOPTS=nocasematch; do
  : >"$W/fnshim/log"
  r=$(bnd "$WD" env PATH="$W/fnshim:$PATH" "BASH_FUNC_probe%%=() { :; }" "$e" bash -p "$PG" 7 --findings "$W/rep.md")
  check "bash -p, $e and an exported function -> no child of the guard receives it, ok (N10 of #75)" \
    eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out" && [ -s "$W/fnshim/log" ] && ! grep -qv "^ *0$" "$W/fnshim/log"'
done
r=$(bnd "$WD" env "FOO=x"$'\n'"BASH_FUNC_y%%=z" bash -p "$PG" 7 --findings "$W/rep.md")
check "a value holding a newline then BASH_FUNC_y%%= -> no restart loop, ok (N10 of #75)" eval '[ $r = 0 ] && grep -q "^push-guard: ok" "$W/out"'
r=$(bnd "$WD" env PUSH_GUARD_RESTARTED=1 "BASH_FUNC_probe%%=() { :; }" bash -p "$PG" 7 --findings "$W/rep.md")
check "restart mark inherited with an exported function -> 2 INCONCLUSIVE (N10 of #75)" eval '[ $r = 2 ] && grep -q "INCONCLUSIVE" "$W/out"'
g checkout -q -f feat/x

for opt in --findings --allow; do
  (cd "$W/repo" && perl -e 'alarm shift; exec @ARGV' 5 "$PG" 7 "$opt") >"$W/out" 2>&1; r=$?
  check "$opt with no value -> refused at once (rc 2), naming it" eval '[ $r = 2 ] && grep -q -- "$opt needs a value" "$W/out"'
done

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
