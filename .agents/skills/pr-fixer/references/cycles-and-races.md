---
Summary: Bounded cycles, push-race safety, concurrency/resume, head writability, verify-before-push, flaky checks, and post-arm monitoring.
Tags: [#pr #github #safety #autonomy #reference]
---

# Cycles, Races & Safe Autonomy

## The Cycle Model

A fixer pass is not one forward sweep. Each push produces new check runs and possibly new
comments, so the pass is a **bounded loop**:

```
load state → detect invalidators → classify lanes → resolve → verify → push → (repeat)
```

Halt on exactly one of:

| Halt reason | Condition |
|-------------|-----------|
| **Terminal** | Armed for automerge, or handed off ready for human review |
| **Budget** | `max_cycles` or `max_wall_time` exhausted |
| **No progress** | The same failure/lane state repeats across cycles with no net change |
| **Invalidator** | Review reopened, PR closed, converted back to draft after it was ready, or base retargeted |
| **Escalation** | A concern needs unsafe, ambiguous, or architectural work |

Always report the halt reason, what remains, and the single next action.

**Budget defaults** (configurable alongside the other portable settings):

| Setting | Purpose | Safe default |
|---------|---------|--------------|
| `max_cycles` | Loop iterations per pass | 5 |
| `max_wall_time` | Total pass duration | 60 min |
| `max_attempts_per_concern` | Correction attempts for one concern | 2 |
| `flaky_rerun_limit` | Re-runs before treating a check as genuine | 1 |

## Mid-Pass Invalidators (re-check every cycle)

State loaded at cycle start can be stale by cycle end. Before acting each cycle, confirm:

- The trusted verdict marker you are working from still names the head you planned against, and
  the label has not moved back to `review:running` (a new review pass started). If either changed,
  stop acting on findings and return to waiting.
- The PR is still open, and was not converted back to draft after it was ready. A draft that was
  already a draft at cycle start is the normal working state, not an invalidator.
- `baseRefName` is unchanged: a retarget invalidates conflict work.
- The head SHA is what you planned against.

Any invalidator → stop and report; do not continue on stale assumptions.

## Push-Race Safety

Never overwrite work you did not author.

```bash
# Immediately before pushing: compare planned head to actual remote head
git fetch origin "$HEAD_REF"
remote_sha=$(git rev-parse "origin/$HEAD_REF")
[ "$remote_sha" = "$PLANNED_SHA" ] || echo "head moved: re-sync and re-plan"
```

`scripts/push-guard.sh <pr> --findings FILE` runs this check and three more in one call: the
checked-out branch is the pull request's head branch, the head is not on a fork, and every file a
new commit touches is named by a finding, passed with `--allow`, or a test file. It posts nothing
and exits 1 with every reason when any check fails.

Rules:

- Head moved: re-fetch, merge the new head into your work (or rebase only your own commits), re-verify,
  then push. Re-plan if the external change already addressed the concern.
- **Never force-push.** Prefer bringing the base into the head with a merge commit, which needs no
  force. Rebase only where the project requires linear history, and then use `--force-with-lease`
  pinned to the exact head SHA you planned against, only for commits authored in this pass, only
  after confirming the remote head still equals that SHA. Never rewrite a branch that carries a
  commit you did not author, and never push to a bot's branch (Dependabot stops rebasing once
  someone else pushes).
- The author force-pushed and invalidated your local checkout → discard local state and reload. Never
  resolve against stale code.

## Concurrency & Resume

- **Concurrent pass**: before acting, check for signs another pass is live (very recent fixer
  commits or replies on the PR, an in-flight push). If detected, decline or wait. Never act in
  parallel on the same PR.
- **Resume after interruption**: reconstruct progress from the PR's own visible surface: commits
  already pushed, comment replies already posted, threads already resolved, check runs already
  triggered. No private persistent state. Work already recorded is not redone.

## Head Writability (check before any code work)

```bash
gh pr view <n> --json headRepositoryOwner,maintainerCanModify,isCrossRepository
```

If the head is a fork without `maintainerCanModify`, or the session lacks write access:

- Detect it **before** making changes, and adapt the plan.
- Deliver fixes as reviewable content (a patch in a comment and/or inline reply reasoning) instead
  of attempting a push.
- Say so in the report. Do not attempt a push that will fail.

## Verify Before Push

Discover the project's own verification commands (do not assume a toolchain): the contributor guide,
`package.json` scripts, `Makefile`, `pyproject.toml`, CI workflow steps.

1. Run the **narrowest** relevant verification for the change (the affected test file/package, then
   lint/build if the change is broad).
2. Verification fails → correct, up to `max_attempts_per_concern`, then escalate that concern.
3. **Do not push on failure.**
4. No verification path exists → push is allowed, but the report must state the change is unverified
   locally and why.

## Flaky vs Real Check Failures

Classify before touching code:

| Class | Signal | Action |
|-------|--------|--------|
| **Transient** | Infra/network/timeout error, failure unrelated to the changed files, known-flaky job | Re-run once (`gh run rerun <id> --failed`) before any code change |
| **Pre-existing** | The same check fails on the base branch without this PR | Report as pre-existing; do **not** widen the PR to fix it |
| **Genuine** | Fails identically after a re-run, and relates to the change | Fix scoped to this PR, or escalate per `ci_triage` |

Never change code to chase a failure a single re-run clears.

## Secrets in Check Logs

Check logs may contain tokens or credentials. Reference the log URL and quote only the shortest
decisive non-sensitive line. Never paste raw log dumps into comments, commits, or the report. If a
secret appears to be exposed in a log or the diff, stop and escalate to the human immediately:
that is a security event, not a fixer task.

## Conflicting Review Asks

Two comments demanding incompatible changes to the same code → do **not** silently pick one. Surface
the conflict, state both asks, and escalate for the human to decide.

## After Arming Automerge

Arming is not the end of the story. Report when the PR stops being on track to merge:

- A new blocking comment arrives.
- A required check turns red.
- The base branch advanced such that the branch must be updated → update it under the same
  guardrails, or escalate.
- A merge queue rejected the PR: "green + approved" is not always sufficient to land.

In each case, state the condition and the single next action.
