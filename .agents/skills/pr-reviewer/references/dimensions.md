---
Summary: The review dimensions a PR reviewer must evaluate, with concrete checks for each.
Tags: [#pr #review #quality #reference]
---

# Review Dimensions

Evaluate every applicable dimension. Design is the highest-leverage; judge it before line details.

| Dimension | Concretely look for |
|-----------|---------------------|
| **Correctness / functionality** | Does it do what the PR claims? Edge cases, off-by-one, null/empty/boundary inputs, race conditions. Behavior serves the end user, not just author intent. |
| **Design / architecture** *(most important)* | Fits the existing system; right layer; not over-engineered or speculative; sound component interactions; no leaky abstractions; separation of concerns. Reject design problems early. See [architecture-checklist.md](architecture-checklist.md). |
| **Complexity** | Can a reader understand it quickly? No premature generalization; is there a simpler alternative? |
| **Readability / maintainability** | Descriptive but not unwieldy names; comments explain *why* not *what*; small single-purpose functions; dead code removed; consistent with local style. |
| **Security** | See [security-checklist.md](security-checklist.md), keyed to the OWASP Top 10:2025 with ASVS 5.0.0 for depth. A confirmed risk is CRITICAL when it is exploitable, WARNING otherwise. |
| **Performance** | Flag only when it matters: N+1 queries, unbounded loops/allocations, sync I/O in hot paths, missing pagination/indexes, avoidable copies. Do not micro-optimize without evidence. |
| **Testing / coverage** | Tests exist and are meaningful; fail when code breaks; cover edge/error paths, not just happy path; deterministic (no flakiness); names document intent. Missing tests for new logic is a real review concern. |
| **Error handling** | Errors caught at the right level; no swallowed exceptions; failures observable (logged/metric); resources closed; graceful degradation; no sensitive data in error messages. |
| **Concurrency** | Shared mutable state guarded; no deadlock / lock-ordering issues; atomic check-then-act; thread-safe collections; async cancellation/timeouts. |
| **API / backward-compat** | Signature changes additive or versioned; no breaking wire/serialization changes; deprecation path; safe defaults; contract documented. |
| **Docs** | Updated when behavior, build, release, or user-facing interaction changes; README/API docs/changelog; ADR for significant decisions. |
| **Dependencies** | New deps justified, license-compatible, maintained, pinned; no known CVEs; minimal transitive bloat; prefer stdlib. |
| **Observability** | Key actions, failures, and state transitions are visible through logs, metrics, or traces when the change affects production diagnosis. |
| **Data integrity / migrations** | Schema changes are expand-then-contract; no data loss or silent rewrite; constraints enforce invariants; backfills batch and resume; rollback works. See [data-and-migrations-checklist.md](data-and-migrations-checklist.md). |
| **Reliability / resilience** | Timeouts, bounded retries with backoff, idempotent handlers, partial-failure recovery, graceful degradation, clean startup and shutdown. See [reliability-checklist.md](reliability-checklist.md). |
| **Scalability / capacity** | Unbounded reads, N+1 access, missing indexes, hot-path cost, fan-out and contention, each with the growth that makes it hurt. See [scalability-checklist.md](scalability-checklist.md). |
| **Operability / deployability** | Safe configuration, gradual rollout, rollback, health signals, diagnosis and alerting, infrastructure as code. See [operability-checklist.md](operability-checklist.md). |
| **Privacy / data protection** | Personal data minimised, kept out of logs, used for its purpose, retained and deleted on time, transferred with safeguards (LGPD, GDPR). See [privacy-checklist.md](privacy-checklist.md). |

## Applying Them

- Not every dimension applies to every PR. Skip cleanly those that don't, but always cover
  correctness, design, security, and tests, and every unit the path floor makes mandatory.
- Severity per area follows [severity-and-verdict.md](severity-and-verdict.md): a defect that loses
  data, exposes personal data, lets an attacker in (crafted input counts as a path) or causes a
  production outage of any scope, one endpoint or one region included, is CRITICAL. A reliability,
  scalability or operability defect short of that is a WARNING with its scenario (the load, the
  failure or the deploy that triggers it), and a NOTE without one.
- Tie each finding to a specific dimension so the author sees the category of risk.
- Weight design and correctness above style; a clean-looking PR with a design flaw is worse than a
  rough one that is structurally sound.
