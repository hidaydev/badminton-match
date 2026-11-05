# CLAUDE.md

Guidance for Claude Code when working in this repository. Runtime facts live in
`docs/handbook/current-status.md`; this file is the short version an agent needs
before touching code.

## Commands

Run from the repo root. `./task` is a dispatcher over `task.d/`; `./task help`
lists every target.

```bash
./task check            # format, nim check, archcheck, unit tests (no database)
./task test             # + integration tests (needs MAJADU_PG_DSN)
./task ci               # check + build + test + contract fingerprint
./task coverage         # line coverage per module, ratcheted
./task parity verify    # frozen v1 corpus + v2 corpus
./task e2e              # Playwright a11y/visual/compat
pnpm check:web          # TypeScript, ESLint, Tailwind guard, Vitest
```

Web scripts proxy to `apps/web`: `pnpm dev`, `pnpm build:web`, `pnpm check:web`.

## Architecture

Mobile-first React 19 PWA (`apps/web`) over a Nim 2.4 API (`apps/api`), one
PostgreSQL 18 database. `apps/scoreboard` is a separate courtside PWA.

- **Modules** (`modules/<domain>/`) hold business rules and SQL. `domain/` is pure
  logic and `infrastructure/` holds the SQL stores where a module has more than
  one (`account`, `achievement`, `community`, `rating`); `player`, `session`,
  `share`, and `tournament` keep their stores at the module root, and
  `platform` keeps `config/`. Modules must not import HTTP, React, or `apps/*`.
- **`apps/api/src`** is delivery only: routing, auth middleware, community
  context, WebSocket hub. Routes are generated from the OpenAPI contract.
- **`shared/platform-lib`** holds the DB binder, clock, logger, metrics, uuidv7,
  sha256, and request context.
- **`packages/contracts/openapi`** is the hand-written source; `api.yaml`,
  `routes_gen.nim`, and `packages/web-client/src/api.ts` are generated. Never edit
  generated files; run `./task contract-gen`.
- **`db/migrations`** is append-only (23 files today). Every table carries
  `community_id`; queries must scope by it.
- **Business numbers live in the database** (`platform.config` →
  `community.settings`), never as literals. `tools/archcheck` fails on violations.

## Non-negotiables

- Code, identifiers, comments, commit messages: **English**. Internal docs
  (handbook, ADR, task notes): Indonesian.
- Do not commit, push, rewrite history, or deploy without explicit approval.
- Do not add a dependency without pinning it in `deps.lock` (`./task deps-check`).
- Do not call `db.query`/`db.queryExec` on the same `Db` inside its own `tx`; use
  the closure `conn` (one connection per worker thread).
- Do not invent config defaults in code; register the key and seed it instead.

## Feature map

| Where | What |
|---|---|
| `modules/session` | Courts, schedule, scores, skip, absent, swap, lock, standings |
| `modules/tournament` | Classic draw/bracket and team format |
| `modules/rating` | Rank points, ingest/revert/rebuild, leaderboard reads |
| `modules/achievement` | Badge rules and idempotent backfill |
| `modules/player` | Players, aliases, claims, merge |
| `modules/community` | Slug, membership, invites, join requests, settings |
| `modules/account` | Users, roles, sessions, audit, lifecycle |
| `modules/share` | Sealed share codes and link reads |
| `apps/web/src/pages` | v2-native screens (login, players, settings, setup, shared session) |
| `apps/web/src/legacy` | The v1 screens kept in use: session pages and host panel, tournaments, rankings, share view, plus their queries and store |

## Testing

- Unit tests sit next to code (`*_test.nim`); integration tests need
  `MAJADU_PG_DSN` and `INTEGRATION=1` (set by `./task test`).
- `tools/parity` replays golden captures; the v1 corpus is frozen (the Go server
  is gone), the v2 corpus is live.
- E2E runs on two phones: `iphone-17` (WebKit) and `poco-f5` (Chromium).

## Known limits

- The shared session view consumes the WebSocket (`useSessionRealtime`); the
  session editor still refetches every 5 s. Realtime is in-memory, so the API
  must stay a single instance.
- There is no schedule generator; the contract accepts a schedule authored by the
  client.
- Cutover rehearsal and VPS-side checks are prepared but not executed; see
  `docs/ops/cutover.md`.

## Pointers

`docs/handbook/current-status.md` · `docs/handbook/architecture.md` ·
`docs/handbook/data-model.md` · `docs/handbook/features-and-routes.md` ·
`docs/ops/cutover.md` · `apps/api/README.md` · `apps/web/README.md`
