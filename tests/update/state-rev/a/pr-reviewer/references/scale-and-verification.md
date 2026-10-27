---
Summary: Partitioning oversized changes, low-signal change classes, and the pre-delivery self-verification pass.
Tags: [#pr #review #scale #quality #reference]
---

# Scale & Self-Verification

## Oversized Changes: Partition, Don't Skim

Beyond the effective-size limit (~400 changed lines), a single pass loses defects. Do not degrade to
a skim plus a disclaimer. **Partition**:

1. **Partition** the change into reviewable units, by cohesion, not by line count: module/package,
   layer, or feature slice. Keep a unit under the effective-size limit where possible.
2. **Review each unit** at full depth with the standard dimensions and security pass.
3. **Review the seams.** defects in oversized PRs often live in the interaction *between* units
   (contract drift between caller and callee, duplicated logic, inconsistent error handling). Do a
   pass over cross-unit interactions after the per-unit passes.
4. **Merge** results into one severity-ranked review, deduplicating the same defect found from two
   units.
5. **Report a depth map**: one line per area with the depth actually reached. No area may be
   silently unreviewed.
6. **Still recommend splitting** the PR. Partitioning is how this review copes; it is not a reason
   the PR was fine at that size.

Depth map format:

| Area | Depth | Note |
|------|-------|------|
| `api/handlers/**` | full | traced error paths |
| `migrations/**` | full | schema + rollback checked |
| `vendor/**` | skimmed | vendored, unmodified upstream |

## Low-Signal Change Classes

Scale effort to signal, since not every changed line is equal:

| Class | How to treat it |
|-------|-----------------|
| **Pure revert** | Verify it *is* a clean revert of the named commit and that nothing since depends on it. Do not re-review the reverted code's style. |
| **Generated files** | Verify the generator input and that output matches regeneration. Do not line-review generated output. |
| **Mechanical rename / move** | Verify completeness (no stale references) and that no logic changed inside the moved code. Sample, don't read every hunk. |
| **Dependency bump** | Check changelog/CVE impact and breaking changes, not the vendored diff. |
| **Formatting-only** | Confirm it is truly behavior-neutral; if it is mixed with logic, ask for a split. |

State which class you applied: a reader must know you chose reduced depth deliberately.

## Self-Verification Pass (before delivering)

Run this over the draft findings. It is cheaper to drop a weak finding than to lose the author's
trust in the strong ones.

For **every** finding:

1. **Substantiation**: can the claim be shown from the diff plus reachable repository code? If not,
   downgrade it to a `question:` with stated confidence, or drop it. Never keep it as a defect.
2. **Check outside the diff**: a construct that looks unsafe in isolation is often guarded by a
   caller, a decorator, a framework contract, or a type. Look before asserting.
3. **Machine-owned?** If a linter/formatter already enforces it, drop it.
4. **Duplicate?** If a human or bot already said it, drop it or explicitly concur/dispute.

For every **CRITICAL** finding, additionally:

5. **Concrete failure scenario**: name the inputs or state and the resulting bad outcome
   ("empty `items` → `items[0]` panics on the retry path"). A CRITICAL without a failure
   scenario is not yet a CRITICAL: demote it to WARNING or to a `question:`.

Then:

6. **Verdict consistency**: the verdict is arithmetic: one or more CRITICAL is BLOCKED, otherwise
   PASSED. A failing required check is not passed over without an explicit stated reason.
7. **Counts**: report them next to the verdict so the outcome is scannable:
   `Verdict: BLOCKED, critical=1 warning=2 note=5`.
