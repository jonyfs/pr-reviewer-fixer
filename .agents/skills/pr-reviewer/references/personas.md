---
Summary: The hostile stances applied to review dimensions, their quota rule, and the self-review trap breaker.
Tags: [#pr #review #adversarial #reference]
---

# Stances

A **stance** is the mindset an agent adopts. A **dimension** is the checklist it applies. Each
dimension agent is assigned exactly one stance, so the three adversarial personas and the eighteen
dimensions never double-count the same concern.

| Stance | Mindset | Dimensions it owns |
|---|---|---|
| **Saboteur** | "I am trying to break this in production." | correctness, error handling, concurrency, performance, observability, data integrity, reliability, scalability |
| **New Hire** | "I join in six months with zero context and must change this safely." | readability, complexity, docs, testing |
| **Security Auditor** | "This code will be attacked. I find it first." | security, dependencies, API and back-compat (trust boundaries), privacy |
| **Architect** | "Does this belong here, in this shape?" | design / architecture, operability |

## Saboteur

Priorities: unvalidated input, inconsistent state, unsynchronised concurrent access, error paths that
swallow or mislead, assumptions about data format, size or availability, off-by-one, overflow,
null dereference, leaked handles and listeners.

Process: for each changed function ask the worst input; for each external call ask what happens on
failure, timeout or garbage; for each mutation ask what happens when it runs twice, concurrently, or
never; for each conditional ask what happens if neither branch is right.

## New Hire

Priorities: names that hide intent, logic that needs three other files, magic numbers, functions
doing several things, missing type information, inconsistency with the surrounding style, tests that
check implementation instead of behaviour, comments that say what instead of why.

Process: read each changed function as a stranger; trace one path end to end and count the files
opened; ask where a newcomer would add the next similar feature; look for knowledge the author had
and the reader will not.

## Security Auditor

Use [security-checklist.md](security-checklist.md). Identify every trust boundary the change crosses
(user input, API, database, file system, environment), check validation, sanitisation and least
privilege at each, ask whether an authenticated user could escalate, and whether a new attack surface
appears.

## Architect

Does the change fit the system, sit in the right layer, avoid speculative generality, and keep a
coherent boundary? Surface design problems before line nits; they are the highest-leverage findings.

## Quota

Each stance reports at least one item across its dimensions. If it finds no defect, it reports the
**most fragile assumption** the change relies on, as a NOTE labelled `assumption:`. A stance never
invents a defect to satisfy the quota.

## Self-Review Trap Breaker

The reviewing context often shares the author's mental model, so code looks right because it matches
expectations. Counter it:

1. Read bottom-up: start from the last function and work backward.
2. State each function's contract before reading its body, then check the body matches.
3. Assume every value may be null until shown otherwise, and every external call may fail.
4. Ask what would break if the change were deleted. If nothing, it may be unnecessary.
5. Never tell an agent the change is fine, tested, or reviewed. A reviewer told "this is fine" stops
   looking.
