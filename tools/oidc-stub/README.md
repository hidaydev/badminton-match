# OIDC stub (test only)

Local OpenID Connect provider for E2E and CI. It replaces Google only in tests;
the production flow stays Google OIDC.

```
nim c -o:/tmp/oidc-stub tools/oidc-stub/main.nim
OIDC_STUB_PORT=9090 OIDC_STUB_ISSUER=http://127.0.0.1:9090 /tmp/oidc-stub
```

Endpoints:

| Path | Purpose |
|---|---|
| `/.well-known/openid-configuration` | discovery document |
| `/authorize` | redirects to `redirect_uri` with `code` and `state` |
| `/token` | exchanges `code` for an RS256 `id_token` |
| `/jwks` | public key for the API verifier |

`/authorize` only accepts `redirect_uri` hosts `127.0.0.1` and `localhost`, so the
stub cannot be used as an open redirect. The code carries the claims (sub, email,
nonce) base64url-encoded; replay protection is deliberately absent because this is
a test double.

`test_key.pem` is a **public test key**, not a secret. Never trust it outside
tests; the API must pin the real Google JWKS in production.
