# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 2.x | Yes |
| 1.x | No |

The current release line is 2.x. Version 1.x is unsupported and receives no
fixes.

## Reporting a vulnerability

Report vulnerabilities through GitHub private security advisories:

https://github.com/hidaydev/badminton-match/security/advisories/new

Do not open a public issue for a vulnerability. A public report exposes the
problem before a fix exists, including for self-hosted deployments that cannot
be patched quickly.

Reports are handled on a best-effort basis by the maintainers. There is no
guaranteed response time or fix deadline.

## What to include

* The affected endpoint or component, and the version or commit you tested.
* Steps to reproduce, with the smallest request or sequence that triggers it.
* The impact you observed, and what an attacker could do with it.
* Any relevant configuration, such as self-hosted or another deployment, and
  whether the database is reachable from the attacker's position.

Redact secrets, session cookies, ops tokens, and personal data from logs and
screenshots.

## What happens next

The maintainers review the report, confirm whether it is reproducible, and work
on a fix. If the report is accepted, the fix is prepared privately and released
with an advisory that describes the issue after a patched version is available.
Credit is given in the advisory unless you ask otherwise.

## Scope notes

These are properties of the current codebase, not guarantees about a specific
deployment:

* Session cookies are `HttpOnly` and `SameSite=Lax`; browser JavaScript cannot
  read them.
* State-changing requests are checked against the `Origin` allowlist before they
  are routed.
* Ops CLI bearer tokens are stored hashed; the plaintext is shown once at issue
  time.
* Secrets and environment files live only on the server. The repository contains
  templates with no real values.

No third-party security audit, bug bounty program, or certification is claimed.
