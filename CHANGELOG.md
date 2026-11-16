# Changelog

All notable changes to Majadu are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning 2.0](https://semver.org/spec/v2.0.0.html). Entries are
generated from Conventional Commits by `./task release`.

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
