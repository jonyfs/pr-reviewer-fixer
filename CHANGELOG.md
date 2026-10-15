# Changelog

All notable changes to `pr-reviewer` and `pr-fixer`. Both skills ship together under one version.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 0.2.0

### Added

- `review-cycle.sh publish --verdict PASSED` marks a draft pull request ready for review, after
  the marker and the label. A failure there is reported and does not undo the verdict. Agents open
  pull requests as drafts.

### Changed

- `review-cycle.sh budget` and `extend` fail closed when `REVIEW_MARKER_AUTHORS` is unset: they
  trust no marker, so a stranger's comment cannot raise the cycle budget.
- `budget` reads a verdict marker only from the start of a comment, as `status` and the gate do.
- `triage-pr.sh` skips a halted pull request by the `review:needs-human` label, not by the newest
  halted marker, so a pull request a person fixed is no longer skipped.
- A draft pull request is reviewed, not skipped. Converting a ready pull request back to draft is
  what invalidates a cycle.
- Wording left over from the removed extension-question comments is gone from both `SKILL.md`
  files and the script header.

## 0.1.0

First tracked release.

### Added

- `scripts/check-version.sh` in both skills. It prints one notice when a newer release exists and
  never installs anything. Opt out with `PR_SKILLS_NO_UPDATE_CHECK=1`.
- `metadata.version` in each `SKILL.md`, a root `VERSION` file and this changelog.
- `review-cycle.sh halt` and the `review:needs-human` label, set over `review:blocked` when the
  loop pauses or stops and a person has to decide.
- `review-cycle.sh budget` and `extend`: the cycle budget and the recorded extension answer, read
  from trusted markers. The question to the person is asked in the session.
- `references/harness-loop.md`: the review loop agent that runs the reviewer and the fixer as
  sub-agents of the person's harness session.
- `templates/review-gate.yml`: a required status check that runs no model and holds no secret.
- `tests/run-all.sh` fails when a workflow, template, script or test names a model action or a
  provider API key.

### Changed

- The skills moved to `.agents/skills/`.
- Review and fix run as agents in the person's harness session. No GitHub Actions workflow runs a
  model, and no provider API key is used. `REVIEW_MARKER_AUTHORS` holds the login the session
  publishes as. The extension question is asked in the session, and `/pr-skill` PR comments no
  longer grant cycles. Workflow templates and prompts call that path.

### Removed

- The `review:ready-to-merge` label. It repeated `review:passed`.
- The workflow templates that called a model (`pr-review`, `pr-review-cycle`,
  `pr-fixer-proactive`, for Claude and Codex), the `FIXER_PUSH_TOKEN` secret, and the 15-second
  comment poll for extension replies.
