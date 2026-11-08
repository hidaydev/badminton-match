# Task runner

`./task <target> [args...]`

The dispatcher resolves `task.d/<target>.sh` and executes it with `sh`. The target
name is always the file name; there are no aliases and no hidden targets. An
unknown target prints the list and exits 2.

## Guaranteed environment

| Variable | Meaning |
|---|---|
| `REPO_ROOT` | absolute path of this worktree |
| `WORKTREE` | sanitized basename + 8-char digest of the absolute path |
| `NIMCACHE_CHECK` | `$REPO_ROOT/.cache/$WORKTREE/check` |
| `NIMCACHE_BUILD` | `$REPO_ROOT/.cache/$WORKTREE/build` |

Two worktrees never share a cache directory. `check` and `build` keep separate
directories so switching between them does not churn artefacts; passing an
explicit `--nimcache` does not add a suffix.

## Targets

| Target | Purpose | Needs database |
|---|---|---|
| `check` | `nim check`, unit tests, archcheck, the flaky register and the TypeScript coverage gate | yes (D-6) |
| `build` | release build of `majadu-api` into `.cache/$WORKTREE/bin/`; `tools/*` and `dbtools` are not built here — compile them by hand with the same flags | no |
| `test` | unit + integration tests; every suite runs on its own freshly copied database | integration only |
| `verify <module>` | build and test one module | when it has integration tests |
| `contract-gen` | regenerate routes, client and fingerprint | no |
| `contract-check` | fail when specs and generated files drift | no |
| `ci` | check + build + test + contract check | same as `test` |
| `coverage` | line coverage per module, ratcheted against `coverage-baseline.json`; `--update` rewrites the baseline | no |
| `deps-check` | compare the installed toolchain and Nim packages with `deps.lock` | no |
| `deps-install` | install the Nim packages pinned in `deps.lock` into `~/.nimble` | no |
| `bootstrap` | migrate, seed L1 config, create the first owner and a default community | yes |
| `dev-db` | create the roles, databases and dev schema through `ops/dev/pg-up.sh` | no |
| `dev` | OIDC stub plus the API in watch mode against `bm2_dev`; the web runs under `pnpm dev` | yes |
| `dev-v1` | rebuild `bm_v1_dev` from the captured v1 schema and seed | yes |
| `hooks` | set `core.hooksPath=.githooks` so the pre-push guard runs | no |
| `e2e` | Playwright against a disposable database and the OIDC stub; `--update-snapshots` rewrites the visual baseline | yes |
| `rehearsal` | `check` reads the committed timings, `run` needs the VPS | `run` only |
| `mock-api` | build the mock API binary the web tests use | no |
| `parity` | v1 golden HTTP corpus (`verify`) and the v2 per-operation corpus (`v2 verify`) | for `replay`/`v2` |
| `account` | anonymise an account: close claims, unlink players, drop sessions | yes |
| `ingest` | ingest approved sessions into rating events (tick, session, rebuild) | yes |
| `ranksnapshot` | write today's ranking snapshot for every community | yes |
| `levels` | read or write the tournament point ladder in `rating.levels` | yes |
| `opstoken` | issue, list or revoke CLI bearer tokens | yes |
| `janitor` | purge expired OAuth flows, idempotency keys, outbox rows, revoked links and ws tickets | yes |
| `audit-retention` | prune `account.audit` beyond `audit.retention_days` as `bm2_owner` | yes |
| `r0-demo` | walking skeleton over HTTP against `bm2_r0` | yes |
| `release` | compute the next SemVer from Conventional Commits; `--apply` writes `VERSION` and `CHANGELOG.md` (dry run otherwise) | no |

## Rules

- `lib.sh` is the shared library, not a target; every script sources it.
- Every script starts with `set -eu` (inherited from `lib.sh`) and exits non-zero
  on failure. Use `fail "message"` for errors.
- Tests live next to their module. Files under `tests/integration/` only run when
  `INTEGRATION=1` (set by `test`, not by `check`).
- `test` and `ci` refuse to start unless `MAJADU_PG_DSN` is set and its database
  name contains `test`; `ALLOW_SHARED_DB=1` is the deliberate opt-out and also
  turns isolation off. The suites mutate rows they do not fully own, so pointing
  them at `bm2_dev` is how unrelated failures are manufactured.
- `test` gives every file a database of its own, copied from a database that
  `bm2_template` plus `db/migrations` and `db/seeds` built once for the run
  (`ops/dev/worker.sh` reaches the same helpers by hand). The database
  `MAJADU_PG_DSN` names is never written, which is why a suite no longer has to
  clean up after itself and why the run order cannot change a result.
  `WORKERS=N` builds N of those databases, so two shard jobs share nothing;
  `ISOLATION=0` restores the old shared-database behaviour.
- The integration fixture layer purges a community through
  `purgeCommunity(db, slug)`, which deletes from every base table carrying a
  `community_id` and then the community row. It needs a role with DELETE on the
  append-only tables (`account.audit`, `player.merge_log`, `import.row_map`) —
  the owner/postgres role, not `bm2_app`.
- `.cache/` and `nimcache/` are ignored by Git.

## Timing on the development machine (2026-11-03)

- Cold `./task check` (empty `.cache`): 2.4 s
- Warm `./task check`: 2.2 s
- `./task build` warm: 2.2 s
