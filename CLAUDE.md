# CLAUDE.md

Guidance for Claude Code when working in this repository. Runtime facts live in
`docs/handbook/current-status.md`; this file is the short version an agent needs
before touching code.

## Commands

Run from the repo root. `./task` is a dispatcher over `task.d/`; `./task help`
lists every target.

```bash
./task check            # nim check, archcheck, unit tests (no database)
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
- **`db/migrations`** is append-only (56 files today). Every table carries
  `community_id`; queries must scope by it.
- **Business numbers live in the database** (`platform.config` →
  `community.settings`), never as literals. `tools/archcheck` fails on violations.

## Non-negotiables

- Code, identifiers, comments, commit messages, and every document under `docs/`
  are **English**.
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
- E2E runs four Playwright projects (`e2e/browsers.ts`): `iphone-17` (WebKit),
  `poco-f5` (Chromium), `desktop` (Chromium) and `api` for the socket spec.

## Versioning & Release SOP

The repository uses SemVer 2.0 derived from Conventional Commits (`tools/release`).

### Release Rules & Sequence
1. **Source of Truth**: `VERSION` file at repository root.
2. **Conventional Commits**: Bumps require at least one `feat` (minor) or `fix`/`perf` (patch) commit since the last tag. Commits with `!` or `BREAKING CHANGE:` trigger a major bump.
3. **Dry Run**:
   ```bash
   ./task release
   ```
   Inspect the computed bump and rendered changelog preview without writing files.
4. **Apply Bump**:
   ```bash
   ./task release --apply
   ```
   This automatically updates:
   - `VERSION`
   - `CHANGELOG.md`
   - `.cache/release/v<version>.md` (tag message source)
   - `testdata/parity/v2/version.json` (pinned version for parity tests)
   - `testdata/parity/v2/MANIFEST.sha256` (pin checksum)
5. **Commit Release**:
   ```bash
   git add VERSION CHANGELOG.md testdata/parity/v2/
   git commit -m "chore(release): v<version>"
   ```
6. **Pre-release Branch Verification**:
   ```bash
   git push origin HEAD:refs/heads/release/v<version>
   ```
   Wait for CI and Coverage workflows to pass. `release.yml` refuses any tag whose commit lacks a green Coverage run (QA-15).
7. **SSH-Signed Tag**:
   ```bash
   git -c gpg.format=ssh -c user.signingkey=~/.ssh/id_ed25519.pub tag -s -F .cache/release/v<version>.md v<version>
   git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=.github/allowed_signers verify-tag v<version>
   ```
8. **Push Order (CRITICAL: Push Tag First, Then Main)**:
   ```bash
   git push origin refs/tags/v<version>
   git push origin HEAD:main
   ```
   **Why:** Pushing the tag triggers `.github/workflows/release.yml` (builds and signs image with cosign). Pushing `main` triggers the VPS deploy webhook, which immediately polls for the image and signature. Pushing main before tag causes the deploy to fail on timeout waiting for an image that isn't building yet.

## Known limits

- The in-app session screen consumes the WebSocket (`useSessionRealtime`) and
  falls back to a 5 s refetch while the socket is down; the public share page
  polls every 10 s. Realtime is in-memory, so the API must stay a single
  instance.
- The schedule generator runs in the browser
  (`apps/web/src/legacy/generator`); the API stores whatever schedule the client
  sends.
- Production runs on the VPS since the cutover, against `bm2`. A few VPS-side
  checks are still unproven and are listed in `docs/ops/cutover.md`.

## Pointers

`docs/handbook/current-status.md` · `docs/handbook/architecture.md` ·
`docs/handbook/data-model.md` · `docs/handbook/features-and-routes.md` ·
`docs/ops/release.md` · `docs/ops/cutover.md` · `apps/api/README.md` · `apps/web/README.md`
