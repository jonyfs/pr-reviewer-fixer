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
g checkout -q feat/x

for opt in --findings --allow; do
  (cd "$W/repo" && perl -e 'alarm shift; exec @ARGV' 5 "$PG" 7 "$opt") >"$W/out" 2>&1; r=$?
  check "$opt with no value -> refused at once (rc 2), naming it" eval '[ $r = 2 ] && grep -q -- "$opt needs a value" "$W/out"'
done

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
