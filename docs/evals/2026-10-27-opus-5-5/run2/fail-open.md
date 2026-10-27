## Review: pasted diff, new src/docs/permissions.py (document permission checks via central policy service)

**Scope:** 1 file, +22 lines, new module (authorization)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=2 note=3
**Head:** unknown (pasted diff)

### Acceptance conditions
1. `can_delete` and `can_read` return the policy service's decision when the service answers.
2. When the policy service is unavailable, slow or raises, no permission is granted (fail closed) for any action.
3. A slow policy service during deploys cannot hold request threads indefinitely (bounded wait).
4. The new authorization paths are covered by tests, including the service-failure path.

### Critical findings

**C1. `can_delete` fails open when the policy service errors** (`src/docs/permissions.py:14`)
- Dimension: security (broken access control, CWE-636 fail-open). Stance: security-auditor; also seen by saboteur.
- Impact: any exception from `client.allowed` (timeout, connection refused, 5xx, even a bug such as `user` being an anonymous object) makes `can_delete` return `True`. The description says the service "is sometimes slow during deploys", so this is an expected, recurring state, not a rare one.
- Failure scenario: during a deploy the policy service times out; an unauthenticated-to-the-document user (or any user) sends a delete request; `client.allowed` raises, the `except Exception` branch logs a warning and returns `True`, and the document is deleted. An attacker can also try to induce the error path (load, malformed ids) to get destructive access. Data loss plus an authorization bypass.
- The sibling `can_read` (line 22) fails closed, so the module is inconsistent and the most destructive action has the weakest default.
- Fix: return `False` on exception (deny by default), and consider raising a specific "authorization unavailable" error that the caller turns into 503 rather than silently denying. Add a test that forces `client.allowed` to raise and asserts `can_delete` is `False`.

### Warnings (declared debt)

**W1. No bounded wait on the policy call** (`src/docs/permissions.py:11`, also line 19) - reliability, saboteur. `PolicyClient()` is built with no timeout and the calls pass none. The description states the service is slow during deploys; if the client's default timeout is long or absent, every permission check blocks a worker for that long and can exhaust the request pool (outage), and once C1 is fixed, slowness turns into user-visible denials with no retry. Cannot confirm `PolicyClient` defaults (pasted diff, no repository). Suggest an explicit short timeout, a bounded retry, and possibly a circuit breaker. Owner: author.

**W2. No tests for new authorization logic** (`src/docs/permissions.py:9`) - testing, new-hire. The diff adds two authorization checks and no tests; per the severity rules this is CRITICAL-class code, but the repository was not available to confirm tests do not exist elsewhere, so it is recorded as a WARNING. Add tests for allow, deny and service-error paths of both functions. Owner: author.

### Notes (declared debt)

**N1. Broad `except Exception` hides programming errors and the log has no context** (`src/docs/permissions.py:13`) - operability, new-hire. Every exception, including `AttributeError`/`TypeError` from bad inputs, is logged as "policy service unavailable" with no exception info, user id, document id or action. Use `log.warning(..., exc_info=True)` with the ids/action, and catch the client's specific transport errors. Owner: author.

**N2. Policy client created at import time** (`src/docs/permissions.py:6`) - architecture, architect. A module-level `PolicyClient()` is a hidden global: it runs on import, is hard to replace in tests, and its configuration (endpoint, timeout) is not visible here. Prefer injection or a lazily built client. Owner: author.

**N3. assumption: `client.allowed` returns a strict boolean** (`src/docs/permissions.py:11`) - correctness, architect. The return value is passed through unchanged; if the client returns a response object or `None` on some paths, truthiness decides access. Confirm the contract or coerce with `is True`. Owner: author.

### Coverage note
Target is a pasted diff: repository code, project rules (AGENTS.md etc. on base), history, existing tests, callers and CI were not available, so the rules were not read and `PolicyClient` behavior (timeouts, return type) is unconfirmed. `review-cycle.sh` (screen, path-floor, lint-report) and `scan-hidden.py` were not run per the task (no PR, no git base). Agents/stances applied inline: security-auditor (security, max), saboteur (reliability), new-hire (testing, operability), architect (design). Dimensions not applicable: data/migrations, dependencies, privacy beyond access control.
Declined to judge: none.

### Summary
A new authorization module with an inverted failure default: `can_delete` grants deletion whenever the policy service errors, which the description says happens during deploys. Fix that to deny-by-default before merge; then bound the policy call's latency and add tests for the error paths.

```findings
version: 1
pr: null
head: unknown
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 2, note: 3}
mandatory_units:
  - {unit: security, effort: max, status: run}
acceptance:
  - {id: A1, text: "can_delete and can_read return the policy decision when the service answers", status: open}
  - {id: A2, text: "Service unavailable, slow or raising grants no permission for any action", status: open}
  - {id: A3, text: "Policy call has a bounded wait so a slow service cannot hold request threads", status: open}
  - {id: A4, text: "Authorization paths, including service failure, are covered by tests", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/docs/permissions.py
    line: 14
    dimension: security
    stance: security-auditor
    claim: "can_delete returns True when the policy service raises (fail-open authorization on a destructive action)"
    failure_scenario: "Policy service times out during a deploy; any user sends a delete; client.allowed raises, except branch returns True, document is deleted without authorization"
    suggested_fix: "Return False on exception (deny by default) or raise an authorization-unavailable error mapped to 503; add a test forcing client.allowed to raise"
    testable: yes
    confidence: 0.97
    owasp: A01:2025
    cwe: CWE-636
    also_seen_by: [saboteur]
  - id: W1
    severity: WARNING
    file: src/docs/permissions.py
    line: 11
    dimension: reliability
    stance: saboteur
    claim: "No explicit timeout on policy calls; a service known to be slow during deploys can block request workers"
    suggested_fix: "Configure a short explicit timeout, bounded retry, optionally a circuit breaker"
    owner_proposed: "author"
    testable: yes
    confidence: 0.6
  - id: W2
    severity: WARNING
    file: src/docs/permissions.py
    line: 9
    dimension: testing
    stance: new-hire
    claim: "New authorization checks have no tests, including the service-error path"
    suggested_fix: "Add tests for allow, deny and exception paths of can_delete and can_read"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: N1
    severity: NOTE
    file: src/docs/permissions.py
    line: 13
    dimension: operability
    stance: new-hire
    claim: "Broad except Exception logs every error as 'policy service unavailable' with no exception info or ids"
    suggested_fix: "Catch client transport errors specifically; log with exc_info=True, user id, document id and action"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N2
    severity: NOTE
    file: src/docs/permissions.py
    line: 6
    dimension: architecture
    stance: architect
    claim: "PolicyClient built at import time as a hidden global, hard to configure and replace in tests"
    suggested_fix: "Inject the client or build it lazily with explicit configuration"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
  - id: N3
    severity: NOTE
    file: src/docs/permissions.py
    line: 11
    dimension: correctness
    stance: architect
    claim: "assumption: client.allowed returns a strict boolean; a non-bool return decides access by truthiness"
    suggested_fix: "Confirm the client contract or compare with `is True`"
    owner_proposed: "author"
    testable: no
    confidence: 0.4
```
