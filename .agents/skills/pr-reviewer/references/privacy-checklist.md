---
Summary: Privacy and data protection checks for a pull request, for LGPD and GDPR: minimisation, purpose, retention, rights and transfers.
Tags: [#pr #review #privacy #lgpd #gdpr #reference]
---

# Privacy and Data Protection Checklist

Run this unit when the change collects, stores, logs, sends or deletes personal data (names, emails,
documents such as CPF, phone numbers, addresses, location, device or online identifiers, health or
financial data), or touches files the path floor marks as privacy paths. The reviewer judges the
code, not legal compliance: a finding names the data, where it goes and the rule it breaks. Personal
data exposed to someone who must not see it is CRITICAL; a missing control with no exposure yet is
a WARNING.

| Check | What a finding looks like |
|---|---|
| **Minimisation** | A new field, log line, event or analytics call that collects more personal data than the feature needs. |
| **Logs and errors** | Personal data or tokens in log lines, error messages, traces or crash reports. |
| **Purpose** | Data collected for one purpose reused for another (marketing, model training) with no consent or legal basis recorded. |
| **Sensitive data** | Health, biometric, religious, ethnic, sexual, political or children's data handled without the stricter controls both LGPD (Art. 11, 14) and GDPR (Art. 9, 8) require. |
| **Retention and deletion** | No retention limit, or a deletion that misses copies (caches, backups, search indexes, third parties). The data subject's right to deletion must reach every store. |
| **Access and portability** | A new store of personal data that the export or access-request path does not read. |
| **Transfers** | Personal data sent to a new third party or another country with no contract or safeguard named in the pull request. |
| **Security of processing** | Personal data unencrypted at rest or in transit, or readable by roles that do not need it. |

Anchors: Brazil's LGPD (Lei 13.709/2018) and the EU GDPR (Regulation 2016/679), privacy by design
and by default (GDPR Art. 25), and ISO/IEC 27701 for a privacy information management system. When
a finding depends on a legal reading, say so and send it to a person.
