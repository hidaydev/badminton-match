# Architecture

This document describes the **v2 runtime**: the Nim backend + React frontend that are in the
repo today. The Go v1 backend has been removed from the tree (T-082); the provenance of the
ported semantics is marked in module docstrings and explained in §12.

## 1. System shape

```text
Browser (React 19 SPA)
   │  same-origin /api  (dev: Vite proxy · prod: Vercel rewrite)
   ▼
apps/api (Nim 2.4, Mummy HTTP + WebSocket)
   │  direct SQL (db_connector, pool)
   ▼
PostgreSQL 18: database bm2, schema per domain
```

- Frontend: React 19, Vite 8, Tailwind 4, React Router 7 (`apps/web/package.json`).
- Backend: Nim `>= 2.4.0 & < 2.5.0`, Mummy 0.4.8, `db_connector` (commit pin), nimcrypto
  (`majadu.nimble`, `deps.lock`).
- Database: PostgreSQL 18; tooling uses the database names `bm2_dev` / `bm2_e2e`
  (`.github/workflows/ci.yml`, `task.d/e2e.sh`). Schema and tables are in
  [`data-model.md`](data-model.md).

There is no PostgREST, Supabase, or SSE in v2. The frontend is indeed a PWA: a service
worker (VitePWA) precaches the app shell, and client state uses TanStack Query
for server data and Zustand for the wizard draft.

## 2. Repo map

| Path | Contents |
|---|---|
| `apps/api/src/` | entrypoint, router, auth, realtime, route config |
| `apps/api/tests/` | HTTP + contract tests (unit; integration in `tests/integration/`) |
| `modules/` | domain + infrastructure per bounded context |
| `shared/platform-lib/` | logger, clock, sha256, uuidv7, metrics, build info |
| `apps/web/src/` | React shell, pages, per-feature API client |
| `packages/contracts/openapi/` | two source specs + combined document + fingerprint |
| `packages/web-client/src/api.ts` | generated TypeScript client |
| `db/migrations/`, `db/seeds/` | schema (`0001`–`0048`) and config seed |
| `tools/` | dbtools, contract-gen, parity, ops CLI, OIDC stub |
| `e2e/` | Playwright suite (a11y, visual, compatibility) |
| `task`, `task.d/` | the only command runner (`./task <target>`) |

Sources: `config.nims:1-8` (module paths), `task:13-34` (target list),
`packages/contracts/openapi/README.md`.

## 3. Boot & process configuration

Entrypoint: `apps/api/src/main.nim`.

1. `loadConfig()` requires `MAJADU_PORT` and `MAJADU_DRAIN_MS`; `MAJADU_SHUTDOWN_TIMEOUT_MS`
   defaults to 30 s (`apps/api/src/server.nim`).
2. `bootHandler` requires `MAJADU_PG_DSN`, loads the OIDC configuration, the share code keyring
   (`SHARE_CODE_KEYS`, `SHARE_CODE_ACTIVE_KEY_ID`), then the config registry from the database
   (`apps/api/src/main.nim`). Missing values make the process refuse to start, rather than
   serve a 500.
3. `newApp()` + `install()` keep a single process-wide `App`; Mummy handlers use the only
   `gcsafe` cast at the boundary (`apps/api/src/app.nim`).
4. The server runs with `max(countProcessors(), 2)` worker threads; SIGTERM/SIGINT
   trigger drain then close (`apps/api/src/main.nim`).

Business configuration is **not** read from env. All numbers live in `platform.config`
with a typed registry in `modules/platform/config/registry.nim`; the snapshot is cached per
`platform.config_version`; when the value changes the cache reloads without a restart
(`modules/platform/config/store.nim:15-80`).

## 4. Request pipeline

`proc route` (`apps/api/src/app.nim`) runs a fixed order:

1. **Body limit**: `security.max_body_bytes` (`apps/api/src/app.nim`). The socket accepts up
   to the registry ceiling for that key (16 MiB), so the guard, never the transport, answers
   an oversized request with the `413 BODY_TOO_LARGE` envelope; a body past the ceiling is
   dropped before any handler can answer (`apps/api/src/security_headers.nim:bodyLimits`).
2. **CSRF**: state-changing methods require an allowed origin (or `Sec-Fetch-Site`
   `same-origin`/`none`); a request with a cookie and no Origin is rejected
   (`apps/api/src/security_headers.nim:22-45`).
3. **Rate limit**: bucket per route template + identity (hash of the session cookie when
   present, otherwise the client address); `/s/{code}` has a per-viewer ceiling and a looser
   ceiling per code (`apps/api/src/app.nim`, `apps/api/src/ratelimit.nim`).
4. **System routes**: `/healthz`, `/readyz` (checks required tables via `to_regclass` and the
   `cutover_state` snapshot), `/version`, `/ops/*`.
5. **Old clients**: `X-API-Version` below the server version is answered with `410 CLIENT_OUTDATED`
   (`apps/api/src/app.nim`).
6. **Auth + authorization**: `majadu_session` cookie (HttpOnly, SameSite=Lax) →
   `currentUser` → `loadCommunity` → `gate` (`apps/api/src/app.nim`,
   `apps/api/src/community_context.nim:15-30`, `apps/api/src/auth_middleware.nim:19-42`).
7. **Dispatch**: branch per prefix: `/c/{slug}/players`, `/sessions`, `/tournaments`,
   `/ratings`, `/members`, `/settings`, `/ws/...`, `/s/...`.

All responses go through `send()` so security headers cannot be missed
(`apps/api/src/app.nim`, `apps/api/src/security_headers.nim:62-75`). Errors use the envelope
`{"status", "code", "detail"}` (`apps/api/src/app.nim`). JSON logs redact share code,
ticket, cookie, email, and IPv4 (`shared/platform-lib/logger.nim:11-32`).

### Roles & data boundaries

- `member` may read; `host`/`admin` may write operational data; `admin`
  manages members, settings, rating, and claims.
- `platformOwner` only passes platform management routes (create community); inside a
  community, the membership role still decides (`modules/account/domain/roles.nim:43-61`).
- A foreign community slug and a non-member both return `404` so community existence does not
  leak (`apps/api/src/community_context.nim:15-22`).
- Every community data query carries `community_id`; there is no cross-community path.

Authoritative matrix per operation: `testdata/authz/matrix.yaml` (generated from the contract and
tested by `apps/api/tests/`).

## 5. API contract & codegen

The contract is hand-written in two JSON-syntax documents:

- `packages/contracts/openapi/core.yaml`
- `packages/contracts/openapi/community.yaml`

`tools/contract-gen` merges them into `api.yaml`, generates
`apps/api/src/routes_gen.nim` + `packages/web-client/src/api.ts`, and writes
`CONTRACT.sha256`. The current operation count is **75** (`CONTRACT.sha256`, line
`operations 75`). `./task contract-check` fails if the spec, the generated output, or the
fingerprint differ.

The contract is not passive documentation: `verifyHandlers` fails at compile time when an
operation has no handler (`verifyHandlers` in `apps/api/src/routes_gen.nim`), and `apps/api/tests/routes_test.nim`
locks the operation count.

Implementation routes that are **not** in the contract (deliberately not promoted):
`GET /ops/ping` (ops bearer token, `apps/api/src/app.nim:1943-1946`) and
`DELETE /c/{slug}/rating-sources/{id}` (admin, used by rating source cleanup).
Treat both as internal; public clients use the operations in the contract.

## 6. Modules & layering rules

```text
modules/
├── account/       # role, audit, lifecycle, OIDC, login sessions, ops token
├── achievement/   # badge catalog + backfill
├── community/     # membership, invite, join request, settings
├── platform/      # config registry, idempotency, janitor, audit retention
├── player/        # player domain, claims, merge, store
├── rating/        # points formula, ingest/revert/rebuild, board reads
├── session/       # session writes, schedule, swap, standings
├── share/         # share code encryption + lookup
└── tournament/    # classic/team domain, draw, store
```

- `domain/` does not touch the database or env; `infrastructure/` owns SQL and
  adapters.
- `tools/archcheck` rejects domain table access from the wrong layer and env reads
  outside the process edge (`tools/archcheck/rules.nim:1-10`); `./task check` runs it.
- Dependencies between modules flow through the domain/store, not through HTTP handlers.

## 7. Database

Database `bm2`, split per schema: `platform`, `community`, `player`, `session`,
`tournament`, `rating`, `achievement`, `auth`, `account` (plus the `dbtools` ledger).
All child tables use a composite FK `(community_id, id)` so one row cannot
cross communities.

Migrations are run by `tools/dbtools` with checksums and a ledger
(`tools/dbtools/main.nim:6-16`); `./task bootstrap` runs migrations, seed, the first
owner, and the default community. Table details are in [`data-model.md`](data-model.md).

## 8. Realtime (WebSocket, not SSE)

- Clients request a **single-use ticket**: `POST /c/{slug}/sessions/{id}/ws-ticket` or
  `POST /s/{code}/ws-ticket`. The ticket is stored as a hash, expires after
  `ws.ticket_ttl_seconds`, and is deleted when used (`apps/api/src/ws_ticket.nim:35-60`,
  `apps/api/src/app.nim:557-588`).
- Upgrade: `GET /ws/c/{slug}/sessions/{id}` or `GET /ws/share/{code}`. Origin is checked
  first; the community URL must match the ticket (`apps/api/src/app.nim:1676-1710`).
- Hub fan-out is **in-memory per process** with per-session, per-IP, and per-process caps from
  the registry (`apps/api/src/live.nim:53-101`).
- Frames sent by the server: `{"type":"ready"}`, `{"type":"session.changed","seq":N}`,
  `{"type":"full"}` when capacity is full, `{"type":"revoked"}`, `{"type":"pong"}`.
  `seq` is only a gap marker, **there is no replay**; a client that needs full state re-reads
  `GET /session` (`apps/api/src/live.nim:33-36`, `apps/api/src/live.nim:142-145`).
- Clients may send `ping`; `subscribe` is accepted but stores no state
  (`apps/api/src/live.nim:166-194`).

Because the hub is in-memory, the API must run as a single instance. This is a deliberate
constraint, not a multi-node feature.

## 9. Session write flow

All schedule mutations use **optimistic concurrency at the session level**:

1. The client sends `If-Match: "<version>"`; without the header → `428`
   (`apps/api/src/app.nim:584-599`).
2. The handler calls the `session` module; `UPDATE ... WHERE version = $n` bumps
   `session.sessions.version` in the same transaction
   (`modules/session/write.nim:63-82`, `modules/session/schedule.nim:190-216`).
3. Version mismatch → `412 STALE_VERSION`; session missing → `404`.
4. After commit, the hub broadcasts `session.changed` with the new version
   (`apps/api/src/app.nim:641`, `apps/api/src/app.nim:678`, `apps/api/src/app.nim:711`).
5. Mutations that supply `Idempotency-Key` store the response in
   `platform.idempotency_keys`; a replay with the same body returns the old response, a
   different body → `409 IDEMPOTENCY_CONFLICT` (`modules/platform/idempotency.nim:23-52`,
   `apps/api/src/app.nim:599-617`).

The schedule is stored relationally in `session.games` (not a JSON snapshot): one row per
`round_no`/`court_no`, with up to two players per side. `PUT .../schedule` only
touches the games it names, so a partial schedule remains valid
(`modules/session/schedule.nim:114-160`). Session lock records `approved_at`/`approved_by`
(`db/migrations/0006_session_approval.sql`).

## 10. Rating & achievement

- Points are computed **at read time** with the v1 rules: one entry per player per source
  (session = the sum of all games; tournament = `champion_points × round_ratio` when the kind
  has an active `rating.levels` row), then the best `best_n` entries in the
  `window_weeks` window are summed and rounded once (`modules/rating/projection.nim`).
- The value of one game = `base * (0.5 + 0.5 * clamp(margin/target, -1, 1))`; opponent multiplier =
  `clamp(average opponent tier / average population, low, high)`, with tier strength =
  the band midpoint (`modules/rating/domain/rating.nim`).
- One game needs players present on both sides; `absent` players are not counted and
  `session.game_skips` removes a player from that game only. The board is anchored on the
  `local_date` of the latest event, not today (`modules/rating/read.nim`).
- The per-game ledger is no longer stored (`0026`); what remains is only the
  played/won/lost counters and `rating.events.point_entries`. Board numbers are never read
  from stored rows.
- All parameters come from the registry: `rating.session_base`, `rating.score_target`,
  `rating.opponent_clamp`, `rating.window_weeks`, `rating.best_n`,
  `rating.thin_evidence_n`, `rating.tier_bands` (`modules/rating/infrastructure/params.nim:5-27`).
- Ingest is idempotent per source (session/tournament): a second run adds no events/entries
  (`modules/rating/infrastructure/ingest.nim:146-171`). Source sign-off is stored in
  `rating.sources`; `DELETE …/rating` rejects a finalized source and a full rebuild
  does not change source rows (`db/migrations/0013_rating_sources.sql`).
- Badges are computed from aggregate facts and the `achievement.definitions` catalog; a key that
  is not in the seed can never be earned (`modules/achievement/domain/achievement.nim:65-100`,
  `db/seeds/achievement_definitions.sql`).

## 11. Frontend shell

- `apps/web/src/main.tsx` creates the root; `App.tsx` mounts `AuthProvider` →
  `BrowserRouter` → `CommunityProvider` → shell. Navigation lives in
  `legacy/components/HomeLayout` (community picker and account menu) and only
  appears after login (`apps/web/src/App.tsx`).
- Routes are defined directly in `App.tsx`. `apps/web/src/routes.manifest.ts`
  only provides `communitySlugFromPath` and `communityHref`, not a route
  list or menu.
- Login uses OIDC through the API; the token never enters JavaScript. All calls
  use the session cookie (`credentials: 'include'`) and the header `X-API-Version: 2`
  (`apps/web/src/auth/api.ts`).
- The browser does not call the domain API directly: dev uses the `/api` proxy in
  `vite.config.ts`, production uses a Vercel rewrite (`apps/web/vercel.json`).
- Server data uses TanStack Query: `useQuery`/`useMutation` with query keys
  per feature prefixed by the community slug (e.g. `[slug, 'session', id]`,
  `[slug, 'rankings', …]`), and the `session.changed` frame invalidates those keys.
  The generator wizard draft stays in Zustand (`apps/web/src/legacy/store`).
- All UI text lives in `apps/web/src/i18n/en.ts`; tests reject hardcoded JSX text
  (`apps/web/README.md`).

## 12. v1 (Go), now removed

The Go v1 source (`apps/api/cmd/`, `apps/api/internal/`, `apps/api/api/`, `go.mod`,
`go.sum`, `Makefile`) was removed in T-082, after the image
`localhost/majadu-api:v1-final` was kept as the rollback path. Consequently
v1 cannot be hotfixed from source during the image retention period; its source exists only in
git history. The frozen v1 contract lives in `testdata/parity/v1/` (cases,
`cases.tsv`, and `routes.txt`) and needs no Go source.

Module docstrings that mention `*.go` are provenance notes ("ported from"),
not files still in the tree. `ops/` already uses the v2 env (`MAJADU_PG_DSN` and
friends in §3); the `/majadu` prefix was kept after cutover, so it is not a
v1 leftover.

## 13. Testing & gates

| Gate | Contents | Needs DB |
|---|---|---|
| `./task check` | `nim check`, unit tests, archcheck | no |
| `./task test` | unit + integration (`INTEGRATION=1`) | yes (`MAJADU_PG_DSN`) |
| `./task verify <module\|api>` | test one module | when integration is present |
| `./task contract-check` | fingerprint + generated output | no |
| `./task coverage` | lines per module, ratchet baseline | yes (integration) |
| `./task parity verify` | frozen v1 corpus + v2 | no / v2: yes |
| `pnpm check:web` | TypeScript, ESLint, Tailwind, Vitest | no |
| `./task e2e` | Playwright: a11y, visual, compatibility | yes (DB `bm2_e2e`) |

CI runs the jobs `api-check`, `api-test` (Postgres 18.6 service), `contract`, `web`,
`e2e`, `image`, then `gate`, which requires every job to succeed
(`.github/workflows/ci.yml`). Coverage has its own workflow
(`.github/workflows/coverage.yml`) so the instrumented build does not share a cache
with the fast gate. E2E uses two real devices: `iphone-17` (WebKit, 402×874,
DPR 3) and `poco-f5` (Chromium, 393×873, DPR 2.75) (`e2e/browsers.ts`).

## 14. Principles

1. **Contract first**: API changes start from the spec, then generate.
2. **Server authoritative**: score, points, authorization, and invariant validation live in Nim.
3. **One rule, one place**: business numbers in the registry, not duplicated in FE/BE.
4. **Community is the data boundary**: every row and query carries `community_id`.
5. **Fail loudly**: missing configuration or a wrong type refuses to start; errors are not swallowed.
