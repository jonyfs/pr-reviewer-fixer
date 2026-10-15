---
Summary: How pr-fixer adapts to the situation and tells the user when it starts, progresses, finishes or stops.
Tags: [#pr #fix #notifications #dynamic #reference]
---

# Dynamic Operation and Notifications

A fixer that pushes to a branch while nobody watches must be easy to follow after the fact. Every
run says when it starts, what it is working, and when it is done or why it stopped.

## Announce, always

| Moment | Required line | Where |
|---|---|---|
| Start | `pr-fixer: started on PR #N (head <sha7>, cycle C of <allowed>). Work: <n> CRITICAL, <m> comments, conflict <yes\|no>, failing checks <k>. Debt to declare: <d>.` | Session output, the status comment (created now), the label |
| Lane change | `pr-fixer: PR #N lane <name> (<i>/<total>).` | Session output |
| Push | `pr-fixer: pushed <sha7> to <branch> (<n> commits).` | Session output |
| Finish | `pr-fixer: finished PR #N cycle C: closed <a>, refused with evidence <b>, debt declared <d> with owners. Head <sha7>. Next: <reviewer pass C+1 \| escalated \| ready for human review>.` | Session output, first visible line of the closure comment, the status comment (edited to `state=finished`), push notification if available |
| Nothing to do | `pr-fixer: PR #N has no work at <sha7> (marker <verdict>).` | Session output |
| Stopped or escalated | `pr-fixer: stopped on PR #N: <reason>. Open: <list>. Next action: <one action>.` | Session output, the closure comment if one is due, the status comment (edited in place), and a push notification |
| Extension granted | `pr-skill: extension granted on PR #N: <n> more cycles (cycle <c+1> to <c+n>, hard ceiling <h>). The loop continues.` | Session output, the answer comment |
| Halted | `pr-skill: halted on PR #N. <reason sentence>` | The answer comment (marker first), session output, push notification, always |

Rules:

- The start line comes **after** `review-cycle.sh fix` has taken the cycle and before the first
  edit, so the label and the announcement agree.
- A lane change or push is one line. No running commentary.
- Every started run ends with exactly one finish or stopped line. Escalation always notifies, and
  so do the extension question and the halt: they are the moments a person must act, so they
  push even on a short run.
- A run dispatched without a named PR says what it found before it acts and states the class of
  every failing check once it decided it.
- Counts in the finish line equal the closure report.

## Channels

1. **Session output**: the lines above, verbatim.
2. **PR status comment**: at most one per run. Create it at start with the start line and the
   lane roster with tier and any substitution in force, keep its id, and edit it in place at finish
   (`gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id>`). Marker
   `<!-- pr-skill-status: skill=pr-fixer run=C head=<sha12> state=started|finished -->`. This is
   neither the verdict marker nor the closure marker. Never edit another author's comment.
3. **Closure comment**: one per cycle, with the `pr-fixer-closure` marker, carrying the finish line
   as its first visible line and then the closure report. There is no separate finish comment.
4. **Push notification** on finish or stop of a run longer than about two minutes, and always on
   escalation, an extension question and a halt, when the harness offers one.
5. **Labels** move only through `review-cycle.sh` (`review:fixing` at start; the head moving
   retires it).

Comment budget per run: one status comment (edited in place) and one closure comment. Lane changes
and pushes go to the session output only. Full budget across both skills:
[pr-protocol.md](pr-protocol.md).

Notifications carry no secrets, no log excerpts and no finding bodies.

## Dynamic operation

| Situation | Behaviour |
|---|---|
| Marker at head is `BLOCKED` | Run the finding lane first, then the others |
| Marker at head is `PASSED` with debt | Debt-only mode in the automatic run: owners into the `pr-debt` block, one closure comment, no code edits. By hand, a WARNING may be fixed when that is cheaper than recording it |
| No marker at head | Wait or ask for the review; do not fix against a report for another commit |
| Only comments, no report | Comment lane only; no cycle count against the review budget |
| Conflict present | Conflict lane first, alone; announce that other lanes are waiting. Playbook: [conflicts.md](conflicts.md) |
| Dispatched with nobody naming the PR and `triage-pr.sh` returns lanes with no `skip_reason` | Announce the start line, then work the lanes it named. `skip_reason` set: do nothing and say why in the session |
| Head not writable (fork, no edit access) | Produce a patch and replies, say no push will happen |
| Failing check looks transient | Re-run once, announce it, then classify. Playbook: [ci-failures.md](ci-failures.md) |
| Failure is pre-existing on base | Report it, do not widen the PR |
| Newest trusted marker is BLOCKED and cycles done reached the allowed budget | Do not start. `review-cycle.sh budget` says `ask`: the loop agent asks the person in the session and notifies |
| Newest trusted extension marker is halted | Do not start; the PR needs a person |
| Harness lacks subagents | Run lanes sequentially in one agent, deep lanes first |
| Harness cannot set effort per call | Run at the session setting and say which lanes lost their tier |
| Budget or rate limit reached | Stop at a lane boundary with a clean branch, report the remaining lanes |
| Invalidator (review reopened, PR closed, converted back to draft after it was ready, base retargeted) | Stop and report; do not continue on stale state |

## Failure honesty

A lane that could not finish says so in the finish line with the reason. A push that was skipped
because the head moved is reported as skipped, with the new head.
