## Review: pasted diff, new src/shop/reports.py (admin customer-orders report)

**Scope:** 1 file, +16 lines, new feature (two Django JSON views)
**Pass:** 1
**Verdict:** PASSED
**Counts:** critical=0 warning=2 note=2
**Head:** none (pasted diff)

### Acceptance conditions
1. The report returns every active customer with the ids of their orders.
2. The report completes within a normal request timeout at the stated scale (about 200000 active customers), with a bounded number of database queries.
3. Only an administrator can read the report.

### Critical findings
None.

### Warnings (declared debt)
- **W1** `src/shop/reports.py:9` (performance, saboteur; also seen by architect). N+1 query: one `Order` query per active customer inside the loop. At about 200000 active customers that is about 200001 queries in one request, plus every row held in memory and serialized into one JSON body. Scenario: an admin opens the report with 200000 active customers; the request issues 200001 queries and exceeds the worker/proxy timeout, tying up a worker and the database. Fix: `Customer.objects.filter(active=True).prefetch_related("order_set")` (or one `Order.objects.filter(customer__active=True).values_list("customer_id", "id")` grouped in Python), and paginate or stream the response. Owner: author.
- **W2** `src/shop/reports.py:6` (security, security-auditor). The description calls this an admin report, but neither view has an access check (`@staff_member_required`, `permission_required`, or similar). If routed without one, any visitor can enumerate every customer id and order id, and also trigger W1's expensive query at will. Routing and middleware are not in the diff, so this is not confirmed exploitable. Fix: add `@staff_member_required` (or the project's admin permission) to `customer_orders` and `recent_orders`. Owner: author.

### Notes (declared debt)
- **N1** `src/shop/reports.py:6` (testing, new-hire). The change adds no test. A test asserting the query count (`assertNumQueries`) would have caught W1, and one for an anonymous request would cover W2. Owner: author.
- **N2** `src/shop/reports.py:15` (scalability, architect). assumption: `recent_orders` relies on an index on `Order.created`; without one, `order_by("-created")[:50]` sorts the whole table. Owner: author.

### Coverage note
Target is a pasted diff: no repository access, so project rules (base commit) were not read, `screen`, `scan-hidden.py` and `path-floor.sh` were not run, and URL routing, middleware, models and indexes could not be checked. Dimensions applied: correctness, performance/scalability, security, testing. Not applicable: migrations, dependencies, CI. Single reviewer pass, no sub-agents dispatched.
Declined to judge: none (all 16 added lines read).

### Summary
The report is functionally correct but issues one query per customer, which at the stated 200000 active customers will time out; fixing the N+1 and paginating is the most important change. The views also show no admin access check, which should be added before this is routed.

```findings
version: 1
pr: none
head: none
pass: 1
verdict: PASSED
counts: {critical: 0, warning: 2, note: 2}
mandatory_units: []
acceptance:
  - {id: A1, text: "Report returns every active customer with their order ids", status: open}
  - {id: A2, text: "Report runs with a bounded query count at about 200000 active customers", status: open}
  - {id: A3, text: "Only an administrator can read the report", status: open}
findings:
  - id: W1
    severity: WARNING
    file: src/shop/reports.py
    line: 9
    dimension: performance
    stance: saboteur
    claim: "N+1 query: one Order query per active customer, about 200001 queries for 200000 customers, unbounded response"
    scenario: "200000 active customers; GET customer_orders issues 200001 queries and exceeds the request timeout"
    suggested_fix: "prefetch_related the orders (or one values_list query grouped in Python) and paginate or stream"
    owner_proposed: "author"
    testable: yes
    confidence: 0.95
    also_seen_by: [architect]
  - id: W2
    severity: WARNING
    file: src/shop/reports.py
    line: 6
    dimension: security
    stance: security-auditor
    claim: "Admin report views have no access check; any requester can read all customer and order ids"
    scenario: "Anonymous GET to the routed customer_orders URL returns every active customer's order ids"
    suggested_fix: "Decorate customer_orders and recent_orders with staff_member_required or the project's admin permission"
    owner_proposed: "author"
    testable: yes
    confidence: 0.6
    owasp: A01:2025
    cwe: CWE-862
  - id: N1
    severity: NOTE
    file: src/shop/reports.py
    line: 6
    dimension: testing
    stance: new-hire
    claim: "No tests for the new views (query count, anonymous access)"
    suggested_fix: "Add assertNumQueries and anonymous-access tests"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N2
    severity: NOTE
    file: src/shop/reports.py
    line: 15
    dimension: scalability
    stance: architect
    claim: "assumption: an index exists on Order.created for the recent_orders sort"
    suggested_fix: "Confirm or add an index on Order.created"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
