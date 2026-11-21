#!/usr/bin/env bash
# Drives remote-review.sh offline against a bare repository on disk. Prints pass/fail and exits non-zero on failure.
set -u
T="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$T/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/remote-review-test.XXXXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1"); fi; }
check() { local n="$1"; shift; if "$@"; then row "$n" ok; else row "$n" bad; fi; }
g() { git -c user.email=t@t -c user.name=t "$@"; }

# A remote "GitHub" repository: main, and a feature branch with one commit.
g init -q -b main "$W/src" && (cd "$W/src" && echo a > a.txt && g add . && g commit -qm base && \
  g checkout -q -b feature && echo b > b.txt && g add . && g commit -qm "feature change")
g clone -q --bare "$W/src" "$W/origin.git" 2>/dev/null
REMOTE="$W/origin.git"
FEAT_BEFORE="$(git -C "$REMOTE" rev-parse feature)"
CACHE="$W/cache"; S="$ROOT/remote-review.sh"

out="$(bash "$S" acme/app feature --url "$REMOTE" --cache "$CACHE" --base main --test "test -f b.txt" 2>&1)"; rc=$?
check "prepares the branch in a worktree -> exit 0" eval '[ "$rc" = 0 ]'
check "the summary names the review branch and the test result" eval 'printf %s "$out" | grep -q "review/feature" && printf %s "$out" | grep -q "tests: exit 0"'
check "the worktree holds the branch's file" eval '[ -f "$CACHE/acme/app/worktrees/feature/b.txt" ]'
check "the worktree is on review/feature, not on feature" eval '[ "$(git -C "$CACHE/acme/app/worktrees/feature" branch --show-current)" = review/feature ]'
check "nothing was pushed: origin feature unchanged" eval '[ "$(git -C "$REMOTE" rev-parse feature)" = "$FEAT_BEFORE" ]'

echo "x" > "$CACHE/acme/app/worktrees/feature/fix.txt"
(cd "$CACHE/acme/app/worktrees/feature" && g add fix.txt && g commit -qm "fix: review finding")
out="$(bash "$S" acme/app feature --url "$REMOTE" --cache "$CACHE" --base main --push 2>&1)"; rc=$?
check "--push publishes review/feature only" eval '[ "$rc" = 0 ] && git -C "$REMOTE" rev-parse --verify -q review/feature >/dev/null'
check "the author's feature branch still has the old commit" eval '[ "$(git -C "$REMOTE" rev-parse feature)" = "$FEAT_BEFORE" ]'

out="$(bash "$S" acme/app missing --url "$REMOTE" --cache "$CACHE" --base main 2>&1)"; rc=$?
check "a branch that does not exist -> refused" eval '[ "$rc" = 1 ] && printf %s "$out" | grep -q "not found"'
out="$(bash "$S" acme/app review/feature --url "$REMOTE" --cache "$CACHE" 2>&1)"; rc=$?
check "a review branch as input -> refused" eval '[ "$rc" = 1 ] && printf %s "$out" | grep -q "already a review branch"'
out="$(bash "$S" acme/app feature --url "$REMOTE" --cache "$CACHE" --open-pr 2>&1)"; rc=$?
check "--open-pr without --push -> refused" eval '[ "$rc" = 1 ]'
out="$(bash "$S" notarepo feature --url "$REMOTE" --cache "$CACHE" 2>&1)"; rc=$?
check "a repository name without an owner -> refused" eval '[ "$rc" = 1 ]'

# Regressions for the pass 1 and pass 2 findings (C1, W1, W2, W7).
# C1: a planted json.py on the reviewed branch must not be imported from the worktree.
g -C "$W/src" checkout -q -b planted main && echo 'open("pwned.flag","w").write("x")' > "$W/src/json.py" && (cd "$W/src" && g add json.py && g commit -qm plant) && g -C "$W/src" push -q "$REMOTE" planted 2>/dev/null || g clone -q "$W/src" "$W/planted.git" 2>/dev/null
bash "$S" acme/app planted --url "$REMOTE" --cache "$CACHE" --base main >/dev/null 2>&1
check "C1: a planted json.py in the reviewed branch is not imported" eval '[ ! -e "$CACHE/acme/app/worktrees/planted/pwned.flag" ]'
# W2: a branch name with a slash works, its log is named after it.
g -C "$W/src" checkout -q -b feat/slash main && echo s > "$W/src/s.txt" && (cd "$W/src" && g add s.txt && g commit -qm slash) && g -C "$W/src" push -q "$REMOTE" feat/slash 2>/dev/null
out="$(bash "$S" acme/app feat/slash --url "$REMOTE" --cache "$CACHE" --base main --test "true" 2>&1)"; rc=$?
check "W2: a branch with a slash prepares and logs its test" eval '[ "$rc" = 0 ] && printf %s "$out" | grep -q "tests: exit 0" && [ -f "$CACHE/acme/app/logs/feat_slash.test.log" ]'
# W7: the author pushes after a fix exists; a second run must refuse to reuse the old review branch.
bash "$S" acme/app feature --url "$REMOTE" --cache "$CACHE" --base main >/dev/null 2>&1
echo "fix" > "$CACHE/acme/app/worktrees/feature/fix2.txt" && (cd "$CACHE/acme/app/worktrees/feature" && g add fix2.txt && g commit -qm fix2)
(cd "$W/src" && g checkout -q feature && echo newer > newer.txt && g add newer.txt && g commit -qm "author moved on" && g push -q -f "$REMOTE" feature 2>/dev/null)
out="$(bash "$S" acme/app feature --url "$REMOTE" --cache "$CACHE" --base main 2>&1)"; rc=$?
check "W7: the author pushed after fixes -> refused, names --reset" eval '[ "$rc" = 1 ] && printf %s "$out" | grep -q "moved after"'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
