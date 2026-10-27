## Review: pasted diff, new `src/accounts/signup.py` (signup logging)

**Scope:** 1 file, 10 added lines, new feature (signup registration with logging)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=1 note=1
**Head:** n/a (pasted diff, no commit)

### Acceptance conditions
1. A signup creates the user from the submitted form and returns it.
2. Each signup leaves a log record that lets support trace account creation (for example the user id and the outcome).
3. No personal data (email, CPF, name) reaches the third-party log service named in the description.

### Critical findings
**C1. Email, CPF and name logged to a third-party log service** (`src/accounts/signup.py:8`, privacy/security, security-auditor; also seen by saboteur)
- Impact: line 8 writes the user's email, CPF (Brazilian national tax id) and full name in clear text at INFO level. The description states these logs are shipped to a third-party log service, so every signup discloses personal data to a processor outside the controller, with no contract or safeguard named (LGPD Art. 6 III minimisation, Art. 46 security; GDPR Art. 5(1)(c), 32). The privacy checklist classifies personal data exposed to a third party as a breach, CRITICAL.
- Failure scenario: a user signs up with `email=ana@example.com, cpf=123.456.789-09, name=Ana Silva`; the INFO record `new signup email=ana@example.com cpf=123.456.789-09 name=Ana Silva` is shipped to the external log vendor, where it is readable by vendor staff and anyone with log access, and is retained under the vendor's policy, outside the system's deletion path.
- Fix: delete line 8. Line 9 (`created user id=%s`) already gives support a traceable key; if more is needed, log a non-reversible reference (user id, a request id), never the raw email, CPF or name. Consider a logging filter that redacts CPF/email patterns as defence in depth.

### Warnings (declared debt)
**W1. No test for the new `register` function** (`src/accounts/signup.py:6`, testing, new-hire). New logic ships without a test, and nothing guards against personal data returning to the log line. Add a test that registers a user and asserts (with `caplog`) that no record contains the email, CPF or name, and that the user id is logged. Owner: author.

### Notes (declared debt)
**N1. question: storage of the CPF** (`src/accounts/signup.py:7`, privacy, architect, confidence 0.4). The CPF is passed to `users.create`; the diff does not show whether it is encrypted at rest, restricted by role, or needed for signup at all (minimisation). Confirm the store protects it. Owner: author.

### Coverage note
- Target: pasted diff. Unavailable: repository code (cannot see `users.create`, callers, existing log filters or handlers), project conventions (base rules not read), history, tests, CI.
- Dimensions run: privacy, security, testing, correctness, operability. Not applicable: performance, migrations, dependencies, concurrency.
- Correctness: `form["..."]` raises `KeyError` on a missing field and `users.create` may raise on duplicates; whether the caller validates first cannot be confirmed from the diff, so not raised as a finding.
- Agents: single reviewer applying the saboteur, new-hire, security-auditor and architect stances inline; no sub-agents dispatched.
- Path floor: `path-floor.sh` not run (no base or head commit); no mandatory units recorded.
- Declined to judge: none

### Summary
A small change that turns every signup into a disclosure of email, CPF and name to an external log vendor. Remove the personal data from line 8 and keep the user-id line, which already meets the stated support need; add a test that keeps it out.

```findings
version: 1
pr: none
head: none
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 1, note: 1}
mandatory_units: []
acceptance:
  - {id: A1, text: "A signup creates the user from the submitted form and returns it", status: closed}
  - {id: A2, text: "Each signup leaves a log record that lets support trace account creation", status: closed}
  - {id: A3, text: "No personal data (email, CPF, name) reaches the third-party log service", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/accounts/signup.py
    line: 8
    dimension: privacy
    stance: security-auditor
    claim: "Email, CPF and name are logged in clear text and shipped to a third-party log service"
    failure_scenario: "Signup with email=ana@example.com cpf=123.456.789-09 name=Ana Silva emits an INFO record containing all three, which is shipped to the external log vendor"
    suggested_fix: "Remove the personal data from the log line; log only the user id or a request id"
    testable: yes
    confidence: 0.95
    owasp: A09:2025
    cwe: CWE-532
    also_seen_by: [saboteur]
  - id: W1
    severity: WARNING
    file: src/accounts/signup.py
    line: 6
    dimension: testing
    stance: new-hire
    claim: "New register function has no test; nothing prevents personal data returning to logs"
    suggested_fix: "Add a test with caplog asserting no record contains email, CPF or name, and that the user id is logged"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N1
    severity: NOTE
    file: src/accounts/signup.py
    line: 7
    dimension: privacy
    stance: architect
    claim: "question: is the stored CPF needed, encrypted at rest and role-restricted? Not visible in the diff"
    suggested_fix: "Confirm minimisation and protection of the CPF in the users store"
    owner_proposed: "author"
    testable: no
    confidence: 0.4
```
