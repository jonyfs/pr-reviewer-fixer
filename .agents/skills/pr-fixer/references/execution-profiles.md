---
Summary: Tier, model and reasoning effort for each fixer lane and the per-harness setting for each tier. The single place these are stated.
Tags: [#pr #fix #models #effort #reference]
---

# Execution Profiles

Stated here and nowhere else. Model names change monthly: the harness column was retrieved on
**2026-10-14** from official docs ([harness-matrix.md](harness-matrix.md) lists sources and
unverified items). Prefer aliases where the harness has them.

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
| Conflict resolution | deep | yes, history | A wrong semantic merge is silent. Run in an isolated worktree |
| Finding fix (CRITICAL) | deep, then standard once the red test exists | yes | Reasoning is in understanding the threat; the edit is bounded |
| Check repair | standard (deep after two failed attempts) | yes | Test output gives a tight loop |
| Comment fixes | standard | yes | Scoped edits with a stated intent |
| Comment triage, check classification | standard | no | Judgement over a bounded input |
| Debt declaration, issue sync, PR body | fast | PR body only | Transcribing decisions already made |

Escalate one tier after the second failed attempt on the same concern instead of raising effort
blindly, then escalate to a person at `max_attempts_per_concern`.

## Per-harness setting

| Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode |
|---|---|---|---|---|---|
| deep | `model: opus`, `effort: high`, `isolation: worktree` for conflicts | `gpt-6.1-sol`, `high`, `workspace-write` | Opus 5.5, `--effort=high` | `claude-opus-5[effort=high]` | opus-class, `reasoningEffort: high` |
| standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | sonnet-class, `medium` |
| fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` | Haiku 5.5 or GPT-6 Luna, `low` | Haiku 5.5 or composer | haiku-class, `low` |

## Applying a profile

Pass `model` and `effort` as call parameters on every dispatch; declaring them in frontmatter alone
does nothing where the harness reads them from the call. Writing lanes run with the narrowest
permission set that works: Codex `workspace-write`, Claude Code `acceptEdits` or `dontAsk` with a
tool allowlist, `maxTurns` where available. One writer per branch or worktree.

## Fallbacks

| Situation | Behaviour |
|---|---|
| Harness rejects the declared model or effort | Report it, dispatch at `standard` or the session default, note the substitution |
| A lane has no row here | Refuse to dispatch it |
| Harness without per-subagent control | Run lanes sequentially in one agent at the `standard` setting; raise effort for `deep` lanes |

The label shows what is in force, not what was declared.
