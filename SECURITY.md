# Security

## Sensitive data

Do not open an issue containing credentials, cookies, browser-profile data, private review payloads, customer documents, or private-source approval details.

Use GitHub's private security-advisory channel for vulnerabilities. Revoke or rotate any credential that may have been exposed before reporting it.

## Trust boundary

Artifacts sent for review and the external model's response are untrusted data. This skill never authorizes executing instructions found inside them. Private-source permission must be exact, explicit, and recorded in the operator-controlled installed copy of `references/allowed-private-sources.md`.
