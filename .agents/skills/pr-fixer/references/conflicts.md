---
Summary: Handoff of the conflict lane from pr-fixer to pr-merge-fixer. The playbook itself moved to pr-merge-fixer in 0.20.0 so one copy exists.
Tags: [#pr #fix #conflict #handoff #reference]
---

# Conflicts: handed to pr-merge-fixer

This skill does not merge the base into the head. A branch that conflicts with its base is the job
of `pr-merge-fixer`, which the review loop agent dispatches before a review, and again after a PASSED
verdict when the base moved.

When this skill starts on a pull request that is `DIRTY` or `CONFLICTING`:

1. Make no write. Do not run `review-cycle.sh fix <pr>` for the conflict.
2. Report `conflict owed to pr-merge-fixer` in the session and in the closure comment, if one is
   posted, with the pull request number.
3. Stop. The loop agent runs the merge fixer, then starts the review again.

The merge playbook (classes of conflicted file, the resolution per class, the tier for each unit,
and the escalation list) is in the `pr-merge-fixer` skill, at `references/conflicts.md` and
`references/orchestration.md`. This skill installs alone and does not link to it.
