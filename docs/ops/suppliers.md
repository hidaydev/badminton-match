# Suppliers

Every external service the product depends on, what it receives, and how the
product leaves it. The access-holder list is in `operations.md`; this is the
service list. Adding a service means adding a row here.

| Service | Purpose | Data it receives | Region | Contract | Owner | Exit path |
|---|---|---|---|---|---|---|
| Vercel | serves the SPA and rewrites `/api` | the built client bundle, request metadata and the SPA's origin IPs; the OIDC callback arrives here | global edge | free/hobby terms, no DPA signed | repo owner | build the client with `pnpm build:web`, serve `ops/caddy/site-web-fallback.caddy` from the VPS, add the fallback hostname to the Google client |
| GitHub | repository, Actions, release tags and the commit history | the source, CI logs, the SSH public signing key | US | free plan terms, DPA on request | repo owner | mirror the repository to another forge, recreate the Actions environment; tags and release notes travel with a `git clone --mirror` |
| GHCR | release image registry | the release images | US | same GitHub terms | repo owner | re-tag `:local` from a locally built image and keep `:prev`; the release workflow pushes elsewhere |
| Google (OIDC) | login only | the person's Google sub, email, name and picture; the redirect URI | global | Google API terms, no DPA signed | repo owner | a second OIDC provider needs a new client and `OIDC_*` values in `env/majadu-prod.env`; there is no local-password fallback |
| VPS provider (Qouver) | host for the API, PostgreSQL, Caddy and the RC instance | all production data at rest, including the database and the logs | provider region | provider terms | repo owner | restore the latest dump from the backup directory onto another host and move the DNS record |
| Alert webhook | delivery of `majadu-alert@` and the red-build notification | one sentence per failure: the unit name, the commit and the run URL | endpoint's region | endpoint terms | repo owner | set `MAJADU_ALERT_WEBHOOK` in `env/alert.env` to another endpoint, or leave it unset and read the dead-letter file |
| npm registry | `pnpm install`, `pnpm audit` | package names and versions, no personal data | global | registry terms | repo owner | the lockfile pins every package; a mirror serves the same tarballs |
| Playwright CDN | browser builds for e2e | the pinned revision names | global | project terms | repo owner | the builds are pinned in `deps.lock` and cached; `pnpm exec playwright install` against the pinned revision |

## Known concentration

Vercel is the only entry point for the web client, and the OIDC redirect is
pinned to the Vercel origin. A Vercel outage or an account suspension takes the
whole product offline while the API and the database are healthy.
`ops/caddy/site-web-fallback.caddy` is the prepared second origin; it is not
active until the fallback hostname is added to the Google client and to
`OIDC_REDIRECT_URI`, which is a host step.

## Monitoring a supplier

There is no supplier dashboard. The external uptime checker in
`operations.md` watches the two origins the product is reached through, and a
red check is the same signal a supplier status page would give.
