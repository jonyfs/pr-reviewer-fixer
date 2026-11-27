---
Summary: Tier, model and reasoning effort for each fixer lane and the per-harness setting for each tier. The single place these are stated.
Tags: [#pr #fix #models #effort #reference]
---

# Execution Profiles

Stated here and nowhere else. Model names change monthly: the harness column was checked on
**2026-11-27** against official docs ([harness-matrix.md](harness-matrix.md) dates each source and
lists the unverified items). Prefer aliases where the harness has them.

## Tiers

| Tier | Use when | Model class | Effort |
|---|---|---|---|
| **deep** | A wrong answer is silent and costly | Flagship | high |
| **standard** | Scoped edits with a tight feedback loop (tests) | Mid | medium |
| **fast** | Transcription, no judgement | Small | low |

## Lanes

| Lane | Tier | Writes | Why |
|---|---|---|---|
| Falsification of a CRITICAL | deep | no (reads, runs) | Deciding that a finding is false is the riskiest call in the cycle |
| Conflict resolution | handed to `pr-merge-fixer` (its own tiers) | no | Moved out in 0.20.0; see that skill's `orchestration.md` |
| Finding fix (CRITICAL) | deep, then standard once the red test exists | yes | Reasoning is in understanding the threat; the edit is bounded |
| Check repair | standard (deep after two failed attempts) | yes | Test output gives a tight loop |
| Comment fixes | standard | yes | Scoped edits with a stated intent |
| Comment triage, check classification | standard | no | Judgement over a bounded input |
| Debt declaration, issue sync, PR body | fast | PR body only | Transcribing decisions already made |
| Any lane on a security-sensitive file | deep, never lowered | yes | Overrides the rows above for that file: no step down to standard after the red test, and a check repair starts at deep. A fix to a signal-handling script co-authored by a fast-tier model shipped a signal-19 bug that the next review blocked (commit 4061e69) |
| Probe (reproduction, behaviour check, timing run) | the tier of the lane that asked for it | only inside its scratchpad | Runs under the read-only probe profile below |

A file is security-sensitive when `scripts/path-floor.sh` gives it security at `max` (workflows,
agent folders and instruction files, authentication, token and secret names), or when it is a
script that handles signals, sandboxes, the gate, push guards or tokens: `review-cycle.sh`,
`push-guard.sh`, `repro-sandbox.sh`, `proof-check.sh`, `behaviour-diff.sh`,
`gate-pr-review-state.py`, `path-floor.sh`, `scan-hidden.py` and `templates/review-gate.yml`. The
same row is stated in the reviewer's `execution-profiles.md`; this copy exists because an installed
fixer reads only its own folder.

Escalate one tier after the second failed attempt on the same concern instead of raising effort
blindly, then escalate to a person at `max_attempts_per_concern`.

## Read-only probe profile

A probe sub-agent may run commands and write files only inside the scratchpad path its brief names,
never in the repository: no Edit or Write on a repository path, no commit, no push, no comment. Its
working directory, `TMPDIR` and `XDG_CACHE_HOME` are under that path, and a worktree it needs is
made there. Name it on the call as `profile: read-only probe`. On Claude Code a tool list cannot
scope writes to one folder, so the limit is the brief, the working directory and the environment;
say so in the closure. The brief template is in [falsify-and-prove.md](falsify-and-prove.md)
("Probe brief").

## Per-harness setting

| Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode |
|---|---|---|---|---|---|
| deep | `model: opus`, `effort: high`, `isolation: worktree` for conflicts | `gpt-6.1-sol`, `high`, `workspace-write` | Opus 5.5, `--effort=high` | `claude-opus-5[effort=high]` | opus-class, `reasoningEffort: high` |
| standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | sonnet-class, `medium` |
| fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` | Haiku 5.5 or GPT-6 Luna, `low` | Haiku 5.5 or composer | haiku-class, `low` |

## Applying a profile

Pass `model`, `effort` and the profile (`writer` or `read-only probe`) as call parameters on every
dispatch; never inherit. Declaring them in frontmatter alone does nothing where the harness reads
them from the call. On Claude Code the call's `model` is an alias (`opus`, `sonnet`, `haiku`), not a
full id or `inherit`, and the per-call `effort` needs v2.1.292 or later
([sub-agents](https://code.claude.com/docs/en/sub-agents), checked 2026-11-27). Writing lanes run with the narrowest
permission set that works: Codex `workspace-write`, Claude Code `acceptEdits` or `dontAsk` with a
tool allowlist, `maxTurns` where available. One writer per branch or worktree.

## Fallbacks

| Situation | Behaviour |
|---|---|
| Harness rejects the declared model or effort | Report it, dispatch at `standard` or the session default, note the substitution |
| A person's environment forces the model or effort (`CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`) | Leave it alone; report what was in force. A security-sensitive lane that could not run at `deep` stops and escalates |
| A lane has no row here | Refuse to dispatch it |
| Harness without per-subagent control | Run lanes sequentially in one agent at the `standard` setting; raise effort for `deep` lanes |

The label shows what is in force, not what was declared.
