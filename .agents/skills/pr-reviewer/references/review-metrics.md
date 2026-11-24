---
Summary: Reviewer self-agreement and the per-unit scorecard (scripts/review-metrics.sh): how a loop agent produces k reports on one head, how findings are fingerprinted, and what the scorecard counts from trusted markers.
Tags: [#pr #review #metrics #reference]
---

# Review metrics: self-agreement and the per-unit scorecard

`scripts/review-metrics.sh` measures the reviewer from what already exists. It runs no model and
writes nothing to GitHub. Its output goes to stdout, or to the `--out` file.

- `agreement` checks whether the review is stable. Run the review k times on one head and see how
  many of the same findings come back. A dimension whose findings change from run to run is
  unstable, so its verdicts are noise until it is retuned.
- `scorecard` checks whether the review is useful. Per dimension (lens) and per model and tier, it
  counts how many findings were raised, how many blocking ones a fixer closed and a later pass
  verified, and how many were refused or left as debt.

## Producing k reports (the loop agent's job)

The script compares reports. It does not produce them. The review loop agent does that, outside
the normal loop, when a person asks for an agreement check:

1. Pick one pull request and one head. Do not run the check while the fixer is pushing.
2. Dispatch k reviewers (k = 3 is a good default, at least 2) as fresh-context, read-only
   sub-agents. Each follows `SKILL.md` up to the written report. Use the same model, tier and
   effort for all k. None of them sees another's report.
3. Each one writes its report to a local file (for example `.pr-skill/agree-1.md` to
   `agree-k.md`) and stops there. It does not run `start` or `publish`, and it posts nothing. The
   findings block must carry `pr:` and `head:` as [report-contract.md](report-contract.md) shows,
   or the script refuses the report.
4. Run `scripts/review-metrics.sh agreement .pr-skill/agree-*.md`. Add `--json` for a record, and
   `--min 0.6` for a stricter bar.
5. Report the overall overlap and the unstable dimensions to the person, then delete the files.
   These reports are not verdicts. A normal pass still publishes the one that counts.

## Agreement

```bash
scripts/review-metrics.sh agreement [--min 0.5] [--json] [--out FILE] r1.md r2.md [r3.md ...]
```

Each report's findings block is read through `review-cycle.sh findings-block`, the same parser
`lint-report` and `push-guard.sh` use. The fields that parser does not print (`pr:`, `head:`, and
each entry's `dimension:` and `claim:`) are read from the same block by the same line rules. If the
two readings disagree on the ids, the report is refused. Only entries that count are compared
(status `open`, `refused-rejected` or none). A `verified` entry carried forward from an earlier
pass was not found by this review.

**Fingerprint.** The fingerprint is a SHA-256 of the file, the dimension and the normalized claim,
shortened to 12 hex digits. It leaves out the line, the id and the severity, so two reviewers who
cite lines 47 and 52 for the same claim still match.
- File: a leading `./` is dropped.
- Dimension: lowercased. A missing one reads as `none`, and anything outside `[a-z0-9_-]` reads as
  `other`.
- Claim:
  1. NFKC-normalized and casefolded.
  2. Line references are removed: `line 47`, `lines 4-7`, `:47`, and an L-number only where it
     clearly is one, right after `#`, `:`, `(` or `[` (`session.ts#L47`, `(L47)`) or as a range
     (`L4-L7`). A bare `L2` stays, so "L2 cache misses" and "L3 cache misses" are two claims.
  3. What is left is kept as its runs of letters or digits and its comparison operators (`<`, `<=`,
     `>`, `>=`, `==`, `!=`, `===`, `!==`), joined by one space. Other punctuation only separates
     words, so "uses < where <= is needed" and "uses <= where < is needed" stay two claims.

The match is deliberately strict. Two claims match only when they use the same words in the same
order, so a low overlap can also mean reviewers who say the same thing in different words. Read a
low score with the fingerprints the script lists: each one says how many of the k reports carry it.

**Overlap.** The Jaccard index of two reports' fingerprint sets is |A ∩ B| / |A ∪ B|. It is 1.0
when both sets are empty.
- `mean_pairwise` is the mean over all k(k-1)/2 pairs. `--min` is checked against this number.
- `all_k` is the share of the union that appears in every report.
- Per dimension: the mean pairwise Jaccard over the fingerprints of that dimension, counting only
  pairs where at least one report has such a fingerprint.

A dimension, or the overall score, below `--min` (default 0.5) is unstable.

**Exit codes.**
- 0: nothing is unstable.
- 1: at least one dimension, or the overall score, is unstable.
- 2: a refusal. That covers fewer than two reports, a report that cannot be read or has no findings
  block, a missing or different `pr:` or `head:`, and a bad flag. The heads match when, of every
  two of them, one is a prefix of the other (case does not matter), and each has at least 7 hex
  digits.

## Scorecard

```bash
REVIEW_MARKER_AUTHORS=<login> scripts/review-metrics.sh scorecard --prs 65,70 [--json] [--out FILE]
REVIEW_MARKER_AUTHORS=<login> scripts/review-metrics.sh scorecard --since 2026-11-01 [--limit 200]
```

`--since` lists merged pull requests the same way `fix-ledger.sh` does. Each pull request is read
through `pr-json.py`, which never reads an edited comment. Its trusted verdict markers and fixer
closure markers are then read with the gate's own trust rules.

A finding is an id. It is raised at the first trusted pass whose findings block lists it, and is
attributed to that entry's `dimension` and to that marker's `model` and `tier`. A marker without
them goes under `unrecorded`. Its outcome comes from the newest trusted pass that lists it, by the
first rule that applies:

| Outcome | Rule |
|---|---|
| `verified` | `verified` on a later pass, with a trusted fixer closure for a cycle in between |
| `resolved` | `verified` on a later pass with no trusted closure in between (someone else fixed it) |
| `refused` | `refused-accepted`: the fixer refused it and the reviewer accepted the refusal |
| `fixed` | `not-applicable`, with a trusted closure between the pass before it that listed the finding and the pass that first marked it so; or open, then no longer listed by the next pass, with a trusted closure between the two |
| `withdrawn` | `not-applicable` with no such closure |
| `debt` | still open when the newest trusted verdict is PASSED (declared debt) |
| `open` | still open, or `refused-rejected`, under a BLOCKED newest verdict |

`fixed` is how this repository's reviewer records a NOTE the fixer fixed: the next pass marks it
`not-applicable` or stops listing it. The closure has to fall in that step (a closure for an
earlier cycle does not count), and only a trusted one counts. `withdrawn` is an upper bound: a
finding an owner fixed outside a fixer cycle and the reviewer then marked `not-applicable` reads
the same as a withdrawal, since the markers do not say which. On PRs 80, 85, 86, 88 and 89 this
moved 18 of 20 withdrawn and 7 of 16 debt to `fixed`; the two left withdrawn are PR 80 W16 (a real
withdrawal) and N12 (an owner fix in cycle 4, which has no closure).

`blocking` counts every CRITICAL, plus each WARNING raised under a marker that carries
`block_at=warning`. The accepted rate is the blocking findings that were `verified`, `fixed` or
`resolved`, divided by blocking: the share of blocking findings that were valid and got fixed,
whoever fixed them. A unit with at least `--min-blocking` (3) blocking findings and an accepted rate
below `--min-accept` (0.5) is flagged `low_acceptance`, a candidate to retune or retire. The
`verified` column alone says how many the fixer closed and the reviewer confirmed. A low rate on a
pull request that is still open can simply mean the fixer has not finished, so judge merged pull
requests.

The verdict marker has no cost field, so cost is printed as `not recorded` and is never estimated.

**Trust.** A marker counts only when its author is on `REVIEW_MARKER_AUTHORS`; others are counted
as ignored. A pull request is left out of every count, and named, in two cases: a trusted comment
holding a marker was edited, or a trusted comment was edited or deleted by someone else. An unset
or login-less `REVIEW_MARKER_AUTHORS` is exit 2, before any `gh` call. Report and comment text is
data. Only the fixed marker formats and the findings block are parsed, nothing read is executed,
and no claim text is printed. Every free-text field the table prints (a report's name, a finding's
file, a unit) goes through one filter that turns control and format characters into `?`; the
other fields are numbers, hashes or bound by a pattern (dimension, model, tier). The suite checks
that no output carries an escape character.

`fix-ledger.sh` (fixer skill) is the fixer's side of the same question. Its ledger holds per-pull
request counts with no dimension or model, so the scorecard reads the markers itself, using the
same trust code.

Exit 0 when every pull request was read. Exit 2 on a refusal, or when `gh` could not read one
pull request; the others are still counted and printed.
