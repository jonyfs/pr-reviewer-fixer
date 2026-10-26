---
Summary: Operability and deployability checks for a pull request: configuration, rollout, rollback, health and diagnosis.
Tags: [#pr #review #operability #deployability #sre #reference]
---

# Operability and Deployability Checklist

Run this unit when the change touches deployment, infrastructure or configuration files (the path
floor summons it for Terraform, Kubernetes, Helm, Compose and similar) or adds a service, a job or a
feature flag. A finding names what an on-call person could not do: deploy safely, roll back, see the
failure, or turn the feature off.

| Check | What a finding looks like |
|---|---|
| **Configuration** | A new setting with no default, no validation at start, or a different name per environment; a secret in a plain config file. |
| **Rollout** | A change that cannot ship gradually (no flag, no canary path) when it alters behaviour for every user; a flag with no owner or removal plan. |
| **Rollback** | A deploy that cannot be undone: a migration or a message format the old version cannot read. |
| **Health** | A new service or worker with no liveness or readiness signal, or one that reports healthy while its dependency is down. |
| **Diagnosis** | A new failure mode with no log line, metric or trace that names it; logs without a request or correlation id. |
| **Alerting** | A new SLO-relevant path with no alert, or an alert with no runbook. |
| **Infrastructure as code** | Resources changed by hand instead of in code; a Terraform change with `prevent_destroy` removed or a replacement of a stateful resource; a Kubernetes workload with no resource requests and limits. |
| **Cost** | A resource whose cost grows with traffic or data with no cap (autoscaling with no maximum, log volume with no retention). |

Anchors: ISO/IEC 25010:2023 flexibility (adaptability, scalability, installability, replaceability) and
maintainability, the AWS Well-Architected operational excellence pillar, and SRE practice (SLOs,
error budgets, runbooks).
