---
Summary: Design and architecture checks for a pull request, anchored on ISO/IEC 25010 maintainability and the AWS Well-Architected pillars.
Tags: [#pr #review #design #architecture #reference]
---

# Architecture Checklist

Design is the highest-leverage dimension: a structural flaw costs more the longer it stays. Judge it
before line details. Severity comes from the cost of the flaw in this codebase, not from taste: a
WARNING needs a concrete consequence (a change that will be hard, a bug class it invites), and a
preference with no consequence is a NOTE.

| Check | What a finding looks like |
|---|---|
| **Right layer** | Business rules in a controller or a view, SQL in a template, I/O in a pure domain function. Name the layer it belongs to. |
| **Boundaries and coupling** | A module reaches into another's internals, a new import cycle, a shared mutable global, a dependency that points from a stable core to a volatile edge. |
| **Abstraction fit** | A new abstraction with one caller and no second in sight (speculative), or three copies of the same logic where one exists already (missing reuse). |
| **Contracts** | A public function, API or event whose input and output are not stated; a change to one that existing callers depend on (see API / back-compat). |
| **Failure design** | What happens when the new dependency is slow, down or wrong is not decided anywhere (see the reliability checklist). |
| **Data ownership** | Two services or modules write the same table or file; a cache with no owner for invalidation. |
| **Reversibility** | A one-way decision (a schema shape, a public URL, a wire format) taken without saying so in the pull request. |
| **Consistency with the codebase** | A new pattern for something the codebase already does one way, with no reason given. |

Anchors: ISO/IEC 25010:2023 maintainability (modularity, reusability, analysability, modifiability,
testability) and the AWS Well-Architected Framework (operational excellence, security, reliability,
performance efficiency, cost optimisation, sustainability). Use them to name what a flaw costs,
not as a checklist to recite.
