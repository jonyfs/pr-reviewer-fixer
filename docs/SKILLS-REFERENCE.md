# Skills reference

Facts you look up while using the skills: commands, labels, markers, settings. For the reasons
behind them, read [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

## The three skills

| Skill | Use it when | Ask for it with | Ends with |
|---|---|---|---|
| `pr-reviewer` | A pull request was opened or pushed, or you want a second opinion | "review PR #12" | `PASSED` or `BLOCKED` |
| `pr-fixer` | The verdict is `BLOCKED`, a comment needs an answer, or CI failed | "fix the findings on #12" | A closure comment, one line per finding |
| `pr-merge-fixer` | The branch conflicts with its base | "resolve the conflicts on #12" | A merge comment with a table of files |

The review loop agent, the coding agent in your session, starts these on its own after a pull request
is opened or pushed. You can also start any of them by hand.

## Install

| `--harness` | Project folder | User folder |
|---|---|---|
| `claude-code` | `.claude/skills` | `~/.claude/skills` |
| `codex`, `amp`, `zed` | `.agents/skills` | `~/.agents/skills` (amp: `~/.config/agents/skills`) |
| `copilot` | `.github/skills` | `~/.copilot/skills` |
| `gemini` | `.gemini/skills` | `~/.gemini/skills` |
| `cursor` | `.cursor/skills` | `~/.claude/skills` |
| `opencode` | `.opencode/skills` | `~/.config/opencode/skills` |
| `roo` | `.roo/skills` | `~/.roo/skills` |
| `cline` | `.cline/skills` | `~/.cline/skills` |
| `kiro` | `.kiro/skills` | `~/.kiro/skills` |
| `windsurf` | `.windsurf/skills` | `~/.codeium/windsurf/skills` |
| `junie` | `.junie/skills` | `~/.junie/skills` |
| `goose` | `.agents/skills` | `~/.agents/skills` |
| `qwen` | `.qwen/skills` | `~/.qwen/skills` |
| `crush` | not supported | `~/.config/crush/skills` |
| `continue` | `.continue/<skill>/` | `~/.continue/<skill>/` |
| `trae` | `.trae/skills` | `~/.trae/skills` (third-party sources; check Trae's docs) |
| `factory` | `.factory/skills` | `~/.factory/skills` |

`--harness auto` finds the harnesses whose marker is present (for example `.cursor` or `~/.cursor`) and installs into each. `--harness a,b` runs one install per harness.

Options:

| Option | Meaning |
|---|---|
| `--yes` | Really install. Without it, you only see the plan |
| `--scope user` | Install under your home folder instead of the project |
| `--skill all` | Default. The three skills |
| `--skill both` | The 0.19 pair: `pr-reviewer` and `pr-fixer` |
| `--skill pr-reviewer,pr-merge-fixer` | Any comma-separated list |
| `--target <dir>` | Install into a folder you name, without a harness |

Aider has no skills feature, so `install.sh` refuses it and tells you why.

## Labels

| Label | Meaning | Set by |
|---|---|---|
| `review:pending` | Owed: the head has moved past the last verdict | `stale` |
| `review:running` | A review is in progress | `start` |
| `review:passed` | The verdict at the head is `PASSED` | `publish` |
| `review:blocked` | The verdict at the head is `BLOCKED` | `publish` |
| `review:fixing` | A correction is in progress | `fix` |
| `review:needs-human` | The loop stopped and a person must decide | `halt` |

No label means "not reviewed", never "approved". Create the labels once with `ensure-labels`.

## Comment markers

Each agent comment starts with one marker line. The scripts read these markers, so keep them first.

| Marker | Written by | Meaning |
|---|---|---|
| `<!-[-] adversarial-review: sha=… verdict=… pass=… -->` | reviewer | The verdict for one commit, with its counts |
| `<!-[-] pr-fixer-closure: cycle=… head=… -->` | fixer | Its work in one cycle |
| `<!-[-] pr-merge-fixer-closure: head=… resolved=… escalated=… -->` | merge fixer | The conflicts it resolved or escalated |
| `<!-[-] pr-skill-status: skill=… … -->` | any | The live status of one run, edited in place |
| `<!-[-] pr-skill-extension: state=granted\|halted … -->` | `extend` or `halt` | Your answer to the cycle question |

Only comments from a login in `REVIEW_MARKER_AUTHORS` count, and an edited comment does not count.

## Findings and severity

| Severity | Meaning | Blocks by default? |
|---|---|---|
| 🔴 CRITICAL | Data loss, a security breach, an outage, or a broken rule the project declares non-negotiable | Yes |
| 🟡 WARNING | A likely bug in an edge case, or a missing test for new logic | Only with `REVIEW_BLOCK_AT=warning` |
| 🔵 NOTE | Style, a documentation gap, a question | No |

A critical finding must include a failing scenario. A warning that blocks must include a `scenario:`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `REVIEW_MARKER_AUTHORS` | none, which refuses to run | Logins whose comments count as reports |
| `REVIEW_BLOCK_AT` | `critical` | Set to `warning` to make warnings block too |
| `MAX_REVIEW_CYCLES` | 5 | Automatic fix cycles before the agent asks you |
| `MAX_REVIEW_CYCLES_HARD` | 10 | The ceiling no answer can pass |
| `FIXER_TRUSTED_LOGINS` | none | Bot logins whose review comments the fixer may act on |
| `PUSH_GUARD_ALLOW_SENSITIVE` | none | Lets the fixer touch a sensitive class of file, such as `skills`. Set it yourself, only when you mean to |
| `PR_SKILLS_NO_UPDATE_CHECK` | unset | Set to `1` to stop the update notice |

## Scripts

All scripts live in each skill's `scripts/` folder.

| Command | What it does |
|---|---|
| `review-cycle.sh status <pr>` | Shows the state of the review at the head |
| `review-cycle.sh stale <pr>` | Moves a label to `review:pending` when the head has moved past it |
| `review-cycle.sh budget <pr>` | Says what the loop does next: `fix`, `ask`, `none` or `ceiling` |
| `review-cycle.sh screen --staged` | Checks what you are about to commit for tokens and private keys |
| `review-cycle.sh lint-report <pr> --report FILE` | Checks a report before it is published |
| `review-cycle.sh publish …` | Publishes the verdict for the head (reviewer only) |
| `review-cycle.sh extend <pr> --n N` | Grants more cycles after your answer |
| `review-cycle.sh halt <pr> --reason …` | Stops the loop and asks for a person |
| `review-cycle.sh export-sarif <pr> [--out FILE]` | Writes the verdict's open findings as SARIF 2.1.0, for you to upload; uploads nothing |
| `push-guard.sh <pr>` | Checks a push before it happens (fixer and merge fixer) |
| `proof-check.sh --pr <pr>` | Re-runs the proofs a fixer closure claims and compares exit codes (fixer; needs an allowlist you set) |
| `behaviour-diff.sh <base> <head> <probes>` | Runs the same probes before and after a fix and flags changes no finding names (fixer only) |
| `fix-ledger.sh --since DATE` | Records how many fixer commits were kept in a local ledger; `audit` checks how many refusals were wrong (fixer only) |
| `review-metrics.sh agreement R1 R2 …` | Compares k reports of one head and flags dimensions whose findings do not come back (reviewer only) |
| `review-metrics.sh scorecard --since DATE` | Counts findings raised, verified, refused and left as debt per dimension and per model, from trusted markers (reviewer only) |
| `REVIEW_REPRO=1 repro-sandbox.sh --repo DIR --sha SHA --expect fail -- CMD` | Runs a CRITICAL candidate's repro in a no-network sandbox and prints `repro: reproduced`, `not-reproduced` or `skipped`; refuses with exit 4 where no sandbox works (reviewer only, opt-in) |
| `check-version.sh` | Prints a notice when a newer release exists. It never installs |
| `update.sh --yes --version X` | Updates the installed skills after you say yes |

Run any script with no arguments, or with `--help` where it has one, to see its usage.

## Glossary

- **Head**: the commit at the tip of the pull request branch.
- **Pass**: one verdict from the reviewer. Pass 1 is the first.
- **Cycle**: one fix attempt by the fixer, between two passes.
- **Closure**: the comment the fixer or merge fixer posts when it finishes.
- **Debt**: a warning or note recorded with an owner, in the `pr-debt` block of the PR body.
- **Trusted marker**: a comment from an allowed login, never edited after it was posted.
