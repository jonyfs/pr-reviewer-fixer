---
Summary: Severity model, promotion cap, verdict arithmetic, comment labels, tone, and anti-patterns for pr-reviewer.
Tags: [#pr #review #severity #verdict #reference]
---

# Severity and Verdict

## Severity

| Severity | Definition | Effect |
|---|---|---|
| **CRITICAL** | Will cause data loss, a security breach, or a production outage, or breaks an invariant the host project declares non-negotiable | Blocks the merge. The only severity that does |
| **WARNING** | Likely to cause a bug in an edge case, degrade performance, or confuse a maintainer. Includes missing tests for new logic | Does not block. Fix now, or declare as debt with a named owner |
| **NOTE** | Style, minor improvement, documentation gap, question, praise | Does not block. Author's discretion, recorded as debt |

### Project invariants are read, not assumed

The CRITICAL definition names "an invariant the host project declares". Find them in the project's
constitution, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, or an `invariants` section of its docs
before the first agent runs, and pass the list to every agent. Typical examples: tenant isolation,
money in integer minor units, an admin key that bypasses policy, environment separation. If the
project declares none, CRITICAL is data loss, security breach and outage only. Never import another
project's invariants.

### Where missing tests land

Missing tests for new logic are a **WARNING**. They become a **CRITICAL** only when the untested
code is itself CRITICAL-class: an authorization check, a data migration, a money calculation, an
invariant guard. The reason is the same as for promotion: absence of a test is a risk, not a
failure, and a blocker with no failure scenario is how a cycle stops terminating.

### Promotion cap

A finding raised from 2 or more stances rises one level and **stops at WARNING**. Promotion
measures agreement between stances, and agreement is not consequence. Three stances noticing the
same stale comment is still a stale comment. Left uncapped, promotion manufactures blockers out of
style, and CRITICAL is the only thing that stops a merge.

## Verdict

- **BLOCKED**: one or more CRITICAL. With `REVIEW_BLOCK_AT=warning`, one or more WARNING also blocks.
  Nothing else does.
- **PASSED**: zero blocking findings. With the default setting that is zero CRITICAL, and warnings
  and notes are declared debt, each with a proposed owner. With `REVIEW_BLOCK_AT=warning` only notes
  remain.

`REVIEW_BLOCK_AT` is `critical` by default. A repository that wants likely bugs fixed before merge
sets it to `warning` (the same value in the shell that publishes and in the repository variable the
`review-gate` reads). A WARNING that blocks must give a `scenario:`: a concrete input or sequence
that fails. If you cannot write one, it is a NOTE. This keeps the stricter setting from turning
style opinions into blockers.

There is no third verdict. A verdict with no state to project into is not a verdict. "No criticals
but many warnings" is PASSED with `warning=N`.

| Verdict | Run | How it is posted | Enforced by |
|---|---|---|---|
| PASSED | Automatic | Marker comment only. No GitHub review event | `review:passed` label and the `review-gate` check passing |
| BLOCKED | Automatic | Marker comment only, with the CRITICAL list in the report. Never `--request-changes` | `review:blocked` label and the required `review-gate` check failing |
| PASSED | Invoked by a person | Marker comment, plus `--approve` when that person is not the PR author | Same as above |
| BLOCKED | Invoked by a person | Marker comment, plus `--request-changes` if that person wants it | Same as above |

Why the automatic run never submits `--request-changes` or `--approve`: a later COMMENT review does
not clear an earlier CHANGES_REQUESTED review from the same identity. A bot change request posted
at pass 1 would keep blocking the merge after pass 2 passed, and nothing in the loop could remove
it. The marker is the verdict; the label and the required status check are its enforcement.

Never approve over a failing required check without an explicit stated reason. A prior CRITICAL
that is still open keeps the verdict at BLOCKED.

## A CRITICAL the fixer refused

The fixer may refuse a CRITICAL that does not reproduce, with the evidence written in its closure
comment. The refusal is a claim, and the reviewer judges it on the next pass, at the deep tier.
Each pass-1 CRITICAL ends pass 2 in exactly one state:

| State | Status in the findings block | Condition | Counts |
|---|---|---|---|
| Closed and verified | `verified` | The reviewer re-ran the fixer's red and green evidence itself and saw the red fail and the green pass | Not counted |
| Refusal accepted | `refused-accepted` | The non-reproduction evidence holds when the reviewer runs it | Withdrawn. The reason is recorded in the report. Counts drop by one |
| Refusal rejected | `refused-rejected` | The evidence does not hold, or tested the wrong form | Still counted. The verdict stays BLOCKED |

A CRITICAL that the fixer neither closed nor refused stays `open` and counted. The fixer never
decides whether its own refusal stands, and a cheaper tier never decides it either.

## Conventional Comments

Findings carry a label so intent is unambiguous: `<label> [decoration]: <subject>` plus rationale.

| Label | Meaning | Usual severity |
|---|---|---|
| `issue:` | A specific problem with the change | CRITICAL or WARNING |
| `todo:` | Small but necessary change | WARNING |
| `chore:` | Task required before acceptance (changelog) | WARNING |
| `suggestion:` | Concrete improvement | WARNING or NOTE |
| `question:` | A concern you cannot confirm | NOTE |
| `assumption:` | Most fragile assumption relied on (quota item) | NOTE |
| `nitpick:` | Trivial, preference-based | NOTE |
| `thought:` | Non-blocking idea | NOTE |
| `praise:` | Something genuinely good | NOTE |

Decorations: `(blocking)` only on a CRITICAL; `(non-blocking)`; `(if-minor)`.

## Documenting a Finding

1. **Location**: `file:line` or region, anchored to the diff.
2. **Impact**: why it matters, not only that it is bad.
3. **Path forward**: a concrete change, a suggested-change block for trivial fixes, or a specific
   question.
4. **Confidence**: say so when the concern is inferred rather than observed.

Good: *"issue (blocking): this unbounded loop can exhaust memory on large inputs (`ingest.go:88`).
Cap batch size or stream."* Bad: *"this is wrong."*

## Tone

Comment on the code, not the person. Ask rather than command. Give a reason every time. Be direct:
"this throws when `user` is undefined", not "this might possibly be a concern". Lead with praise
where earned.

## Anti-Patterns

| Anti-pattern | Why it is wrong |
|---|---|
| "LGTM, nothing found" | Every change has a risk, an assumption or an improvement. Say which |
| Cosmetic-only findings | Whitespace reported while a null dereference is missed is worse than no review |
| BLOCKED with no CRITICAL | Finding something and barring the door are different acts. The script refuses it |
| Promoting a NOTE into a CRITICAL | Agreement is not consequence |
| A new bar on pass 3 | The acceptance list was fixed at pass 1. A moving target cannot be reached |
| A bot change request | It outlives the CRITICAL it was about. Post the marker; the required check enforces it |
| Accepting a refusal without running its evidence | The closure report is input, not evidence |
| Manufacturing a defect for the quota | Report the fragile assumption as a NOTE instead |
| Counts the marker does not carry | `critical`, `warning`, `note` are the arithmetic. Prose and counts must agree |
| Bikeshedding, ego, scope creep | Demanding unrelated refactors or re-litigating style a formatter owns |
