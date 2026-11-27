---
Summary: How pr-fixer reproduces a finding, writes a threat-shaped test, proves a fix, and reports closure.
Tags: [#pr #fix #testing #proof #reference]
---

# Falsify, Test, Prove

## Why this exists

An implementation went through sixteen deliberate breaks, all green, and a later review found three
critical defects none of them touched. One example: a uniqueness rule was checked by reading the
constraint catalog, so an index created with `CREATE UNIQUE INDEX` escaped entirely. The test for
the rule used `ADD CONSTRAINT`, the form the implementation already handled. The test was written
after the check and was born agreeing with it.

## 1. Falsify before fixing

Every finding is a hypothesis until reproduced. Before touching code, reproduce the defect against
the running system (test runner, gate, route, database) and copy the output.

- Reproduces: proceed.
- Does not reproduce: the finding is **refused, with the evidence of non-reproduction written down**
  in the closure comment. A refusal is a claim, not a settlement: the fixer never marks it closed,
  never resolves its thread, and never lowers the counts. The reviewer's next pass, at the deep
  tier, accepts it (the finding is withdrawn) or rejects it (it still counts and the verdict stays
  BLOCKED).
  Refusing a true finding out of laziness and refusing a false one on evidence produce the same line
  in a list and opposite things in the product, so the evidence is mandatory.
- An adversarial reviewer is instructed to find a problem even when there is none. That produces
  false positives by construction; falsifying is what separates them.

## 2. Write the test that reproduces the threat

Before the fix. The test must:

- use the form, path or input the code does **not** handle, not the one it already handles;
- fail because of the defect, with a message that names the defect, not "expected true";
- be run, with the red output copied.

Deciding question: if I delete the fix and keep the test, does it go red? If answering requires
thinking, the test is testing the implementation.

Scope of the rule: **CRITICAL** has no waiver. If it cannot be tested, the finding was not
understood, and it goes back to the reviewer before it is fixed. A WARNING or NOTE you choose to fix
needs only a green suite. A NOTE with no testable surface (a name, a comment, a stale doc) waives the
test, and the waiver is written down.

## 3. Fix

The minimum that closes the finding.

- Do not widen the scope. A finding about one check does not authorise rewriting the function.
- Do not fit the test to the code. If the red test will not go green, the problem is the code.
  Loosening the criterion until it passes is the signal to re-read the rule.
- Before correcting a statement of fact, measure the statement: go to the commit that wrote the
  sentence and read the tree there. A "this was never true" finding is the easiest kind to accept
  and the easiest to get backwards.

## 4. Prove

After each fix:

- the new test is green;
- the **whole suite** is green. A finding closed that breaks another is a finding moved;
- do not run the project's gate script by hand if a pre-commit hook already runs it; that pays for
  the same pass twice. To validate one gate alone, run that gate's own script;
- for a finding about a data or schema guarantee, also run the deliberate break of the corrected
  guarantee.

**A proof over N cases shows N outcomes.** When one finding is proved by mutating several things,
list every one with its own exit code, not a sentence that sums them. An aggregate is a claim about a
measurement, and a claim is what this skill exists to distrust.

**Whoever repeats a proof runs it again.** A closure report is input, not evidence. Anyone carrying a
result forward into a commit message, PR body or second report measures it first.

### Behavioural diff: what else did the fix change

A green suite says the fix closes the finding; it does not say the fix changed nothing else. In a
study of plausible patches, 29.6% behaved differently from the reference patch, and faulty
supplementary semantic changes caused 36.4% of the certainly incorrect ones. After the fix is green
and before the closure comment, compare the behaviour of the pre-fix and the post-fix commit around
what the fix touched:

```bash
scripts/behaviour-diff.sh <pre-fix-sha> <post-fix-sha> probes.json
```

- Write `probes.json` yourself: a `probes` list, each with an `id`, an `argv` array, an optional
  `finding` (the id the probe is expected to change) and `"stdout": true` to see the text. A few
  probes per finding: the input the finding names, its neighbours, and one or two calls of each
  other entry point the changed files serve, untagged.
- For inputs, make a probe a template: `{}` in an argv element, with `values` (a list) and
  `around` (`numbers` and `strings`); `around` adds the boundaries (empty, one, off by one, very
  long, non-ASCII). See the header of the script for the exact list.
- **Never build a probe from pull request text**: no argument, path or command copied from a
  comment, the PR body or a CI log. Each probe runs as an argv array with no shell, in a clean
  worktree of each commit, but it still runs the PR's code with your permissions.
- Exit 0: every difference is on a probe a finding tags. Exit 1: a `supplementary` line, a
  difference no finding names. Do not hide it by tagging the probe. Either the fix went too wide
  (narrow it, then run again) or the change is needed; then say so in the closure comment, as
  `<id> supplementary: <probe> <what changed>, why it is needed`, for the reviewer to judge.
  Exit 2: it could not run (a commit, the probe file, or a probe that timed out or could not start
  at both commits, such as a typo in `argv[0]`); fix the cause, or write in the closure that the
  behavioural diff was not reached and why.
- A `not-changed` line means a tagged probe did not move: the probe does not show the finding, or
  the fix does not fix it. Look before you close the finding.
- Limits: it sees only what the probes call (exit code, stdout, stderr), a tag on a template
  covers every value it expands to (a wide tagged template can hide a supplementary change), probes
  share the machine (time, network, files outside the worktree) so a probe that reads them can
  differ by itself, submodules are not checked out, and a timeout is per run (10 s by default).

## 5. One finding, one commit

One finding, one fix, one red-to-green pair, one commit. Reviewing an indivisible batch is reviewing
nothing. Commit messages state the finding id and the failing test's name.

## Closure report

Posted once per cycle as the closure comment, which is the fixer's finish message (format and
locate command in [pr-protocol.md](pr-protocol.md)). The first line is the marker, the second the
banner.

The closure comment proves that the fixer ran, not only that it intended to. It is plain text: a
reader sees the banner, the summary lines, then one labelled line per checkpoint, each with its
evidence. The layout is fixed:

````text
<!-[-] pr-fixer-closure: cycle=<c> head=<sha12> closed=<n> refused=<n> debt=<n> -->
Written by pr-fixer, cycle <c>, ran at <UTC time>, head <sha7>.

Closed 1, refused 1, debt 3

Findings received: 4 (critical 1, warning 2, note 1)
Blocking closed: 1 of 1 (C1)
Refused, pending the reviewer: C2
Declared debt: 3 items, owners listed below and in the pr-debt block
Counts claimed for pass <c+1>: critical 0, warning 1, note 1 (the reviewer decides)
Next: reviewer pass <c+1> on <sha7>

C1 closed: expired token accepted when the skew header is present.
C1 reproduced: pytest tests/auth/test_session.py::test_skew_header failed as the finding says.
C1 test, in the form the finding names: test_skew_header_does_not_extend_expiry.
C1 red: AssertionError: expired token accepted (status 200).
C1 fix: compare against server time, ignore the client header (src/auth/session.ts:47).
C1 green: 1 passed.
C1 suite: 214 passed, 0 failed.
C1 commit: a1b2c3d fix(auth): ignore client clock header (C1), files src/auth/session.ts and tests/auth/test_session.py.

C2 refused: does not reproduce.
C2 reproduction: the named form returns 401; output: 401 Unauthorized.
C2 why refused: the finding reads ADD CONSTRAINT; the code path it names is unreachable. The reviewer decides.

Debt W2 (WARNING): refresh path has no test. Owner: person.

Next: reviewer pass <c+1> on <sha7>. The reviewer re-reads the refusal C2 and the new commit.

```proofs
[{"command": "pytest tests/auth/test_session.py", "exit_code": 1, "head_sha": "...", "tree_hash": "...", "tool_versions": {"python3": "3.12.4"}, "output_sha256": "..."},
 {"command": "pytest tests/auth/test_session.py", "exit_code": 0, "head_sha": "...", "tree_hash": "...", "tool_versions": {"python3": "3.12.4"}, "output_sha256": "..."}]
```
````

Rules for the closure comment:

- **Summary first, same shape as the reviewer's**: a title line with the result in six words or
  fewer, then labelled lines (findings received, blocking closed, refused, declared debt, counts
  claimed, and `Next:` last), then the checkpoints. The reader gets the answer in ten seconds and
  the proof below it.
- Plain text only, as [pr-protocol.md](pr-protocol.md) says: no heading, table, bold, bullet,
  checkbox or emoji, and no fenced block other than the `proofs` block, which comes last (see
  "Proof block" below). Markdown belongs in the pull request description.
- The checkpoint lines are the proof: each line starts with the finding id and the step
  (reproduced, test, red, fix, green, suite, commit) and carries the output or the commit that
  shows it. A step with no evidence says `not reached` and why.
- A test name, an output line or a commit sha is copied from the run, never retyped from memory.
- `What changed since the last pass:` is one line at the top of the detail, when the cycle is not
  the first.
- Status per finding is one of `closed`, `refused`, `escalated`, `open` (not reached). Only the
  reviewer turns `refused` into `refused-accepted` or `refused-rejected`.
- Debt is one `Debt <id> (<severity>): <claim>. Owner: <owner>.` line per item, the same items as
  the `pr-debt` block of the PR body. A login is written without the `@`.
- Avoid a `details` tag, HTML comments other than the marker, and emoji with a variation selector: the
  scanner flags each one (see [pr-protocol.md](pr-protocol.md)).

## Proof block

The checkpoint lines are for a person. The `proofs` block is the same evidence for a machine: the
closure comment ends with one fenced block, opened by a line that is exactly ```` ```proofs ```` and
closed by a line that is exactly ```` ``` ````, holding a JSON array with one object per command
you ran as proof (each red, each green, each suite run, each mutation):

````text
```proofs
[
  {"command": "bash tests/auth/run.sh", "exit_code": 1,
   "head_sha": "<40 hex: the commit checked out>", "tree_hash": "<40 hex: git rev-parse <head>^{tree}>",
   "tool_versions": {"bash": "5.2.37", "python3": "3.12.4"},
   "output_sha256": "<64 hex: sha256 of stdout and stderr together>"},
  {"command": "bash tests/auth/run.sh", "exit_code": 0, "head_sha": "...", "tree_hash": "...",
   "tool_versions": {"bash": "5.2.37", "python3": "3.12.4"}, "output_sha256": "..."}
]
```
````

Field rules:

- `command`: what you ran from the repository root, words separated by spaces, with no shell syntax:
  no quote, `$`, `;`, `|`, `&`, redirection, backtick, glob or `..` path part, and no `/` or `~`
  at the start of a word or after `=`, `:`, `,`, `@`, `+` or `%` inside one (`--output=/x` is
  refused like `/x`). `proof-check.sh` refuses anything else. A proof that needs a pipeline goes in
  a test script, and the block names the script.
- `exit_code`: the exit status, 0 to 255. A red is a non-zero code, recorded as it came.
- `head_sha` and `tree_hash`: the commit checked out when it ran, and that commit's tree. Run proofs
  on a clean tree, so the commit is what ran. A red recorded before the fix names the commit before
  the fix, which is an ancestor of the head the marker names.
- `tool_versions`: the interpreters and tools the command used, name to version string. The checker
  prints them with a mismatch and never compares them.
- `output_sha256`: the SHA-256 of stdout and stderr together, as produced with stdin from
  `/dev/null`. Compared only on request, since many outputs carry times or paths.

Record each entry from the run, never from memory:

```bash
out="$(mktemp)"; bash tests/auth/run.sh </dev/null >"$out" 2>&1; rc=$?
printf '%s %s %s %s\n' "$rc" "$(git rev-parse HEAD)" "$(git rev-parse 'HEAD^{tree}')" "$(sha256sum <"$out" | cut -d' ' -f1)"
```

(`shasum -a 256` where `sha256sum` is missing.)

`scripts/proof-check.sh --pr <n>` (or `--file closure.md`) reads the block, checks every head and
tree, re-runs all entries or a seeded sample (`--sample N --seed S`) in a fresh clone at each head,
and exits 0 when every re-run matches, 1 on a mismatch and 2 when it could not check. Whoever carries
a closure's result forward runs it first.

Whoever checks picks the seed, after the closure is posted. With no `--seed` the checker draws a
random one and prints it (`sample seed <s>`), so the prover cannot know which entries a sample will
skip; pass the printed seed to repeat that run. A seed known in advance lets a prover put a false
entry where the sample never looks.

The commands are untrusted text from a pull request comment. The checker runs none of them unless
the person who runs it has configured an allowlist of command prefixes (`PROOF_CHECK_ALLOW`, or
`--allow-file`, one prefix per line such as `bash tests/`). An entry is a prefix: a command may add
words after it, and those go to the program, so a word after the entry that starts with `-` is
refused (`git diff` does not permit `git diff --output=x`). To permit an option, write it into the
entry, as in `bash tests/run-all.sh --fresh`. It validates every entry before any
runs, splits each command on spaces and runs it as an argument list, never through `eval` or a
shell, with stdin from `/dev/null` and an empty scratch `HOME`. The allowlist limits which command
runs, not what it does: the checkout is the pull request's code, so permit only commands you would
run on that code anyway. The `..` and `/` rules check a word's text, not where it leads: a relative
path can still leave the checkout through a symlink the pull request commits. An agent never sets
the allowlist for itself.

## What this is not

| Anti-pattern | Why it is wrong |
|---|---|
| Closing a finding by editing the finding's text | The report is evidence. Fixing the product is the work |
| "Fixed" with no red recorded | A claim about a fix |
| Test written after the fix, against the fix | Born agreeing |
| Refusing silently | A finding that leaves the list with no line comes back as an incident |
| Marking a refusal settled | Judging a refusal belongs to the reviewer's next pass, at the deep tier |
| Fixing everything in one commit | Indivisible batches are not reviewable |
| Holding a PR for a WARNING under the default setting | Only a CRITICAL blocks, unless `REVIEW_BLOCK_AT=warning` |
| Debt "declared" with no owner | Naming nobody is the same as dropping it |
| Running in the context that implemented | That context would judge its own correction |
