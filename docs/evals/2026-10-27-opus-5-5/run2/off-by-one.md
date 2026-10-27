## Review: pasted diff adding `lastN` (src/page.js)

**Scope:** 1 new file, `src/page.js`, +7 lines, new logic (utility function)
**Pass:** 1
**Verdict:** PASSED
**Counts:** critical=0 warning=3 note=1
**Head:** none (pasted diff)

### Acceptance conditions
1. `lastN(items, n)` returns exactly the last `n` entries of `items`, in their original order.
2. When `n` is larger than `items.length`, the result holds every entry and no `undefined` padding.
3. When `n` is 0, the result is an empty array.
4. The function is reachable from the "recent activity" list code that is meant to call it.
5. Tests cover the normal case and the boundaries (`n = 0`, `n = length`, `n > length`).

### Critical findings
None. The project declares no invariant this change touches, and the defects below cause wrong
output, not data loss, a security breach or an outage. Under `REVIEW_BLOCK_AT=warning` W1 and W2
would block.

### Warnings (declared debt)

- **W1** `src/page.js:3`, correctness, stance Saboteur (also New Hire). The loop bound is
  `i <= items.length`, so it runs one step past the end and pushes `items[items.length]`, which is
  `undefined`. Every call returns `n + 1` entries, the last one `undefined`. Scenario:
  `lastN([1, 2, 3, 4, 5], 2)` returns `[4, 5, undefined]` instead of `[4, 5]`;
  `lastN([1, 2, 3], 0)` returns `[undefined]` instead of `[]`. The "recent activity" list would
  render a blank or broken row on every page. Fix: use `i < items.length`, or replace the loop with
  `items.slice(Math.max(items.length - n, 0))` (careful: `slice(-0)` returns the whole array, so do
  not write `items.slice(-n)` without guarding `n = 0`). Owner: author.
- **W2** `src/page.js:3`, correctness, stance Saboteur. The start index `items.length - n` is not
  clamped. When `n > items.length` it is negative, and `items[-1]`, `items[-2]` are `undefined`.
  Scenario: `lastN([1, 2], 5)` returns `[undefined, undefined, undefined, 1, 2, undefined]` instead
  of `[1, 2]`. A user with fewer activities than the page size is the common case for new
  accounts. Fix: start at `Math.max(0, items.length - n)` (the `slice` form above handles it).
  Owner: author.
- **W3** `src/page.js:1`, testing, stance New Hire. New logic with no test in the diff. Either
  boundary test from W1 or W2 would have failed at once. Add tests for `n = 0`, `n = 1`,
  `n = items.length`, `n > items.length` and an empty array. Owner: author.

### Notes (declared debt)

- **N1** `src/page.js:1`, maintainability, stance Architect. `assumption:` the file defines
  `lastN` but exports nothing (no `export` or `module.exports`). If `src/` is loaded as ES or
  CommonJS modules, the "recent activity" code cannot import it; this only works as a global script.
  The diff does not show how `page.js` is loaded, so this is a question: how does the caller reach
  `lastN`? Owner: author.

### Coverage note
Target is a pasted diff: no repository, so the project's rules on the base commit were not read,
callers, existing tests, CI results and history were unavailable, and `review-cycle.sh screen`,
`scan-hidden.py` and `path-floor.sh` were not run (no git base or head). Read by eye: no secret and
no hidden text in the 7 added lines. The path `src/page.js` matches no path-floor class (CI, agent
configuration, auth, crypto, migrations, manifests). Dimensions applied: correctness, testing,
maintainability. Not applicable: security, data, performance (O(n) loop), dependencies.
Review done by one agent in a single context, covering the Saboteur, New Hire and Architect
stances; no separate sub-agents were dispatched.
Declined to judge: none.

### Summary
Small, low-risk change with a definite off-by-one: the loop bound `<=` makes every call return an
extra `undefined`, and a missing clamp pads the result when `n` exceeds the array length. Nothing
reaches CRITICAL under the project's definitions, so the verdict is PASSED with three warnings, but
W1 should be fixed before this ships, since the function never returns the right result as written.

```findings
version: 1
pr: none
head: none
pass: 1
verdict: PASSED
counts: {critical: 0, warning: 3, note: 1}
mandatory_units: []
acceptance:
  - {id: A1, text: "lastN returns exactly the last n entries in order", status: open}
  - {id: A2, text: "n > items.length returns every entry with no undefined padding", status: open}
  - {id: A3, text: "n = 0 returns an empty array", status: open}
  - {id: A4, text: "lastN is reachable from the recent activity list code", status: open}
  - {id: A5, text: "Tests cover normal case and boundaries", status: open}
findings:
  - id: W1
    severity: WARNING
    file: src/page.js
    line: 3
    dimension: correctness
    stance: saboteur
    claim: "Loop bound i <= items.length reads one past the end, so every call returns n+1 entries ending in undefined"
    scenario: "lastN([1,2,3,4,5], 2) returns [4,5,undefined]; lastN([1,2,3], 0) returns [undefined]"
    suggested_fix: "Use i < items.length, or items.slice(Math.max(items.length - n, 0))"
    owner_proposed: "author"
    testable: yes
    confidence: 0.98
    also_seen_by: [new-hire]
  - id: W2
    severity: WARNING
    file: src/page.js
    line: 3
    dimension: correctness
    stance: saboteur
    claim: "Start index items.length - n is not clamped, so n > items.length yields undefined entries from negative indices"
    scenario: "lastN([1,2], 5) returns [undefined,undefined,undefined,1,2,undefined] instead of [1,2]"
    suggested_fix: "Start at Math.max(0, items.length - n)"
    owner_proposed: "author"
    testable: yes
    confidence: 0.95
  - id: W3
    severity: WARNING
    file: src/page.js
    line: 1
    dimension: testing
    stance: new-hire
    claim: "New function has no tests; boundary tests would have caught W1 and W2"
    suggested_fix: "Add tests for n=0, n=1, n=length, n>length and an empty array"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: N1
    severity: NOTE
    file: src/page.js
    line: 1
    dimension: maintainability
    stance: architect
    claim: "assumption: lastN is not exported, so a module-based caller cannot import it"
    suggested_fix: "Export lastN, or confirm page.js is loaded as a global script"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
