# Changelog

All notable changes to Majadu are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning 2.0](https://semver.org/spec/v2.0.0.html). Entries are
generated from Conventional Commits by `./task release`.

## [2.0.1] - 2026-11-16

### Changed
- test(ops): give the cutover fixtures the roles.sql the script now feeds over stdin (6128883; ops/db/roles.sql, tools/shelltests/tests/deploy_guards_test.nim)

### Fixed
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
