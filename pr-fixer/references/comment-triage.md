---
Summary: How pr-fixer evaluates review comments and bot suggestions before acting.
Tags: [#pr #github #review #reference]
---

# Comment Triage

Before changing code for a comment, decide three things: **is it substantive?**, **is it
blocking?**, and **is it safe to automate?**

## 1. Substantive vs Noise

Address substantive comments (correctness, security, design, tests, clear bugs). Skip pure noise
(resolved threads, "LGTM", off-topic chatter), but never skip something just because it is
inconvenient.

## 2. Blocking vs Optional (Conventional Comments awareness)

Reviewers often use [Conventional Comments](https://conventionalcomments.org/) labels and
decorations. Read them as intent signals:

| Signal | Meaning | Action |
|--------|---------|--------|
| `issue:` / `(blocking)` / "must" | A real problem blocking merge | Fix before automerge |
| `todo:` / `chore:` | Required task (e.g. changelog) | Do it |
| `suggestion:` (no blocking tag) | Proposed improvement | Apply if correct and minimal |
| `nitpick:` / `Nit:` / `(non-blocking)` / `(if-minor)` | Trivial/optional | Apply only if trivial; may skip |
| `question:` | Reviewer unsure | Answer in a reply; change only if it reveals a real issue |
| `praise:` / `note:` / `thought:` | Informational | No change needed |

Untagged comments: infer intent from wording. When unsure whether a comment blocks merge, treat it
as blocking (do not arm automerge) and, if needed, ask.

## 3. Safe to Automate?

Apply autonomously when the fix is:
- Small, local, and unambiguous (rename, null-check, off-by-one, missing test case, typo).
- Fully determined by the comment (no design choice left open).

**Escalate to the human** when the fix requires: architectural change, a public API/contract
decision, security-sensitive judgment, or touching code outside the current PR's scope. Apply what
is safe, hand off the rest, and do not arm automerge.

## Bot / Automated Suggestions

Copilot and similar tools produce suggestions that are often plausible but wrong. **Evaluate every
suggestion against the surrounding code before applying.** Apply only if it is correct and minimal.
For any suggestion you decline, post a reply comment stating the reason (e.g. "Declined: this
breaks the null contract established in `X`"). Never apply a suggestion blindly.

## Conflicting Asks

Two comments demanding incompatible changes to the same code → do not silently pick one. State both
asks and escalate for the human to decide.

## After Addressing

- One focused commit per concern; scope limited to the comment's subject.
- Reply to resolved threads where a reply adds clarity (especially declines).
- Re-check that the change did not break checks before moving to the approval lane.

## Outcome Ledger (one outcome per comment)

Every substantive comment ends the pass with **exactly one** recorded outcome. This is what makes a
later pass resumable and stops the same comment being re-processed.

| Outcome | Recorded as |
|---------|-------------|
| **fixed** | Reply `Closed in <sha7> (C1)` naming the commit and the finding id; mark the thread resolved |
| **declined** | Reply `Declined (C1): <reasoning>`; mark resolved only if the reviewer agrees |
| **escalated** | Reply stating what the human must decide; leave unresolved |
| **not-substantive** | No reply needed; no action |

Rules:

- Mark addressed threads resolved where the platform allows it (see
  [gh-commands.md](gh-commands.md)).
- On a later pass, a comment carrying a recorded outcome is **not** re-processed, unless the author
  replied again after that outcome.
- Report the ledger: one line per comment with its outcome.
