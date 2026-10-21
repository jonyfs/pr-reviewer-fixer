---
Summary: gh CLI/API commands for pr-fixer: wait-for-closure poll, state loading, comments, checks, merge.
Tags: [#pr #github #cli #reference]
---

# gh Commands

All commands assume an authenticated `gh`. Replace `<n>` with the PR number and `{owner}/{repo}`
with the target repository. Confirm the repository and base/head before any state-changing action.

## Wait for Review Closure (poll)

Review closure is a trusted verdict marker at the current head, not a GitHub review decision. The
automatic reviewer never submits `--request-changes` or `--approve`, so `reviewDecision` would never
change and a poll on it would never end. Poll the marker instead.

```bash
# One-shot read: exit 0 PASSED at the head, 1 owed (BLOCKED, no marker, stale), 2 inconclusive
scripts/review-cycle.sh status <n>

# Bounded poll loop: wait while a pass is in flight or no marker exists at the head
attempt=0; max=60
while :; do
  labels=$(gh pr view <n> --json labels --jq '.labels[].name')
  case "$labels" in
    *review:passed*|*review:blocked*) echo "review closed"; break ;;
  esac
  attempt=$((attempt+1)); [ "$attempt" -ge "$max" ] && { echo "still waiting"; break; }
  sleep 60
done
```

When the loop ends, read the verdict comment itself with filter F1 in
[pr-protocol.md](pr-protocol.md) (marker `sha=` equal to the head, author in
`REVIEW_MARKER_AUTHORS`). The label is only the projection; the marker decides. Take no
state-changing action while there is no trusted marker at the head. Prefer a notification-driven
trigger (a watch loop) over long blocking polls when available.

## Load PR State

```bash
gh pr view <n> --json \
  title,state,isDraft,mergeable,mergeStateStatus,headRefName,baseRefName,\
reviewDecision,statusCheckRollup,comments,reviews
gh pr diff <n> --name-only         # changed files
gh pr diff <n>                     # full unified diff
gh pr checks <n>                   # CI status per check
```

## Reviewer Report and Closure

Find the verdict comment and its `findings` block, the closure comment of an earlier cycle, and the
`pr-debt` block with filters F1, F3 and F4 in [pr-protocol.md](pr-protocol.md). Screen the closure
comment, then post it:

```bash
scripts/review-cycle.sh screen --file closure.md && gh pr comment <n> --body-file closure.md
```

Write the debt block with the read-modify-write recipe there, which screens the new body before
`gh pr edit`. Any other comment (an overflow of a long closure report) goes through `screen` the
same way. `screen` exits 1 and names the kind of secret, never the value; replace it with
`[REDACTED]` and screen again.

## Comments (Comment Lane)

```bash
gh pr view <n> --comments                                   # top-level PR comments
gh api repos/{owner}/{repo}/pulls/<n>/comments              # inline review comments
gh api repos/{owner}/{repo}/pulls/<n>/reviews               # submitted reviews + bodies
```

Reply to a specific inline comment. A reviewer's inline comment starts with its finding id, `[C1]`;
the reply names the same id:

```bash
gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment_id>/replies \
  -f body="Closed in <sha7> (C1)"
gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment_id>/replies \
  -f body="Declined (C1): <reasoning>"
```

`gh api` is not in the automatic run's allowlist. There, the closure comment carries the same lines
and the replies wait for a run that has `gh api`.

## Conflict / Check Lanes

```bash
gh pr checkout <n>                 # local checkout to fix or trace
# ... make minimal scoped commits on the PR branch, then verify, then:
git fetch origin "$HEAD_REF"       # re-check the remote head BEFORE pushing (race safety)
git rev-parse "origin/$HEAD_REF"   # must equal the SHA you planned against
git push                           # to the PR head branch only, never the protected base
```

Never `git push --force`, `--force-with-lease` or `--force-if-includes`. A conflict is resolved by
merging the base into the head, which pushes as a fast-forward. A rebase of a pushed branch is
never pushed: if the project requires linear history, hand the rebase to a person.

## Head Writability & Check Re-Runs

```bash
gh pr view <n> --json isCrossRepository,maintainerCanModify,headRepositoryOwner  # can we push?
gh run rerun <run_id> --failed     # re-run a plausibly flaky check before changing code
gh run view <run_id> --log-failed  # inspect the failure (never paste raw logs: secrets)
```

## Proactive Triage

```bash
scripts/triage-pr.sh <n>           # read-only: lanes, failing checks, skip_reason as one JSON object
gh run list --branch <base> --workflow <workflow> --limit 1   # is the failure pre-existing on base?
```

Act only when `skip_reason` is null and `lane_suggestions` is not empty. Exit 2 means nobody
looked (gh missing or offline), never "nothing to do".

## Resolving Review Threads

```bash
gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -F t=<thread_id>
```

Thread IDs come from the `reviewThreads` connection on the PR via the GraphQL API. Resolve only
threads whose comment has a recorded `fixed` outcome (or a `declined` the reviewer accepted).

## Approval Lane

```bash
gh pr ready <n>                                   # run by review-cycle.sh publish on PASSED; the fixer does not run it
gh pr merge <n> --squash --auto --delete-branch   # arm automerge (strategy from config)
```

Never `--no-verify`, never bypass a required check. Merge strategy (`--squash` / `--merge` /
`--rebase`) comes from the `merge_strategy` config.
