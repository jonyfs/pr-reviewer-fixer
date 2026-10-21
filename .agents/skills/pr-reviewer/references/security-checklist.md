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

## Mechanical Floor: Committed Credentials

`scripts/review-cycle.sh screen --diff <base> <head>` screens the added lines of the pull request for
tokens and private keys (GitHub, AWS, Slack, Stripe, Google, npm, GitLab, JWT, `sk-` keys, bearer
headers, PEM private key blocks) and prints one `path:line kind` per hit, never the value. The loop
runs it before dispatching the review and hands the hits over; a review run without the loop runs
it itself.

Each hit is a **mandatory CRITICAL** finding, whatever any agent thinks of it:

- `dimension: security`, `file:` and `line:` from the hit, claim `credential committed (<kind>)`;
- the value is written `[REDACTED]` in the report, never copied;
- the scenario is the standard one: anyone who can read the repository or its history can use the
  credential, and removing the line in a later commit does not remove it from history;
- the fix: remove it from the change, rotate the credential, and read it from the environment or a
  secret store. A test that needs a token-shaped value builds it at run time.

A hit is not downgraded and not dropped in self-verification. If the screen did not run (exit 2),
the coverage note says so.

## Reporting Security Findings

- State the vulnerability class, the exact location, a concrete exploit/impact scenario, and the fix.
- If you cannot confirm exploitability from the diff alone, raise it as a `question:` with the risk
  noted. Do not silently drop it, and do not overstate an unconfirmed issue as certain.

Reference: OWASP Code Review Guide and OWASP Top 10.
