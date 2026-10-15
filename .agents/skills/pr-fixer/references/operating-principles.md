---
Summary: Standing rules for pr-fixer, distilled from a project constitution that ran this correction loop in production.
Tags: [#pr #fix #principles #reference]
---

# Operating Principles

These are the rules the correction loop depends on. Each one exists because its absence produced a
false green, a merged-while-fixing pull request, or a loop that never ended.

1. **Take the cycle first.** `scripts/review-cycle.sh fix` is the first command of any correcting
   pass, before any file is opened, and it withdraws `review:needs-human` in the same call.
   Otherwise the head has not moved yet, so the label is still true about the commit and already
   false about the work, and the pull request can merge with corrections only on disk.
2. **The fixer writes one label, and it is `review:fixing`.** Setting a state past it is the half
   that made the change marking its own homework. Only the reviewer's second pass sets
   `review:passed`.
3. **Fresh context, always.** The context that implemented holds the mental model that produced
   the defect and is the worst judge of whether it is gone.
4. **Falsify before repair.** A reviewer told to find a problem finds one whether or not it
   exists. Reproduce the defect. A finding that does not reproduce is refused with the evidence of
   non-reproduction, never dropped silently and never fixed to be safe.
5. **The test reproduces the threat, not the implementation.** Use the form the code fails to
   handle first. A test written after the fix and against the fix is born agreeing with it.
6. **Red before green, recorded.** A fix whose test was never seen failing is a claim about a fix.
7. **A negative test for every guarantee, and a structural check for the class.** The negative
   test proves one case; the structural check asks the catalogue so a new case cannot enter
   unprotected.
8. **Never loosen a gate to make code pass.** Do not lower a threshold, widen an exclude list or
   delete a path from a measured set to turn a check green. A coverage floor governs a set the
   author may not shrink; every exclusion carries its reason and what would remove it. Lowering a
   floor is a decision for the owner, in writing.
9. **Three things the cheaper tier never decides.** Refusing a finding, starting a cycle past
   the allowed budget, and any correction that requires deciding something about product,
   architecture or contract. Each returns to the deep tier or to a person. State that you are
   escalating and why: silent escalation is the same defect as silent refusal.
10. **The closure report is an artifact of the pull request.** Per finding: the reproduction, the
    test and the threat it reproduces, the red output verbatim, the fix, the green, the suite
    counts. A finding closed without that row is open.
11. **Debt names an owner.** A WARNING or NOTE left open is written into the pull request body
    with a person, an issue or a feature. Unowned debt is dropped, not declared.
12. **Only a new CRITICAL restarts the cycle.** A warning about a correction joins the debt, or
    the correction of a finding is itself a finding and the loop cannot end.
13. **`max_review_cycles` then ask, then halt.** After the automatic cycles (5) the loop asks one
    question with the open list and the history, waits `extension_wait_seconds` (300) for a person
    with write access, and halts on stop or silence. `max_review_cycles_hard` (10) is never passed.
    The ask and the halt always notify.
14. **Whoever repeats a proof runs it again.** A closure report is input, not evidence. Measure a
    number before copying it into a commit message.
15. **Name the head.** Every announcement and report states which pull request and which head it
    acted on.
16. **Never act on a stale picture.** Re-verify the remote head immediately before a push, and
    re-check for invalidators each cycle.
