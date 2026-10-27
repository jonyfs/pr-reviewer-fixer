## Review: pasted diff, new k8s/api/deployment.yaml (API move to new cluster)

**Scope:** 1 file added, 22 lines, Kubernetes Deployment manifest (infrastructure)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=3 note=3
**Head:** unknown (pasted diff)

### Acceptance conditions
1. A1: The API Deployment runs on the new cluster with the pinned image digest.
2. A2: A deploy (new revision of this Deployment) never leaves the API with zero ready pods; old pods keep serving until new pods are ready.
3. A3: Traffic only reaches a pod once it can serve requests (readiness gating).
4. A4: Voluntary disruptions in the new cluster (node drain, upgrade) do not take all replicas down at once.

### Critical findings

**C1, k8s/api/deployment.yaml:8, reliability, Saboteur (also Architect).** `strategy.type: Recreate`
terminates all 3 existing pods before any new pod is created. The description states "The API must
stay up during deploys: customers call it all day."
Failure scenario: push a new image digest; the controller scales the old ReplicaSet to 0, all 3 pods
terminate, and until the new pods pull the image, start and pass readiness, every customer call gets
connection refused / 503. Every deploy is a full outage.
Fix: use `type: RollingUpdate` with `rollingUpdate: {maxUnavailable: 0, maxSurge: 1}` (or 25%), together
with a readiness probe (W1).

### Warnings (declared debt)

- **W1, k8s/api/deployment.yaml:18, reliability, Saboteur.** The container has no `readinessProbe` (nor
  `livenessProbe`) and no `ports`. Even after C1 is fixed, a rolling update counts a pod Ready as soon
  as its process starts, so traffic reaches pods that are still warming up and old pods are removed
  too early. Scenario: API takes 10s to open its listener; rollout replaces pods in 1-2s each and
  requests fail during the window. Fix: add `ports` and an HTTP `readinessProbe` (and a liveness
  probe), plus `minReadySeconds`. Owner: author.
- **W2, k8s/api/deployment.yaml:6, operability, Architect.** No PodDisruptionBudget and no topology
  spread / anti-affinity. On a new cluster, a node drain or upgrade can evict all 3 replicas at once,
  or all 3 may be scheduled on one node, so the "stay up" requirement fails outside deploys too.
  Fix: add a PDB (`minAvailable: 2` or `maxUnavailable: 1`) and `topologySpreadConstraints` on
  `kubernetes.io/hostname`. Owner: author.
- **W3, k8s/api/deployment.yaml:18, security, Security Auditor.** No `securityContext`: the container
  may run as root, with privilege escalation allowed and a writable root filesystem, and the default
  service account token is mounted. Fix: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `capabilities: {drop: [ALL]}`, `seccompProfile: RuntimeDefault`,
  and `automountServiceAccountToken: false` unless the API needs it. Owner: author.

### Notes (declared debt)

- **N1, k8s/api/deployment.yaml:4, operability, New Hire.** No `namespace`; the Deployment lands in
  whatever namespace the apply context selects. Question: is the target namespace set elsewhere
  (kustomize, CI)? Owner: author.
- **N2, k8s/api/deployment.yaml:19, security, Security Auditor.** Praise: the image is pinned by
  `sha256` digest, so the deployed bytes cannot change under the same reference. Owner: author.
- **N3, k8s/api/deployment.yaml:20, reliability, New Hire.** `assumption:` no CPU limit and a
  memory limit of 2x the request; the API is assumed to fit in 512Mi under load, otherwise pods are
  OOM-killed. No Service or Ingress is in the diff, so how traffic reaches these pods during the move
  was not checked. Owner: author.

### Coverage note
Target is a pasted diff: no repository code, conventions (AGENTS.md / CLAUDE.md of the target project
were not read), history, tests or CI were available. Cannot confirm a Service, Ingress, PDB or
kustomization exist elsewhere; W2 and N1 assume they do not.
Path floor (path-floor.sh --files over the file list): operability standard, reliability standard,
security standard; all run. Dimensions not applicable: data and migrations, dependencies, API
contract, testing (manifest only).
Agents: single reviewer covering Saboteur, New Hire, Security Auditor and Architect stances inline
(no sub-agent dispatch in this run).
Declined to judge: none

### Summary
The manifest contradicts the change's own stated requirement: `Recreate` takes all replicas down on
every deploy, an outage for customers who call the API all day. Switch to RollingUpdate with
`maxUnavailable: 0` and add a readiness probe; a PDB and spread constraints close the same gap for
node maintenance on the new cluster.

```findings
version: 1
pr: none
head: unknown
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 3, note: 3}
mandatory_units:
  - {unit: operability, effort: standard, status: run}
  - {unit: reliability, effort: standard, status: run}
  - {unit: security, effort: standard, status: run}
acceptance:
  - {id: A1, text: "API Deployment runs on the new cluster with the pinned image digest", status: closed}
  - {id: A2, text: "A deploy never leaves the API with zero ready pods", status: open}
  - {id: A3, text: "Traffic reaches a pod only once it is ready", status: open}
  - {id: A4, text: "Voluntary disruptions do not take all replicas down at once", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: k8s/api/deployment.yaml
    line: 8
    dimension: reliability
    stance: saboteur
    claim: "strategy Recreate kills all 3 pods before new ones start, so every deploy is an outage, contradicting the stated zero-downtime requirement"
    failure_scenario: "Deploy a new image digest: old ReplicaSet scales to 0, all pods terminate, customer calls get connection refused/503 until new pods start"
    suggested_fix: "type: RollingUpdate with rollingUpdate {maxUnavailable: 0, maxSurge: 1}, plus a readiness probe"
    testable: yes
    confidence: 0.95
    also_seen_by: [architect]
  - id: W1
    severity: WARNING
    file: k8s/api/deployment.yaml
    line: 18
    dimension: reliability
    stance: saboteur
    claim: "No readinessProbe, livenessProbe or ports; rolling updates would send traffic to pods not yet serving"
    suggested_fix: "Add containerPort, HTTP readinessProbe and livenessProbe, and minReadySeconds"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: W2
    severity: WARNING
    file: k8s/api/deployment.yaml
    line: 6
    dimension: operability
    stance: architect
    claim: "No PodDisruptionBudget or topology spread; a node drain or co-scheduling can take all replicas down"
    suggested_fix: "Add a PDB (maxUnavailable: 1) and topologySpreadConstraints on kubernetes.io/hostname"
    owner_proposed: "author"
    testable: yes
    confidence: 0.7
  - id: W3
    severity: WARNING
    file: k8s/api/deployment.yaml
    line: 18
    dimension: security
    stance: security-auditor
    claim: "No securityContext: container may run as root with privilege escalation and writable root fs; SA token automounted"
    suggested_fix: "runAsNonRoot, allowPrivilegeEscalation false, readOnlyRootFilesystem, drop ALL caps, seccomp RuntimeDefault, automountServiceAccountToken false"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N1
    severity: NOTE
    file: k8s/api/deployment.yaml
    line: 4
    dimension: operability
    stance: new-hire
    claim: "No namespace set; target namespace depends on apply context"
    suggested_fix: "Set metadata.namespace or confirm it is set by kustomize/CI"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
  - id: N2
    severity: NOTE
    file: k8s/api/deployment.yaml
    line: 19
    dimension: security
    stance: security-auditor
    claim: "praise: image pinned by sha256 digest"
    suggested_fix: "Keep it"
    owner_proposed: "author"
    testable: no
    confidence: 0.9
  - id: N3
    severity: NOTE
    file: k8s/api/deployment.yaml
    line: 20
    dimension: reliability
    stance: new-hire
    claim: "assumption: API fits in 512Mi memory limit under load; no Service/Ingress in the diff"
    suggested_fix: "Confirm memory headroom from load data; confirm the Service exists in the new cluster"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
```
