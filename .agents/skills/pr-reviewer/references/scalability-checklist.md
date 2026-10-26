---
Summary: Scalability and capacity checks for a pull request: unbounded work, N+1 access, hot paths and growth.
Tags: [#pr #review #scalability #capacity #performance #reference]
---

# Scalability and Capacity Checklist

Flag a scalability finding only with evidence: a loop, a query or a payload whose size grows with
data or users, in a path the change makes reachable. A finding names the growth (per row, per user,
per request) and the size at which it hurts. Micro-optimisation without that is not a finding.

| Check | What a finding looks like |
|---|---|
| **Unbounded reads** | A query or API call with no limit or pagination on a table or list that grows; loading a whole table or file into memory. |
| **N+1 access** | A query, HTTP call or file read inside a loop over results, where one batched call would do. |
| **Missing indexes** | A new query filters or sorts on a column with no index, on a table the pull request or the schema shows is large. |
| **Hot-path cost** | Synchronous I/O, a lock, a full scan or an expensive serialisation added to a path every request takes. |
| **Fan-out** | One request that triggers work proportional to followers, tenants or items, with no queue or cap. |
| **Contention** | A single row, key or lock every writer updates (a global counter, a status row). |
| **Payload growth** | A response, message or cache entry that grows without bound; no compression or streaming for large bodies. |
| **Capacity limits** | A new dependency on a rate-limited API or a quota with no budget or backoff; a fixed pool size that the expected load exceeds. |

Anchors: ISO/IEC 25010:2023 performance efficiency (time behaviour, resource utilisation, capacity)
and flexibility (scalability), and the AWS Well-Architected performance efficiency and cost
optimisation pillars.
