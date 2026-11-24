---
Summary: Layout of the pr-reviewer report for people and the machine-readable findings block that pr-fixer and pr-merge-fixer consume.
Tags: [#pr #review #contract #reference]
---

# Report Contract

The report is one GitHub comment. Two readers use it: a person who opens the pull request after the
agent, and `pr-fixer`, which reads only the `findings` block. The layout below serves the person
first, and the block serves the fixer. Neither may contradict the other: the counts, the ids and the
statuses must match.

## Layout

The verdict comment is plain text, in order: the marker, the banner, the summary, the detail, and
the findings block last. `review-cycle.sh publish` writes the marker and posts the report as it is.
The template below is the whole comment; everything outside the `findings` fence is plain text.

````text
<!-[-] adversarial-review: sha=<40hex> verdict=BLOCKED pass=2 critical=1 warning=1 note=1 -->
Written by pr-reviewer, pass 2, head 9f2c1ab4e0d3, 2026-11-19 14:02 UTC.

BLOCKED: 1 critical finding stops the merge

Verdict: BLOCKED
Counts: critical 1, warning 1, note 1
Scope: 6 files, 214 lines, change type: feature
Head: 9f2c1ab4e0d3
Next: pr-fixer cycle 2 closes C1 first

What changed: session expiry now trusts a client clock header (see C1).
What blocks: only C1. Warnings and notes are declared debt with an owner.
Check first: src/auth/session.ts:47, then the test list for the refresh path.

Acceptance conditions, written at pass 1:
A1 met: Expired tokens are rejected on every route.
A2 open: Refresh tokens are revoked on logout.

Critical findings, which always block:
C1 at src/auth/session.ts:47 (security): Expired token accepted when the clock-skew header is present.
C1 failure scenario: a request with a Date header two hours ahead and an expired token returns 200.
C1 suggested fix: compare against server time and ignore the client header.

Warnings, declared debt:
W1 at src/auth/session.ts:80: No test for the refresh path. Proposed owner: the author.

Notes, declared debt:
N1 at README.md:12: Setup line refers to the old flag. Proposed owner: the author.

Coverage:
security, effort max: run.
dependencies, effort standard: run.
privacy: not applicable, no privacy path in the diff.
Declined to judge: none.
Review mode: separate agents | single session.

Prior findings (pass 2 and later, one line per earlier blocking finding):
C0 verified: the closure's test fails on the old head and passes on this one.

Pass history: pass 1 BLOCKED (1 critical), fixer cycle 1 closed 1, pass 2 BLOCKED (1 critical).

Summary: the session change reopens expired tokens through a client header. Fix C1 first; the rest
can follow in a later pass as declared debt.

```findings
version: 1
pr: 123
head: 9f2c1ab4e0d3
pass: 2
verdict: BLOCKED
counts: {critical: 1, warning: 1, note: 1}
mandatory_units:
  - {unit: security, effort: max, status: run}
  - {unit: dependencies, effort: standard, status: run}
acceptance:
  - {id: A1, text: "Expired tokens are rejected on every route", status: verified}
  - {id: A2, text: "Refresh tokens are revoked on logout", status: open}
findings:
  - id: C1
    severity: CRITICAL
    status: open
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
    status: open
    file: src/auth/session.ts
    line: 80
    dimension: testing
    stance: new-hire
    claim: "No test for the refresh path"
    suggested_fix: "Add a test for refresh with a revoked token"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N1
    severity: NOTE
    status: open
    file: README.md
    line: 12
    dimension: documentation
    stance: new-hire
    claim: "Setup line refers to the old flag"
    suggested_fix: "Name the new flag"
    owner_proposed: "author"
    testable: no
    confidence: 0.9
```
````

The banner, the summary lines and the pass history are for people. The findings block is the only
part the fixer parses for its work list, so prose and block must agree on every id and count.

## Summary standard

The summary is what a person reads first, so it follows one template, in this order, as plain
lines:

1. Title line: the verdict and the reason in six words or fewer, no emoji.
2. Labelled lines: `Verdict:`, `Counts:`, `Head:` and, last, `Next:`, which starts with the actor
   (`pr-fixer`, `A person`). There is no separate next-step line.
3. Reading guide: at most three labelled lines: what changed, what blocks, what to check first.

```text
BLOCKED: one critical finding stops the merge

Verdict: BLOCKED
Counts: critical 1, warning 6, note 11
Head: c3d204a
Next: pr-fixer, cycle 1

Changed: the merge fixer's conflict step (see C1).
Blocks: C1 only. Warnings and notes are debt with an owner.
Check first: SKILL.md:102.
```

Rules that keep the summary short without losing detail:

- Details move down into the per-finding lines, never into the summary.
- Every number in the summary equals the number in the marker and in the findings block.
- Use the words from the legend in [pr-protocol.md](pr-protocol.md) and nothing else.

## Rules for the person-facing part

- The comment is plain text. No Markdown outside the `findings` fence: no headings, no tables, no
  bold or italics, no bullet or numbered lists, no checkboxes, no quotes, no other fenced block
  (Mermaid included), and no emoji. The marker line and the `findings` block are the only
  exceptions. Markdown belongs in the pull request description only.
- Each detail line starts with its label or its id (`C1 at path:line`, `Coverage:`, `A2 open:`),
  so a reader scans the left edge. One finding per line, plus its scenario and fix lines.
- The labelled summary states the verdict, the counts, the head and the next action in one place.
- Counts in the summary equal the counts in the marker and in the findings block.
- Severity and outcome are words from the legend in [pr-protocol.md](pr-protocol.md): CRITICAL,
  WARNING, NOTE; met, open, verified, refused-accepted, refused-rejected, not applicable.
- An acceptance condition is a line `A<n> met:` or `A<n> open:` with the condition. It states a
  condition, not a task.
- The pass history is one `Pass history:` line from pass 2 on.
- Three lines, at most, in the reading guide.
- Write a login without the `@` (jonyfs, not @jonyfs): `publish` does not rewrite the report, and a
  bare @login notifies that person.

## Findings block

The report ends with one fenced block tagged `findings`. `pr-fixer` and `pr-merge-fixer` read this
block and nothing else for the work list, so prose and block must agree. The report must contain
exactly one line that is exactly ```` ```findings ````, and that fence must be the last block in the
report. `lint-report` refuses a report with a second such line, even one quoted inside another fence, so
examples elsewhere in the report must not use that exact opener (the example above is in this
contract, not in a report).

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

Optional field `repro:`: the result of the opt-in execution check, written only when
`scripts/repro-sandbox.sh` ran (or refused) for that entry, usually a CRITICAL candidate. It is one of
`reproduced` (the repro exited as the finding predicts: a failing test, a crash, a given exit code),
`not-reproduced`, or `skipped` (opt-in off, no sandbox on the host, timeout, the repro never started,
a limit or a leftover process). The script prints `repro: <word> (<reason>)`; the field takes the
first word only. It is evidence
for the reviewer and the fixer: it never raises or lowers a severity by itself and never changes the
verdict rule ([severity-and-verdict.md](severity-and-verdict.md)). A CRITICAL that is
`not-reproduced` still needs its failure scenario judged on the code; a `skipped` one is judged as if
no repro ran. `lint-report` refuses any other value (on every entry, `not-applicable` included);
`findings-block` prints the field as written, and an entry without it has no `repro` key. A report
with no `repro:` field anywhere is valid as before.

```yaml
  - id: C1
    severity: CRITICAL
    status: open
    repro: reproduced
```

The script runs the repro in a scratch clone at `--sha`, inside a `box/` folder that is the only
path the repro can write, with `env -i` (a fixed PATH, HOME and TMPDIR in box, no token, no SSH
agent, git's system and global config off), stdin from /dev/null, a new session, `timeout`, `ulimit
-t`, `-f` and `-u` (the uid's process count plus 256), and a sandbox called by a fixed path:
`/usr/bin/sandbox-exec` on macOS with a profile that starts from `(deny default)` (exec and fork,
signals only within the run's own sandbox instance, reads of the system folders, reads and writes in
box, reads of one marker file outside box; no network and no mach-lookup, so no LaunchServices,
pasteboard, keychain or Apple Events), `/usr/bin/bwrap` on Linux
(every namespace unshared, only /usr, /etc and the /bin, /sbin and /lib folders bound read-only,
tmpfs on /tmp, /run, /var/run and /home, `--die-with-parent`, `--new-session`, `--clearenv`, box the
only writable bind). `unshare -rn` is not enough (it confines neither reads nor writes) and is
refused like no sandbox: the script prints `no network sandbox here; repro skipped` and exits 4; it
never falls back to an unsandboxed run. It also refuses (exit 2) when HOME does not resolve to a
folder. The output and status files sit outside box and reach the repro only as open descriptors, so
it cannot replace or block them. The repro is given as `--cmd-file` or as argv after `--`, never as
a string the script builds. Its log (`--log`) is pull request output: screen it before quoting it in
a report.

When the result is `skipped` rather than evidence: the repro never started (the wrapper writes a
sentinel just before it execs the repro; a sandbox that aborts first leaves none), the timeout (124),
a SIGKILL (137: the timeout's KILL or the repro's own, which the script cannot tell apart), a command
that could not run (126, 127), the script's own CPU or file-size limit (152, 153), a process of the
repro that outlived it outside its session (found and killed) or survived the kill, or a repro that
replaced or removed its box folder.
`--expect fail` counts any other non-zero exit, so a missing dependency (`ModuleNotFoundError`, a
package the fresh clone lacks) reads as `reproduced`: pair `fail` with `--expect-log <fixed string>`,
the assertion message the finding predicts, and the result is `reproduced` only when the log holds it.

Limits that remain. On macOS a process the repro leaves behind is found through `sandbox_check(3)`,
which needs `/usr/bin/python3` (without it the result is `skipped`). The test asks only about two
random marker paths outside box, one that this run's profile alone may read and one it may not, so
nothing the repro writes can steer it onto another process; the path box is never asked about. The
kill goes through a reaper the wrapper forks inside the run's sandbox instance, which the kernel lets
signal nothing outside that instance (`kill(-1)` is not used: its confinement could not be shown
safely). The scan repeats until two rounds in a row find nothing, at most 15 s. The script kills
directly only when the reaper is gone and box is still the folder it made; a repro that kills or
stops the reaper and also replaces or removes box leaves its survivors running (named on stderr,
result `skipped`). Signals reach only processes of the same sandbox instance. launchd still answers
read queries that come through the bootstrap port, which is not a mach-lookup: `launchctl print
gui/<uid>` lists the user's services with their pids and state inside the sandbox (changes are
refused), and that text can reach `--log`. The profile allows reads of /usr, /System, /Library, /private/etc and the
runtime folders (/opt/homebrew, Xcode): a secret kept there is readable, though nothing can leave
without network. On Linux the bwrap backend is built from bwrap's documented flags and its rows run
only where bwrap works (they skip elsewhere, and CI does not run this suite); /etc is bound read-only, so world-readable files there are visible;
runtimes outside /usr (/opt, a home-installed toolchain) are not; and the process cap is per uid, as
on macOS. Neither backend limits memory.

Optional fields: a security finding may carry `owasp:` (a category id such as `A01:2025`,
`API3:2023`, `LLM01:2025` or `ASI02:2026`) and `cwe:` (such as `CWE-639`), as described in
[security-checklist.md](security-checklist.md). `lint-report` and the fixer ignore them.

Field rules: `line` is the line in the new version of `file`, counted from the hunk header's
`+start` ([targets-and-context.md](targets-and-context.md)), never the line of a patch file.
`severity` is one of CRITICAL, WARNING, NOTE. `failure_scenario` is mandatory for CRITICAL.
`testable: no` is allowed only for a NOTE; a CRITICAL nobody can reproduce goes back to the
reviewer rather than to the fixer. `owner_proposed` is mandatory for WARNING and NOTE. `refusal`
is mandatory for `refused-accepted` and `refused-rejected`. Counts equal the number of entries per
severity whose status is `open` or `refused-rejected`; `verified`, `refused-accepted` and
`not-applicable` entries stay in the block for the record and are not counted.

The block is the last thing in the report. Write a login you mention in prose without the `@`: `publish` does not rewrite the report, so a bare @login notifies that person.

## Marker

Published only through `scripts/review-cycle.sh publish`, which writes

```
<!-[-] adversarial-review: sha=<40hex> verdict=PASSED|BLOCKED pass=<n> critical=<n> warning=<n> note=<n> [model=<id> tier=fast|standard|deep] [block_at=warning] -->
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
<!-[-] pr-skill-extension: state=granted cycle=5 n=2 -->
pr-skill: 2 more review-fix cycles granted on #7 after cycle 5.
```

or, on `stop`, no answer, or the ceiling:

```
<!-[-] pr-skill-extension: state=halted reason=stop -->
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
2. Keep the banner, the summary, the acceptance conditions and CRITICAL findings in full.
3. Shorten WARNING and NOTE prose to one line each; the findings block already carries their fields.
4. Move long prose, per-file depth maps and the coverage note to a second comment or to a file
   attached elsewhere, and link it from the verdict comment. That second comment carries no marker.
   `publish` screens only the verdict comment, so screen the second one before posting it:
   `scripts/review-cycle.sh screen --file overflow.md && gh pr comment <n> --body-file overflow.md`.

```bash
wc -c < .pr-skill/review.md   # bytes; keep well under 60000, the marker is added on top
```
