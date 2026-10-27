## Review: pasted diff, src/payments/webhooks.py (new file)

**Scope:** 1 file, 18 added lines, new feature (payment and refund webhook handlers)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=2 note=3
**Head:** n/a (pasted diff)

### Acceptance conditions
1. Every public webhook endpoint (payment and refund) rejects a request whose body is not signed with `HOOK_KEY`, before any order state changes.
2. A forged or unsigned payment event cannot mark an order paid.
3. A validly signed event cannot be replayed to change state twice or out of order.
4. Signature acceptance and rejection are covered by tests for both endpoints.

### Critical findings

**C1. `on_payment` trusts an unauthenticated body and marks orders paid** (`src/payments/webhooks.py:9-11`)
- Dimension: security (broken authentication / authorization, OWASP A01:2025, CWE-345). Stance: security-auditor; also seen by saboteur.
- Impact: the description says both endpoints are public. `on_refund` verifies an HMAC over the body, `on_payment` does not, so anyone who can reach the endpoint marks any order paid without paying.
- Failure scenario: an attacker POSTs `{"order_id": "1234"}` with no `X-Signature` header to the payment endpoint; `json.loads` succeeds and `orders.mark_paid("1234")` runs, so order 1234 ships unpaid.
- Fix: apply the same `hmac.compare_digest` check as `on_refund` before parsing, ideally through one shared `verify(request)` helper that both handlers call first and that returns 403 on mismatch.

### Warnings (declared debt)

**W1. No replay protection on signed events** (`src/payments/webhooks.py:15-18`). The signature covers only the body; there is no timestamp, event id or nonce check, so a captured signed refund event can be re-sent at will (and, once C1 is fixed, the same holds for payment events). Fix: verify a signed timestamp within a tolerance window and record processed event ids. Owner: author.

**W2. No tests for new security-relevant logic** (`src/payments/webhooks.py:14`). The diff adds signature verification and state changes with no tests: valid signature, wrong signature, missing header, and unsigned payment request. Owner: author.

### Notes (declared debt)

**N1. Malformed body surfaces as a 500** (`src/payments/webhooks.py:10`). Invalid JSON or a missing `order_id` raises `JSONDecodeError`/`KeyError`; return 400 instead so the provider's retry logic and logs are not polluted. Owner: author.

**N2. Inconsistent return contract** (`src/payments/webhooks.py:17`). `on_refund` returns the integer `403` on failure and `None` on success, `on_payment` always returns `None`. Whether the framework turns a bare int into a status code cannot be confirmed from a pasted diff (question, confidence 0.5). Owner: author.

**N3. assumption: the provider's signature format is a bare lowercase hex SHA-256 HMAC of the raw body** (`src/payments/webhooks.py:15`). Many providers send a prefixed or base64 signature or sign `timestamp.body`; if so every genuine refund is rejected. Also `mark_paid`/`mark_refunded` are assumed idempotent for provider retries. Owner: author.

### Coverage note
- Target is a pasted diff: no repository, base-commit project rules, callers of `orders`, framework routing, tests or CI could be read. Project rules were not read.
- `review-cycle.sh screen`, `scan-hidden.py` and `path-floor.sh` were not run (no git base/head, no PR, no network per instructions). The diff contains no literal secret; the key is read from the environment.
- Dimensions applied: security, correctness, reliability, testing. Not applicable: data migrations, dependencies, performance at scale, UI.
- Agents: single reviewer session covering security-auditor, saboteur, new-hire and architect stances (no separate sub-agents dispatched).
- Declined to judge: none
- Unit floor: see the findings block's `mandatory_units` field.

### Summary
Small change with one blocking hole: the payment webhook performs no signature check, so any caller on the public internet can mark orders paid. Fix C1 by routing both handlers through one verification helper, then add replay protection and tests.

```findings
version: 1
pr: null
head: null
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 2, note: 3}
mandatory_units:
  - {unit: security, effort: max, status: run}
acceptance:
  - {id: A1, text: "Both public webhook endpoints reject requests not signed with HOOK_KEY before changing order state", status: open}
  - {id: A2, text: "A forged or unsigned payment event cannot mark an order paid", status: open}
  - {id: A3, text: "A signed event cannot be replayed to change state twice", status: open}
  - {id: A4, text: "Tests cover signature acceptance and rejection on both endpoints", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/payments/webhooks.py
    line: 11
    dimension: security
    stance: security-auditor
    claim: "on_payment marks an order paid from an unauthenticated request body; no HMAC signature check unlike on_refund"
    failure_scenario: "POST {\"order_id\": \"1234\"} with no X-Signature to the public payment endpoint; orders.mark_paid(\"1234\") runs and the order is treated as paid without payment"
    suggested_fix: "Verify hmac.compare_digest(HMAC-SHA256(KEY, body), X-Signature) before parsing, via a shared helper used by both handlers; return 403 on mismatch"
    testable: yes
    confidence: 0.95
    also_seen_by: [saboteur]
    owasp: A01:2025
    cwe: CWE-345
  - id: W1
    severity: WARNING
    file: src/payments/webhooks.py
    line: 15
    dimension: security
    stance: saboteur
    claim: "Signed events have no timestamp or event-id check, so a captured signed event can be replayed"
    suggested_fix: "Verify a signed timestamp within a tolerance window and record processed event ids"
    owner_proposed: "author"
    testable: yes
    confidence: 0.75
    cwe: CWE-294
  - id: W2
    severity: WARNING
    file: src/payments/webhooks.py
    line: 14
    dimension: testing
    stance: new-hire
    claim: "No tests for signature verification or for the unsigned payment path"
    suggested_fix: "Add tests: valid signature, wrong signature, missing header, unsigned payment request rejected"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: N1
    severity: NOTE
    file: src/payments/webhooks.py
    line: 10
    dimension: reliability
    stance: saboteur
    claim: "Invalid JSON or missing order_id raises an unhandled exception (500) instead of a 400"
    suggested_fix: "Catch JSONDecodeError/KeyError and return 400"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: N2
    severity: NOTE
    file: src/payments/webhooks.py
    line: 17
    dimension: correctness
    stance: architect
    claim: "question: handlers return a bare int 403 on failure and None otherwise; unclear the framework maps this to an HTTP status"
    suggested_fix: "Return the framework's response object with explicit status codes from both handlers"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N3
    severity: NOTE
    file: src/payments/webhooks.py
    line: 15
    dimension: correctness
    stance: architect
    claim: "assumption: provider signs the raw body as bare hex HMAC-SHA256 and mark_paid/mark_refunded are idempotent under provider retries"
    suggested_fix: "Confirm the provider's signature scheme and header format; make state transitions idempotent"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
