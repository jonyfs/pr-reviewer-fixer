## Review: pasted diff, new module src/auth/tokens.py

**Scope:** 1 file, 13 added lines, new authentication helper (JWT decoding)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=2 note=2
**Head:** n/a (pasted diff)

### Acceptance conditions
1. The user id returned for an API call comes only from a bearer token whose signature was verified with the server key and a pinned algorithm list.
2. A forged, tampered, unsigned (`alg: none`) or expired token is rejected and yields no user id.
3. Tests show the accept and reject paths of `user_from_token`.

### Critical findings

**C1. `user_from_token` decodes the bearer token without verifying its signature** (`src/auth/tokens.py:7`, security, Security Auditor; also Saboteur)
`jwt.decode(token, options={"verify_signature": False})` returns whatever claims the caller wrote. The description says this function supplies the user id "on every API call", so it is the authentication step. With verification off, PyJWT also skips `exp`, `nbf` and `aud` checks.
Failure scenario: an attacker builds `{"alg":"none"}` or any HS256 token signed with an arbitrary key, payload `{"sub":"<victim id>"}`, and sends it as `Authorization: Bearer <token>`. `user_from_token` returns the victim's id and the request runs as that user. Expired or revoked tokens are accepted the same way. OWASP A07:2025 / A01:2025, CWE-347.
Fix: `jwt.decode(token, SECRET, algorithms=["HS256"], audience=<user audience>, options={"require": ["exp", "sub"]})`, as `service_from_token` already does for the key and algorithm, and map `jwt.InvalidTokenError` to a 401.

### Warnings (declared debt)

- **W1** `src/auth/tokens.py:6` testing, New Hire. New authentication logic ships with no tests; nothing would catch C1 or a regression of its fix. Add tests for a valid token, a token signed with another key, an `alg: none` token, an expired token, and a service token presented as a user token. Owner: author.
- **W2** `src/auth/tokens.py:12` security, Saboteur. `service_from_token` does not require `exp`: PyJWT checks `exp` only when present, so a service token minted without it never expires. Add `options={"require": ["exp", "sub"]}`. Owner: author.

### Notes (declared debt)

- **N1** `src/auth/tokens.py:3` maintainability, New Hire. `__import__("os").environ["JWT_SECRET"]` should be `import os` at the top. Reading at import time fails the whole import with `KeyError` when the variable is unset; fail-fast is acceptable, but the error should name the variable clearly. Owner: author.
- **N2** `src/auth/tokens.py:8` reliability, Architect. `claims["sub"]` raises `KeyError` on a token without `sub`, which surfaces as a 500 rather than a 401 unless the caller catches it. `assumption:` callers translate decode errors into 401. Owner: author.

### Coverage note
Target is a pasted diff: no repository, so project rules (AGENTS.md, CLAUDE.md) were not read at a base commit, callers of `user_from_token` could not be inspected, CI and tests could not be run, and `review-cycle.sh screen` / `scan-hidden.py` were not run against a PR (manual read found no credential and no hidden text in the 13 lines). `path-floor.sh --files` printed `security max src/auth/tokens.py`; the security unit was run at max effort by this single reviewer (no parallel sub-agents in this run). Dimensions not applicable: data and migrations, dependencies (PyJWT is assumed already declared; the manifest is not in the diff), scalability.
Declined to judge: none

### Summary
The new module authenticates users from a JWT whose signature is never checked, so any client can impersonate any user; this blocks. Verify the token with the server key and pinned algorithm (as the service path already does), require `exp`, and add reject-path tests.

```findings
version: 1
pr: null
head: null
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 2, note: 2}
mandatory_units:
  - {unit: security, effort: max, status: run}
acceptance:
  - {id: A1, text: "User id comes only from a token verified with the server key and pinned algorithms", status: open}
  - {id: A2, text: "Forged, unsigned, tampered or expired tokens are rejected", status: open}
  - {id: A3, text: "Tests cover accept and reject paths of user_from_token", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/auth/tokens.py
    line: 7
    dimension: security
    stance: security-auditor
    claim: "user_from_token decodes the bearer token with verify_signature False, so any forged token yields any user id"
    failure_scenario: "Bearer token with alg none (or signed with an attacker key) and sub=<victim id> makes user_from_token return the victim id; expired tokens are also accepted"
    suggested_fix: "jwt.decode(token, SECRET, algorithms=['HS256'], audience=<user aud>, options={'require': ['exp','sub']}) and map InvalidTokenError to 401"
    testable: yes
    confidence: 0.97
    also_seen_by: [saboteur]
    owasp: A07:2025
    cwe: CWE-347
  - id: W1
    severity: WARNING
    file: src/auth/tokens.py
    line: 6
    dimension: testing
    stance: new-hire
    claim: "New authentication logic has no tests"
    suggested_fix: "Add tests for valid, wrong-key, alg none, expired and wrong-audience tokens"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: W2
    severity: WARNING
    file: src/auth/tokens.py
    line: 12
    dimension: security
    stance: saboteur
    claim: "service_from_token does not require exp, so a service token minted without exp never expires"
    suggested_fix: "Pass options={'require': ['exp','sub']}"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: N1
    severity: NOTE
    file: src/auth/tokens.py
    line: 3
    dimension: maintainability
    stance: new-hire
    claim: "__import__('os') inline import; missing JWT_SECRET fails the import with a bare KeyError"
    suggested_fix: "import os at top; raise a clear error naming JWT_SECRET"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N2
    severity: NOTE
    file: src/auth/tokens.py
    line: 8
    dimension: reliability
    stance: architect
    claim: "claims['sub'] raises KeyError on a token without sub, likely a 500 instead of 401"
    suggested_fix: "Require sub in decode options or catch and map to 401"
    owner_proposed: "author"
    testable: yes
    confidence: 0.6
```
