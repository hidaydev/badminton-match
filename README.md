# Majadu

Run a badminton club from one screen: sessions, scores, tournaments, and rank points.

## What this is

Majadu is a mobile-first, multi-community progressive web app for recreational and club badminton.
It handles the whole life of a badminton community: planning match nights, allocating courts,
recording scores with optimistic concurrency, running knockout and team tournaments, and computing
rolling 12-week rank points.

The backend is written in Nim (`apps/api`, `modules/`, `shared/platform-lib`) and the web client is
React 19 with Vite and Tailwind CSS 4 (`apps/web`), plus a courtside scoring kiosk (`apps/scoreboard`).
All three live in one pnpm workspace behind a single task runner, `./task`.

What it does not do: it is not a general tournament platform or a booking system for venues. It
assumes one deployment serves several clubs, each with slugged routes, its own settings, and its own
members.

## Status

Version `VERSION` at the root is the current release line, 2.x. Version 1.x is unsupported.

Shipped and in production: sessions and courts, tournaments (classic draws and team tournaments),
ratings, achievements, player management with claim and merge, multi-tenancy, sealed share links,
the social canvas, and live updates over WebSocket with an HTTP fallback.

The contract is 76 operations across an OpenAPI definition, backed by 61 migrations on PostgreSQL
keyed and scoped by `community_id`. Production runs PostgreSQL 19.0; CI and local dev pin the
`postgres:18.6` image, and every migration is exercised there. `./task docs-check` fails the build
when a document quotes a different number.

## Architecture

Majadu follows clean architecture with strict boundary enforcement.

```text
 Client layer (PWA)          React 19, TypeScript, Tailwind CSS 4, Vite 8
 Delivery and API layer      Nim 2.4, Mummy HTTP and WebSocket server
 Domain core                 9 pure modules: rules, entities, invariants
 Shared platform library     DB binder, clock, logger, metrics, UUIDv7
 Data layer                  PostgreSQL 19 in production, 18.6 in CI and dev
```

- Domain isolation: modules under `modules/<domain>/` hold business logic and database access, and
  never import HTTP, React or delivery concerns. `tools/archcheck` enforces that continuously.
- Contract driven: `packages/contracts/openapi` is the single source of truth. Generated routes
  (`routes_gen.nim`) and client interfaces (`packages/web-client/src/api.ts`) come from
  `./task contract-gen`.
- No hardcoded configuration: business numbers, limits and scoring parameters live in
  `platform.config` and `community.settings`.

| Part | Language | Version |
|---|---|---|
| API | Nim (Mummy) | 2.4 |
| Web and scoreboard | React + TypeScript | React 19, Vite, Tailwind 4 |
| Database | PostgreSQL | 18 |
| Migrations | SQL | 56, append-only |

## Repository layout

```text
apps/web/                  Primary React PWA (Vite, Tailwind 4)
apps/scoreboard/           Courtside scoring kiosk PWA
apps/api/                  Nim API server
modules/                   Domain logic: account, community, player, session,
                           tournament, rating, achievement, share, platform
shared/platform-lib/       Core primitives: db, clock, log, metrics, uuidv7
packages/contracts/openapi/  OpenAPI definitions (core.yaml + community.yaml)
packages/web-client/       Generated TypeScript API client
db/                        56 append-only migrations, seeds, platform config
ops/                       Podman quadlet, Caddy, backup, restore
tools/                     dbtools, contract-gen, archcheck, parity, release
e2e/                       Playwright suites (a11y, visual, multi-browser)
testdata/                  Parity corpora (v1 golden, v2 live)
docs/                      Architecture, data model, runbooks, design system
task                       Single project dispatcher (`./task help`)
```

## Local development

### Prerequisites

| Tool | Version | Source |
|---|---|---|
| Nim | 2.4.0 | `deps.lock`, `.github/workflows/ci.yml` |
| PostgreSQL | 18.6 | CI and dev pin `postgres:18.6`; production runs 19.0 |
| Node.js | 26 | `.github/workflows/ci.yml` |
| pnpm | 12.17.0 | `packageManager` in `package.json` |

Nim packages are installed into `~/.nimble/pkgs2` and checked against `deps.lock` by
`./task deps-check`.

### Quickstart

```sh
pnpm install                       # workspace dependencies
./task dev-db                      # create bm2_dev, bm2_template and the bm2 roles
export MAJADU_PG_DSN="postgresql://$USER@127.0.0.1:5432/bm2_dev"
./task bootstrap --sub stub-user-1 --email stub@example.com
./task dev                         # API on http://127.0.0.1:8080, --watch for hot rebuild
pnpm dev                           # web on http://localhost:5173
```

`./task dev-db` needs a Postgres client: the host `psql` when one is installed, otherwise
`docker exec` into the `pg18` container. Set `MAJADU_DB_CLIENT=host|docker` to pick one
explicitly, and `MAJADU_PG_CONTAINER` / `MAJADU_PG_SUPERUSER` when the container is not
`pg18` or its superuser is not `postgres`. It writes the generated development role passwords to
`.env.local`, which is gitignored.

## Configuration

The API reads `MAJADU_*` variables: `MAJADU_ENV`, `MAJADU_PORT`, `MAJADU_PG_DSN`,
`MAJADU_METRICS_PORT`, the DB timeouts, `MAJADU_TRUSTED_PROXIES`, `PUBLIC_BASE_URL`,
`CORS_ALLOWED_ORIGINS`, the `SHARE_CODE_KEYS` map plus `SHARE_CODE_ACTIVE_KEY_ID`, and the
`OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` / `OIDC_REDIRECT_URI` trio. The complete list with defaults is
in [`ops/env/prod.env.example`](ops/env/prod.env.example) and the RC variant beside it; the web client
takes one variable, `VITE_API_BASE` ([`apps/web/.env.local.example`](apps/web/.env.local.example)).

Every value in those files marked `CHANGE_ME` is a secret and belongs only in the deployment
environment. Nothing in this repository carries a real credential.

## Quality gates

All validation runs through the single `./task` dispatcher.

| Command | Guards |
|---|---|
| `./task check` | `nim check`, architectural boundary check (`archcheck`), and the database-free unit suites |
| `./task test` | integration tests against isolated PostgreSQL databases (`--timing`, `WORKERS=N` to shard) |
| `./task ci` | composite gate: linting, contract parity, builds and integration tests |
| `./task coverage` | per-module line coverage, ratcheted against the committed baseline JSON |
| `./task docs-check` | documentation counts (61 migrations, 76 operations), link and path integrity, release order, pinned tool versions, design-system review age |
| `./task parity v2 verify` | golden contract replay: 144 fixtures against the frozen and live corpora |
| `./task e2e` | multi-browser end-to-end (iPhone 17 WebKit, POCO F5 Chromium, desktop, WebSocket) |
| `pnpm check:web` | TypeScript, ESLint, Tailwind token validation, Vitest coverage |

CI runs the same targets; `docs-check` is part of the CI chain, so a stale count fails the build.

## Deployment

- Web: deployed automatically to Vercel from `apps/web` on pushes to `main`.
- API: rootless Podman with a systemd quadlet on the VPS, behind Caddy.
- Image provenance: every release image is pulled by digest and verified against `env/cosign.pub`
  before the `:local` container is swapped.
- Rollback: the previous image is kept as `:prev`, so a failed smoke check falls back instantly.

A release follows `./task release`, then a signed tag, then the tag pushed before `main`: the tag
builds and signs the image, `main` triggers the deploy webhook that polls for it. The full runbook,
including the order and why it matters, is [`docs/ops/release.md`](docs/ops/release.md).

## Documentation

[`docs/README.md`](docs/README.md) is the index. The documents a reader lands on first:

- [`docs/handbook/current-status.md`](docs/handbook/current-status.md): operational stack, contracts, gates, infrastructure.
- [`docs/handbook/architecture.md`](docs/handbook/architecture.md): layers, execution pipeline, module boundaries.
- [`docs/handbook/data-model.md`](docs/handbook/data-model.md): schemas, multi-tenancy, platform config registry.
- [`docs/handbook/features-and-routes.md`](docs/handbook/features-and-routes.md): frontend routes and the 76 API operations.
- [`docs/ops/operations.md`](docs/ops/operations.md): production operations, log rotation, access, incident SOPs.
- [`docs/ops/release.md`](docs/ops/release.md): release runbook, gate criteria, rollback.
- [`docs/decisions.md`](docs/decisions.md): architecture decision records.

## Security

Do not open a public issue for a vulnerability. Reporting channel, what to include and what is in
scope are in [`SECURITY.md`](SECURITY.md); GitHub private vulnerability reporting is the channel it
names.

## Contributing

Fork, branch, pull request against `main`; large changes start as an issue. Build steps, the branch
and commit convention, and what a change must pass before review are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

Code and original graphics in `apps/web/public` are MIT; see [`LICENSE`](LICENSE). Third-party fonts
and assets keep their own licenses, listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
