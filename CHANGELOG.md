# Changelog

All notable changes to `pr-reviewer` and `pr-fixer`. Both skills ship together under one version.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 0.8.5

### Fixed

- An option given last with no value (`halt 7 --reason`, `install.sh --harness`, `push-guard.sh 7
  --allow`, and the other options that read their value as `${2:-}`) made `shift 2` fail, and with
  no `set -e` the argument loop spun forever. The `publish` options read `$2` under `set -u`, so
  they did not hang but exited 1 with `$2: unbound variable`. Every option that takes a value now
  checks that one follows and refuses at once, naming the option: `review-cycle.sh` and
  `install.sh` exit 1, `push-guard.sh` exits 2.
- A pull request argument that is not a number (`7x`, `#7`, a non-ASCII digit) or a second number
  was dropped by `pr-json.py` and the gate, which then read the branch's own pull request. Both now
  refuse anything but one number in ASCII digits: the gate answers inconclusive (exit 2), and every
  `review-cycle.sh` command that reads the pull request refuses as it does when the pull request
  cannot be read.
- `install.sh` resolves symbolic links before its same-folder check, so a destination such as
  `.claude/skills` linked to `.agents/skills` is refused instead of being replaced by a copy of
  itself with its template rewritten in the source tree. A source skill folder that is a symbolic
  link, or that holds one at any depth (a linked `templates/`, say), is refused before any change,
  because `cp -R` would copy the link and the template rewrite would write through it. A
  destination inside the source (`--target <source>/pr-reviewer`) is refused too, by physical path,
  instead of putting a copy of the skill inside the source skill.
- `install.sh` deleted its own source when the source lay inside a skill folder it replaces: the
  repository cloned as `~/.claude/skills/pr-reviewer` and run with `--scope user --yes` lost the
  whole clone, `.git` and uncommitted work included, to the `rm -rf` of the old install, and then
  printed that the old install was untouched. It now refuses before any change, in the dry run too,
  when a source skill folder and the destination skill folder of the same name are one folder or
  one lies inside the other, and when the folder `install.sh` runs from lies inside a destination
  skill folder (the same clone, with `--source` naming another folder).
- `install.sh` compared paths as strings, so on a case-insensitive file system (the macOS default)
  a clone at `~/.claude/skills/pr-reviewer` run as `~/.claude/SKILLS/pr-reviewer/install.sh`, or a
  clone stored as `~/.claude/skills/Pr-Reviewer`, passed the overlap checks and was still deleted by
  `--scope user --yes`. The overlap checks now also compare folder identity (`test -ef`, device and
  inode) along every parent. As a backstop that does not depend on path logic, an existing
  destination skill folder is replaced only when it is a real folder holding a `SKILL.md` with that
  skill's name and no `.git` at any depth; a file, a repository, or a person's own folder of that
  name is refused before any change. A leftover folder with the name of the run's stage or set-aside
  copy is refused instead of removed.
- `install.sh` printed a shell error (`VERSION: No such file or directory`) when the source had no
  `VERSION` two folders up, because the redirection of stderr came after the failing `<`. It now
  prints `unknown` and no error.
- `install.sh` resolved paths with a logical `cd`, which reads `..` before following a link, so
  `--target <link to a source skill>/..` passed the same-folder check, set the source's skill folder
  aside and then claimed it was back. Paths are made absolute and resolve with `cd -P`, the copy
  writes to the resolved paths, and a path that cannot be resolved (a `..` after a folder that does
  not exist yet, a file in the way, a folder it cannot enter) is refused instead of kept as written.
  A failed swap names where the old copy is when it could not be put back.
- `install.sh --help` printed a fixed line range that no longer reached the end of the header and
  cut the exit-codes sentence. It now prints the whole header comment.
- `review-cycle.sh` discarded `pr-json.py`'s stderr, so a refused pull request argument (`status
  7x`) said only that the pull request could not be read. The reason now reaches stderr too.
- The install test suite runs a copy of `install.sh` and the skills inside its own scratch
  directory, so a refusal that regressed cannot touch the checkout it was started from. Its header
  says that its optional argument is an `install.sh` beside `.agents/skills` and `VERSION`, and it
  stops before the first row when they are not there.
- `triage-pr.sh` compared `TRIAGE_IGNORE_CHECKS` and `FIXER_COMMIT_AUTHORS` with every space
  removed, so a check named `CI Tests` or a commit author named `Fixer Bot` never matched. Entries
  are now trimmed and compared without case, as written.
- `review-cycle.sh stale` refuses (exit 2, no label moved) when `REVIEW_MARKER_AUTHORS` names no
  login, like `status`. Unset, it read every commenter's markers, so a forged marker at the new
  head kept a stale `review:passed` standing.
- `review-cycle.sh marker` matches in the C locale, so `nocasematch` folds ASCII letters only. Some
  locales fold a dotless i or a long s onto `i` and `s`, which no other reader does. Not verified
  on glibc, where that folding happens; macOS does not do it.
- `budget` and `halt` split marker fields on the six ASCII whitespace characters written out, the
  same set as `MARKER_WS`, instead of `\s` under a flag.
- `harness-loop.md` and the fixer's references say to wait, at most two minutes, until GitHub
  reports the pushed commit as the head before running `stale`. Run earlier, `stale` compared the
  marker with the old head and changed nothing.
- `tests/install/run.sh` takes the skills from beside the `install.sh` it tests. It always used
  this checkout's `.agents/skills`, so testing another copy of `install.sh` that lacked the
  same-folder refusal installed that copy over this checkout's skills.

## 0.8.4

### Security

- `REVIEW_MARKER_AUTHORS` holding only an invisible character named nobody but read as a list. A
  value of a lone BOM (any locale), or a no-break space under `LC_ALL=C`, passed the "lists a login"
  check in `review-cycle.sh` and the guard in `review-gate.yml`, and then the node reader in
  `parse()` and the Python reader in `budget` saw no login and trusted every commenter. A PASSED
  marker forged by anyone made `status` print "Nothing owed" and the gate go green. Every reader now
  applies one rule: split on commas, trim ASCII spaces, tabs, CR and LF, and keep an entry only if
  it is ASCII letters, digits, hyphens and underscores, starting with a letter or digit. Anything else drops the entry whole. The shell computes
  the kept list once (`marker_authors`) and hands it to the node and Python readers; the gate and
  the `jq` recipes in `pr-protocol.md` apply the same grammar. The `review-gate.yml` guard is a
  looser pre-check: it deletes every CR, splits on commas and LF, and passes when at least one entry
  matches the grammar, leaving the reading itself to `status`. An empty
  kept list trusts nobody everywhere, including `budget`, which used to trust everyone then. The underscore
  keeps Enterprise Managed User logins (`handle_shortcode`) working. A `[bot]` suffix is outside the
  grammar, and an entry carrying one is dropped.
- `publish`, `extend` and `halt --reason` refuse when the login `gh` is signed in to is not on
  `REVIEW_MARKER_AUTHORS`, or cannot be resolved. A marker posted as anyone else is one every reader
  ignores, so `status` owed the review forever and a halt was posted again on every run.
- The Python marker and extension regexes (`budget`, `halt`, `export-audit`, the gate) and the
  lint-report regexes that read numbers (hunk headers, the `line:` value, the `counts:` line) run
  with `re.ASCII`. The lint-report regexes that read a finding's `id:` and field lines do not, and
  need not: they read no number and decide no trust. `\d` took non-ASCII digits, which `int()`
  then parsed, so the gate read `pass=١` as pass 1 while `status` read no marker at all. Whitespace inside a marker is now the six ASCII characters (space, tab, LF, CR, FF,
  VT) in every reader: the node regex in `parse()` and the bash `MARKER_RE` spell them out instead of
  `\s` and `[[:space:]]`, so a no-break or ideographic space after `<!--` is no marker to `status`,
  `marker`, the gate, `budget` and `export-audit` alike, under any locale.

### Fixed

- `budget` split the fields of a marker it had matched on a space only. A trusted marker with a tab,
  LF, CR, FF or VT between fields, such as the two-line form the gate's docstring shows, read as
  pass 0 (so the hard ceiling never tripped) or as no marker at all, while `status`, `marker`, the
  gate and `export-audit` read it right. `budget` and `halt` now end a field value at any of the six
  ASCII whitespace characters, in verdict and extension markers alike.
- The `review-cycle.sh` header said `publish` wraps a bare `@login` in backticks. It does not; the
  report's author does, as `pr-protocol.md` says.

## 0.8.3

### Fixed

- A pull request carrying two `review:*` states at once could not leave them. `start`, `fix` and
  `publish` passed both names to one `--remove-label`, real `gh` refused the call ("accepts at most
  1 arg(s)"), and the only way out was clearing labels by hand. Each state is now removed with its own
  flag, and `status` names `start` as the way out. The fake `gh` in the tests now refuses a second
  positional argument the way real `gh` does, which is why the suite never caught this.
- The gate re-run step in `harness-loop.md` and the `review-gate.yml` template re-runs every failed,
  cancelled or timed-out run for the head SHA, one at a time, waiting for each, because the
  workflow cancels a run in progress when another starts. Re-running only the newest run picked the
  green `ready_for_review` run that `publish` starts on PASSED and left the red `opened` run on the
  pull request. The wait is bounded at 10 minutes, the failed ids are listed once and every one is
  re-run, and the loop then moves on without listing again: after BLOCKED, or with
  `REVIEW_MARKER_AUTHORS` unset, the gate fails on purpose, and that failure is its answer.
- `harness-loop.md` and the README say who runs `review-cycle.sh stale`: the fixer after its push, and
  the review loop after any push (now in its Roles table and step 1). Nothing ran it for a push the
  loop agent or a person made. `docs/HOW-IT-WORKS.md` no longer draws it as something GitHub does.
- A rerun of `release.yml` publishes a release left as a draft, after checking that the draft targets
  the commit being released and attaching both files again. Before, it saw `SHA256SUMS` and
  stopped, so a draft stayed a draft; v0.8.2, left that way, is published by hand. A published
  release that already has `SHA256SUMS` ends the run green, naming the commit it targets, with no
  tag lookup. On every other path, creating a release included, the step looks the tag up through
  `git/matching-refs` (exact ref only, an annotated tag followed to its commit) and refuses when
  the tag points at another commit. A failed tag lookup stops the step instead of reading as "no
  tag". Missing files are attached to a published release only when it targets this commit and
  its tag points at it. The reads of the release's fields and of the tag are plain assignments, so
  a failed read stops the step, and each refusal names what to delete before a rerun (W15, W16 of
  #19).
- The comment above `block_at_mismatch` in `review-cycle.sh` no longer says every caller applies
  it: only `status` calls it, and `budget` and the gate make the same comparison in Python, each
  only at the head (N1 of #18).
- The test row for `budget` on a stale `block_at=warning` marker matches the exact `B_WHY` reason
  instead of a negative grep on the mismatch message, so rewording that message cannot make it
  pass without testing anything (N3 of #18). The stale gate check now sits right after the gate run
  it reads (N2 of #18).

## 0.8.2

### Fixed

- The comment above `block_at_mismatch` in `review-cycle.sh` says the function only compares the
  settings and each caller applies it to a marker at the head, and names what each reader does
  with a stale marker: `status` owes the review, the gate fails, `budget` says `none` (N1 and N3
  of #17).

### Added

- A test row: `budget` on a `block_at=warning` marker the head left behind answers `none` for no
  verdict at the head, not the mismatch (N2 of #17).

## 0.8.1

### Fixed

- Two comments in `review-cycle.sh` now say that a reader with another `REVIEW_BLOCK_AT` refuses
  to judge a `block_at=warning` marker only while that marker is at the head; a marker on an older
  commit is stale and the review is due, as the code already did (N7 of #16). Comments only, no
  behavior change.

## 0.8.0

### Added

- The verdict marker records the setting it was published under. With `REVIEW_BLOCK_AT=warning`,
  `publish` appends `block_at=warning`; under the default it writes nothing new, so those markers
  are byte for byte what 0.7.x readers parse. `marker` prints the setting as a seventh field when
  the marker names one, and `export-audit` records `block_at` in the JSON.
- A reader running with a different setting no longer misreads such a marker at the head: `status`
  and the gate answer inconclusive (exit 2) and `budget` answers `none`, each naming both values. Before, a shell
  without `warning` read a warning-only BLOCKED as a BLOCKED with nothing blocking, and its fixer
  found no work.

- `export-audit` writes `block_at` as the marker states it: `warning`, or `null` when the marker
  names no setting.

### Changed

- A 0.7.x gate does not parse a marker carrying `block_at=` and reports it absent (fail closed).
  Update the gate scripts together with the skills before publishing under `warning`.

### Fixed

- The README says `REVIEW_BLOCK_AT` is read exactly, so a repository variable set to `Warning`
  shows up as an inconclusive gate after upgrading from 0.7.0.
- The `budget` header in `review-cycle.sh` says `ask` fires when a blocking finding is open.

## 0.7.1

### Fixed

- A blocking WARNING can now finish a loop. With `REVIEW_BLOCK_AT=warning`, pass 2 marks a WARNING
  `verified`, `refused-accepted` or `refused-rejected`, the same end states a CRITICAL has
  (`report-contract.md`, the reviewer's step 9 and the refusal tables). Before, a WARNING could only
  be `open` or `not-applicable`, so a fixed one stayed counted until the budget ran out.
- Prose both skills read at run time no longer says only a CRITICAL blocks when the setting says
  otherwise: the reviewer's `SKILL.md`, `severity-and-verdict.md`, `targets-and-context.md`,
  `operating-principles.md` and `workflow-and-gh.md`, the fixer's `lanes.md`,
  `operating-principles.md` and `falsify-and-prove.md`, the gate docstring and `docs/HOW-IT-WORKS.md`.
- The fixer's `SKILL.md` and `trigger-and-handoff.md`, both copies of `harness-loop.md` and
  `pr-protocol.md`, and the README and `HOW-IT-WORKS.md` budget text speak of blocking findings, not
  only CRITICALs: a new blocking finding restarts a cycle, the fixer proves each one red then green,
  and the question at the end of the budget lists the open blocking findings.
- The gate reads `REVIEW_BLOCK_AT` exactly, as `review-cycle.sh` does. A value such as `Warning` was
  accepted by the gate and refused by the script; both now answer inconclusive.
- The `mention-url` eval case names line 10, where the faulty lookbehind is, not line 11.

## 0.7.0

### Added

- `REVIEW_BLOCK_AT=critical|warning` (default `critical`, so installed copies behave as before). With
  `warning`, a WARNING blocks too: `publish` refuses a `PASSED` that counts a warning and accepts a
  `BLOCKED` with warnings and no CRITICAL, `budget` says `fix` and tracks blocking findings per pass,
  `status` and the gate judge a marker by the same rule, and the fixer works the warning like a
  CRITICAL instead of declaring it as debt. The marker format is unchanged. Any other value is
  refused by `publish`, answered `none` by `budget` and inconclusive (exit 2) by `status` and the
  gate. The `review-gate` template passes the repository variable `REVIEW_BLOCK_AT`.
- `lint-report` requires a `scenario:` (a concrete failing input) on every open WARNING when
  `REVIEW_BLOCK_AT=warning`, so a blocking warning is never a style opinion.
- Three review eval cases cut from bugs this repository really had: `mention-url`,
  `push-guard-rename`, `hunk-header`.

### Changed

- With the default setting nothing changes. A repository that wants likely bugs fixed before merge
  sets `REVIEW_BLOCK_AT=warning` in the shell that publishes and as a repository variable.
  Changing the setting on a repository invalidates earlier `PASSED` markers that count warnings.

## 0.6.1

### Fixed

- Removed the `@login` wrapping that 0.6.0 added to `publish`. Six review passes and four rewrites of it
  (a Markdown scanner, then a zero-width space with its own entity rules) each left a case where GitHub
  still rendered a mention, or changed the text it was meant to protect, and the guard had grown a
  fuzz harness larger than the check it served. `publish` posts the report as written again. Write a
  login you mention as `@login` in backticks; the secret screen stays.
- The secret screen no longer needs a word boundary before a token, so a token glued to an
  underscore prefix is refused. It also covers npm, GitLab and Google OAuth tokens.
- The last-cycle rule in `harness-loop.md`, README and HOW-IT-WORKS names the last cycle of every
  allowance, not only the fifth, and says what follows: `ask`, or `ceiling` at the hard limit.
  It no longer tells the fixer to pass `--model` and `--tier`, which belong to `publish`.
- The release workflow attaches the archive and `SHA256SUMS` to an existing release that lacks
  them, so a rerun after a failed upload repairs it.

## 0.6.0

### Added

- `review-cycle.sh publish` refuses a report that holds a token or private key (GitHub, AWS, Slack,
  Stripe, Google, JWT, `sk-` keys, bearer headers) and names the kind without printing the value.
  `lint-report` fails such a report too. The report is never rewritten, and high-entropy strings are
  not screened, because a commit SHA would always match.
- `publish` wraps a bare `@login` in backticks, outside code spans and fences, so the comment
  notifies nobody.
- The release workflow attaches `pr-reviewer-fixer-X.Y.Z.tar.gz` and `SHA256SUMS`. The README
  explains how to check them and says the sum proves integrity, not authorship.
- `harness-loop.md` (both copies): the last automatic cycle sends a fixer one tier up before the
  question to the person.

### Fixed

- `harness-matrix.md` sandbox section (both copies): Copilot CLI, Cursor and OpenCode rows use the
  controls the matrix records, `isolation: worktree` is no longer called a test-run control, and
  `approval_policy` is listed as a choice.
- `pr-protocol.md` (both copies) says `extend` stops because `budget` says `none`.
- The install test reports a root skip as `SKIP` and no longer counts it as a pass.

## 0.5.3

### Fixed

- `pr-protocol.md` (both copies) listed `budget` among the commands that refuse without
  `REVIEW_MARKER_AUTHORS`. It now says `budget` prints `B_NEXT='none'` and exits 0.
- The install test prints a SKIP row when it skips the failed-copy case as root.

### Added

- README and the ISO guide tell operators to dismiss stale approvals when new commits are pushed,
  so a human approval is tied to the head it was given on. A PR comment is never an approval.
- `harness-matrix.md` (both copies) has a section on isolating the fixer's test run, built from
  the controls already recorded there; harnesses with no verified control say so.

## 0.5.2

### Fixed

- `docs/HOW-IT-WORKS.md` said the scripts refuse to run without `REVIEW_MARKER_AUTHORS`. They
  trust no marker instead (`budget` prints `B_NEXT='none'` and exits 0).
- `harness-loop.md` listed `budget` among the commands that refuse without `REVIEW_MARKER_AUTHORS`.
  It prints `B_NEXT='none'` and exits 0, so the text now says that.
- The install test for a failed copy relies on `chmod 000`, which root ignores, so it now runs
  only for other users.

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
