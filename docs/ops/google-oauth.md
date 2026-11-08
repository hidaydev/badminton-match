# Google OAuth (OIDC)

This page answers the one thing that must not need looking up when login is
broken: which Google client is used, what callback URL is registered, where the
secret is, and what to do on rotation or revocation.

Status: the login code exists (`modules/account/infrastructure/oidc.nim` and
`apps/api/src/app.nim` → `/auth/start`, `/auth/callback`), but it has **never
been tried with a real Google client**. Treat it as untested until there is a
login test on the production origin (§6).

## 1. What the process reads

| Variable | Required | Default | Used for |
|---|---|---|---|
| `OIDC_CLIENT_ID` | yes | none | `client_id` in the authorize and token request |
| `OIDC_CLIENT_SECRET` | yes for a web client | none | `client_secret` in the token request; a Google client of type *Web application* rejects the exchange without it |
| `OIDC_REDIRECT_URI` | yes | none | `redirect_uri` in both requests; must match exactly what is registered in Google |
| `OIDC_AUTHORIZE_URL` | no | `https://accounts.google.com/o/oauth2/v2/auth` | consent page |
| `OIDC_TOKEN_URL` | no | `https://oauth2.googleapis.com/token` | `code` → `id_token` exchange |
| `OIDC_JWKS_URL` | no | `https://www.googleapis.com/oauth2/v3/certs` | `id_token` signature verification (1 hour cache) |
| `OIDC_ISSUER` | no | `https://accounts.google.com` | `iss` check |

The process refuses to start if `OIDC_CLIENT_ID` or `OIDC_REDIRECT_URI` is empty
(`oidc.nim:31-32`), so a misconfiguration shows up as a unit that fails to
start, not as a 500 at login.

The production values are in `/srv/qouver/apps/majadu/env/majadu-prod.env`
(symlink to `.v1` or `.v2`, mode 600). The repo template only contains
`CHANGE_ME`. The flow TTL is stored in the registry (`auth.flow_ttl_minutes`,
seed default 10, range 1–60), not in env.

Build note: the https path needs a binary built with `-d:ssl`; without it the
code exchange throws `https OIDC requires a build with -d:ssl`
(`oidc.nim:40-51`). The image now passes that flag along with `libssl-dev` in
the build stage (`apps/api/Dockerfile`), and the local `./task build` still has
no ssl because dev uses an http stub. What is **not yet proven**: a real
exchange with Google (§6).

## 2. The redirect URI must be on the SPA origin

The correct `OIDC_REDIRECT_URI` is `<spa-origin>/api/auth/callback`, for
production:

```
https://majadu.vercel.app/api/auth/callback
```

Not `https://api.qouver.com/auth/callback`. The reasons stack up:

1. **Route.** Caddy only forwards `/majadu/*`
   (`ops/caddy/site-v2.caddy`); `https://api.qouver.com/auth/callback` matches
   no handler in the `api.qouver.com` site.
2. **Cookie.** The `/auth/start` response sets `majadu_auth_flow` (state hash,
   `Path=/`, `HttpOnly`, `SameSite=Lax`, a session cookie with no `Max-Age`), and
   `/auth/callback` rejects the request if that cookie does not come along.
   A cookie without `Domain` is only sent to the host that set it. The browser
   starts the flow from `<origin>/api/auth/start`, so the callback **must**
   return to the same origin; any other host means that cookie is never sent and
   every login ends in `400 INVALID_STATE`.
3. **First-party session.** `vercel.json` rewrites `/api/:path*` to
   `https://api.qouver.com/majadu/:path*`, so over HTTP the browser still talks
   to its own origin (ADR-021). Session cookies and the flow cookie stay
   first-party; that is what makes `SameSite=Lax` sufficient.

The consequence: changing the web origin (new domain, staging alias) means
updating **two** places at once, the redirect URI list in Google and
`OIDC_REDIRECT_URI` in env. Vercel preview deployments must not be registered:
their host changes on every deploy and the cookie will not match.

## 3. Creating a client

In the Google Cloud Console, in the project in use:

1. **OAuth consent screen**: type External, scopes `openid`, `email`, `profile`.
   Add the `platform_owner` account as a test user while the application is not
   yet published.
2. **Credentials → Create credentials → OAuth client ID**.
3. **Authorized redirect URIs**: exactly the `OIDC_REDIRECT_URI` value
   (`https://majadu.vercel.app/api/auth/callback`). Authorized
   JavaScript origins are not needed: this flow is server-side, the browser does
   not call Google endpoints with JavaScript.
4. Copy the client ID **and client secret** into env, `chmod 600`, restart the
   unit.

**The client secret is mandatory for a *Web application* client.** `loadOidcConfig`
reads `OIDC_CLIENT_SECRET` (`oidc.nim:31`), and `tokenRequestBody`
adds `client_secret` to the token request as long as its value is not empty
(`oidc.nim:76-77`). Google rejects the `code` exchange from a confidential client
without that parameter (`invalid_request` / `client_secret is missing`), so fill
in the secret together with the client ID before testing login. Leave it empty
only if you deliberately use a public client. Test on the production origin
before considering login live.

## 4. Verification after configuration

```sh
systemctl --user restart majadu-api
curl -fsS http://127.0.0.1:8080/readyz
curl -s -X POST http://127.0.0.1:8080/auth/start \
  -H 'content-type: application/json' -d '{"returnTo":"/"}'
```

Then in the browser, from the web origin: press login, complete consent, and
make sure you return to the start page with an active session. What you should
see:

| Symptom | Meaning |
|---|---|
| `400 INVALID_STATE`, "flow not found, expired or already used" | the flow cookie is missing or foreign, the flow expired, or the callback was repeated |
| `400 TOKEN_EXCHANGE_FAILED` | `redirect_uri` does not exactly match the registered one, or the client secret (see §3) |
| `401 INVALID_ID_TOKEN` | `aud`/`iss`/`exp` do not match, or the binary lacks `-d:ssl` |
| `401 NONCE_MISMATCH` | the `nonce` in `id_token` does not belong to this flow |
| `403 ACCOUNT_ANONYMIZED` | this account has already been anonymized; login is deliberately refused |
| `500 KEY_ERROR` | `SHARE_CODE_KEYS` does not contain the key used when the flow started (the key was rotated mid-flow) |

Check the leftover flows (must go back to 0 after login):

```sql
select count(*), min(expires_at) from auth.oauth_flows;
```

Expired rows are not cleaned up by a timer; such a row just fails to match at
callback and can be deleted by hand with `delete from auth.oauth_flows where
expires_at < now()`.

## 5. Rotation and revocation

- **Replace the client** (suspected leak, or moving project): create a new client →
  register the same redirect URI → change `OIDC_CLIENT_ID` in env (600) →
  restart → test login → only then delete the old client in the console.
- **Revoke access immediately**: delete the client in the Google Cloud Console.
  All new logins fail; sessions already issued stay alive until they expire. To
  cut sessions as well, revoke the sessions in the database (`auth.sessions`)
  through the `account` tool, not manual SQL.
- **Deleting a user's Google account** does not delete the `platform.user` row
  (the subject is stored as a hash). The next login is only refused after the
  account is anonymized through `tools/accountlifecycle`.
- Rotating `SHARE_CODE_KEYS` mid-flow makes the callback fail with `500
  KEY_ERROR`; schedule it outside login hours.

## 6. What is not yet proven

- There is no real Google client yet; the whole symptom table above comes from
  the code, not from an experiment.
- The `Set-Cookie` behaviour through the Vercel rewrite must be tested on a
  staging alias registered as a redirect URI, not a random preview.
- `client_secret` and `-d:ssl` are done: the secret is sent
  (`oidc.nim:76-77`) and the image is built with `-d:ssl`
  (`apps/api/Dockerfile:27`). The only unproven items are the two above.