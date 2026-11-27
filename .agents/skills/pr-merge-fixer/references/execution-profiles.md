---
Summary: Tier, model and reasoning effort for each conflict unit of pr-merge-fixer, and the per-harness setting for each tier. The single place these are stated for this skill.
Tags: [#pr #merge #models #effort #reference]
---

# Execution Profiles

Model names change monthly. The harness column was checked on **2026-11-27** against official docs
([harness-matrix.md](harness-matrix.md) dates each source and lists the unverified items; only the
Claude Code pages were re-opened on that date, the others on 2026-10-14). Prefer aliases where the
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
| Security-sensitive file | deep | only when a person allowed the class | Classified at deep, never lower. Posture rules 3 and 8 still hold: the file escalates to a person, and it is resolved, at deep, only when a person set `PUSH_GUARD_ALLOW_SENSITIVE` for that class. A fast-tier fix to a signal-handling script shipped a bug the next review blocked (commit 4061e69) |

A file is security-sensitive when `scripts/path-floor.sh` gives it security at `max`, or when it is
a script that handles signals, sandboxes, the gate, push guards or tokens (`review-cycle.sh`,
`push-guard.sh`, `repro-sandbox.sh`, `proof-check.sh`, `behaviour-diff.sh`,
`gate-pr-review-state.py`, `path-floor.sh`, `scan-hidden.py`, `templates/review-gate.yml`). The
reviewer's `execution-profiles.md` states the same row.

## Per-harness setting

| Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode |
|---|---|---|---|---|---|
| deep | `model: opus`, `effort: high`, `isolation: worktree` | `gpt-6.1-sol`, `high`, `workspace-write` | Opus 5.5, `--effort=high` | `claude-opus-5[effort=high]` | opus-class, `reasoningEffort: high` |
| standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | sonnet-class, `medium` |
| fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` | Haiku 5.5 or GPT-6 Luna, `low` | Haiku 5.5 or composer | haiku-class, `low` |

## Applying a profile

Pass `model`, `effort` and the profile (`writer`, or `read-only probe` for a unit that only runs a
check) as call parameters on every dispatch; never inherit. Declaring them in frontmatter alone
does nothing where the harness reads them from the call. On Claude Code the call's `model` is an
alias, not a full id or `inherit`, and the per-call `effort` needs v2.1.292 or later
([sub-agents](https://code.claude.com/docs/en/sub-agents), checked 2026-11-27). A read-only probe
runs commands and writes only inside the scratchpad path its brief names, never in the repository:
its working directory, `TMPDIR` and `XDG_CACHE_HOME` are under that path, it makes no commit, push or
comment, and it returns the commands it ran, their exit codes and the deciding output. On Claude Code
that limit is set by the brief and the environment, not by the tool list. Each unit writes only its own files; one
agent makes the commit.

## Fallbacks

| Situation | Behaviour |
|---|---|
| Harness rejects the declared model or effort | Report it, dispatch at `standard` or the session default, note the substitution |
| A unit has no tier here | Escalate it. Do not dispatch it |
| Harness without per-subagent control | Run the units in one agent, deepest first, and say so in the start line |
