#!/usr/bin/env bash
# The --only filter of tests/run-all.sh (PR 60, W2): a filter that matches no suite exits 1, an empty word exits 2.
# Both refusals come before any suite starts. The rows after them (PR 87 N3) run a copy of the tree whose only
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
G="$X/t/.agents/skills/pr-fixer/scripts/review-cycle.sh"; cp -p "$G" "$X/rc.bak"; printf '#\n' >>"$G"; only
check "--only push-guard, one byte added to the fixer's review-cycle.sh -> exit 1, DIFFERS named (PR 87 N3)" \
  eval '[ $r = 1 ] && has "^== scripts/review-cycle.sh DIFFERS between the skills$"'
cp -p "$X/rc.bak" "$G"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
