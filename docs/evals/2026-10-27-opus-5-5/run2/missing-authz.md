## Review: pasted diff, customer portal read endpoints for invoices and orders

**Scope:** 1 file (`src/billing/views.py`, new, +17 lines), feature
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=2 note=2
**Head:** unavailable (pasted diff)

### Acceptance conditions
1. A logged-in customer can read an invoice they own by id and gets its JSON.
2. A logged-in customer can read an order they own by id and gets its JSON.
3. A customer who asks for an invoice or order owned by someone else gets the same response as for a missing id (no data disclosed).
4. A missing id returns 404, not a 500.
5. Tests cover the owner, non-owner and missing-id paths for both endpoints.

### Critical findings

**C1. `get_invoice` returns any customer's invoice (IDOR / broken object-level authorization)** - `src/billing/views.py:8`
- Dimension: security. Stance: security-auditor (also seen by saboteur, architect).
- Impact: the handler fetches `db.invoices.get(invoice_id)` and returns it with no ownership check, unlike `get_order` in the same file (line 15), which compares `order.owner_id != g.user.id`. Any logged-in customer can read every other customer's invoices (billing data, amounts, addresses) by walking integer ids.
- Failure scenario: customer A (id 1) is logged in; `GET /invoices/2` where invoice 2 belongs to customer B returns 200 with B's invoice JSON. Iterating `/invoices/1..N` dumps all invoices.
- Fix: mirror the order handler: `if invoice is None or invoice.owner_id != g.user.id: abort(404)` (or scope the query by owner), and add a non-owner test.
- OWASP A01:2025, API1:2023; CWE-639.

### Warnings (declared debt)

**W1. Missing invoice raises a 500 instead of 404** - `src/billing/views.py:9`. `db.invoices.get` on an unknown id (assuming it returns `None`, as the order handler assumes for orders) makes `invoice.to_dict()` raise `AttributeError`, so `GET /invoices/999999` returns 500 and logs a stack trace. Closed by the same guard as C1. Owner: author.

**W2. No tests for the new endpoints** - `src/billing/views.py:6`. The diff adds two authorization-bearing handlers and no test; the C1 gap is exactly what an owner/non-owner test would have caught. Add tests for owner 200, non-owner 404, missing id 404, for both routes. Owner: author.

### Notes (declared debt)

**N1. question: where is login enforced?** - `src/billing/views.py:15`. Neither route has a login decorator; both rely on `g.user` being set. If no `before_request` hook guarantees it for these paths, an anonymous `GET /orders/1` raises `AttributeError` on `g.user.id` (500), and an anonymous `GET /invoices/1` returns data (worse, compounds C1). Could not confirm from a pasted diff. Confidence 0.5. Owner: author.

**N2. assumption: ids are sequential integers** (architect) - `src/billing/views.py:6`. The `<int:...>` routes make ids trivially enumerable; safe only while every handler checks ownership. Consider a shared ownership helper or owner-scoped repository method so the next handler cannot forget the check. Owner: author.

### Coverage note
- Target: pasted diff. Unavailable: repository code, `db`/`app` modules, auth middleware, project rules (AGENTS.md etc. not read for this target), history, tests, CI. `screen`, `scan-hidden.py`, `path-floor.sh` and `lint-report` not run (no PR, no base/head commits); manual inspection found no credential or hidden text in the 17 added lines.
- Dimensions applied: security, correctness, reliability/error handling, testing, architecture. Not applicable: data/migrations, dependencies, performance, privacy beyond C1.
- Agents: single reviewer applying the security-auditor, saboteur, new-hire and architect stances in sequence; no separate sub-agents dispatched.
- Declined to judge: none (all 17 lines read).
- Unit floor: not computed for a pasted diff; security run at max effort regardless.

### Summary
Small change with one serious hole: `get_invoice` has no ownership check, so any logged-in customer can read every invoice by id, while the sibling `get_order` handler does it correctly. Add the same owner/None guard to `get_invoice` plus tests for non-owner and missing-id paths; that closes C1, W1 and most of W2.

```findings
version: 1
pr: none
head: unavailable
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 2, note: 2}
mandatory_units:
  - {unit: security, effort: max, status: run}
acceptance:
  - {id: A1, text: "Owner can read own invoice by id", status: open}
  - {id: A2, text: "Owner can read own order by id", status: open}
  - {id: A3, text: "Non-owner gets same response as missing id for invoices and orders", status: open}
  - {id: A4, text: "Missing id returns 404, not 500", status: open}
  - {id: A5, text: "Tests cover owner, non-owner and missing-id paths for both endpoints", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/billing/views.py
    line: 8
    dimension: security
    stance: security-auditor
    claim: "get_invoice returns any invoice by id with no ownership check (IDOR)"
    failure_scenario: "Customer 1 logged in requests GET /invoices/2 owned by customer 2 and receives 200 with customer 2's invoice JSON"
    suggested_fix: "abort(404) when invoice is None or invoice.owner_id != g.user.id, as get_order does"
    testable: yes
    confidence: 0.95
    owasp: A01:2025
    cwe: CWE-639
    also_seen_by: [saboteur, architect]
  - id: W1
    severity: WARNING
    file: src/billing/views.py
    line: 9
    dimension: correctness
    stance: saboteur
    claim: "Unknown invoice id makes invoice.to_dict() raise AttributeError, returning 500 instead of 404"
    scenario: "GET /invoices/999999 with no such invoice returns 500"
    suggested_fix: "Guard None and abort(404) before to_dict()"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: W2
    severity: WARNING
    file: src/billing/views.py
    line: 6
    dimension: testing
    stance: new-hire
    claim: "No tests for the two new authorization-bearing endpoints"
    suggested_fix: "Add owner 200, non-owner 404 and missing-id 404 tests for both routes"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: N1
    severity: NOTE
    file: src/billing/views.py
    line: 15
    dimension: security
    stance: security-auditor
    claim: "question: no login decorator; both routes assume g.user is set by some hook not visible in the diff"
    suggested_fix: "Confirm a before_request guard covers these routes or add a login_required decorator"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N2
    severity: NOTE
    file: src/billing/views.py
    line: 6
    dimension: architecture
    stance: architect
    claim: "assumption: sequential integer ids are enumerable; safety depends on every handler repeating the owner check"
    suggested_fix: "Centralize ownership in an owner-scoped repository method or helper"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
```
