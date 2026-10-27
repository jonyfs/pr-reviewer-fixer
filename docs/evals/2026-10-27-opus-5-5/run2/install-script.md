## Review: pasted diff rv16 (new package.json with a postinstall setup step)

**Scope:** 1 file, package.json (new, 11 lines); manifest change adding an npm lifecycle script
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=1 note=2
**Head:** unknown (pasted diff)

### Acceptance conditions
1. `npm install` installs the image tools the project needs.
2. The setup step does not execute unverified code fetched from the network at install time.
3. A failure of the setup step fails the install visibly instead of leaving a half-set-up tree.

### Critical findings

**C1. `postinstall` pipes a remote script into `sh` on every install** (package.json:6, security, security-auditor, also seen by saboteur)
- Impact: every `npm install`/`npm ci` on every developer machine and CI runner downloads `https://get.tools.example/setup.sh` and executes it with the installing user's privileges and environment (CI tokens, npm tokens, cloud credentials). The script is unpinned (no version, no checksum, no signature), so whoever controls that host, its DNS or its CDN can change what runs at any time without a change in this repository. This is the `curl | sh` install script the supply-chain check forbids (OWASP A03:2025, CWE-494 download of code without integrity check, CWE-829).
- Failure scenario: get.tools.example is compromised or the domain lapses and is re-registered; the next `npm ci` in CI runs a setup.sh that reads `$NPM_TOKEN`/`$GITHUB_TOKEN` from the environment and posts them out; the job still ends green.
- Fix: remove the network-fetching postinstall. Install the image tools as pinned npm dependencies (e.g. `sharp` at an exact version, resolved through the lockfile), or vendor setup.sh into the repo and run it explicitly (`npm run setup:images`), verifying a pinned SHA-256 of any binary it downloads. If a lifecycle hook must remain, it must run only local, reviewed code.

### Warnings (declared debt)

**W1. Download failure is swallowed; a truncated download is executed** (package.json:6, reliability, saboteur; owner: author)
- `curl -fsSL ... | sh` runs without `pipefail`: when curl fails (`-f` on a 404/500, DNS failure, offline install) sh reads an empty script and exits 0, so `npm install` reports success with no image tools. A connection dropped mid-transfer feeds sh a partial script, which runs whatever prefix arrived. It also hard-requires `curl` and a POSIX `sh`, so installs on Windows shells fail.
- Fix: subsumed by C1's fix; if any scripted step stays, download to a file, verify its checksum, then run it, and fail on any non-zero step.

### Notes (declared debt)

**N1. question: no lockfile in the diff** (package.json:8, dependencies, new-hire; owner: author; confidence 0.5)
- package.json is a new file and no package-lock.json / yarn.lock / pnpm-lock.yaml appears beside it. `react` is pinned exactly, but its transitive tree is not. Commit the lockfile with the manifest, unless the repository already holds one this pasted diff does not show.

**N2. Package is not marked private** (package.json:2, dependencies, architect; owner: author)
- An app package named `web` without `"private": true` can be published by an accidental `npm publish`, and if published, its postinstall would run on every consumer's machine too. Add `"private": true`.

### Coverage note
- Target: pasted diff. Unavailable: repository code, project rules (AGENTS.md/CLAUDE.md at base not read), history, tests, CI results, existing lockfile. N1 is a question for that reason.
- `screen --diff` not run (no repository commits for a pasted diff); manual read found no credential in the added lines. `scan-hidden.py --file` over the diff and description: 0 hits.
- Path floor (`path-floor.sh --files`, package.json): dependencies at standard, run. The security dimension was also run at max because the change adds an install-time code execution hook.
- Dimensions not applicable: data and migrations, privacy, scalability, UI, API design.
- Agents: single reviewer session, stances saboteur, new-hire, security-auditor, architect applied in sequence; no sub-agent dispatch.
- Declined to judge: none.

### Summary
The change makes every install execute an unpinned remote shell script, a direct supply-chain and credential-exfiltration risk on developer machines and CI, and it fails silently when the download breaks. Replace the `curl | sh` postinstall with pinned npm dependencies or a vendored, checksum-verified script run on demand.

```findings
version: 1
pr: 0
head: unknown
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 1, note: 2}
mandatory_units:
  - {unit: dependencies, effort: standard, status: run}
acceptance:
  - {id: A1, text: "npm install installs the image tools the project needs", status: open}
  - {id: A2, text: "The setup step does not execute unverified code fetched from the network at install time", status: open}
  - {id: A3, text: "A failure of the setup step fails the install visibly", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: package.json
    line: 6
    dimension: security
    stance: security-auditor
    claim: "postinstall pipes an unpinned remote script (curl https://get.tools.example/setup.sh | sh) into sh on every npm install"
    failure_scenario: "get.tools.example is compromised or re-registered; the next npm ci in CI runs a setup.sh that exfiltrates NPM_TOKEN/GITHUB_TOKEN from the environment while the job stays green"
    suggested_fix: "Remove the network postinstall; use pinned npm dependencies for the image tools or a vendored, checksum-verified script run explicitly"
    testable: yes
    confidence: 0.95
    also_seen_by: [saboteur]
    owasp: A03:2025
    cwe: CWE-494
  - id: W1
    severity: WARNING
    file: package.json
    line: 6
    dimension: reliability
    stance: saboteur
    claim: "curl -f failure in a pipe without pipefail is swallowed (sh exits 0 on empty input) and a truncated download is executed partially"
    suggested_fix: "Download to a file, verify checksum, then run; fail on any non-zero step (or drop the step per C1)"
    owner_proposed: "author"
    testable: yes
    confidence: 0.85
  - id: N1
    severity: NOTE
    file: package.json
    line: 8
    dimension: dependencies
    stance: new-hire
    claim: "question: new manifest with no lockfile in the diff; transitive dependencies are unpinned"
    suggested_fix: "Commit package-lock.json alongside package.json"
    owner_proposed: "author"
    testable: no
    confidence: 0.5
  - id: N2
    severity: NOTE
    file: package.json
    line: 2
    dimension: dependencies
    stance: architect
    claim: "App package lacks \"private\": true; an accidental publish would ship the postinstall to consumers"
    suggested_fix: "Add \"private\": true"
    owner_proposed: "author"
    testable: no
    confidence: 0.7
```
