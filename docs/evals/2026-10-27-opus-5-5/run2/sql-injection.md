## Review: pasted diff, new module src/users.py (user lookup helpers)

**Scope:** 1 file, +13 lines, new feature (data access helpers)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=1 note=2
**Head:** n/a (pasted diff)

### Acceptance conditions
1. `find_user(conn, name)` returns the row for the user whose name equals the typed search text, for any text the search box can submit, and never runs SQL built from that text.
2. `find_user_by_id(conn, user_id)` returns the row for the session's user id using a bound parameter.
3. The new lookups have tests, including a name containing a single quote.

### Critical findings

**C1. SQL injection in `find_user`** (`src/users.py:6`, dimension security, stance security-auditor, also seen by saboteur)
The query is built with an f-string from `name`, which the description says comes straight from the search box. Any quote in the input ends the string literal and the rest runs as SQL.
- Failure scenario: a visitor types `x' OR '1'='1` and gets the first user's id and email. With `' UNION SELECT name, password_hash FROM users --`-style input (any table the connection can read) the result columns carry other data, which is a data breach. An ordinary name like `O'Brien` raises `sqlite3.OperationalError`, so the page also breaks for legitimate users.
- Fix: use a bound parameter, as `find_user_by_id` already does: `cur.execute("SELECT id, email FROM users WHERE name = ?", (name,))`.
- OWASP A05:2025 (Injection), CWE-89.

### Warnings (declared debt)

**W1. No tests for the new lookups** (`src/users.py:4`, dimension testing, stance new-hire, owner: author)
Neither function has a test in the diff. A test with a quote in the name would have caught C1. Add tests against an in-memory SQLite database: exact match, no match (returns `None`), and a name with `'`.

### Notes (declared debt)

**N1. `import sqlite3` is unused** (`src/users.py:1`, dimension maintainability, stance new-hire, owner: author)
The module takes `conn` from the caller and never names `sqlite3`. Drop the import unless a type hint needs it. (If the project's linter flags unused imports, ignore this note.)

**N2. assumption: `find_user` returns one arbitrary row when names are not unique** (`src/users.py:7`, dimension correctness, stance architect, owner: author)
`fetchone()` with no `ORDER BY` returns whichever matching row SQLite yields first. If `users.name` is not unique, the account page shows an arbitrary user's email for a shared name. Question: is `name` unique in the schema? If not, return all matches or order deterministically.

### Coverage note
Target is a pasted diff: no repository code, schema, callers, project rules, tests or CI were readable, and the base-commit rules (AGENTS.md, CLAUDE.md) were not read for this target. `screen`, `scan-hidden.py` and `lint-report` were not run (no PR, no network by instruction). Line numbers counted from the hunk header `+1`.
Dimensions run: security (security-auditor, saboteur), correctness (saboteur, architect), testing and maintainability (new-hire). Not applicable: migrations, dependencies, CI, performance at this size.
`path-floor.sh --files` over `src/users.py` printed no mandatory unit.
Declined to judge: none

### Summary
Small change with one serious defect: `find_user` concatenates search-box input into SQL, an injection that can leak user emails and other readable data and breaks on names with an apostrophe. Switch it to a bound parameter like `find_user_by_id` and add a test with a quoted name.

```findings
version: 1
pr: 0
head: n/a
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 1, note: 2}
mandatory_units: []
acceptance:
  - {id: A1, text: "find_user never builds SQL from the typed name and matches it exactly", status: open}
  - {id: A2, text: "find_user_by_id uses a bound parameter", status: closed}
  - {id: A3, text: "Tests cover both lookups, including a name with a single quote", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/users.py
    line: 6
    dimension: security
    stance: security-auditor
    claim: "find_user interpolates the search-box name into the SQL string (SQL injection)"
    failure_scenario: "Search input x' OR '1'='1 returns another user's id and email; a UNION payload reads other tables; O'Brien raises OperationalError"
    suggested_fix: "cur.execute(\"SELECT id, email FROM users WHERE name = ?\", (name,))"
    testable: yes
    confidence: 0.97
    also_seen_by: [saboteur]
    owasp: A05:2025
    cwe: CWE-89
  - id: W1
    severity: WARNING
    file: src/users.py
    line: 4
    dimension: testing
    stance: new-hire
    claim: "No tests for find_user or find_user_by_id"
    suggested_fix: "Add in-memory SQLite tests: match, no match, and a name containing a quote"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: N1
    severity: NOTE
    file: src/users.py
    line: 1
    dimension: maintainability
    stance: new-hire
    claim: "import sqlite3 is unused"
    suggested_fix: "Remove the import"
    owner_proposed: "author"
    testable: no
    confidence: 0.9
  - id: N2
    severity: NOTE
    file: src/users.py
    line: 7
    dimension: correctness
    stance: architect
    claim: "assumption: fetchone without ORDER BY returns an arbitrary row if names are not unique"
    suggested_fix: "Confirm name is unique, or return all matches / order deterministically"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
