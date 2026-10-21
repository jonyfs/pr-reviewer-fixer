#!/usr/bin/env bash
# Drives push-guard.sh against a throwaway git repository and the triage fake gh. Prints a table.
set -u
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
prjson() { # state head_ref head_oid cross [base_oid]
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s","baseRefName":"main","baseRefOid":"%s","isCrossRepository":%s}' "$1" "$2" "$3" "${5:-$BASE_OID}" "$4" >"$FAKE_DIR/pr.json"; }
run() { (cd "$W/repo" && "$PG" 7 "$@") >"$W/out" 2>&1; echo $?; }

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

for opt in --findings --allow; do
  (cd "$W/repo" && perl -e 'alarm shift; exec @ARGV' 5 "$PG" 7 "$opt") >"$W/out" 2>&1; r=$?
  check "$opt with no value -> refused at once (rc 2), naming it" eval '[ $r = 2 ] && grep -q -- "$opt needs a value" "$W/out"'
done

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
