---
Summary: Data integrity and migration checks for a pull request: safe schema changes, constraints, backfills and rollback.
Tags: [#pr #review #data #migrations #integrity #reference]
---

# Data Integrity and Migrations Checklist

The path floor summons this unit (with security) for migrations and schema files. A lost or
silently rewritten row is the worst kind of bug: nothing errors. A change that can lose or corrupt
existing data in an ordinary deploy is CRITICAL.

| Check | What a finding looks like |
|---|---|
| **Destructive change** | `DROP COLUMN`, `DROP TABLE`, a type narrowing or a `NOT NULL` with no default on a populated table, in the same deploy as the code that stops using it. Expand, migrate, contract: add first, backfill, switch the code, drop later. |
| **Locking** | A migration that rewrites or locks a large table (`ALTER TYPE`, an index built without the database's online option) during traffic. |
| **Backfill** | A backfill in one transaction over a large table, with no batching, no resume point, or one that runs before the code that writes the new column is live. |
| **Constraints** | An invariant the code assumes (unique, foreign key, not null, check) that the schema does not enforce, so a concurrent writer or a second service breaks it. |
| **Transactions** | Related writes outside one transaction; a read-modify-write without a lock or a conditional update. |
| **Rollback** | No down migration, or a down migration that loses the data the up one moved; code that cannot run against both the old and the new schema during a rolling deploy. |
| **Data correctness** | Time zones, encodings, rounding of money, precision of numeric types, collation changes that reorder or merge keys. |
| **Personal data** | A new column holding personal data with no retention or deletion path (see the privacy checklist). |

Anchors: ISO/IEC 25010:2023 functional correctness and reliability, and ISO/IEC 25012 for data
quality (accuracy, completeness, consistency).
