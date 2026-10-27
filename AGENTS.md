# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this repository is

Two Agent Skills, `pr-reviewer` and `pr-fixer`, plus the scripts that enforce their protocol. The skills live in `.agents/skills/` and nowhere else. Do not add copies or symlinks under `.claude/skills/`. Almost everything is prose (`SKILL.md` and `references/*.md`) read by a model at run time. The only executable code is a few shell and Python scripts, one gate workflow and one release workflow (whose logic is `.github/scripts/release.sh`). `README.md` has the full explanation, install table and caveats.

## Commands

```bash
bash tests/run-all.sh                                   # whole suite, no network
bash tests/fake-gh/run.sh .agents/skills/pr-reviewer/scripts       # review-cycle.sh + gate, one copy
bash tests/fake-gh/triage/run.sh .agents/skills/pr-fixer/scripts   # triage-pr.sh
bash tests/push-guard/run.sh .agents/skills/pr-fixer/scripts       # push-guard.sh, in a scratch git repo
python3 tests/feedback/t.py .agents/skills/pr-fixer/scripts        # fetch-feedback.py
bash tests/install/run.sh                                          # install.sh, in scratch directories
docker run --rm --privileged -v "$PWD":/src:ro -w /src debian:stable-slim bash tests/install/run.sh  # its Linux-only rows
bash tests/eval/selftest.sh                                        # the review eval scorer, on canned reports
bash tests/version/run.sh .agents/skills/pr-reviewer/scripts       # check-version.sh
bash tests/release/run.sh                                          # .github/scripts/release.sh, the release workflow's logic
bash tests/update/run.sh .agents/skills/pr-reviewer/scripts install.sh   # update.sh and check-version.sh --latest/--decline
python3 tests/budget/t.py .agents/skills/pr-reviewer/scripts       # budget, extend, halt
python3 tests/scan-hidden/t.py .agents/skills/pr-reviewer/scripts  # scan-hidden.py
```

`tests/run-all.sh` runs the suites at the same time. Each run uses its own scratch directory, named by `TEST_TAG` (`work-*/` and `state-*/`, both gitignored), so set a different `TEST_TAG` when you start two runs of the same suite together. `run-all.sh` puts a `TEST_TAG` you give it in front of each suite's own tag, so two runs of `run-all.sh` with different tags do not collide either. Every suite unsets `REVIEW_BLOCK_AT` and `PUSH_GUARD_ALLOW_SENSITIVE` when it starts, so a value exported in your shell does not change the results. `run-all.sh` runs the suites of the shared scripts once, from the reviewer's copy (the `cmp` checks at its end compare every script found in both skills' `scripts/` folders, so a new shared script needs no new line), and, outside a virtual environment, puts a link to the real `python3` first on `PATH`, since a pyenv or asdf shim costs a few hundred milliseconds per start.

The suite needs bash, python3, node, jq, git, curl, tar and sha256sum. It puts a fake `gh` first on `PATH` (`tests/*/bin/gh`, backed by `fakegh.py`), so nothing touches GitHub. There is no build or lint step. Workflows and templates are checked with `actionlint`, which is run by hand.

## Architecture

**The two skills never call each other.** They communicate only through the pull request: `review:*` labels, a verdict comment carrying `<!-- adversarial-review: sha=... verdict=... pass=... -->`, a fixer closure comment, a `pr-debt` block in the PR body, and extension answer comments. The artifact table in `README.md` lists each one, and `.agents/skills/pr-reviewer/references/pr-protocol.md` has the exact `gh` command to find it. Changing a marker or label format means updating both skills and the scripts.

**Mechanism lives in scripts, judgement lives in prose.**
- `scripts/review-cycle.sh` is the state machine: it owns labels, prints a report's findings block as JSON (`findings-block`, the one parser `lint-report` and `push-guard.sh` share), publishes the verdict bound to the head SHA (it re-reads the head from GitHub and refuses a stale `--sha`), refuses inconsistent verdict arithmetic (a `BLOCKED` with no CRITICAL, a `PASSED` with one), computes the cycle budget (`budget`, `extend`, `halt`), refuses to start a correction on code from a fork or a non-collaborator (`fix`), and exports audit records (`export-audit`).
- `scripts/gate-pr-review-state.py` is the check the `review-gate` required job runs.
- `scripts/pr-json.py` is the only way the scripts read a pull request. It drops comments edited after creation and fails closed. Every marker rule (allowlist must name a login, edited comments never read as a verdict but still counted for BLOCKED history and the highest pass) is decided on its output.
- `.agents/skills/pr-fixer/scripts/triage-pr.sh` decides what the fixer owes on a PR. The reviewer has no copy.
- `.agents/skills/pr-fixer/scripts/fetch-feedback.py` is the comment lane's work list: review threads, reviews and issue comments from GraphQL, with author association, thread state and the action the fixer may take (it acts only on OWNER, a MEMBER or COLLABORATOR with write access, the reviewer's login and `FIXER_TRUSTED_LOGINS`, and skips minimized comments, dismissed reviews and the inline comments of a dismissed review). It is the one script besides `pr-json.py` that reads pull request comments, and it fails closed the same way. The reviewer has no copy.
- `.agents/skills/pr-fixer/scripts/push-guard.sh` is the check the fixer runs before a push: right branch, no fork, fast-forward, every touched file in scope, no sensitive path (unless `PUSH_GUARD_ALLOW_SENSITIVE` names its class), and no secret in the added lines (through `review-cycle.sh screen --patch`). The reviewer has no copy.
- `scripts/check-version.sh` and `scripts/update.sh` (both skills) are the update path. The check
  prints one notice when a newer release exists and installs nothing. The agent then puts a yes/no
  question to the person in the session (the review loop agent asks once, before it dispatches; a
  dispatched sub-agent skips the notice, never asks and never updates); on yes it runs
  `update.sh --yes --version <version>` (the version the question named: the script refuses when
  the latest release is another one), on no `check-version.sh --decline <version>`. `update.sh` downloads the release archive,
  refuses one whose SHA-256 differs from `SHA256SUMS`, and runs that release's own `install.sh` with
  `--target` on the skills directory it sits in. The upstream address is fixed in it:
  `PR_SKILLS_DOWNLOAD_URL` and `PR_SKILLS_RELEASE_URL` are honored only with
  `--allow-custom-source`, and with either set and no flag it refuses. Both scripts print a custom
  source as scheme and host only, and `update.sh` drops `curl`'s own error text: a mirror URL can
  carry a token, and everything printed reaches the agent's transcript. Unlike the check, every
  failure in it is loud. A failure before `install.sh` runs leaves the old install as it was;
  `install.sh` keeps a skill's old copy when that skill's swap fails but swaps one skill at a time,
  so with both skills the first may already be replaced, and running `update.sh` again finishes the
  job. A PR comment never answers the question.
- `install.sh` at the repository root copies the skills into the folder a harness reads. Its harness table mirrors the install table in `README.md`; change both together. Without `--yes` it changes nothing.
- `scripts/scan-hidden.py` (both skills) reports invisible text in what the agents read: the diff's
  added lines, the PR title, body and comments (through `pr-json.py`), the commit messages and,
  with `--feedback-json`, the fixer's `fetch-feedback.py` list (review-thread comments, review bodies and issue comments). It
  strips nothing and excludes the protocol's own markers by exact regex, the verdict one imported
  from the gate.
- `scripts/path-floor.sh` (both skills) maps the paths a change touches to the review units that must run (CI and agent configuration, auth and crypto: security at `max`; migrations: security and data integrity; infrastructure and deployment files: security, reliability and operability; privacy-named paths: privacy; manifests and lockfiles: dependencies). `review-cycle.sh lint-report` runs it over the diff and refuses a report whose findings block `mandatory_units:` field does not list each unit as run, which is why it ships beside `review-cycle.sh` in both skills.
- `.github/scripts/release.sh` is what `.github/workflows/release.yml` runs: it creates, completes or publishes the release for `VERSION`, sets Latest only for the highest version, and refuses with a remedy when a tag or a release belongs to another commit. `tests/release/run.sh` drives it against the fake `gh`.
- `tests/eval/` holds seeded review cases and `score.py`, which prints recall and precision for reports a person produced in a harness session. `tests/run-all.sh` runs only the scorer's own tests, never a model.

**Shared files are duplicated on purpose.** `review-cycle.sh`, `gate-pr-review-state.py`, `pr-json.py`, `scan-hidden.py`, `path-floor.sh`, `check-version.sh`, `update.sh`, `templates/review-gate.yml`, `references/pr-protocol.md`, `references/harness-matrix.md` and `references/harness-loop.md` exist in both skill folders so each skill installs alone. Edit one copy and mirror it to the other. `tests/run-all.sh` fails if any of them differ. Other same-named references (`execution-profiles.md`, `operating-principles.md`, and so on) differ by design, one per skill.

**Who runs the loop.** The review and the fix run as sub-agents of the session's own agent, never in GitHub Actions. `.agents/skills/*/references/harness-loop.md` is the procedure. The only workflows are `templates/review-gate.yml` (a status check that runs no model; `.github/workflows/review-gate.yml` is this repository's copy of it, and `tests/run-all.sh` fails if the two differ) and `.github/workflows/release.yml` (which runs `.github/scripts/release.sh`).

**Cycle budget.** `MAX_REVIEW_CYCLES` (5) and `MAX_REVIEW_CYCLES_HARD` (10) are read by `review-cycle.sh budget`, which computes the next step from the trusted markers. The person answers the extension question in the session; `review-cycle.sh extend` and `halt` record the answer in a marker comment. A PR comment never grants cycles.

## The review loop

Review and correction are done by agents in the harness session you are running in, automatically, with no GitHub Actions workflow and no provider API key.

- After you open a pull request (`gh pr create`) or push to the branch of an open one, and before the turn ends, run the loop in `.agents/skills/pr-reviewer/references/harness-loop.md`. Do not wait to be asked.
- You are the review loop agent. You do not review or edit the code yourself in the loop. Dispatch the reviewer as a fresh-context, read-only sub-agent that follows `.agents/skills/pr-reviewer/SKILL.md`, and the fixer as a fresh-context sub-agent that follows `.agents/skills/pr-fixer/SKILL.md`. Drive the loop from `review-cycle.sh budget`.
- Open pull requests as drafts (`gh pr create --draft`). `review-cycle.sh publish --verdict PASSED` marks the pull request ready for review when the reviewer approves it. Do not run `gh pr ready` yourself.
- Set `REVIEW_MARKER_AUTHORS` to your `gh` login (`gh api user --jq .login`) and run `review-cycle.sh ensure-labels` once per repository.
- When the budget is spent, ask the person in the session. Never read an answer from a PR comment.
- Never merge, approve, tag or publish a release. A person does that.
- `push-guard.sh` refuses a fixer commit that touches `.agents/skills/**`, and this repository's
  fixes are mostly there. So the loop in this repository runs with
  `PUSH_GUARD_ALLOW_SENSITIVE=skills`, set by the person who owns the session (export it with
  `REVIEW_MARKER_AUTHORS`). It names `skills` only: workflows, actions, CODEOWNERS, `.claude/` and
  `.mcp.json` stay refused, and a finding on them goes to the person.
- **Never use, request, store or print a provider API key** (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or any other), here, in a script, a hook or a workflow. Authentication belongs to the harness. Never add a workflow, template or action that runs a model. `tests/run-all.sh` fails if one appears.
- If the harness cannot start a fresh-context sub-agent, say that the review was not independent.

## Releases

Every change to the skills, their scripts or their templates is a new semantic version. Nothing is committed to `main` directly.

1. Branch from `main`, named `release/<version>` or a topic name, and make the change.
2. Bump the version in all of these together: `VERSION`, `metadata.version` in both `SKILL.md` files, and a new entry at the top of `CHANGELOG.md`. `tests/run-all.sh` fails when they disagree.
3. Choose the bump by what an installed copy would notice:
   - major: a marker format, label name, script subcommand or exit code that existing workflows rely on is removed or changes meaning;
   - minor: a new label, subcommand, script, lane or rule that existing installs can ignore;
   - patch: a fix, a wording change or documentation only.
   Below 1.0.0, breaking changes bump the minor version.
4. Run `bash tests/run-all.sh` and `actionlint .github/workflows/*.yml .agents/skills/*/templates/*.yml`.
5. Open a pull request, then run the review loop on it before the turn ends (see "The review loop" above). The change is reviewed and corrected by the skills it changes. A person reads the verdict and merges.
6. When `VERSION` lands on `main`, `release.yml` runs `.github/scripts/release.sh`, which tags `v<version>` and publishes the release. `check-version.sh` in installed copies compares against that release, and `update.sh` installs it once the person has said yes.

Do not merge, tag or publish a release without a person's go-ahead.

## Documentation

Documentation is part of the change. A pull request that changes behavior, layout, labels, commands or paths also updates every document that describes them, in the same pull request. A change that leaves a document stating something false is not finished.

Decide what to update from what the change touches:

| The change touches | Update |
|---|---|
| A label, a state, a marker field, a trust rule or a `review-cycle.sh` subcommand | `README.md` (the artifact table, the label state diagram, the cycle budget text), `docs/HOW-IT-WORKS.md` (its own diagrams, which are not in `docs/diagrams/`), `docs/diagrams/*.mmd`, both copies of `references/pr-protocol.md`, the `SKILL.md` steps that name it, and the header comments of `review-cycle.sh` |
| Budget settings (`MAX_REVIEW_CYCLES`, `MAX_REVIEW_CYCLES_HARD`) | `README.md` budget table and text, the defaults in `review-cycle.sh budget`, `references/harness-loop.md` and `references/posture-and-config.md`, and the `Cycle budget` paragraph in this file |
| A script, a test or a workflow (added, renamed, removed) | `README.md` (layout, install, tests), the `Commands` and `Architecture` sections of this file, and `tests/run-all.sh` |
| An install path, a harness or a model name | the `README.md` install table and its date, the harness table in `install.sh`, and `references/harness-matrix.md` and `references/execution-profiles.md` (both skills) |
| The version | `CHANGELOG.md` and the `Versions and updates` section of `README.md` if the mechanism changed |
| Controls, records or roles that the ISO mapping cites | `docs/ISO-27001-AND-42001.md` and the ISO section of `README.md` |
| This file's own subject (commands, layout, process) | this file |

Rules for doing it:

- A diagram exists twice, as a Mermaid block in `README.md` and as a file in `docs/diagrams/`. Change both and keep them identical.
- Before opening the pull request, search the repository for the old name, path or label you removed or renamed, for example `grep -rn "<old name>" . --exclude-dir=.git`. Zero hits outside `CHANGELOG.md` is the goal.
- Describe what the code does now. Put history in `CHANGELOG.md`, not in the other documents.
- Claims in `README.md` about status and limits ("not run on live GitHub Actions", test counts) must match what is true after the change. Change them when they stop being true.
- Run the `humanizer` skill over any Markdown you write or substantially edit, except `CHANGELOG.md`.
- If a document could not be updated in the pull request, say which one and why in the pull request description.

## Conventions

- Write everything in this project in English: code, comments, docs, commit messages, PR text and skill prose.
- `SKILL.md` frontmatter uses `name`, `description` and `metadata.version`. Do not add harness-specific keys.
- `templates/review-gate.yml` calls scripts at `.agents/skills/pr-reviewer/scripts/`. Keep that prefix, since the README tells users to replace it if they install elsewhere. Claude Code does not scan `.agents/skills/`, so tell a sub-agent to read `.agents/skills/<skill>/SKILL.md` by path.
- Third-party actions in workflows and templates are pinned to full commit SHAs. Keep them pinned.
- Diagrams in `README.md` are sourced from `docs/diagrams/*.mmd`. Update both together.
- Dated facts (harness paths, model names) carry a date, currently 2026-10-14. Update the date when you re-verify them.
- Test output directories (`tests/**/state/`, `work-*/`, `state-*/` and a few generated files) are gitignored. The model-key scan in `tests/run-all.sh` skips `state-*/` and `work-*/` under `tests/` only, fails if a tracked file anywhere in the repository sits in a folder with such a name, and fails when `git ls-files` or `grep` cannot answer. `bash tests/run-all.sh --scan-only` runs just that scan.
