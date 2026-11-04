# Contributing

Majadu is a community badminton session and tournament manager. The backend is
written in Nim (`apps/api`, `modules/`, `shared/platform-lib`) and the web client
is React 19 with Vite and Tailwind CSS 4 (`apps/web`). Both live in one pnpm
workspace and share a single task runner, `./task`.

Contributions are welcome. The workflow is fork, branch, pull request: open a PR
against `main` from a branch in your fork. Large changes should start as an issue
so the approach can be agreed on before the work is done.

## Prerequisites

Pin the same versions the project uses. They are recorded in `deps.lock`,
`package.json`, and the CI workflows.

| Tool | Version | Source |
|---|---|---|
| Nim | 2.4.0 | `deps.lock`, `.github/workflows/ci.yml` |
| PostgreSQL | 18.x | CI uses `postgres:18.6` |
| Node.js | 22 | `.github/workflows/ci.yml` |
| pnpm | 11.25.0 | `packageManager` in `package.json` |

You also need a POSIX shell and `psql`. Nim packages are installed by hand into
`~/.nimble/pkgs2`; `./task deps-check` verifies what is installed against
`deps.lock`.

## Local setup

```sh
pnpm install                 # workspace dependencies
./task dev-db                # create bm2_dev, bm2_template, and the bm2 roles
export MAJADU_PG_DSN="postgresql://$USER@127.0.0.1:5432/bm2_dev"
./task bootstrap --sub <google-sub> [--email <address>]
```

`./task dev-db` needs `psql`; it writes the generated development role passwords
to `.env.local` (gitignored). `./task bootstrap` applies migrations, seeds the L1
platform config, and creates the first platform owner and a default community.

Day-to-day commands:

| Command | What it does |
|---|---|
| `./task check` | Fast gate: `nim check`, the architecture checker, and unit tests. No database. |
| `./task test` | Unit and integration tests. Integration tests need `MAJADU_PG_DSN` pointed at a migrated database. |
| `./task build` | Release build of the API binary into `.cache/<worktree>/bin/majadu-api`. |
| `./task ci` | `check` + `build` + `test` + `contract-check`. |
| `./task contract-gen` | Regenerate the merged OpenAPI document, Nim route skeletons, and TypeScript client. |
| `./task deps-check` | Verify installed toolchain and packages against `deps.lock`. |

The web client has its own checks:

```sh
cd apps/web
pnpm check                   # TypeScript, ESLint, Tailwind guard, Vitest
```

## Branches and commits

* Branch from `main` in your fork; name branches after the change, for example
  `fix/join-request-race` or `feat/session-approval`.
* Use Conventional Commits: `feat(scope): ...`, `fix(scope): ...`,
  `docs(scope): ...`, `refactor(scope): ...`, `test(scope): ...`. Add `!` or a
  `BREAKING CHANGE:` footer for an incompatible change.
* One logical change per pull request. Keep unrelated refactors out of it.
* Never push to `main` directly, and do not rewrite or force-push history on a
  branch that is under review.

## Code rules

These are enforced rules, not suggestions.

* Identifiers, code comments, log messages, and commit messages are in English.
  Internal documentation under `docs/` may be in Indonesian.
* Every user-visible string lives in `apps/web/src/i18n/en.ts`. Do not hardcode
  copy in components.
* Business numbers come from the database, not from code. Values resolve from
  `community.settings` (L2) to `platform.config` (L1); a missing required key
  fails startup instead of falling back to a constant.
* Every new HTTP operation needs a contract entry. Edit
  `packages/contracts/openapi/core.yaml` or `community.yaml`, then run
  `./task contract-gen`, and commit the regenerated files. `./task contract-check`
  fails when specs and generated files drift.
* Migrations are append-only. Add the next numbered file under `db/migrations/`;
  never edit a migration that has already been applied.
* Do not edit generated files by hand: `apps/api/src/routes_gen.nim`,
  `packages/contracts/openapi/api.yaml`, `packages/web-client/src/api.ts`, and
  `packages/contracts/openapi/CONTRACT.sha256`.

## Gates a pull request must pass

| Gate | Command |
|---|---|
| Fast check | `./task check` |
| Tests | `./task test` |
| Release build | `./task build` |
| Contract | `./task contract-check` |
| Web | `cd apps/web && pnpm check` |

CI runs `./task check`, `./task test`, and `./task contract-check`, plus the web
checks and build, and an image build. A pull request that fails a gate is not
merged.

## Where to start

* `docs/plan/TECH-SPEC.md` — architecture, data model, security, and build rules.
* `docs/handbook/README.md` — product overview, architecture, and feature map.
* `docs/design-system.md` — UI tokens and typography.

Open an issue before a large change so the design can be discussed first.
