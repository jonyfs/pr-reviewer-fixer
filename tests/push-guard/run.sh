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
ROOTS="$(sed -n 's/^ *[a-z-]*) *echo "\([^|]*\)|.*/\1/p' "$T/../../install.sh" | sort -u)"
check "install.sh names at least 11 project skill folders for the rows below (W7 of PR #29)" eval '[ "$(printf "%s\n" "$ROOTS" | grep -c /skills$)" -ge 11 ]'
for sp in $ROOTS .devin/skills; do
  sens "the skill folder install.sh writes" "$sp/s/SKILL.md" "$(case "$sp" in .claude/*) echo claude ;; \
    .github/*|.gemini/*|.cursor/*|.opencode/*|.windsurf/*) echo instructions ;; *) echo skills ;; esac)"
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
r=$(run --findings "$W/rep.md" --allow src/gone.ts)
check "a commit whose added blob is missing -> 2 INCONCLUSIVE, not a pass of the secret screen (N9 of #27)" \
  eval '[ $r = 2 ] && grep -q "could not be read for the secret screen" "$W/out"'
g checkout -q -f feat/x 2>/dev/null; g branch -q -D feat/gone 2>/dev/null

for opt in --findings --allow; do
  (cd "$W/repo" && perl -e 'alarm shift; exec @ARGV' 5 "$PG" 7 "$opt") >"$W/out" 2>&1; r=$?
  check "$opt with no value -> refused at once (rc 2), naming it" eval '[ $r = 2 ] && grep -q -- "$opt needs a value" "$W/out"'
done

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
