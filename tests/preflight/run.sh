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
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
