# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this repository is

Two Agent Skills, `pr-reviewer` and `pr-fixer`, plus the scripts and GitHub Actions templates that run them. The skills live in `.agents/skills/` and nowhere else. Do not add copies or symlinks under `.claude/skills/`. Almost everything is prose (`SKILL.md` and `references/*.md`) read by a model at run time. The only executable code is a few shell and Python scripts and the workflow YAML. `README.md` has the full explanation, install table and caveats.

## Commands

```bash
bash tests/run-all.sh                                   # whole suite, no network
bash tests/fake-gh/run.sh .agents/skills/pr-reviewer/scripts       # review-cycle.sh + gate, one copy
bash tests/fake-gh/triage/run.sh .agents/skills/pr-fixer/scripts   # triage-pr.sh
bash tests/version/run.sh .agents/skills/pr-reviewer/scripts       # check-version.sh
python3 tests/extwait/run.py .agents/skills/pr-fixer/templates/pr-review-cycle.claude.yml   # extension-wait step
python3 tests/budget/t.py    .agents/skills/pr-fixer/templates/pr-review-cycle.claude.yml   # cycle-budget logic
```

The suite needs bash, python3 with PyYAML, node and jq. It puts a fake `gh` first on `PATH` (`tests/*/bin/gh`, backed by `fakegh.py`), so nothing touches GitHub. There is no build or lint step. Workflows and templates are checked with `actionlint`, which is run by hand.

## Architecture

**The two skills never call each other.** They communicate only through the pull request: `review:*` labels, a verdict comment carrying `<!-- adversarial-review: sha=... verdict=... pass=... -->`, a fixer closure comment, a `pr-debt` block in the PR body, and extension question and answer comments. The artifact table in `README.md` lists each one, and `.agents/skills/pr-reviewer/references/pr-protocol.md` has the exact `gh` command to find it. Changing a marker or label format means updating both skills and the scripts.

**Mechanism lives in scripts, judgement lives in prose.**
- `scripts/review-cycle.sh` is the state machine: it owns labels, publishes the verdict bound to the head SHA (it re-reads the head from GitHub and refuses a stale `--sha`), and refuses inconsistent verdict arithmetic (a `BLOCKED` with no CRITICAL, a `PASSED` with one).
- `scripts/gate-pr-review-state.py` is the check the `review-gate` required job runs.
- `.agents/skills/pr-fixer/scripts/triage-pr.sh` decides what the fixer owes on a PR. The reviewer has no copy.

**Shared files are duplicated on purpose.** `review-cycle.sh`, `gate-pr-review-state.py`, `check-version.sh`, `templates/*.yml`, `references/pr-protocol.md` and `references/harness-matrix.md` exist in both skill folders so each skill installs alone. Edit one copy and mirror it to the other. `tests/run-all.sh` fails if the three scripts differ. It does not check the templates or the two references, so verify those with `diff -r .agents/skills/pr-reviewer/templates .agents/skills/pr-fixer/templates` and `cmp`. Other same-named references (`execution-profiles.md`, `operating-principles.md`, and so on) differ by design, one per skill.

**Workflow templates** come in `claude` and `codex` pairs: `pr-review`, `pr-review-cycle`, `pr-fixer-proactive`. A change to one provider's file usually needs the same change in the other. The tests parse `pr-review-cycle.*.yml` and execute its shell steps against the fake `gh`, so keep step names and structure that `tests/extwait/run.py` and `tests/budget/t.py` look up.

**Cycle budget.** `MAX_REVIEW_CYCLES` (5), `MAX_REVIEW_CYCLES_HARD` (10) and `EXTENSION_WAIT_SECONDS` (300) are defined in the cycle workflow and described in `README.md`. A person answers the extension question with a comment whose first line is exactly `/pr-skill continue N` or `/pr-skill stop`.

## Releases

Every change to the skills, their scripts or their templates is a new semantic version. Nothing is committed to `main` directly.

1. Branch from `main`, named `release/<version>` or a topic name, and make the change.
2. Bump the version in all of these together: `VERSION`, `metadata.version` in both `SKILL.md` files, and a new entry at the top of `CHANGELOG.md`. `tests/run-all.sh` fails when they disagree.
3. Choose the bump by what an installed copy would notice:
   - major: a marker format, label name, script subcommand or exit code that existing workflows rely on is removed or changes meaning;
   - minor: a new label, subcommand, script, lane or rule that existing installs can ignore;
   - patch: a fix, a wording change or documentation only.
   Below 1.0.0, breaking changes bump the minor version.
4. Run `bash tests/run-all.sh` and `actionlint .github/workflows/*.yml`.
5. Open a pull request. The review loop in `.github/workflows/` runs `pr-reviewer` and `pr-fixer` on it, so the change is reviewed and corrected by the skills it changes. A person reviews the verdict and merges.
6. When `VERSION` lands on `main`, `release.yml` tags `v<version>` and publishes the release. `check-version.sh` in installed copies compares against that release.

Do not merge, tag or publish a release without a person's go-ahead.

## Documentation

Documentation is part of the change. A pull request that changes behavior, layout, labels, commands or paths also updates every document that describes them, in the same pull request. A change that leaves a document stating something false is not finished.

Decide what to update from what the change touches:

| The change touches | Update |
|---|---|
| A label, a state, a marker field or a `review-cycle.sh` subcommand | `README.md` (the artifact table, the label state diagram, the cycle budget text), `docs/diagrams/*.mmd`, both copies of `references/pr-protocol.md`, the `SKILL.md` steps that name it, and the header comments of `review-cycle.sh` |
| Budget settings (`MAX_REVIEW_CYCLES`, `MAX_REVIEW_CYCLES_HARD`, `EXTENSION_WAIT_SECONDS`) | `README.md` budget table and text, the defaults in the cycle workflow, and the `Cycle budget` paragraph in this file |
| A script, a test or a workflow (added, renamed, removed) | `README.md` (layout, install, tests), the `Commands` and `Architecture` sections of this file, and `tests/run-all.sh` |
| An install path, a harness or a model name | the `README.md` install table and its date, and `references/harness-matrix.md` and `references/execution-profiles.md` (both skills) |
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
- The workflow templates call scripts at `.agents/skills/<skill>/scripts/`, and the Claude prompts tell the agent to read the skill's `SKILL.md` by that path because Claude Code does not scan `.agents/skills/`. Keep that prefix, since the README tells users to replace it if they install elsewhere.
- Third-party actions in the templates are pinned to full commit SHAs. Keep them pinned.
- Diagrams in `README.md` are sourced from `docs/diagrams/*.mmd`. Update both together.
- Dated facts (harness paths, model names) carry a date, currently 2026-10-14. Update the date when you re-verify them.
- Test output directories (`tests/**/state/` and a few generated files) are gitignored.
