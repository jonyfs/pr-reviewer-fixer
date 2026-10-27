## Review: pasted diff, src/shop/coupons.py (single-use coupon redemption)

**Scope:** 1 new file, 13 added lines, new feature (checkout coupon redemption)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=3 note=2
**Head:** n/a (pasted diff)

### Acceptance conditions
1. A coupon code can be redeemed against an order exactly once, including under concurrent requests.
2. Redemption applies the coupon amount to the order of the requesting user only.
3. Either both the order discount and the coupon's `used` flag are written, or neither is.
4. Tests cover first redemption, second redemption, and a foreign order.

### Critical findings

**C1. Single-use coupon can be redeemed more than once (check-then-act race)**
- Location: `src/shop/coupons.py:6` (check) and `:11-12` (write)
- Dimension: security / concurrency. Stance: saboteur; also seen by security-auditor.
- Impact: the "single-use" invariant the PR exists to provide does not hold. `coupon.used` is read
  without a lock, and the write happens later with a plain `save()`. Money is lost per duplicate.
- Failure scenario: a customer sends two checkout requests with the same unused code at once (two
  orders, or two tabs). Both `Coupon.objects.get` calls read `used=False`, both pass line 6, both
  set the discount on their order and save, and both write `used=True`. One single-use coupon has
  discounted two orders.
- Fix: inside `transaction.atomic()`, claim the coupon atomically, e.g.
  `claimed = Coupon.objects.filter(code=code, used=False).update(used=True)`, raise if
  `claimed == 0`, then apply the discount; or `select_for_update()` the coupon row in the same
  transaction.

### Warnings (declared debt)

**W1. Order and coupon writes are not atomic** (`src/shop/coupons.py:10`, reliability, saboteur,
owner: author). `order.save()` commits before `coupon.save()`. If the second save fails (DB error,
timeout, process killed), the order keeps the discount and the coupon stays unused and can be
redeemed again. Wrap both writes in one `transaction.atomic()` block (same change as C1).

**W2. Discount applied to an order in any state** (`src/shop/coupons.py:8`, correctness,
architect, owner: author). The order is fetched by id and user only. Nothing checks that it is
still open at checkout (not paid, shipped or cancelled) or that it does not already carry a
discount, so a second coupon silently overwrites the first, and a coupon can be spent on an order
that was already paid. Filter on the order's checkout state and decide the rule for an existing
discount.

**W3. No tests for new redemption logic** (`src/shop/coupons.py:4`, testing, new-hire, owner:
author). The diff adds money-moving logic with no test: first redemption, reuse, unknown code,
another user's order, and a concurrent double redemption.

### Notes (declared debt)

**N1. assumption: coupon has no expiry, minimum or ownership rule** (`src/shop/coupons.py:5`,
correctness, new-hire, owner: author). The code assumes any unused coupon is valid for any user
and any order, and that `coupon.amount` never exceeds the order total (no clamp, so the total may go
negative depending on how `discount` is used). The `Coupon` model is not in the diff; confirm.

**N2. Unhandled `DoesNotExist` and code probing** (`src/shop/coupons.py:5`, security,
security-auditor, owner: author). An unknown code raises `Coupon.DoesNotExist` (likely a 500) while a
used code raises `ValueError`, so responses distinguish invalid, used and valid codes, which helps
enumeration. Map both to one domain error and rate-limit redemption at the caller.

### Coverage note
Target is a pasted diff: no repository code, `shop.models`, project rules, history, tests or CI
were available. `screen`, `scan-hidden.py` and `path-floor.sh` need base and head commits and were
not run; the path `src/shop/coupons.py` falls in no path-floor class by inspection (not CI, auth,
crypto, migration or manifest), so no mandatory unit applies. Dimensions applied: security,
concurrency, reliability, correctness, testing. Not applicable: performance, migrations,
dependencies, docs. Single reviewer pass, no sub-agents dispatched.
Declined to judge: `shop.models` (`Coupon`, `Order`), not in the diff (context missing).

### Summary
Small change, but its one invariant (single use) fails under concurrent requests and under a
partial write, and that costs money. Fix C1 and W1 together: claim the coupon with one conditional
update inside a transaction that also saves the order.

```findings
version: 1
pr: 0
head: pasted-diff
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 3, note: 2}
mandatory_units: []
acceptance:
  - {id: A1, text: "A coupon is redeemed exactly once, including under concurrent requests", status: open}
  - {id: A2, text: "Discount applies only to the requesting user's order", status: open}
  - {id: A3, text: "Order discount and coupon used flag are written together or not at all", status: open}
  - {id: A4, text: "Tests cover first use, reuse and a foreign order", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/shop/coupons.py
    line: 6
    dimension: security
    stance: saboteur
    claim: "Check-then-act on coupon.used without lock or conditional update lets a single-use coupon be redeemed by concurrent requests"
    failure_scenario: "Two simultaneous redeem() calls with the same unused code both read used=False, both discount their orders, both save used=True"
    suggested_fix: "In transaction.atomic(), Coupon.objects.filter(code=code, used=False).update(used=True) and raise when it returns 0, or select_for_update() the coupon"
    testable: yes
    confidence: 0.95
    also_seen_by: [security-auditor]
    cwe: CWE-367
  - id: W1
    severity: WARNING
    file: src/shop/coupons.py
    line: 10
    dimension: reliability
    stance: saboteur
    claim: "order.save() and coupon.save() are separate commits; a failure between them leaves a discounted order and a reusable coupon"
    suggested_fix: "Wrap both writes in one transaction.atomic() block"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: W2
    severity: WARNING
    file: src/shop/coupons.py
    line: 8
    dimension: correctness
    stance: architect
    claim: "Order state and existing discount are not checked; coupons apply to paid/cancelled orders and overwrite a prior discount"
    suggested_fix: "Restrict the lookup to orders still in checkout and define the rule for an existing discount"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: W3
    severity: WARNING
    file: src/shop/coupons.py
    line: 4
    dimension: testing
    stance: new-hire
    claim: "New money-moving redemption logic has no tests"
    suggested_fix: "Add tests for first use, reuse, unknown code, foreign order and concurrent redemption"
    owner_proposed: "author"
    testable: yes
    confidence: 0.9
  - id: N1
    severity: NOTE
    file: src/shop/coupons.py
    line: 5
    dimension: correctness
    stance: new-hire
    claim: "assumption: coupons have no expiry, ownership or minimum rule, and amount never exceeds the order total"
    suggested_fix: "Confirm against the Coupon model; clamp the discount to the order total"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N2
    severity: NOTE
    file: src/shop/coupons.py
    line: 5
    dimension: security
    stance: security-auditor
    claim: "Unknown code raises DoesNotExist (likely 500) while a used code raises ValueError, distinguishing code states"
    suggested_fix: "Map both to one domain error and rate-limit redemption"
    owner_proposed: "author"
    testable: yes
    confidence: 0.6
```
