#!/usr/bin/env bash
#
# triage-pr.sh: read-only triage of one pull request for pr-fixer runs with no named PR.
#
# Usage: triage-pr.sh <pr-number>
#
# It never writes anything: no label, no comment, no push. It answers one question for the review
# loop agent and for a person: is there conflict or failing-check work on this pull request, and is
# it safe to start it now? A draft that nobody named is skipped; the review loop names its own pull
# requests, so it is not affected by that skip.
#
# OUTPUT. One JSON object on stdout:
#
#   number, head, base            PR number, head commit SHA, base commit SHA
#   headRef, baseRef, state       branch names and OPEN | CLOSED | MERGED
#   draft, isCrossRepository      booleans
#   mergeable, mergeStateStatus   as GitHub reports them; UNKNOWN is re-read (see below)
#   conflicts                     true when mergeable is CONFLICTING or mergeStateStatus is DIRTY
#   headWritable                  true for a same-repository branch, or a fork with maintainer edits
#   failing_checks                [{name, workflow, conclusion, run_id, url}]
#   lane_suggestions              subset of ["conflict", "check"], conflict first
#   skip_reason                   null when it may act, otherwise one of:
#                                   closed, draft, fork-without-edit, extension-halted,
#                                   live-label, recent-fixer-commit
#   live_label                    the review:running or review:fixing label behind live-label
#
# EXIT CODES. 0 whenever it printed an answer, including every skip. 2 when gh or node is missing,
# the argument is not a PR number, or gh cannot read the pull request (offline, no access, no such
# PR). Exit 2 never means "nothing to do"; it means nobody looked.
#
# WHY `mergeable` IS RE-READ. GitHub computes mergeability lazily. Right after the base branch
# moves it answers UNKNOWN, and no event fires when the background job finishes. So an UNKNOWN is
# read again after TRIAGE_UNKNOWN_WAIT_S seconds, up to TRIAGE_UNKNOWN_RETRIES times. A value that
# stays UNKNOWN is reported as is, with conflicts=false, and the next scan looks again.
#
# WHAT "LIVE" MEANS FOR A LABEL. review:running and review:fixing say a pass is in flight. A label
# applied less than TRIAGE_LIVE_LABEL_MINUTES ago (from the issue events API) is live and the
# fixer must not start. When the events cannot be read, the label counts as live: when in doubt,
# do not act.
#
# ENVIRONMENT (all optional):
#
#   FIXER_COMMIT_AUTHORS         logins, names or e-mails that identify the fixer's own commits.
#                                Default: none, so the recent-fixer-commit skip is off. No workflow
#                                runs the fixer, and a session fixer commits as the person; set this
#                                to your own login or name to turn the skip on
#   TRIAGE_RECENT_FIXER_MINUTES  a fixer commit younger than this skips the PR (default 10)
#   TRIAGE_LIVE_LABEL_MINUTES    default 60
#   TRIAGE_IGNORE_CHECKS         check names never counted as failing (default review-gate,
#                                which fails by design while the verdict is BLOCKED)
#   TRIAGE_UNKNOWN_RETRIES       default 3
#   TRIAGE_UNKNOWN_WAIT_S        default 10
#   TRIAGE_NOW                   ISO-8601 time to use as "now" (tests only)
#
# Needs gh and node, like review-cycle.sh. Treats every PR field as data: nothing read here is
# ever executed or used as an instruction.
set -uo pipefail

command -v gh >/dev/null 2>&1 || { echo "triage-pr: gh is not installed, INCONCLUSIVE" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "triage-pr: node is not installed, INCONCLUSIVE" >&2; exit 2; }
PR="${1:-}"
case "$PR" in ''|*[!0-9]*) echo "triage-pr: usage: triage-pr.sh <pr-number>" >&2; exit 2 ;; esac

digits() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
RETRIES=$(digits "${TRIAGE_UNKNOWN_RETRIES:-}" 3)
WAIT_S=$(digits "${TRIAGE_UNKNOWN_WAIT_S:-}" 10)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/triage-pr.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

FIELDS=number,state,isDraft,headRefOid,headRefName,baseRefOid,baseRefName,mergeable,mergeStateStatus,isCrossRepository,maintainerCanModify,labels,commits,statusCheckRollup
read_pr() { gh pr view "$PR" --json "$FIELDS" > "$TMP/pr.json" 2>"$TMP/err" && [ -s "$TMP/pr.json" ]; }
mergeable() { node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mergeable||""))}catch(e){}' "$TMP/pr.json"; }

read_pr || { echo "triage-pr: gh could not read PR #$PR: $(head -c 300 "$TMP/err")" >&2; exit 2; }
i=0
while [ "$(mergeable)" = UNKNOWN ] && [ "$i" -lt "$RETRIES" ]; do
  sleep "$WAIT_S"
  read_pr || { echo "triage-pr: gh could not re-read PR #$PR" >&2; exit 2; }
  i=$((i + 1))
done

# Label events are read only when a pass-in-flight label is present. A failed read leaves the file
# empty, and an empty file makes the label live.
: > "$TMP/events.tsv"
EVENTS_OK=1
if node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((p.labels||[]).some(l=>l.name==="review:running"||l.name==="review:fixing")?0:1)' "$TMP/pr.json"; then
  gh api "repos/{owner}/{repo}/issues/$PR/events?per_page=100" --paginate \
    --jq '.[] | select(.event == "labeled") | "\(.label.name)\t\(.created_at)"' > "$TMP/events.tsv" 2>/dev/null || EVENTS_OK=0
fi

EVENTS_OK=$EVENTS_OK node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const events = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean).map(l => l.split("\t"));
const env = process.env;
const num = (v, d) => /^[0-9]+$/.test(v || "") ? Number(v) : d;
const now = env.TRIAGE_NOW ? Date.parse(env.TRIAGE_NOW) : Date.now();
// Each entry is trimmed and compared without case, as written: a check or author name can hold a space.
const list = v => String(v || "").split(",").map(s => s.trim().toLowerCase()).filter(Boolean);

const conflicts = p.mergeable === "CONFLICTING" || p.mergeStateStatus === "DIRTY";
const headWritable = !p.isCrossRepository || !!p.maintainerCanModify;

// Failing checks. review-gate is excluded by default: it fails by design while a verdict is BLOCKED.
const ignore = list(env.TRIAGE_IGNORE_CHECKS === undefined ? "review-gate" : env.TRIAGE_IGNORE_CHECKS);
const runId = u => { const m = /\/actions\/runs\/(\d+)/.exec(u || ""); return m ? Number(m[1]) : null; };
const failing = [];
for (const c of p.statusCheckRollup || []) {
  if (c.__typename === "StatusContext" || (c.context !== undefined && c.name === undefined)) {
    if (["FAILURE", "ERROR"].includes(c.state) && !ignore.includes(String(c.context).trim().toLowerCase()))
      failing.push({ name: c.context, workflow: null, conclusion: c.state, run_id: runId(c.targetUrl), url: c.targetUrl || null });
  } else if (["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"].includes(c.conclusion) && !ignore.includes(String(c.name).trim().toLowerCase())) {
    failing.push({ name: c.name, workflow: c.workflowName || null, conclusion: c.conclusion, run_id: runId(c.detailsUrl), url: c.detailsUrl || null });
  }
}

// A pass-in-flight label is live when it was applied less than TRIAGE_LIVE_LABEL_MINUTES ago.
const liveMin = num(env.TRIAGE_LIVE_LABEL_MINUTES, 60);
let liveLabel = null;
for (const name of ["review:running", "review:fixing"]) {
  if (!(p.labels || []).some(l => l.name === name)) continue;
  const times = events.filter(e => e[0] === name).map(e => Date.parse(e[1])).filter(t => !isNaN(t));
  const last = times.length ? Math.max(...times) : NaN;
  if (env.EVENTS_OK !== "1" || isNaN(last) || now - last < liveMin * 60000) { liveLabel = name; break; }
}

// The fixer'"'"'s own last commit, younger than TRIAGE_RECENT_FIXER_MINUTES, means a fixer is still at work.
const fixers = list(env.FIXER_COMMIT_AUTHORS === undefined ? "" : env.FIXER_COMMIT_AUTHORS);
const commits = p.commits || [];
const lastCommit = commits.length ? commits[commits.length - 1] : null;
let recentFixer = false;
if (lastCommit) {
  const who = (lastCommit.authors || []).flatMap(a => [a.login, a.name, a.email]).filter(Boolean).map(s => String(s).trim().toLowerCase());
  const t = Date.parse(lastCommit.committedDate || lastCommit.authoredDate || "");
  recentFixer = who.some(w => fixers.includes(w)) && !isNaN(t) && now - t < num(env.TRIAGE_RECENT_FIXER_MINUTES, 10) * 60000;
}

let skip = null;
if (p.state !== "OPEN") skip = "closed";
else if (p.isDraft) skip = "draft";
else if (!headWritable) skip = "fork-without-edit";
else if ((p.labels || []).some(l => l.name === "review:needs-human")) skip = "extension-halted";
else if (liveLabel) skip = "live-label";
else if (recentFixer) skip = "recent-fixer-commit";

const lanes = [];
if (conflicts) lanes.push("conflict");
if (failing.length) lanes.push("check");

process.stdout.write(JSON.stringify({
  number: p.number, head: p.headRefOid, base: p.baseRefOid, headRef: p.headRefName, baseRef: p.baseRefName,
  state: p.state, draft: !!p.isDraft, isCrossRepository: !!p.isCrossRepository,
  mergeable: p.mergeable || "UNKNOWN", mergeStateStatus: p.mergeStateStatus || "UNKNOWN",
  conflicts, headWritable, failing_checks: failing, lane_suggestions: lanes,
  skip_reason: skip, live_label: skip === "live-label" ? liveLabel : null,
}) + "\n");
' "$TMP/pr.json" "$TMP/events.tsv" || { echo "triage-pr: could not parse the PR payload" >&2; exit 2; }
exit 0
