---
Summary: Tier, model and reasoning effort for each conflict unit of pr-merge-fixer, and the per-harness setting for each tier. The single place these are stated for this skill.
Tags: [#pr #merge #models #effort #reference]
---

# Execution Profiles

Model names change monthly. The harness column was retrieved on **2026-10-14** from official docs
([harness-matrix.md](harness-matrix.md) lists sources and unverified items). Prefer aliases where the
harness has them.

## Tiers

| Tier | Use when | Model class | Effort |
|---|---|---|---|
| **deep** | A wrong merge is silent and costly | Flagship | high |
| **standard** | Scoped edits with a tight feedback loop | Mid | medium |
| **fast** | Disjoint hunks, mechanical edits | Small | low |
| **none** | Regenerated or vendored output | no model | n/a |

## Units

| Unit | Tier | Writes | Why |
|---|---|---|---|
| Semantic conflict, or a cluster that shares a symbol | deep | yes, in an isolated worktree | A wrong semantic merge looks right in the diff |
| Textual overlap, rename | fast, standard after one failed check | yes | Disjoint edits with a clear reason |
| Lockfile, generated, vendored | none | yes, by regeneration | The output is produced, not written |
| Final verification (build and tests) | standard | no | Reads output and reports it |
| Closure table and comment | fast | no | Transcribes decisions already made |

## Per-harness setting

| Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode |
|---|---|---|---|---|---|
| deep | `model: opus`, `effort: high`, `isolation: worktree` | `gpt-6.1-sol`, `high`, `workspace-write` | Opus 5.5, `--effort=high` | `claude-opus-5[effort=high]` | opus-class, `reasoningEffort: high` |
| standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | sonnet-class, `medium` |
| fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` | Haiku 5.5 or GPT-6 Luna, `low` | Haiku 5.5 or composer | haiku-class, `low` |

## Applying a profile

Pass `model` and `effort` as call parameters on every dispatch. Declaring them in frontmatter alone
does nothing where the harness reads them from the call. Each unit writes only its own files; one
agent makes the commit.

## Fallbacks

| Situation | Behaviour |
|---|---|
| Harness rejects the declared model or effort | Report it, dispatch at `standard` or the session default, note the substitution |
| A unit has no tier here | Escalate it. Do not dispatch it |
| Harness without per-subagent control | Run the units in one agent, deepest first, and say so in the start line |
