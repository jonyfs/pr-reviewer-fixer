## Review: pasted diff, db/migrations/0042_rename_email.sql

**Scope:** 1 file, 4 added lines, schema migration (column rename)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=2 warning=2 note=1
**Head:** n/a (pasted diff)

### Acceptance conditions
1. After the migration every existing row of `users` has its email value in `email_address`, unchanged.
2. The application keeps working through and after the deploy of this migration, before the later pull request that switches the code lands.
3. Constraints and indexes that held on `users.email` hold on `users.email_address`.
4. The migration can be rolled back without losing data.

### Critical findings

**C1. Every stored email is destroyed** (`db/migrations/0042_rename_email.sql:3`, data integrity, Saboteur; also Architect)
The migration adds an empty `email_address` column (line 2) and then drops `email` (line 3). No statement copies the values across (`UPDATE users SET email_address = email` or `ALTER TABLE users RENAME COLUMN email TO email_address`). This is not a rename.
Failure scenario: a `users` table holds 10,000 rows with emails. After the migration, `email_address` is NULL in all 10,000 rows and the `email` data is gone. Only a backup restore brings it back.
Fix: use `ALTER TABLE users RENAME COLUMN email TO email_address;`. If the expand/contract route is wanted instead, add the column, backfill it in batches, and leave the drop out of this migration.

**C2. Drop ships before the code that stops using the column** (`db/migrations/0042_rename_email.sql:3`, data integrity / reliability, Architect; also New Hire)
The description says the application code moves to `email_address` in a later pull request. Until then the code still reads and writes `users.email`, and that column no longer exists.
Failure scenario: deploy this migration, then a login or signup runs `SELECT ... WHERE email = $1` or `INSERT INTO users (email, ...)`. The database raises "column email does not exist" and every request that touches user email fails. That is a production outage.
Fix: expand, migrate, contract. Add and backfill `email_address` here (or keep the old column readable through a view or trigger), switch the code in the next pull request, and drop `email` in a third migration after that code is live. A plain `RENAME COLUMN` in the same deploy as the code change also works.

### Warnings (declared debt)

**W1. Index built with a blocking lock** (`db/migrations/0042_rename_email.sql:4`, performance / data integrity, Saboteur). A plain `CREATE INDEX` holds a lock that blocks writes to `users` until the build finishes. On a large table that stalls signups and profile updates while the deploy runs. Use `CREATE INDEX CONCURRENTLY` (outside a transaction on PostgreSQL), or the online option of whatever database this is. If a rename keeps the existing index, this statement is not needed at all. Owner: author.

**W2. No rollback path** (`db/migrations/0042_rename_email.sql:1`, data integrity, Architect). There is no down migration, and no down migration could recover data after line 3 runs. Add a down step. With the rename fix it becomes a reverse `RENAME COLUMN` and needs no data movement. Owner: author.

### Notes (declared debt)

**N1. question: constraints on `email` are not carried over** (`db/migrations/0042_rename_email.sql:2`, data integrity, Security Auditor, confidence 0.5). `email_address` is created as a nullable `TEXT` column with a non-unique index. If `email` was `NOT NULL` or `UNIQUE`, as login emails usually are, both invariants are lost, and duplicate accounts with the same address become possible. The diff does not show the original definition. A `RENAME COLUMN` keeps the existing constraints. Owner: author.

### Coverage note
Target is a pasted diff with no repository, so the base schema of `users`, the application queries, the CI results and the project rules were not available. Units run: data integrity (standard), security (standard), reliability, architecture. The path floor puts this file under migrations, so data-integrity and security are mandatory. `screen` and `scan-hidden.py` were not run because there is no git range; a manual read of the 4 lines found no credentials and no hidden text.
Declined to judge: none.

### Summary
The migration claims to rename a column, but it drops `email` without copying it and ships before the code that still reads it. Deploying it loses every user email and breaks every query on that column. Replace lines 2 and 3 with `ALTER TABLE users RENAME COLUMN email TO email_address`, or split the change into expand, migrate and contract steps.

```findings
version: 1
pr: none
head: none
pass: 1
verdict: BLOCKED
counts: {critical: 2, warning: 2, note: 1}
mandatory_units:
  - {unit: security, effort: standard, status: run}
  - {unit: data-integrity, effort: standard, status: run}
acceptance:
  - {id: A1, text: "Existing email values survive in email_address unchanged", status: open}
  - {id: A2, text: "Application keeps working before the code switch lands", status: open}
  - {id: A3, text: "Constraints and indexes of email hold on email_address", status: open}
  - {id: A4, text: "Migration can be rolled back without data loss", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: db/migrations/0042_rename_email.sql
    line: 3
    dimension: data-integrity
    stance: saboteur
    claim: "email is dropped without its values being copied to email_address; all emails are lost"
    failure_scenario: "users has 10000 rows with emails; after migration email_address is NULL for all and email data is gone"
    suggested_fix: "ALTER TABLE users RENAME COLUMN email TO email_address (or add, backfill, and drop later)"
    testable: yes
    confidence: 0.98
    also_seen_by: [architect]
  - id: C2
    severity: CRITICAL
    file: db/migrations/0042_rename_email.sql
    line: 3
    dimension: reliability
    stance: architect
    claim: "Column dropped before the application code stops using it (code change is in a later PR)"
    failure_scenario: "After deploy, the unchanged app runs SELECT/INSERT on users.email and gets 'column email does not exist'; login and signup fail"
    suggested_fix: "Expand/migrate/contract: keep email until the code switch is live, drop it in a later migration"
    testable: yes
    confidence: 0.95
    also_seen_by: [new-hire]
  - id: W1
    severity: WARNING
    file: db/migrations/0042_rename_email.sql
    line: 4
    dimension: performance
    stance: saboteur
    claim: "CREATE INDEX without CONCURRENTLY blocks writes to users during the build"
    suggested_fix: "CREATE INDEX CONCURRENTLY, or keep the existing index via RENAME COLUMN"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: W2
    severity: WARNING
    file: db/migrations/0042_rename_email.sql
    line: 1
    dimension: data-integrity
    stance: architect
    claim: "No down migration, and the drop makes rollback impossible without data loss"
    suggested_fix: "Add a down step; with RENAME COLUMN it is a reverse rename"
    owner_proposed: "author"
    testable: yes
    confidence: 0.75
  - id: N1
    severity: NOTE
    file: db/migrations/0042_rename_email.sql
    line: 2
    dimension: data-integrity
    stance: security-auditor
    claim: "question: NOT NULL/UNIQUE constraints of email are not recreated on email_address"
    suggested_fix: "Recreate the constraints, or use RENAME COLUMN which keeps them"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
