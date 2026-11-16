# Changelog

All notable changes to Majadu are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning 2.0](https://semver.org/spec/v2.0.0.html). Entries are
generated from Conventional Commits by `./task release`.

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
