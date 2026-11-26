# Changelog

All notable changes to Majadu are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning 2.0](https://semver.org/spec/v2.0.0.html). Entries are
generated from Conventional Commits by `./task release`.

## [2.4.1] - 2026-11-26

### Changed
- docs(ops): order the v1 DSN preflight before and after the owner-run (388d1dd; docs/handbook/current-status.md, docs/ops/cutover.md)
- docs: record the live bm ACL and the bm2 default-ACL gap (f55f755; docs/handbook/current-status.md)
- docs: say which Postgres each environment runs in the remaining two files (50da00c; CLAUDE.md, apps/api/README.md)
- docs(release): record all fourteen releases, not the first three (e9a93b5; docs/ops/release.md)
- docs(cutover): state who the CONNECT asserts actually fire for (d863c41; docs/ops/cutover.md)
- docs: record the 2026-11-26 host run and correct the stale Postgres/version lines (721d1a1; README.md, docs/decisions.md, docs/handbook/architecture.md (+9 more))
- docs: drop the host soak (T-074) and record ADR-023 (774dd9a; docs/decisions.md, docs/handbook/current-status.md, docs/handbook/roadmap.md (+3 more))
- ci: run registry retention daily (0c9de11; .github/workflows/retention.yml)

### Fixed
- fix(ops): require a usable majadu_app login before closing bm (249a51c; docs/ops/cutover.md, ops/db/roles.sql)
- fix(ops): require majadu_app to log in before closing bm (6eed589; docs/ops/cutover.md, ops/db/roles.sql)
- fix(ops): keep v1 able to reach bm when the role is missing (28147cc; docs/ops/cutover.md, ops/db/roles.sql)
- fix(ops): make the archive asserts conditional and the rehearsal runnable (f9da92b; ops/db/roles.sql, ops/scripts/cutover.sh, tools/rehearsal/README.md (+1 more))

## [2.4.0] - 2026-11-25

### Added
- feat(web): reach the community directory from the account menu (3eee581; apps/web/src/App.tsx, apps/web/src/community/DirectoryPage.test.tsx, apps/web/src/community/DirectoryPage.tsx (+3 more))

### Changed
- test(e2e): walk /directory in the a11y baseline (c37675a; e2e/visual.routes.ts)
- docs(routes): list /directory and the account-menu entry (e3a940e; docs/handbook/features-and-routes.md)
- test(security): move the ISO-17 fallback-origin suite to a reserved host (00570a3; apps/api/tests/integration/security/oidc_fallback_origin_test.nim)

## [2.3.1] - 2026-11-25

### Fixed
- fix(ci): nightly order-check provisions the import databases it runs (b962bd6; .github/workflows/nightly.yml)
- fix(levels): resolve the tenant before reading or writing a ladder (bffea98; task.d/policy-test.sh, tools/ratinglevels/main.nim, tools/ratinglevels/tests/integration/policy_levels_test.nim)
- fix(share): sweep every tenant in retire-legacy and rotate (0f0098d; modules/share/store.nim, modules/share/tests/integration/policy_share_tools_test.nim)
- fix(account): anonymize through the tenant facade in every community (45a9962; modules/account/infrastructure/lifecycle_store.nim, modules/account/tests/integration/policy_lifecycle_test.nim)

## [2.3.0] - 2026-11-24

### Added
- feat(db): guard community.membership and drop directory_entries (425eaba; db/migrations/0061_rls_tenant_policies.sql)
- feat(db): add 0061 row level security tenant policies (2694128; db/migrations/0061_rls_tenant_policies.sql)

### Changed
- ci(deps): finish the setup-nim bump the batch merge left behind (ead4e9e; .github/workflows/ci.yml)
- ci(tenancy): run the policy suites as bm2_app on a database that has 0061 (bd8c883; .github/workflows/ci.yml, task, task.d/policy-test.sh (+1 more))
- test(tenancy): fail hard when the policy set is absent (fc91341; apps/api/tests/integration/tenant_scope_route_test.nim, tools/ranksnapshot/tests/integration/snapshot_test.nim)
- test(db): prove a refusal audit row lands and is refused unscoped (bff505a; apps/api/tests/integration/rls_isolation_test.nim)
- test(db): derive views from the catalogue and pin the definer set (c479dd4; apps/api/tests/integration/policy_coverage_test.nim)
- docs: move the migration count to 61 (74eda03; README.md, docs/handbook/current-status.md)
- test(db): prove RLS binds for the application role (c5609f2; apps/api/tests/integration/rls_isolation_test.nim)
- test(db): assert RLS coverage from the catalogue (9caaf20; apps/api/tests/integration/policy_coverage_test.nim)
- chore(deps): pin playwright 1.65.1 in deps.lock and refresh the tree (050ab80; deps.lock)
- chore(deps-dev): bump @testing-library/jest-dom from 7.0.1 to 8.0.0 (530e376; apps/scoreboard/package.json, apps/web/package.json, pnpm-lock.yaml)
- chore(deps): bump the npm-patch-minor group with 10 updates (2d3a2aa; apps/scoreboard/package.json, apps/web/package.json, package.json (+1 more))
- chore(deps): bump the github-actions group with 2 updates (a5ee887; .github/workflows/ci.yml, .github/workflows/nightly.yml, .github/workflows/release.yml)

### Fixed
- fix(tenancy): send a share-link hash as the 32 bytes the column holds (2a3207a; apps/api/tests/integration/policy_definer_bytea_test.nim, modules/share/store.nim, shared/platform-lib/db/db.nim (+1 more))
- fix(deps): record the browser builds playwright 1.65.1 actually installs (ee237aa; deps.lock)
- fix(tenancy): audit each login grant in its own community (e218a54; apps/api/src/app.nim, apps/api/tests/integration/policy_login_audit_test.nim)

## [2.2.0] - 2026-11-24

### Added
- feat(tenancy): read the community context through a definer door (31a3acd; apps/api/src/community_context.nim)
- feat(db): ask the catalogue whether a tenant helper is installed (f849748; shared/platform-lib/db/db.nim)
- feat(tenancy): scope the reads that run before a context exists (6a4bd5b; apps/api/src/app.nim, modules/community/infrastructure/community_store.nim, modules/community/infrastructure/invite.nim (+3 more))
- feat(jobs): bind each community before its statements (71c3e73; modules/platform/janitor.nim, modules/rating/infrastructure/jobs.nim, tools/ranksnapshot/main.nim (+1 more))
- feat(db): declare a community per statement on a scoped facade (fe581ef; shared/platform-lib/db/db.nim, shared/platform-lib/tests/integration/db_test.nim)
- feat(community): serve many communities from one database (bcd0e49; apps/api/src/app.nim, apps/api/src/main.nim, apps/api/tests/http_support.nim (+17 more))
- feat(web): open the create-community panel on every build (87ff35e; apps/web/src/community/tenancy.ts, apps/web/src/i18n/en.ts, apps/web/src/pages/SetupPage.tsx (+2 more))
- feat(web): refuse a second community on a single-community deployment (581e804; apps/web/src/community/tenancy.ts, apps/web/src/i18n/en.ts, apps/web/src/pages/SetupPage.tsx (+2 more))
- feat(community): refuse a second community on the create route (0258c62; apps/api/src/app.nim, apps/api/src/main.nim, apps/api/tests/integration/community_limit_http_test.nim (+11 more))

### Changed
- test(jobs): give the janitor wrapper case a community to sweep (8b5c4a8; tools/opstoken/tests/integration/wrappers_test.nim)
- test(tenancy): prove the three pre-context paths against 0061 as bm2_app (112152a; apps/api/tests/integration/tenant_scope_guc_test.nim, apps/api/tests/integration/tenant_scope_route_test.nim)
- test(deploy): lock the job env split instead of the old shared one (7f61741; tools/shelltests/tests/deploy_guards_test.nim)
- test(jobs): run the nightly paths as the application role (30e3c70; apps/api/tests/integration/janitor_test.nim, modules/platform/janitor.nim, shared/platform-lib/tests/app_role_fixture.nim (+2 more))
- ops(job-env): run the scheduled jobs on a one-variable env file (3e8f4fd; ops/env/prod-job.env.example, ops/env/prod-tools.env.example, ops/systemd/majadu-ingest.service (+2 more))
- ci(e2e): run one browser job on pull requests, keep two on main (3a0aa14; .github/workflows/ci.yml)
- test(api): prove the prod refusal and give the tournament probe a real draw (14de1a5; apps/api/tests/http_support.nim, apps/api/tests/integration/community_isolation_matrix_test.nim)

### Fixed
- fix(jobs): fail loudly when a nightly run reached no community (e6b04c2; modules/platform/janitor.nim, tools/janitorcli/main.nim, tools/ranksnapshot/main.nim (+1 more))
- fix(tenancy): list memberships and create a community under a tenant (9be03ab; apps/api/src/app.nim, modules/community/infrastructure/community_store.nim)
- fix(tenancy): read a community's settings on its own scope (9124632; apps/api/src/community_context.nim)
- fix(import): declare the community before the loader writes (ef7e2eb; tools/import/main.nim)
- fix(audit): name the community on a refusal written before the tenant is installed (e288e9c; apps/api/src/app.nim)

## [2.1.2] - 2026-11-21

### Fixed
- fix(ops): keep :local alive across the rotation, reset a latched unit (1ef0c84; apps/web/README.md, apps/web/vercel.json, ops/scripts/deploy-vps.sh (+3 more))

## [2.1.1] - 2026-11-21

### Fixed
- fix(test): stop the two suites the release shards died on (94b6196; docs/decisions.md, modules/platform/tests/integration/idempotency_test.nim, modules/rating/tests/integration/read_test.nim)

## [2.1.0] - 2026-11-21

### Added
- feat(share): let a draft session carry a share link, capped at 48 hours (0d266c6; apps/api/src/app.nim, apps/api/tests/integration/problem_codes_http_test.nim, apps/api/tests/integration/security/idor_escalation_test.nim (+10 more))

### Changed
- docs(handbook): stop claiming CI judges the coverage ratchet (80de2cd; docs/handbook/current-status.md, docs/handbook/roadmap.md)
- refactor(ops): purge the release-candidate instance (227f83b; .github/workflows/release.yml, apps/scoreboard/README.md, apps/web/README.md (+23 more))
- test(ops): give release-rollback's fixtures the flock fake (27bf74e; tools/shelltests/tests/ops_scripts_test.nim)
- docs: state the real worker and pool sizing in the architecture handbook (d58b825; docs/handbook/architecture.md)
- test(qa): prove the drain on a real SIGTERM and cover the bootstrap ladder (70405ef; apps/api/tests/drain_shutdown_test.nim, apps/web/src/auth/AuthProvider.test.tsx)
- ci: state the nightly history plainly (f5b4b45; .github/workflows/nightly.yml)
- ci: fold the contract job into api-check and notify into gate (00f1c09; .github/workflows/ci.yml, .github/workflows/nightly.yml, docs/handbook/architecture.md (+3 more))
- ci(gate): one ./task gate target, same file as the other seven repos (abf2b36; .github/workflows/ci.yml, docs/handbook/current-status.md, ops/scripts/contract-check.sh (+6 more))
- ci(retention): cap the GHCR package at the 10 newest versions (d33d8ef; .github/workflows/retention.yml)
- ci(coverage): drop the instrumented coverage graph (bf84905; .github/workflows/ci.yml, .github/workflows/coverage.yml, .github/workflows/release.yml (+7 more))
- ci(deps): provision the runtime and coverage toolchains once per cache key (#82) (fc431d6; .github/workflows/ci.yml, .github/workflows/coverage.yml, .github/workflows/nightly.yml (+7 more))
- ci(pipeline): cheap preflight gate in front of the expensive jobs (#81) (3357944; .github/workflows/ci.yml, .github/workflows/coverage.yml, .github/workflows/release.yml (+4 more))

### Fixed
- fix(ops): keep one weekly bm2 dump outside the daily rotation (df80c46; ops/scripts/backup.sh)
- fix(rating): read every tournament's games in one bulk connection (444b234; modules/rating/infrastructure/tournament.nim, modules/rating/projection.nim, modules/rating/tests/integration/read_test.nim (+1 more))
- fix(ops): keep the owner DSN out of the process arguments (2132e73; ops/scripts/deploy-vps.sh, ops/scripts/rollback.sh)
- fix(ci): page on a cancelled nightly too (2da906f; .github/workflows/nightly.yml)
- fix(ops): stop rotate-log making one gzip per tick per idle log (df3e0df; ops/scripts/rotate-log.sh, tools/shelltests/tests/ops_scripts_test.nim)
- fix(ops): boot ordering and the deploy drift check from the host audit (82156f6; ops/scripts/deploy-check.sh, ops/systemd/majadu-api.container, ops/systemd/majadu-backup.service (+3 more))
- fix(task): detect suite order dependence inside one run and gate on it (22201d0; .github/workflows/nightly.yml, docs/test-plan.md, task.d/test.sh (+2 more))
- fix(dev): say how far behind the local database is before serving (e5a7b52; task.d/dev.sh, task.d/lib.sh, tools/shelltests/tests/lib_guards_test.nim)
- fix(web): re-raise the update banner while a worker waits (e514060; apps/web/src/App.tsx, apps/web/src/pwa/updateCheck.test.ts, apps/web/src/pwa/updateCheck.ts)
- perf(ci): cache the release image layers (4d0a22e; .github/workflows/release.yml)
- fix(ci): untag the pulled image, label the release build, keep failure evidence (5ece44c; .github/workflows/release.yml, ops/scripts/deploy-vps.sh)
- fix(ops): lock before the checkout, bound the migrations, lock the rollback (26ceecb; ops/scripts/deploy-vps.sh, ops/scripts/release-rollback.sh)
- fix(api): retry a failed rating job once, batch share tickets, cap auth sessions (12afa97; apps/api/src/app.nim, apps/api/src/live.nim, apps/api/src/server.nim (+8 more))
- fix(data): index the absent lookup, drop the duplicate keys, delete the dead config rows (6634fe4; CLAUDE.md, README.md, apps/api/README.md (+9 more))
- fix(web): keep the shell loading offline and stop one read blanking admin (a5c9abc; apps/web/src/auth/AuthProvider.test.tsx, apps/web/src/auth/AuthProvider.tsx, apps/web/src/i18n/en.ts (+2 more))
- fix(ops): outwait the drain on a stop, and settle the backup unit's schedule (8e9c025; .github/pull_request_template.md, docs/test-plan.md, ops/systemd/majadu-api.container (+4 more))
- fix(data): bound the janitor run and make a restore re-apply the roles (000ec97; CLAUDE.md, README.md, apps/api/README.md (+9 more))
- fix(api): size workers above core count, bound watcher queues, retryable drains (74edc26; apps/api/src/app.nim, apps/api/src/live.nim, apps/api/src/main.nim (+3 more))
- fix(task): make the gate layer fail when it cannot read or finish (b54047b; task.d/coverage-debt.sh, task.d/e2e.sh, task.d/flakeregister.sh (+6 more))
- fix(web): detect a dead session socket and keep a landed save landed (2aacf34; apps/web/src/legacy/hooks/useDebouncedPublish.test.tsx, apps/web/src/legacy/queries/sessionRealtime.test.tsx, apps/web/src/legacy/queries/sessions.ts)
- fix(web): stop the roster read from poisoning the cache (f5a9ffb; apps/web/src/legacy/queries/endpoints.ts, apps/web/src/legacy/queries/playerCache.test.ts)
- fix(ops): refuse a bm2 backup without an owner DSN and add the backup timer (2f89f71; docs/ops/cutover.md, ops/scripts/backup.sh, ops/systemd/majadu-backup.service (+1 more))
- fix(task): fail loudly when the test file list is empty (0719234; task.d/check.sh, task.d/coverage.sh, task.d/lib.sh (+2 more))
- fix(scoreboard): guard Reset with the writer check (9cce3f4; apps/scoreboard/src/pages/ScoreboardPage.test.tsx, apps/scoreboard/src/pages/ScoreboardPage.tsx)
- fix(web): make OCC recovery reads bypass the 30s cache (e435733; apps/web/src/legacy/queries/sessionOcc.test.tsx, apps/web/src/legacy/queries/sessions.ts)
- fix(api): revalidate pooled connections and settle idempotency keys in-transaction (23dda3a; apps/api/src/app.nim, modules/platform/tests/integration/idempotency_test.nim, shared/platform-lib/db/db.nim (+1 more))
- perf(ci): split the browser suite and take the fourth test shard (1b2d3c0; .github/workflows/ci.yml, .github/workflows/release.yml, task.d/test-costs.sh)
- perf(ci): three test shards, and the coverage toolchain leaves the pipeline (6a17411; .github/workflows/ci.yml, .github/workflows/release.yml, CONTRIBUTING.md (+8 more))
- fix(web): skip a Vercel build against the previous deploy, not HEAD^ (#80) (75a029c; apps/web/README.md, apps/web/vercel.json, task.d/ci-guards.sh (+1 more))

## [2.0.6] - 2026-11-18

### Changed
- ci(e2e): install the pinned browser libraries instead of --with-deps (#77) (684770b; .github/workflows/ci.yml, .github/workflows/nightly.yml, .github/workflows/release.yml (+6 more))

### Fixed
- fix(e2e): cache the browser system packages and cap the install step (#78) (27616d0; .github/workflows/ci.yml, .github/workflows/nightly.yml, .github/workflows/release.yml (+4 more))
- fix(release): install browsers with the launch check instead of a bare --with-deps (#76) (5c53cdd; .github/workflows/release.yml, tools/shelltests/tests/workflow_contract_test.nim)

## [2.0.5] - 2026-11-18

### Changed
- docs: drop em dashes from CONTRIBUTING (f2e6984; CONTRIBUTING.md)
- docs(security): document the osv-scanner exception contract and guard it (3880a8f; docs/handbook/deps-format.md, osv-scanner.toml, tools/shelltests/tests/osv_exception_test.nim)
- docs(security): name a channel that works while private reporting is off (5bb58fd; SECURITY.md)
- docs(readme): reorder the README to the repository documentation standard (3454a6c; README.md)
- ci(contract): accept a static-host frontend and never plan an empty shard (0a8314b; ops/scripts/cicd-standard-check.sh, task.d/lib.sh, tools/shelltests/tests/lib_guards_test.nim)
- docs(ops): record what a CI wall number does not say (933fb95; docs/ops/operations.md, task.d/test-costs.sh)
- ci(standard): drop the coverage poll, guard Dependabot PRs, run the static rules (b0f5778; .github/workflows/ci.yml, docs/handbook/current-status.md, ops/scripts/cicd-standard-check.sh (+1 more))

### Fixed
- fix(dev): reach Postgres through the pg18 container on a host without psql (222728b; CONTRIBUTING.md, README.md, e2e/global-setup.ts (+4 more))
- fix(deploy): serialise the RC build and use one lock-wait constant (797563a; docs/ops/rc.md, ops/scripts/deploy-vps-rc.sh, ops/scripts/deploy-vps.sh (+1 more))
- perf(ci): split the test shards by measured cost (147bea9; task.d/lib.sh, task.d/test-costs.sh, task.d/test.sh (+1 more))

## [2.0.4] - 2026-11-18

### Changed
- chore: ignore local mcp-results output (92074df; .gitignore)
- test(achievement): pin the BO3 format rule in the backfill suite (57abe7a; modules/achievement/tests/integration/backfill_format_test.nim)
- chore(ci): strip signature block from release notes in release.yml (2871e23; .github/workflows/release.yml)

### Fixed
- fix(web): show tier and tournament medals on the player shelf (113c88f; apps/web/src/legacy/components/ratings/AchievementBadge.tsx, apps/web/src/legacy/components/ratings/AchievementDetailModal.tsx, apps/web/src/legacy/config/achievements.ts (+4 more))

## [2.0.3] - 2026-11-16

### Changed
- docs: fix Button.tsx path in design-system.md (0181f14; docs/design-system.md)
- docs: prune stale QA spike sessions and handover snapshot (8f385f6; HANDOVER.md, docs/README.md, docs/handbook/README.md (+5 more))
- docs: audit and prune documentation for v2.0.2 (deaf079; CLAUDE.md, HANDOVER.md, README.md (+29 more))

### Fixed
- fix(docs): clarify release SOP, version bump workflow, and beautify README (d3f8d24; .gitignore, AGENTS.md, CLAUDE.md (+1 more))

## [2.0.2] - 2026-11-16

### Fixed
- fix(ops): wait for the image signature instead of failing the deploy (dfab039; ops/scripts/deploy-vps.sh, tools/shelltests/tests/deploy_guards_test.nim)
- fix(web): rebuild the SPA when VERSION changes (7ea5391; apps/web/README.md, apps/web/vercel.json)

## [2.0.1] - 2026-11-16

### Changed
- chore(ci): pin Nim 2.4.2 and record it in deps.lock (8bb85d6; .github/workflows/ci.yml, .github/workflows/coverage.yml, .github/workflows/nightly.yml (+2 more))
- chore(deps): pin playwright 1.65.0 and its browser builds (4989c57; deps.lock, e2e/README.md)
- chore(deps): bump the npm-patch-minor group with 9 updates (89ce1f4; apps/scoreboard/package.json, apps/web/package.json, package.json (+1 more))
- ci(image): start the image job after a green gate instead of skipping with it (7aa3a13; .github/workflows/ci.yml)
- test(docs-check): cover HEAD:main in the release order rule (a19112a; tools/shelltests/tests/docs_check_test.nim)
- test(ci): expect the gate without image and coverage-gate (#66) (47c1d32; tools/shelltests/tests/workflow_contract_test.nim)
- ci(deploy): publish the image only after the gate (#65) (44d7fd7; .github/workflows/ci.yml, docs/ops/release.md, ops/scripts/deploy-vps.sh)
- chore(deps-dev): bump jsdom from 30.1.3 to 31.0.0 (1bddab0; apps/scoreboard/package.json, apps/web/package.json, pnpm-lock.yaml)
- chore(deps): bump the github-actions group with 3 updates (c259d1c; .github/workflows/ci.yml, .github/workflows/coverage.yml, .github/workflows/nightly.yml (+1 more))
- ci(deploy): deploy the image of the pushed commit (6930ec3; docs/ops/release.md, ops/scripts/deploy-vps.sh, ops/scripts/release-rollback.sh (+1 more))
- ci(image): publish sha and main images on every push to main (208ce1d; .github/workflows/ci.yml, docs/ops/release.md)
- ci(deps): group patch and minor bumps so one weekly round is one PR (12ae897; .github/dependabot.yml)
- test(ops): give the cutover fixtures the roles.sql the script now feeds over stdin (6128883; ops/db/roles.sql, tools/shelltests/tests/deploy_guards_test.nim)

### Fixed
- fix(ops): restart Caddy on cutover, never reload (7ec266b; ops/scripts/cutover.sh)
- fix(deps): correct the deps.lock tree digest for the grouped bump (be1e216; deps.lock)
- fix(release): refresh the parity corpus digest with the version pin (5124c31; tools/release/main.nim, tools/release/tests/repo_test.nim)
- fix(release): keep release bookkeeping out of the changelog (c76ddc0; tools/release/repo.nim, tools/release/tests/repo_test.nim)
- fix(release): accept HEAD:main in the docs release-order check (3b76ab2; docs/ops/release.md, task.d/docs-check.sh)
- fix(release): move the parity version pin and push before tagging (d6c2db6; docs/ops/release.md, tools/release/main.nim, tools/release/tests/repo_test.nim)
- fix(release): print the SSH-signed tag command the gate accepts (295bc2a; docs/ops/release.md, tools/release/main.nim, tools/release/tests/repo_test.nim)
- fix(e2e): give every repeat its own fixture session (84edf1c; e2e/global-setup.ts, e2e/session-occ.spec.ts, e2e/session-write.spec.ts (+1 more))
- fix(web): fall back to the API socket host on deployed pages (e00a5d1; apps/web/README.md, apps/web/src/legacy/queries/sessionRealtime.test.tsx, apps/web/src/legacy/queries/sessions.ts (+1 more))
- fix(ops): accept the spaced asset digest field too (0e18fe9; ops/scripts/deploy-vps.sh, tools/shelltests/tests/deploy_guards_test.nim)
- fix(ops): count release-body digests, not the assets' own digests (4c9daca; ops/scripts/deploy-vps.sh, tools/shelltests/tests/deploy_guards_test.nim)
- fix(ops): judge a symlinked credential by the file it points at (fa78bb8; ops/scripts/bootstrap-rc.sh, ops/scripts/cutover.sh, ops/scripts/deploy-common.sh (+3 more))
- fix(player): let a sole admin decide a claim they filed (3da14d1; apps/api/tests/integration/problem_codes_http_test.nim, modules/player/claim.nim, modules/player/tests/integration/claim_test.nim)
- fix(ops): seed the owner under the import slug and tolerate a generated unit (e8b7f5b; ops/scripts/cutover.sh)
- fix(ops): feed roles.sql to the containerised psql over stdin (f209c5c; ops/scripts/cutover.sh)
- fix(ops): stop roles.sql from locking the v1 role out of bm (f181991; ops/db/roles.sql)
- fix(ops): count the release digest in the release text, not the asset digests (f07914e; ops/scripts/cutover.sh)
- fix(ops): unblock the bm2 cutover and the prune role (#52) (973ff1b; docs/ops/audit.md, ops/caddy/Caddyfile.api.qouver.com, ops/caddy/log-share.caddy (+4 more))

## [2.0.0] - 2026-11-09

### Added

- Google OIDC login with first-owner bootstrap and platform owner administration.
- Communities, players, sessions, doubles and singles scoring, and share links.
- Rating projection with Elo events, leaderboards, rank snapshots and achievements.
- Tournament support with point ladders and classic tournament views.
- Live session watchers over WebSocket with per-session and per-address limits.
- A v1 to v2 ETL importer, audit retention, janitor and account lifecycle tools.
- An installable scoreboard PWA and an internationalised web client.
- CI gates for contract drift, coverage, mutation, parity, E2E, visual and a11y.

### Changed

- The database is the `bm2` schema; production cutover from `bm` is a separate
  documented operation with a tested rollback.
- Releases are built once per tag, published by digest to GHCR, signed with
  cosign, and deployed by pulling that digest.
- The API runs as `bm2_app`; migrations and destructive tools use `bm2_owner`
  from a tool-only env file.

### Fixed

- Deploy failures no longer overwrite the record of the running release.
- A missed webhook delivery now produces a deploy drift alert.
- Ambiguous release notes cannot redirect production to an arbitrary digest.
