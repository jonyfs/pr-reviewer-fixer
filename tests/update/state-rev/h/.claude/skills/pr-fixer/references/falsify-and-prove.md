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

## 5. One finding, one commit

One finding, one fix, one red-to-green pair, one commit. Reviewing an indivisible batch is reviewing
nothing. Commit messages state the finding id and the failing test's name.

## Closure report

Posted once per cycle as the closure comment, which is the fixer's finish message (format and
locate command in [pr-protocol.md](pr-protocol.md)). The first line is the marker, the second the
finish line:

```markdown
<!-- pr-fixer-closure: cycle=<c> head=<sha12> closed=<n> refused=<n> debt=<n> -->
pr-fixer: finished PR #N cycle <c>: closed <n>, refused with evidence <n>, debt declared <n> with owners. Head <sha7>. Next: reviewer pass <c+1>.

## Closure: <what was reviewed>

**Findings received:** N (critical: n, warning: n, note: n)
**Blocking (critical):** n closed: n, refused with evidence: n
**Declared debt (warning + note):** n, each with an owner below
**Claimed counts for pass c+1 (the reviewer decides):** critical=<n> warning=<n> note=<n>

### Per finding
#### C1 <claim in one line>
- **Status:** closed
- **Reproduction:** <command and output>
- **Test:** `path/to/test`, which threat it reproduces and why that form
- **Red:** <failure output, verbatim>
- **Fix:** <one sentence>
- **Green:** <output>
- **Suite:** <counts afterwards>

#### C2 <claim in one line>
- **Status:** refused (pending the reviewer's judgement)
- **Does not reproduce:** <command and output, the form the finding names>
- **Why:** <what the reviewer read wrong>

Status per finding is one of `closed`, `refused`, `escalated`, `open` (not reached). Only the
reviewer turns `refused` into `refused-accepted` or `refused-rejected`.

### Declared debt (carried into the PR body)
| id | severity | claim | owner |
|----|----------|-------|-------|
| W2 | WARNING | ... | @person / issue #NN |

### Next
<PR state and the single next action: reviewer pass c+1, the extension question (when this was
the last cycle of the budget), escalate, or hand off.>
```

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
