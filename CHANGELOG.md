# Changelog

All notable changes to `pr-reviewer` and `pr-fixer`. Both skills ship together under one version.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 0.4.0

### Changed

- `review-cycle.sh` reads the six simple pull request fields with one `node` process instead of
  six, so each subcommand starts fewer processes.
- The reviewer brief in `references/harness-loop.md` names the fenced `findings` block, so the
  fixer reads CRITICAL ids and claims from it.

### Fixed

- `review-cycle.sh budget` read a marker written as `verdict=blocked` as not BLOCKED and answered
  `none`. The verdict is now upper-cased before it is compared.
- A header comment in `parse()` still said an unset allowlist skips nothing.
- `tests/fake-gh/err`, a test output file, is no longer tracked.
- `review-cycle.sh halt` posted a second halted marker when the pull request already carried
  `review:needs-human`. It now posts one.
- `triage-pr.sh` defaulted `FIXER_COMMIT_AUTHORS` to the Actions bot names, though no workflow runs
  the fixer. The default is empty, so the recent-fixer-commit skip is off until you set it.

## 0.3.0

### Added

- `review-cycle.sh fix` refuses a pull request from a fork, and one whose author or any commit
  author is not a collaborator with `write`, `maintain` or `admin` permission, before any label
  moves. `FIXER_TRUSTED_LOGINS` allows a bot the repository owns.
- `scripts/pr-json.py` in both skills: reads the pull request through GraphQL, drops every comment
  edited after it was created, and fails closed when edits cannot be checked.
- `publish --model <id> --tier fast|standard|deep` writes optional, self-attested `model=` and
  `tier=` into the marker. Older markers stay valid.
- `review-cycle.sh export-audit <pr>` writes `docs/compliance-records/<pr>-<pass>.json` from the
  trusted marker and the PR's label events, and refuses when the head moved after the marker.
- `publish` appends one line to a per-machine `audit.jsonl` as a convenience copy.
- `docs/compliance-records/README.md` and the design record `docs/designs/iso-alignment-0.3.0.md`.

### Changed

- **Breaking for installs that relied on it:** with `REVIEW_MARKER_AUTHORS` unset, empty or listing
  no login (a lone comma), `status`, `publish`, `budget`, `extend` and the gate refuse instead of
  reading every comment. Set it to the login the harness publishes as.
- A marker comment that was edited after it was created is ignored by every reader. An edited
  BLOCKED marker still counts as BLOCKED history, so an edit cannot unlock a pass-1 PASSED.
- `export-audit` reads a timeline split over several pages, writes atomically, and `fix` treats a
  missing `isCrossRepository` or a commit list of 250 or more as unknown and refuses.
- `budget` reads a marker with exactly the grammar the other readers use.
- Removed the dead extension-marker loop from `triage-pr.sh`.

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
