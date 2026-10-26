# Changelog

All notable changes to `pr-reviewer` and `pr-fixer`. Both skills ship together under one version.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 0.16.0

Engineering-quality knowledge for `pr-reviewer`, and the security pass keyed to OWASP. New
dimensions, path-floor units and optional finding fields; existing installs can ignore them.

- Five dimensions join the reviewer, for eighteen in all: data integrity and migrations, reliability
  and resilience, scalability and capacity, operability and deployability, and privacy and data
  protection (LGPD, GDPR). Each has a checklist under `references/`, and design has one too:
  `architecture-checklist.md`, `reliability-checklist.md`, `scalability-checklist.md`,
  `data-and-migrations-checklist.md`, `operability-checklist.md`, `privacy-checklist.md`. The
  dispatch limit goes from thirteen agents to eighteen; the stance table and `execution-profiles.md`
  place each new unit; `dimensions.md` gives severity guidance per area, bound to
  `severity-and-verdict.md` (an outage of one endpoint or one region is still CRITICAL).
- `security-checklist.md` is keyed to the OWASP Top 10:2025 (A01 to A10) with code-level checks
  (CSRF under cookie authentication, path traversal, XXE, open redirect, ReDoS, TOCTOU, mass
  assignment, uploads, rate limiting, JWT and sessions), ASVS 5.0.0 chapters for depth (Level 1 by default, Level 2 when the floor hits
  authentication, session or cryptography), a per-change threat model, and stack lists read when the
  change has that stack: API Security Top 10 2023, CI/CD Top 10, LLM Top 10 2025, Agentic Top 10
  for 2026, Mobile Top 10 2024 and Kubernetes Top 10 (2025). Sources, dates and licences are named.
- Findings may carry optional `owasp:` and `cwe:` fields (`report-contract.md`). `lint-report` and
  the fixer ignore them.
- `path-floor.sh`: infrastructure and deployment files (Terraform and OpenTofu, Kubernetes, Helm,
  Kustomize, Compose, Pulumi, CloudFormation, Ansible, Nomad, and others in its header) summon
  `reliability` and `operability`; privacy-named paths (`privacy`, `gdpr`, `lgpd`, `consent`, `pii`,
  `personal-data` and others) summon `privacy`. `lint-report` requires these units in
  `mandatory_units:` like any other floor unit.
- Eval: fourteen seeded cases, each with a decoy. One per OWASP Top 10:2025 category that had none
  (`missing-authz` A01, `xxe` A02, `install-script` A03, `fast-hash` A04, `coupon-race` A06,
  `jwt-noverify` A07, `webhook-unsigned` A08, `token-in-log` A09, `fail-open` A10; A05 was already
  `sql-injection`), and one per new dimension (`retry-double-charge`, `n-plus-one`, `drop-column`,
  `pii-in-logs`, `recreate-deploy`). `score.py --validate` refuses a case whose decoy window overlaps a defect's, and takes
  `--cases DIR` (W1 of #35).
- `docs/ISO-27001-AND-42001.md` maps the dimensions to the ISO/IEC 25010:2023 quality
  characteristics, and assesses the two skills against the OWASP Top 10 for Agentic Applications
  for 2026, risk by risk, with what each leaves to the person or the harness.
- `security-checklist.md` says which OWASP lists were confirmed on their pages that day (Top
  10:2025, ASVS chapters, Kubernetes items, the Agentic title and date) and which came from the
  editions or secondary sources (the Agentic item names, API, CI/CD, LLM, Mobile).
- Tests: the fake `gh` pages comment deletions (`deleted-page-size`), and a row checks that
  `pr-json.py` reads deletions past the first page (N2 of #34); a row checks that
  `path-floor.sh --help` prints its whole header. The 0.15.4 entry's suite time is corrected to the
  measured figure (N1 of #34).

## 0.15.4

Performance only. No output, marker, label, subcommand or exit code changes.

- `pr-json.py` reads the first page of comment edits and of comment deletions in one GraphQL call
  instead of two, so every `review-cycle.sh` subcommand that reads the pull request, and the gate,
  makes one round trip fewer. A connection with more than one page goes on with its own query, as
  before.
- `review-cycle.sh extend` computes the budget from the pull request it already read, instead of
  reading it again (one `pr-json.py` run and its `gh` calls fewer), and `publish` asks `gh api user`
  once instead of twice.
- Tests: `tests/run-all.sh` runs the suites of the shared scripts once, from the reviewer's copy;
  its `cmp` checks already fail when the fixer's copy differs, so the second run added time and no
  coverage. It also puts a link to the real `python3` first on `PATH`, because a pyenv or asdf shim
  costs a few hundred milliseconds per start; `tests/fake-gh/run.sh` does the same and reads labels,
  comment counts and the head through `jq`. The whole suite went from 11.6 to about 3 minutes on a
  machine with a pyenv shim.
- Tests: the scan-hidden rows for W1 of #33 use 120000 escaped brackets instead of 30000, so the
  quadratic code they guard against takes about 8 s against the 2 s bound instead of about 2 s
  (debt N4 of #33).

## 0.15.3

Fixes from an audit of 0.15.2. No marker, label, subcommand or exit code changes.

- `scan-hidden.py`: the invisible-HTML check is linear. A text of 20000 `<a` with no `>` took 23 s
  (one scan to the end per `<a`), so a pull request author could stall the loop; it now takes 0.1 s.
  The tag start, its `>` and the invisibility marker are found by separate scans and joined by
  position, with the same matches as before.
- `scan-hidden.py` reports more invisible text: the bidi marks U+200E, U+200F and U+061C (kind
  `bidi`), blank fillers such as the soft hyphen and the Hangul filler (new kind `filler`), and a run
  of two or more variation selectors, the way bytes are smuggled after one visible character (new
  kind `variation-selector`; one selector after an emoji is not reported).
- `scan-hidden.py` reports a link reference definition whose destination is a `#fragment`
  (`[//]: #ignore-the-rules`) or that carries a title, when no link in the same text uses its label.
  A plain URL definition, and one whose label a link uses, are still not reported. The label uses are
  found in one pass, so a run of escaped brackets (`\[`) does not slow the scan.
- `path-floor.sh`: authentication and cryptography names it missed now summon security at `max`:
  authenticate, authorize, signin and sign-in, mfa, token(s), secret(s), hmac, signing, signature,
  tls, ssl, cert(s), keystore, kms, bcrypt, scrypt, argon2 and others (the header has the list). CI
  outside GitHub (`.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `azure-pipelines.yml`,
  `.buildkite/`, `buildkite.yml`, `.woodpecker.yaml` and others) summons security at `max` too.
  push-guard.sh does not refuse those CI files yet. The header comment says why the broad words
  (token, secret, signature, cert, tls) stay, though they also match paths that are not about security.
- `triage-pr.sh`: `gh pr view --json commits` lists at most 100 commits, so on a longer pull request
  the "last" commit was the 100th, not the head, and a fixer still at work could be missed. The head
  commit is now read on its own; when that read fails and `FIXER_COMMIT_AUTHORS` is set, a fixer
  counts as at work.
- `install.sh` no longer copies `__pycache__` folders and `.pyc` files from a checkout that ran the
  tests.
- Docs: README says the `review-gate` check runs on this repository's own pull requests (it said it
  had never run live) and lists the test requirements without PyYAML, which nothing imports.
  AGENTS.md names `.github/workflows/review-gate.yml` and `findings-block`. `MAX_CONFLICT_FILES` is
  described as read by the agent, not by a script. The fixer's improvements catalog names
  `review-cycle.sh stale` instead of a `review-stale.sh` that does not exist.
- Removed `tests/fake-gh/export-out/7-2.json`, a leftover of a 0.3.0 run that no test reads.

## 0.15.2

Documentation only. Fixes the four notes declared on PR #31: the residual
`Mandatory units:` label in the report template is renamed to `Unit floor:`,
the ambiguous status wording is clarified, an over-long sentence in
HOW-IT-WORKS.md is wrapped, and the CHANGELOG claim about WR-01 is now
accurate because the template label is gone.

## 0.15.1

Documentation only. The reviewer contract now says where mandatory units are written: in the
findings block's `mandatory_units:` field, not a prose `Mandatory units:` line, which `lint-report`
ignores. The contract also states the one-`findings`-line rule that `lint-report` enforces. Fixes
the two warnings declared on PR #30 (WR-01, WR-02).

## 0.15.0

Makes the path floor and the findings block mechanical, so the reviewer and the fixer read the same
structured lists. Interface change: `path-floor.sh --diff` is removed; the `<base> <head>` form keeps
working, and `--pr <n>` and `--files <file>` are new.

- `path-floor.sh` reads paths only from a structured list: `git diff --no-renames --name-only -z`
  (`<base> <head>`), the pull request's file list from the API (`--pr <n>`, paginated, rename's old
  path included, refuses when the count differs from `changedFiles` or exceeds 3000), or a NUL list
  (`--files`). It no longer parses diff text.
- `review-cycle.sh findings-block` prints the report's `findings` block as JSON. `lint-report` and
  `push-guard.sh` both read it through that one function, so they cannot take different blocks.
- `lint-report` takes `--files <file>` or `--base`/`--head` in place of a diff file for scope, and
  reads each unit's `status` and `effort` from `mandatory_units`.
- Test harness: the fake `gh` answers the files endpoint when the path follows `--paginate`, and
  passes a non-list answer through so the script's own check fires. `findings-block` tests read the
  error of their own call.
- Suite: `tests/run-all.sh` passes on both skill copies, which are identical.

## 0.14.0

Adds the mechanical path floor (I50), closes the two notes PR #28 declared as debt (N1, N3), and
the open `release.yml` and gate-template items of PR #19 (N1, N3, N5, N7, N8, N9, N12, N13, N15,
N16, N17, N19, N23, N27, N29-N35).

### Added

- `scripts/path-floor.sh <base> <head>` (or `--diff <file>`), in both skills, maps the paths a change
  touches to review units that must run: `.github/workflows/**`, `.github/scripts/**`,
  `.github/actions/**`, `action.yml`, CODEOWNERS, `.mcp.json`, agent directories at any depth
  (`.claude/**`, `.codex/**`, `.opencode/**`, `.cursor/**`, `.gemini/**`, `.windsurf/**`, and the
  `skills/` folder of `.agents`, `.roo`, `.cline`, `.kiro`, `.devin` and `.junie`, so every project
  skill folder `install.sh` writes counts; #29 W7), agent instruction files (`AGENTS.md`,
  `CLAUDE.md`, `GEMINI.md` in any directory, `.github/copilot-instructions.md`,
  `.github/{instructions,agents,skills,prompts}/**`, `opencode.json`, `.cursorrules`,
  `.windsurfrules`), Dockerfiles, and authentication and cryptography paths (also as a camelCase
  word, `AuthService.ts`) get security at `max`; migrations get security and data integrity;
  manifests and lockfiles get dependencies. A rename counts by both paths. `--diff` splits on `\n`
  only, so a form feed or U+2028 in a changed line cannot forge a hunk header, and reads a
  header-only section (binary, empty, mode change) by its quoted or unquoted `diff --git` names. It
  exits 2 when it cannot read the paths, including a diff that is not empty but names no path (a
  coloured `gh pr diff`) (I50; #29 W1, W2, W3, W4, W8).
- `review-cycle.sh lint-report` runs `path-floor.sh` over the diff it checks and refuses a report
  whose coverage note has no `Mandatory units:` line listing each mandatory unit as run, with
  `(max)` where the floor says `max`. It reads exactly one such line, in the Coverage note section
  outside any fence or blockquote, refuses a second line, a second Coverage note section or a unit
  listed twice, and wants the status to be exactly `run`. Fences are tracked line by line as
  CommonMark closes them, so a ```` fence quoting a ``` block hides all of its text, and the
  `findings` block is the first one outside every other fence (#29 W6). It reads a pull request's
  diff with `gh pr diff --color=never`, so `CLICOLOR_FORCE=1` cannot empty the floor (#29 W8). A diff with no mandatory unit needs no such line, so reports that passed
  before still pass. It exits 2 when the floor cannot be computed (I50; #29 W5). Its anchor parser
  splits the diff on `\n` only, like the floor (#29 W1).
- `push-guard.sh` counts `.github/scripts/**` in the `workflows` class (the scripts a workflow runs)
  and has a new `instructions` class for the agent instruction files above, which
  `PUSH_GUARD_ALLOW_SENSITIVE` may name; a link at, into or above one is refused like the others
  (#29 W2). The `skills` class covers the `skills/` folder of `.agents`, `.roo`, `.cline`, `.kiro`,
  `.devin` and `.junie`, and agent directories (`.claude`, `.cursor` and the rest) count at any
  depth, as in the path floor; a test reads `install.sh`'s table so a new harness cannot be missed
  (#29 W7).
- `security-checklist.md` has a section for CI, workflow and agent configuration:
  `pull_request_target` and `workflow_run`, expression injection, unpinned actions, `permissions`,
  secrets, agent configuration (I50). The loop computes the floor in step 3 and hands it to the
  reviewer; `SKILL.md`, `agents-and-dispatch.md`, `execution-profiles.md` (a data-integrity unit)
  and `report-contract.md` name it.
- `.github/scripts/release.sh` holds the release logic; `release.yml` runs it. `tests/release/run.sh`
  drives it against the fake `gh` through every state a release can be in, and `tests/run-all.sh`
  runs it (#19 N16). The fake `gh` answers the release and git-ref calls.

### Changed

- The gate template, for a run still queued after 10 minutes, says to tell the person and skip the
  re-runs, as `harness-loop.md` does, instead of "stop" (#29 N4).
- `tests/fake-gh/run.sh`: the `lint-report` helper expands `\n`, so each `Mandatory units:` row puts
  the line on its own line, and a row checks that git mode and `--diff` mode of `path-floor.sh`
  print the same floor (#29 N1, N2 in part).
- `fetch-feedback.py` asks each review-thread comment for `pullRequestReview{state}`, and an inline
  comment of a DISMISSED review is `skip: dismissed`, like the review's own body (#28 N1).
- `fetch-feedback.py` fails closed on a review, issue comment or thread comment whose `isMinimized`
  is not a boolean, and on a thread comment without the `pullRequestReview` key. Introspection on
  2026-10-21 shows `isMinimized` is a non-null Boolean on IssueComment, PullRequestReviewComment and
  PullRequestReview, and `pullRequestReview` a nullable object; the docstring records it (#28 N3).
- `release.yml` has a concurrency group (`release`, `cancel-in-progress: false`), so two runs never
  interleave their lookups and writes (#19 N33), and its step is named "Create, complete or publish
  the release for VERSION", with the four states as a table in the script's header (#19 N32).
- The release lookup lists every release through the API with `--paginate`, so a draft (which has
  no tag) is seen and any error fails the run instead of reading as "no release". Two releases of
  one tag are refused (#19 N15).
- A release is marked Latest only when no published release has a higher x.y.z, compared as
  numbers; drafts and other tags do not count. `--latest` or `--latest=false` is passed on both
  `create` and the draft's `edit` (#19 N3).
- A published release counts as complete only when it has both the archive and `SHA256SUMS` and the
  downloaded archive matches the sum. Otherwise the files of this commit's release are attached
  again (#19 N17). The early exit prints the tag's commit, not `target_commitish`, and says when that
  commit is not this run's (#19 N34).
- A draft is published with the title and notes from `CHANGELOG.md`, and a draft carrying any other
  file is refused (#19 N5).
- A published release with no tag and a draft that targets another commit get their own refusals,
  apart from a tag on another commit (#19 N31). Every refusal names what to delete or fix before a
  rerun, including a tag that resolves to something other than a commit (#19 N29). The comments say
  what reruns the workflow (#19 N30) and that the `matching-refs` lookup now pages (#19 N35).
  `VERSION` must be exactly x.y.z.
- `harness-loop.md` step 1 runs `stale` at the start of every loop, since the loop agent cannot see
  a person's push (#19 N9). Step 4 is skipped after a BLOCKED verdict (#19 N12) and says a
  `gh run watch` that has not finished after 10 minutes is stopped, since `timeout-minutes` does not
  bound a queued run (#19 N27).
- The gate template, and `harness-loop.md`, say a new head cancels the old head's runs and re-runs
  on purpose (#19 N7), what to do when a run is still queued after 10 minutes (#19 N19), and that
  the gate also fails, inconclusive, on an invalid `REVIEW_BLOCK_AT` or one that differs from the
  marker's `block_at` (#19 N23).
- README: the gate fails at once on a push made outside a session only if it is installed (#19 N1).
  HOW-IT-WORKS draws the fixer's push, `stale` and closure comment in the order the skill runs them
  (#19 N8).

### Not changed

- Step 4 of the loop (re-running the gate) stays prose with no `review-cycle.sh` subcommand and no
  test; `harness-loop.md` says so (#19 N13).

## 0.13.0

Closes the 17 notes PR #27 declared as debt (N1-N14, N18-N20) and the open items of the debt sweeps
(T1-T3, #4 N1, #5 N1, #6 W1, #12 N1, #13 N3, #13 N4, D2, R7, R8, #19 N2, N4, N24, N26). The
`release.yml` items of the sweeps are left for 0.14.0.

### Added

- `scan-hidden.py` kind `link-ref-comment`: a Markdown link reference definition whose destination
  is `#` or `<>` (`[//]: # (text)`), which GitHub renders as nothing, also with the destination on
  the next line, an escaped `]` or a line break in the label, or inside a blockquote or list item. A
  definition with a real destination is not reported. The check reads a line of list or blockquote
  markers in one pass, so a comment of spaced markers that is not a definition cannot stall the scan
  (#27 N1, #28 W3, W5).
- `scan-hidden.py --feedback-json <file|->` scans a `fetch-feedback.py` list, which holds the
  review-thread comments and review bodies that `--pr` does not read. The loop runs it before
  dispatching the fixer, and the fixer's comment lane runs it on its own work list (#27 N2).
- The secret screen (`publish`, `lint-report`, `screen`, `push-guard.sh`) refuses a password
  assignment: a `password` or `passwd` key given a quoted value of eight or more characters, or, at
  the start of a line, an unquoted one on that same line. A value that reads as code (an identifier, a dotted name, a
  call, an index), a path or a placeholder is not counted, so `password = self.password` passes.
  The limit that follows: an unquoted value shaped like a variable name (a letter or underscore,
  then letters, digits, underscores and dots, such as `PASSWORD=` followed by one plain word) is not
  screened, since refusing it would refuse every assignment of a variable. A YAML key whose value is
  a nested mapping on the lines below (`password:`, then `valueFrom:`) is not an assignment
  (#12 N1, #28 W4).
- `fetch-feedback.py` items carry `minimized`, and two new actions: `skip: minimized` and
  `skip: dismissed` (#27 N5).
- `review-cycle.sh` can be sourced: run as a command it dispatches; sourced, it only defines its
  functions. `tests/fake-gh/run.sh` uses this to test `parse()` directly on crafted payloads (#4 N1).

### Changed

- `review-cycle.sh screen` exits 2, not 1, on a usage error (an unknown option, a missing value, two
  modes, no mode) and when the screen itself fails, so exit 1 always means a hit. `publish` and
  `lint-report` say INCONCLUSIVE instead of "looks like a secret" when the screen fails. Existing
  callers that treat any non-zero exit as "do not post" behave as before (#27 N10).
- The bearer pattern no longer counts a placeholder as a credential: `${NAME}`, `$NAME`, `<...>`,
  `[REDACTED]` and the like (R8).
- `fetch-feedback.py`: a `FIXER_TRUSTED_LOGINS` entry written as `app/<name>` or `<name>[bot]` names
  that bot only, never a person whose login is `<name>`; a bare entry still matches both.
  `REVIEW_MARKER_AUTHORS` keeps the one login grammar the scripts and the gate share: the bare login
  GraphQL prints, so a `<name>[bot]` entry there names nobody (#27 N4).
- The permission lookup in `fetch-feedback.py` and in `review-cycle.sh fix` reads `role_name` as well
  as the legacy `permission`; either field equal to admin, maintain or write, ignoring case, is write
  access. Each field is compared whole, so a custom role named "Write Docs" is not (#28 W2). The live
  response was checked for an admin (`{"permission":"admin","role_name":"admin"}`); the maintain and
  triage mapping of the legacy field is GitHub's documented one and was not observed (#27 N13).
- `push-guard.sh`: `PUSH_GUARD_ALLOW_SENSITIVE` may hold only lower-case letters, commas, spaces and
  tabs, so a class after a newline is refused rather than never read (#27 N7). A symlink target that
  steps back with `..` out of a component that is itself a link involves every class, the link
  names compared after the case fold, so `A/..` steps out of a link `a` (#27 N19, #28 W1). A
  link name or target holding a control character is printed quoted with `printf %q` (#27 N20).
- `tests/run-all.sh` puts a caller's `TEST_TAG` in front of each suite's tag, the triage suite has a
  `TEST_TAG` of its own, and every suite unsets `REVIEW_BLOCK_AT` and `PUSH_GUARD_ALLOW_SENSITIVE`
  when it starts (T1, T2).

### Fixed

- `push-guard.sh` exits 2 (INCONCLUSIVE) when git cannot show a commit's patch or file modes, or
  shows an empty patch for a commit that touches paths. Before, the failure was swallowed and that
  commit dropped out of the secret screen and the link check (#27 N9).
- The secret screen's patch mode and `scan-hidden.py --diff` report a path as the file is named:
  git's trailing tab after a name with a space and its C quotes (`"b/caf\303\251"`, a quote, a
  backslash) are undone (#27 N8).
- `lint-report` reads the same quoted paths, so a finding on `café.txt` is no longer "not in the
  diff", and refuses a backwards range such as `30-1` (R7).
- `fetch-feedback.py` fails closed on a review thread whose `comments`, `pageInfo`, `hasNextPage` or
  `nodes` is missing or malformed, instead of reading it as a thread with no comments (#27 N6).
- The `remove_states_except` comment said gh takes one name per flag; the real reason is that a
  space-joined value splits into two arguments. It now also states why the unquoted
  `$(remove_states_except ...)` is safe: `STATES_RE` admits only the five literal `review:*` names
  (#19 N24, #19 N4).

### Documentation

- README: the by-hand install for Claude Code copies the skills into `.claude/skills/` instead of
  linking them, and says why: a committed link under `.claude/skills` makes `push-guard.sh` refuse
  every fixer push (`sensitive-path`) unless a person sets `PUSH_GUARD_ALLOW_SENSITIVE=skills,claude`;
  an untracked link does not (#27 N18). "Check the install" names the skills folder per harness
  instead of hard-coding `.agents/skills` (D2). "Run it by hand" no longer claims the harness table
  lists every invocation prefix (#6 W1). The list of screened token kinds names npm, GitLab, Google
  OAuth and password assignments (#13 N3).
- `docs/HOW-IT-WORKS.md`: the fixer's Comment step describes the author gate `fetch-feedback.py`
  applies (#27 N11).
- Both `SKILL.md` files list `scan-hidden.py` and `pr-json.py`; the reviewer's step 0 runs
  `scan-hidden.py` (#27 N12).
- `security-checklist.md`: a hit inside source text the diff shows verbatim is dismissed and counted;
  an invisible character never is (#27 N3).
- `comment-triage.md`: a not-substantive `act` in a resolved thread is answered once in the declined
  form, so it stops coming back. This is a rule for the fixer, not a script change: GraphQL gives no
  time of resolution to order a comment against (#27 N14).
- `harness-loop.md`: `stale` moves nothing on a pull request with two review states; `start`, `fix`
  and `publish` each leave one (#19 N2).
- `AGENTS.md`: the gitignored test outputs include `work-*/` and `state-*/`; how `TEST_TAG` and the
  unset variables behave (#5 N1, T1, T2).

### Tests

- New rows: `tests/feedback/t.py` 11, `tests/push-guard/run.sh` 7, `tests/scan-hidden/t.py` 9 and
  `tests/fake-gh/run.sh` 22 (screen exit codes, placeholders, password assignments, quoted paths,
  lint-report paths and ranges, `parse()` sourced on crafted payloads, upper-case `block_at=` for
  `parse()`, `status` and the gate, two states with `review:needs-human` for `publish` and `fix`,
  `stale` on two states). Run against v0.12.0, 11 of the feedback rows, 4 of the push-guard rows,
  5 of the scan-hidden rows and 16 fake-gh rows fail (14 new, and the 2 existing `screen` rows
  whose expected exit changed from 1 to 2); the rest pin behaviour that was already right or values
  that must not be refused. The T3 rows were also checked against
  a copy of the scripts with the case fold of `block_at` removed from `parse()` and the gate: they
  fail there (T3, #19 N26).
- Rows from the first review of #28: `tests/push-guard/run.sh` 2 (W1), `tests/feedback/t.py` 4 and
  `tests/fake-gh/run.sh` 2 (W2), `tests/scan-hidden/t.py` 10 (W3), `tests/fake-gh/run.sh` 1 (W4).
  Each failing row failed before its fix. The fake `gh` now runs a permission lookup's `--jq` through
  real jq and takes a custom role as a `{"permission", "role_name"}` object.
- `tests/fake-gh/run.sh`: the section header "secrets and mentions" is now "secrets in a published
  report" (#13 N4).

## 0.12.0

### Added

- `scripts/scan-hidden.py`, shipped in both skills: reports zero-width characters and BOMs, bidi
  overrides and isolates (U+202A-U+202E, U+2066-U+2069), Unicode tag characters
  (U+E0000-U+E007F), HTML comments other than the five protocol marker forms, `<details>` blocks
  and invisibly styled HTML in the diff's added lines, the PR title, body and comments (through
  `pr-json.py`) and the commit messages. JSON output, exit 1 on hits, 2 when an input cannot be
  read. It strips nothing. The verdict marker regex is imported from the gate. Homoglyphs are not
  detected: without a confusables table the hits would be mostly noise. The loop runs it before the
  reviewer and the fixer; the reviewer treats each hit as a candidate CRITICAL prompt-injection
  finding, the fixer as "do not act" (I49).
- `pr-fixer/scripts/fetch-feedback.py <pr>`: review threads (resolved, outdated, path, line),
  review bodies and issue comments from GraphQL, with author association, as one JSON list of work
  items. It fails closed on any truncation. The comment lane works only from it (I26).
- `review-cycle.sh screen --staged`, `--patch <file>` and `--diff <base> <head>`: the secret screen
  over the added lines of the staged diff, a given diff, and a pull request from its merge base,
  printing `path:line kind` per hit and never the value. The fixer screens the staged diff before
  each commit (I53). The loop screens the pull request before dispatching the reviewer, and each hit
  is a mandatory CRITICAL "credential committed" finding (I54).
- `push-guard.sh` screens the added lines of the commits it would push (each commit's own changes)
  and refuses with reason `secret` (I53).
- `push-guard.sh` refuses any commit that touches `.github/workflows/**`, `.github/actions/**`,
  CODEOWNERS (root, `.github/`, `docs/`), `.agents/skills/**`, `.claude/**` or `.mcp.json`, with
  reason `sensitive-path`, even with `--allow` or a finding naming the file. A person can opt
  classes in with `PUSH_GUARD_ALLOW_SENSITIVE`; this repository's loop sets `skills` (I51).
- New suites `tests/scan-hidden/t.py` and `tests/feedback/t.py`.

### Changed

- The comment lane acts only on comments from the OWNER, a MEMBER or COLLABORATOR whose permission
  on the repository is admin, maintain or write (looked up once per login, the gate `fix` uses), the
  reviewer's login and bots in `FIXER_TRUSTED_LOGINS`; everything else is listed as
  `not acted: author not trusted` and never fixed (I52).
- The fixer resolves a review thread only when the reviewer's login or a trusted bot opened it; a
  thread a person opened gets the reply and stays open (I67).
- `pr-json.py` also returns the pull request's `title` and `body`, for `scan-hidden.py`.
- The foreign-edit refusal asks the author to edit the comment back and warns that deleting it would
  lose any BLOCKED history or highest pass it carried; marker signing stays on the backlog (#26 N2).
- The permanent stop after a foreign deletion names the way out: a person reads the timeline,
  closes the pull request and opens a new one from the same branch, where the review starts at
  pass 1 (#26 N4).

### Fixed

- `start` refuses when `REVIEW_MARKER_AUTHORS` names no login, before the foreign-edit check, so it
  no longer refuses with a permanent-stop message that names the wrong cause (#26 N1).
- `export-audit` resolves `--out` with every symbolic link followed and refuses a directory outside
  the repository top level, so `--out link/` and a committed `docs` link are refused (#26 N3).
- The git < 2.38 merge refusal in `push-guard.sh` has a test row (#26 N5).
- The diff parsers of `scan-hidden.py` and `screen --patch` count the lines of each hunk, as
  `lint-report` does, so an added line whose text starts with `++ ` (shown as `+++ ...`) is
  scanned instead of being taken for a file header (#27 W1).
- `screen --staged`, `screen --diff`, `push-guard.sh` check 6 and `scan-hidden.py --diff` read the
  diff with `--text --no-textconv`, so a file git treats as binary (a NUL byte, or a `binary` or
  `-diff` attribute from any `.gitattributes` or `.git/info/attributes`) is screened too (#27 W2).
- `push-guard.sh` check 5 also refuses a symlink added at a sensitive directory or file or at a
  parent of one (`.claude -> evil`, `.agents -> ag`, `.github/workflows -> ../ci`), which moved the
  real files to a path no class covers. It passes only when every class the path covers is named
  in `PUSH_GUARD_ALLOW_SENSITIVE` (#27 W3).
- `push-guard.sh` check 5 refuses the whole push when the pull request head or the local HEAD
  holds a symlink or a gitlink at a sensitive path or a parent of one (`.claude/skills ->
  ../skills`, a gitlink at `.claude`), or a symlink whose target, resolved lexically against the
  link's own directory, points at, into or above one (`src/x -> ../.claude`, `src/x -> ..`). Links
  are not followed, so an edit through a link, through a chain of links or through a link nested in
  another link's target is refused by the link itself. A symlink target holding a non-ASCII byte or
  leaving the repository (an absolute path, `..` above the root) is refused as if it reached every
  class. A link passes only when every class it involves is named in `PUSH_GUARD_ALLOW_SENSITIVE`.
  This replaces the link-following of earlier cycles of this pull request at the person's decision
  of 2026-10-21 (#27 W7, W8, N15, W10).
- `push-guard.sh` check 5 compares names after a Unicode fold broader than APFS or NTFS (NFKD,
  combining marks and default-ignorable code points dropped, case folded), for touched paths and
  links alike, so `.CLAUDE/x`, `.agents/ſkills/x` and an NFD spelling reach their class. All of
  check 5 runs in one node pass with one `git cat-file --batch` for the link targets, instead of a
  `tr` per link per class (#27 W9, W10, N16).
- The comment lane prescribes `Escalated (C1): <what the person must decide>` for an escalation,
  so `fetch-feedback.py` reads it back as the fixer's own reply instead of a work order (#27 W5).
- In a resolved thread, a comment after the fixer's last reply keeps its own action (`act`, or
  `not-acted: author not trusted`) instead of being dropped as `skip: resolved` (#27 W6).

### Not done

- I26 `dup_of` dedupe against the reviewer's findings and automatic re-anchoring of outdated
  threads; I54 merging `gitleaks` or `trufflehog` output (needs I57's trusted path resolution).

## 0.11.0

### Changed

- New subcommand `review-cycle.sh screen --file <file>`: the secret screen `publish` and
  `lint-report` already ran, for any other text an agent posts. Exit 0 clean, 1 naming the kind of
  secret (never the value), 2 when the file cannot be read. The fixer runs it before its closure
  comment, before writing the `pr-debt` body and before any overflow comment, and the reviewer
  before an overflow comment (S3).
- `push-guard.sh` checks merge commits. Each one is recomputed with
  `git merge-tree --write-tree <p1> <p2>` (git 2.38 or later), and every path where the commit
  differs from that automatic merge must be in scope, so an edit hidden inside a merge is refused
  and a conflict resolution needs `--allow`. An octopus merge, a merge git cannot recompute and any
  merge under an older git are refused (S4).
- `FIXER_TRUSTED_LOGINS` treats `app/<name>` (a bot author in `gh pr view`) and `<name>[bot]` (the
  same bot as a commit author) as one login, so listing either form admits a bot pull request (R5).
- `pr-json.py` reads the timeline's `CommentDeletedEvent` items through GraphQL into
  `deletedComments`, paging and failing closed like the comment query. A trusted comment deleted by
  anyone other than its author counts as a foreign change: BLOCKED history in the gate, `budget`
  answers `none`, and `publish`, `start` and `status` stop. A deletion cannot be undone, so the stop
  is permanent for that pull request. A deletion by the author stays the documented limit (#25 N5).
- `status` reports a trusted comment edited or deleted by another login and exits 2, and `start`
  refuses on it before any label moves. `stale` does not check it, and says why (#25 N2).

### Fixed

- `export-audit` no longer writes through a symlink: the temporary record is created with
  `tempfile.mkstemp` in the output directory, and the export refuses when the output directory or
  the final record path is a symbolic link (S9).
- `export-audit` reads the pull request and the timeline from temporary files instead of
  environment variables, which failed with "argument list too long" on a large pull request (R6).
- `push-guard.sh` compares touched paths with the scope byte for byte, NUL-delimited, instead of
  `grep -Fxq`, which split a path holding a newline into several patterns; a touched path or an
  `--allow` value holding a control character is refused (S5).
- The foreign-edit refusal in `publish`, `start`, `status` and `budget`'s `B_WHY` names the comment's
  url and the remedies that clear it: its author edits it back or deletes it. The old advice to
  restore it with a new comment did not clear it (#25 N6).
- Comments in `review-cycle.sh`: "an empty list skips nothing" holds only for a list that is not
  active, and `extend` refuses when no blocking finding is open, not only no CRITICAL.

### Documentation

- `pr-protocol.md` rule 2 and the `pr-json.py` docstring state that `IssueComment.editor` is
  assumed to name the last editor, which could not be checked without a second login (#25 N4).
- The fixer references no longer allow `--force-with-lease`: conflicts are resolved by merging the
  base into the head, and a rebase of a pushed branch is never pushed (`gh-commands.md`,
  `cycles-and-races.md`, `conflicts.md`, `lanes.md`, improvements-catalog item 51) (I35).
- README, HOW-IT-WORKS, the fixer `SKILL.md`, `harness-loop.md`, `pr-protocol.md`,
  `report-contract.md` and ISO row 6 describe the screen, the merge check, the bot login forms and
  the deleted-comment stop.

### Tests

- Rows for each item above: export through a symlink and a 1.5 MB pull request, bot logins in both
  forms, `screen`, deletion events in `budget`, `publish` and the gate, `pr-json.py` failing closed
  on the deletion query, `status` and `start` on a foreign edit or deletion, the url in the
  refusal, and evil, conflicted and octopus merges and a newline path in `push-guard.sh`. The fake
  `gh` gives each comment a url and serves the deletion query from a `deleted-events` file.

## 0.10.0

### Changed

- A trusted verdict marker edited by anyone other than its author now stops the loop. GitHub lets
  any collaborator with write access edit another login's comment, so such an edit could rewrite
  `pass=` (and the cycle count) or turn a BLOCKED into a PASSED (N4 of #24). `pr-json.py` records
  the login of the last edit (`IssueComment.editor`) in `editedComments`; `publish` refuses,
  `budget` answers `none` and names the editor, and the gate counts that marker as BLOCKED history,
  until a person deletes or restores the comment. This holds whether or not the edited body still
  reads as a marker, so a foreign edit that breaks the marker (for example `adversarial_review`)
  cannot drop it from the count unseen (W1 of #25). An edit by the author is treated as before; an
  editor GitHub no longer names counts as another login.
- `budget` takes the highest pass from `parse()` instead of reading the edited comments again, so
  `publish` and `budget` count edited markers the same way (N8 of #23).

### Documentation

- The gate says in a comment why it does not read a 0.7.x warning-only BLOCKED marker as published
  under `warning`: it fails any marker that is not PASSED, so the inference could only turn a red
  check into another red check (N3 of #23). The same inference in `parse()` and `budget` is covered
  by the B6 rows that check `status` and `budget` together.
- Rule 2 in `pr-protocol.md` no longer says it "stops an edit" without qualification, and no longer
  calls every edit an edit by a trusted login (N2 and N4 of #24). The `pr-json.py` comment and the
  `tests/budget/t.py` comment that still said an edit cannot lower the count now say it holds when
  the edit keeps the number (N1 and N3 of #24).
- The `none` row of the step-5 table in `harness-loop.md` lists a trusted comment edited by another
  login among the reasons (N1 of #25).

### Tests

- Rows for a foreign edit that breaks the marker shape, in `budget`, `publish` and the gate, and a
  row for an editor GitHub no longer names (the fake `gh` reads `-` in `edited-by` as a null login)
  (W1 and N3 of #25).

## 0.9.1

### Documentation

- The documents and comments that said an edit cannot lower the cycle count now say it holds only
  when the edit keeps the `pass=` number. Only the body after an edit is kept, so an edit that
  rewrites the number counts as the new number (N5 of #23). `pr-json.py` describes both reasons it
  keeps edited comments.
- Filter F2 in `pr-protocol.md` no longer claims to number the next pass. It reads only unedited
  comments and the newest marker; the numbers come from `B_NEXT_PASS` and `B_CYCLE` (N6 of #23).
- Rule 2 in `pr-protocol.md` says an edit can also raise the highest pass, up to the ceiling, which
  fails closed (N7 of #23).

## 0.9.0

### Changed

- `review-cycle.sh budget` counts cycles from the highest `pass=` among the trusted markers,
  whatever commit it names, not from the marker at the head. A head that went back to an older
  reviewed commit restarted the count at that commit's pass. `B_DONE` is now that highest pass
  minus 1 on every path, and `budget` prints two new fields: `B_CYCLE`, the cycle about to run, and
  `B_NEXT_PASS`, the pass number the next verdict must carry.
- `review-cycle.sh publish` accepts only `--pass` equal to `B_NEXT_PASS`. A lower number, the same
  number again, or a skipped one is refused. Callers that kept their own pass counter must read it
  from `budget`.
- `review-cycle.sh start` refuses a halted pull request (`review:needs-human`) whose BLOCKED verdict
  is still at the head, since a pass there has nothing new to review and only spends a cycle. A
  pushed correction or a grant ends the refusal.

### Fixed

- The highest trusted pass ignored edited verdict comments, so editing the newest marker lowered
  `B_NEXT_PASS` and `B_DONE`, and `publish` then accepted that pass number a second time (W1 of
  #23). `parse` and `budget` now count `pass=` from edited trusted markers too; an edited marker is
  still never read as a verdict.
- The `status` line on a halted pull request offered `extend` even after a ceiling halt, where
  `extend` refuses; it now says only a push helps there.
- `review-cycle.sh extend` left `review:needs-human` on a halted pull request, so the fixer and
  triage still refused it and the grant changed nothing. `extend` now removes the label after it
  posts the granted marker.
- `budget` compared the marker SHA with the head case-sensitively, so a marker with capital hex
  digits matched in `status` but not in `budget`.
- A BLOCKED marker from 0.7.x that counts warnings, no critical and names no `block_at` was
  published under `REVIEW_BLOCK_AT=warning`. `status` and `budget` now read it that way, so a shell
  under `critical` answers inconclusive and names the setting instead of acting on a BLOCKED with
  nothing blocking.
- `install.sh` checked its install rule once, before the plan, so a `.git` or a mount added to the
  old copy before its removal was not seen (N1 of #22). The rule now runs again on the set-aside
  copy right before the `chmod` and `rm -rf`. A copy that fails it is kept, named, and the run
  exits 1.

### Documentation

- The `none` row of `harness-loop.md` listed only a PASSED head and a missing verdict. It now names
  the setting errors that also answer `none` (no login in `REVIEW_MARKER_AUTHORS`, a bad or
  mismatched `REVIEW_BLOCK_AT`) and tells the loop agent to report `B_WHY` to the person.
- The README tests section and `AGENTS.md` give the `docker run --privileged` line that runs the
  Linux-only `install.sh` rows (N2 of #22), which no CI runs.

## 0.8.6

### Fixed

- `install.sh` read the frontmatter with `awk` in the caller's locale. Under a UTF-8 locale, macOS
  `awk` stops on a byte that is not UTF-8, so a copy installed without a locale was refused on the
  next run with a message saying the `name:` line was missing. The rule now runs `awk` with
  `LC_ALL=C`.
- A file system mounted inside a destination skill folder had its files removed with the old copy,
  and the `chmod` before the removal crossed into it. The rule now refuses a folder that holds a
  mount point, and the `chmod` runs with `-xdev`. A mount point is an entry `find -xdev` does not
  reach and, on Linux, a mount target under the folder in `/proc/self/mountinfo`, so a bind mount
  from the same file system, which keeps the device number, is refused too instead of being emptied
  with the old copy. The refusal says to unmount it first, not to move the folder away. Outside
  Linux an empty mounted file system, or a folder mounted from the same device, is not seen;
  removing the old copy then empties it or fails at the mount point, and the run exits 1, naming it.
- A source holding both `SKILL.md` and `skill.md`, possible on a case-sensitive file system, passed
  the rule, and the copy into a case-insensitive destination kept only one of them. The rule now
  refuses more than one `SKILL.md` in any letter case.
- A failed copy left its stage behind when its folders could not be read (a umask of `0400`, say),
  and said nothing about it. The cleanup now restores `u+rwx` before removing the stage, and names
  the stage when it still cannot be removed.
- An old copy that cannot be removed in full now says when it still holds a `SKILL.md`, since a
  harness that loads folders starting with a dot could load it.
- The `install.sh` header listed only refusals and the old-copy removal under exit 1. It now also
  lists a failed `mkdir`, copy or move with `--yes`, and says that with `--skill both`, `pr-reviewer`
  may already be replaced when a `pr-fixer` step fails. The README says what happens to an old copy
  that cannot be removed.

### Tests

- The install suite checks that the copy of a read-only source folder is writable (the row passed
  with that `chmod` removed), and adds rows for a frontmatter byte that is not UTF-8 under
  `C.UTF-8`, a stage its owner cannot read, an old copy whose `SKILL.md` cannot be removed, and
  `SKILL.md` beside `skill.md` (skipped on a case-insensitive file system), and a bind mount from
  the same file system inside the destination, at a path with a space (runs only as root on Linux,
  in a privileged container; it fails without the mount-table check).
- The `marker` locale row runs under `C.UTF-8`, which both macOS and glibc systems ship. On Debian 12
  (glibc 2.36) it fails with the `LC_ALL=C` line removed from `cmd_marker` and passes with it.

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
  destination skill folder is replaced only when it looks like an install of that skill: a real
  folder, nothing named `.git` in any letter case at any depth, and a `SKILL.md` whose frontmatter
  (the first `---` block, not the body) has the line `name: <skill>`. A file, a repository, or a
  person's own folder of that name is refused before any change, and before the dry run's plan, so
  the plan never says it will replace a folder that the rule refuses. With `--yes`, a leftover folder with
  the name of the run's stage or set-aside copy is refused instead of removed.
- The same rule now holds the source to what the destination must be. A source skill folder with
  CRLF line endings in `SKILL.md`, or with a `.git` inside, installed once and then refused its own
  copy on every later run. A trailing CR is now ignored on both sides, and a source that fails the
  rule is refused before any change. `cp -R` kept a read-only source folder read-only, so the next
  run could not remove the old copy and left it beside the new one while reporting success. The
  copy's folders are now made writable, an old copy holding a read-only folder is emptied in full,
  and an old copy that still cannot be removed is named and the run exits 1.
  `same_or_inside` returns at once on a relative path instead of looping (no caller passes one).
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
