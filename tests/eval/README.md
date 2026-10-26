# Review evals

The unit tests in `tests/` check the scripts. They cannot tell whether the reviewer finds real
defects. This folder measures that: seeded cases with known defects, and a scorer that reads the
reviewer's reports and prints recall and precision.

Nothing here calls a model. `tests/run-all.sh` runs only the scorer's own tests, against canned
reports. You produce the real reports yourself, in your own harness session.

## Cases

Each case is a folder under `cases/`:

- `diff.patch`: a unified diff of new code.
- `description.txt`: what a pull request description would say.
- `expected.json`: the defects the review must find (`file`, `line`, `tolerance`, `min_severity`) and
  the decoys it must not flag.

`sql-injection` has one CRITICAL and a safe query beside it. `off-by-one` has one WARNING.
`clean-rename` has no defect, so every CRITICAL or WARNING there counts against precision.
`mention-url`, `push-guard-rename` and `hunk-header` are bugs this repository really had, cut down to a
self-contained diff. Each has one WARNING. With the default `REVIEW_BLOCK_AT=critical` such a bug is
reported and the pull request still passes; run the cases again with `REVIEW_BLOCK_AT=warning` set to
see whether the reviewer backs each one with a `scenario:` and whether precision holds.
`missing-authz` (OWASP A01:2025) and `fail-open` (A10:2025) have one CRITICAL each beside a safe
twin. `retry-double-charge` (reliability), `n-plus-one` (scalability), `drop-column` (data
integrity, CRITICAL), `pii-in-logs` (privacy) and `recreate-deploy` (operability) each seed one
defect of the engineering-quality dimensions added in 0.16.0, with a decoy.
Check that the expected lines sit inside the diffs, and that no decoy's window overlaps a defect's (a
finding there would score as the defect), with `python3 tests/eval/score.py --validate`.

## Run it

For each case, start a fresh-context sub-agent in your harness and give it this prompt, with the
case name filled in:

```text
Follow .agents/skills/pr-reviewer/SKILL.md. The target is a pasted diff: read
tests/eval/cases/<case>/diff.patch, and use tests/eval/cases/<case>/description.txt as the pull
request description. There is no pull request, so do not publish and do not call review-cycle.sh.
Write the report to tests/eval/reports/<case>.md. It must end with the fenced findings block.
```

Then score the folder:

```bash
python3 tests/eval/score.py --reports tests/eval/reports
python3 tests/eval/score.py --reports tests/eval/reports --min-recall 0.8 --min-precision 0.8
```

The second form exits 1 when a threshold is missed. A report that is missing or has no `findings`
block exits 2: nothing is scored on a guess.

## Reading the result

A finding is a hit when it names the same file, lies within `tolerance` lines of the defect, and has
at least the defect's `min_severity`. Notes are not counted. A CRITICAL or WARNING that hits no
defect lowers precision, and one that lands on a decoy is also listed under `decoy hits`.

Three cases are a smoke test, not a benchmark. Add a case for each defect class you care about
before you trust a number, and run the same cases again after a change to the skill prose or a
change of model. To keep a result, commit the printed table with the model id and the date under
`docs/evals/`.
