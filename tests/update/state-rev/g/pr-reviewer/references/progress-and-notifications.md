---
Summary: How pr-reviewer adapts to the situation and tells the user when it starts, progresses, finishes or stops.
Tags: [#pr #review #notifications #dynamic #reference]
---

# Dynamic Operation and Notifications

The skill runs unattended, so silence is a defect. The user must be able to tell, from the places
they already look, that a review is running, what it is doing, and when it is done.

## Announce, always

| Moment | Required line | Where |
|---|---|---|
| Start | `pr-reviewer: started on PR #N (head <sha7>, pass P, <lines> lines changed). Plan: <k> agents (<deep>/<standard>/<fast>). I will report when done.` | Session output, the status comment (created now), the label, CI job summary |
| Phase change (only these: dispatching, verifying, publishing) | `pr-reviewer: PR #N <phase>.` | Session output |
| Finish | `pr-reviewer: finished PR #N pass P: <PASSED\|BLOCKED> critical=C warning=W note=N. Next: <pr-fixer \| ready for human review \| nothing>.` | Session output, first visible line of the verdict comment, the status comment (edited to `state=finished`), push notification if available |
| Nothing to do | `pr-reviewer: PR #N at <sha7> already reviewed (pass P, <verdict>). No action.` | Session output |
| Stopped early | `pr-reviewer: stopped on PR #N: <reason>. Next action: <one action>.` | Session output, the status comment (edited in place), push notification |
| Halted | `pr-skill: halted on PR #N. <reason sentence>` | The answer comment (marker first), session output, push notification, always |

Rules:

- Start line comes **before** the first read of the diff, so a crash leaves a trace.
- Never more than one line per phase change. Progress chatter is a cost, not a feature.
- Every started run ends with exactly one finish or stopped line. If the run dies, the next run
  that finds `review:running` with no marker at the head says so and reports the interrupted pass.
- Finish line counts must equal the counts in the marker.
- The extension question and the halt always notify, whatever the run length: they are the
  moments a person must act. Escalation always notifies.

## Channels

1. **Session output**: the lines above, verbatim.
2. **PR status comment**: at most one per run. Create it at start with the start line and the
   agent roster with tier and any model substitution in force, keep its id, and edit it in place at
   finish or stop (`gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id>`). Marker:
   `<!-- pr-skill-status: skill=pr-reviewer run=P head=<sha12> state=started|finished -->`. This is
   not the verdict marker and must never be confused with it: the verdict is published only by
   `scripts/review-cycle.sh publish`. Never edit another author's comment.
3. **Verdict comment**: carries the finish line as its first visible line, then the report and the
   `findings` block. There is no separate finish comment.
4. **Push notification**: on finish or stop of a run longer than about two minutes, when the
   harness offers one (Claude Code `PushNotification`). One per run, plus one for each extension
   question and halt, always.
5. The label (`review:running`, `review:passed`, `review:blocked`) is the at-a-glance state in the
   PR list and is moved by the script, not by hand.

Comment budget per run: one status comment (edited in place) and one verdict comment. Phase
changes go to the session output only. Full budget across both skills:
[pr-protocol.md](pr-protocol.md).

Do not put secrets, log excerpts or finding bodies in notifications. Finding detail lives in the
report.

## Dynamic operation

Decide each run from facts, and say what was decided in the start line or the coverage note.

| Situation | Behaviour |
|---|---|
| Trigger is a new PR, a push to its branch, or a manual call | Pass number from the newest marker: no marker means pass 1, `BLOCKED` marker means the next pass |
| Head already carries a trusted marker | No new review. Announce "already reviewed". Exception: a closure comment for that cycle is newer than the marker, so the next pass is owed on the same head |
| Draft PR | Review it. The agent opens PRs as drafts, and `review-cycle.sh publish --verdict PASSED` marks the PR ready for review |
| Actor is the fixer's own push | Pass 2 on the new head. Never start a fresh pass 1 |
| Tiny change (under about 150 lines) | Batch fast and standard units, dispatch deep units separately |
| Large change (over about 400 lines) | Partition, depth map, recommend a split |
| Low-signal class (revert, generated, rename, format-only) | Reduced roster, stated in the coverage note |
| Harness has no subagents | Walk the units sequentially in one context, deep units first |
| Harness cannot set effort per call | Run at the session setting and say which units lost their tier |
| Rate limit or budget cap | Run deep units first, list deferred units as not run, finish with `PASSED` or `BLOCKED` only on what ran, flagged incomplete |
| Required check failing or not yet finished | Say so; never PASSED over it without a stated reason |
| Target is not a PR | Local diff review, no marker, no label, finish line says "no PR to publish to" |

## Failure honesty

If a step cannot run, the finish or stopped line says which one and why. A review that skipped its
security unit says so in the first line, not in a footnote.
