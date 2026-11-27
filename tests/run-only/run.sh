#!/usr/bin/env bash
# The --only filter of tests/run-all.sh (PR 60, W2): a filter that matches no suite exits 1, an empty word exits 2.
# Both refusals come before any suite starts. The rows after them (PR 87 N3, N4) run a copy of the tree whose only
# suite --only starts is a stub, so this suite never starts a real suite, itself included (no recursion).
set -u
# A nested call from this suite: run-all refuses to start any suite when RUN_ALL_NESTED is set, so even a
# broken refusal cannot start this suite again.
export RUN_ALL_NESTED=1
T="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$T/../.." && pwd)"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }
bash "$ROOT/tests/run-all.sh" --only zzz-no-such-suite >/dev/null 2>&1; r=$?
check "a filter that matches no suite exits 1 and runs nothing" [ "$r" = 1 ]
bash "$ROOT/tests/run-all.sh" --only ",x" >/dev/null 2>&1; r=$?
check "an empty word in the filter is refused (exit 2)" [ "$r" = 2 ]

# PR 87 N3: .github/workflows/suite-check.yml runs `run-all.sh --only push-guard` and relies on the checks run-all
# makes after its suites (the shared-script cmp, the model-key scan) running under --only too. The rows run the work
# tree's run-all.sh in a copy of the work tree (git's file list, ignored files left out) whose push-guard suite is a
# stub. The copy lives outside tests/, which the model-key scan reads. RUN_ALL_NESTED is lifted for that one call
# only: the stub is the one suite that --only push-guard starts there.
X="$(mktemp -d "${TMPDIR:-/tmp}/run-only-test.XXXXXX")" || { echo "run-only suite: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$X"' EXIT
mkdir -p "$X/t"
( cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue; mkdir -p "$X/t/$(dirname "$f")" && cp -p "$f" "$X/t/$f"; done )
git -C "$X/t" init -q
printf '#!/usr/bin/env bash\necho "push-guard stub: TOTAL: 1 passed, 0 failed"\n' >"$X/t/tests/push-guard/run.sh"
only() { r=0; env -u RUN_ALL_NESTED TEST_TAG="${TEST_TAG:-main}-onlycopy" bash "$X/t/tests/run-all.sh" --only push-guard \
  </dev/null >"$X/out" 2>&1 || r=$?; }
has() { grep -qE -- "$1" "$X/out"; }
only
check "--only push-guard, on a clean copy: exit 0, and only the stub suite ran" \
  eval '[ $r = 0 ] && has "^push-guard stub: TOTAL" && [ "$(grep -c "^== .*[0-9]s)$" "$X/out")" = 1 ]'
check "--only push-guard still runs the shared-script cmp checks (PR 87 N3)" \
  eval 'has "^== [0-9]+ shared scripts checked$" && has "^== references/pr-protocol.md identical in pr-merge-fixer$"'
check "--only push-guard still runs the model-key scan (PR 87 N3)" has "^== no model action or provider key in [0-9]+ files"
check "--only push-guard runs the suite-check.yml check, and the real workflow passes it (PR 87 N4)" \
  has "^== suite-check.yml: pull_request only"
check "the real workflow matches the sha256 pinned in run-all.sh (PR 87 W2)" \
  has "^== suite-check.yml matches the sha256 pinned in tests/run-all.sh$"
G="$X/t/.agents/skills/pr-fixer/scripts/review-cycle.sh"; cp -p "$G" "$X/rc.bak"; printf '#\n' >>"$G"; only
check "--only push-guard, one byte added to the fixer's review-cycle.sh -> exit 1, DIFFERS named (PR 87 N3)" \
  eval '[ $r = 1 ] && has "^== scripts/review-cycle.sh DIFFERS between the skills$"'
cp -p "$X/rc.bak" "$G"

# PR 87 N4: suite-check.yml runs the pull request's own code, so run-all holds its trigger, its token scope and the
# checkout's credential setting. Each mutant is written over the copy's workflow, run, then the original put back.
WF="$X/t/.github/workflows/suite-check.yml"; cp -p "$WF" "$X/wf.bak"
mutant() {
  local name="$1"; shift; "$@" <"$X/wf.bak" >"$WF"; only
  check "suite-check.yml mutant, $name -> exit 1 (${mt:-PR 87 N4})" \
    eval '[ $r = 1 ] && has "^== suite-check.yml is not pull_request only" && ! cmp -s "$WF" "$X/wf.bak" \
      && { [ -z "${ml:-}" ] || grep -qF -- "$ml" "$WF"; }'
  cp -p "$X/wf.bak" "$WF"
}
mutant "pull_request_target added as a second trigger" awk '{print} /^  pull_request:$/{print "  pull_request_target:"}'
mutant "workflow_run added as a second trigger" awk '{print} /^  pull_request:$/{print "  workflow_run:"}'
mutant "contents: write" sed 's/^  contents: read$/  contents: write/'
mutant "a second permission (pull-requests: write)" awk '{print} /^  contents: read$/{print "  pull-requests: write"}'
mutant "a job-level permissions block" awk '{print} /^    runs-on:/{print "    permissions: write-all"}'
mutant "persist-credentials: true" sed 's/persist-credentials: false/persist-credentials: true/'
mutant "persist-credentials removed (the default keeps the token)" grep -v 'persist-credentials'
mutant "a second checkout without persist-credentials" awk '{print} /^    steps:$/{print "      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262"}'
# PR 87 W1: forms the line counts of the N4 check let through: a quoted or spaced job-level permissions key, the
# checkout's persist-credentials line moved under another step or under the checkout's env, and a second checkout
# written quoted, in another case, with a quoted key or as a flow mapping.
mt="PR 87 W1"
mutant "a job-level \"permissions\": write-all (quoted key)" \
  awk '{print} /^    runs-on:/{print "    \"permissions\": write-all"}'
mutant "a job-level 'permissions': {contents: write} (quoted key)" \
  awk '{print} /^    runs-on:/{print "    \047permissions\047: {contents: write}"}'
mutant "a job-level permissions : write-all (space before the colon)" \
  awk '{print} /^    runs-on:/{print "    permissions : write-all"}'
mutant "persist-credentials: false moved under a later step that is not a checkout" \
  awk '/^        with:$/||/persist-credentials/{next} {print} END{print "      - uses: some/other@0000000000000000000000000000000000000000"; print "        with:"; print "          persist-credentials: false"}'
mutant "persist-credentials: false under the checkout's env, not its with" sed 's/^        with:$/        env:/'
mutant "a second checkout, uses quoted, without persist-credentials" \
  awk '{print} /^    steps:$/{print "      - uses: \"actions/checkout@11d5960a326750d5838078e36cf38b85af677262\""}'
mutant "a second checkout written Actions/Checkout, without persist-credentials" \
  awk '{print} /^    steps:$/{print "      - uses: Actions/Checkout@11d5960a326750d5838078e36cf38b85af677262"}'
mutant "a second checkout with a quoted uses key, without persist-credentials" \
  awk '{print} /^    steps:$/{print "      - \"uses\": actions/checkout@11d5960a326750d5838078e36cf38b85af677262"}'
mutant "a second checkout as a flow mapping, without persist-credentials" \
  awk '{print} /^    steps:$/{print "      - {uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262}"}'
# PR 87 W2: YAML decodes escapes in a double-quoted value, so the raw text the parser reads can differ from the
# value a loader sees; and a single-quoted value left open runs on over the lines below it. Each form adds a checkout
# that keeps its token. The escaped lines are appended with printf, never through awk or echo, which would decode the
# backslash themselves; each row also checks that the literal escape reached the mutant file ($ml).
mt="PR 87 W2"
append() { cat; printf '%s\n' "$1"; }
CO_SHA=11d5960a326750d5838078e36cf38b85af677262
ml='\x65' mutant "a second checkout written \"actions/ch\\x65ckout@...\", without persist-credentials" \
  append '      - uses: "actions/ch\x65ckout@'"$CO_SHA"'"'
ml='\u0065' mutant "a second checkout written \"actions/ch\\u0065ckout@...\", without persist-credentials" \
  append '      - uses: "actions/ch\u0065ckout@'"$CO_SHA"'"'
ml='\U00000065' mutant "a second checkout written \"actions/ch\\U00000065ckout@...\", without persist-credentials" \
  append '      - uses: "actions/ch\U00000065ckout@'"$CO_SHA"'"'
ml='\x2f' mutant "a second checkout written \"actions\\x2fcheckout@...\", without persist-credentials" \
  append '      - uses: "actions\x2fcheckout@'"$CO_SHA"'"'
ml="name: 'x" mutant "a single-quoted name opened after the checkout's uses and closed after persist-credentials" \
  awk '{print} /^      - uses: actions\/checkout@/{print "        name: \047x"} /persist-credentials/{print "        y: z\047"}'
mt=""
# The workflow is pinned by its sha256 in run-all.sh (PR 87 W2), so any edit to it fails the suite until the pin is
# updated in the same pull request. The rows below are edits the parser accepts: each must exit 1 on the pin alone,
# with the parser's success line still printed. That a harmless edit fails is intended.
pinned() {
  check "$1 -> exit 1 on the pin alone, the parser still accepts it (PR 87 W2, intended)" \
    eval '[ $r = 1 ] && has "^== suite-check.yml DIFFERS from the sha256 pinned in tests/run-all.sh" \
      && has "^== suite-check.yml: pull_request only" && ! cmp -s "$WF" "$X/wf.bak"'
  cp -p "$X/wf.bak" "$WF"
}
# A checkout step written name, then uses, then with is the same step: the parser accepts it.
awk '/^      - uses: actions\/checkout@/{print "      - name: checkout"; sub(/- uses:/, "  uses:")} {print}' <"$X/wf.bak" >"$WF"; only
pinned "a checkout step written name, uses, with: persist-credentials: false (PR 87 W1)"
awk 'NR==1{print "# pull_request_target, workflow_run and persist-credentials: true are never used here"} {print}' \
  <"$X/wf.bak" >"$WF"; only
pinned "a comment naming pull_request_target, which the parser does not read (PR 87 N4)"
awk '{print} /^name: suite-check$/{print ""}' <"$X/wf.bak" >"$WF"; only
pinned "a whitespace-only edit (an empty line after name:)"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
