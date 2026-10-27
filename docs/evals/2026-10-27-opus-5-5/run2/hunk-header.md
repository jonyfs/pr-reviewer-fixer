## Review: pasted diff, new `tools/anchors.py` (`new_side_ranges`)

**Scope:** 1 file, 11 added lines, new utility (unified-diff hunk parser)
**Pass:** 1
**Verdict:** PASSED
**Counts:** critical=0 warning=3 note=4
**Head:** none (pasted diff)

### Acceptance conditions
1. For every file in a git unified diff, `new_side_ranges` returns the new-side line range of each hunk, keyed by the path the findings use.
2. It handles every hunk header form git emits, including an omitted count (`+N`) and a zero count (`+N,0`), without raising.
3. Content lines of a hunk are never mistaken for file or hunk headers.
4. The new parsing logic has tests covering the header forms above.

### Critical findings
None.

### Warnings (declared debt)
- **W1** `issue:` `tools/anchors.py:9` (correctness, saboteur; also architect). Unpacking `start, n = ....split(",")` raises `ValueError` when git omits the count, which it does for every one-line hunk (`@@ -0,0 +1 @@`, `@@ -5 +5 @@`). Reproduced: `new_side_ranges(["+++ b/a.py", "@@ -0,0 +1 @@"])` raises `ValueError: not enough values to unpack`. Any diff adding a one-line file or changing one line crashes the anchoring step. Fix: parse with `re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", ln)` and default the count to 1. Owner: author.
- **W2** `issue:` `tools/anchors.py:5` (correctness, saboteur). The `+++ ` test runs on every line, including hunk bodies, so an added line whose content begins with `++ ` (e.g. a C `++ i` continuation, a Markdown or diff fixture) is read as a new file header. Reproduced: `["+++ b/a.py", "@@ -1,2 +1,3 @@", "+++ x", "@@ -9,1 +9,2 @@"]` returns `{'a.py': [(1, 3)], 'x': [(9, 10)]}`: the second hunk of `a.py` is attributed to a phantom file `x`, so a valid finding on `a.py:9` is rejected. Fix: track remaining hunk line counts (or only accept `+++ ` immediately after a `--- ` line / `diff --git`). Owner: author.
- **W3** `todo:` `tools/anchors.py:1` (testing, new-hire). No test accompanies new parsing logic; W1 and W2 would both have been caught by a table test of header forms. Add tests for `+N`, `+N,M`, `+N,0`, `/dev/null`, quoted paths and a body line starting with `++ `. Owner: author.

### Notes (declared debt)
- **N1** `suggestion:` `tools/anchors.py:10` (correctness, saboteur). A zero-count hunk (`+3,0`, pure deletion) yields the inverted range `(3, 2)`. Harmless for a `start <= line <= end` test, but any consumer that iterates or sizes ranges gets garbage. Skip `n == 0`. Owner: author.
- **N2** `suggestion:` `tools/anchors.py:6` (correctness, architect). A deleted file is keyed `/dev/null` (and all deletions share that key), and git's quoted paths (`+++ "b/a b.py"`, or non-ASCII with `core.quotePath`) keep the quotes and the `b/` prefix, so lookups by the real path miss. Ignore `/dev/null` and unquote C-style quoted paths. Owner: author.
- **N3** `question:` `tools/anchors.py:2` (documentation, new-hire). The docstring says "ranges its hunks add", but the range is the whole new-side hunk, context lines included. The description ("lines the diff shows") suggests context lines are intended; if so, reword the docstring; if only added lines should anchor, the logic is wrong. Confidence 0.6. Owner: author.
- **N4** `assumption:` `tools/anchors.py:8` (security, security-auditor). The function assumes well-formed git output: a `@@` line before any `+++` header raises `KeyError: None`, and nothing bounds input size. Fine for trusted `git diff` output; if it ever parses a user-pasted diff, fail with a clear error instead. Owner: author.

### Coverage note
Target is a pasted diff: repository code, callers, conventions, history, tests and CI were unavailable; the project's rules (base commit) were not read. `screen`, `scan-hidden.py`, `path-floor.sh` and `lint-report` were not run (no repository commits; instructed not to call `review-cycle.sh`). By inspection `tools/anchors.py` matches no path-floor class (CI/agent config, auth/crypto, migrations, manifests), so `mandatory_units` is empty. Findings W1, W2, N1 and N2 were reproduced by running the function from the diff in a scratch directory. Dimensions applied: correctness, testing, documentation, security (input trust); others not applicable to an 11-line pure function. Stances: saboteur, new-hire, security-auditor, architect, single reviewer session (no sub-agents).
Declined to judge: callers of `new_side_ranges` (not in the diff).

### Summary
Small, readable parser with two real input-handling bugs: it crashes on git's count-less one-line hunk header (W1), and treats added lines beginning with `++ ` as file headers (W2). Nothing reaches CRITICAL, so the verdict is PASSED with debt; fix W1 first, since one-line hunks are routine.

```findings
version: 1
pr: none
head: none
pass: 1
verdict: PASSED
counts: {critical: 0, warning: 3, note: 4}
mandatory_units: []
acceptance:
  - {id: A1, text: "Returns new-side range of each hunk per file, keyed by path", status: open}
  - {id: A2, text: "Handles +N and +N,0 hunk headers without raising", status: open}
  - {id: A3, text: "Hunk content lines never read as headers", status: open}
  - {id: A4, text: "Tests cover the header forms", status: open}
findings:
  - id: W1
    severity: WARNING
    file: tools/anchors.py
    line: 9
    dimension: correctness
    stance: saboteur
    claim: "Hunk header without a count (one-line hunk, '@@ -0,0 +1 @@') raises ValueError on unpack"
    scenario: "new_side_ranges(['+++ b/a.py', '@@ -0,0 +1 @@']) raises ValueError: not enough values to unpack"
    suggested_fix: "Parse with a regex and default the count to 1"
    owner_proposed: "author"
    testable: yes
    confidence: 0.95
    also_seen_by: [architect]
  - id: W2
    severity: WARNING
    file: tools/anchors.py
    line: 5
    dimension: correctness
    stance: saboteur
    claim: "An added line whose content starts with '++ ' is parsed as a '+++ ' file header, misattributing later hunks"
    scenario: "['+++ b/a.py','@@ -1,2 +1,3 @@','+++ x','@@ -9,1 +9,2 @@'] gives {'a.py': [(1,3)], 'x': [(9,10)]}"
    suggested_fix: "Track remaining hunk line counts, or accept '+++ ' only right after a '--- ' header"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: W3
    severity: WARNING
    file: tools/anchors.py
    line: 1
    dimension: testing
    stance: new-hire
    claim: "New diff-parsing logic ships with no tests"
    suggested_fix: "Add table tests for +N, +N,M, +N,0, /dev/null, quoted paths, body lines starting with '++ '"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: N1
    severity: NOTE
    file: tools/anchors.py
    line: 10
    dimension: correctness
    stance: saboteur
    claim: "Zero-count hunk (+3,0) yields inverted range (3, 2)"
    suggested_fix: "Skip hunks whose new-side count is 0"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: N2
    severity: NOTE
    file: tools/anchors.py
    line: 6
    dimension: correctness
    stance: architect
    claim: "Deleted files keyed '/dev/null'; git-quoted paths keep quotes and 'b/' prefix"
    suggested_fix: "Ignore /dev/null and unquote C-style quoted paths before removeprefix"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: N3
    severity: NOTE
    file: tools/anchors.py
    line: 2
    dimension: documentation
    stance: new-hire
    claim: "Docstring says ranges the hunks add, but ranges include context lines"
    suggested_fix: "Reword the docstring, or restrict to added lines if that is the intent"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
  - id: N4
    severity: NOTE
    file: tools/anchors.py
    line: 8
    dimension: security
    stance: security-auditor
    claim: "assumption: input is well-formed trusted git output; '@@' before any '+++' raises KeyError: None"
    suggested_fix: "Raise a clear error on a hunk with no current file"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
```
