# Test plan

Owner: QA. Last review: 2026-11-10. This document is the risk map, not the test
suite: it says what is covered, at which layer, and what is deliberately not
covered. A test that is missing here is a gap, not an omission somebody has to
guess.

## 1. Scope and non-goals

In scope: the Nim API (`apps/api`, `modules/`, `shared/platform-lib`), the web
client (`apps/web`), the scoreboard PWA (`apps/scoreboard`), the contract and its
generated clients, the ETL importer, the operator scripts, and the workflows that
gate a merge or a tag.

Out of scope, on purpose:

- **The VPS runtime.** Podman, Quadlet, Caddy and systemd are proven by the
  shelltests only (`tools/shelltests/tests/ops_scripts_test.nim`,
  `deploy_guards_test.nim`). Execution on the host is tracked in
  `docs/ops/operations.md` §6.
- **Real Google OIDC.** `tools/oidc-stub` issues the token; the replay and
  nonce cases prove the verifier, not Google.
- **Browser matrix beyond two phones.** `e2e/browsers.ts` is the list. Firefox
  is excluded by an owner decision recorded in `e2e/README.md`.
- **Fuzzing and property tests.** No harness exists; the mutation manifest is
  the closest substitute and it is narrow (§5).

## 2. Layers

| Layer | What it proves | Where | Cost |
|---|---|---|---|
| Unit | one module's rules, no I/O | `modules/*/tests/*_test.nim` | seconds |
| Database-backed | rules against a real schema, one fresh database per suite | `apps/api/tests/integration/`, `apps/api/tests/security/` | ~1 s each plus clone |
| HTTP integration | the router, session gate, problem envelope | `apps/api/tests/integration/*_http_test.nim` | one server per suite |
| Contract | the specs, the generated routes and the TS client agree | `./task contract-check`, `packages/contracts/openapi/CONTRACT.sha256` | seconds |
| Parity | recorded v1/v2 responses still match | `./task parity verify`, `./task parity v2 verify` | minutes |
| E2E | router, server gate and UI visibility together | `e2e/*.spec.ts`, two phone engines | minutes |
| Gates | coverage ratchet, mutation, deps, docs, architecture | `./task check`, `coverage.yml`, `nightly.yml` | varies |

`./task check` runs the unit layer and the static gates; `./task test` adds the
database-backed and integration layers. A suite under `tests/integration/` is
only run when a DSN is present, and the runner says how many suites it ran
instead of implying the whole tree.

## 3. Risk register

| Module | Risk | Why | Primary suites |
|---|---|---|---|
| `modules/account` | High | authorization classes, sessions, invites, claims, OIDC | `tests/authz_matrix_test.nim`, `apps/api/tests/security/{idor_escalation,csrf_redirect,oidc_replay,ratelimit}_test.nim`, `integration/auth_sessions_http_test.nim`, `e2e/authz.spec.ts` |
| `modules/session` | High | scoring rules, optimistic concurrency, schedule generation, swaps | `tests/scoring_test.nim`, `tests/integration/{schedule,swap,write}_test.nim`, `integration/session_{concurrency,schedule}_http_test.nim`, `e2e/session-{write,occ}.spec.ts` |
| `modules/tournament` | High | bracket generation, idempotency, match writes | `tests/{classic,team}_test.nim`, `tests/integration/store_test.nim`, `integration/tournament_http_test.nim`, `e2e/draw.ts` fixtures |
| `modules/share` | High | share-code crypto and key rotation | `tests/crypto_test.nim`, `e2e/shared.spec.ts`, `tools/sharekeys/tests` |
| `modules/rating` | Medium | projection, job ticks, level ladder | `tests/`, `tools/ratingingest/tests`, `integration/rankings_http_test.nim` |
| `modules/player` | Medium | merge, claims, name normalization | `tests/`, `integration/player_http_test.nim` |
| `modules/community` | Medium | membership roles, join requests, settings | `tests/`, `integration/community_http_test.nim`, `integration/config_routes_test.nim` |
| `modules/platform` | Medium | config snapshot, clock, database helpers | `tests/`, `apps/api/tests/{middleware,client_ip,request_id,quota_route}_test.nim` |
| `modules/achievement` | Low | badges are derived, not authoritative | `tests/`, `integration/janitor_test.nim` |
| `apps/api` dispatch | High | every route must be reachable and gated | `tests/routes_dispatch_test.nim` (matrix-driven anonymous sweep), `tests/routes_test.nim` |
| ETL (`tools/import`) | High | cutover correctness | `tools/import/tests/import_test.nim`, `testdata/import/production-shaped.sql`, `nightly.yml` |
| `apps/web` | Medium | member-facing flows, hooks, router | `apps/web/src/**/*.test.tsx`, `pnpm check:web` |
| `apps/scoreboard` | Medium | the score is the product | `apps/scoreboard/src/**`, `e2e/scoreboard.spec.ts`, `./task scoreboard-pwa` |
| Operator scripts | High | deploy, cutover, rollback | `tools/shelltests/tests/ops_scripts_test.nim`, `deploy_guards_test.nim` |

## 4. Requirement traceability

| Area | Requirement or contract | Suite |
|---|---|---|
| Authorization | every operation in `testdata/authz/matrix.yaml` | `modules/account/tests/authz_matrix_test.nim` (classifier), `apps/api/tests/routes_dispatch_test.nim` (anonymous sweep per operation) |
| Authorization, role boundary in the UI | a member cannot see or trigger a staff action | `e2e/authz.spec.ts` |
| Contract | 75 operations, one fingerprint | `./task contract-check`, `./task docs-check` |
| Scoring | the rules in `docs/handbook/scoring-presets.md` | `modules/session/tests/scoring_test.nim`, `tools/rating*/tests` |
| Concurrency | two writers, one winner | `integration/session_concurrency_http_test.nim`, `e2e/session-occ.spec.ts` |
| Migration | schema reachable, upgrade from N-1 preserves rows | `tools/dbtools/tests/integration/migrations_test.nim` |
| Cutover | v1 data arrives intact | `tools/import/tests/import_test.nim` (including the verify canary) |
| Coverage | the ratchet, per file and total | `./task coverage`, `task.d/fixtures/coverage/` models |
| Accessibility | WCAG A/AA on every route | `e2e/a11y.spec.ts` + `e2e/a11y-exemptions.json` |
| Reflow | 320 CSS pixels without horizontal scroll | `e2e/reflow.spec.ts` |
| Visual | reviewed baselines on both platforms | `e2e/visual.spec.ts`, `e2e/nav.spec.ts` |
| Flake process | every quarantine has owner, firstSeen, expires, issue | `docs/handbook/flaky-tests.json`, `./task check` |

## 5. Known gaps

Dated from the RC audit (2026-11-09). Each is either an exemption with an expiry
or work that needs an environment this repository cannot provide.

| Gap | Status | Owner | Where recorded |
|---|---|---|---|
| 13 routes have no axe walk | dated exemption | QA | `e2e/a11y-exemptions.json` (2027-03-31) |
| Keyboard pass is limited to the two sheets | partial | QA | `e2e/overlay.spec.ts` |
| No 1M-request soak on the VPS | open | owner | `docs/handbook/roadmap.md` T-074 |
| Mutation manifest covers 6 files | open | QA | `tools/mutation/manifest.txt` |
| Import fixture is synthetic plus production-shaped | partial | QA | `testdata/import/` |
| Web coverage threshold is below the API's | open | web | `apps/web/vitest.config.ts` |
| Scoreboard has no API round-trip in e2e | open | QA | `e2e/scoreboard.spec.ts` |
| 13 files sit under the 80 percent line floor | dated exception | QA | `docs/handbook/coverage-debt.json` |
| Branch coverage is reported, not gated | open | QA | `task.d/coverage.sh` |

## 6. Adding a test

1. Put a module rule in `modules/<name>/tests/`; put anything that needs the
   schema in `tests/integration/` so `./task check` stays database-free.
2. Add the suite to this plan's risk table if it covers a new risk.
3. For a new screen, add it to `e2e/visual.routes.ts` or to
   `e2e/a11y-exemptions.json`; the guard in `a11y.spec.ts` fails otherwise.
4. For a new operation, update the contract and `testdata/authz/matrix.yaml`;
   the dispatch sweep and the classifier test both read it.
5. Do not add a skip without `task.d/skip-allowlist.txt` (owner and expiry), and
   do not add a quarantine without `docs/handbook/flaky-tests.json`.
