## Review: pasted diff, new file src/checkout/payments.py (rv02)

**Scope:** 1 file, +21 lines, new module (payment retry, plus an unrelated rate fetch)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=2 warning=3 note=3
**Head:** n/a (pasted diff)

### Acceptance conditions
1. A transient failure of the payments service (connection error, timeout, 5xx) is retried and checkout succeeds once the service recovers.
2. A charge is never created twice for one order, whatever the retry does (idempotency key or equivalent).
3. Retries are bounded (attempt count or total deadline); after the bound, checkout fails with a clear error instead of hanging.
4. Non-retryable responses (4xx such as a declined card or a validation error) fail immediately and are not retried.
5. Tests cover success, transient failure then success, exhausted retries, and a non-retryable 4xx.

### Critical findings

**C1. Retrying a non-idempotent charge POST can charge the customer twice.** `src/checkout/payments.py:11` (reliability, saboteur; also seen by security-auditor)
Impact: financial loss and customer harm. The POST carries no idempotency key, and the loop retries on every `RequestException`, including `Timeout` and `ReadTimeout`, where the server may already have created the charge.
Failure scenario: the payments service takes 6 s to answer a charge for order 42 (it commits the charge at 4 s). `requests.post(..., timeout=5)` raises `ReadTimeout`, the loop sleeps 1 s and POSTs again, and a second charge is created for order 42. The same happens when the response is 2xx but the body is not JSON: in requests >= 2.27, `r.json()` raises `requests.exceptions.JSONDecodeError`, a `RequestException` subclass, so an already successful charge is retried.
Fix: send a stable idempotency key derived from the order (for example an `Idempotency-Key: order-<id>` header the service honours), and only retry on errors where it is safe. Confirm the payments service supports idempotent charges; if it does not, do not retry on timeouts.

**C2. Unbounded `while True` retry hangs checkout forever and retries non-retryable errors.** `src/checkout/payments.py:9` (reliability, saboteur; also seen by architect)
Impact: production outage of checkout. There is no attempt limit or deadline, and `raise_for_status()` turns every 4xx into `HTTPError`, which is a `RequestException`, so it is retried too.
Failure scenario: (a) a customer's card is declined and the service returns 402: `charge()` loops every second forever, the request never returns, and the worker is lost. (b) the payments service is down for 30 minutes: every checkout request blocks its worker; once all workers are blocked the whole checkout (and anything else on those workers) stops serving. The PR description asks for surviving a *short* outage; this turns any long outage or permanent error into a hang.
Fix: bound the retries (for example 3 to 5 attempts or a total deadline under the caller's own timeout), retry only on connection errors, timeouts (with C1 fixed) and 5xx/429, and re-raise the last error when the bound is reached.

### Warnings (declared debt)

**W1. No tests for the new retry logic.** `src/checkout/payments.py:8` (testing, new-hire). The diff adds no test file; retry, bounding and error classification are untested. Owner: author.

**W2. Fixed 1 s sleep with no backoff or jitter.** `src/checkout/payments.py:15` (scalability, architect). Every blocked checkout retries once a second in lockstep, so a recovering payments service receives a retry storm proportional to queued checkouts. Use exponential backoff with jitter. Owner: author.

**W3. Retries are silent.** `src/checkout/payments.py:14` (operability, architect). The exception is swallowed with no log line, metric or attempt count, so an outage or a looping declined card is invisible to operators. Log each failed attempt with the order id and status. Owner: author.

### Notes (declared debt)

**N1. question: `fetch_rate` is outside the stated purpose and builds its URL by concatenation.** `src/checkout/payments.py:19` (security, security-auditor). `"https://rates.internal/" + currency` lets a value like `../admin` or `x?y=` change the path on an internal host if `currency` can come from user input. Callers are not visible in a pasted diff, so this is a question (confidence 0.4). Validate against an ISO 4217 allowlist or URL-encode it, and consider moving it to its own PR. Owner: author.

**N2. Service URLs are hard-coded.** `src/checkout/payments.py:5` (maintainability, new-hire). `PAYMENTS` and the rates URL cannot change per environment. Read them from configuration. Owner: author.

**N3. assumption: `order.total` is JSON-serialisable and in the unit the service expects.** `src/checkout/payments.py:11` (correctness, new-hire). If it is a `Decimal`, `json=` raises `TypeError` on every charge; if it is a float, rounding can misstate the amount. Not confirmable from the diff. Owner: author.

### Coverage note
Target is a pasted diff: no repository code, project rules, callers, tests, history or CI were available. Project rules were not read. `review-cycle.sh screen`, `scan-hidden.py` and `path-floor.sh` were not run (no base/head commits, and the task forbids calling `review-cycle.sh`); by inspection the diff contains no credential, no hidden text, and touches no path class the floor names (CI, agent config, auth/crypto, migrations, manifests), so `mandatory_units` is empty. Dimensions applied: reliability, security, testing, scalability, operability, maintainability, correctness. Not applicable: data and migrations, privacy, dependencies, UI. Single reviewer, no sub-agents dispatched.
Declined to judge: none.

### Summary
The change retries a payment POST with no idempotency key and no bound, so a timeout can charge a customer twice and a declined card or a long outage hangs checkout forever. Fix C1 first: make the charge idempotent before any retry ships, then bound and classify the retries (C2).

```findings
version: 1
pr: none
head: none
pass: 1
verdict: BLOCKED
counts: {critical: 2, warning: 3, note: 3}
mandatory_units: []
acceptance:
  - {id: A1, text: "Transient payments failures are retried and checkout succeeds after recovery", status: open}
  - {id: A2, text: "A charge is never created twice for one order", status: open}
  - {id: A3, text: "Retries are bounded and fail with a clear error", status: open}
  - {id: A4, text: "Non-retryable 4xx responses fail immediately", status: open}
  - {id: A5, text: "Tests cover success, transient-then-success, exhaustion and 4xx", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/checkout/payments.py
    line: 11
    dimension: reliability
    stance: saboteur
    claim: "Charge POST is retried without an idempotency key, so a timeout after the server committed the charge creates a second charge"
    failure_scenario: "Service commits charge for order 42 at 4s and replies at 6s; timeout=5 raises ReadTimeout; loop re-POSTs and order 42 is charged twice (same for a 2xx with a non-JSON body, since JSONDecodeError is a RequestException)"
    suggested_fix: "Send an idempotency key derived from the order id and retry only where safe"
    testable: yes
    confidence: 0.9
    also_seen_by: [security-auditor]
  - id: C2
    severity: CRITICAL
    file: src/checkout/payments.py
    line: 9
    dimension: reliability
    stance: saboteur
    claim: "while True retries forever, including 4xx HTTPError, so checkout hangs on a declined card or a long outage"
    failure_scenario: "Service returns 402 for a declined card; raise_for_status raises HTTPError (a RequestException); charge() loops every second forever and the worker never returns; during a long outage all workers block and checkout stops"
    suggested_fix: "Bound attempts or total time, retry only connection errors, timeouts, 5xx and 429, re-raise after the bound"
    testable: yes
    confidence: 0.95
    also_seen_by: [architect]
  - id: W1
    severity: WARNING
    file: src/checkout/payments.py
    line: 8
    dimension: testing
    stance: new-hire
    claim: "No tests for the new retry logic"
    suggested_fix: "Add tests for success, transient failure then success, exhausted retries and a 4xx"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: W2
    severity: WARNING
    file: src/checkout/payments.py
    line: 15
    dimension: scalability
    stance: architect
    claim: "Fixed 1s sleep with no backoff or jitter creates a synchronized retry storm on a recovering service"
    suggested_fix: "Exponential backoff with jitter"
    owner_proposed: "author"
    testable: yes
    confidence: 0.75
  - id: W3
    severity: WARNING
    file: src/checkout/payments.py
    line: 14
    dimension: operability
    stance: architect
    claim: "Failed attempts are swallowed with no log or metric, so outages and looping charges are invisible"
    suggested_fix: "Log each failed attempt with order id, attempt number and status"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: N1
    severity: NOTE
    file: src/checkout/payments.py
    line: 19
    dimension: security
    stance: security-auditor
    claim: "question: currency is concatenated into an internal URL unvalidated; fetch_rate is also outside the PR's stated purpose"
    suggested_fix: "Validate currency against an ISO 4217 allowlist or URL-encode it; move fetch_rate to its own PR"
    owner_proposed: "author"
    testable: yes
    confidence: 0.4
  - id: N2
    severity: NOTE
    file: src/checkout/payments.py
    line: 5
    dimension: maintainability
    stance: new-hire
    claim: "Service URLs are hard-coded"
    suggested_fix: "Read the URLs from configuration"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
  - id: N3
    severity: NOTE
    file: src/checkout/payments.py
    line: 11
    dimension: correctness
    stance: new-hire
    claim: "assumption: order.total is JSON-serialisable and in the unit the service expects"
    suggested_fix: "Serialise the amount explicitly (integer minor units)"
    owner_proposed: "author"
    testable: no
    confidence: 0.4
```
