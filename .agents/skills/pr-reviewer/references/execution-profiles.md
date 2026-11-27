---
Summary: Tier, model and reasoning effort for each review unit and the per-harness setting for each tier. The single place these are stated.
Tags: [#pr #review #models #effort #reference]
---

# Execution Profiles

Stated here and nowhere else. SKILL.md and the dispatch reference point to this file, so the copies
cannot drift. Model names change monthly: the harness column was checked on **2026-11-27** against
official docs ([harness-matrix.md](harness-matrix.md) dates each source and lists the unverified
items; the Claude Code pages were re-opened on that date, the others on 2026-10-14). Re-check before
relying on an id, and prefer aliases where the harness has them.

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
| Data integrity | Saboteur | deep | Summoned by the path floor for migrations and schema files: a lost or rewritten row is silent |
| Reliability | Saboteur | deep | Summoned by the path floor for infrastructure files; failure paths need tracing across calls |
| Privacy | Security Auditor | deep | A leak of personal data is not undone by a later fix |
| Scalability | Saboteur | standard | Needs evidence of growth, bounded by the changed queries and loops |
| Operability | Architect | standard | Summoned by the path floor for infrastructure files; judges rollout, rollback and diagnosis |
| Readability | New Hire | fast | Pattern checks |
| Docs | New Hire | fast | Pattern checks |
| Observability | Saboteur | fast | Pattern checks |
| Orchestrator (merge, verify, count) | none | standard | Deep reasoning was spent in the units; merging is bounded. A floor, not a default: see Orchestrator tier |
| Fixer and merge fixer on security-sensitive files | none | deep | A fixer commit to a signal-handling script, co-authored by a fast-tier model, shipped a signal-19 bug that the next review had to block (commit 4061e69). The miss is silent until a reviewer traces the path |
| Probe (a reproduction, a behaviour check, a timing run) | per the unit that asked for it | same tier as that unit | Runs under the read-only probe profile below |
| Pass 2 re-check | per unit | same tier as the unit that raised the item | A cheaper re-check can miss what the original caught |

Escalate one tier on the second failure of the same unit instead of raising effort blindly. Raise
`security` to `max` only for changes that touch authentication, authorisation, cryptography,
parsing of untrusted input, or the files that run CI or instruct an agent (workflows and the
scripts they run, actions, CODEOWNERS, every harness's skill folder, `.claude/**` and the other
agent directories at any depth, `.mcp.json`, `AGENTS.md`
and the other instruction files, Dockerfiles). `scripts/path-floor.sh` names those
paths; see the path floor in [agents-and-dispatch.md](agents-and-dispatch.md).

## Security-sensitive files

A file is security-sensitive when `scripts/path-floor.sh` gives it security at `max` (workflows,
agent folders and instruction files, and the authentication, authorisation, token and secret
names), or when it is one of the scripts that handle signals, sandboxes, the gate, push guards or
tokens: `review-cycle.sh`, `push-guard.sh`, `repro-sandbox.sh`, `proof-check.sh`,
`behaviour-diff.sh`, `gate-pr-review-state.py`, `path-floor.sh`, `scan-hidden.py` and
`templates/review-gate.yml`, in any skill. Every lane or unit that writes such a file runs at
`deep` with effort `high` for the whole lane: the step down to `standard` once a red test exists
does not apply, and a check repair on such a file starts at `deep`. The fixers' own profiles
repeat this row, because an installed fixer reads only its own folder. The merge fixer still
escalates these files to a person; the row sets the tier of the classification, and of the
resolution only when a person allowed that class with `PUSH_GUARD_ALLOW_SENSITIVE`.

## Read-only probe profile

A probe is a sub-agent that runs code to answer one question: a reproduction of a CRITICAL, a
behaviour check, a timing run. It may run commands and write files, but only inside the scratchpad
path its brief names, never in the repository. A read-only review agent cannot run a probe (it
holds no Bash), so an orchestrator that dispatched one had to rerun the decisive probe itself; the
probe profile closes that gap without giving the probe write access to the checkout.

| Aspect | Value |
|---|---|
| Name in a dispatch call | `profile: read-only probe` |
| Tools | Read, Grep, Glob, Bash. No Edit or Write on any path of the repository |
| Working directory | The scratchpad path in the brief. `TMPDIR` and `XDG_CACHE_HOME` point under it |
| Repository | Read only. A worktree the probe needs is made under the scratchpad (`git worktree add <scratchpad>/...`) and removed at the end; git's own record of it under `.git/worktrees` is the one write outside the scratchpad |
| Network, push, comments | None. No `git push`, no `gh` write, no comment |
| Tier | The tier of the unit that asked for the probe |
| Returns | The command lines it ran, their exit codes and the output that decides the question |

On Claude Code a sub-agent's tool list cannot scope writes to one folder. An `Edit(path)` permission
rule covers the built-in file tools, not a script that writes files itself, and OS-level sandboxing
is the person's setting, which the skill does not change ([harness-matrix.md](harness-matrix.md),
source 31). So the limit to the scratchpad is set by the brief, the working directory and the
environment: say so in the report. Codex `workspace-write` started with the scratchpad as its workspace would
make the limit structural ([harness-matrix.md](harness-matrix.md) lists the sandbox modes); that
use is not tested here. The brief template is in
[agents-and-dispatch.md](agents-and-dispatch.md) ("Probe brief").

## Orchestrator tier

The orchestrator (the session that dispatches, merges, verifies and publishes) needs at least the
`standard` tier. If the session model is below it (a `fast`-class model such as `haiku`), the start
line says so (`Orchestrator below standard: <model>`, see
[progress-and-notifications.md](progress-and-notifications.md)) and the merge and verify work moves
to one sub-agent dispatched at the `standard` setting, which returns the merged findings and the
verification for the session to publish. The skill never changes a person's settings (`/model`,
`settings.json`, environment) to raise the session's own tier.

## Per-harness setting

| Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode | Antigravity / Gemini |
|---|---|---|---|---|---|---|
| deep | `model: opus`, `effort: high` (`fable`, Fable 5.2, if budget allows) | `gpt-6.1-sol`, `model_reasoning_effort = "high"` | Claude Opus 5.5 or GPT-6.1 Sol, `--effort=high` | `claude-opus-5[effort=high]`, `readonly: true` | `<provider>/<opus-class>`, `reasoningEffort: high` | Gemini 4 Argon, `--effort high` |
| standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | sonnet-class, `medium` | Gemini 3.8 Flash |
| fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` | Haiku 5.5 or GPT-6 Luna, `--effort=low` | Haiku 5.5 or composer | haiku-class, `low` | Gemini 3.8 Flash, low |

Harnesses without per-subagent model control (Aider, Cline, Roo, Zed) run the whole review at the
`standard` setting and treat `deep` units as a second sequential pass with the effort raised.
Copilot's native code review has no model choice (Lite or Balanced); use Balanced.

## Reporting model and tier

When the reviewer publishes, it passes the model id the harness reports for the run and the tier it
used for the verdict-bearing units, as `review-cycle.sh publish ... --model <id> --tier
fast|standard|deep`. Use the id exactly as the harness prints it (letters, digits, dot, colon, dash,
underscore, at most 64 characters). If the run mixed tiers, report the highest tier that produced a
finding. If the harness does not report a model id, leave both flags out rather than guess: the
marker stays valid and the export shows them as absent. These values are self-attested and are
not checked by any script.

## Applying a profile

Pass `model`, `effort` and the profile as call parameters on every dispatch; never inherit.
Frontmatter that declares them does nothing in harnesses that read them only from the call, and the
agent would silently run at the session's settings. On Claude Code the Agent call's `model` takes an
alias (`opus`, `sonnet`, `haiku`, `fable`), not a full id or `inherit`, and the per-call `effort`
needs Claude Code v2.1.292 or later; without it a sub-agent takes the spawner's effort or
`CLAUDE_CODE_SUBAGENT_EFFORT` ([sub-agents](https://code.claude.com/docs/en/sub-agents), checked
2026-11-27). The aliases resolve to other models on Bedrock, Foundry and Claude Platform on AWS
([model-config](https://code.claude.com/docs/en/model-config)); record the model the harness reports.

## Fallbacks

| Situation | Behaviour |
|---|---|
| Harness rejects the declared model | Report it, dispatch at the `standard` model, note the substitution |
| Harness rejects the declared effort | Report it, dispatch at the session default, note the substitution |
| A person's environment forces a value (`CLAUDE_CODE_EFFORT_LEVEL`, or `CLAUDE_CODE_SUBAGENT_MODEL` with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`) | Dispatch as declared, leave the setting alone, and report the model and effort in force as a substitution |
| Session model below `standard` | Say it in the start line; merge and verify run in one `standard` sub-agent |
| A unit has no row here | Refuse to dispatch it. Do not fall back to inheriting |
| Rate limit or budget cap reached | Run the `deep` units first; defer `fast` units and list them as not run |

When a substitution happens, the label shows what is in force, not what was declared. Declaring a
profile is not proof it ran: record the model and effort actually used in the report so the choice
is auditable.

## Changing a profile

Edit this file only, then re-check the harness column against current docs.
