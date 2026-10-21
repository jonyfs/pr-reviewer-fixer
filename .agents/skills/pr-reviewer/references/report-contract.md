---
Summary: Layout of the pr-reviewer report and the machine-readable findings block that pr-fixer consumes.
Tags: [#pr #review #contract #reference]
---

# Report Contract

## Layout

```markdown
## Review: <what was reviewed>

**Scope:** <files, lines changed, change type>
**Pass:** N
**Verdict:** BLOCKED | PASSED
**Counts:** critical=N warning=N note=N
**Head:** <sha12>

### Acceptance conditions
<Pass 1: numbered list, written before findings.
 Pass 2+: the same list, each item marked closed or open, never rewritten.>

### Critical findings
<These always block the merge. Each: id, location, dimension, stance, impact, failure scenario, fix.>

### Warnings (declared debt)
<Real and recorded. Each carries a proposed owner. Not blocking by default; under
 REVIEW_BLOCK_AT=warning each one blocks and carries a `scenario:`.>

### Notes (declared debt)

### Coverage note
<Large changes: depth map. Dimensions not applicable. Checks unavailable for this target.
 Agents dispatched with tier, and any substitution in force.
 Declined to judge: files or regions the review did not assess, each with the reason (too large,
 generated, binary, context missing, tool unavailable). Write `Declined to judge: none` when it
 read everything. Never leave the line out.>

### Prior findings
<Re-review only. Each earlier finding with one status: verified (closed, red and green re-run by
 the reviewer), open, refused-accepted (withdrawn, with the reason), refused-rejected (still
 counted, with what the evidence missed), or not-applicable (the region is gone). Cite the closure
 comment for the cycle (`pr-fixer-closure: cycle=<c>`).>

### Summary
<Two or three sentences: the risk profile and the single most important thing to fix.>
```

## Findings block

The report ends with one fenced block tagged `findings`. `pr-fixer` reads this block and nothing
else for the work list, so prose and block must agree.

````markdown
```findings
version: 1
pr: 123
head: 9f2c1ab4e0d3
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 2, note: 3}
acceptance:
  - {id: A1, text: "Login rejects expired tokens", status: open}
findings:
  # A WARNING also carries `scenario:` (a concrete failing input) when REVIEW_BLOCK_AT=warning.
  - id: C1
    severity: CRITICAL
    file: src/auth/session.ts
    line: 47
    dimension: security
    stance: security-auditor
    claim: "Expired token is accepted when the clock skew header is present"
    failure_scenario: "Request with Date header +2h and an expired token returns 200 and a session"
    suggested_fix: "Compare against server time, ignore the client header"
    testable: yes
    confidence: 0.9
    also_seen_by: [saboteur]
  - id: W1
    severity: WARNING
    file: src/auth/session.ts
    line: 80
    dimension: testing
    stance: new-hire
    claim: "No test for the refresh path"
    suggested_fix: "Add a test for refresh with a revoked token"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
```
````

On pass 2 and later every entry also carries `status`. For a blocking entry (every CRITICAL, and every
WARNING when `REVIEW_BLOCK_AT=warning`) it is one of `open`, `verified`, `refused-accepted`,
`refused-rejected`, `not-applicable`; for any other WARNING and every NOTE it is `open` or
`not-applicable`. An entry with no `status` is `open`. A pass-2 blocking entry looks like:

```yaml
  - id: C1
    severity: CRITICAL
    status: refused-rejected
    refusal: "Fixer reproduced with ADD CONSTRAINT; the finding names CREATE UNIQUE INDEX"
    claim: "Expired token is accepted when the clock skew header is present"
```

The fixer's closure comment uses a smaller vocabulary per finding: `closed`, `refused`,
`escalated`, or `open` (not reached). `refused` is the fixer's claim; only the reviewer turns it into
`refused-accepted` or `refused-rejected`.

Field rules: `severity` is one of CRITICAL, WARNING, NOTE. `failure_scenario` is mandatory for CRITICAL.
`testable: no` is allowed only for a NOTE; a CRITICAL nobody can reproduce goes back to the
reviewer rather than to the fixer. `owner_proposed` is mandatory for WARNING and NOTE. `refusal`
is mandatory for `refused-accepted` and `refused-rejected`. Counts equal the number of entries per
severity whose status is `open` or `refused-rejected`; `verified`, `refused-accepted` and
`not-applicable` entries stay in the block for the record and are not counted.

The block is the last thing in the report. Write a login you mention in prose as `@login` in backticks: `publish` does not rewrite the report, so a bare one notifies that person.

## Marker

Published only through `scripts/review-cycle.sh publish`, which writes

```
<!-- adversarial-review: sha=<40hex> verdict=PASSED|BLOCKED pass=<n> critical=<n> warning=<n> note=<n> [model=<id> tier=fast|standard|deep] [block_at=warning] -->
```

`model` and `tier` are optional, come as a pair, and are self-attested by the publishing session. A
marker without them is still valid. `block_at=warning` is written when the reviewer published under
`REVIEW_BLOCK_AT=warning`, and left out under the default. A reader running with another setting
does not judge such a marker ([pr-protocol.md](pr-protocol.md)).

and moves the label (`review:passed` or `review:blocked`). The marker is the authority and the label
is its projection. The marker string keeps its original prefix so existing gates still parse it.
Readers accept it only from a login in `REVIEW_MARKER_AUTHORS`; how to find it and the rest of the
PR artifacts: [pr-protocol.md](pr-protocol.md).

## When the loop halts

The verdict comment of the last pass does not change: it is an ordinary BLOCKED report with its
marker and its `findings` block, and it stays the authority. The question to the person is asked
in the session, not on the PR, with the open blocking finding ids and one-line claims (from the `findings`
block of the verdict at the head), the open count per pass (`pass 1: 3, pass 2: 3, ..., pass 6:
1`, the blocking count of each marker, printed by `review-cycle.sh budget`), the suggestion with
its reason, and the choices `continue N` or `stop`.

The answer is one comment with its marker as the first line ([pr-protocol.md](pr-protocol.md)),
written by `review-cycle.sh`:

```
<!-- pr-skill-extension: state=granted cycle=5 n=2 -->
pr-skill: 2 more review-fix cycles granted on #7 after cycle 5.
```

or, on `stop`, no answer, or the ceiling:

```
<!-- pr-skill-extension: state=halted reason=stop -->
pr-skill: halted on #7 (reason: stop). The pull request stays review:blocked and a person decides.
```

`reason=ceiling` says the hard ceiling was reached and comes with no question. A halt also adds
`review:needs-human` to the pull request; nothing else is relabelled by hand. The session prints
the same lines, and the halt always sends a push notification
([progress-and-notifications.md](progress-and-notifications.md)).

## Size

GitHub rejects a comment body over 65536 characters, and `review-cycle.sh publish` refuses a marker
plus report over 60000 bytes. Check the size before publishing and trim to fit:

1. The marker and the `findings` block always stay in the verdict comment. They are what the fixer,
   the escalation step and the gate read.
2. Keep the header, acceptance conditions and CRITICAL findings in full.
3. Shorten WARNING and NOTE prose to one line each; the findings block already carries their fields.
4. Move long prose, per-file depth maps and the coverage note to a second comment or to a file
   attached elsewhere, and link it from the verdict comment. That second comment carries no marker.
   `publish` screens only the verdict comment, so screen the second one before posting it:
   `scripts/review-cycle.sh screen --file overflow.md && gh pr comment <n> --body-file overflow.md`.

```bash
wc -c < .pr-skill/review.md   # bytes; keep well under 60000, the marker is added on top
```
