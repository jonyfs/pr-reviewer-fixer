## Review: pasted diff, new request-logging middleware (src/api/middleware.py)

**Scope:** 1 file, +8 lines, new file (feature: per-request logging)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=3 note=3
**Head:** n/a (pasted diff, no commit)

### Acceptance conditions
1. Every API request produces a log record with method, path and the acting user, usable for debugging production issues.
2. No credential (Authorization header, bearer token, basic-auth password, session cookie) reaches any log record.
3. The middleware never makes a request fail: anonymous requests and requests without the logged fields pass through unchanged.
4. Logged request data cannot forge or split log records.
5. Tests show conditions 2 and 3 hold.

### Critical findings

**C1. Authorization header written to the log on every request** (`src/api/middleware.py:7`, security, security-auditor; also raised by saboteur)
- Impact: `request.headers.get("Authorization")` is logged verbatim at INFO, so every bearer token, API key or HTTP Basic credential (base64 of `user:password`) of every caller lands in the application log and in whatever ships, indexes and retains it. Anyone with log read access (ops staff, a log SaaS, a leaked log bundle, a support export) can replay live sessions. OWASP A09:2025, CWE-532.
- Failure scenario: client sends `GET /api/orders` with `Authorization: Bearer eyJ...`; the log line reads `request GET /api/orders auth=Bearer eyJ...`; a person with read access to the log store copies the token and calls the API as that user until the token expires. For Basic auth the password itself is recovered.
- Fix: drop the header from the log line. If the debugging need is "was the request authenticated and by which scheme", log only the scheme (`Bearer`/`Basic`/none) or a non-reversible marker, never the value. Rotate any credentials already logged if this ran anywhere.

### Warnings (declared debt)

**W1. Request path logged unneutralised** (`src/api/middleware.py:7`, security, saboteur). `request.path` comes from the caller and goes into the record with `%s`; most frameworks percent-decode it, so a path containing `%0d%0a` puts CR/LF in the message and forges a second record in line-based log sinks. Scenario: `GET /api/x%0aINFO%20api:user%20id=1` writes a fake `user id=1` line. Fix: escape control characters (for example `request.path.encode("unicode_escape")` or `repr`) or use a structured formatter. Owner: author.

**W2. `user.id` raises when there is no authenticated user** (`src/api/middleware.py:8`, reliability, saboteur). The hook runs on every API request, including login, health checks and anonymous routes, where `user` is commonly `None`; `None.id` raises `AttributeError` and the logging hook turns a working request into a 500. Callers are not in the diff, so this is stated with moderate confidence. Scenario: unauthenticated `POST /api/login` with `user=None` returns 500. Fix: `getattr(user, "id", None)` and log `anonymous`. Owner: author.

**W3. No tests for the new middleware** (`src/api/middleware.py:6`, testing, new-hire). Nothing checks that credentials stay out of the record or that an anonymous request passes. Fix: a test with `caplog` asserting the token value never appears and that `user=None` does not raise. Owner: author.

### Notes (declared debt)

**N1. Two unrelated records per request** (`src/api/middleware.py:8`, operability, architect). Method/path and user id are separate lines with no request id; under concurrency they interleave and cannot be joined, which defeats the stated debugging purpose. Merge into one record or add a request/correlation id. Owner: author.

**N2. Personal identifier in every log line** (`src/api/middleware.py:8`, privacy, security-auditor). A user id per request at INFO is personal data under LGPD/GDPR; confirm the log retention and who reads the sink. `assumption:` the log sink is internal to the controller. Owner: author.

**N3. question: where is `before_request` registered?** (`src/api/middleware.py:6`, architecture, new-hire). The diff adds the function but no wiring; with no repository access I cannot tell whether it runs at all or what passes `user`. Confidence 0.5. Owner: author.

### Coverage note
Target is a pasted diff: repository code, callers, conventions, history, tests and CI were not available. Project rules were not read (no base commit). `path-floor.sh` printed no mandatory unit for `src/api/middleware.py`. `scan-hidden.py` on the diff and description: 0 hits. `review-cycle.sh screen --file` on the diff: no credential. Dimensions applied: security, privacy, reliability, operability, testing, architecture; others (performance, data/migrations, dependencies, CI) not applicable. Review done by a single agent in this session covering the four stances; no parallel sub-agents dispatched.
Declined to judge: none (all 8 lines read); framework-specific behaviour of `request.path` decoding and `user` nullability is unverified because callers are absent.

### Summary
A small logging hook that, as written, copies every caller's credential into the logs: C1 must be fixed (drop the Authorization value) before merge. After that, neutralise the path, guard a missing user and add a test that pins both.

```findings
version: 1
pr: null
head: n/a
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 3, note: 3}
mandatory_units: []
acceptance:
  - {id: A1, text: "Every API request logs method, path and acting user", status: open}
  - {id: A2, text: "No credential reaches any log record", status: open}
  - {id: A3, text: "Middleware never fails a request (anonymous included)", status: open}
  - {id: A4, text: "Logged request data cannot forge log records", status: open}
  - {id: A5, text: "Tests cover A2 and A3", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/api/middleware.py
    line: 7
    dimension: security
    stance: security-auditor
    claim: "Authorization header value (bearer token / basic credentials) is logged at INFO on every request"
    failure_scenario: "Request with 'Authorization: Bearer eyJ...' logs 'auth=Bearer eyJ...'; anyone with log access replays the token as that user"
    suggested_fix: "Remove the header value from the log; log at most the auth scheme or presence"
    testable: yes
    confidence: 0.95
    also_seen_by: [saboteur]
    owasp: A09:2025
    cwe: CWE-532
  - id: W1
    severity: WARNING
    file: src/api/middleware.py
    line: 7
    dimension: security
    stance: saboteur
    claim: "Caller-controlled request.path logged without neutralising CR/LF (log forging)"
    scenario: "GET /api/x%0aINFO%20api:user%20id=1 writes a forged 'user id=1' record"
    suggested_fix: "Escape control characters in the path or use a structured log formatter"
    owner_proposed: "author"
    testable: yes
    confidence: 0.6
    cwe: CWE-117
  - id: W2
    severity: WARNING
    file: src/api/middleware.py
    line: 8
    dimension: reliability
    stance: saboteur
    claim: "user.id raises AttributeError when the request has no authenticated user"
    scenario: "Unauthenticated POST /api/login with user=None returns 500"
    suggested_fix: "Use getattr(user, 'id', None) and log 'anonymous'"
    owner_proposed: "author"
    testable: yes
    confidence: 0.55
  - id: W3
    severity: WARNING
    file: src/api/middleware.py
    line: 6
    dimension: testing
    stance: new-hire
    claim: "No tests for the new middleware"
    suggested_fix: "caplog test asserting no token in records and no exception for user=None"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N1
    severity: NOTE
    file: src/api/middleware.py
    line: 8
    dimension: operability
    stance: architect
    claim: "Method/path and user id are separate records with no correlation id; they interleave under load"
    suggested_fix: "Emit one record per request or add a request id"
    owner_proposed: "author"
    testable: no
    confidence: 0.7
  - id: N2
    severity: NOTE
    file: src/api/middleware.py
    line: 8
    dimension: privacy
    stance: security-auditor
    claim: "assumption: logging the user id per request is acceptable only if the log sink is internal with bounded retention"
    suggested_fix: "Confirm sink and retention; document it"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N3
    severity: NOTE
    file: src/api/middleware.py
    line: 6
    dimension: architecture
    stance: new-hire
    claim: "question: before_request is not registered anywhere in the diff; how is it wired and what supplies user?"
    suggested_fix: "Show the registration or add it in this change"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
