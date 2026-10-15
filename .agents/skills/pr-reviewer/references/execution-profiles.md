---
Summary: Tier, model and reasoning effort for each review unit and the per-harness setting for each tier. The single place these are stated.
Tags: [#pr #review #models #effort #reference]
---

# Execution Profiles

Stated here and nowhere else. SKILL.md and the dispatch reference point to this file, so the copies
cannot drift. Model names change monthly: the harness column was retrieved on **2026-10-14** from
official docs ([harness-matrix.md](harness-matrix.md) lists sources and unverified items). Re-check
before relying on an id, and prefer aliases where the harness has them.

## Tiers

| Tier | Use when | Model class | Effort |
|---|---|---|---|
| **deep** | A miss here is silent and costly: reasoning across files, adversarial thinking | Flagship | high (max only for a dedicated security sweep) |
| **standard** | Bounded analysis against a clear scope | Mid | medium |
| **fast** | Pattern checks, transcription, merging already-decided facts | Small | low |

The tier follows the cost of being wrong and how long a miss stays invisible, never the size of
the task. A long job that fails loudly is cheap; a short judgement that fails silently is not.
A cheap model returns eloquent findings instead of true ones, which is worse than no review.

Two axes, assigned independently. Model tracks reasoning depth. Effort tracks the cost of a wrong
answer. They do not always move together.

## Units

| Unit | Stance | Tier | Why |
|---|---|---|---|
| Security | Security Auditor | deep | Misses here are exploitable. Low effort misses real bugs |
| Design / architecture | Architect | deep | Highest-leverage findings; needs the whole system in mind |
| Correctness | Saboteur | deep | Core of the review; edge and failure-path tracing |
| Concurrency | Saboteur | deep | Interleavings are easy to get plausibly wrong |
| Error handling | Saboteur | standard | Bounded by the changed paths |
| Performance | Saboteur | standard | Only flag with evidence |
| API / back-compat | Security Auditor | standard | Contract diff against a known surface |
| Testing | New Hire | standard | Judge whether tests would fail when code breaks |
| Complexity | New Hire | standard | Judgement, but local |
| Dependencies | Security Auditor | standard | Changelog and CVE lookup, bounded |
| Readability | New Hire | fast | Pattern checks |
| Docs | New Hire | fast | Pattern checks |
| Observability | Saboteur | fast | Pattern checks |
| Orchestrator (merge, verify, count) | none | standard | Deep reasoning was spent in the units; merging is bounded |
| Pass 2 re-check | per unit | same tier as the unit that raised the item | A cheaper re-check can miss what the original caught |

Escalate one tier on the second failure of the same unit instead of raising effort blindly. Raise
`security` to `max` only for changes that touch authentication, authorisation, cryptography or
parsing of untrusted input.

## Per-harness setting

| Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode | Antigravity / Gemini |
|---|---|---|---|---|---|---|
| deep | `model: opus`, `effort: high` (`fable` if budget allows) | `gpt-6.1-sol`, `model_reasoning_effort = "high"` | Claude Opus 5.5 or GPT-6.1 Sol, `--effort=high` | `claude-opus-5[effort=high]`, `readonly: true` | `<provider>/<opus-class>`, `reasoningEffort: high` | Gemini 4 Argon, `--effort high` |
| standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | sonnet-class, `medium` | Gemini 3.8 Flash |
| fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` | Haiku 5.5 or GPT-6 Luna, `--effort=low` | Haiku 5.5 or composer | haiku-class, `low` | Gemini 3.8 Flash, low |

Harnesses without per-subagent model control (Aider, Cline, Roo, Zed) run the whole review at the
`standard` setting and treat `deep` units as a second sequential pass with the effort raised.
Copilot's native code review has no model choice (Lite or Balanced); use Balanced.

## Applying a profile

Pass `model` and `effort` as call parameters on every dispatch. Frontmatter that declares them does
nothing in harnesses that read them only from the call, and the agent would silently run at the
session's settings.

## Fallbacks

| Situation | Behaviour |
|---|---|
| Harness rejects the declared model | Report it, dispatch at the `standard` model, note the substitution |
| Harness rejects the declared effort | Report it, dispatch at the session default, note the substitution |
| A unit has no row here | Refuse to dispatch it. Do not fall back to inheriting |
| Rate limit or budget cap reached | Run the `deep` units first; defer `fast` units and list them as not run |

When a substitution happens, the label shows what is in force, not what was declared. Declaring a
profile is not proof it ran: record the model and effort actually used in the report so the choice
is auditable.

## Changing a profile

Edit this file only, then re-check the harness column against current docs.
