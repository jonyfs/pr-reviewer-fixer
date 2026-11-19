---
Summary: How pr-merge-fixer splits a conflict into units and picks each unit's tier and effort without a person choosing, and how the choice stays the same on any harness.
Tags: [#pr #merge #orchestration #models #reference]
---

# Orchestration

The skill decides three things on its own: how to split the work, which tier each unit gets, and when
to stop and ask. Nothing here names a model. The tier maps to a model and an effort in
[execution-profiles.md](execution-profiles.md) for the harness in use.

## 1. Split into units

| Unit | Made of | Dispatch |
|---|---|---|
| Mechanical | Every lockfile and generated file in the conflict | Run the regeneration command yourself. No sub-agent |
| File | One conflicted file with no hunk shared with another | One sub-agent, in parallel with the other file units |
| Cluster | Files that share a symbol, a module or a hunk | One sub-agent for the whole cluster, so the merge is decided once |
| Escalated | Anything in the escalation list in [conflicts.md](conflicts.md) | No sub-agent. The closure comment names it |

Two files that import each other's changed symbol are a cluster, even if no hunk overlaps.

## 2. Score each unit

Each unit gets one score per row. The highest score wins.

| Signal | Score |
|---|---|
| Class is 🧩 generated or lockfile | mechanical (no model) |
| Class is 🚚 rename, 🔀 textual, and the hunks are disjoint | fast |
| Class is 🧠 semantic, or hunks touch the same lines | deep |
| The base commit that touched the file says why it changed (a fix, a contract change) | deep |
| The file is in a test folder only, and the hunks add cases | fast |
| The unit has failed verification once | one tier up, at most once |
| The unit has failed verification twice | escalate |

Effort follows the tier: deep is `high`, standard `medium`, fast `low`. A unit that is only a test
file never goes deep.

## 3. Write the choice down

Each unit's row in the closure table states its tier. A reader can see why a semantic merge ran on
the deep tier and a lockfile on none. The label of a run shows what was in force, not what was
declared, as in [execution-profiles.md](execution-profiles.md).

## 4. Harness independence

- With per-subagent control (model and effort on each call), dispatch each unit with its tier.
- Without it, run the units one after another in one agent, deepest first, and say in the start line
  that the tiers were not set per unit.
- A harness that rejects a declared model or effort falls back to `standard` and says so.

## 5. Stop rules

- No unit is dispatched above `deep`. A unit the deep tier cannot resolve is escalated, not retried
  a third time.
- The skill never raises effort blindly. It moves one tier up after one failed verification, and
  escalates after the second.
- The total of dispatched units is stated in the start line, so a person sees the plan before the
  work starts.
