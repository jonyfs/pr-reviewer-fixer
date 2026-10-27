## Review: pasted diff adding scripts/scope-check.sh

**Scope:** 1 new file, scripts/scope-check.sh (11 added lines; the hunk header claims 13), new shell gate
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=2 warning=2 note=3
**Head:** n/a (pasted diff)

### Acceptance conditions
1. For every commit in `base..HEAD`, every path the commit adds, modifies, deletes or renames (both sides of a rename) is checked against the allowed folder.
2. Any out-of-scope path makes the script exit non-zero and name the path.
3. If the commit range or any commit cannot be read (bad base, unfetched base, git error), the script exits non-zero; it never passes by reading nothing.
4. An in-scope-only range exits 0.

### Critical findings

**C1. Gate fails open when `git rev-list` fails** (scripts/scope-check.sh:6, reliability/security, saboteur)
`for c in $(git rev-list "$base"..HEAD)` runs the command in a substitution inside a `for` word list; `set -e` does not see its exit status. A base that does not resolve (typo, a base not fetched in a shallow CI clone) produces an empty loop, `bad` stays 0, and the script exits 0. The same holds for `git show` inside the `< <(...)` process substitution on line 9: its failure is never checked.
Failure scenario (reproduced in a scratch repo): `scope-check.sh allowed nosuchref` prints `fatal: ambiguous argument 'nosuchref..HEAD'` and exits 0, so a push touching any file passes.
Fix: resolve and verify first (`git rev-parse --verify "$base^{commit}" >/dev/null`), capture the list in an assignment (`commits=$(git rev-list "$base"..HEAD)`, which `set -e` does check), and capture each commit's file list the same way (or `wait $!` on the process substitution) before reading it.

**C2. Rename hides the out-of-scope source path** (scripts/scope-check.sh:9, security, security-auditor)
`git show --name-only` uses rename detection by default and prints only the destination of a rename. A commit that moves `secret/k` to `allowed/k` deletes an out-of-scope file, yet only `allowed/k` is listed, so the commit passes. Porcelain `git show` also follows user config (`diff.renames`, copies), so results vary by machine.
Failure scenario (reproduced): repo with `secret/k`; commit `git mv secret/k allowed/k`; `scope-check.sh allowed <base>` exits 0 and prints nothing.
Fix: use plumbing with renames off, e.g. `git diff-tree --root --no-commit-id -r --no-renames --name-only -z "$c"` (and `-m` or `--cc` handling chosen deliberately for merges), so both the deleted source and the added destination are checked.

### Warnings (declared debt)

**W1. No tests for a new gate** (scripts/scope-check.sh:1, testing, new-hire) — owner: author.
Both criticals above would be caught by a fixture test (rename into the folder, bad base, deletion, path with spaces/newline, merge commit). Add a scratch-repo test.

**W2. Argument forms silently refuse everything or give a raw error** (scripts/scope-check.sh:4, correctness, new-hire) — owner: author.
No usage check: a missing argument dies with `unbound variable`; `allowed=src/` builds the pattern `src//*`, which never matches, so every commit is reported out of scope; `allowed=.` likewise. Scenario: `scope-check.sh src/ main` on a commit touching only `src/a` exits 1 with `out of scope: src/a`. Normalise a trailing slash and print usage on `$# -ne 2`.

### Notes (declared debt)

**N1. question: which commits is "the push"?** (scripts/scope-check.sh:6, intent, architect) — owner: author.
The description says it walks every commit in the push, but the code walks `base..HEAD`. In a pre-push hook the pushed refs come on stdin and need not be HEAD; pushing another branch would check the wrong range. State the intended caller or take the head as an argument.

**N2. Hunk header does not match the body** (scripts/scope-check.sh:11, documentation, new-hire) — owner: author.
`@@ -0,0 +1,13 @@` announces 13 lines; 11 are present. Either the paste is truncated or lines are missing from the review; confirm the file is complete.

**N3. assumption: the allowed value is a plain path prefix** (scripts/scope-check.sh:8, security, security-auditor) — owner: author.
`"$allowed"/*` is quoted, so glob characters in the argument are literal; good. The gate also relies on `-z` for odd file names (also good). It still assumes a single allowed folder; multiple paths, as the header comment's "allowed paths" implies, are not supported.

### Coverage note
Target is a pasted diff: no repository, no base commit, no history, no CI. Project rules were not read from a base commit. `review-cycle.sh screen`, `scan-hidden.py` and `path-floor.sh` were not run against git refs (no PR, no commits); by inspection of `path-floor.sh` rules, `scripts/scope-check.sh` matches no floor class (not under `.github/`, no auth/crypto/migration/manifest name), so the unit floor is empty. C1 and C2 were reproduced by running the added script in a scratch git repository. Dimensions reviewed: correctness, security, reliability, testing, intent. Not applicable: performance, data, privacy, UI. Agents: single reviewer, all four stances, deep tier; no parallel sub-agents.
Declined to judge: callers of the script (not in the diff); the two lines the hunk header claims but the paste lacks.

### Summary
A scope gate that passes when it cannot read the range (C1) and misses the source side of a rename (C2) does not enforce scope; both reproduce in a scratch repo. Fix C1 first: verify the base and check git's exit status, then switch to `git diff-tree --no-renames`.

```findings
version: 1
pr: none
head: none
pass: 1
verdict: BLOCKED
counts: {critical: 2, warning: 2, note: 3}
mandatory_units: []
acceptance:
  - {id: A1, text: "Every path each commit in base..HEAD adds, modifies, deletes or renames (both sides) is checked", status: open}
  - {id: A2, text: "Any out-of-scope path exits non-zero and names the path", status: open}
  - {id: A3, text: "An unreadable range or commit exits non-zero, never passes", status: open}
  - {id: A4, text: "An in-scope-only range exits 0", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: scripts/scope-check.sh
    line: 6
    dimension: security
    stance: saboteur
    claim: "git rev-list failure inside the for-loop substitution (and git show in the process substitution) is ignored, so the gate exits 0"
    failure_scenario: "scope-check.sh allowed nosuchref prints a git fatal error and exits 0; an unfetched base in a shallow clone passes any push"
    suggested_fix: "git rev-parse --verify \"$base^{commit}\"; capture rev-list and per-commit lists in assignments so set -e sees failures"
    testable: yes
    confidence: 0.95
    also_seen_by: [security-auditor]
  - id: C2
    severity: CRITICAL
    file: scripts/scope-check.sh
    line: 9
    dimension: security
    stance: security-auditor
    claim: "git show --name-only with rename detection lists only the rename destination, so moving an out-of-scope file into the allowed folder passes"
    failure_scenario: "commit git mv secret/k allowed/k; scope-check.sh allowed <base> exits 0 though secret/k was deleted"
    suggested_fix: "use git diff-tree --root --no-commit-id -r --no-renames --name-only -z \"$c\""
    testable: yes
    confidence: 0.95
  - id: W1
    severity: WARNING
    file: scripts/scope-check.sh
    line: 1
    dimension: testing
    stance: new-hire
    claim: "New scope gate has no tests (rename, bad base, deletion, odd names, merge)"
    suggested_fix: "Add a scratch-repo test suite covering those cases"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: W2
    severity: WARNING
    file: scripts/scope-check.sh
    line: 4
    dimension: correctness
    stance: new-hire
    claim: "No argument validation; a trailing slash in allowed makes every path out of scope, a missing argument gives an unbound-variable error"
    scenario: "scope-check.sh src/ main on a commit touching only src/a exits 1 with out of scope: src/a"
    suggested_fix: "Check $# -eq 2 with a usage line; strip a trailing slash from allowed"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: N1
    severity: NOTE
    file: scripts/scope-check.sh
    line: 6
    dimension: intent
    stance: architect
    claim: "question: description says every commit in the push, code walks base..HEAD; a pre-push hook pushing another ref checks the wrong range"
    suggested_fix: "Take the head ref as an argument or document the caller"
    owner_proposed: "author"
    testable: yes
    confidence: 0.6
  - id: N2
    severity: NOTE
    file: scripts/scope-check.sh
    line: 11
    dimension: documentation
    stance: new-hire
    claim: "Hunk header announces 13 lines but the body has 11; paste may be truncated"
    suggested_fix: "Confirm the file content is complete"
    owner_proposed: "author"
    testable: no
    confidence: 0.7
  - id: N3
    severity: NOTE
    file: scripts/scope-check.sh
    line: 8
    dimension: security
    stance: security-auditor
    claim: "assumption: a single plain-prefix allowed folder; the header says allowed paths (plural) but only one is supported"
    suggested_fix: "Accept several prefixes or fix the header comment"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
```
