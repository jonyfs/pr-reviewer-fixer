## Review: pasted diff adding `wrap_mentions` (tools/mentions.py)

**Scope:** 1 new file, `tools/mentions.py`, 12 added lines; new feature (text transform)
**Pass:** 1
**Verdict:** PASSED
**Counts:** critical=0 warning=4 note=1
**Head:** n/a (pasted diff)

### Acceptance conditions
1. A bare `@login` in prose comes out wrapped in backticks, so posting the text notifies nobody.
2. A mention inside a code span is left unchanged.
3. Text such as a URL or an email address comes out byte-for-byte unchanged.

### Critical findings
None.

### Warnings (declared debt)
- **W1** `tools/mentions.py:10` (correctness, saboteur). The lookbehind `(?<![\w`@])` only excludes word characters, backtick and `@`, so an `@` after `/`, `:`, `-`, `.` or `<` is rewritten. Reproduced: `https://medium.com/@alice/post` becomes ``https://medium.com/`@alice`/post``, which breaks the link and contradicts condition 3. Fix: skip matches inside URL-like tokens (e.g. lookbehind also excluding `/`, `:`, `.`, `-`, or tokenise URLs first). Owner: author.
- **W2** `tools/mentions.py:8` (correctness, security-auditor). Code spans are found by splitting each line on single backticks and taking every other segment. An unmatched backtick or a double-backtick span shifts the parity, so prose after it is treated as code and the real mention is left bare and notifies. Reproduced: ``use ``a`b`` cc @bob`` and ``it` is @bob`` both return `@bob` unwrapped. Fix: parse code spans by backtick-run length (CommonMark rule), treat an unmatched run as literal. Owner: author.
- **W3** `tools/mentions.py:7` (correctness, saboteur). Processing is per line, so a fenced code block (```` ``` ```` on its own lines) is not seen as code: `"```\n@bob\n```"` becomes `` "```\n`@bob`\n```" ``, inserting literal backticks into the code shown in the report. This changes code content the description says must be left alone. Fix: track fenced-block state across lines and skip lines inside a fence. Owner: author.
- **W4** `tools/mentions.py:4` (testing, new-hire). New logic with no tests; each case above (URL, email, double-backtick span, unmatched backtick, fenced block) is a one-line table test. Owner: author.

### Notes (declared debt)
- **N1** `tools/mentions.py:10` (architecture, architect). assumption: the login pattern `[A-Za-z0-9-]+` stops at `/`, so `@org/team` becomes ```@org`/team``. It no longer notifies, but the team name is split from its wrapping; wrapping `@org/team` whole would read better. Owner: author.

### Coverage note
Target is a pasted diff: no repository code, callers, project conventions (rules not read from a base commit), history, tests or CI were available. `review-cycle.sh screen`, `scan-hidden.py` and `path-floor.sh` were not run (no base/head commits); by inspection the only path is `tools/mentions.py`, which maps to no mandatory unit. The behaviour claims in W1 to W3 were reproduced by running the function from the diff on the quoted inputs. Dimensions applied: correctness, testing, security (notification leak), architecture. Not applicable: data, migrations, dependencies, performance (linear in input size), operability.
Declined to judge: none

### Summary
Small, well-scoped helper whose core idea works on simple input, but the line-by-line backtick-split heuristic fails both ways: it alters URLs and fenced code it must leave alone, and it misses real mentions after an unmatched backtick or a double-backtick span. Nothing blocks at the default threshold; the most important fix is a CommonMark-aware code-span and fence parse plus a URL exclusion, with tests for each case.

```findings
version: 1
pr: null
head: null
pass: 1
verdict: PASSED
counts: {critical: 0, warning: 4, note: 1}
mandatory_units: []
acceptance:
  - {id: A1, text: "A bare @login in prose is wrapped in backticks", status: open}
  - {id: A2, text: "A mention inside a code span is left unchanged", status: open}
  - {id: A3, text: "A URL or an email address comes out unchanged", status: open}
findings:
  - id: W1
    severity: WARNING
    file: tools/mentions.py
    line: 10
    dimension: correctness
    stance: saboteur
    claim: "Mentions in URL paths are rewritten: the lookbehind does not exclude '/', ':', '.', '-'"
    scenario: "wrap_mentions('https://medium.com/@alice/post') returns 'https://medium.com/`@alice`/post'"
    suggested_fix: "Exclude URL-like contexts (lookbehind on / : . - or tokenise URLs first) and test it"
    owner_proposed: "author"
    testable: yes
    confidence: 0.95
  - id: W2
    severity: WARNING
    file: tools/mentions.py
    line: 8
    dimension: correctness
    stance: security-auditor
    claim: "Per-line single-backtick split mis-detects code spans; real mentions after an unmatched backtick or a double-backtick span stay bare and notify"
    scenario: "wrap_mentions('use ``a`b`` cc @bob') and wrap_mentions('it` is @bob') both leave @bob unwrapped"
    suggested_fix: "Match code spans by backtick-run length per CommonMark; treat unmatched runs as literal text"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
    also_seen_by: [saboteur]
  - id: W3
    severity: WARNING
    file: tools/mentions.py
    line: 7
    dimension: correctness
    stance: saboteur
    claim: "Fenced code blocks are not recognised, so mentions inside them get literal backticks inserted"
    scenario: "wrap_mentions('```\\n@bob\\n```') returns '```\\n`@bob`\\n```'"
    suggested_fix: "Track fence state across lines and skip lines inside a fenced block"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: W4
    severity: WARNING
    file: tools/mentions.py
    line: 4
    dimension: testing
    stance: new-hire
    claim: "New text-transform logic ships with no tests"
    suggested_fix: "Add table tests: plain mention, email, URL with /@, single and double backtick spans, unmatched backtick, fenced block"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: N1
    severity: NOTE
    file: tools/mentions.py
    line: 10
    dimension: architecture
    stance: architect
    claim: "assumption: login pattern stops at '/', so @org/team is wrapped as `@org`/team"
    suggested_fix: "Allow an optional /team suffix in the pattern"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
```
