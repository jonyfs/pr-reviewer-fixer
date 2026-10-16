# Harness model and effort matrix

Retrieved: 2026-10-14. All facts come from pages opened on that date (URLs in Sources). Model names here are the names those pages print. Where a page printed a display name but no API id, the id is marked `unverified`. Re-check before shipping: Codex retires GPT-5.5 for ChatGPT sign-in on 2026-10-14 and Copilot retired several models on 2026-10-02.

## Matrix

Tier shorthand: flagship = deep, mid = standard, fast = fast.

| Harness | Flagship | Mid | Fast | Effort / thinking control | Subagents and per-subagent model/effort | Read-only / sandbox / approval | Context that matters | Src |
|---|---|---|---|---|---|---|---|---|
| Claude Code | `fable` alias (Fable 5.1, id `claude-fable-5-1`); `opus` alias = Opus 5.5 | `sonnet` alias = Sonnet 5.5 | `haiku` alias = Haiku 5.5 | `--effort`, `/effort`, env `CLAUDE_CODE_EFFORT_LEVEL`, settings `effortLevel` or per-model `modelSettings`. Levels low, medium, high, xhigh, max. Default medium on Opus/Sonnet/Haiku 5.5, high on most others | Yes. Markdown subagent frontmatter has `model` (alias, full id, or `inherit`) and `effort`. Model order: per-call param, frontmatter, `CLAUDE_CODE_SUBAGENT_MODEL`, parent. Also `isolation: worktree`, `tools`, `disallowedTools`, `permissionMode` | `permissionMode`: default, acceptEdits, auto, dontAsk, bypassPermissions, plan. Tool allowlist per subagent for read-only | Opus 4.7+ and Sonnet 5/5.5 have native 1M window. Cursor and Kiro pages list 1M for the same models | 1, 2 |
| OpenAI Codex CLI | `gpt-6-astra` | `gpt-6.1-sol` (docs say use when available) | `gpt-6-luna` | `model_reasoning_effort` in config.toml: low, medium, high, xhigh, max, ultra (Luna up to max, no ultra). CLI `-m`/`--model`, `/model` for effort. Action input `effort` | Yes. `~/.codex/agents/*.toml` or `.codex/agents/*.toml` with `name`, `description`, `developer_instructions`, optional `model`, `model_reasoning_effort`. Defaults `agents.default_subagent_model`, `agents.default_subagent_reasoning_effort`, `agents.max_threads`. Subagents inherit sandbox from parent; cannot set `sandbox_mode` per agent | `sandbox_mode`: read-only, workspace-write, danger-full-access. `approval_policy`: on-request, never, granular table. Action: `permission-profile: ":workspace"` | `model_context_window` key exists; size per model `unverified` | 3, 4, 5 |
| GitHub Copilot CLI | Claude Opus 5.5, GPT-6 Astra, Fable 5.1 (display names; ids `unverified`) | Claude Sonnet 5.5, GPT-6.1 Sol | Claude Haiku 5.5, GPT-6 Luna, Gemini 3.8 Flash | `--effort=LEVEL` / `--reasoning-effort=LEVEL`: low, medium, high, xhigh, max (`max` for Anthropic only). Also user config. `/model` or `--model` | Custom agents with frontmatter `reasoningEffort` (low, medium, high; inherits if unset). Model per agent field: `unverified` | `--allow-tool`, `--deny-tool`, `--allow-all-tools`, `/allow-all`, Shift+Tab cycles standard/plan/autopilot | 1M window on selected models in VS Code and CLI only; configurable reasoning on VS Code, CLI, cloud agent | 6, 7 |
| Copilot cloud agent | Same catalog as above | same | same | Configurable reasoning available in cloud agent. Whether a model can be chosen depends on how the task starts | Custom agents and skills; per-agent model `unverified` | Works on one branch, one PR per task, repo-scoped | `unverified` | 6, 8 |
| Copilot code review | Not selectable | Not selectable | Not selectable | Review effort: Lite (faster) or Balanced (default, routes to a higher-reasoning model). "Model switching is not supported" | Not applicable | Review only; reads `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `AGENTS.md`, `.github/skills/` from head branch | No diff size limit documented | 9 |
| Gemini CLI | Gemini 4 Argon (as listed by Copilot, Cursor, Devin Desktop; Gemini CLI id `unverified`) | Gemini 3.8 Flash (also in Antigravity catalog) | Flash / Flash-Lite family. Gemini CLI model page (Mar 2026, stale) still lists `gemini-3-pro-preview`, `gemini-3-flash-preview`, `gemini-2.5-pro`, `gemini-2.5-flash` | Gemini CLI: no effort flag found. Antigravity CLI: `--effort`, `/effort`, `/model` gauge, picks model default if unset | Antigravity CLI keeps subagents; custom agent Markdown frontmatter has `model` (default `inherit`) and an `agents` list | Antigravity: `--mode auto`, plan review, terminal sandbox, `--dangerously-skip-permissions`. Gemini CLI approval flags: `unverified` (page did not cover) | `unverified` | 10, 11, 12 |
| Cursor | Claude Fable 5.1, Claude Opus 5.5, GPT-5.6 Sol, Gemini 4 Argon | Claude Sonnet 5.5, GPT-5.6 Terra | Claude Haiku 5.5, GPT-5.6 Luna, Composer 2.5, `composer-2`; explore subagent uses a faster model | Model parameter syntax `claude-opus-5[effort=high]`, `[context=300k]`. Bugbot: `review.effort` low, default, high, smart | Yes. Subagent frontmatter `model` (id or `inherit`), `readonly: true`, `is_background`. Legacy request-based plans run Composer regardless | `readonly: true` for subagents. Cursor Action `permissions: read-only` is validated but not enforced | Grok 4.7 default 256k, up to 500k. Opus 5.5 / Sonnet 5.5 up to 1M. Haiku 5.5 `unverified` | 13, 14, 15 |
| Windsurf (docs now redirect to Devin Desktop) | Claude Opus 5.5, GPT-6 Astra, GPT-6.1 Sol | Claude Sonnet 5.5 Medium (marked recommended), Gemini 4 Argon | GPT-6 Luna, Adaptive, SWE models (`unverified`), GLM-5.2 | Effort is part of the model variant name: Low, Medium, High, XHigh, Max, plus Fast (priority) variants at 2x credits | `unverified` | `unverified` | No context figures on page | 16 |
| Cline | Any BYOK model | Any BYOK model | Any BYOK model | CLI `--thinking none|low|medium|high|xhigh` (bare = medium); `-m/--model`; else last `/model` choice | `unverified` (not on pages opened) | `-p/--plan` starts Plan mode; `--auto-approve true|false` (default true); headless via `--json` or piped stdin | Provider dependent | 17 |
| Roo Code | Any BYOK model | same | same | `unverified` | Custom modes (`slug`, `roleDefinition`, `groups`); no model field in mode schema, "sticky" last model per mode | `groups`: read, edit, command, mcp; `fileRegex` limits editable files, which gives a read-only mode | Provider dependent | 18 |
| Aider | Any provider model | same | same | `--reasoning-effort` low, medium, high (OpenAI reasoning models); `--thinking-tokens` e.g. 8k, 0 disables; in chat `/reasoning-effort`, `/thinking-tokens` | No subagents found. `unverified` | Not covered on the page; `unverified` | Provider dependent | 19 |
| OpenCode | `provider/model-id` of any configured provider | same | same | Agent option keys pass through to provider, e.g. `"reasoningEffort": "high"` | Yes. Agents in `opencode.json` `agent` key or `.opencode/agents/*.md`; fields `model`, `mode` (primary, subagent, all), `permission` (ask, allow, deny), `reasoningEffort` | Per-agent `permission` such as `edit: deny`, `bash: deny` gives read-only | Provider dependent | 20, 21 |
| Amp | Modes Low, Medium, High, Ultra; each bundles model, effort, prompt, tools, oracle. Per-mode model not on page opened (`unverified`) | same | `--fast` flag; Raw Models picker pins main agent only | Effort is baked into the mode; no separate flag found | Five subagents (Search, Oracle, Librarian, Task, Read Thread), each with its own model, set on the Modes page | Execute mode `-x` headless; permission model for headless `unverified` | `unverified` | 22, 23 |
| Kiro | Claude Fable 5.1 (preview, 6x), Opus 5.5 (2.0x), GPT-5.6 Sol (4.4x) | Claude Sonnet 5.5 (1.3x), GPT-5.6 Terra (2.2x) | Claude Haiku 4.5 (0.4x), GPT-5.6 Luna (0.6x) | CLI `--effort` at launch, or `/model` Effort. Session only in V3 | Subagents exist; model per subagent `unverified` | Permissions page not opened; `unverified`. Headless mode with API key | 1M on Fable 5.1, Opus 5.5, Sonnet 5.5, GPT-5.6; 200K on Haiku 4.5, Opus 4.5 | 24, 25 |
| Zed | Any configured | same | same | Not documented on page opened | `agent.subagent_model` setting exists | `agent.default_model` (provider, model); profiles and tool permissions control read-only | `unverified` | 26 |
| JetBrains Junie | BYOK: Anthropic, OpenAI, Google, xAI, OpenRouter, or `junie_api_key` | same | same | No effort setting found for reviews | Not found | `silent_mode` runs without repo modification; GitHub template needs write perms | `unverified` | 27, 28 |

Not found / not covered: I found no evidence either way for a separate "Devin" CLI used by Windsurf users beyond the Devin Desktop docs. Gemini CLI itself is being replaced by Antigravity CLI for consumer tiers; see Triggering and Unverified.

## Tier mapping

Names are the ones the docs print today. Pin by alias where one exists so the mapping survives point releases.

### Job 1: read-only review dimension agents

| Dimension | Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | Antigravity / Gemini | OpenCode | Rationale |
|---|---|---|---|---|---|---|---|---|
| Security, design | deep | `model: opus` (or `fable` if budget allows), `effort: high`; use `max` only for security sweeps | `gpt-6.1-sol`, `model_reasoning_effort = "high"`; `gpt-6-astra` low for the hardest cases | Claude Opus 5.5 or GPT-6.1 Sol, `--effort=high` | `claude-opus-5-5[effort=high]` (id form `unverified`), `readonly: true` | Gemini 4 Argon, `--effort high` (id `unverified`) | `anthropic/<opus id>` with `reasoningEffort: high`, `permission edit: deny` | These dimensions miss real bugs at low effort; Claude docs name `max` as suited to vulnerability hunting but warn of overthinking |
| Correctness, tests | standard | `model: sonnet`, `effort: medium` | `gpt-6.1-sol`, `medium` | Sonnet 5.5, `--effort=medium` | Sonnet 5.5, `[effort=medium]` | Gemini 3.8 Flash | sonnet-class, `medium` | Day-to-day review with clear scope matches the vendor default |
| Docs, style, naming | fast | `model: haiku`, `effort: low` | `gpt-6-luna`, `low` or `medium` | Haiku 5.5 or GPT-6 Luna, `--effort=low` | Haiku 5.5 or composer, `readonly: true` | Gemini 3.8 Flash, low | haiku-class | Pattern checks need little reasoning; Codex docs recommend Luna for clear, repeatable tasks |
| Orchestrator that merges findings | standard | session model `sonnet`, `medium` | `gpt-6.1-sol` `medium` | same | same | same | same | Merging is bounded; deep reasoning was already spent in dimensions |

Enforce read-only structurally: Claude subagent `tools: Read, Grep, Glob`; Codex `sandbox_mode = "read-only"` on the parent (cannot be set per agent); Cursor `readonly: true`; OpenCode `permission` deny edit and bash. Do not rely on Cursor Action `permissions: read-only`, which is not enforced.

### Job 2: write-capable fixer lanes

| Lane | Tier | Claude Code | Codex CLI | Copilot CLI | Cursor | OpenCode | Rationale |
|---|---|---|---|---|---|---|---|
| Merge conflict resolution | deep | `opus`, `high`, `isolation: worktree` | `gpt-6.1-sol` `high`, `workspace-write` | Opus 5.5 `--effort=high` | Opus 5.5 `[effort=high]` | opus-class `high` | Wrong semantic merges are silent and costly |
| Failing-check repair | standard | `sonnet`, `medium` (raise to `high` if two attempts fail) | `gpt-6.1-sol` `medium` | Sonnet 5.5 `medium` | Sonnet 5.5 `medium` | sonnet-class `medium` | Test output gives a tight feedback loop, so medium is enough |
| Review-comment fixes | standard | `sonnet`, `medium` | `gpt-6.1-sol` `medium` | Sonnet 5.5 `medium` | Sonnet 5.5 `medium` | sonnet-class `medium` | Scoped edits with a stated intent |
| Issue-sync / transcription | fast | `haiku`, `low` | `gpt-6-luna` `low` | Haiku 5.5 / GPT-6 Luna `low` | Haiku 5.5 / composer | haiku-class `low` | Mechanical copying; cheap model, verify by diff |

Rules for all lanes: one writer per branch or worktree; run the same permission-restricted sandbox (`workspace-write` on Codex, `acceptEdits` or `dontAsk` with an allowlist on Claude Code); cap with `maxTurns` where available; escalate one tier on a second failure instead of raising effort blindly.

## Isolating the fixer's test run

The fixer runs the project's tests, which execute repository code. A script cannot sandbox the
agent's own tool calls, so the harness has to. These are the controls this file already records
(retrieved 2026-10-14); nothing here was re-tested.

| Harness | Control | Notes |
|---|---|---|
| Claude Code | `acceptEdits` or `dontAsk` permission mode with an allowlist; `isolation: worktree` for a subagent | The allowlist should name the project's test command and nothing broader. |
| Codex CLI | `sandbox_mode = "workspace-write"`, `approval_policy` set to `on-request` | Subagents inherit the parent's sandbox and cannot set their own. In the action, `permission-profile: ":workspace"`. |
| Copilot CLI, Cursor, OpenCode | `unverified` | Check the harness's own permission settings before running the fixer. |
| Gemini CLI | `unverified` | The page did not cover approval flags. |

Whatever the harness, run the fixer on branches you trust, in a checkout without long-lived
credentials.

## Dispatching the review loop

The review loop agent runs in the person's own session and dispatches the reviewer and the fixer as
fresh-context sub-agents, using the facility in the "Subagents and per-subagent model/effort" column
of the matrix above (see [harness-loop.md](harness-loop.md)). No GitHub Action runs a model.

| Harness capability | What the loop agent does |
|---|---|
| Subagents with a per-agent tool list | Dispatch the reviewer with read-only tools and the fixer with write tools |
| Subagents without a per-agent tool list | Dispatch both, and enforce read-only on the reviewer by instruction; say the enforcement is by instruction |
| No subagents (Aider, some Cline and Roo setups) | Run the reviewer in a new session with the same checkout, then the fixer in another, and say the contexts were separated by session, not by sub-agent |
| Copilot native code review, Cursor Bugbot | Not part of this loop: no model choice and no marker. Treat their comments as review comments for the comment lane |

## Unverified

- Exact API model ids for Copilot, Cursor, Windsurf, Kiro and Gemini entries; the pages print display names only. Verified ids: Claude Code `claude-fable-5`, `claude-fable-5-1`, `claude-opus-5-5`; Codex `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6-luna`, `gpt-5.5`; Cursor `composer-2`, `composer-2.5`, `claude-opus-5`, `gpt-5.6-sol`.
- Copilot custom-agent `model` field; Copilot cloud agent context size; per-model Codex context sizes.
- Gemini CLI approval flags and current default model ids.
- Amp per-mode model table (the modes page returned 404; the Dial page says to see Modes).
- Windsurf subagents, sandbox, PR review; whether Windsurf is renamed to Devin Desktop (the page does not say).
- Cline subagents and Action; Roo Code effort control; Aider subagents and sandbox; Zed effort and read-only profile; Junie effort and PR-open trigger; Kiro per-subagent model and permissions.
- Roo Code activity status: no sunset notice found on the page opened, but I did not check the repository for activity.
- Usage ranking: I did not find a source for "top 5 by usage", so I added no extra harness beyond the requested list. Devin Desktop and Antigravity CLI appear only as renamed or successor products.
- Antigravity CLI dated changelog entries: the page gave versions without dates and was truncated after 100000 characters.
- No Codex page opened stated the effective context window for gpt-6.* models.

## Sources

1. https://code.claude.com/docs/en/model-config (aliases, effort, defaults, context)
2. https://code.claude.com/docs/en/sub-agents (frontmatter, model resolution)
3. https://learn.chatgpt.com/docs/models (redirect target of developers.openai.com/codex/models; models, retirements)
4. https://learn.chatgpt.com/docs/agent-configuration/subagents
5. https://learn.chatgpt.com/docs/config-file/config-reference
6. https://docs.github.com/en/copilot/reference/ai-models/supported-models
7. https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference (permissions; effort flag and `reasoningEffort` read from search excerpt of this page)
8. https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent
9. https://docs.github.com/en/copilot/concepts/agents/code-review
10. https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/
11. https://geminicli.com/docs/cli/model/ and https://github.com/google-gemini/gemini-cli
12. https://github.com/google-antigravity/antigravity-cli/blob/main/CHANGELOG.md
13. https://cursor.com/docs/subagents and https://cursor.com/docs/models
14. https://cursor.com/docs/bugbot (search excerpt)
15. https://github.com/marketplace/actions/cursor-action
16. https://docs.devin.ai/desktop/models (redirect from docs.windsurf.com/windsurf/models)
17. https://docs.cline.bot/getting-started/what-is-cline and https://docs.cline.bot/cline-cli/overview
18. https://roocodeinc.github.io/Roo-Code/features/custom-modes
19. https://aider.chat/docs/config/reasoning.html
20. https://opencode.ai/docs/agents/
21. https://opencode.ai/docs/github/
22. https://ampcode.com/manual and https://ampcode.com/docs/models-and-subagents
23. https://ampcode.com/docs/cli/execute-mode
24. https://kiro.dev/docs/cli/ and https://kiro.dev/docs/cli/chat/model-selection/
25. https://kiro.dev/docs/models/available-models/
26. https://zed.dev/docs/ai/agent-settings
27. https://junie.jetbrains.com/docs/junie-on-github.html
28. https://junie.jetbrains.com/docs/automated-code-reviews.html (search result summary only)
29. https://code.claude.com/docs/en/github-actions
30. https://learn.chatgpt.com/docs/github-action (search excerpt)
