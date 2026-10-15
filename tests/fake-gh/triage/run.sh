#!/usr/bin/env bash
# Drives triage-pr.sh against a fake gh. Prints a pass/fail table.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$T/../../../.agents/skills/pr-fixer/scripts}"
TR="$SRC/triage-pr.sh"
export PATH="$T/bin:$PATH" FAKE_DIR="$T/state" TRIAGE_NOW=2026-10-14T12:00:00Z TRIAGE_UNKNOWN_WAIT_S=0
export REVIEW_MARKER_AUTHORS=github-actions
unset FIXER_COMMIT_AUTHORS TRIAGE_IGNORE_CHECKS
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
reset() { rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"; : >"$FAKE_DIR/calls.log"; }
# pr <overrides as a python dict literal>: writes pr.json from a clean same-repo PR plus overrides.
pr() { python3 -I - "$FAKE_DIR/${2:-pr.json}" "$1" <<'PY'
import json, sys, ast
base = {"number": 7, "state": "OPEN", "isDraft": False, "headRefOid": "a" * 40, "headRefName": "feat/x",
        "baseRefOid": "b" * 40, "baseRefName": "main", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
        "isCrossRepository": False, "maintainerCanModify": False, "labels": [{"name": "review:passed"}],
        "comments": [], "statusCheckRollup": [
            {"__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS",
             "detailsUrl": "https://github.com/o/r/actions/runs/11/job/1"}],
        "commits": [{"oid": "a" * 40, "committedDate": "2026-10-14T09:00:00Z",
                     "authors": [{"login": "alice", "name": "Alice", "email": "alice@example.com"}]}]}
base.update(ast.literal_eval(sys.argv[2]))
json.dump(base, open(sys.argv[1], "w"))
PY
}
# expect <name> <jq boolean expression over the output> [expected exit code]
expect() {
  local name="$1" q="$2" want_rc="${3:-0}" out rc
  out=$("$TR" 7 2>"$FAKE_DIR/err"); rc=$?
  if [ "$rc" != "$want_rc" ]; then row "$name" bad "exit $rc, want $want_rc: $(head -c 200 "$FAKE_DIR/err")"; return; fi
  if [ "$want_rc" != 0 ]; then row "$name" ok; return; fi
  if printf '%s' "$out" | jq -e "$q" >/dev/null 2>&1; then row "$name" ok; else row "$name" bad "got $out"; fi
}
CHK_FAIL='{"__typename": "CheckRun", "name": "lint", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://github.com/o/r/actions/runs/4242/job/9"}'
GATE_FAIL='{"__typename": "CheckRun", "name": "review-gate", "workflowName": "pr-review", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://github.com/o/r/actions/runs/5/job/1"}'
STATUS_ERR='{"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR", "targetUrl": "https://ci.example.com/b/3"}'
HALT='{"author": {"login": "github-actions"}, "body": "<!-- pr-skill-extension: state=halted reason=no-answer-in-300s -->\nhalted"}'
FIXC='{"oid": "cccccccccccccccccccccccccccccccccccccccc", "committedDate": "2026-10-14T11:55:00Z", "authors": [{"login": "", "name": "github-actions[bot]", "email": "41898282+github-actions[bot]@users.noreply.github.com"}]}'

reset; pr '{}'
expect "clean PR: no lanes, no skip" '.lane_suggestions == [] and .skip_reason == null and .conflicts == false and .headWritable == true and .failing_checks == []'

reset; pr '{"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"}'
expect "conflicting PR: lane conflict" '.conflicts == true and .lane_suggestions == ["conflict"] and .skip_reason == null'

reset; pr "{\"statusCheckRollup\": [$CHK_FAIL, $GATE_FAIL, $STATUS_ERR]}"
expect "failing checks: lane check, run_id parsed, review-gate ignored, status context kept" '.lane_suggestions == ["check"] and (.failing_checks | length) == 2 and .failing_checks[0] == {"name":"lint","workflow":"CI","conclusion":"FAILURE","run_id":4242,"url":"https://github.com/o/r/actions/runs/4242/job/9"} and .failing_checks[1].name == "ci/legacy"'

reset; pr "{\"mergeable\": \"CONFLICTING\", \"statusCheckRollup\": [$CHK_FAIL]}"
expect "conflict and failing check: conflict first" '.lane_suggestions == ["conflict", "check"]'

reset; pr '{"isDraft": True, "mergeable": "CONFLICTING"}'
expect "draft: skip draft" '.skip_reason == "draft" and .draft == true'

reset; pr '{"state": "CLOSED"}'
expect "closed: skip closed" '.skip_reason == "closed"'

reset; pr '{"isCrossRepository": True, "maintainerCanModify": False, "mergeable": "CONFLICTING"}'
expect "fork without maintainer edit: skip, headWritable false" '.skip_reason == "fork-without-edit" and .headWritable == false'

reset; pr '{"isCrossRepository": True, "maintainerCanModify": True}'
expect "fork with maintainer edit: writable, isCrossRepository true" '.skip_reason == null and .headWritable == true and .isCrossRepository == true'

reset; pr "{\"labels\": [{\"name\": \"review:needs-human\"}], \"mergeable\": \"CONFLICTING\"}"
expect "review:needs-human label: skip extension-halted" '.skip_reason == "extension-halted"'

reset; pr "{\"comments\": [$HALT], \"mergeable\": \"CONFLICTING\"}"
expect "halted marker without the label (a person fixed it): no skip" '.skip_reason == null'

reset; pr "{\"comments\": [{\"author\": {\"login\": \"mallory\"}, \"body\": \"<!-- pr-skill-extension: state=halted reason=stop -->\"}]}"
expect "halted marker from untrusted login: ignored" '.skip_reason == null'

reset; pr "{\"comments\": [{\"author\": {\"login\": \"github-actions\"}, \"body\": \"report quoting <!-- pr-skill-extension: state=halted reason=stop -->\"}]}"
expect "marker quoted inside a trusted comment: ignored" '.skip_reason == null'

reset; pr "{\"comments\": [$HALT, {\"author\": {\"login\": \"github-actions\"}, \"body\": \"<!-- pr-skill-extension: state=granted n=2 -->\"}]}"
expect "granted after halted: newest wins, no skip" '.skip_reason == null'


reset; pr '{"labels": [{"name": "review:fixing"}]}'; printf 'review:fixing\t2026-10-14T11:50:00Z\n' >"$FAKE_DIR/events.tsv"
expect "live review:fixing label (10 min old): skip live-label" '.skip_reason == "live-label" and .live_label == "review:fixing"'

reset; pr '{"labels": [{"name": "review:running"}]}'; printf 'review:running\t2026-10-14T11:59:00Z\n' >"$FAKE_DIR/events.tsv"
expect "live review:running label: skip live-label" '.skip_reason == "live-label" and .live_label == "review:running"'

reset; pr '{"labels": [{"name": "review:fixing"}]}'; printf 'review:fixing\t2026-10-14T09:00:00Z\n' >"$FAKE_DIR/events.tsv"
expect "stale review:fixing label (3 h old): not live" '.skip_reason == null'

reset; pr '{"labels": [{"name": "review:fixing"}]}'; touch "$FAKE_DIR/events-fail"
expect "label events unreadable: counts as live" '.skip_reason == "live-label"'

reset; pr "{\"commits\": [$FIXC], \"mergeable\": \"CONFLICTING\"}"
expect "fixer commit 5 min ago, no FIXER_COMMIT_AUTHORS: no skip" '.skip_reason == null'
export FIXER_COMMIT_AUTHORS="github-actions[bot]"
expect "fixer commit 5 min ago, author configured: skip recent-fixer-commit" '.skip_reason == "recent-fixer-commit"'

reset; pr "{\"commits\": [${FIXC/11:55:00Z/11:40:00Z}]}"
expect "fixer commit 20 min ago: no skip" '.skip_reason == null'
unset FIXER_COMMIT_AUTHORS

reset; pr '{"commits": [{"oid": "dddddddddddddddddddddddddddddddddddddddd", "committedDate": "2026-10-14T11:59:00Z", "authors": [{"login": "alice", "name": "Alice", "email": "a@x"}]}]}'
expect "human commit 1 min ago: no skip" '.skip_reason == null'

reset; pr '{"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"}' pr.1.json; pr '{"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"}'
expect "UNKNOWN mergeable is re-read: conflict found on the second read" '.conflicts == true and .mergeable == "CONFLICTING"'
check_reads=$(grep -c '^gh pr view' "$FAKE_DIR/calls.log"); [ "$check_reads" = 2 ] && row "UNKNOWN re-read made exactly 2 reads" ok || row "UNKNOWN re-read made exactly 2 reads" bad "reads=$check_reads"

reset; pr '{"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"}'
expect "UNKNOWN that stays UNKNOWN: reported, conflicts false" '.mergeable == "UNKNOWN" and .conflicts == false and .lane_suggestions == []'
reads=$(grep -c '^gh pr view' "$FAKE_DIR/calls.log"); [ "$reads" = 4 ] && row "UNKNOWN re-read stops after 3 retries" ok || row "UNKNOWN re-read stops after 3 retries" bad "reads=$reads"

reset; pr '{}'; touch "$FAKE_DIR/offline"
expect "gh offline: exit 2" '' 2

reset; pr '{}'
out=$(PATH="/usr/bin:/bin" "$TR" 7 2>&1); rc=$?
[ "$rc" = 2 ] && row "gh missing: exit 2" ok || row "gh missing: exit 2" bad "exit $rc"
out=$("$TR" abc 2>&1); rc=$?
[ "$rc" = 2 ] && row "non-numeric argument: exit 2" ok || row "non-numeric argument: exit 2" bad "exit $rc"

reset; pr '{}'
"$TR" 7 >/dev/null 2>&1
grep -qE '^gh (pr (edit|comment|merge)|api -X|api .*-f)' "$FAKE_DIR/calls.log" && row "read-only: no write call to gh" bad "$(cat "$FAKE_DIR/calls.log")" || row "read-only: no write call to gh" ok

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
