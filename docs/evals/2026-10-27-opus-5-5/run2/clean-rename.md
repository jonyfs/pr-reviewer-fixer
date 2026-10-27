## Review: pasted diff, rename `total` to `sum` in src/util.ts

**Scope:** src/util.ts, 1 hunk, 4 lines removed, 4 added; mechanical rename (function and locals)
**Pass:** 1
**Verdict:** PASSED
**Counts:** critical=0 warning=0 note=4
**Head:** n/a (pasted diff)

### Acceptance conditions
1. The exported function is renamed from `total` to `sum`, and its locals get clearer names.
2. The body computes the same result for every input as before (no behavior change).
3. Every reference to `total` that this rename affects is updated in the same change.

Status: 1 and 2 hold on the diff (the loop, the accumulator start value `0` and the return are
unchanged token for token apart from names). 3 cannot be checked from a pasted diff: the
description says the only caller was updated in a file the diff does not show.

### Critical findings
None.

### Warnings (declared debt)
None.

### Notes (declared debt)
- **N1** `question:` src/util.ts:1 (api-compat, security-auditor). `total` was an exported name
  and is now gone. The description says the only caller was updated in a file not in this diff;
  that file, any test importing `total`, and any external consumer (if `src/util.ts` is re-exported
  from a package entry point) cannot be confirmed here. If one remains, the build fails at compile
  time, or a published consumer breaks. Suggest including the caller's hunk in the review, or a
  `grep -rn "\btotal\b" src test` result; if the module is public API, keep
  `export const total = sum` as a deprecated alias for one release. Confidence 0.5. Owner: author.
- **N2** `assumption:` src/util.ts:1 (correctness, saboteur). "No behavior change" rests on no code
  reaching the function by a string name (`util["total"]`, `jest.spyOn(util, "total")` with a
  loosely typed module, a serialised registry). Those references are not compile errors in every
  setup and would fail only at run time. Owner: author.
- **N3** `assumption:` src/util.ts:1 (design, architect). The rename assumes no other `sum` is
  exported from a module that re-exports `./util` with `export *`; a clash there makes the name
  ambiguous (TS2308) or hides one of them. Not checkable from the pasted diff. Owner: author.
- **N4** `praise:` src/util.ts:1 (readability, new-hire). `sum(values)` with `acc`/`v` reads better
  than `total(xs)` with `t`/`x`; the signature and return type stay explicit. Owner: author.

### Coverage note
Target is a pasted diff: repository code, project conventions on the base commit, history, tests
and CI were not available, so project rules were not read, callers could not be searched, and
`review-cycle.sh screen`, `scan-hidden.py` and `path-floor.sh` were not run (no git refs; by its
path `src/util.ts` maps to no mandatory unit). No credential or hidden text seen in the diff by
reading. Change class: mechanical rename, reviewed in full (8 lines). Dimensions applied:
correctness, api-compat, readability, design; others not applicable (no I/O, no state, no
concurrency, no dependencies). Agents: single reviewer applying the four stances in one context.
Declined to judge: the caller file named in the description (not in the diff, context missing).

### Summary
A behavior-preserving rename of a small pure function; the body is unchanged apart from names.
The only real risk is outside the diff: a remaining reference to the removed export `total`,
which a pasted diff cannot rule out. Nothing blocks.

```findings
version: 1
pr: null
head: null
pass: 1
verdict: PASSED
counts: {critical: 0, warning: 0, note: 4}
mandatory_units: []
acceptance:
  - {id: A1, text: "Exported function renamed total -> sum with clearer local names", status: closed}
  - {id: A2, text: "Body computes the same result for every input", status: closed}
  - {id: A3, text: "Every reference to total affected by the rename is updated in the same change", status: open}
findings:
  - id: N1
    severity: NOTE
    file: src/util.ts
    line: 1
    dimension: api-compat
    stance: security-auditor
    claim: "Exported name total removed; the updated caller, tests and any external consumer are not in the diff and cannot be confirmed"
    suggested_fix: "Show the caller hunk or a grep for total; if public API, keep export const total = sum as a deprecated alias"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N2
    severity: NOTE
    file: src/util.ts
    line: 1
    dimension: correctness
    stance: saboteur
    claim: "assumption: no string-keyed reference to total (dynamic access, spies, registries) that the compiler would not catch"
    suggested_fix: "Search for the string \"total\" in tests and registries"
    owner_proposed: "author"
    testable: no
    confidence: 0.4
  - id: N3
    severity: NOTE
    file: src/util.ts
    line: 1
    dimension: design
    stance: architect
    claim: "assumption: no other sum export collides through an export * barrel"
    suggested_fix: "Check barrels that re-export ./util"
    owner_proposed: "author"
    testable: no
    confidence: 0.3
  - id: N4
    severity: NOTE
    file: src/util.ts
    line: 1
    dimension: readability
    stance: new-hire
    claim: "praise: clearer names, explicit signature kept"
    suggested_fix: "none"
    owner_proposed: "author"
    testable: no
    confidence: 0.9
```
