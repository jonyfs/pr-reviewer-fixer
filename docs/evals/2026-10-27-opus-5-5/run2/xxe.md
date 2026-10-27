## Review: pasted diff, new src/imports/xml_reader.py

**Scope:** 1 file, 12 added lines, new feature (XML invoice upload parsing, internal config parsing)
**Pass:** 1
**Verdict:** BLOCKED
**Counts:** critical=1 warning=1 note=1
**Head:** none (pasted diff)

### Acceptance conditions
1. `read_upload` parses a well-formed customer XML invoice and returns its root element.
2. `read_upload` never resolves external entities, never fetches network or local resources named in a DTD, and does not expand entity bombs from customer input.
3. `read_config` parses the internal XML config file.
4. Tests cover both functions, including a hostile upload.

### Critical findings
**C1 - XXE and SSRF on customer uploads** (`src/imports/xml_reader.py:3`, used at line 8)
- Dimension: security (OWASP A02:2025, CWE-611). Stance: security-auditor; also seen by saboteur.
- Impact: `UPLOAD_PARSER` is built with `resolve_entities=True, no_network=False`, and `read_upload` feeds it customer-supplied bytes. The parsers are swapped: the trusted config file gets the hardened parser, the untrusted upload gets the permissive one.
- Failure scenario: a customer uploads `<!DOCTYPE i [<!ENTITY x SYSTEM "file:///etc/passwd">]><invoice>&x;</invoice>`; the returned tree contains the server's `/etc/passwd`, which flows into whatever the importer stores or echoes. With `SYSTEM "http://169.254.169.254/latest/meta-data/iam/security-credentials/"` the server issues the request (SSRF, cloud credential theft).
- Fix: build the upload parser as `etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False, dtd_validation=False, huge_tree=False)` (or use `defusedxml.lxml`), and reject documents with a DOCTYPE. Add a test that the payload above does not expand.

### Warnings (declared debt)
**W1 - No tests for new parsing code** (`src/imports/xml_reader.py:7`). Dimension: testing. Stance: new-hire. Neither function has a test, and the security property of `read_upload` is exactly the kind that regresses silently. Proposed owner: author.

### Notes (declared debt)
**N1 - assumption: config path is trusted** (`src/imports/xml_reader.py:11`). Stance: architect. `read_config` is safe only if `path` never comes from a request. Nothing in the diff shows callers; if it ever does, `etree.parse` also accepts URLs. Proposed owner: author.

### Coverage note
Target is a pasted diff: no repository code, callers, project rules, history, tests or CI were available. Project rules were not read (no base commit). `review-cycle.sh screen`, `scan-hidden.py` and `path-floor.sh` were not run (no git refs, no PR); by inspection the diff touches no CI, agent, auth, migration or manifest path, so no floor unit is expected. Dimensions applied: security, correctness, testing, architecture. Not applicable: performance, data/migrations, dependencies (lxml presumed already a dependency; no manifest in diff), UI.
Declined to judge: none.

### Summary
Small change with one severe defect: the untrusted upload path uses an XML parser that resolves external entities and allows network access, giving file disclosure and SSRF to any customer. Swap in a hardened parser for uploads (the config parser already shows the right flags) and add a hostile-input test.

```findings
version: 1
pr: 0
head: none
pass: 1
verdict: BLOCKED
counts: {critical: 1, warning: 1, note: 1}
mandatory_units: []
acceptance:
  - {id: A1, text: "read_upload parses a well-formed customer XML invoice", status: open}
  - {id: A2, text: "read_upload never resolves external entities or fetches network/local resources", status: open}
  - {id: A3, text: "read_config parses the internal XML config", status: open}
  - {id: A4, text: "Tests cover both functions, including a hostile upload", status: open}
findings:
  - id: C1
    severity: CRITICAL
    file: src/imports/xml_reader.py
    line: 3
    dimension: security
    stance: security-auditor
    claim: "Upload parser resolves external entities with network access enabled; customer XML gets XXE and SSRF"
    failure_scenario: "Upload <!DOCTYPE i [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><invoice>&x;</invoice>; read_upload returns a tree containing /etc/passwd"
    suggested_fix: "XMLParser(resolve_entities=False, no_network=True, load_dtd=False) or defusedxml.lxml for uploads; reject DOCTYPE"
    testable: yes
    confidence: 0.95
    also_seen_by: [saboteur]
    owasp: A02:2025
    cwe: CWE-611
  - id: W1
    severity: WARNING
    file: src/imports/xml_reader.py
    line: 7
    dimension: testing
    stance: new-hire
    claim: "No tests for read_upload or read_config, including the hostile-input case"
    suggested_fix: "Add tests: valid invoice parses; external-entity payload does not expand"
    owner_proposed: "author"
    testable: yes
    confidence: 0.8
  - id: N1
    severity: NOTE
    file: src/imports/xml_reader.py
    line: 11
    dimension: architecture
    stance: architect
    claim: "assumption: read_config path is never request-controlled"
    suggested_fix: "Document or enforce that path is a fixed internal location"
    owner_proposed: "author"
    testable: no
    confidence: 0.6
```
