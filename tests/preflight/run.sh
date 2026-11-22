#!/usr/bin/env bash
# preflight (review-cycle.sh) against scratch repositories: a clean commit passes, a commit with a hidden
# comment is refused, and a base that is not fetched is refused. No network and no GitHub access.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$T/../.." && pwd)"
RC="$ROOT/.agents/skills/pr-reviewer/scripts/review-cycle.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }
R="$W/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q -b main
printf 'plain text\n' > "$R/a.md"; g add -A; g commit -q -m base
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b feat
printf 'more plain text\n' >> "$R/a.md"; g commit -qam "clean change"
( cd "$R" && "$RC" preflight main >"$W/clean.out" 2>&1 ); r=$?
check "a clean commit passes preflight (exit 0)" [ "$r" = 0 ]
printf 'x <%s-- hidden --> y\n' '!' > "$R/b.md"; g add -A; g commit -qm "hidden comment"
( cd "$R" && "$RC" preflight main >"$W/hidden.out" 2>&1 ); r=$?
check "a commit with a hidden comment is refused (exit 1)" [ "$r" = 1 ]
check "the refusal names the hidden-text scan" grep -q "hidden-text scan" "$W/hidden.out"
( cd "$R" && "$RC" preflight no-such-base >"$W/nobase.out" 2>&1 ); r=$?
check "a base that is not fetched is refused (exit 1)" [ "$r" = 1 ]
# A secret-screen refusal: a fake token in the shape the screen knows (not a real credential). It starts from a
# clean commit, so the only thing preflight can refuse it for is the token.
g reset -q --hard HEAD~1
printf 'token ghp_%s\n' "$(printf 'A%.0s' $(seq 1 36))" > "$R/c.md"; g add -A; g commit -qm "fake token"
( cd "$R" && "$RC" preflight main >"$W/token.out" 2>&1 ); r=$?
check "a commit with a token-shaped secret is refused (exit 1)" [ "$r" = 1 ]
check "the refusal names the secret screen" grep -q "secret screen" "$W/token.out"
# With the scanner missing, preflight cannot report clean. It runs from a copy of the scripts in this run's own
# folder, so the tracked scan-hidden.py is never moved (another suite reads it at the same time).
g reset -q --hard HEAD~1
printf 'plain again\n' > "$R/d.md"; g add -A; g commit -qm "plain"
mkdir -p "$W/scripts"; cp "$ROOT/.agents/skills/pr-reviewer/scripts/review-cycle.sh" "$W/scripts/"
cp "$ROOT/.agents/skills/pr-reviewer/scripts/gate-pr-review-state.py" "$W/scripts/" 2>/dev/null
( cd "$R" && "$W/scripts/review-cycle.sh" preflight main >"$W/noscan.out" 2>&1 ); r=$?
check "with scan-hidden.py missing, preflight does not report clean (exit 1)" [ "$r" = 1 ]
# A merge that stopped on a conflict: the change adds conflict markers, and preflight refuses it (item 2 of the plan)
g reset -q --hard HEAD~1 2>/dev/null
printf 'before\n<%s<<<<<< HEAD\nours\n=======\ntheirs\n>%s>>>>>>> origin/main\n' '<' '>' > "$R/merge.md"; g add -A; g commit -qm "a conflicted merge"
( cd "$R" && "$RC" preflight main >"$W/conflict.out" 2>&1 ); r=$?
check "a change that adds conflict markers is refused (exit 1)" [ "$r" = 1 ]
check "the refusal names the conflict markers" grep -q "conflict markers" "$W/conflict.out"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
