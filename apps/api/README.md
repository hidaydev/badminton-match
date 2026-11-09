# apps/api: Majadu API (Nim)

The Majadu v2 backend. Replaces the Go v1 server; the decisions and their
consequences are in `docs/decisions.md`. The HTTP contract is
[`packages/contracts/openapi/`](../../packages/contracts/openapi/README.md),
not a separate document in this folder.

## Stack

- Nim 2.4.0, `mummy` as the HTTP server (thread pool, WebSocket)
- PostgreSQL 18, one schema per domain (`platform`, `community`, `player`, `session`,
  `tournament`, `rating`, `achievement`, `auth`, `account`); role `bm2_app` for
  runtime, `bm2_owner` for migrations, `bm2_etl` for ETL
- A single `HttpOnly` session cookie; no tokens on the client
- Routes are generated from the contract (`routes_gen.nim`); handlers are verified at compile time

## Structure

```
src/main.nim            # entrypoint: read env, open db, install handlers
src/server.nim          # process contract (port, drain, timeout), no hidden defaults
src/app.nim             # route dispatch, handlers, audit
src/routes_gen.nim      # GENERATED from the contract; do not edit
src/auth_middleware.nim # 401/403/404 per the role matrix
src/community_context.nim
src/security_headers.nim
src/live.nim            # WebSocket hub for sessions & share
src/ratelimit.nim
tests/                  # unit + integration + security
```

Domain modules live in [`modules/`](../../modules), shared libraries in
[`shared/platform-lib/`](../../shared/platform-lib), migrations and seeds in
[`db/`](../../db).

## Environment

No defaults for anything that determines behavior: the process refuses to start
if any required value is missing.

| Variable | Required | Description |
|---|---|---|
| `MAJADU_PG_DSN` | yes | Postgres DSN |
| `MAJADU_PORT` | yes | listen port |
| `MAJADU_DRAIN_MS` | yes | drain window on SIGTERM (0 allowed) |
| `MAJADU_SHUTDOWN_TIMEOUT_MS` | no | hard shutdown limit, default 30000 |
| `OIDC_{AUTHORIZE_URL,TOKEN_URL,JWKS_URL,ISSUER,CLIENT_ID,REDIRECT_URI}` | yes | identity provider |
| `SHARE_CODE_KEYS`, `SHARE_CODE_ACTIVE_KEY_ID` | yes | share link keyring |
| `MAJADU_BOOTSTRAP_OWNER_EMAIL` | no | first platform owner |
| `CUTOVER_SNAPSHOT_SHA256` | no | expected snapshot; `/readyz` rejects any other |

`MAJADU_TEST_ROUTES=1` is only for the suite, not for deployment.

## Running

```sh
./task dev            # API :8080 + OIDC stub :19090, migration + seed bm2_dev
./task dev --watch    # same, rebuild + restart when a .nim file changes
./task build          # release binary in .cache/<worktree>/bin/majadu-api
./task test           # requires MAJADU_PG_DSN
```

Health: `GET /healthz` is up as long as the process is alive; `GET /readyz`
checks the database, the schema, and the snapshot, and replies `503` if any of
them is not ready.

## Contract

```sh
./task contract-gen     # rewrite routes_gen.nim, TS client, fingerprint
./task contract-check   # fails if the spec and the generated output differ
```

`packages/contracts/openapi/{core,community}.yaml` are the source: **75 operations**
(see `CONTRACT.sha256`). Every generated route must have a handler; compilation
fails if one is missing.

## Gate

```sh
./task check            # nim check, unit tests, archcheck (no database)
./task test             # + integration (requires MAJADU_PG_DSN)
./task coverage         # lines per module, ratchet against coverage-baseline-<platform>.json
./task parity verify    # frozen v1 corpus (71 cases, 48 routes)
```

Migrations: 33 files (`db/migrations/0001`–`0033`). Business config: 34 keys in
`modules/platform/config/registry.nim`.

## v1 has been removed

The Go v1 source (`cmd/`, `internal/`, `api/openapi.yaml`, `go.mod`, `go.sum`,
`Makefile`) was removed in T-082, after the `localhost/majadu-api:v1-final` image
became the rollback path. The consequence: v1 can no longer be hotfixed from
source during the 30-day image retention period; fixes go into v2, or rollback
uses the image as is. The source can still be retrieved from git history before
T-082.

The frozen v1 contract is in `testdata/parity/v1/` (see its README) and does not
need the Go source.