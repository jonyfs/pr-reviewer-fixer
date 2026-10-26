---
Summary: Reliability and resilience checks for a pull request: timeouts, retries, idempotency, degradation and recovery.
Tags: [#pr #review #reliability #resilience #reference]
---

# Reliability and Resilience Checklist

Run this unit when the change calls another service, a database, a queue or the network, runs in
the background, or changes infrastructure or deployment files (the path floor summons it for
those). A failure path that loses data or takes the service down for every user is CRITICAL when the
trigger is ordinary (a slow dependency, a restart, a retry); otherwise a WARNING with its scenario.

| Check | What a finding looks like |
|---|---|
| **Timeouts** | A network, database or subprocess call with no timeout, or one longer than the caller's own deadline. |
| **Retries** | A retry with no limit, no backoff or no jitter (a retry storm); a retry of an operation that is not idempotent (a double charge, a duplicate row). |
| **Idempotency** | A handler for a message, webhook or job that runs twice on redelivery with a different result; no idempotency key where the client can retry. |
| **Partial failure** | Two writes that must both happen with no transaction, outbox or compensation; a crash between them leaves a state nothing repairs. |
| **Degradation** | A non-essential dependency whose failure fails the whole request; no fallback, cache or circuit breaker where the pull request says the dependency is flaky. |
| **Resource exhaustion** | An unbounded queue, pool, buffer or goroutine/thread spawn; a connection or file handle not closed on the error path. |
| **Startup and shutdown** | A process that drops in-flight work on SIGTERM; a readiness check that passes before dependencies are ready; a migration that must finish before the new code serves. |
| **Recovery** | State that cannot be rebuilt after a crash (in-memory only, no replay); a backup or restore path the change breaks. |

Anchors: ISO/IEC 25010:2023 reliability (faultlessness, availability, fault tolerance,
recoverability) and the AWS Well-Architected reliability pillar. Google's SRE book is the reference
for retries, load shedding and graceful degradation.
