---
Summary: Reviewer workflow, gh commands for fetching PR data, effective-size limits, and verdict mapping.
Tags: [#pr #review #cli #reference]
---

# Workflow, Size Limits & gh Commands

## Reviewer Workflow

1. **Read the PR description and linked issue first.** Understand intent, scope and non-goals
   before reading code. If context is missing, ask or flag it.
2. **Scan the diff top-down for the big picture.** Architecture and design fit first (highest
   leverage).
3. **Read the tests.** They reveal intended behavior and edge cases; confirm they would fail if the
   code broke. Call out missing or weak tests.
4. **Trace critical paths.** Main data and control flow and error paths; mentally execute edge
   cases, partial failures, retries and boundary conditions.
5. **Verify scope.** No unrelated changes; the PR does one thing. If it does more, say so.
6. **Write findings with labels and severities**, then a summary and verdict. Be honest about what
   you reviewed deeply versus what you only skimmed.

## Effective-Size Limits (empirical, SmartBear/Cisco)

- Review **200 to 400 changed lines** at a time at most; beyond about 400 LOC defect detection drops
  sharply.
- Inspection rate **under 500 LOC/hour**; sessions **60 minutes or less**.
- A well-run review of 200 to 400 LOC finds about 70 to 90% of defects.
- If a PR is too big to review well, **partition it** into reviewable units, review each, review the
  seams between them, and merge the results (see
  [scale-and-verification.md](scale-and-verification.md)). Report the depth actually reached per area
  and still **recommend splitting** the PR. Never pretend to have reviewed a surface you did not.

## gh Commands (read-only by default)

```bash
gh pr view <n> --json title,body,author,files,additions,deletions,labels,reviewDecision
gh pr diff <n>                     # full unified diff
gh pr diff <n> --name-only         # changed files
gh pr checkout <n>                 # local checkout to run/trace critical paths
gh pr view <n> --json statusCheckRollup   # CI status
gh api repos/{owner}/{repo}/pulls/<n>/files   # per-file patches (programmatic)
```

The verdict comment, the fixer's closure comment and the debt block are found with the commands in
[pr-protocol.md](pr-protocol.md), which keep only comments by logins in `REVIEW_MARKER_AUTHORS`.

## Posting a Review

The verdict is always the marker comment, published by `scripts/review-cycle.sh publish`. What else
is posted depends on who started the run.

**Automatic run (the review loop agent, a hook).** Post no GitHub review event at all: never
`--request-changes`, never `--approve`, and no `--comment` review either, since the verdict comment
already carries the report. The reviewer sub-agent is not given `gh pr review` or `gh api`, so
inline comments are not available there; findings live in the verdict
comment with their ids.

**A person invoked the review by hand.** The marker comment is still the verdict. The person may
also ask for a GitHub review beside it:

```bash
gh pr review <n> --approve         -b "summary"          # only if the invoker is not the PR author
gh pr review <n> --request-changes -b "blocking items..."
gh pr review <n> --comment         -b "..."
```

Inline comments via API require `path`, `line`/`start_line`, `side`, and the head `commit_id`. Each
inline comment body starts with its finding id, `[C1] ...`, so the fixer's reply can name it.
Batch inline comments into one submitted review. Use ` ```suggestion ` blocks for trivial concrete
fixes.

## Verdict Mapping

| Verdict | Automatic run | Invoked by a person | When |
|---------|---------------|---------------------|------|
| **PASSED** | Marker comment only | Marker comment, plus `--approve` if the invoker is not the author | Zero CRITICAL. Warnings and notes are declared debt |
| **BLOCKED** | Marker comment only, never `--request-changes` | Marker comment, plus `--request-changes` if wanted | One or more CRITICAL, listed in the report |

A later COMMENT review does not clear an earlier CHANGES_REQUESTED review from the same identity,
so a bot change request would outlive the CRITICAL it named. In the automatic run, BLOCKED is
enforced by the `review:blocked` label and the required `review-gate` status check
(`templates/review-gate.yml`). Bias toward PASSED once the change definitively improves code health, but never pass
over an unaddressed CRITICAL or an unexplained failing required check. See
[severity-and-verdict.md](severity-and-verdict.md).
