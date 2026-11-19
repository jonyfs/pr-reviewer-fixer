# Communication and merge handling, 0.20.0

Status: design for release 0.20.0. Written before the change, kept as the record of why.

Later in the same release, agent comments became plain text: the banners lost their emoji, and
the tables, checkboxes, headings and Mermaid charts this design puts in comments became labelled
lines. `pr-protocol.md` and `report-contract.md` describe the current layout; the rows below are
the original design.

## Goal

A person who opens a pull request after the automatic review should, in under a minute, know:

1. who wrote each comment (the reviewer, the fixer, or the merge fixer) and that it actually ran;
2. whether the pull request can merge, and what blocks it;
3. what was fixed, commit by commit, with the evidence;
4. what they still have to decide.

Merge conflicts that the agents can resolve must not reach that person at all.

## Constraints that shape the design

| Constraint | Why it limits the design |
|---|---|
| `pr-json.py`, `review-cycle.sh findings-block` and the filters read markers at the start of a comment, and the findings block must be the last fenced block | Banners and emoji go after the marker line, never before it. Nothing is wrapped around the findings block |
| `scan-hidden.py` reports `<details>`, HTML comments other than the markers and runs of variation selectors in PR comments, and a hit is a candidate CRITICAL | No `<details>` in any agent comment. No emoji that carry U+FE0F (`⚠️`, `✔️`, `ℹ️`). Use `🔴 🟡 🔵 ✅ ⛔ 🔧 🤖 🧭` instead, which carry no selector |
| GitHub rejects a comment over 65536 characters; `publish` refuses a marker plus report over 60000 bytes | Tables are cheap in bytes. Long prose still moves to an overflow comment |
| Each skill installs alone, so shared scripts and shared references are copies | The merge fixer gets its own copies; `run-all.sh` checks every copy |
| Skills never call each other; they talk through the pull request | The merge fixer is dispatched by the review loop agent, not by `pr-fixer`. Its artifacts are a closure comment and a label-free marker |
| Every push moves the head, and the gate needs a verdict at the head | After a merge push the reviewer always runs again. The re-review scope is narrowed by hunk list, never by skipping the review |

## Improvements

### Reviewer report (`pr-reviewer`)

| # | Improvement | Where |
|---|---|---|
| 1 | Banner under the marker: `🤖 Written by pr-reviewer · pass N · head sha`, so a reader knows who wrote the report | `report-contract.md`, `SKILL.md` Output |
| 2 | Summary table at the top: verdict, counts, blocking count, head, next action | `report-contract.md` |
| 3 | Acceptance conditions as checkboxes (`- [ ]` open, `- [x]` met), never rewritten | `report-contract.md` |
| 4 | Findings as tables per severity (id, location, dimension, claim), with the detail as short sections below. No `<details>` | `report-contract.md` |
| 5 | A "How to read this review" block of three bullets for the human who reviews after the agent | `report-contract.md` |
| 6 | Mermaid pass-history chart in the verdict comment, placed before the findings block | `report-contract.md` |
| 7 | One emoji legend (`🔴 CRITICAL`, `🟡 WARNING`, `🔵 NOTE`, `✅ PASSED`, `⛔ BLOCKED`), defined once, with no selector characters | `pr-protocol.md`, `report-contract.md` |
| 8 | Coverage as a table of review units: unit, effort, status (`run`, `deferred`, `not run`) | `report-contract.md` |
| 9 | Prior findings on re-review as a table: id, status, evidence | `report-contract.md` |
| 10 | Summary cut to at most three lines, with the one thing to fix first in bold | `report-contract.md` |

### Fixer closure (`pr-fixer`)

| # | Improvement | Where |
|---|---|---|
| 11 | Banner `🔧 Written by pr-fixer · cycle C · ran at <time>`, so the reader knows the fixer executed and did not only plan | `falsify-and-prove.md` |
| 12 | Checkpoint list per finding: reproduced, test written, red seen, fix, green seen, suite green. Each a checkbox with the evidence next to it | `falsify-and-prove.md` |
| 13 | Commit table: sha, finding id, message, files touched | `falsify-and-prove.md` |
| 14 | Refusals as a table with the evidence line that refutes the finding | `falsify-and-prove.md` |
| 15 | Debt as a table with owners, mirrored in the PR body block | `falsify-and-prove.md` |
| 16 | A "What changed since last pass" line, so the reviewer and the human see the delta first | `falsify-and-prove.md` |

### Shared and status comments

| # | Improvement | Where |
|---|---|---|
| 17 | Status comment as a small table (state, skill, pass or cycle, head, agents and tiers) | `progress-and-notifications.md` |
| 18 | Fixed order for every agent comment: marker, banner, summary, detail, next action | `pr-protocol.md` |
| 19 | Scanner-safe formatting rule written down: no `<details>`, no FE0F symbols, no HTML comments besides markers | `pr-protocol.md`, `AGENTS.md` |
| 20 | Mermaid used where it adds a picture (cycle state, merge plan), never for a list a table already shows | `report-contract.md`, `falsify-and-prove.md` |

### Merge handling (new `pr-merge-fixer`)

| # | Improvement | Where |
|---|---|---|
| 21 | New skill `pr-merge-fixer`: resolves conflicts with the base before review, and after a PASSED verdict if the base moved | `.agents/skills/pr-merge-fixer/` |
| 22 | Conflict classes with a resolution ladder: lockfile and generated (regenerate, no model), textual overlap (fast tier), semantic overlap (deep tier), security-sensitive and contract (escalate) | `pr-merge-fixer/references/conflicts.md` |
| 23 | Orchestration rule: each conflict unit chooses its tier from the classification, and the choice is written in the closure table | `pr-merge-fixer/references/orchestration.md` |
| 24 | Always re-review after a merge push. The reviewer's focus list is the list of resolved hunks, and it still reads the whole diff | `harness-loop.md`, `pr-protocol.md` |
| 25 | Closure comment `pr-merge-fixer-closure` with a per-file table: file, class, tier, resolution, evidence | `pr-merge-fixer/SKILL.md`, `pr-protocol.md` |
| 26 | `pr-fixer`'s conflict lane becomes a handoff to the merge fixer, so one playbook exists | `pr-fixer/references/conflicts.md`, `pr-fixer/SKILL.md` |

### Install and plumbing

| # | Improvement | Where |
|---|---|---|
| 27 | `install.sh` installs all three skills by default; `--skill both` keeps its meaning of the two original skills | `install.sh`, `README.md` |
| 28 | `run-all.sh` checks shared scripts and references in the three skills | `tests/run-all.sh` |

## Decisions taken

- **No new label.** The merge fixer reads and writes what the reviewer and the fixer already use, so `ensure-labels` and the gate do not change.
- **Escalation without a new state.** When the merge fixer must escalate, it posts its closure with `escalated` and the loop asks the person in the session, as it does for any other stop.
- **Budget unchanged.** A merge push after a verdict creates a new pass, which counts toward the budget under the existing rules. This is stated in the merge skill, not hidden.
- **Models by tier.** No model ID is written in the new skill. The tier and the harness column come from `execution-profiles.md` and `harness-matrix.md`, as the other two skills do.
- **Version 0.20.0.** Minor: a new skill and a new marker that existing installs can ignore. No existing marker, label or subcommand changes meaning.
