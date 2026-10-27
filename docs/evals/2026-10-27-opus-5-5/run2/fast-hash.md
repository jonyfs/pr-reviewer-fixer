## Review: pasted diff, src/accounts/passwords.py (password hashing and reset tokens)

**Scope:** 1 new file, 10 added lines, security-sensitive (path `passwords` puts security at `max` on the path floor)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=1 note=3
**Head:** n/a (pasted diff)

### Acceptance conditions
1. Stored passwords cannot be recovered or cheaply brute-forced from a leaked database: each is hashed with a slow, salted KDF (Argon2id, scrypt, bcrypt or PBKDF2 with a current work factor).
2. A password check compares against the stored hash in constant time.
3. Reset tokens come from a CSPRNG with at least 128 bits of entropy.
4. New logic has tests covering hash, verify and token generation.

### Critical findings

**C1. Passwords hashed with unsalted single-round SHA-256** (`src/accounts/passwords.py:6`, security, Security Auditor; also seen by Saboteur)
- Impact: SHA-256 is a fast hash, built for throughput. With no salt, identical passwords yield identical digests, so one precomputed table or one GPU run (billions of SHA-256 per second) cracks the whole table at once. The PR's purpose is to stop storing recoverable passwords, and this does not achieve it (OWASP A04:2025, CWE-916, CWE-759).
- Failure scenario: a database dump holds `hash_password("Summer2024!")` for many users. The attacker looks the hex digest up in a public SHA-256 rainbow table, or runs hashcat mode 1400 over a wordlist, and recovers the plaintext for every account sharing that password in seconds.
- Fix: use a password KDF with a per-password salt, e.g. `argon2-cffi` (`PasswordHasher().hash(pw)` / `.verify(stored, pw)`), or `hashlib.scrypt(pw, salt=os.urandom(16), n=2**14, r=8, p=1)` storing the salt and parameters with the hash. Rehash on next login for existing records.

### Warnings (declared debt)

**W1. No tests for new security logic** (`src/accounts/passwords.py:5`, testing, New Hire). The diff adds hashing and token generation with no test. Owner: author.

### Notes (declared debt)

**N1. question: no verify function** (`src/accounts/passwords.py:5`, security, Architect). Callers will compare digests themselves, likely with `==`, which is not constant time. Add `verify_password(stored, password)` using the KDF's verify or `hmac.compare_digest`. Confidence 0.6 (callers not visible). Owner: author.

**N2. assumption: reset tokens are stored hashed, single-use and expiring** (`src/accounts/passwords.py:10`, security, Saboteur). `secrets.token_urlsafe(32)` is sound (256 bits, CSPRNG). Nothing in the diff stores, expires or invalidates it; if it is stored in plain text a DB read grants account takeover. Owner: author.

**N3. question: migration of existing plain-text passwords** (`src/accounts/passwords.py:5`, data-integrity, Architect). The description says passwords were stored as plain text; the diff shows no migration converting them or clearing the plaintext column. Owner: author.

### Coverage note
Pasted diff: repository code, callers, conventions (AGENTS.md / CLAUDE.md at base), history, tests and CI were unavailable; `screen`, `scan-hidden.py` and `path-floor.sh` could not run on a git range. Path floor applied by hand: `passwords` matches the AUTH pattern, so security ran at `max`. Single reviewer covering security, correctness, testing and architecture stances.
Declined to judge: none (the whole 10-line diff was read).

### Summary
The change replaces plaintext storage with unsalted SHA-256, which is still trivially crackable after a leak, so it blocks. Switch `hash_password` to Argon2id, scrypt or bcrypt with a per-password salt and add a constant-time verify. Reset token generation itself is sound.

```findings
version: 1
pr: 0
head: pasted-diff
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 1, note: 3}
mandatory_units:
  - {unit: security, effort: max, status: run}
acceptance:
  - {id: A1, text: "Passwords hashed with a slow salted KDF", status: open}
  - {id: A2, text: "Password check compares in constant time", status: open}
  - {id: A3, text: "Reset tokens from a CSPRNG with >=128 bits", status: closed}
  - {id: A4, text: "Tests cover hash, verify and token generation", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/accounts/passwords.py
    line: 6
    dimension: security
    stance: security-auditor
    claim: "Passwords hashed with unsalted single-round SHA-256, a fast hash"
    failure_scenario: "Leaked digest of a common password is reversed via rainbow table or hashcat mode 1400 in seconds; identical passwords share digests"
    suggested_fix: "Use Argon2id (argon2-cffi), scrypt or bcrypt with a per-password salt; rehash on login"
    testable: yes
    confidence: 0.95
    also_seen_by: [saboteur]
    owasp: A04:2025
    cwe: CWE-916
  - id: W1
    severity: WARNING
    file: src/accounts/passwords.py
    line: 5
    dimension: testing
    stance: new-hire
    claim: "No tests for new hashing and token logic"
    suggested_fix: "Add tests: hash differs per call (salt), verify accepts right and rejects wrong password, token length/uniqueness"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N1
    severity: NOTE
    file: src/accounts/passwords.py
    line: 5
    dimension: security
    stance: architect
    claim: "No verify function; callers may compare digests with non-constant-time =="
    suggested_fix: "Add verify_password using the KDF's verify or hmac.compare_digest"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
  - id: N2
    severity: NOTE
    file: src/accounts/passwords.py
    line: 10
    dimension: security
    stance: saboteur
    claim: "assumption: reset tokens are stored hashed, single-use and expiring; nothing in the diff ensures it"
    suggested_fix: "Store only a hash of the token with an expiry and invalidate it on use"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N3
    severity: NOTE
    file: src/accounts/passwords.py
    line: 5
    dimension: data-integrity
    stance: architect
    claim: "No migration for existing plain-text passwords"
    suggested_fix: "Add a migration or rehash-on-login path and drop the plaintext column"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
