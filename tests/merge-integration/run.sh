#!/usr/bin/env bash
# The deterministic part of the merge fixer's path (plan item 10), end to end in a scratch repository: the base and the
# branch change the same line, the merge stops on a conflict, a commit of the unresolved merge is refused by preflight,
# the resolved merge is accepted. No network, no GitHub, no model.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$T/../.." && pwd)"
RC="$ROOT/.agents/skills/pr-reviewer/scripts/review-cycle.sh"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }
R="$W/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q -b main
printf 'title\nshared line\n' > "$R/doc.md"; g add -A; g commit -qm base
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b feat
printf 'title\nbranch wording\n' > "$R/doc.md"; g commit -qam "branch edits the line"
g checkout -q main
printf 'title\nbase wording\n' > "$R/doc.md"; g commit -qam "base edits the same line"
g update-ref refs/remotes/origin/main HEAD
g checkout -q feat
if g merge --no-edit origin/main >/dev/null 2>&1; then merged=1; else merged=0; fi
check "the merge of the base into the branch stops on a conflict" [ "$merged" = 0 ]
check "the conflicted file holds conflict markers" grep -q '^<<<<<<< ' "$R/doc.md"
g add doc.md; g commit -qm "unresolved merge" 2>/dev/null
( cd "$R" && "$RC" preflight main >"$W/unresolved.out" 2>&1 ); r=$?
check "preflight refuses a commit of the unresolved merge (exit 1)" [ "$r" = 1 ]
check "the refusal names the conflict markers" grep -q "conflict markers" "$W/unresolved.out"
printf 'title\nresolved wording\n' > "$R/doc.md"; g add doc.md; g commit -qm "merge: resolve the line" 2>/dev/null
( cd "$R" && "$RC" preflight main >"$W/resolved.out" 2>&1 ); r=$?
check "preflight accepts the resolved merge (exit 0)" [ "$r" = 0 ]
check "the resolved file holds no marker" eval '! grep -q "^<<<<<<< \|^>>>>>>> " "$R/doc.md"'
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
