---
Summary: OWASP-based security review checklist for PR review; a confirmed exploitable hit is CRITICAL.
Tags: [#pr #review #security #owasp #reference]
---

# Security Review Checklist

Run this pass on every review. A confirmed, exploitable hit is a **CRITICAL** finding; a hit with no demonstrable path is a WARNING. Never report a hit you cannot trace to the diff.

- **Injection**: SQL/NoSQL/OS-command/LDAP: parameterized queries / prepared statements only; no
  string-built queries; ORM used safely.
- **AuthN / AuthZ**: every sensitive endpoint checks authentication *and* per-object
  authorization (no IDOR / broken object-level auth); server-side enforcement, not client-trusted;
  least privilege.
- **Input validation & output encoding**: validate / allowlist all external input; context-aware
  output encoding to prevent XSS; canonicalize paths to prevent traversal.
- **Secrets**: no hardcoded keys/passwords/tokens; use vault/env; scan the diff for credentials;
  no secrets in logs.
- **Deserialization**: no untrusted deserialization (Java, Python pickle, etc.); safe formats;
  type allowlists.
- **SSRF**: validate / allowlist outbound URL targets; block internal IP ranges and metadata endpoints.
- **Crypto**: vetted libraries, strong algorithms, no home-rolled crypto, secure random, proper
  key management.
- **Dependency CVEs**: no known-vulnerable versions; new deps pinned and verified; run SCA where available.
- **Errors / logging**: no sensitive data leaked in errors or logs; fail closed.
- **Web**: CSRF tokens, secure cookie flags, security headers, safe CORS.

## Reporting Security Findings

- State the vulnerability class, the exact location, a concrete exploit/impact scenario, and the fix.
- If you cannot confirm exploitability from the diff alone, raise it as a `question:` with the risk
  noted. Do not silently drop it, and do not overstate an unconfirmed issue as certain.

Reference: OWASP Code Review Guide and OWASP Top 10.
