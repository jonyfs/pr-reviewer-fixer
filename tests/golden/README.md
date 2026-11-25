# Golden set: real pull requests

`tests/eval/` measures the reviewer on seeded defects in small made-up diffs. This folder measures it
on real pull requests of this repository: the defects a past review raised on the first pass, a fixer
closed, and a later pass confirmed (`verified`). A judge sub-agent decides which report finding, if
any, names each expected defect, and a second judge checks a sample of the first judge's work.

Nothing here calls a model, and nothing needs an API key. Scripts prepare inputs, check files and
score. The reviewer runs and the judging are done by sub-agents that the loop agent (or a person in
their own harness session) dispatches. `tests/run-all.sh` runs only the scripts' own tests, on
fixtures.

## The cases are candidates until a person validates them

Every case starts with `validated_by: none`. Its expected findings come from the review history,
not from a person: a finding the reviewer raised and later called verified can still be wrong, minor,
or described too narrowly. **An unvalidated case is a candidate only.** The scorer prints the
validated and unvalidated cases separately, and `--min-recall` is checked against the validated
cases only. Do not quote an unvalidated recall as the reviewer's recall.

To validate a case, read it next to its pull request and the fix, then:

- edit or remove an expected finding that is wrong, and fix a description that is off;
- run `python3 tests/golden/golden.py mark-validated pr-45 --login <your-github-login>`.

That writes your login, today's date and a digest of the case. A later edit to the case changes the
digest, and `golden.py validate` then refuses it until someone validates it again. Only a person runs
`mark-validated`; an agent never marks a case validated.

## Cases

20 cases, one per merged pull request, in `cases/pr-<n>.json` (46 expected findings in all, 1 CRITICAL
and 45 WARNING; 15 testing, 14 security, 7 correctness, 6 reliability, one each of architecture,
design, documentation and performance). They are every pull request from #30 to #94 whose first trusted pass raised a
finding that was later verified after a fixer closure: 33, 35, 36, 38, 40, 41, 44, 45, 70, 73, 75, 78,
79, 80, 82, 83, 88, 89, 90 and 92. The rest were skipped: no such finding (most), not merged (54, 58,
93, 94), a trusted marker comment edited (87), or the only verified id moved to another file between
passes (71, 85). Two more ids were left out the same way inside kept cases: W4 of #80 and W3 of #89. The set leans on tests, security and reliability findings in shell and Python; it
says nothing yet about other languages.

A case file has these fields, and no others:

| field | meaning |
| --- | --- |
| `schema` | 1 |
| `repo`, `pr` | the pull request |
| `base`, `head` | the 40-digit shas the first pass reviewed: `head` is that verdict's `sha=`, `base` the merge base of `head` with the base branch as it stood when the verdict was posted (its newest first-parent commit not after the verdict). When the base branch was deleted (#35 and #36 targeted release branches), its tip at merge time stands in, which can be newer than what the first pass saw. `build-cases.py` fetches the base branch first and flags a base whose base..head does not hold exactly the pull request's own commits up to `head`. One shipped case is flagged and kept: #38's base..head holds 6 commits, but GitHub now lists 1 of them, because #38's branch had taken in #35 (merged into it at 19:40, before #38's first verdict at 19:55 on 2026-10-26) and those commits reached main by another route before #38 merged; none of the 6 was on main when the verdict was posted, so the base is what the first pass saw |
| `pass` | the verdict's pass number |
| `expected` | a list of `{id, source_id, file, lines, dimension, severity, description}`: `id` is E1, E2, ...; `source_id` the finding's id in the verdict; `lines` is `[start, end]` in the new file; `description` is one sentence written from the verdict and the fix diff |
| `validated_by` | `none`, or the login of the person who validated it |
| `validated_at`, `validated_digest` | null, or the date and the digest `mark-validated` wrote |

`python3 tests/golden/golden.py validate` checks every case against these rules.

### Building more cases

`build-cases.py` drafts cases from merged pull requests. It is read-only on GitHub and calls no model:

```bash
REVIEW_MARKER_AUTHORS=jonyfs python3 tests/golden/build-cases.py --prs 95-120 --out /tmp/golden-drafts
```

It trusts a marker only from a login on `REVIEW_MARKER_AUTHORS`, reads comments through
`pr-json.py` (an edited comment is never read), skips a pull request where a trusted comment was
edited or deleted by someone else, and reads each findings block through `review-cycle.sh
findings-block`. Run it inside a clone of this repository: it fetches the base branch there, and
marks the draft `base_check: mismatch` and exits 2 when the base..head commit count differs from the
pull request's own commits up to the first-pass head (GitHub's list, which is as of the merge): check
that base by hand before you keep the case. A draft (`pr-<n>.draft.json`) carries the reviewer's own claim and the fix head, so
whoever finishes it can write the description from the claim and `git diff <head> <fix head>`.
`golden.py validate` refuses a draft as it stands: copy only the case fields into `cases/pr-<n>.json`,
write each `description` in your own words, then run `golden.py prepare` (below) to check that every
expected line sits inside the case's diff. Aim to grow the set past 20 with each batch of merged pull
requests, and validate each new case before you count it.

## Run it

A run is a folder of its own under `tests/golden/runs/` (git ignores it). Each step below is done by
the loop agent or the person; the scripts only check and count.

1. **Prepare.** `python3 tests/golden/golden.py prepare --run tests/golden/runs/2026-12-01-<model>`
   writes each case's diff to `inputs/<token>.patch`, under a token that does not name the pull
   request, `map.json`, and the judge's copy of each case in `judge-cases/`. It refuses a case whose expected lines are not inside its diff.

2. **Review.** For each token, start a fresh-context reviewer sub-agent. Check the case's head out in
   a separate worktree first (`git worktree add /tmp/golden-<token> <head>`), so the code around the
   diff is the code the first pass saw and the later fix is not there to read. The blinding is
   not a wall: the worktree shares this repository's refs and objects (`git log --all` there shows
   the fix commits), and the token is a hash of the case name that anyone can recompute, so it hides
   the name only from a casual reader. What keeps the reviewer from looking is the prompt. Give it:

   ```text
   Follow <checkout>/.agents/skills/pr-reviewer/SKILL.md. You were dispatched by the review loop
   agent: skip the Version Notice. The target is a pasted diff: read
   <checkout>/tests/golden/runs/<run>/inputs/<token>.patch. The repository at the diff's head is
   /tmp/golden-<token>; read files there for context. There is no pull request and no description:
   do not publish, do not call review-cycle.sh, and do not read GitHub or this repository's git
   history, and do not open tests/golden/cases/, tests/golden/runs/<run>/map.json or any judge file.
   Write the report to <checkout>/tests/golden/runs/<run>/reports/<token>.md. It must end with the
   fenced findings block.
   ```

3. **Judge.** For each case, start a fresh-context judge sub-agent with `tests/golden/JUDGE.md`, the
   judge's copy of the case (`judge-cases/<case>.json`, which prepare writes without `source_id`, so
   no verdict id can anchor a match), the report (`reports/<token>`, `map.json` names it), the diff and the output path
   `judge-a/<case>.json`.

4. **Second judge.** `python3 tests/golden/golden.py sample --run <run>` lists the cases the second
   judge must see: 20% of the cases, at least 3, picked by a hash of the run folder's name. The
   pick is repeatable, not secret: anyone who knows the folder name knows the sample, so do not tell
   the primary judge which cases will be checked. For each,
   start another fresh judge sub-agent with the same prompt, `judge` set to `"b"`, writing
   `judge-b/<case>.json`. Do not show it the first judge's file.

5. **Score.**

   ```bash
   python3 tests/golden/golden.py score --run tests/golden/runs/<run>
   python3 tests/golden/golden.py score --run tests/golden/runs/<run> --json
   python3 tests/golden/golden.py score --run tests/golden/runs/<run> --min-recall 0.7
   ```

Exit 2 means an input is missing or malformed (a report without a findings block, a judge file that
breaks a rule of JUDGE.md, a sampled case without a second judge, a malformed case): nothing is
scored on a guess. Exit 1 means the judges disagreed on at least one finding, or `--min-recall` was
missed on the validated cases.

## Reading the result

- **Recall** is matched expected findings over expected findings, from the primary judge, printed
  for validated and unvalidated cases apart, in all and per severity and per dimension.
- **Unmatched report findings** are counted per severity. They are not called false positives: the
  set lists only the defects a past review confirmed fixed, so a report finding outside it may be a
  real defect nobody fixed. Read them before you draw a precision figure from them.
- **Matched at a lower severity** counts matches whose report severity is below the expected one.
- **Judge agreement** is the share of expected findings, in the cases both judges saw, where both
  named the same report finding (or both `none`). Each disagreement is printed as `DISAGREEMENT
  <case> <id>: judge-a ..., judge-b ...`. A person settles it by reading the report and, when the
  primary judge was wrong, rewriting `judge-a/<case>.json`; then score again. Agreement below about
  0.9 means the judge prompt or the descriptions need work before the recall means much.

To keep a result, commit the printed table with the model id and the date under `docs/evals/`, as
`tests/eval/` does. Say how many cases were validated.
