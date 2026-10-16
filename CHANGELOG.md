# Changelog

All notable changes to `pr-reviewer` and `pr-fixer`. Both skills ship together under one version.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 0.5.1

### Fixed

- `push-guard.sh` lists both paths of a rename (`git show --no-renames`), so moving an
  out-of-scope file to a test name no longer hides the deleted source.
- `install.sh` checks every destination (symbolic link, unknown name) before it removes anything,
  also in the dry run. It copies each skill to a sibling folder and moves it into place, so a failed
  copy leaves the old install untouched. `--help` no longer prints the `set` line.
- `install.sh` describes what it does (it replaces each skill folder with a copy swapped in, and
  sets the old one back if the swap fails) and a test covers a failed copy.
- `review-cycle.sh lint-report` checks that a `line` range `A-B` sits inside one hunk, not only that
  both ends are in some hunk.
- `review-cycle.sh lint-report` stops reading file headers inside a hunk, so a line such as
  `-- comment` or `++ x` is no longer taken as a file. A finding whose `line` is missing or not a
  number or a `A-B` range is now reported instead of skipped.

### Added

- `docs/HOW-IT-WORKS.md`: a plain-language explanation of both skills with Mermaid diagrams, and a
  README note that a review starts only inside an agent session.

## 0.5.0

### Added

- `review-cycle.sh lint-report [pr] --report FILE [--diff FILE]` checks a report before `publish`:
  each finding must name a file the diff touches and a line a hunk shows, the `counts:` line must
  equal the open entries, and the coverage note must carry a `Declined to judge:` line. It posts
  nothing. `publish` does not call it.
- `pr-fixer/scripts/push-guard.sh <pr> [--findings FILE] [--allow PATH]...` runs before a push. It
  refuses a checked-out branch that is not the pull request head, a fork head, a pull request that is
  not open, a push that is not a fast-forward, and a commit that touches a file no open finding names
  (test files and `--allow` paths excepted).
- `install.sh` copies the skills into the folder a harness reads, for 13 harnesses, project or user
  scope. It prints the plan and changes nothing without `--yes`. With `--yes` it removes the old
  `pr-reviewer` and `pr-fixer` folders first, so files a release dropped do not stay, and refuses a
  symbolic-link destination.
- `tests/eval/`: seeded review cases (`sql-injection`, `off-by-one`, `clean-rename`) and `score.py`,
  which prints recall and precision for reports produced in a harness session. `tests/run-all.sh`
  runs the scorer's own tests only.
- The report's coverage note carries a mandatory `Declined to judge:` line, with `none` when the
  review read everything.

### Changed

- The reviewer reads project rules (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, `GEMINI.md`,
  Copilot instructions, lint configuration) from the base commit, not the head. A diff that edits
  one of them is reviewed as code. This adopts item 52 of the reviewer catalog.
- The README install section leads with `install.sh`, and the update steps say to replace the
  installed folders instead of copying over them.
- `tests/run-all.sh` adds the suites for `push-guard.sh`, `install.sh` and the eval scorer.

## 0.4.2

### Changed

- The README install section starts with requirements and a quick install, gives the `git clone`
  command for a release tag, shows the Claude Code links as a command block, and adds a user-level
  install note and a check step. The harness table follows as a reference.
- "Run it by hand" names the invocation prefix per harness (`/pr-reviewer`, `$pr-reviewer`).
- "Run it on every pull request" separates the two required steps from the recommended ones, and
  shows how to set `REVIEW_MARKER_AUTHORS` in the shell and as a repository variable.
- The update instructions name the command to repeat.

## 0.4.1

### Changed

- The test suites run at the same time, each in its own scratch directory (`TEST_TAG`). The whole
  suite takes about two and a half minutes instead of four and a half.
- The label events request asks for 100 events a page, so a long pull request needs a third of the
  round-trips (`review-cycle.sh export-audit`, `triage-pr.sh`).

### Fixed

- `review-cycle.sh halt` refuses an unset or login-less `REVIEW_MARKER_AUTHORS`, as the other
  decision subcommands do, instead of posting a duplicate halted marker on every call.
- `halt` skips the marker only when the newest trusted extension marker is a halted one with the
  same reason, the reading `budget` makes. The refusal text no longer claims no label was added.
- `parse()` exits 2 with "could not read the pull request fields" when no number can be read, for
  instance when a field holds the unit separator it uses between fields. Before, `start` went on
  with empty fields. `stale` now exits 2 on an unreadable payload too, where it carried on with
  empty fields.

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
  `review:needs-human`. It now posts one, and posts it before the label so a failed comment leaves
  no label behind.
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
